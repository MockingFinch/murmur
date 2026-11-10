import AppKit
import MurmurCore
import SwiftUI

/// `Murmur --film <dir> [--only name]` records the README's demos: the real
/// capsule on a made-up desktop, driven by a script, captured offscreen in
/// real time so every animation runs at its own speed. Each frame is a PNG;
/// `frames.txt` holds their timings for ffmpeg. A development aid.
@MainActor
enum Films {
    static let size = NSSize(width: 960, height: 540)

    static func run(into dir: URL, only: String?) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        SoftShadow.prerendered = true
        if ProcessInfo.processInfo.environment["FILM_PROFILE"] != nil { return profile() }
        for film in all where only.map({ film.name.contains($0) }) ?? true {
            record(film, into: dir.appendingPathComponent(film.name, isDirectory: true))
        }
    }

    // MARK: Recording

    private static func record(_ film: Film, into dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stage = Stage()
        let hud = HUDModel()
        let view = FilmScene(stage: stage, hud: hud, window: film.window)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let writes = DispatchGroup()
        var timings: [(String, Double)] = []
        var done = Set<Int>()
        let start = Date()
        var t = 0.0
        while t < film.duration {
            t = Date().timeIntervalSince(start)
            for (i, cue) in film.cues.enumerated() where !done.contains(i) && cue.at <= t {
                done.insert(i)
                cue.run(stage, hud)
            }
            for span in film.spans where t >= span.from && t <= span.to + 0.1 {
                span.run(min(1, max(0, (t - span.from) / max(0.001, span.to - span.from))), t, stage, hud)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = String(format: "f%05d.png", timings.count)
            timings.append((name, t))
            let box = RepBox(rep: rep, url: dir.appendingPathComponent(name))
            DispatchQueue.global(qos: .userInitiated).async(group: writes) { box.write() }
        }
        writes.wait()
        window.orderOut(nil)

        var list = ""
        for (i, (name, time)) in timings.enumerated() {
            let next = i + 1 < timings.count ? timings[i + 1].1 : film.duration
            list += "file '\(name)'\nduration \(String(format: "%.4f", max(0.001, next - time)))\n"
        }
        if let last = timings.last { list += "file '\(last.0)'\n" }
        try? list.write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        print("\(film.name): \(timings.count) frames in \(String(format: "%.1f", film.duration)) s")
    }

    private static func profile() {
        let stage = Stage()
        let hud = HUDModel()
        hud.startListening()
        hud.liveText = "Um, so for next week, uh, I think we should ship the first draft by Wednesday"
        let variants: [(String, AnyView)] = [
            ("full", AnyView(FilmScene(stage: stage, hud: hud, window: .mail))),
            ("wallpaper", AnyView(FilmWallpaper().frame(width: size.width, height: size.height))),
            ("window", AnyView(MailWindow(stage: stage).frame(width: size.width, height: size.height))),
            ("hud", AnyView(HUDView(model: hud, snapshot: true).frame(width: size.width, height: size.height))),
            ("plain", AnyView(Color.white.frame(width: size.width, height: size.height))),
        ]
        for (name, view) in variants {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            for scale in [2.0, 1.0] {
                let start = Date()
                for _ in 0 ..< 10 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
                print("\(name) @\(Int(scale))x: \(Int(Date().timeIntervalSince(start) * 100)) ms per frame")
            }
            window.orderOut(nil)
        }
    }

    private final class RepBox: @unchecked Sendable {
        let rep: NSBitmapImageRep
        let url: URL
        init(rep: NSBitmapImageRep, url: URL) { self.rep = rep; self.url = url }
        func write() { try? rep.representation(using: .png, properties: [:])?.write(to: url) }
    }

    // MARK: The films

    static var all: [Film] { [dictate, translate, rewrite, offline] }

    /// Talk, and it's written: fillers out, punctuation in, where you type.
    static var dictate: Film {
        let heard = "Um, so for next week, uh, I think we should ship the first draft by Wednesday, then have the design team review it on Thursday, and, you know, spend Friday polishing onboarding before it goes to QA."
        let polished = "Next week: ship the first draft by Wednesday, have the design team review it on Thursday, and spend Friday polishing onboarding before it goes to QA."
        var f = Film(name: "dictate", duration: 12.6, window: .mail)
        f.caption(0.2, "Press ⌃X anywhere you type")
        f.press(0.9, ["⌃", "X"]) { s, h in s.murmurActive = true; h.startListening() }
        f.caption(1.6, "Just talk. Your words appear as you speak")
        f.speak(from: 1.2, to: 7.0, heard)
        f.press(7.5, ["⌃", "X"]) { s, h in s.murmurActive = false; h.show(.transcribing(retry: 0)) }
        f.caption(7.9, "Murmur cleans it up: no ums, no rambling")
        f.answer(at: 8.1, job: .polish, input: heard, output: polished, streamFor: 1.6)
        f.insert(at: 10.0, polished, done: "Inserted and copied")
        f.caption(10.0, "…and it's in, right where your cursor was")
        f.reset(at: 12.1)
        return f
    }

    /// Speak Chinese, send English.
    static var translate: Film {
        let heard = "可以的，周四我有空，不过能不能把电话改到四点？我三点半之前还有一个会。"
        let polished = "可以的，周四我有空，不过能否把电话改到 4 点？我 3 点半之前还有一个会。"
        let english = "Sure, I'm free on Thursday, but could we move the call to 4:00? I have another meeting until 3:30."
        var f = Film(name: "translate", duration: 13.0, window: .chat)
        f.caption(0.2, "Press ⌃⌘X to dictate and translate")
        f.press(0.9, ["⌃", "⌘", "X"]) { s, h in s.murmurActive = true; h.startListening(translatingTo: "English") }
        f.caption(1.6, "Speak Chinese…")
        f.speak(from: 1.2, to: 6.4, heard)
        f.press(6.9, ["⌃", "⌘", "X"]) { s, h in s.murmurActive = false; h.show(.transcribing(retry: 0)) }
        f.answer(at: 7.4, job: .polish, input: heard, output: polished, streamFor: 0.9)
        f.caption(8.6, "…and send it in English")
        f.answer(at: 8.6, job: .translate("English"), input: polished, output: english, streamFor: 1.5)
        f.insert(at: 10.4, english, done: "Translated, inserted and copied")
        f.reset(at: 12.5)
        return f
    }

    /// Select, press, rewritten in place.
    static var rewrite: Film {
        let rough = "so basically signups went down mostly because the new form is way too long and people just give up halfway"
        let refined = "Signups fell mainly because the new form is too long, so people abandon it halfway through."
        var f = Film(name: "rewrite", duration: 9.4, window: .doc)
        f.cue(0.0) { s, _ in s.selected = rough }
        f.caption(0.2, "Select any text")
        f.caption(1.3, "Press ⌃X to rewrite it with your prompt")
        f.press(1.5, ["⌃", "X"]) { _, h in
            h.reset()
            h.preview = rough
            h.show(.model(.refine, retry: 0, thinking: false))
        }
        f.spans.append(Span(from: 2.4, to: 4.0) { p, _, _, h in h.liveText = Film.prefix(refined, p) })
        f.cue(4.3) { s, h in
            withAnimation(.easeOut(duration: 0.25)) { s.selected = nil; s.inserted = refined; s.flash = true }
            h.finish(.done("Replaced and copied"))
        }
        f.caption(4.3, "Replaced, right in place")
        f.cue(5.6) { s, _ in withAnimation(.easeOut(duration: 1.2)) { s.flash = false } }
        f.reset(at: 8.9)
        return f
    }

    /// The network drops mid-sentence; nothing said is lost.
    static var offline: Film {
        let words = "Quick update from the client call. So they loved the new dashboard, but they want the export button moved to the top, and they asked whether we can support CSV and PDF by the end of the month."
        let polished = "Quick update from the client call: they loved the new dashboard, but want the export button moved to the top, and asked whether we can support CSV and PDF exports by the end of the month."
        var f = Film(name: "offline", duration: 14.6, window: .notes)
        f.caption(0.2, "Dictating a long note…")
        f.press(0.8, ["⌃", "X"]) { s, h in s.murmurActive = true; h.startListening() }
        // Spoken from 1.1 to 9.0; Doubao is unreachable from 3.6 to 6.4.
        f.level(from: 1.1, to: 9.0)
        let cut = 0.34, caughtUp = 0.62
        f.spans.append(Span(from: 1.1, to: 3.6) { p, _, _, h in h.liveText = Film.prefix(words, p * cut) })
        f.cue(3.6) { s, h in withAnimation(.snappy) { s.wifiOff = true }; h.link = .reconnecting }
        f.caption(3.7, "Wi-Fi drops? Keep talking")
        f.cue(6.4) { s, h in withAnimation(.snappy) { s.wifiOff = false }; h.link = .live }
        f.caption(6.5, "Murmur reconnects and catches up")
        // Back online: what was said meanwhile arrives at once, then live again.
        f.spans.append(Span(from: 6.5, to: 7.1) { p, _, _, h in h.liveText = Film.prefix(words, cut + (caughtUp - cut) * p) })
        f.spans.append(Span(from: 7.1, to: 9.0) { p, _, _, h in h.liveText = Film.prefix(words, caughtUp + (1 - caughtUp) * p) })
        f.press(9.4, ["⌃", "X"]) { s, h in s.murmurActive = false; h.show(.transcribing(retry: 0)) }
        f.answer(at: 9.9, job: .polish, input: words, output: polished, streamFor: 1.4)
        f.insert(at: 11.6, polished, done: "Inserted and copied")
        f.caption(11.6, "Every word makes it in")
        f.reset(at: 14.1)
        return f
    }
}

