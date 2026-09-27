import Foundation
import UIKit

struct Meal: Codable, Identifiable {
    let id: UUID
    let eatenAt: Date
    let note: String
    let imageName: String?
}

@MainActor
final class MealStore: ObservableObject {
    @Published private(set) var meals: [Meal] = []
    @Published var errorMessage: String?

    private let directory: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Meals", isDirectory: true)
        indexURL = directory.appendingPathComponent("meals.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                meals = try JSONDecoder().decode([Meal].self, from: Data(contentsOf: indexURL))
                    .sorted { $0.eatenAt > $1.eatenAt }
            }
        } catch {
            errorMessage = "Saved meals could not be loaded: \(error.localizedDescription)"
        }
    }

    func save(image: UIImage, note: String, eatenAt: Date = Date()) throws {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw MealError.invalidImage
        }
        let id = UUID()
        let imageName = "\(id.uuidString).jpg"
        let imageURL = directory.appendingPathComponent(imageName)
        let meal = Meal(id: id, eatenAt: eatenAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines), imageName: imageName)
        try data.write(to: imageURL, options: [.atomic, .completeFileProtection])
        do {
            let updated = ([meal] + meals).sorted { $0.eatenAt > $1.eatenAt }
            let encoded = try JSONEncoder().encode(updated)
            try encoded.write(to: indexURL, options: [.atomic, .completeFileProtection])
            meals = updated
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

    func image(for meal: Meal) -> UIImage? {
        guard let data = imageData(for: meal) else { return nil }
        return UIImage(data: data)
    }

    func imageData(for meal: Meal) -> Data? {
        guard let imageName = meal.imageName else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(imageName))
    }

    func importRemote(id: UUID, eatenAt: Date, note: String, imageData: Data?) throws {
        guard !meals.contains(where: { $0.id == id }) else { return }
        if let imageData, UIImage(data: imageData) == nil { throw MealError.invalidImage }
        let imageName = imageData == nil ? nil : "\(id.uuidString).jpg"
        let imageURL = imageName.map { directory.appendingPathComponent($0) }
        let meal = Meal(id: id, eatenAt: eatenAt, note: note, imageName: imageName)
        if let imageData, let imageURL {
            try imageData.write(to: imageURL, options: [.atomic, .completeFileProtection])
        }
        do {
            let updated = (meals + [meal]).sorted { $0.eatenAt > $1.eatenAt }
            try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
            meals = updated
        } catch {
            if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
            throw error
        }
    }

    private enum MealError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "The selected photo could not be saved." }
    }
}
