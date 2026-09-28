import Foundation
import UIKit

struct Meal: Codable, Identifiable {
    let id: UUID
    let eatenAt: Date
    let note: String
    let imageName: String?
    let remoteImagePath: String?
    let pendingUpload: Bool

    init(id: UUID, eatenAt: Date, note: String, imageName: String?,
         remoteImagePath: String?, pendingUpload: Bool = false) {
        self.id = id
        self.eatenAt = eatenAt
        self.note = note
        self.imageName = imageName
        self.remoteImagePath = remoteImagePath
        self.pendingUpload = pendingUpload
    }

    private enum CodingKeys: String, CodingKey {
        case id, eatenAt, note, imageName, remoteImagePath, pendingUpload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        eatenAt = try values.decode(Date.self, forKey: .eatenAt)
        note = try values.decode(String.self, forKey: .note)
        imageName = try values.decodeIfPresent(String.self, forKey: .imageName)
        remoteImagePath = try values.decodeIfPresent(String.self, forKey: .remoteImagePath)
        pendingUpload = try values.decodeIfPresent(Bool.self, forKey: .pendingUpload) ?? false
    }
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

    func save(image: UIImage?, note: String, eatenAt: Date = Date()) throws {
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard image != nil || !cleanNote.isEmpty else { throw MealError.emptyMeal }
        let data = image?.jpegData(compressionQuality: 0.85)
        if image != nil && data == nil { throw MealError.invalidImage }
        let id = UUID()
        let imageName = data == nil ? nil : "\(id.uuidString).jpg"
        let imageURL = imageName.map { directory.appendingPathComponent($0) }
        let meal = Meal(id: id, eatenAt: eatenAt, note: cleanNote,
                        imageName: imageName, remoteImagePath: nil, pendingUpload: true)
        if let data, let imageURL { try data.write(to: imageURL, options: [.atomic, .completeFileProtection]) }
        do {
            let updated = ([meal] + meals).sorted { $0.eatenAt > $1.eatenAt }
            let encoded = try JSONEncoder().encode(updated)
            try encoded.write(to: indexURL, options: [.atomic, .completeFileProtection])
            meals = updated
        } catch {
            if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
            throw error
        }
    }

    func updateNote(id: UUID, note: String) throws {
        guard let existing = meals.first(where: { $0.id == id }) else { throw MealError.missingMeal }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.imageName != nil || !cleanNote.isEmpty else { throw MealError.emptyMeal }
        guard existing.note != cleanNote else { return }
        let updated = meals.map { meal in
            meal.id == id ? Meal(id: meal.id, eatenAt: meal.eatenAt, note: cleanNote,
                                 imageName: meal.imageName, remoteImagePath: meal.remoteImagePath,
                                 pendingUpload: true) : meal
        }
        try persist(updated)
    }

    func markUploaded(_ uploaded: Meal, remoteImagePath: String?) throws {
        let updated = meals.map { meal in
            guard meal.id == uploaded.id else { return meal }
            let unchanged = meal.note == uploaded.note && meal.eatenAt == uploaded.eatenAt &&
                meal.imageName == uploaded.imageName
            return Meal(id: meal.id, eatenAt: meal.eatenAt, note: meal.note,
                        imageName: meal.imageName, remoteImagePath: remoteImagePath,
                        pendingUpload: !unchanged)
        }
        try persist(updated)
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
        if existing.pendingUpload { return false }
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
        if existing?.pendingUpload == true { return }
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

    private func persist(_ updated: [Meal]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        meals = updated
    }

    private enum MealError: LocalizedError {
        case invalidImage, missingImageData, emptyMeal, missingMeal
        var errorDescription: String? {
            switch self {
            case .invalidImage: "The selected photo could not be saved."
            case .missingImageData: "The remote meal photo has not been downloaded."
            case .emptyMeal: "Add a photo or a note before saving."
            case .missingMeal: "This meal is no longer available."
            }
        }
    }
}
