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

func parseDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// Undocumented endpoint Claude Code itself uses for /usage. May break without notice.
struct PR: Decodable, Identifiable {
    struct Repo: Decodable { let name: String }
    let number: Int, title: String, url: String, repository: Repo
    var id: String { url }
}

/// Open PRs via the GitHub CLI (uses its existing login). Empty if gh is missing or logged out.
func fetchPRs(_ filter: String) -> [PR] {
    guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile) else { return [] }
    let out = sh(gh, ["search", "prs", filter, "--state=open", "--json", "number,title,url,repository", "--limit", "30"])
    return (try? JSONDecoder().decode([PR].self, from: out)) ?? []
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
    URLSession.shared.dataTask(with: req) { d, _, _ in
        out = d.flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }; sem.signal()
    }.resume()
    sem.wait()
    return out
}

// ponytail: rescans all 30d of logs every refresh; cache per-file offsets if it gets slow.
func scanTokens() -> (today: Int, month: Int, top: String) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    let cutoff = Date().addingTimeInterval(-30 * 86400), dayStart = Calendar.current.startOfDay(for: Date())
    let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
    var seen = Set<String>(), today = 0, month = 0, byModel: [String: Int] = [:]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return (0, 0, "–") }
    for case let url as URL in e where url.pathExtension == "jsonl" {
        guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, mod > cutoff,
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") where line.contains("\"usage\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let ts = parseDate(o["timestamp"] as? String), ts > cutoff else { continue }
            if let id = msg["id"] as? String, !seen.insert(id).inserted { continue } // streamed msgs repeat
            let n = keys.reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
            month += n
            if let model = msg["model"] as? String, !model.hasPrefix("<") { byModel[model, default: 0] += n }
            if ts >= dayStart { today += n }
        }
    }
    return (today, month, byModel.max { $0.value < $1.value }?.key ?? "–")
}

final class Model: ObservableObject {
    @Published var agents = 0
    @Published var working = 0
    @Published var limits: Usage?
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
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refresh() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.pollAgents() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in self.tick() }
    }

    // open = claude processes; working = session logs written in the last 10s
    // ponytail: walks all log files every 3s; watch with FSEvents if it ever shows up in CPU.
    func pollAgents() {
        DispatchQueue.global().async {
            let open = String(decoding: sh("/usr/bin/pgrep", ["-x", "claude"]), as: UTF8.self)
                .split(separator: "\n").count
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let recent = Date().addingTimeInterval(-10)
            var working = 0
            for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) ?? .init()
            where url.pathExtension == "jsonl" && url.deletingLastPathComponent().lastPathComponent != "subagents" {
                if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > recent { working += 1 }
            }
            DispatchQueue.main.async { self.agents = open; self.working = min(working, open) }
        }
    }

    func refresh() {
        pollAgents()
        DispatchQueue.global().async {
            let limits = fetchLimits(), tokens = scanTokens()
            let review = fetchPRs("--review-requested=@me")
            var seen = Set<String>()
            let mine = (fetchPRs("--author=@me") + fetchPRs("--assignee=@me")).filter { seen.insert($0.url).inserted }
            DispatchQueue.main.async {
                self.tokens = tokens; self.toReview = review; self.mine = mine
                if let limits { self.limits = limits } // keep last good value on network error
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

struct Press: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        c.label.contentShape(Rectangle())
            .opacity(c.isPressed ? 0.5 : 1).scaleEffect(c.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: c.isPressed)
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
            .animation(reduceMotion ? nil : .linear(duration: 1), value: progress)
            .animation(.easeOut(duration: 0.25), value: active)
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

struct PRList: View {
    static let shown = 3
    let title: String, prs: [PR], all: String
    func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title) · \(prs.count)")
                Spacer()
                if prs.count > Self.shown { Button("All \(Image(systemName: "arrow.up.right"))") { open(all) }.buttonStyle(Press()) }
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
                        }
                        .foregroundStyle(Tone.dim).frame(maxWidth: 150, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
                .buttonStyle(Press())
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
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: m.working > 0 && !reduceMotion)
                Text("\(m.agents)").monospacedDigit()
            }
            .opacity(m.agents > 0 ? 1 : 0.4)
            .accessibilityLabel(agentsText)
            if !m.toReview.isEmpty {
                Label("\(m.toReview.count)", systemImage: "arrow.triangle.pull").monospacedDigit()
                    .padding(.leading, 8)
                    .accessibilityLabel("\(m.toReview.count) pull requests waiting for your review")
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
                .buttonStyle(Press()).foregroundStyle(Tone.dim)
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
                    .buttonStyle(Press()).foregroundStyle(Tone.dim).accessibilityLabel("Five minutes less")
                Preset(label: "\(m.custom)", selected: m.length == m.custom * 60 && ![15, 25, 45].contains(m.custom)) {
                    m.startPomo(m.custom)
                }
                Button { m.custom = min(180, m.custom + 5) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(Press()).foregroundStyle(Tone.dim).accessibilityLabel("Five minutes more")
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
                            .buttonStyle(Press()).foregroundStyle(Tone.dim)
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
    m.toReview = [fake(137, "Add cache headers to product pages"), fake(12, "Fix mobile header overlap")]
    m.mine = ["Dark mode tokens", "Button focus ring", "Docs: theming guide", "Bump deps", "Icon set v2"].enumerated().map { fake($0.offset + 40, $0.element) }
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
