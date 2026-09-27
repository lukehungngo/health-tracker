import Foundation
import HealthKit

struct TodaySnapshot {
    var appleHeightCm: Double?
    var appleLeanMassKg: Double?
    var appleBirthDate: Date?
    var appleSex: FormulaSex?
    var steps: Double?
    var activeKcal: Double?
    var basalKcal: Double?
    var workoutMinutes: Double?
    var sleepMinutes: Double?
}

@MainActor
final class HealthStore: ObservableObject {
    @Published private(set) var today = TodaySnapshot()
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let store = HKHealthStore()

    var isAvailable: Bool {
#if targetEnvironment(simulator)
        false
#else
        HKHealthStore.isHealthDataAvailable()
#endif
    }

    private var readTypes: Set<HKObjectType> {
        let quantityIds: [HKQuantityTypeIdentifier] = [
            .height, .bodyFatPercentage, .leanBodyMass, .stepCount,
            .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
            .heartRate, .restingHeartRate
        ]
        var types = Set<HKObjectType>(quantityIds.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            .map { $0 as HKObjectType })
        types.insert(HKObjectType.workoutType())
        types.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .biologicalSex)!)
        return types
    }

    func requestAccess() async {
        guard isAvailable else {
            errorMessage = "Health data is unavailable on this device."
            return
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: HealthError.authorizationFailed) }
                }
            }
            var deliveryWarning: String?
            do {
                try await BackgroundSync.shared.enableHealthDelivery()
            } catch {
                deliveryWarning = "Health access granted, but background delivery could not be enabled: \(error.localizedDescription)"
            }
            await refresh()
            if errorMessage == nil { errorMessage = deliveryWarning }
        } catch {
            errorMessage = "Health access could not be requested: \(error.localizedDescription)"
        }
    }

    func refresh() async {
#if targetEnvironment(simulator)
        // An unsigned Simulator build cannot receive the HealthKit entitlement.
        // Cloud meals and History remain testable without presenting a false device error.
        return
#else
        guard isAvailable else {
            errorMessage = "Health data is unavailable on this device."
            return
        }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        let start = Calendar.current.startOfDay(for: Date())
        let end = Date()
        do {
            today = TodaySnapshot(
                appleHeightCm: try await latestQuantity(.height, unit: .meterUnit(with: .centi)),
                appleLeanMassKg: try await latestQuantity(.leanBodyMass, unit: .gramUnit(with: .kilo)),
                appleBirthDate: (try? store.dateOfBirthComponents()).flatMap { Calendar.current.date(from: $0) },
                appleSex: Self.formulaSex(from: try? store.biologicalSex().biologicalSex),
                steps: try await sum(.stepCount, unit: .count(), from: start, to: end),
                activeKcal: try await sum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end),
                basalKcal: try await sum(.basalEnergyBurned, unit: .kilocalorie(), from: start, to: end),
                workoutMinutes: try await workoutMinutes(from: start, to: end),
                sleepMinutes: try await sleepMinutes(from: end.addingTimeInterval(-24 * 60 * 60), to: end)
            )
            lastRefresh = Date()
        } catch {
            errorMessage = "Health data could not be refreshed: \(error.localizedDescription)"
        }
#endif
    }

    private static func formulaSex(from value: HKBiologicalSex?) -> FormulaSex? {
        switch value {
        case .male: .male
        case .female: .female
        default: nil
        }
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        let type = HKObjectType.quantityType(forIdentifier: id)!
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let sample = samples?.first as? HKQuantitySample
                continuation.resume(returning: sample?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async throws -> Double? {
        let type = HKObjectType.quantityType(forIdentifier: id)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func workoutMinutes(from start: Date, to end: Date) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
                continuation.resume(returning: workouts.isEmpty ? nil : workouts.reduce(0) { $0 + $1.duration } / 60)
            }
            store.execute(query)
        }
    }

    private func sleepMinutes(from start: Date, to end: Date) async throws -> Double? {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let asleep: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ]
                let intervals = (samples ?? []).compactMap { $0 as? HKCategorySample }
                    .filter { asleep.contains($0.value) }
                    .map { (max($0.startDate, start), min($0.endDate, end)) }
                    .filter { $0.0 < $0.1 }
                    .sorted { $0.0 < $1.0 }
                var seconds: TimeInterval = 0
                var coveredUntil = start
                for (begin, finish) in intervals {
                    if finish > coveredUntil {
                        seconds += finish.timeIntervalSince(max(begin, coveredUntil))
                        coveredUntil = finish
                    }
                }
                let minutes = seconds / 60
                continuation.resume(returning: minutes == 0 ? nil : minutes)
            }
            store.execute(query)
        }
    }

    private enum HealthError: Error { case authorizationFailed }
}
