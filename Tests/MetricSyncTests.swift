import Foundation
import XCTest
@testable import PersonalHealthTracker

@MainActor
final class MetricSyncTests: XCTestCase {
    func testHealthKitBackfillStopsAtTwelveCalendarMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2,
                                                                   hour: 19, minute: 17)))
        let cutoff = HealthSyncWindow.cutoff(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: cutoff),
                       DateComponents(year: 2025, month: 10, day: 2))
        XCTAssertFalse(HealthSyncWindow.includes(endAt: cutoff.addingTimeInterval(-1), since: cutoff))
        XCTAssertTrue(HealthSyncWindow.includes(endAt: cutoff, since: cutoff))
        XCTAssertTrue(HealthSyncWindow.includes(endAt: now, since: cutoff))
    }

    // A failed startup read must never turn an unread local file into an empty
    // cache that a subsequent cloud merge/save can overwrite.
    func testWeightMergeRetriesFailedLoadAndPreservesPendingLocalWeight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("weights.json")
        try Data("unreadable index".utf8).write(to: file)
        let store = WeightStore(directory: directory)
        XCTAssertNotNil(store.errorMessage)

        let pending = WeightEntry(id: UUID(), measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  kilograms: 77.7)
        // Restore readable bytes, representing access becoming available again.
        try JSONEncoder().encode([pending]).write(to: file)
        let remote = WeightEntry(id: UUID(), measuredAt: Date(timeIntervalSince1970: 1_699_000_000),
                                 kilograms: 78.4, pendingUpload: false)
        try store.merge([remote])

        XCTAssertEqual(Set(store.entries.map(\.id)), Set([pending.id, remote.id]))
        XCTAssertEqual(store.pendingEntries, [pending])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(WeightStore(directory: directory).entries, store.entries)
    }

    func testUnreadWeightIndexCannotBeOverwrittenByAnyMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("weights.json")
        let original = Data("unreadable index".utf8)
        try original.write(to: file)
        let store = WeightStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertThrowsError(try store.save(kilograms: 77, measuredAt: date))
        XCTAssertThrowsError(try store.merge([]))
        XCTAssertThrowsError(try store.markUploaded([UUID()]))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(store.errorMessage)
    }

    func testWeightRecoveryWorksOfflineAndClearsStartupError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("weights.json")
        try Data("unreadable index".utf8).write(to: file)
        let store = WeightStore(directory: directory)
        let pending = WeightEntry(id: UUID(), measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                                  kilograms: 77.7)
        try JSONEncoder().encode([pending]).write(to: file)

        try store.loadIfNeeded()
        try store.loadIfNeeded()
        XCTAssertEqual(store.entries, [pending])
        XCTAssertNil(store.errorMessage)
        try store.save(kilograms: 77.5, measuredAt: pending.measuredAt.addingTimeInterval(60))
        XCTAssertEqual(WeightStore(directory: directory).entries.count, 2)
    }

    func testLegacyFormulaProfileLoadsUnderGenderName() throws {
        let legacy = Data(#"{"sex":"Male","useManualSex":true,"useManualBirthDate":false}"#.utf8)
        let profile = try JSONDecoder().decode(FormulaOverrides.self, from: legacy)
        XCTAssertEqual(profile.gender, .male)
        XCTAssertTrue(profile.useManualGender)
        let saved = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["gender"] as? String, "Male")
        XCTAssertNil(object["sex"])
    }

    func testWeightCloudCorrectionWinsWithoutReuploadOrDuplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WeightStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()

        try store.merge([WeightEntry(id: id, measuredAt: date, kilograms: 78.4,
                                     pendingUpload: false)])
        try store.merge([WeightEntry(id: id, measuredAt: date, kilograms: 79.1,
                                     source: "AI", pendingUpload: false)])
        try store.merge([WeightEntry(id: id, measuredAt: date, kilograms: 79.1,
                                     source: "AI", pendingUpload: false)])

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.kilograms, 79.1)
        XCTAssertEqual(store.entries.first.map { MetricSource.label($0.source) }, "AI")
        XCTAssertTrue(store.pendingEntries.isEmpty)
        XCTAssertEqual(WeightStore(directory: directory).entries.count, 1)
    }

    func testLegacyLeanMassAndPendingLocalEntrySurviveCloudRefresh() throws {
        struct Legacy: Encodable {
            let id: UUID
            let measuredAt: Date
            let kilograms: Double
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let legacy = try JSONEncoder().encode(Legacy(id: id, measuredAt: date, kilograms: 60))
        let decoded = try JSONDecoder().decode(LeanMassEntry.self, from: legacy)
        XCTAssertTrue(decoded.pendingUpload)
        XCTAssertEqual(decoded.source, MetricSource.manual)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LeanMassStore(directory: directory)
        try store.save(kilograms: 60, measuredAt: date, latestWeightKg: 80)
        let pendingID = try XCTUnwrap(store.pendingEntries.first?.id)
        try store.merge([])
        XCTAssertEqual(store.entries.count, 1)
        try store.markUploaded([pendingID])
        XCTAssertTrue(store.pendingEntries.isEmpty)
        try store.merge([])
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEnergyLatestAICorrectionAndRemoteDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnergyStore(directory: directory)
        let old = EnergyEntry(id: UUID(), kind: .maintenance,
                              recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              kilocalories: 2_100, pendingUpload: false)
        let newerID = UUID()
        let newer = EnergyEntry(id: newerID, kind: .maintenance,
                                recordedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                kilocalories: 2_200, source: "ChatGPT", pendingUpload: false)
        try store.merge([old, newer])
        XCTAssertEqual(store.latest(for: .maintenance)?.kilocalories, 2_200)
        XCTAssertEqual(store.latest(for: .maintenance).map { MetricSource.label($0.source) }, "AI")

        let corrected = EnergyEntry(id: newerID, kind: .maintenance,
                                    recordedAt: newer.recordedAt, kilocalories: 2_250,
                                    source: "ChatGPT", pendingUpload: false)
        try store.merge([old, corrected])
        try store.merge([old, corrected])
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.latest(for: .maintenance)?.kilocalories, 2_250)
        XCTAssertTrue(store.pendingEntries.isEmpty)
        try store.merge([old])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.latest(for: .maintenance)?.kilocalories, 2_100)
    }

    func testProteinTargetAIUpdateIsIdempotentAndRetainsPendingManualEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProteinTargetStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        try store.merge([ProteinTargetEntry(id: id, recordedAt: date,
                                            minGrams: 100, maxGrams: 130,
                                            source: "ChatGPT", pendingUpload: false)])
        try store.merge([ProteinTargetEntry(id: id, recordedAt: date,
                                            minGrams: 110, maxGrams: 140,
                                            source: "ChatGPT", pendingUpload: false)])
        try store.merge([ProteinTargetEntry(id: id, recordedAt: date,
                                            minGrams: 110, maxGrams: 140,
                                            source: "ChatGPT", pendingUpload: false)])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.latest?.minGrams, 110)
        XCTAssertEqual(store.latest?.maxGrams, 140)
        XCTAssertEqual(store.latest.map { MetricSource.label($0.source) }, "AI")
        try store.save(minGrams: 120, maxGrams: 150, recordedAt: date.addingTimeInterval(10))
        XCTAssertEqual(store.pendingEntries.count, 1)
        try store.merge([])
        XCTAssertEqual(store.pendingEntries.count, 1)
    }

    func testMaintenanceIntakeCarriesForwardWithoutRewritingEarlierDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func day(_ number: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: number, hour: 12))!
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EnergyStore(directory: directory)
        try store.merge([
            EnergyEntry(id: UUID(), kind: .maintenance, recordedAt: day(10),
                        kilocalories: 2_000, pendingUpload: false),
            EnergyEntry(id: UUID(), kind: .maintenance, recordedAt: day(15),
                        kilocalories: 2_100, source: "ChatGPT", pendingUpload: false)
        ])
        let now = day(27)
        XCTAssertNil(store.effective(for: .maintenance, on: day(9), now: now, calendar: calendar))
        for number in 10...14 {
            XCTAssertEqual(store.effective(for: .maintenance, on: day(number), now: now,
                                           calendar: calendar)?.kilocalories, 2_000)
        }
        XCTAssertEqual(store.effective(for: .maintenance, on: day(15), now: now,
                                       calendar: calendar)?.kilocalories, 2_100)
    }
}
