import Foundation
import XCTest
@testable import PersonalHealthTracker

@MainActor
final class MetricSyncTests: XCTestCase {
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
}
