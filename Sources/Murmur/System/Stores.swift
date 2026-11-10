import Foundation
import Observation
import MurmurCore

enum AppFiles {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// The usage records behind the statistics. Measures only, never text.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var records: [UsageRecord] = []
    @ObservationIgnored private let file = AppFiles.directory.appendingPathComponent("usage.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder.iso.decode([UsageRecord].self, from: data) {
            records = list
        }
    }

    var summary: UsageSummary { UsageMath.summarize(records) }

    func add(_ record: UsageRecord) {
        records.append(record)
        save()
    }

    func reset() {
        records = []
        save()
    }

    /// Sample data for the snapshot renderer; never saved.
    func preview(_ sample: [UsageRecord]) { records = sample }

    private func save() {
        let snapshot = records
        let file = self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder.iso.encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

/// OpenRouter's model list, cached for a day: each model's thinking rules
/// (asked for at the least) and its name and price for the hint under the
/// model field. Used only when the endpoint is OpenRouter.
@MainActor @Observable
final class ModelCatalog {
    static let shared = ModelCatalog()

    private(set) var models: [OpenRouterModel] = []
    private(set) var loading = false
    private(set) var failure: String?
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private let file = AppFiles.directory.appendingPathComponent("models.json")

    private struct Cache: Codable {
        var fetchedAt: Date
        var models: [OpenRouterModel]
    }

    private init() {
        if let data = try? Data(contentsOf: file), let cache = try? JSONDecoder.iso.decode(Cache.self, from: data) {
            models = cache.models
            fetchedAt = cache.fetchedAt
        }
    }

    func info(for id: String) -> OpenRouterModel? { models.first { $0.id == id } }

    func refresh(force: Bool = false) {
        guard !loading else { return }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 86_400, !models.isEmpty { return }
        loading = true
        failure = nil
        Task {
            do {
                let list = try await OpenRouterClient.fetchModels()
                models = list
                fetchedAt = Date()
                let cache = Cache(fetchedAt: Date(), models: list)
                if let data = try? JSONEncoder.iso.encode(cache) { try? data.write(to: file, options: .atomic) }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loading = false
        }
    }
}
