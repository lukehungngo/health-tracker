import Foundation

struct LeanMassEntry: Codable, Identifiable {
    let id: UUID
    let measuredAt: Date
    let kilograms: Double
}

@MainActor
final class LeanMassStore: ObservableObject {
    @Published private(set) var entries: [LeanMassEntry] = []
    @Published var errorMessage: String?

    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("LeanMass", isDirectory: true)
        indexURL = directory.appendingPathComponent("lean-mass.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([LeanMassEntry].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.measuredAt > $1.measuredAt }
            }
        } catch {
            errorMessage = "Saved lean mass could not be loaded: \(error.localizedDescription)"
        }
    }

    func save(kilograms: Double, measuredAt: Date, latestWeightKg: Double?) throws {
        guard kilograms.isFinite, (10...200).contains(kilograms), measuredAt <= Date(),
              latestWeightKg.map({ kilograms <= $0 }) ?? true else {
            throw LeanMassError.invalidEntry
        }
        let entry = LeanMassEntry(id: UUID(), measuredAt: measuredAt, kilograms: kilograms)
        let updated = ([entry] + entries).sorted { $0.measuredAt > $1.measuredAt }
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    func merge(_ remote: [LeanMassEntry]) throws {
        let existing = Set(entries.map(\.id))
        let newEntries = remote.filter { !existing.contains($0.id) }
        guard !newEntries.isEmpty else { return }
        guard newEntries.allSatisfy({ $0.kilograms.isFinite && (10...200).contains($0.kilograms) }) else {
            throw LeanMassError.invalidEntry
        }
        let updated = (entries + newEntries).sorted { $0.measuredAt > $1.measuredAt }
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    private enum LeanMassError: LocalizedError {
        case invalidEntry
        var errorDescription: String? {
            "Enter lean (fat-free) mass from 10 to 200 kg, no greater than your latest weight, with a time that is not in the future."
        }
    }
}
