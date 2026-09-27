import Foundation
import UIKit

struct Meal: Codable, Identifiable {
    let id: UUID
    let eatenAt: Date
    let note: String
    let imageName: String?
    let remoteImagePath: String?
}

@MainActor
final class MealStore: ObservableObject {
    @Published private(set) var meals: [Meal] = []
    @Published var errorMessage: String?

    private let directory: URL
    private let indexURL: URL

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? documents.appendingPathComponent("Meals", isDirectory: true)
        indexURL = self.directory.appendingPathComponent("meals.json")
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
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
        let meal = Meal(id: id, eatenAt: eatenAt, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                        imageName: imageName, remoteImagePath: nil)
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

    func needsRemoteImage(id: UUID, path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        guard let existing = meals.first(where: { $0.id == id }) else { return true }
        if existing.remoteImagePath == path { return false }
        // An app-captured photo already has the same local file before its first cloud pull.
        if existing.remoteImagePath == nil, let name = existing.imageName,
           path.hasSuffix("/\(name)") { return false }
        return true
    }

    func importRemote(id: UUID, eatenAt: Date, note: String, imageData: Data?, imagePath: String? = nil) throws {
        if let imageData, UIImage(data: imageData) == nil { throw MealError.invalidImage }
        let path = imagePath.flatMap { $0.isEmpty ? nil : $0 }
        guard !needsRemoteImage(id: id, path: path) || imageData != nil else { throw MealError.missingImageData }
        let existing = meals.first(where: { $0.id == id })
        // Keep the previous photo intact until the updated index is committed.
        let imageName: String? = if path == nil {
            nil
        } else if imageData != nil, existing?.imageName != nil {
            "\(id.uuidString)-\(UUID().uuidString).jpg"
        } else {
            existing?.imageName ?? "\(id.uuidString).jpg"
        }
        let imageURL = imageName.map { directory.appendingPathComponent($0) }
        let meal = Meal(id: id, eatenAt: eatenAt, note: note, imageName: imageName, remoteImagePath: path)
        if let existing, existing.eatenAt == meal.eatenAt, existing.note == meal.note,
           existing.imageName == meal.imageName, existing.remoteImagePath == meal.remoteImagePath { return }
        if let imageData, let imageURL {
            try imageData.write(to: imageURL, options: [.atomic, .completeFileProtection])
        }
        do {
            let updated = (meals.filter { $0.id != id } + [meal]).sorted { $0.eatenAt > $1.eatenAt }
            try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
            meals = updated
        } catch {
            if imageName != existing?.imageName, let imageURL {
                try? FileManager.default.removeItem(at: imageURL)
            }
            throw error
        }
    }

    private enum MealError: LocalizedError {
        case invalidImage, missingImageData
        var errorDescription: String? {
            switch self {
            case .invalidImage: "The selected photo could not be saved."
            case .missingImageData: "The remote meal photo has not been downloaded."
            }
        }
    }
}
