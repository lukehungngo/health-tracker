import Foundation
import HealthKit
import Supabase

struct HourlyEnergy: Decodable {
    let hour_at: Date
    let basal_kcal: Double
    let active_kcal: Double
    let basal_samples: Int
    let active_samples: Int
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

    var totalKcal: Double { measuredKcal + estimatedKcal }
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

enum HourlyEnergyCalculator {
    static func summary(for date: Date, now: Date, calendar: Calendar,
                        hourly: [HourlyEnergy], sleep: [SleepInterval],
                        weights: [WeightEntry]) -> DailyEnergySummary {
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
        var cursor = start
        while cursor < end {
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            let finish = min(nextHour, end)
            let hourSeconds = finish.timeIntervalSince(cursor)
            let overlapping = hourly.filter {
                $0.hour_at < finish && $0.hour_at.addingTimeInterval(3600) > cursor
            }
            if !overlapping.isEmpty {
                for row in overlapping {
                    let effectiveEnd = min(row.hour_at.addingTimeInterval(3600), now)
                    let seconds = min(finish, effectiveEnd)
                        .timeIntervalSince(max(cursor, row.hour_at))
                    let observedSeconds = effectiveEnd.timeIntervalSince(row.hour_at)
                    if seconds > 0, observedSeconds > 0 {
                        measured += (row.basal_kcal + row.active_kcal) * seconds / observedSeconds
                    }
                }
            } else if let weight = weights.first(where: { $0.measuredAt <= cursor })
                ?? weights.last {
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
                estimated += weight.kilograms * (isSleep ? 1.0 : 1.3) * hourSeconds / 3600
                if assumed { assumedSleep += hourSeconds / 3600 }
            } else {
                uncovered += hourSeconds / 3600
            }
            cursor = finish
        }
        return DailyEnergySummary(measuredKcal: measured, estimatedKcal: estimated,
                                  uncoveredHours: uncovered, assumedSleepHours: assumedSleep)
    }
}

@MainActor
final class DailyEnergyStore: ObservableObject {
    @Published private(set) var months: [Date: [HourlyEnergy]] = [:]
    @Published private(set) var sleepMonths: [Date: [SleepInterval]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client = SupabaseConnection.client
    private var loadedUserID: UUID?

    func clear() {
        months = [:]
        sleepMonths = [:]
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
                                              weights: weights)
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
            guard loadedUserID == userID else { return }
            months[start] = rows
            sleepMonths[start] = sleeps
        } catch {
            if !(error is CancellationError) {
                errorMessage = "Energy could not load: \(error.localizedDescription)"
            }
        }
    }

    private func monthStart(_ date: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date))!
    }
}