// MARK: - Scripts

struct FilmCue {
    let at: Double
    let run: @MainActor (Stage, HUDModel) -> Void
}

/// Runs every frame from `from` to `to`, with progress 0...1.
struct Span {
    let from: Double
    let to: Double
    let run: @MainActor (Double, Double, Stage, HUDModel) -> Void
}

@MainActor
struct Film {
    let name: String
    let duration: Double
    let window: MockWindow
    var cues: [FilmCue] = []
    var spans: [Span] = []

    init(name: String, duration: Double, window: MockWindow) {
        self.name = name
        self.duration = duration
        self.window = window
    }

    mutating func cue(_ at: Double, _ run: @escaping @MainActor (Stage, HUDModel) -> Void) {
        cues.append(FilmCue(at: at, run: run))
    }

    mutating func caption(_ at: Double, _ text: String) {
        cue(at) { s, _ in withAnimation(.smooth(duration: 0.45)) { s.caption = text } }
    }

    /// A shortcut pressed: shown as key caps, then `then`.
    mutating func press(_ at: Double, _ keys: [String], then: @escaping @MainActor (Stage, HUDModel) -> Void) {
        cue(at) { s, _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { s.keys = keys; s.keysDown = true }
        }
        cue(at + 0.16) { s, h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { s.keysDown = false }
            then(s, h)
        }
        cue(at + 1.2) { s, _ in withAnimation(.easeOut(duration: 0.3)) { s.keys = [] } }
    }

