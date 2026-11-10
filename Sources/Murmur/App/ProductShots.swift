import AppKit
import MurmurCore
import SwiftUI

/// `Murmur --product-shots <dir>` draws the README's still pictures: the
/// settings window as a set-up user sees it, on the demos' wallpaper, in
/// light and dark, and the capsule's states side by side. A development aid.
@MainActor
enum ProductShots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        SoftShadow.prerendered = false
        UsageStore.shared.preview(sampleRecords())

        for page in [Page.overview, .polish, .translate, .speech] {
            for dark in [false, true] {
                let navigator = Navigator()
                navigator.page = page
                let view = WindowShot(dark: dark) { RootView().environment(navigator) }
                render(view, size: ProductShots.windowCanvas, dark: dark,
                       to: dir.appendingPathComponent("window-\(page.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        render(CapsuleGallery(), size: CapsuleGallery.canvas, dark: false, to: dir.appendingPathComponent("capsule.png"))
    }

    static let windowCanvas = NSSize(width: 1040, height: 760)
    static let windowSize = CGSize(width: 920, height: 640)

    static func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        window.orderOut(nil)
        print("wrote \(url.lastPathComponent)")
    }

    /// Two weeks of steady use, translations included.
    private static func sampleRecords() -> [UsageRecord] {
        var list: [UsageRecord] = []
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let pattern = [6, 0, 9, 12, 4, 10, 14, 7, 0, 11, 16, 9, 13, 12]
        for (back, uses) in pattern.reversed().enumerated() {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            for n in 0 ..< uses {
                let words = 18 + (n * 7) % 40
                let text = String(repeating: "word ", count: words)
                let kind: UsageRecord.Kind = n % 6 == 5 ? .refine : .dictation
                list.append(UsageRecord(date: day.addingTimeInterval(Double(9 * 3600 + n * 1700)), kind: kind,
                                        audioSeconds: kind == .refine ? 0 : Double(words) / 2.6, text: text,
                                        polish: n % 11 == 4 ? .fallback : .polished, waitSeconds: 0.8 + Double(n % 4) * 0.3,
                                        attempts: 1, translated: n % 4 == 1))
            }
        }
        return list
    }
}

// MARK: - The settings window

/// The settings window as it sits on screen: title bar, traffic lights,
/// rounded corners and shadow, over the wallpaper.
private struct WindowShot<Content: View>: View {
    let dark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            FilmWallpaper()
            VStack(spacing: 0) {
                // The title bar: the sidebar's column and the page's, carried up.
                HStack(spacing: 0) {
                    Color(white: dark ? 0.102 : 0.98).frame(width: 190)
                    Color(white: dark ? 0.06 : 0.76).frame(width: 1)
                    Color(white: dark ? 0.11 : 1)
                }
                .frame(height: 38)
                .overlay(alignment: .leading) { TrafficLights().padding(.leading, 18) }
                content
            }
                .frame(width: ProductShots.windowSize.width, height: ProductShots.windowSize.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.22), radius: 34, y: 18)
        }
        .frame(width: ProductShots.windowCanvas.width, height: ProductShots.windowCanvas.height)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                Circle()
                    .fill(Color(hex: UInt32(hex)))
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

// MARK: - The capsule

/// The capsule's moments, side by side.
private struct CapsuleGallery: View {
    static var canvas: NSSize { NSSize(width: 1040, height: 500) }

    private static func model(_ setUp: (HUDModel) -> Void) -> HUDModel {
        let m = HUDModel()
        setUp(m)
        return m
    }

    private let states: [(String, HUDModel)] = [
        ("Listening", model { m in
            m.startListening(); m.level = 0.55
            m.liveText = "Um, so for next week, I think we should ship the first draft by Wednesday"
        }),
        ("Dictate and translate", model { m in
            m.startListening(translatingTo: "English"); m.level = 0.45
            m.liveText = "可以的，周四我有空，不过能不能把电话改到四点？"
        }),
        ("Polishing", model { m in
            m.show(.model(.polish, retry: 0, thinking: false))
            m.liveText = "Next week: ship the first draft by Wednesday, have the design team review it on Thursday."
            m.waitingSince = Date().addingTimeInterval(-2)
        }),
        ("Translating", model { m in
            m.show(.model(.translate("English"), retry: 0, thinking: false))
            m.liveText = "Sure, I'm free on Thursday, but could we move the call to 4:00?"
        }),
        ("Connection lost, still recording", model { m in
            m.startListening(); m.level = 0.5; m.link = .reconnecting
            m.liveText = "Quick update from the client call. They loved the new dashboard,"
        }),
        ("Done", model { m in m.show(.done("Inserted and copied")) }),
    ]

    var body: some View {
        ZStack {
            FilmWallpaper()
            Grid(horizontalSpacing: 8, verticalSpacing: 22) {
                ForEach(0 ..< 3, id: \.self) { row in
                    GridRow {
                        ForEach(0 ..< 2, id: \.self) { column in
                            let (title, model) = states[row * 2 + column]
                            VStack(spacing: -12) {
                                HUDView(model: model, snapshot: true)
                                    .frame(width: HUDView.canvas.width, height: HUDView.canvas.height)
                                    .scaleEffect(0.74)
                                    .frame(width: HUDView.canvas.width * 0.74, height: HUDView.canvas.height * 0.74)
                                    // Only the bottom holds the capsule; the shadow may spill over.
                                    .frame(width: HUDView.canvas.width * 0.74, height: 112, alignment: .bottom)
                                Text(title)
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.black.opacity(0.55))
                            }
                        }
                    }
                }
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
    }
}
