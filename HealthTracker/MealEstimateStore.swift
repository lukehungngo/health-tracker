import Foundation

struct MealEstimate: Codable, Identifiable {
    let id: UUID
    let meal_id: UUID
    let calories_kcal: Double
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let confidence: Double?
}

@MainActor
final class MealEstimateStore: ObservableObject {
    @Published private(set) var estimates: [MealEstimate] = []
    @Published var errorMessage: String?

    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("MealEstimates", isDirectory: true)
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
            estimate.calories_kcal.isFinite && (0...20_000).contains(estimate.calories_kcal) &&
            [estimate.protein_g, estimate.carbs_g, estimate.fat_g]
                .allSatisfy { $0.map { $0.isFinite && (0...2_000).contains($0) } ?? true } &&
            (estimate.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true)
        }) else {
            throw EstimateError.invalidCalories
        }
        try JSONEncoder().encode(remote).write(to: indexURL, options: [.atomic, .completeFileProtection])
        estimates = remote
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
        meals.filter { estimate(for: $0.id) == nil }.count
    }

    private enum EstimateError: LocalizedError {
        case invalidCalories
        var errorDescription: String? { "A cloud meal estimate contains invalid calories, macros, or confidence." }
    }
}