    /// A voice: loudness for the waveform.
    mutating func level(from: Double, to: Double) {
        spans.append(Span(from: from, to: to) { p, t, _, h in
            let syllables = pow(abs(sin(t * 11.3)), 0.7)
            let phrase = 0.55 + 0.45 * sin(t * 1.9 + 0.6)
            h.level = p >= 1 ? 0 : Float(0.12 + 0.72 * syllables * max(0.15, phrase))
        })
    }

    /// Speech, heard a few words at a time as Doubao's partial results come in.
    mutating func speak(from: Double, to: Double, _ text: String) {
        level(from: from, to: to)
        spans.append(Span(from: from + 0.35, to: to) { p, _, _, h in h.liveText = Film.prefix(text, p) })
    }

    /// The model at work on `input`, its answer streaming in.
    mutating func answer(at: Double, job: HUDModel.Job, input: String, output: String, streamFor: Double) {
        cue(at) { _, h in
            h.preview = input
            h.liveText = ""
            h.show(.model(job, retry: 0, thinking: false))
        }
        spans.append(Span(from: at + 0.5, to: at + 0.5 + streamFor) { p, _, _, h in h.liveText = Film.prefix(output, p) })
    }

    /// The text lands in the window, and the capsule says so.
    mutating func insert(at: Double, _ text: String, done: String) {
        cue(at) { s, h in
            withAnimation(.easeOut(duration: 0.2)) { s.inserted = text; s.flash = true }
            h.finish(.done(done))
        }
        cue(at + 1.3) { s, _ in withAnimation(.easeOut(duration: 1.2)) { s.flash = false } }
    }

