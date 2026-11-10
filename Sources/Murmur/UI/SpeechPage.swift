import MurmurCore
import SwiftUI

struct SpeechPage: View {
    @Bindable private var settings = AppSettings.shared
    @State private var check: CheckState = .idle

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

        PageSection(title: "Connection") {
            Card {
                CheckButton(title: "Test Connection", state: check, disabled: !settings.speechReady) { test() }
                if !settings.speechReady {
                    Text("Add your credentials first.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }

        PageSection(title: "Listening") {
            Card {
                SettingRow(title: "Stop when it's quiet",
                           detail: "When Doubao hears no new words for this long, Murmur stops listening and carries on with what you said. A shortcut pressed by accident won't keep running up your Doubao bill.") {
                    Picker("", selection: $settings.quietStop) {
                        ForEach(quietChoices, id: \.self) { s in
                            Text(s == SilenceWatch.defaultLimit ? "\(DictationEngine.spoken(s)) (default)" : DictationEngine.spoken(s)).tag(s)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .onChange(of: settings.doubaoKey) { check = .idle }
        .onChange(of: settings.doubaoAppID) { check = .idle }
        .onChange(of: settings.doubaoResource) { check = .idle }
        .onChange(of: settings.doubaoAuth) { check = .idle }
    }

    private var quietChoices: [Double] {
        let base: [Double] = [30, 60, 120, 180, 300, 600]
        return base.contains(settings.quietStop) ? base : (base + [settings.quietStop]).sorted()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selected)
    }
}
