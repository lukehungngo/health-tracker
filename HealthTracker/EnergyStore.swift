import Foundation

enum EnergyKind: String, CaseIterable, Codable, Identifiable {
    case basal = "app_basal_energy"
    case maintenance = "app_maintenance_energy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basal: "Estimated basal energy"
        case .maintenance: "Maintenance intake"
        }
    }
}

struct EnergyEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: EnergyKind
    let recordedAt: Date
    let kilocalories: Double
    let source: String
    let pendingUpload: Bool

    init(id: UUID, kind: EnergyKind, recordedAt: Date, kilocalories: Double,
         source: String = MetricSource.manual, pendingUpload: Bool = true) {
        self.id = id
        self.kind = kind
        self.recordedAt = recordedAt
        self.kilocalories = kilocalories
        self.source = source
        self.pendingUpload = pendingUpload
    }
}

@MainActor
final class EnergyStore: ObservableObject {
    @Published private(set) var entries: [EnergyEntry] = []
    @Published var errorMessage: String?

    private let indexURL: URL

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = directory ?? documents.appendingPathComponent("EnergyOverrides", isDirectory: true)
        indexURL = directory.appendingPathComponent("entries.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([EnergyEntry].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.recordedAt > $1.recordedAt }
            }
        } catch {
            errorMessage = "Saved energy values could not be loaded: \(error.localizedDescription)"
        }
    }

    func latest(for kind: EnergyKind) -> EnergyEntry? {
        entries.first { $0.kind == kind }
    }

    func effective(for kind: EnergyKind, on date: Date,
                   now: Date = .now, calendar: Calendar = .current) -> EnergyEntry? {
        let start = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let cutoff = min(nextDay, now)
        guard cutoff > start else { return nil }
        return entries.first { $0.kind == kind && $0.recordedAt < cutoff }
    }

    var pendingEntries: [EnergyEntry] { entries.filter(\.pendingUpload) }

    func save(kind: EnergyKind, kilocalories: Double, recordedAt: Date) throws {
        guard kilocalories.isFinite, (400...10_000).contains(kilocalories), recordedAt <= Date() else {
            throw EnergyError.invalidEntry
        }
        let entry = EnergyEntry(id: UUID(), kind: kind, recordedAt: recordedAt,
                                kilocalories: kilocalories)
        try persist(([entry] + entries).sorted { $0.recordedAt > $1.recordedAt })
    }

    func merge(_ remote: [EnergyEntry]) throws {
        guard remote.allSatisfy({ $0.kilocalories.isFinite && (400...10_000).contains($0.kilocalories) }) else {
            throw EnergyError.invalidEntry
        }
        let remoteIDs = Set(remote.map(\.id))
        let pending = entries.filter { $0.pendingUpload && !remoteIDs.contains($0.id) }
        let updated = (remote + pending).sorted { $0.recordedAt > $1.recordedAt }
        if updated != entries { try persist(updated) }
    }

    func markUploaded(_ ids: Set<UUID>) throws {
        let updated = entries.map { entry in
            guard ids.contains(entry.id) else { return entry }
            return EnergyEntry(id: entry.id, kind: entry.kind, recordedAt: entry.recordedAt,
                               kilocalories: entry.kilocalories, source: entry.source,
                               pendingUpload: false)
        }
        if updated != entries { try persist(updated) }
    }

    private func persist(_ updated: [EnergyEntry]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    private enum EnergyError: LocalizedError {
        case invalidEntry
        var errorDescription: String? { "Enter a daily energy value from 400 to 10,000 kcal at a time not in the future." }
    }
}
