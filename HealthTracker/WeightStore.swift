import Foundation

struct WeightEntry: Codable, Identifiable {
    let id: UUID
    let measuredAt: Date
    let kilograms: Double
}

@MainActor
final class WeightStore: ObservableObject {
    @Published private(set) var entries: [WeightEntry] = []
    @Published var errorMessage: String?

    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Weights", isDirectory: true)
        indexURL = directory.appendingPathComponent("weights.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([WeightEntry].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.measuredAt > $1.measuredAt }
            }
        } catch {
            errorMessage = "Saved weights could not be loaded: \(error.localizedDescription)"
        }
    }

    func save(kilograms: Double, measuredAt: Date) throws {
        guard kilograms.isFinite, (20...500).contains(kilograms), measuredAt <= Date() else {
            throw WeightError.invalidEntry
        }
        let entry = WeightEntry(id: UUID(), measuredAt: measuredAt, kilograms: kilograms)
        let updated = ([entry] + entries).sorted { $0.measuredAt > $1.measuredAt }
        let encoded = try JSONEncoder().encode(updated)
        try encoded.write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    func merge(_ remote: [WeightEntry]) throws {
        let existing = Set(entries.map(\.id))
        let newEntries = remote.filter { !existing.contains($0.id) }
        guard !newEntries.isEmpty else { return }
        guard newEntries.allSatisfy({ $0.kilograms.isFinite && (20...500).contains($0.kilograms) }) else {
            throw WeightError.invalidEntry
        }
        let updated = (entries + newEntries).sorted { $0.measuredAt > $1.measuredAt }
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    private enum WeightError: LocalizedError {
        case invalidEntry
        var errorDescription: String? { "Enter a weight from 20 to 500 kg and a time that is not in the future." }
    }
}
