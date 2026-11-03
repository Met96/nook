import SwiftUI
import AppKit

/// Pause whatever is playing: the system "now playing" app (YouTube in a browser, Podcasts…)
/// via the private MediaRemote framework, plus Spotify/Music explicitly via AppleScript.
func pauseAllMedia() {
    if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
       let sym = dlsym(h, "MRMediaRemoteSendCommand") {
        typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
        _ = unsafeBitCast(sym, to: Send.self)(1, nil)   // 1 = kMRPause (pause, never toggles)
    }
    for (bundle, name) in [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
    where !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
        NSAppleScript(source: "tell application \"\(name)\" to pause")?.executeAndReturnError(nil)
    }
}

// MARK: - Data

struct Usage: Decodable {
    struct Window: Decodable { let utilization: Double; let resets_at: String? }
    let five_hour: Window?
    let seven_day: Window?
}

func sh(_ path: String, _ args: [String]) -> Data {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return d
}

// Formatters are expensive to build (thread-safe, so shared); parseDate runs per log line and on every render.
private let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlain = ISO8601DateFormatter()
func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

// Undocumented endpoint Claude Code itself uses for /usage. May break without notice.
struct PR: Decodable, Identifiable {
    struct Repo: Decodable { let name: String }
    struct Commits: Decodable {
        struct Node: Decodable {
            struct Commit: Decodable { struct Rollup: Decodable { let state: String }; let statusCheckRollup: Rollup? }
            let commit: Commit
        }
        let nodes: [Node]
    }
    let number: Int, title: String, url: String, repository: Repo
    var commits: Commits? = nil
    var id: String { url }
    /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED, or nil when the repo has no checks
    var ci: String? { commits?.nodes.first?.commit.statusCheckRollup?.state }
    var failing: Bool { ci == "FAILURE" || ci == "ERROR" }
}

/// Open PRs + CI state of their last commit, via the GitHub CLI's existing login.
/// Empty if gh is missing or logged out.
func fetchPRs(_ filter: String) -> [PR] {
    struct Response: Decodable { struct D: Decodable { struct S: Decodable { let nodes: [PR] }; let search: S }; let data: D }
    guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile) else { return [] }
    let query = "query($q:String!){search(query:$q,type:ISSUE,first:30){nodes{... on PullRequest{number title url repository{name} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}"
    let out = sh(gh, ["api", "graphql", "-f", "q=is:pr is:open archived:false \(filter)", "-f", "query=\(query)"])
    return (try? JSONDecoder().decode(Response.self, from: out))?.data.search.nodes ?? []
}

