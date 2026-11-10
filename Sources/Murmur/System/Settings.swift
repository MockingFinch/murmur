import Foundation
import Observation
import MurmurCore

/// API keys, in a file only your account can read.
///
/// Not the keychain: an unsigned app is a new app to the keychain after
/// every build, and macOS then asks for your password before it may read
/// its own keys.
enum SecretStore {
    /// Development runs (snapshots, self-checks) never read or write real keys.
    nonisolated(unsafe) static var disabled = false

    private static var file: URL { AppFiles.directory.appendingPathComponent("credentials.json") }

    static func read(_ account: String) -> String {
        guard !disabled else { return "" }
        return load()[account] ?? ""
    }

    static func write(_ value: String, _ account: String) {
        guard !disabled else { return }
        var all = load()
        all[account] = value.isEmpty ? nil : value
        guard let data = try? JSONEncoder().encode(all) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: file)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

enum DoubaoAuth: String, CaseIterable, Identifiable {
    /// The new Volcengine console: one API key.
    case apiKey
    /// The classic console: an App ID and an Access Token.
    case classic
    var id: String { rawValue }
}

/// Everything the user sets up: plain values in UserDefaults, keys in `SecretStore`.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var secretWrites: [String: Task<Void, Never>] = [:]

    var shortcut: Shortcut { didSet { store(shortcut, "shortcut") } }
    var translateShortcut: Shortcut { didSet { store(translateShortcut, "translate.shortcut") } }
    /// The language translations go into, as the model is told it.
    var translateLanguage: String { didSet { defaults.set(translateLanguage, forKey: "translate.language") } }
    var translatePrompt: String { didSet { defaults.set(translatePrompt, forKey: "translate.prompt") } }
    var doubaoAuth: DoubaoAuth { didSet { defaults.set(doubaoAuth.rawValue, forKey: "doubao.auth") } }
    var doubaoAppID: String { didSet { defaults.set(doubaoAppID, forKey: "doubao.appID") } }
    var doubaoResource: String { didSet { defaults.set(doubaoResource, forKey: "doubao.resource") } }
    var doubaoKey: String { didSet { saveSecret(doubaoKey, "doubao") } }
    /// The language model's OpenAI-compatible endpoint, as typed.
    var openRouterBase: String { didSet { defaults.set(openRouterBase, forKey: "llm.base") } }
    var openRouterKey: String { didSet { saveSecret(openRouterKey, "llm") } }
    var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openrouter.model") } }
    var prompt: String { didSet { defaults.set(prompt, forKey: "prompt") } }
    /// Seconds to wait for the model, retries included, before inserting the transcript as it is.
    var polishTimeout: Double { didSet { defaults.set(polishTimeout, forKey: "polish.timeout") } }
    var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }

    static let defaultModel = "google/gemini-3.1-flash-lite"

    private init() {
        shortcut = (defaults.data(forKey: "shortcut")).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        translateShortcut = (defaults.data(forKey: "translate.shortcut")).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .translateDefault
        translateLanguage = defaults.string(forKey: "translate.language") ?? TranslatePrompt.defaultLanguage
        translatePrompt = defaults.string(forKey: "translate.prompt") ?? TranslatePrompt.defaultInstructions
        doubaoAuth = DoubaoAuth(rawValue: defaults.string(forKey: "doubao.auth") ?? "") ?? .apiKey
        doubaoAppID = defaults.string(forKey: "doubao.appID") ?? ""
        doubaoResource = defaults.string(forKey: "doubao.resource") ?? DoubaoAPI.defaultResource
        openRouterBase = defaults.string(forKey: "llm.base") ?? OpenRouterClient.defaultBase.absoluteString
        openRouterModel = defaults.string(forKey: "openrouter.model") ?? Self.defaultModel
        prompt = defaults.string(forKey: "prompt") ?? PolishPrompt.defaultInstructions
        polishTimeout = defaults.object(forKey: "polish.timeout") as? Double ?? OpenRouterClient.defaultTimeout
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        doubaoKey = SecretStore.read("doubao")
        openRouterKey = SecretStore.read("llm")
    }

    /// The Doubao credentials, when they are complete.
    var doubaoCredentials: DoubaoCredentials? {
        let appID = doubaoAuth == .classic ? doubaoAppID : ""
        if doubaoAuth == .classic, appID.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let c = DoubaoCredentials(appID: appID, token: doubaoKey, resource: doubaoResource)
        return c.isComplete ? c : nil
    }

    var speechReady: Bool { doubaoCredentials != nil }

    /// The endpoint, when it reads as one.
    var llmEndpoint: URL? { OpenRouterClient.endpoint(from: openRouterBase) }

    /// A model on this Mac (Ollama, LM Studio…) may need no key.
    var llmIsLocal: Bool {
        guard let host = llmEndpoint?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    var llmUsesOpenRouter: Bool { llmEndpoint.map(OpenRouterClient.isOpenRouter) ?? false }

    var polishReady: Bool {
        let hasKey = !openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return llmEndpoint != nil && (hasKey || llmIsLocal)
            && !openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A client set up the way the user configured it.
    func openRouterClient(timeout: Double? = nil, attempts: Int? = nil) -> OpenRouterClient {
        var tuning = OpenRouterClient.Tuning()
        tuning.timeout = timeout ?? polishTimeout
        if let attempts { tuning.attempts = attempts }
        return OpenRouterClient(apiKey: openRouterKey, base: llmEndpoint ?? OpenRouterClient.defaultBase, tuning: tuning)
    }

    /// The catalog entry for the model, when the endpoint is OpenRouter.
    var modelInfo: OpenRouterModel? {
        llmUsesOpenRouter ? ModelCatalog.shared.info(for: openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    /// Writes wait for typing to pause.
    private func saveSecret(_ value: String, _ account: String) {
        secretWrites[account]?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        secretWrites[account] = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            SecretStore.write(trimmed, account)
        }
    }
}
