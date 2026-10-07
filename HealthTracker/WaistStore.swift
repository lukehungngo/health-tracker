import Foundation

struct WaistEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let measuredAt: Date
    let centimeters: Double
    let source: String
    let pendingUpload: Bool

    init(id: UUID, measuredAt: Date, centimeters: Double,
         source: String = MetricSource.manual, pendingUpload: Bool = true) {
        self.id = id
        self.measuredAt = measuredAt
        self.centimeters = centimeters
        self.source = source
        self.pendingUpload = pendingUpload
    }
}

@MainActor
final class WaistStore: ObservableObject {
    @Published private(set) var entries: [WaistEntry] = []
    @Published var errorMessage: String?

    private let indexURL: URL
    private var hasLoaded = false

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = directory ?? documents.appendingPathComponent("Waist", isDirectory: true)
        indexURL = directory.appendingPathComponent("waist.json")
        try? loadIfNeeded()
    }

    func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data: Data
            do {
                data = try Data(contentsOf: indexURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                entries = []
                hasLoaded = true
                errorMessage = nil
                return
            }
            entries = try JSONDecoder().decode([WaistEntry].self, from: data)
                .sorted { $0.measuredAt > $1.measuredAt }
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Saved waist measurements could not be loaded: \(error.localizedDescription)"
            throw error
        }
    }

    func save(centimeters: Double, measuredAt: Date) throws {
        guard Self.isValid(centimeters), measuredAt <= Date() else {
            throw WaistError.invalidEntry
        }
        try loadIfNeeded()
        let entry = WaistEntry(id: UUID(), measuredAt: measuredAt, centimeters: centimeters)
        try persist(([entry] + entries).sorted { $0.measuredAt > $1.measuredAt })
    }

    var pendingEntries: [WaistEntry] { entries.filter(\.pendingUpload) }

    func merge(_ remote: [WaistEntry]) throws {
        guard remote.allSatisfy({ Self.isValid($0.centimeters) }) else {
            throw WaistError.invalidEntry
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
            return WaistEntry(id: entry.id, measuredAt: entry.measuredAt,
                              centimeters: entry.centimeters, source: entry.source,
                              pendingUpload: false)
        }
        if updated != entries { try persist(updated) }
    }

    static func isValid(_ centimeters: Double) -> Bool {
        centimeters.isFinite && (30...300).contains(centimeters)
    }

    private func persist(_ updated: [WaistEntry]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
        errorMessage = nil
    }

    private enum WaistError: LocalizedError {
        case invalidEntry
        var errorDescription: String? {
            "Enter a waist circumference from 30 to 300 cm and a time that is not in the future."
        }
    }
}
