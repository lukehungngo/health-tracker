import Foundation

struct MealEstimate: Codable, Identifiable {
    let id: UUID
    let meal_id: UUID
    let calories_kcal: Double?
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let confidence: Double?
    let pendingUpload: Bool

    init(id: UUID, meal_id: UUID, calories_kcal: Double?, protein_g: Double?,
         carbs_g: Double?, fat_g: Double?, confidence: Double?, pendingUpload: Bool = false) {
        self.id = id
        self.meal_id = meal_id
        self.calories_kcal = calories_kcal
        self.protein_g = protein_g
        self.carbs_g = carbs_g
        self.fat_g = fat_g
        self.confidence = confidence
        self.pendingUpload = pendingUpload
    }

    private enum CodingKeys: String, CodingKey {
        case id, meal_id, calories_kcal, protein_g, carbs_g, fat_g, confidence, pendingUpload
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        meal_id = try values.decode(UUID.self, forKey: .meal_id)
        calories_kcal = try values.decodeIfPresent(Double.self, forKey: .calories_kcal)
        protein_g = try values.decodeIfPresent(Double.self, forKey: .protein_g)
        carbs_g = try values.decodeIfPresent(Double.self, forKey: .carbs_g)
        fat_g = try values.decodeIfPresent(Double.self, forKey: .fat_g)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        pendingUpload = try values.decodeIfPresent(Bool.self, forKey: .pendingUpload) ?? false
    }
}

@MainActor
final class MealEstimateStore: ObservableObject {
    @Published private(set) var estimates: [MealEstimate] = []
    @Published var errorMessage: String?

    private let indexURL: URL

    init(directory: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = directory ?? documents.appendingPathComponent("MealEstimates", isDirectory: true)
        indexURL = directory.appendingPathComponent("estimates.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                estimates = try JSONDecoder().decode([MealEstimate].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            errorMessage = "Saved meal estimates could not be loaded: \(error.localizedDescription)"
        }
    }

    func replaceFromCloud(_ remote: [MealEstimate]) throws {
        guard remote.allSatisfy({ estimate in
            (estimate.calories_kcal.map { $0.isFinite && (0...20_000).contains($0) } ?? true) &&
            [estimate.protein_g, estimate.carbs_g, estimate.fat_g]
                .allSatisfy { $0.map { $0.isFinite && (0...2_000).contains($0) } ?? true } &&
            (estimate.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }) else {
            throw EstimateError.invalidCalories
        }
        let pending = estimates.filter(\.pendingUpload)
        let pendingMealIDs = Set(pending.map(\.meal_id))
        try persist(remote.filter { !pendingMealIDs.contains($0.meal_id) } + pending)
    }

    var pendingEstimates: [MealEstimate] { estimates.filter(\.pendingUpload) }

    func saveManual(mealID: UUID, calories: Double?, protein: Double?, carbs: Double?, fat: Double?) throws {
        let values = [calories, protein, carbs, fat]
        guard values.contains(where: { $0 != nil }),
              (calories.map { $0.isFinite && (0...20_000).contains($0) } ?? true),
              [protein, carbs, fat].allSatisfy({ $0.map { $0.isFinite && (0...2_000).contains($0) } ?? true }) else {
            throw EstimateError.invalidManualEntry
        }
        let prior = estimate(for: mealID)
        let entry = MealEstimate(id: prior?.id ?? UUID(), meal_id: mealID,
                                 calories_kcal: calories, protein_g: protein,
                                 carbs_g: carbs, fat_g: fat, confidence: nil, pendingUpload: true)
        try persist(estimates.filter { $0.meal_id != mealID } + [entry])
    }

    func markUploaded(_ uploaded: MealEstimate, remoteID: UUID) throws {
        let updated = estimates.map { entry in
            guard entry.meal_id == uploaded.meal_id else { return entry }
            let unchanged = entry.calories_kcal == uploaded.calories_kcal &&
                entry.protein_g == uploaded.protein_g && entry.carbs_g == uploaded.carbs_g &&
                entry.fat_g == uploaded.fat_g
            return MealEstimate(id: remoteID, meal_id: entry.meal_id,
                                calories_kcal: entry.calories_kcal, protein_g: entry.protein_g,
                                carbs_g: entry.carbs_g, fat_g: entry.fat_g,
                                confidence: entry.confidence, pendingUpload: !unchanged)
        }
        try persist(updated)
    }

    private func persist(_ updated: [MealEstimate]) throws {
        try JSONEncoder().encode(updated).write(to: indexURL, options: [.atomic, .completeFileProtection])
        estimates = updated
    }

    func estimate(for mealID: UUID) -> MealEstimate? {
        estimates.first { $0.meal_id == mealID }
    }

    func totalCalories(for meals: [Meal]) -> Double {
        meals.compactMap { estimate(for: $0.id)?.calories_kcal }.reduce(0, +)
    }

    func totalProtein(for meals: [Meal]) -> Double {
        meals.compactMap { estimate(for: $0.id)?.protein_g }.reduce(0, +)
    }

    func missingProteinCount(for meals: [Meal]) -> Int {
        meals.filter { estimate(for: $0.id)?.protein_g == nil }.count
    }

    func unestimatedCount(for meals: [Meal]) -> Int {
        meals.filter { estimate(for: $0.id)?.calories_kcal == nil }.count
    }

    private enum EstimateError: LocalizedError {
        case invalidCalories, invalidManualEntry
        var errorDescription: String? {
            switch self {
            case .invalidCalories: "A cloud meal estimate contains invalid calories, macros, or confidence."
            case .invalidManualEntry: "Enter at least one non-negative value (kcal up to 20,000; grams up to 2,000)."
            }
        }
    }
}
