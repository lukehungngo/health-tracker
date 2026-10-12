import Foundation
import HealthKit

struct HourlyEnergy: Decodable {
    let hour_at: Date
    let basal_kcal: Double
    let active_kcal: Double
    let basal_samples: Int
    let active_samples: Int
}

struct EnergyBackfill: Decodable {
    let hour_at: Date
    let active_kcal: Double?
    let total_burn_kcal: Double?
}

struct SleepInterval: Decodable {
    let start_at: Date
    let end_at: Date
    let value: Double

    var isAsleep: Bool {
        let stages: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        return stages.contains(Int(value))
    }

    var isAwake: Bool { Int(value) == HKCategoryValueSleepAnalysis.awake.rawValue }
}

struct DailyEnergySummary {
    let measuredKcal: Double
    let estimatedKcal: Double
    let uncoveredHours: Double
    let assumedSleepHours: Double
    var aiBackfillKcal = 0.0
    var activeKcal: Double? = nil
    var aiActiveKcal = 0.0

    var totalKcal: Double { measuredKcal + estimatedKcal + aiBackfillKcal }
    var isPartial: Bool { uncoveredHours > 0 }
}

enum CalorieBalance: Equatable {
    case unknown, deficit, surplus, even

    static func evaluate(mealCount: Int, missingEstimates: Int, intakeKcal: Double,
                         burned: DailyEnergySummary?, future: Bool) -> CalorieBalance {
        guard !future, mealCount > 0, missingEstimates == 0,
              let burned, !burned.isPartial else { return .unknown }
        if intakeKcal < burned.totalKcal { return .deficit }
        if intakeKcal > burned.totalKcal { return .surplus }
        return .even
    }

    var direction: Int {
        switch self {
        case .deficit: -1
        case .surplus: 1
        case .unknown, .even: 0
        }
    }
}

struct NetCaloriesSummary {
    let kilocalories: Double?
    let countedDays: Int
    let windowDays: Int
}

