import Foundation
import UIKit
import XCTest
@testable import PersonalHealthTracker

@MainActor
final class MealSyncTests: XCTestCase {
    func testTextOnlyMealCanBeSavedAndRetriedWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealStore(directory: directory)
        try store.save(image: nil, note: "  Rice and fish  ")
        let saved = try XCTUnwrap(store.meals.first)
        XCTAssertEqual(saved.note, "Rice and fish")
        XCTAssertNil(saved.imageName)
        XCTAssertTrue(saved.pendingUpload)
        try store.markUploaded(saved, remoteImagePath: nil)
        try store.importRemote(id: saved.id, eatenAt: saved.eatenAt, note: saved.note, imageData: nil)
        XCTAssertEqual(store.meals.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.meals.first).pendingUpload)
    }

    func testPhotoOnlyAndPhotoWithNoteSaveAndEmptyMealFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealStore(directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        XCTAssertThrowsError(try store.save(image: nil, note: "  "))
        try store.save(image: image, note: "")
        try store.save(image: image, note: "Soup")
        XCTAssertEqual(store.meals.count, 2)
        XCTAssertTrue(store.meals.allSatisfy { store.image(for: $0) != nil })
        XCTAssertEqual(Set(store.meals.map(\.note)), Set(["", "Soup"]))
    }

    func testPendingLocalEditSurvivesCloudPullThenCloudCanCorrectIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealStore(directory: directory)
        let id = UUID()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        try store.importRemote(id: id, eatenAt: time, note: "Cloud", imageData: nil)
        try store.updateNote(id: id, note: "Local edit")
        try store.importRemote(id: id, eatenAt: time, note: "Stale cloud", imageData: nil)
        XCTAssertEqual(store.meals.first?.note, "Local edit")
        let edited = try XCTUnwrap(store.meals.first)
        try store.markUploaded(edited, remoteImagePath: nil)
        try store.importRemote(id: id, eatenAt: time, note: "Later AI edit", imageData: nil)
        XCTAssertEqual(store.meals.first?.note, "Later AI edit")
        XCTAssertEqual(store.meals.count, 1)
    }

    func testManualProteinOnlyEstimateSurvivesRetryAndCloudCorrection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealEstimateStore(directory: directory)
        let mealID = UUID()
        try store.saveManual(mealID: mealID, calories: nil, protein: 32, carbs: nil, fat: nil)
        let local = try XCTUnwrap(store.estimate(for: mealID))
        XCTAssertNil(local.calories_kcal)
        XCTAssertTrue(local.pendingUpload)
        let cloud = MealEstimate(id: local.id, meal_id: mealID, calories_kcal: 450,
                                 protein_g: 25, carbs_g: nil, fat_g: nil, confidence: 0.7)
        try store.replaceFromCloud([cloud])
        XCTAssertEqual(store.estimate(for: mealID)?.protein_g, 32)
        try store.markUploaded(local, remoteID: cloud.id)
        try store.replaceFromCloud([cloud])
        try store.replaceFromCloud([cloud])
        XCTAssertEqual(store.estimates.count, 1)
        XCTAssertEqual(store.estimate(for: mealID)?.protein_g, 25)
        XCTAssertFalse(try XCTUnwrap(store.estimate(for: mealID)).pendingUpload)
    }

    func testOlderUploadCannotClearNewerPendingMealOrEstimateEdit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let meals = MealStore(directory: directory.appendingPathComponent("meals"))
        let estimates = MealEstimateStore(directory: directory.appendingPathComponent("estimates"))
        try meals.save(image: nil, note: "First")
        let firstMeal = try XCTUnwrap(meals.meals.first)
        try meals.updateNote(id: firstMeal.id, note: "Second")
        try meals.markUploaded(firstMeal, remoteImagePath: nil)
        XCTAssertEqual(meals.meals.first?.note, "Second")
        XCTAssertTrue(try XCTUnwrap(meals.meals.first).pendingUpload)

        try estimates.saveManual(mealID: firstMeal.id, calories: 100, protein: nil, carbs: nil, fat: nil)
        let firstEstimate = try XCTUnwrap(estimates.estimate(for: firstMeal.id))
        try estimates.saveManual(mealID: firstMeal.id, calories: 200, protein: 20, carbs: nil, fat: nil)
        try estimates.markUploaded(firstEstimate, remoteID: firstEstimate.id)
        XCTAssertEqual(estimates.estimate(for: firstMeal.id)?.calories_kcal, 200)
        XCTAssertTrue(try XCTUnwrap(estimates.estimate(for: firstMeal.id)).pendingUpload)
    }

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
