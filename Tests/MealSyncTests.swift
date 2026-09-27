import Foundation
import UIKit
import XCTest
@testable import PersonalHealthTracker

@MainActor
final class MealSyncTests: XCTestCase {
    func testCloudCorrectionAndRetryKeepOneMeal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealStore(directory: directory)
        let mealID = UUID()
        let time = Date(timeIntervalSince1970: 1_700_000_000)

        try store.importRemote(id: mealID, eatenAt: time, note: "Original", imageData: nil)
        try store.importRemote(id: mealID, eatenAt: time, note: "Corrected by ChatGPT", imageData: nil)
        try store.importRemote(id: mealID, eatenAt: time, note: "Corrected by ChatGPT", imageData: nil)

        XCTAssertEqual(store.meals.count, 1)
        XCTAssertEqual(store.meals.first?.note, "Corrected by ChatGPT")
        XCTAssertEqual(MealStore(directory: directory).meals.first?.note, "Corrected by ChatGPT")
    }

    func testChangedCloudImagePathDownloadsOnceAndKeepsOneMeal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealStore(directory: directory)
        let mealID = UUID()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let firstPath = "owner/first.jpg"
        let secondPath = "owner/revised.jpg"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let imageData = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))

        XCTAssertTrue(store.needsRemoteImage(id: mealID, path: firstPath))
        try store.importRemote(id: mealID, eatenAt: time, note: "Meal", imageData: imageData, imagePath: firstPath)
        XCTAssertFalse(store.needsRemoteImage(id: mealID, path: firstPath))
        XCTAssertTrue(store.needsRemoteImage(id: mealID, path: secondPath))
        let oldImageName = store.meals.first?.imageName
        try store.importRemote(id: mealID, eatenAt: time, note: "Revised", imageData: imageData, imagePath: secondPath)
        try store.importRemote(id: mealID, eatenAt: time, note: "Revised", imageData: nil, imagePath: secondPath)

        XCTAssertEqual(store.meals.count, 1)
        XCTAssertNotEqual(store.meals.first?.imageName, oldImageName)
        XCTAssertEqual(store.meals.first?.remoteImagePath, secondPath)
        XCTAssertNotNil(store.image(for: try XCTUnwrap(store.meals.first)))
        XCTAssertEqual(MealStore(directory: directory).meals.first?.remoteImagePath, secondPath)
    }
}