enum NetCaloriesCalculator {
    static func summary(days: Int, through now: Date, calendar: Calendar,
                        meals: [Meal], estimates: [MealEstimate],
                        burnedFor: (Date) -> DailyEnergySummary?) -> NetCaloriesSummary {
        guard days > 0 else { return NetCaloriesSummary(kilocalories: nil, countedDays: 0, windowDays: 0) }
        let endDay = calendar.startOfDay(for: now)
        let estimatesByMeal = Dictionary(estimates.map { ($0.meal_id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        var net = 0.0
        var counted = 0
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: endDay) else { continue }
            let dayMeals = meals.filter {
                $0.eatenAt <= now && calendar.isDate($0.eatenAt, inSameDayAs: day)
            }
            guard !dayMeals.isEmpty,
                  let burned = burnedFor(day), !burned.isPartial else { continue }
            let calories = dayMeals.compactMap { estimatesByMeal[$0.id]?.calories_kcal }
            guard calories.count == dayMeals.count else { continue }
            net += calories.reduce(0, +) - burned.totalKcal
            counted += 1
        }
        return NetCaloriesSummary(kilocalories: counted > 0 ? net : nil,
                                  countedDays: counted, windowDays: days)
    }
}

enum HourlyEnergyCalculator {
    static func summary(for date: Date, now: Date, calendar: Calendar,
                        hourly: [HourlyEnergy], sleep: [SleepInterval],
                        weights: [WeightEntry], backfills: [EnergyBackfill] = []) -> DailyEnergySummary {
        let start = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else {
            return DailyEnergySummary(measuredKcal: 0, estimatedKcal: 0,
                                      uncoveredHours: 0, assumedSleepHours: 0)
        }
        let end = min(nextDay, now)
        guard end > start else {
            return DailyEnergySummary(measuredKcal: 0, estimatedKcal: 0,
                                      uncoveredHours: 0, assumedSleepHours: 0)
        }

        var measured = 0.0
        var estimated = 0.0
        var uncovered = 0.0
        var assumedSleep = 0.0
        var ai = 0.0
        var active = 0.0
        var aiActive = 0.0
        var hasActive = false
        var cursor = start
        while cursor < end {
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            let finish = min(nextHour, end)
            let overlapping = hourly.filter {
                $0.hour_at < finish && $0.hour_at.addingTimeInterval(3600) > cursor
            }
            let weight = weights.first(where: { $0.measuredAt <= cursor }) ?? weights.last
            let sleepStages = sleep.filter {
                ($0.isAsleep || $0.isAwake) && $0.start_at < finish && $0.end_at > cursor
            }
            let asleepSeconds = sleepStages.filter(\.isAsleep).reduce(0.0) { total, stage in
                total + min(finish, stage.end_at).timeIntervalSince(max(cursor, stage.start_at))
            }
            let awakeSeconds = sleepStages.filter(\.isAwake).reduce(0.0) { total, stage in
                total + min(finish, stage.end_at).timeIntervalSince(max(cursor, stage.start_at))
            }
            let recordedSleep = !sleepStages.isEmpty && asleepSeconds > awakeSeconds
            let assumed = sleepStages.isEmpty && (0..<7).contains(calendar.component(.hour, from: cursor))
            let isSleep = recordedSleep || assumed

            // Split at UTC boundaries so each AI row contributes only its own hour,
            // including a partially elapsed current hour or a local day boundary.
            var slice = cursor
            while slice < finish {
                let utcHour = Date(timeIntervalSince1970: floor(slice.timeIntervalSince1970 / 3600) * 3600)
                let sliceEnd = min(finish, utcHour.addingTimeInterval(3600))
                let seconds = sliceEnd.timeIntervalSince(slice)
                let fraction = seconds / 3600
                let hk = overlapping.first { $0.hour_at == utcHour }
                let aiRow = backfills.first { $0.hour_at == utcHour }
                let observedSeconds = max(0, min(utcHour.addingTimeInterval(3600), now)
                    .timeIntervalSince(utcHour))
                let observedFraction = observedSeconds > 0 ? seconds / observedSeconds : 0
                let hasBasal = (hk?.basal_samples ?? 0) > 0
                let hasHKActive = (hk?.active_samples ?? 0) > 0
                let basal = hasBasal ? (hk?.basal_kcal ?? 0) * observedFraction : 0
                let hkActive = hasHKActive ? (hk?.active_kcal ?? 0) * observedFraction : 0
                let suppliedActive = hasHKActive ? 0 : (aiRow?.active_kcal ?? 0) * fraction
                if hasHKActive || aiRow?.active_kcal != nil {
                    hasActive = true
                    active += hkActive + suppliedActive
                    aiActive += suppliedActive
                }

                measured += basal + hkActive
                if hasBasal && hasHKActive {
                    // Complete recorded hour always wins over an AI estimate.
                } else if let aiTotal = aiRow?.total_burn_kcal {
                    ai += max(0, aiTotal * fraction - basal - hkActive, suppliedActive)
                } else if hasBasal {
                    ai += suppliedActive
                } else if let weight {
                    if hasHKActive || suppliedActive > 0 {
                        // Active energy is additional to a basal estimate.
                        estimated += weight.kilograms * fraction
                        ai += suppliedActive
                    } else {
                        estimated += weight.kilograms * (isSleep ? 1.0 : 1.3) * fraction
                    }
                    if assumed { assumedSleep += seconds / 3600 }
                } else if suppliedActive > 0 {
                    ai += suppliedActive
                    uncovered += seconds / 3600 // Basal energy is still unknown.
                } else {
                    uncovered += seconds / 3600
                }
                slice = sliceEnd
            }
            cursor = finish
        }
        return DailyEnergySummary(measuredKcal: measured, estimatedKcal: estimated,
                                  uncoveredHours: uncovered, assumedSleepHours: assumedSleep,
                                  aiBackfillKcal: ai, activeKcal: hasActive ? active : nil,
                                  aiActiveKcal: aiActive)
    }
}

@MainActor
final class DailyEnergyStore: ObservableObject {
    @Published private(set) var months: [Date: [HourlyEnergy]] = [:]
    @Published private(set) var sleepMonths: [Date: [SleepInterval]] = [:]
    @Published private(set) var backfillMonths: [Date: [EnergyBackfill]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client = NeonConnection.client
    private var loadedUserID: UUID?

    func clear() {
        months = [:]
        sleepMonths = [:]
        backfillMonths = [:]
        loadedUserID = nil
        errorMessage = nil
    }

    func hasMonth(_ date: Date) -> Bool {
        months[monthStart(date)] != nil
    }

    func summary(for date: Date, now: Date = .now, weights: [WeightEntry]) -> DailyEnergySummary? {
        let key = monthStart(date)
        guard let rows = months[key] else { return nil }
        return HourlyEnergyCalculator.summary(for: date, now: now, calendar: .current,
                                              hourly: rows, sleep: sleepMonths[key] ?? [],
                                              weights: weights, backfills: backfillMonths[key] ?? [])
    }

    func loadMonth(_ date: Date, userID: UUID, force: Bool = false) async {
        if loadedUserID != userID {
            clear()
            loadedUserID = userID
        }
        let start = monthStart(date)
        guard force || months[start] == nil else { return }
        guard let end = Calendar.current.date(byAdding: .month, value: 1, to: start) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let parameters = ["p_from": start.ISO8601Format(), "p_to": end.ISO8601Format()]
            let rows: [HourlyEnergy] = try await client.rpc("tracker_hourly_energy", params: parameters)
                .execute().value
            let sleeps: [SleepInterval] = try await client.from("health_samples")
                .select("start_at,end_at,value")
                .eq("user_id", value: userID.uuidString)
                .eq("type", value: HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
                .lt("start_at", value: end.ISO8601Format())
                .gt("end_at", value: start.ISO8601Format())
                .limit(1000)
                .execute().value
            let backfills: [EnergyBackfill] = try await client.from("energy_backfills")
                .select("hour_at,active_kcal,total_burn_kcal")
                .eq("user_id", value: userID.uuidString)
                .gte("hour_at", value: start.ISO8601Format())
                .lt("hour_at", value: end.ISO8601Format())
                .limit(800)
                .execute().value
            guard loadedUserID == userID else { return }
            months[start] = rows
            sleepMonths[start] = sleeps
            backfillMonths[start] = backfills
        } catch {
            if !(error is CancellationError) {
                errorMessage = "Energy could not load: \(error.localizedDescription)"
            }
        }
    }

    func loadRecentDays(_ days: Int, through date: Date, userID: UUID, force: Bool = false) async {
        guard days > 0,
              let oldest = Calendar.current.date(byAdding: .day, value: 1 - days,
                                                  to: Calendar.current.startOfDay(for: date)) else { return }
        let oldestMonth = monthStart(oldest)
        var month = monthStart(date)
        var failed = false
        while month >= oldestMonth {
            await loadMonth(month, userID: userID, force: force)
            failed = failed || months[month] == nil
            guard let previous = Calendar.current.date(byAdding: .month, value: -1, to: month) else { break }
            month = previous
        }
        if failed { errorMessage = "Some recent energy data could not load; net calories are partial." }
    }

    private func monthStart(_ date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date))!
    }
}
