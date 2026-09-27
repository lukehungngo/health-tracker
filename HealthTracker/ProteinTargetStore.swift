import Foundation
import Supabase

struct ProteinTargetEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let recordedAt: Date
    let minGrams: Double
    let maxGrams: Double
    let source: String
    let pendingUpload: Bool

    init(id: UUID, recordedAt: Date, minGrams: Double, maxGrams: Double,
         source: String = MetricSource.manual, pendingUpload: Bool = true) {
        self.id = id
        self.recordedAt = recordedAt
        self.minGrams = minGrams
        self.maxGrams = maxGrams
        self.source = source
        self.pendingUpload = pendingUpload
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordedAt, minGrams, maxGrams, source, pendingUpload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        minGrams = try values.decode(Double.self, forKey: .minGrams)
        maxGrams = try values.decode(Double.self, forKey: .maxGrams)
        source = try values.decode(String.self, forKey: .source)
        pendingUpload = try values.decodeIfPresent(Bool.self, forKey: .pendingUpload) ?? true
    }
}

private struct ProteinTargetDownload: Decodable {
    let id: UUID
    let recorded_at: Date
    let min_g: Double
    let max_g: Double
    let source: String
}

private struct ProteinTargetUpload: Encodable {
    let id: UUID
    let user_id: UUID
    let recorded_at: Date
    let min_g: Double
    let max_g: Double
    let source: String
}

@MainActor
final class ProteinTargetStore: ObservableObject {
    @Published private(set) var entries: [ProteinTargetEntry] = []
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?

    private let indexURL: URL
    private let client = SupabaseConnection.client

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = directory ?? documents.appendingPathComponent("ProteinTargets", isDirectory: true)
        indexURL = directory.appendingPathComponent("targets.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([ProteinTargetEntry].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.recordedAt > $1.recordedAt }
            }
        } catch {
            errorMessage = "Saved protein targets could not be loaded: \(error.localizedDescription)"
        }
    }

    var latest: ProteinTargetEntry? { entries.first }
    var pendingEntries: [ProteinTargetEntry] { entries.filter(\.pendingUpload) }

    func save(minGrams: Double, maxGrams: Double, recordedAt: Date) throws {
        guard Self.valid(minGrams, maxGrams), recordedAt <= .now else {
            throw ProteinError.invalidEntry
        }
        let entry = ProteinTargetEntry(id: UUID(), recordedAt: recordedAt,
                                       minGrams: minGrams, maxGrams: maxGrams)
        try persist(([entry] + entries).sorted { $0.recordedAt > $1.recordedAt })
    }

    func merge(_ remote: [ProteinTargetEntry]) throws {
        guard remote.allSatisfy({ Self.valid($0.minGrams, $0.maxGrams) }) else {
            throw ProteinError.invalidEntry
        }
        let ids = Set(remote.map(\.id))
        let pending = entries.filter { $0.pendingUpload && !ids.contains($0.id) }
        let updated = (remote + pending).sorted { $0.recordedAt > $1.recordedAt }
        if updated != entries { try persist(updated) }
    }

    func markUploaded(_ ids: Set<UUID>) throws {
        let updated = entries.map { entry in
            guard ids.contains(entry.id) else { return entry }
            return ProteinTargetEntry(id: entry.id, recordedAt: entry.recordedAt,
                                      minGrams: entry.minGrams, maxGrams: entry.maxGrams,
                                      source: entry.source, pendingUpload: false)
        }
        if updated != entries { try persist(updated) }
    }

    func sync(userID: UUID) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let remote: [ProteinTargetDownload] = try await client.from("protein_targets")
                .select("id,recorded_at,min_g,max_g,source")
                .eq("user_id", value: userID.uuidString)
                .order("recorded_at", ascending: false)
                .limit(100)
                .execute().value
            try merge(remote.map {
                ProteinTargetEntry(id: $0.id, recordedAt: $0.recorded_at,
                                   minGrams: $0.min_g, maxGrams: $0.max_g,
                                   source: $0.source, pendingUpload: false)
            })
            let pending = pendingEntries
            guard !pending.isEmpty else { return }
            let rows = pending.map {
                ProteinTargetUpload(id: $0.id, user_id: userID, recorded_at: $0.recordedAt,
                                    min_g: $0.minGrams, max_g: $0.maxGrams, source: $0.source)
            }
            try await client.from("protein_targets").upsert(rows, onConflict: "id").execute()
            try markUploaded(Set(pending.map(\.id)))
        } catch {
            errorMessage = "Protein target could not sync: \(error.localizedDescription)"
        }
    }

    private func persist(_ updated: [ProteinTargetEntry]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        entries = updated
    }

    private static func valid(_ minGrams: Double, _ maxGrams: Double) -> Bool {
        minGrams.isFinite && maxGrams.isFinite && minGrams >= 20 &&
            maxGrams >= minGrams && maxGrams <= 400
    }

    private enum ProteinError: LocalizedError {
        case invalidEntry
        var errorDescription: String? { "Enter a protein range from 20 to 400 g/day, with minimum no greater than maximum." }
    }
}