    /// Back to where it started, so the loop is seamless.
    mutating func reset(at: Double) {
        cue(at) { s, h in
            withAnimation(.easeInOut(duration: 0.45)) { s.inserted = nil; s.selected = nil; s.caption = nil }
            h.hide()
        }
    }

    /// The first `p` of `text`, as recognition delivers it: Chinese a few
    /// characters at a time, other text a word at a time.
    static func prefix(_ text: String, _ p: Double) -> String {
        let p = min(1, max(0, p))
        if text.unicodeScalars.contains(where: { (0x4E00 ... 0x9FFF).contains($0.value) }) {
            let chars = Array(text)
            var n = Int(Double(chars.count) * p)
            if n < chars.count { n -= n % 3 }
            return String(chars.prefix(n))
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let n = Int((Double(words.count) * p).rounded(.down))
        return words.prefix(n).joined(separator: " ")
    }
}

// MARK: - The stage

@MainActor @Observable
final class Stage {
    var caption: String?
    var keys: [String] = []
    var keysDown = false
    var murmurActive = false
    var wifiOff = false
    /// Text Murmur put in the window.
    var inserted: String?
    /// Text selected in the window.
    var selected: String?
    /// The inserted text is highlighted for a moment.
    var flash = false
}

enum MockWindow { case mail, chat, doc, notes }

private struct FilmScene: View {
    let stage: Stage
    let hud: HUDModel
    let window: MockWindow

    var body: some View {
        ZStack(alignment: .top) {
            FilmWallpaper()
            VStack(spacing: 0) {
                MenuBar(stage: stage)
                Spacer(minLength: 0)
            }
            Group {
                switch window {
                case .mail: MailWindow(stage: stage)
                case .chat: ChatWindow(stage: stage)
                case .doc: DocWindow(stage: stage)
                case .notes: NotesWindow(stage: stage)
                }
            }
            .padding(.top, 70)
            Caption(text: stage.caption)
                .padding(.top, 36)
            KeyStrokes(stage: stage)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 38)
                .padding(.trailing, 26)
            HUDView(model: hud, snapshot: true)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: 12)
        }
        .frame(width: Films.size.width, height: Films.size.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

struct FilmWallpaper: View {
    /// Rendered once: a mesh gradient is slow to draw offscreen every frame.
    @MainActor private static let image: NSImage = {
        let r = ImageRenderer(content: Mesh().frame(width: Films.size.width, height: Films.size.height))
        r.scale = 2
        return r.nsImage ?? NSImage()
    }()

    var body: some View { Image(nsImage: Self.image).resizable() }
}

private struct Mesh: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.55, 0], [1, 0],
            [0, 0.5], [0.42, 0.56], [1, 0.45],
            [0, 1], [0.6, 1], [1, 1],
        ], colors: [
            Color(hex: 0x9DB4F2), Color(hex: 0xC9B8F5), Color(hex: 0xF0C6E2),
            Color(hex: 0xB7C9F7), Color(hex: 0xD9CCF4), Color(hex: 0xF6D3C8),
            Color(hex: 0x8FC7E8), Color(hex: 0xC3D7F3), Color(hex: 0xF4DCC4),
        ])
    }
}

private struct MenuBar: View {
    let stage: Stage

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 12, weight: .semibold))
            Text("File")
            Text("Edit")
            Text("View")
            Spacer()
            Image(nsImage: StatusIcon.image(active: stage.murmurActive))
                .renderingMode(stage.murmurActive ? .original : .template)
                .frame(width: 18, height: 18)
            Image(systemName: stage.wifiOff ? "wifi.slash" : "wifi")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(stage.wifiOff ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            Image(systemName: "battery.75percent").font(.system(size: 14))
            Text("9:41")
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.black.opacity(0.82))
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(.white.opacity(0.32))
    }
}

/// What the film is showing, at the top of the screen.
private struct Caption: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.62)))
                    .modifier(SoftShadow(cornerRadius: 16, opacity: 0.14, radius: 10, y: 4))
                    .id(text)
                    .transition(.blurReplace.combined(with: .scale(0.96)))
            }
        }
    }
}