func fetchLimits() -> Usage? {
    let raw = sh("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let token = (j["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String else { return nil }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let sem = DispatchSemaphore(value: 0)
    var out: Usage?
    URLSession.shared.dataTask(with: req) { d, resp, _ in
        // Only a real 200 with data counts: an error body (e.g. 429) also decodes, as an empty Usage.
        if (resp as? HTTPURLResponse)?.statusCode == 200, let d,
           let u = try? JSONDecoder().decode(Usage.self, from: d), u.five_hour != nil {
            out = u
            UserDefaults.standard.set(d, forKey: "limits")   // survives relaunches
        }
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

/// Serial queue for all background work, so scans never overlap and the cache below needs no lock.
let work = DispatchQueue(label: "nook.work", qos: .utility)

struct TokenEntry { let id: String?, ts: Date, n: Int, model: String? }
/// Per log file: bytes already parsed + what they contained. Logs are append-only, so each scan reads only the tail.
private var tokenCache: [URL: (offset: UInt64, entries: [TokenEntry])] = [:]

func scanTokens() -> (today: Int, month: Int, top: String) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    let cutoff = Date().addingTimeInterval(-30 * 86400), dayStart = Calendar.current.startOfDay(for: Date())
    let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
    let usageMark = Data("\"usage\"".utf8)
    var live = Set<URL>()
    for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) ?? .init()
    where url.pathExtension == "jsonl" {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mod = v.contentModificationDate, mod > cutoff, let size = v.fileSize.map(UInt64.init) else { continue }
        live.insert(url)
        var c = tokenCache[url] ?? (0, [])
        if size < c.offset { c = (0, []) }   // truncated/rewritten: start over
        if size > c.offset, let h = try? FileHandle(forReadingFrom: url) {
            try? h.seek(toOffset: c.offset)
            let data = (try? h.readToEnd()) ?? Data(); try? h.close()
            if let nl = data.lastIndex(of: 10) {   // only complete lines; a half-written one is read next time
                c.offset += UInt64(nl - data.startIndex + 1)
                for line in data[..<nl].split(separator: 10) where line.range(of: usageMark) != nil {
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                          let ts = parseDate(o["timestamp"] as? String) else { continue }
                    c.entries.append(.init(id: msg["id"] as? String, ts: ts, n: keys.reduce(0) { $0 + ((u[$1] as? Int) ?? 0) },
                                           model: (msg["model"] as? String).flatMap { $0.hasPrefix("<") ? nil : $0 }))
                }
            }
        }
        tokenCache[url] = c
    }
    tokenCache = tokenCache.filter { live.contains($0.key) }   // forget deleted / >30d files

    var seen = Set<String>(), today = 0, month = 0, byModel: [String: Int] = [:]
    for (_, c) in tokenCache {
        for e in c.entries where e.ts > cutoff {
            if let id = e.id, !seen.insert(id).inserted { continue } // streamed msgs repeat
            month += e.n
            if let m = e.model { byModel[m, default: 0] += e.n }
            if e.ts >= dayStart { today += e.n }
        }
    }
    return (today, month, byModel.max { $0.value < $1.value }?.key ?? "–")
}

final class Model: ObservableObject {
    @Published var agents = 0
    @Published var working = 0
    @Published var limits: Usage? = UserDefaults.standard.data(forKey: "limits").flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
    var lastLimitsFetch = Date.distantPast
    @Published var tokens = (today: 0, month: 0, top: "–")
    @Published var toReview: [PR] = []
    @Published var mine: [PR] = []   // authored by me or assigned to me
    @Published var pomo = 25 * 60
    @Published var running = false
    @Published var length = 25 * 60
    @Published var done = false { didSet { if !done { alarm?.stop() } } }
    var alarm: NSSound?
    @Published var custom = 30
    var onDone: (() -> Void)?
    @Published var expanded = false

    func start() {
        refresh(); pollAgents()
        // Tolerance lets macOS batch these wakeups with others: the biggest idle-energy lever for a background app.
        for (s, f) in [(60.0, refresh), (5, pollAgents), (1, tick)] {
            Timer.scheduledTimer(withTimeInterval: s, repeats: true) { _ in f() }.tolerance = s * 0.2
        }
    }

    // open = claude processes; working = session logs (projects/<p>/<session>.jsonl) written in the last 10s
    func pollAgents() {
        work.async {
            let open = String(decoding: sh("/usr/bin/pgrep", ["-x", "claude"]), as: UTF8.self)
                .split(separator: "\n").count
            let fm = FileManager.default, root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let recent = Date().addingTimeInterval(-10)
            var working = 0
            for proj in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for url in (try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where url.pathExtension == "jsonl" {
                    if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > recent { working += 1 }
                }
            }
            DispatchQueue.main.async {   // assign only on change: every publish re-renders the whole view
                if self.agents != open { self.agents = open }
                if self.working != min(working, open) { self.working = min(working, open) }
            }
        }
    }

    var lastPRFetch = Date.distantPast
    func refresh() {
        // limits rate-limit (429) and PRs cost 3 gh processes + network: both at most every 5 min
        let askLimits = Date().timeIntervalSince(lastLimitsFetch) > 300
        if askLimits { lastLimitsFetch = Date() }
        let askPRs = Date().timeIntervalSince(lastPRFetch) > 300
        if askPRs { lastPRFetch = Date() }
        work.async {
            let limits = askLimits ? fetchLimits() : nil
            let tokens = scanTokens()
            var prs: ([PR], [PR])?
            if askPRs {
                var seen = Set<String>()
                prs = (fetchPRs("review-requested:@me"),
                       (fetchPRs("author:@me") + fetchPRs("assignee:@me")).filter { seen.insert($0.url).inserted }
                           .sorted { $0.failing && !$1.failing })   // red builds first, so they make the top 3
            }
            DispatchQueue.main.async {
                if self.tokens != tokens { self.tokens = tokens }
                if let prs { self.toReview = prs.0; self.mine = prs.1 }
                if let limits { self.limits = limits } // keep last good value on errors
            }
        }
    }

    func tick() {
        guard running else { return }
        pomo -= 1
        if pomo <= 0 {
            pauseAllMedia()
            alarm = NSSound(named: "Glass"); alarm?.loops = true; alarm?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.alarm?.stop() } // don't ring forever if away
            running = false; done = true; pomo = length
            onDone?()
        }
    }

    func startPomo(_ mins: Int) {
        length = mins * 60; pomo = length; done = false; running = true
    }

    var timerActive: Bool { running || pomo < length }
    var progress: Double { Double(pomo) / Double(length) }
    var pomoText: String { String(format: "%d:%02d", pomo / 60, pomo % 60) }
}

