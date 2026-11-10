import AppKit
import MurmurCore
import SwiftUI

/// Draws every state of the interface to PNG files, offscreen.
@MainActor
enum Snapshots {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        UsageStore.shared.preview(sampleRecords())

        let hudStates: [(String, (HUDModel) -> Void)] = [
            ("listening", { m in m.startListening(); m.level = 0.7 }),
            ("listening-live", { m in
                m.startListening(); m.level = 0.45
                m.liveText = "我觉得这个方案其实还可以，就是时间上可能有点紧"
            }),
            ("listening-one-line", { m in
                m.startListening(); m.level = 0.5
                m.liveText = "Besides that, you can see."
            }),
            ("listening-two-lines", { m in
                m.startListening(); m.level = 0.5
                m.liveText = "Besides that, you can see that when the content only has one line, the capsule should hug it instead of leaving room."
            }),
            ("listening-long", { m in
                m.startListening(); m.level = 0.55
                m.liveText = "下周的安排是这样的：周三之前先把初版发出来，周四请设计团队一起过一遍，收集大家的意见，周五集中把新手引导的流程打磨好，然后交给测试同学做一轮完整的回归。"
            }),
            ("listening-long-en", { m in
                m.startListening(); m.level = 0.3
                m.liveText = "So the plan for next week is to ship the first draft on Wednesday, collect feedback from the design team on Thursday, and then spend Friday polishing the onboarding flow before we hand it over to QA for a full regression pass."
            }),
            ("transcribing", { m in m.show(.transcribing(retry: 0)) }),
            ("reconnecting", { m in m.show(.transcribing(retry: 1)) }),
            ("polishing", { m in m.preview = "嗯那个我觉得这个方案呢其实还可以"; m.show(.model(.polish, retry: 0, thinking: false)) }),
            ("polishing-long", { m in
                m.show(.model(.polish, retry: 0, thinking: false))
                m.liveText = "下周安排：周三前发出初版；周四请设计团队评审并收集意见；周五打磨新手引导流程，之后交给测试做完整回归。"
                m.waitingSince = Date().addingTimeInterval(-9)
            }),
            ("thinking", { m in m.show(.model(.polish, retry: 0, thinking: true)) }),
            ("retrying", { m in m.show(.model(.polish, retry: 2, thinking: false)); m.waitingSince = Date().addingTimeInterval(-47) }),
            ("listening-translate", { m in m.startListening(translatingTo: "Simplified Chinese"); m.level = 0.6 }),
            ("translating", { m in
                m.preview = "So the plan for next week is to ship the first draft on Wednesday."
                m.show(.model(.translate("Japanese"), retry: 0, thinking: false))
                m.liveText = "来週の予定としては、水曜日に"
            }),
            ("translating-selection", { m in
                m.preview = "我觉得这个方案其实还可以，就是时间上可能有点紧。"
                m.show(.model(.translate("English"), retry: 0, thinking: false))
            }),
            ("done-translated", { m in m.show(.done("Translated, inserted and copied")) }),
            ("refining", { m in m.show(.model(.refine, retry: 0, thinking: false)) }),
            ("done", { m in m.show(.done("Inserted and copied")) }),
            ("notice-warning", { m in m.show(.notice(.init(tone: .warning, title: "Inserted without polishing", detail: "No complete answer within 180 seconds."))) }),
            ("notice-error", { m in m.show(.notice(.init(tone: .error, title: "Couldn't transcribe", detail: "Doubao didn't accept the key."))) }),
            ("notice-info", { m in m.show(.notice(.init(tone: .info, title: "No speech detected", detail: nil))) }),
            ("cancelled", { m in m.show(.cancelled) }),
        ]
        let only = CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1] }
        for (name, setUp) in hudStates where only.map({ "hud-\(name)".contains($0) }) ?? true {
            let model = HUDModel()
            setUp(model)
            let view = ZStack {
                LinearGradient(colors: [Color(hex: 0x9FB6D6), Color(hex: 0xE8D9C9)], startPoint: .top, endPoint: .bottom)
                HUDView(model: model, snapshot: true)
            }
            render(view, size: HUDView.canvas, dark: true, to: dir.appendingPathComponent("hud-\(name).png"))
        }

        for page in Page.allCases where only.map({ "page-\(page.rawValue)".contains($0) }) ?? true {
            for dark in [false, true] {
                let navigator = Navigator()
                navigator.page = page
                let view = RootView().environment(navigator).background(Color(nsColor: .windowBackgroundColor))
                render(view, size: NSSize(width: 920, height: 1100), dark: dark,
                       to: dir.appendingPathComponent("page-\(page.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// One window, pages switched the way the sidebar rows switch them: each
    /// switch must redraw the detail side. Returns false if one doesn't.
    static func checkNavigation() -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let navigator = Navigator()
        let size = NSSize(width: 920, height: 680)
        let host = NSHostingView(rootView: RootView().environment(navigator))
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()

        func detailPixels() -> Data {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            // The right-hand side only: the sidebar's highlight doesn't count.
            let detail = NSRect(x: 300, y: 0, width: size.width - 300, height: size.height)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: detail) else { return Data() }
            host.cacheDisplay(in: detail, to: rep)
            return rep.tiffRepresentation ?? Data()
        }

        // Rows set the page directly; offscreen windows get no clicks, so
        // set it the same way and check the right side follows.
        var ok = true
        var previous = detailPixels()
        for page in [Page.speech, .polish, .shortcut, .overview] {
            navigator.page = page
            let now = detailPixels()
            let changed = now != previous
            print("→ \(page.rawValue): detail \(changed ? "redrawn" : "UNCHANGED")")
            ok = ok && changed
            previous = now
        }
        window.orderOut(nil)
        return ok
    }

    private static func render(_ view: some View, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
        window.orderOut(nil)
        print("wrote \(url.lastPathComponent)")
    }

    private static func sampleRecords() -> [UsageRecord] {
        var list: [UsageRecord] = []
        let cal = Calendar.current
        let pattern = [3, 0, 5, 8, 2, 6, 9, 4, 0, 7, 11, 6, 8, 5]
        for (back, uses) in pattern.reversed().enumerated() {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            for n in 0..<uses {
                let text = String(repeating: "我们下周三之前先出一个初版，", count: 2 + n % 4)
                list.append(UsageRecord(date: day.addingTimeInterval(Double(-n * 600)), kind: n % 5 == 0 ? .refine : .dictation,
                                        audioSeconds: n % 5 == 0 ? 0 : Double(8 + n * 3), text: text,
                                        polish: n % 9 == 4 ? .fallback : .polished, waitSeconds: 0.9 + Double(n % 3) * 0.4, attempts: 1))
            }
        }
        return list
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
