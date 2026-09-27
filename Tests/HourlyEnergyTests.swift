import Foundation
import HealthKit
import XCTest
@testable import PersonalHealthTracker

final class HourlyEnergyTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27,
                                           hour: hour, minute: minute))!
    }

    private func weight(at measuredAt: Date? = nil) -> WeightEntry {
        WeightEntry(id: UUID(), measuredAt: measuredAt ?? date(0).addingTimeInterval(-3600),
                    kilograms: 80)
    }

    func testSleepWindowAndCurrentPartialHourUseOnlyElapsedTime() {
        let row = HourlyEnergy(hour_at: date(1), basal_kcal: 60, active_kcal: 20,
                               basal_samples: 1, active_samples: 1)
        let summary = HourlyEnergyCalculator.summary(for: date(0), now: date(3, 30),
                                                     calendar: calendar, hourly: [row], sleep: [],
                                                     weights: [weight()])
        XCTAssertEqual(summary.measuredKcal, 80, accuracy: 0.001)
        XCTAssertEqual(summary.estimatedKcal, 200, accuracy: 0.001)
        XCTAssertEqual(summary.assumedSleepHours, 2.5, accuracy: 0.001)
    }

    func testOfficeHoursUseOnePointThreeMETAfterSeven() {
        let summary = HourlyEnergyCalculator.summary(for: date(0), now: date(9),
                                                     calendar: calendar, hourly: [], sleep: [],
                                                     weights: [weight()])
        XCTAssertEqual(summary.estimatedKcal, 768, accuracy: 0.001)
        XCTAssertEqual(summary.assumedSleepHours, 7, accuracy: 0.001)
    }

    func testLateRecordedHourReplacesEstimateWithoutDuplication() {
        let row = HourlyEnergy(hour_at: date(1), basal_kcal: 70, active_kcal: 20,
                               basal_samples: 1, active_samples: 1)
        let initial = HourlyEnergyCalculator.summary(for: date(0), now: date(2),
                                                     calendar: calendar, hourly: [], sleep: [],
                                                     weights: [weight()])
        let updated = HourlyEnergyCalculator.summary(for: date(0), now: date(2),
                                                     calendar: calendar, hourly: [row], sleep: [],
                                                     weights: [weight()])
        XCTAssertEqual(initial.totalKcal, 160, accuracy: 0.001)
        XCTAssertEqual(updated.measuredKcal, 90, accuracy: 0.001)
        XCTAssertEqual(updated.estimatedKcal, 80, accuracy: 0.001)
        XCTAssertEqual(updated.totalKcal, 170, accuracy: 0.001)
        XCTAssertEqual(HourlyEnergyCalculator.summary(for: date(0), now: date(2),
                                                    calendar: calendar, hourly: [row], sleep: [],
                                                    weights: [weight()]).totalKcal, 170, accuracy: 0.001)
    }

    func testEarliestAppWeightCanEstimateEarlierHistory() {
        let summary = HourlyEnergyCalculator.summary(for: date(0), now: date(1),
                                                     calendar: calendar, hourly: [], sleep: [],
                                                     weights: [weight(at: date(12))])
        XCTAssertEqual(summary.estimatedKcal, 80, accuracy: 0.001)
    }

    func testNoAppWeightLeavesHourUncovered() {
        let summary = HourlyEnergyCalculator.summary(for: date(0), now: date(1),
                                                     calendar: calendar, hourly: [], sleep: [],
                                                     weights: [])
        XCTAssertEqual(summary.totalKcal, 0)
        XCTAssertEqual(summary.uncoveredHours, 1)
        XCTAssertTrue(summary.isPartial)
    }

    func testRecordedAwakeStageOverridesAssumedSleepWindow() {
        let awake = SleepInterval(start_at: date(2), end_at: date(3),
                                  value: Double(HKCategoryValueSleepAnalysis.awake.rawValue))
        let summary = HourlyEnergyCalculator.summary(for: date(0), now: date(3),
                                                     calendar: calendar, hourly: [], sleep: [awake],
                                                     weights: [weight()])
        XCTAssertEqual(summary.estimatedKcal, 264, accuracy: 0.001)
        XCTAssertEqual(summary.assumedSleepHours, 2, accuracy: 0.001)
    }

    func testBalanceColorsOnlyCompleteLoggedDays() {
        let burned = DailyEnergySummary(measuredKcal: 1_500, estimatedKcal: 500,
                                        uncoveredHours: 0, assumedSleepHours: 0)
        XCTAssertEqual(CalorieBalance.evaluate(mealCount: 1, missingEstimates: 0,
                                              intakeKcal: 1_800, burned: burned, future: false), .deficit)
        XCTAssertEqual(CalorieBalance.evaluate(mealCount: 1, missingEstimates: 0,
                                              intakeKcal: 2_200, burned: burned, future: false), .surplus)
        XCTAssertEqual(CalorieBalance.evaluate(mealCount: 0, missingEstimates: 0,
                                              intakeKcal: 0, burned: burned, future: false), .unknown)
        XCTAssertEqual(CalorieBalance.evaluate(mealCount: 1, missingEstimates: 1,
                                              intakeKcal: 1_800, burned: burned, future: false), .unknown)
        let partial = DailyEnergySummary(measuredKcal: 1_500, estimatedKcal: 0,
                                         uncoveredHours: 1, assumedSleepHours: 0)
        XCTAssertEqual(CalorieBalance.evaluate(mealCount: 1, missingEstimates: 0,
                                              intakeKcal: 1_800, burned: partial, future: false), .unknown)
    }
}