func short(_ n: Int) -> String {
    let d = Double(n)
    return d >= 1e9 ? String(format: "%.1fB", d / 1e9) : d >= 1e6 ? String(format: "%.1fM", d / 1e6)
         : d >= 1e3 ? String(format: "%.0fK", d / 1e3) : "\(n)"
}

// MARK: - UI  (monochrome: white on black, hierarchy by size/opacity only)

enum Tone {
    static let fg = Color.white
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.14)
}

/// Quiet, native-feeling hover: rows get a soft highlight, dim icons light up, solid controls lift slightly.
struct Press: ButtonStyle {
    enum Kind { case plain, dim, row }
    var kind = Kind.plain
    func makeBody(configuration c: Configuration) -> some View { Hoverable(c: c, kind: kind) }

    struct Hoverable: View {
        let c: Configuration, kind: Kind
        @State private var hover = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            Group {
                if kind == .dim { c.label.foregroundStyle(hover ? Tone.fg : Tone.dim) } else { c.label }
            }
            .contentShape(Rectangle())
            .background {
                if kind == .row {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)).padding(.horizontal, -6)
                }
            }
            .scaleEffect(c.isPressed ? 0.96 : kind == .plain && hover && !reduceMotion ? 1.04 : 1)
            .opacity(c.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: c.isPressed)
            .onHover { h in withAnimation(.easeOut(duration: h ? 0.15 : 0.1)) { hover = h } }   // exit faster than enter
        }
    }
}

/// Thin line that drains toward the centre (under the notch) as time runs out.
struct DrainLine: View {
    let progress: Double, active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack {
                Capsule().fill(Tone.faint)
                Capsule().fill(Tone.fg).frame(width: g.size.width * progress)
                    .opacity(active ? 1 : 0.4)
            }
            .animation(.easeOut(duration: 0.25), value: active)   // progress isn't animated: <1px/s, and animating it redrew all session
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

struct Meter: View {
    let title: String, w: Usage.Window?
    var left: Double { max(0, 100 - (w?.utilization ?? 100)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                if let r = parseDate(w?.resets_at) {
                    (Text(Image(systemName: "arrow.clockwise")) + Text(" \(r, style: .relative)"))
                        .foregroundStyle(Tone.dim).lineLimit(1).accessibilityLabel(Text("resets in \(r, style: .relative)"))
                }
                Spacer()
                Text(w == nil ? "–" : "\(Int(left))%").monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tone.faint)
                    Capsule().fill(Tone.fg).frame(width: g.size.width * left / 100)
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Stat: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Tone.dim)
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct Preset: View {
    let label: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).monospacedDigit()
                .frame(minWidth: 34).padding(.vertical, 5)
                .foregroundStyle(selected ? .black : Tone.fg)
                .background(selected ? Tone.fg : .clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : Tone.faint))
        }
        .buttonStyle(Press())
        .accessibilityLabel("\(label) minute focus")
    }
}

/// CI of a PR's last commit. Monochrome: failure is the only full-white mark, so it's the one that catches the eye.
struct CIBadge: View {
    let state: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            switch state {
            case "SUCCESS": Image(systemName: "checkmark").foregroundStyle(Tone.dim)
            case "FAILURE", "ERROR": Image(systemName: "xmark").foregroundStyle(Tone.fg).fontWeight(.bold)
            case "PENDING", "EXPECTED":
                Image(systemName: "circle.dotted").foregroundStyle(Tone.dim)
                    .symbolEffect(.rotate, options: .repeat(.periodic(delay: 4)), isActive: !reduceMotion)
            default: Color.clear
            }
        }
        .font(.system(size: 10))
        .frame(width: 12)
        .help(state.map { "CI: \($0.lowercased())" } ?? "No CI")
        .accessibilityLabel(state.map { "CI \($0.lowercased())" } ?? "No CI")
    }
}

