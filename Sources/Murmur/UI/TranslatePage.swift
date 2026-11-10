import MurmurCore
import SwiftUI

/// Speak in one language, insert in another. Translation is one more step
/// after polishing, with the model from Polish and a prompt of its own.
struct TranslatePage: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(Navigator.self) private var navigator

    var body: some View {
        PageHeader(symbol: "translate", gradient: Brand.translate, title: "Translate",
                   subtitle: "Speak in one language, insert in another: Murmur polishes what you said, then translates it. With text selected, the same shortcut translates the selection.")

        if !settings.polishReady {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Translation uses the model from Polish").font(.system(size: 13, weight: .medium))
                        Text("Set up its endpoint, key and model there; nothing else is needed.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button("Set Up Polish") { navigator.page = .polish }
                        .buttonStyle(.glass)
                }
            }
        }

        PageSection(title: "Shortcut") {
            Card { ShortcutRecorder(hotkey: .translate) }
        }

        PageSection(title: "Translate into") {
            Card { LanguageChoice() }
        }

        PageSection(title: "Prompt", trailing: settings.translatePrompt == TranslatePrompt.defaultInstructions ? nil : AnyView(
            Button("Restore Default") {
                withAnimation(Motion.gentle) { settings.translatePrompt = TranslatePrompt.defaultInstructions }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        )) {
            Card(padding: 0) {
                TextEditor(text: $settings.translatePrompt)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 220, maxHeight: 340)
            }
            Text("\(TranslatePrompt.placeholder) stands for the language above. Murmur also names the language to the model on its own, so translations follow your choice even if the prompt leaves it out.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }

        PageSection(title: "Try it") {
            Card { TryIt(job: .translate) }
        }
    }
}

/// A listed language, or one typed in: anything the model understands,
/// like "Cantonese" or "formal German".
private struct LanguageChoice: View {
    @Bindable private var settings = AppSettings.shared
    @State private var typing = false

    private static let other = "\u{0}other"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Language", detail: "What your words go in as, whatever language you speak.") {
                Picker("", selection: choice) {
                    ForEach(TranslationLanguages.all) { l in
                        Text(l.native == l.name ? l.name : "\(l.name) — \(l.native)").tag(l.name)
                    }
                    Divider()
                    Text("Other…").tag(Self.other)
                }
                .labelsHidden()
                .fixedSize()
            }
            if custom {
                PlainField(placeholder: "Any language, e.g. Cantonese or formal German", text: $settings.translateLanguage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.smooth, value: custom)
    }

    private var custom: Bool { typing || TranslationLanguages.entry(settings.translateLanguage) == nil }

    private var choice: Binding<String> {
        Binding(
            get: { custom ? Self.other : TranslationLanguages.entry(settings.translateLanguage)?.name ?? Self.other },
            set: { picked in
                if picked == Self.other {
                    typing = true
                } else {
                    typing = false
                    settings.translateLanguage = picked
                }
            }
        )
    }
}
