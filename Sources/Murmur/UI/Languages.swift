import Foundation

/// Languages offered for translation. The English name is what the model
/// is told; the native name is what people recognise at a glance, so the
/// capsule and the menu show it.
enum TranslationLanguages {
    struct Entry: Identifiable, Hashable {
        let name: String
        let native: String
        var id: String { name }
    }

    static let all: [Entry] = [
        .init(name: "English", native: "English"),
        .init(name: "Simplified Chinese", native: "简体中文"),
        .init(name: "Traditional Chinese", native: "繁體中文"),
        .init(name: "Japanese", native: "日本語"),
        .init(name: "Korean", native: "한국어"),
        .init(name: "Spanish", native: "Español"),
        .init(name: "French", native: "Français"),
        .init(name: "German", native: "Deutsch"),
        .init(name: "Portuguese", native: "Português"),
        .init(name: "Italian", native: "Italiano"),
        .init(name: "Russian", native: "Русский"),
        .init(name: "Arabic", native: "العربية"),
        .init(name: "Hindi", native: "हिन्दी"),
        .init(name: "Vietnamese", native: "Tiếng Việt"),
        .init(name: "Thai", native: "ไทย"),
        .init(name: "Indonesian", native: "Bahasa Indonesia"),
        .init(name: "Turkish", native: "Türkçe"),
        .init(name: "Dutch", native: "Nederlands"),
    ]

    static func entry(_ name: String) -> Entry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// The native name of a listed language, or the name as typed.
    static func native(_ name: String) -> String {
        entry(name)?.native ?? name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
