import Foundation

struct WeightEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let measuredAt: Date
    let kilograms: Double
    let source: String
    let pendingUpload: Bool

    init(id: UUID, measuredAt: Date, kilograms: Double,
         source: String = MetricSource.manual, pendingUpload: Bool = true) {
        self.id = id
        self.measuredAt = measuredAt
        self.kilograms = kilograms
        self.source = source
        self.pendingUpload = pendingUpload
    }

    private enum CodingKeys: String, CodingKey {
        case id, measuredAt, kilograms, source, pendingUpload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        measuredAt = try values.decode(Date.self, forKey: .measuredAt)
        kilograms = try values.decode(Double.self, forKey: .kilograms)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? MetricSource.manual
        // Legacy local entries without this flag may not yet have reached the cloud.
        pendingUpload = try values.decodeIfPresent(Bool.self, forKey: .pendingUpload) ?? true
    }
}

@MainActor
final class WeightStore: ObservableObject {
    @Published private(set) var entries: [WeightEntry] = []
    @Published var errorMessage: String?

    private let indexURL: URL
    private var hasLoaded = false

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = directory ?? documents.appendingPathComponent("Weights", isDirectory: true)
        indexURL = directory.appendingPathComponent("weights.json")
        try? loadIfNeeded()
    }

    // Background launches can happen while complete-protection files are locked.
    // Keep a failed read distinct from an empty store, and retry before any write.
    func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data: Data
            do {
                // fileExists can hide access failures; only an actual missing-file
                // error establishes that this is a new, empty store.
                data = try Data(contentsOf: indexURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                entries = []
                hasLoaded = true
                errorMessage = nil
                return
            }
            entries = try JSONDecoder().decode([WeightEntry].self, from: data)
                .sorted { $0.measuredAt > $1.measuredAt }
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Saved weights could not be loaded: \(error.localizedDescription)"
            throw error
        }
    }

    func save(kilograms: Double, measuredAt: Date) throws {
        guard kilograms.isFinite, (20...500).contains(kilograms), measuredAt <= Date() else {
            throw WeightError.invalidEntry
        }
        try loadIfNeeded()
        let entry = WeightEntry(id: UUID(), measuredAt: measuredAt, kilograms: kilograms)
        try persist(([entry] + entries).sorted { $0.measuredAt > $1.measuredAt })
    }

    var pendingEntries: [WeightEntry] { entries.filter(\.pendingUpload) }

    func merge(_ remote: [WeightEntry]) throws {
        guard remote.allSatisfy({ $0.kilograms.isFinite && (20...500).contains($0.kilograms) }) else {
            throw WeightError.invalidEntry
        }
        try loadIfNeeded()
        let remoteIDs = Set(remote.map(\.id))
        let pending = entries.filter { $0.pendingUpload && !remoteIDs.contains($0.id) }
        let updated = (remote + pending).sorted { $0.measuredAt > $1.measuredAt }
        if updated != entries { try persist(updated) }
    }

    func markUploaded(_ ids: Set<UUID>) throws {
        try loadIfNeeded()
        let updated = entries.map { entry in
            guard ids.contains(entry.id) else { return entry }
            return WeightEntry(id: entry.id, measuredAt: entry.measuredAt,
                               kilograms: entry.kilograms, source: entry.source,
                               pendingUpload: false)
        }
        if updated != entries { try persist(updated) }
    }

    private func persist(_ updated: [WeightEntry]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
        errorMessage = nil
    }

    private enum WeightError: LocalizedError {
        case invalidEntry
        var errorDescription: String? { "Enter a weight from 20 to 500 kg and a time that is not in the future." }
    }
}
