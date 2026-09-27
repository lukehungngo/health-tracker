import Foundation

struct MaintenanceEstimate {
    let kilocalories: Double
    let formula: String
}

enum MaintenanceEnergy {
    // Cunningham uses fat-free mass, not skeletal muscle mass. Both formulas
    // estimate resting energy, then apply the same mostly seated activity factor.
    static func dailyEstimate(leanMassKg: Double?, weightKg: Double?, heightCm: Double?,
                              birthDate: Date?, sex: FormulaSex?) -> MaintenanceEstimate? {
        if let leanMassKg, leanMassKg.isFinite, (10...200).contains(leanMassKg),
           weightKg.map({ leanMassKg <= $0 }) ?? true {
            return MaintenanceEstimate(kilocalories: (500 + 22 * leanMassKg) * 1.2,
                                       formula: "Cunningham (lean mass) × 1.2")
        }
        guard let weightKg, let heightCm, let birthDate, let sex,
              weightKg.isFinite, heightCm.isFinite,
              (20...500).contains(weightKg), (100...250).contains(heightCm),
              let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year,
              (18...120).contains(age) else { return nil }
        let resting = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
            + (sex == .male ? 5 : -161)
        return MaintenanceEstimate(kilocalories: resting * 1.2,
                                   formula: "Mifflin-St Jeor × 1.2")
    }
}

struct ProteinRange {
    let lowerGrams: Double
    let upperGrams: Double
    let basis: String
}

enum ProteinRecommendation {
    // Reference range for resistance-trained people reducing calories (Helms et al., 2014).
    static func dailyRange(leanMassKg: Double?, weightKg: Double?) -> ProteinRange? {
        if let leanMassKg, leanMassKg.isFinite, (10...200).contains(leanMassKg),
           weightKg.map({ leanMassKg <= $0 }) ?? true {
            return ProteinRange(lowerGrams: 2.3 * leanMassKg,
                                upperGrams: 3.1 * leanMassKg,
                                basis: "2.3–3.1 g/kg lean mass")
        }
        guard let weightKg, weightKg.isFinite, (20...500).contains(weightKg) else { return nil }
        return ProteinRange(lowerGrams: 1.8 * weightKg,
                            upperGrams: 2.7 * weightKg,
                            basis: "1.8–2.7 g/kg body weight")
    }
}