struct PRList: View {
    static let shown = 3
    let title: String, prs: [PR], all: String
    func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title) · \(prs.count)")
                Spacer()
                if prs.count > Self.shown { Button("All \(Image(systemName: "arrow.up.right"))") { open(all) }.buttonStyle(Press(kind: .dim)) }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Tone.dim).frame(height: 14)
            if prs.isEmpty {
                Text("Nothing here").foregroundStyle(Tone.dim).frame(height: 20)
            }
            ForEach(prs.prefix(Self.shown)) { pr in
                Button { open(pr.url) } label: {
                    HStack(spacing: 8) {
                        Text(pr.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        HStack(spacing: 4) {
                            Text(pr.repository.name).lineLimit(1).truncationMode(.tail)
                            Text("#\(pr.number)").monospacedDigit().layoutPriority(1)
                            CIBadge(state: pr.ci)
                        }
                        .foregroundStyle(Tone.dim).frame(maxWidth: 150, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
                .buttonStyle(Press(kind: .row))
                .help(pr.title)
            }
        }
    }
}

struct NotchView: View {
    @ObservedObject var m: Model
    let notchHeight: CGFloat
    let onHover: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var agentsText: String {
        m.agents == 0 ? "No agents running" : "\(m.working) working · \(m.agents - m.working) idle"
    }

    var header: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .symbolEffect(.rotate, options: .repeat(.periodic(delay: 3)), isActive: m.working > 0 && !reduceMotion)   // periodic, not continuous: a nonstop spin redraws every frame
                Text("\(m.agents)").monospacedDigit()
            }
            .opacity(m.agents > 0 ? 1 : 0.4)
            .accessibilityLabel(agentsText)
            if !m.toReview.isEmpty {
                Label("\(m.toReview.count)", systemImage: "arrow.triangle.pull").monospacedDigit()
                    .padding(.leading, 8)
                    .accessibilityLabel("\(m.toReview.count) pull requests waiting for your review")
            }
            if case let failing = m.mine.filter(\.failing).count, failing > 0 {
                Label("\(failing)", systemImage: "xmark").monospacedDigit()
                    .padding(.leading, 8)
                    .accessibilityLabel("\(failing) of your pull requests failing CI")
            }
            Spacer()
            Group {
                if m.timerActive {
                    Text(m.pomoText).monospacedDigit().opacity(m.running ? 1 : 0.55)
                } else if m.done {
                    Label("Done", systemImage: "checkmark")
                } else {
                    Text(m.limits?.five_hour.map { "\(Int(100 - $0.utilization))%" } ?? "–").monospacedDigit()
                }
            }
            .contentTransition(.numericText())
        }
        .frame(height: notchHeight)
    }

    var focus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.done {
                HStack {
                    Image(systemName: "checkmark")
                    Text("Focus complete").fontWeight(.semibold)
                    Spacer()
                    Button("Dismiss") { withAnimation(.smooth(duration: 0.25)) { m.done = false } }
                        .buttonStyle(Press())
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Tone.fg, in: RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            HStack(alignment: .center) {
                Text(m.pomoText)
                    .font(.system(size: 30, weight: .light).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                Spacer()
                Button { m.running = false; m.pomo = m.length } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 32, height: 32)
                }
                .buttonStyle(Press(kind: .dim))
                .accessibilityLabel("Reset timer").help("Reset")
                Button { m.running.toggle(); m.done = false } label: {
                    Image(systemName: m.running ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Tone.fg, in: Circle())
                }
                .buttonStyle(Press())
                .accessibilityLabel(m.running ? "Pause" : "Start")
            }
            DrainLine(progress: m.progress, active: m.running)
            HStack(spacing: 6) {
                ForEach([15, 25, 45], id: \.self) { mins in
                    Preset(label: "\(mins)", selected: m.length == mins * 60) { m.startPomo(mins) }
                }
                Spacer()
                Button { m.custom = max(5, m.custom - 5) } label: { Image(systemName: "minus").frame(width: 24, height: 24) }
                    .buttonStyle(Press(kind: .dim)).accessibilityLabel("Five minutes less")
                Preset(label: "\(m.custom)", selected: m.length == m.custom * 60 && ![15, 25, 45].contains(m.custom)) {
                    m.startPomo(m.custom)
                }
                Button { m.custom = min(180, m.custom + 5) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(Press(kind: .dim)).accessibilityLabel("Five minutes more")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if m.expanded {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(agentsText).foregroundStyle(m.agents > 0 ? Tone.fg : Tone.dim)
                        Spacer()
                        Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 24, height: 24) }
                            .buttonStyle(Press(kind: .dim))
                            .accessibilityLabel("Quit Nook").help("Quit")
                    }
                    Meter(title: "Session", w: m.limits?.five_hour)
                    Meter(title: "Weekly", w: m.limits?.seven_day)
                    HStack {
                        Stat(label: "TODAY", value: short(m.tokens.today))
                        Stat(label: "30 DAYS", value: short(m.tokens.month))
                        Stat(label: "TOP MODEL", value: m.tokens.top.replacingOccurrences(of: "claude-", with: ""))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        PRList(title: "TO REVIEW", prs: m.toReview, all: "https://github.com/pulls/review-requested")
                        PRList(title: "YOURS", prs: m.mine, all: "https://github.com/pulls")
                    }
                    Rectangle().fill(Tone.faint).frame(height: 1)
                    focus
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(.horizontal, 18).padding(.bottom, m.expanded ? 18 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
        .overlay(alignment: .bottom) {   // collapsed: the whole pomodoro is one hairline
            if m.timerActive && !m.expanded {
                DrainLine(progress: m.progress, active: m.running)
                    .padding(.horizontal, 20).padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(Tone.fg)
        .font(.system(size: 12, weight: .medium))
        .onHover(perform: onHover)
    }
}

// MARK: - Window pinned to the notch

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: NSPanel!
    var runningSub: Any?
    var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main! }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let h = max(screen.safeAreaInsets.top, 32)
        panel.contentView = NSHostingView(rootView: NotchView(m: model, notchHeight: h) { [weak self] in self?.hover($0) })
        resize(false)
        panel.orderFrontRegardless()
        model.onDone = { [weak self] in   // pop the notch open so the finish is seen
            guard let self else { return }
            withAnimation(.smooth(duration: 0.3)) { self.model.expanded = true }
            self.resize(true)
        }
        runningSub = model.$running.sink { [weak self] _ in   // grow/shrink the pill for the progress line
            DispatchQueue.main.async { if let self, !self.model.expanded { self.resize(false) } }
        }
        model.start()
    }

    // Resizing the window fires spurious hover exits; trust the real mouse position instead.
    func hover(_ h: Bool) {
        let inside = h || panel.frame.contains(NSEvent.mouseLocation)
        guard inside != model.expanded else { return }
        withAnimation(.smooth(duration: inside ? 0.3 : 0.2)) { model.expanded = inside }
        resize(inside)
    }

    // fixed-height rows keep this exact: two headers + rows (1 "Nothing here" row when empty)
    var prHeight: CGFloat {
        let rows = [model.toReview, model.mine].map { CGFloat(max(1, min(PRList.shown, $0.count))) }
        return 18 + 2 * 18 + 12 + 20 * (rows[0] + rows[1])
    }

    func resize(_ expanded: Bool) {
        let s = screen
        let notchW = s.frame.width - (s.auxiliaryTopLeftArea?.width ?? 0) - (s.auxiliaryTopRightArea?.width ?? 0)
        let collapsedW = max(notchW, 180) + 110
        // expanded must fully cover the collapsed pill, or hovering its edge collapses/expands forever
        let size = expanded ? NSSize(width: max(380, collapsedW + 40), height: (model.done ? 405 : 360) + prHeight)
                            : NSSize(width: collapsedW, height: max(s.safeAreaInsets.top, 32) + (model.timerActive ? 8 : 0))
        panel.setFrame(NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true, animate: true)
    }
}