/// The keys pressed, as a screencast shows them.
private struct KeyStrokes: View {
    let stage: Stage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(stage.keys.enumerated()), id: \.offset) { _, key in
                KeyCap(label: key, size: 34)
                    .modifier(SoftShadow(cornerRadius: 8, opacity: 0.12, radius: 8, y: 4))
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .scaleEffect(stage.keysDown ? 0.9 : 1)
        .offset(y: stage.keysDown ? 2 : 0)
    }
}

// MARK: - Windows

private struct WindowFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 600
    var height: CGFloat = 330
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5F57))
                    Circle().fill(Color(hex: 0xFEBC2E))
                    Circle().fill(Color(hex: 0x28C840))
                    Spacer()
                }
                .frame(height: 12)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Divider().opacity(0.6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        .modifier(SoftShadow(cornerRadius: 14, opacity: 0.16, radius: 30, y: 16))
    }
}

/// Blinks where text would go.
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle().fill(Color(hex: 0x2F7BF5)).frame(width: 2, height: 18).opacity(on ? 1 : 0)
        }
    }
}

private let bodyFont = Font.system(size: 15)
private let flashColor = Color(hex: 0x30C48D).opacity(0.22)

/// Inserted text, highlighted for a moment.
private struct Inserted: View {
    let stage: Stage
    var caretAfter = true

    var body: some View {
        if let text = stage.inserted {
            Text(text)
                .font(bodyFont)
                .foregroundStyle(.black.opacity(0.86))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(stage.flash ? flashColor : .clear))
                .transition(.opacity)
        } else if caretAfter {
            Caret()
        }
    }
}

private struct MailWindow: View {
    let stage: Stage

    var body: some View {
        WindowFrame(title: "New Message") {
            VStack(alignment: .leading, spacing: 0) {
                field("To:", "Product Team")
                field("Subject:", "Plan for next week")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hi all,").font(bodyFont).foregroundStyle(.black.opacity(0.86))
                    Inserted(stage: stage)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(label).foregroundStyle(.black.opacity(0.42))
                Text(value).foregroundStyle(.black.opacity(0.85))
                Spacer()
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 20)
            .frame(height: 34)
            Divider().opacity(0.5).padding(.leading, 20)
        }
    }
}

private struct ChatWindow: View {
    let stage: Stage

    var body: some View {
        WindowFrame(title: "Emma Wilson", height: 340) {
            VStack(alignment: .leading, spacing: 8) {
                bubble("Hi! Are you free for a quick call on Thursday at 3?", mine: false)
                bubble("I can send the agenda beforehand.", mine: false)
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    Group {
                        if let text = stage.inserted {
                            Text(text)
                                .font(.system(size: 14))
                                .foregroundStyle(.black.opacity(0.86))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 3)
                                .background(RoundedRectangle(cornerRadius: 4).fill(stage.flash ? flashColor : .clear))
                                .transition(.opacity)
                        } else {
                            HStack(spacing: 2) {
                                Caret()
                                Text("Message").font(.system(size: 14)).foregroundStyle(.black.opacity(0.3))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.black.opacity(0.14)))
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(stage.inserted == nil ? Color.black.opacity(0.15) : Color(hex: 0x2F7BF5))
                }
            }
            .padding(16)
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(mine ? .white : .black.opacity(0.86))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(mine ? Color(hex: 0x2F7BF5) : Color(white: 0.92)))
    }
}

private struct DocWindow: View {
    let stage: Stage

    var body: some View {
        WindowFrame(title: "Q3 Review", height: 320) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Why signups dropped")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                Text("We changed the signup flow on August 4. Within two weeks, completed signups fell by 18%.")
                    .font(bodyFont)
                    .foregroundStyle(.black.opacity(0.8))
                    .lineSpacing(3)
                Group {
                    if let selected = stage.selected {
                        Text(selected)
                            .font(bodyFont)
                            .foregroundStyle(.black.opacity(0.86))
                            .lineSpacing(3)
                            .background(Color(hex: 0xB3D7FF))
                            .transition(.opacity)
                    } else {
                        Inserted(stage: stage, caretAfter: false)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
        }
    }
}

private struct NotesWindow: View {
    let stage: Stage

    var body: some View {
        WindowFrame(title: "Client Notes", height: 320) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Acme Weekly Call")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                Text("Tuesday, 10:30")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.4))
                Inserted(stage: stage)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
        }
    }
}
