import Foundation

// Compile with HealthTracker/MaintenanceEnergy.swift to test the production formulas.
enum FormulaGender { case male, female }

@main
struct FormulaChecks {
    static func main() {
        let birthday = Calendar.current.date(byAdding: .year, value: -30, to: Date())!
        let lean = MaintenanceEnergy.dailyEstimate(leanMassKg: 60, weightKg: 80,
                                                   heightCm: nil, birthDate: nil, gender: nil)
        precondition(lean?.kilocalories == 2_184)
        precondition(lean?.formula.contains("Cunningham") == true)

        let fallback = MaintenanceEnergy.dailyEstimate(leanMassKg: nil, weightKg: 80,
                                                       heightCm: 180, birthDate: birthday, gender: .male)
        precondition(fallback?.kilocalories == 2_136)
        precondition(MaintenanceEnergy.dailyEstimate(leanMassKg: 90, weightKg: 80,
                                                     heightCm: 180, birthDate: birthday,
                                                     gender: .male)?.kilocalories == 2_136)
        precondition(MaintenanceEnergy.dailyEstimate(leanMassKg: nil, weightKg: 80,
                                                     heightCm: nil, birthDate: birthday, gender: .male) == nil)

        let leanProtein = ProteinRecommendation.dailyRange(leanMassKg: 60, weightKg: 80)!
        precondition(abs(leanProtein.lowerGrams - 138) < 0.001)
        precondition(abs(leanProtein.upperGrams - 186) < 0.001)
        let fallbackProtein = ProteinRecommendation.dailyRange(leanMassKg: nil, weightKg: 80)!
        precondition(abs(fallbackProtein.lowerGrams - 144) < 0.001)
        precondition(abs(fallbackProtein.upperGrams - 216) < 0.001)
        print("Formula checks passed")
    }
}