// `Nook --snapshot <dir>`: render collapsed/expanded states to PNG for design review.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--snapshot" { MainActor.assumeIsolated {
    let m = Model()
    let fake = { (n: Int, t: String) in PR(number: n, title: t, url: "u\(n)", repository: .init(name: n > 100 ? "web-app" : "design-system")) }
    let ci = { (state: String) in PR.Commits(nodes: [.init(commit: .init(statusCheckRollup: .init(state: state)))]) }
    m.toReview = [fake(137, "Add cache headers to product pages"), fake(12, "Fix mobile header overlap")]
    m.toReview[0].commits = ci("SUCCESS")
    m.mine = ["Dark mode tokens", "Button focus ring", "Docs: theming guide", "Bump deps", "Icon set v2"].enumerated().map { fake($0.offset + 40, $0.element) }
    m.mine[0].commits = ci("FAILURE"); m.mine[1].commits = ci("PENDING"); m.mine[2].commits = ci("SUCCESS")
    m.agents = 3; m.working = 1; m.pomo = 14 * 60 + 7; m.length = 25 * 60; m.running = true
    m.tokens = (today: 42_000_000, month: 1_200_000_000, top: "claude-opus-5-5")
    let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600 + 7 * 60))
    m.limits = try? JSONDecoder().decode(Usage.self, from: Data(#"{"five_hour":{"utilization":3,"resets_at":"\#(reset)"},"seven_day":{"utilization":41}}"#.utf8))
    for (name, exp, done, w, h) in [("collapsed", false, false, 320.0, 40.0), ("expanded", true, false, 380.0, 360.0 + 166), ("done", true, true, 380.0, 405.0 + 166)] {
        m.expanded = exp; m.done = done
        let r = ImageRenderer(content: NotchView(m: m, notchHeight: 32) { _ in }.frame(width: w, height: h).background(.gray).environment(\.locale, Locale(identifier: "en_US")))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("\(name).png"))
        }
    }
    exit(0)
} }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
