import MurmurCore
import SwiftUI

struct SpeechPage: View {
    @Bindable private var settings = AppSettings.shared
    @State private var check: CheckState = .idle
    @State private var devices: [AudioInputDevice] = []
    @State private var micTester = MicTester()

    var body: some View {
        PageHeader(symbol: "waveform", gradient: Brand.voice, title: "Speech",
                   subtitle: "Doubao's streaming recognition, from Volcengine. Murmur waits for its final pass before anything is inserted.")

        PageSection(title: "Credentials", trailing: AnyView(LinkLabel(title: "Volcengine console", url: "https://console.volcengine.com/speech/app"))) {
            Card {
                SettingRow(title: "Console", detail: settings.doubaoAuth == .apiKey
                           ? "The new console gives one API key."
                           : "The classic console gives an App ID and an Access Token.") {
                    Picker("", selection: $settings.doubaoAuth) {
                        Text("API Key").tag(DoubaoAuth.apiKey)
                        Text("App ID + Token").tag(DoubaoAuth.classic)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 10) {
                    if settings.doubaoAuth == .classic {
                        FieldLabel("App ID")
                        PlainField(placeholder: "e.g. 1234567890", text: $settings.doubaoAppID, monospaced: true)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    FieldLabel(settings.doubaoAuth == .apiKey ? "API Key" : "Access Token")
                    SecretField(placeholder: settings.doubaoAuth == .apiKey ? "Paste your API key" : "Paste your access token",
                                text: $settings.doubaoKey)
                    Text("Saved on this Mac, readable only by your account.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    CheckButton(title: "Test Connection", state: check, disabled: !settings.speechReady) { test() }
                        .padding(.top, 4)
                }
                .animation(Motion.smooth, value: settings.doubaoAuth)
            }
        }

        PageSection(title: "Billing") {
            Card(padding: 6) {
                ForEach(Array(DoubaoAPI.resources.enumerated()), id: \.element.id) { index, resource in
                    if index > 0 { RowDivider().padding(.vertical, -6).padding(.leading, 40) }
                    ResourceRow(resource: resource, selected: settings.doubaoResource == resource.id) {
                        settings.doubaoResource = resource.id
                    }
                }
            }
            Text("Murmur uses Doubao ASR 2.0, which makes a second, more accurate pass over each sentence. Pick the billing you opened in the console.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }

        PageSection(title: "Microphone", trailing: AnyView(
            Button("Refresh") { refreshDevices() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        )) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "Input device",
                               detail: "Pin your built-in or desk mic to avoid switching Bluetooth headphones into call mode.") {
                        Picker("", selection: $settings.preferredMicUID) {
                            Text(defaultMicLabel).tag("")
                            if !devices.isEmpty { Divider() }
                            ForEach(devices) { d in
                                Text(d.name).tag(d.uid)
                            }
                            if !settings.preferredMicUID.isEmpty,
                               !devices.contains(where: { $0.uid == settings.preferredMicUID }) {
                                Divider()
                                Text("Disconnected device (using default)").tag(settings.preferredMicUID)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    RowDivider()
                    HStack(spacing: 12) {
                        Button {
                            micTester.running ? micTester.stop() : micTester.start(deviceUID: settings.preferredMicUID)
                        } label: {
                            Label(micTester.running ? "Stop Test" : "Test Mic",
                                  systemImage: micTester.running ? "stop.fill" : "mic.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(.glass)
                        .disabled(Permissions.microphone == .denied || Permissions.microphone == .restricted)

                        MicLevelBar(level: micTester.level, active: micTester.running)
                            .frame(height: 8)

                        if let err = micTester.error {
                            Text(err)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Brand.coral)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }

        PageSection(title: "Vocabulary", trailing: settings.vocabularyTerms.isEmpty ? nil : AnyView(
            Badge(text: "\(settings.vocabularyTerms.count) \(settings.vocabularyTerms.count == 1 ? "term" : "terms")", tint: .secondary)
        )) {
            Card(padding: 0) {
                ZStack(alignment: .topLeading) {
                    if settings.vocabulary.isEmpty {
                        Text("e.g. Murmur, Volcengine, OpenRouter")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $settings.vocabulary)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 74, maxHeight: 120)
                }
            }
            Text("Names, technical terms, and phrases you dictate often (one per line or comma-separated). Sent to Doubao as recognition hints and to your polish model so exact spellings stick.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }

        PageSection(title: "Listening") {
            Card {
                SettingRow(title: "Stop when it's quiet",
                           detail: "When Doubao hears no new words for this long, Murmur stops listening and carries on with what you said. Choose Never to rely only on the 15-minute cap.") {
                    Picker("", selection: $settings.quietStop) {
                        ForEach(quietChoices, id: \.self) { s in
                            Text(quietLabel(s)).tag(s)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .onAppear { refreshDevices() }
        .onDisappear { micTester.stop() }
        .onChange(of: settings.preferredMicUID) {
            if micTester.running { micTester.start(deviceUID: settings.preferredMicUID) }
        }
        .onChange(of: settings.doubaoKey) { check = .idle }
        .onChange(of: settings.doubaoAppID) { check = .idle }
        .onChange(of: settings.doubaoResource) { check = .idle }
        .onChange(of: settings.doubaoAuth) { check = .idle }
    }

    private var defaultMicLabel: String {
        if let name = devices.first(where: \.isDefault)?.name {
            return "System Default (\(name))"
        }
        return "System Default"
    }

    private var quietChoices: [Double] {
        let base: [Double] = [30, 60, 120, 180, 300, 600, 0]
        if base.contains(settings.quietStop) { return base }
        return (base.filter { $0 > 0 } + [settings.quietStop]).sorted() + [0]
    }

    private func quietLabel(_ s: Double) -> String {
        if s <= 0 { return "Never (15-min limit only)" }
        return s == SilenceWatch.defaultLimit ? "\(DictationEngine.spoken(s)) (default)" : DictationEngine.spoken(s)
    }

    private func refreshDevices() {
        devices = AudioDevices.inputs()
    }

    /// Opens a real stream: Doubao checks the key, the resource and the
    /// parameters before it answers the first request.
    private func test() {
        guard let credentials = settings.doubaoCredentials else { return }
        check = .running
        Task {
            let session = DoubaoSession(credentials: credentials)
            let started = Date()
            do {
                try await session.open(timeout: 10)
                session.cancel()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                check = .passed("Connected in \(ms) ms")
            } catch {
                session.cancel()
                check = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

@MainActor @Observable
private final class MicTester {
    private(set) var running = false
    private(set) var level: Double = 0
    private(set) var error: String?
    @ObservationIgnored private var capture: AudioCapture?

    func start(deviceUID: String) {
        stop()
        error = nil
        if Permissions.microphone == .notDetermined {
            Task {
                let granted = await Permissions.requestMicrophone()
                Readiness.shared.refresh()
                if granted { self.begin(deviceUID: deviceUID) }
                else { self.error = "Microphone access denied." }
            }
            return
        }
        begin(deviceUID: deviceUID)
    }

    private func begin(deviceUID: String) {
        let c = AudioCapture(preferredDeviceUID: deviceUID)
        c.onLevels = { [weak self] levels in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                let peak = Double(levels.max() ?? 0)
                self.level = peak > self.level ? peak : self.level * 0.72 + peak * 0.28
            }
        }
        c.onLost = { [weak self] in
            MainActor.assumeIsolated {
                self?.stop()
                self?.error = "Microphone disconnected."
            }
        }
        do {
            try c.start()
            capture = c
            running = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        running = false
        level = 0
    }
}

private struct MicLevelBar: View {
    let level: Double
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.well)
                Capsule()
                    .fill(Brand.voice)
                    .frame(width: active ? max(6, geo.size.width * CGFloat(min(1, max(0, level)))) : 0)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 0.5))
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
}

private struct ResourceRow: View {
    let resource: DoubaoAPI.Resource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1.2)
                    Circle().fill(Brand.voice).opacity(selected ? 1 : 0)
                    Circle().fill(.white).frame(width: 6, height: 6).opacity(selected ? 1 : 0).scaleEffect(selected ? 1 : 0.2)
                }
                .frame(width: 16, height: 16)
                .padding(.leading, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resource.title).font(.system(size: 13, weight: .medium))
                    Text(resource.detail + " · " + resource.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering && !selected ? Color.primary.opacity(0.035) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.gentle, value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selected)
    }
}
