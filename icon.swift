// Renders AppIcon.icns: `swift icon.swift` (re-run only if the icon design changes).
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: 824pt tile inside a 1024 canvas
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 4))
                .frame(width: 824, height: 824)
            // the notch
            UnevenRoundedRectangle(bottomLeadingRadius: 44, bottomTrailingRadius: 44)
                .fill(.black)
                .frame(width: 360, height: 96)
                .offset(y: -364)
            Image(systemName: "sparkle")
                .font(.system(size: 330, weight: .regular))
                .foregroundStyle(.white)
                .offset(y: 10)
            // the drain line
            Capsule().fill(.white.opacity(0.18)).frame(width: 440, height: 14).offset(y: 270)
            Capsule().fill(.white).frame(width: 260, height: 14).offset(y: 270)
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let dir = URL(fileURLWithPath: "AppIcon.iconset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let r = ImageRenderer(content: Icon())
            r.scale = CGFloat(size * scale) / 1024
            guard let cg = r.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try? png.write(to: dir.appendingPathComponent(name))
        }
    }
}
