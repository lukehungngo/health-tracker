import Foundation
import HealthKit
import Supabase

private struct HealthSampleUpload: Encodable {
    let user_id: UUID
    let external_id: UUID
    let type: String
    let start_at: Date
    let end_at: Date
    let value: Double
    let unit: String
    let source: String
}

private struct WorkoutUpload: Encodable {
    let user_id: UUID
    let healthkit_id: UUID
    let type: String
    let start_at: Date
    let end_at: Date
    let duration_seconds: Double
    let active_energy_kcal: Double?
    let avg_heart_rate: Double?
    let max_heart_rate: Double?
    let source_metadata: WorkoutSourceMetadata
}

private struct WorkoutSourceMetadata: Encodable {
    let healthkit_duration_seconds: Double
    let duration_clamped_to_interval: Bool
}

private struct MealUpload: Encodable {
    let id: UUID
    let user_id: UUID
    let eaten_at: Date
    let note: String
    let image_path: String
}

private struct MealDownload: Decodable {
    let id: UUID
    let eaten_at: Date
    let note: String
    let image_path: String?
}

private struct ManualMassDownload: Decodable {
    let external_id: UUID
    let start_at: Date
    let value: Double
}

private struct HeightDownload: Decodable {
    let external_id: UUID
    let start_at: Date
    let value: Double
}

@MainActor
final class CloudSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var isRefreshingMeals = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastMealSync: Date?
    @Published var message: String?
    @Published var mealMessage: String?

    private let client = SupabaseConnection.client
    private let health = HKHealthStore()
    private let batchLimit = 250

    func run(userID: UUID, meals: MealStore, weights: WeightStore, leanMass: LeanMassStore, profile: ProfileStore,
             mealEstimates: MealEstimateStore) async {
        guard !isSyncing else { return }
        let lastSuccessKey = "last-cloud-sync.\(userID.uuidString)"
        lastSuccess = UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
        isSyncing = true
        message = "Uploading Health data…"
        defer { isSyncing = false }

        // This path is independent of the potentially long HealthKit history upload.
        await refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates)
        do {
            try await syncWeights(userID: userID, weights: weights)
            try await syncLeanMass(userID: userID, leanMass: leanMass)
            try await syncHeight(userID: userID, profile: profile)
            try await syncHealth(userID: userID)
            lastSuccess = Date()
            UserDefaults.standard.set(lastSuccess, forKey: lastSuccessKey)
            message = "Health data synced."
        } catch {
            message = "Health sync stopped: \(error.localizedDescription). Tap Sync Now to retry."
        }
    }

    func refreshMeals(userID: UUID, meals: MealStore, mealEstimates: MealEstimateStore) async {
        guard !isRefreshingMeals else { return }
        let key = "last-meal-sync.\(userID.uuidString)"
        lastMealSync = UserDefaults.standard.object(forKey: key) as? Date
        isRefreshingMeals = true
        mealMessage = "Refreshing meals…"
        defer { isRefreshingMeals = false }
        do {
            try await syncMeals(userID: userID, meals: meals)
            try await pullMealEstimates(userID: userID, into: mealEstimates)
            lastMealSync = Date()
            UserDefaults.standard.set(lastMealSync, forKey: key)
            mealMessage = nil
        } catch {
            mealMessage = "Meal refresh stopped: \(error.localizedDescription). Tap Refresh Meals to retry."
        }
    }

    private func syncHealth(userID: UUID) async throws {
#if targetEnvironment(simulator)
        return
#else
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .height, .bodyFatPercentage, .leanBodyMass, .stepCount,
            .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
            .heartRate, .restingHeartRate
        ]
        // Prioritize the records missing from History before a large quantity-sample backfill.
        try await sync(type: .workoutType(), userID: userID)
        let sampleTypes: [HKSampleType] = [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
            + quantityIDs.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        for type in sampleTypes {
            try await sync(type: type, userID: userID)
        }
#endif
    }

    private func sync(type: HKSampleType, userID: UUID) async throws {
        let key = "health-anchor.\(userID.uuidString).\(type.identifier)"
        var anchor = try savedAnchor(for: key)

        while true {
            let batch = try await changes(for: type, after: anchor)
            if batch.samples.isEmpty && batch.deleted.isEmpty { break }

            if type.identifier == HKObjectType.workoutType().identifier {
                let rows = batch.samples.compactMap { $0 as? HKWorkout }.compactMap { workout -> WorkoutUpload? in
                    let reportedDuration = workout.duration
                    guard reportedDuration.isFinite, reportedDuration >= 0 else { return nil }
                    // The server requires duration <= end-start. Whole-second bounds also
                    // avoid a subsecond JSON/timestamptz rounding mismatch on retry.
                    let startAt = Date(timeIntervalSince1970: floor(workout.startDate.timeIntervalSince1970))
                    let endAt = Date(timeIntervalSince1970: ceil(workout.endDate.timeIntervalSince1970))
                    let duration = min(reportedDuration, max(0, endAt.timeIntervalSince(startAt)))
                    return WorkoutUpload(
                        user_id: userID,
                        healthkit_id: workout.uuid,
                        type: String(workout.workoutActivityType.rawValue),
                        start_at: startAt,
                        end_at: endAt,
                        duration_seconds: duration,
                        active_energy_kcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        avg_heart_rate: nil,
                        max_heart_rate: nil,
                        source_metadata: WorkoutSourceMetadata(
                            healthkit_duration_seconds: reportedDuration,
                            duration_clamped_to_interval: duration < reportedDuration
                        )
                    )
                }
                if !rows.isEmpty {
                    try await client.from("workouts")
                        .upsert(rows, onConflict: "user_id,healthkit_id")
                        .execute()
                }
                for deleted in batch.deleted {
                    try await client.from("workouts")
                        .delete()
                        .eq("user_id", value: userID.uuidString)
                        .eq("healthkit_id", value: deleted.uuid.uuidString)
                        .execute()
                }
            } else {
                let rows = batch.samples.compactMap { sample -> HealthSampleUpload? in
                    if let quantity = sample as? HKQuantitySample {
                        let (unit, unitName) = canonicalUnit(for: quantity.quantityType.identifier)
                        return HealthSampleUpload(
                            user_id: userID,
                            external_id: quantity.uuid,
                            type: quantity.quantityType.identifier,
                            start_at: quantity.startDate,
                            end_at: quantity.endDate,
                            value: quantity.quantity.doubleValue(for: unit),
                            unit: unitName,
                            source: quantity.sourceRevision.source.name
                        )
                    }
                    if let category = sample as? HKCategorySample {
                        return HealthSampleUpload(
                            user_id: userID,
                            external_id: category.uuid,
                            type: category.categoryType.identifier,
                            start_at: category.startDate,
                            end_at: category.endDate,
                            value: Double(category.value),
                            unit: "sleep_stage",
                            source: category.sourceRevision.source.name
                        )
                    }
                    return nil
                }
                if !rows.isEmpty {
                    try await client.from("health_samples")
                        .upsert(rows, onConflict: "user_id,external_id")
                        .execute()
                }
                for deleted in batch.deleted {
                    try await client.from("health_samples")
                        .delete()
                        .eq("user_id", value: userID.uuidString)
                        .eq("external_id", value: deleted.uuid.uuidString)
                        .execute()
                }
            }

            // Commit only after all cloud writes for this batch succeed.
            if let next = batch.anchor {
                let data = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
                UserDefaults.standard.set(data, forKey: key)
                anchor = next
            }
            if batch.samples.count + batch.deleted.count < batchLimit { break }
        }
    }

    private func canonicalUnit(for identifier: String) -> (HKUnit, String) {
        switch identifier {
        case HKQuantityTypeIdentifier.height.rawValue:
            return (.meterUnit(with: .centi), "cm")
        case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return (.gramUnit(with: .kilo), "kg")
        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return (.percent(), "fraction")
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return (.count(), "count")
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return (.kilocalorie(), "kcal")
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return (.meter(), "m")
        case HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.restingHeartRate.rawValue:
            return (.count().unitDivided(by: .minute()), "bpm")
        default:
            preconditionFailure("Unexpected HealthKit quantity type")
        }
    }

    private func savedAnchor(for key: String) throws -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func changes(for type: HKSampleType, after anchor: HKQueryAnchor?) async throws
        -> (samples: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: batchLimit) {
                _, samples, deleted, nextAnchor, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples ?? [], deleted ?? [], nextAnchor))
            }
            health.execute(query)
        }
    }

    private func syncMeals(userID: UUID, meals: MealStore) async throws {
        let remote: [MealDownload] = try await client.from("meals")
            .select("id,eaten_at,note,image_path")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        for meal in remote where !meals.meals.contains(where: { $0.id == meal.id }) {
            var imageData: Data?
            if let path = meal.image_path {
                guard path.hasPrefix("\(userID.uuidString)/") else {
                    throw SyncError.invalidMealPath
                }
                imageData = try await client.storage.from("meal-images").download(path: path)
            }
            try meals.importRemote(id: meal.id, eatenAt: meal.eaten_at, note: meal.note, imageData: imageData)
        }
        let remoteIDs = Set(remote.map(\.id))
        for meal in meals.meals where !remoteIDs.contains(meal.id) {
            guard let data = meals.imageData(for: meal) else {
                throw SyncError.missingMealImage
            }
            guard let imageName = meal.imageName else { throw SyncError.missingMealImage }
            let path = "\(userID.uuidString)/\(imageName)"
            try await client.storage.from("meal-images")
                .upload(path, data: data,
                        options: FileOptions(contentType: "image/jpeg", upsert: true))
            let row = MealUpload(id: meal.id, user_id: userID, eaten_at: meal.eatenAt,
                                 note: meal.note, image_path: path)
            try await client.from("meals").upsert(row).execute()
        }
    }

    private func syncWeights(userID: UUID, weights: WeightStore) async throws {
        let remote: [ManualMassDownload] = try await client.from("health_samples")
            .select("external_id,start_at,value")
            .eq("user_id", value: userID.uuidString)
            .eq("type", value: "app_weight")
            .execute()
            .value
        try weights.merge(remote.map {
            WeightEntry(id: $0.external_id, measuredAt: $0.start_at, kilograms: $0.value)
        })
        let rows = weights.entries.map { entry in
            HealthSampleUpload(
                user_id: userID,
                external_id: entry.id,
                type: "app_weight",
                start_at: entry.measuredAt,
                end_at: entry.measuredAt,
                value: entry.kilograms,
                unit: "kg",
                source: "Health Tracker (manual)"
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("health_samples")
            .upsert(rows, onConflict: "user_id,external_id")
            .execute()
    }

    private func syncLeanMass(userID: UUID, leanMass: LeanMassStore) async throws {
        let remote: [ManualMassDownload] = try await client.from("health_samples")
            .select("external_id,start_at,value")
            .eq("user_id", value: userID.uuidString)
            .eq("type", value: "app_lean_mass")
            .execute()
            .value
        try leanMass.merge(remote.map {
            LeanMassEntry(id: $0.external_id, measuredAt: $0.start_at, kilograms: $0.value)
        })
        let rows = leanMass.entries.map { entry in
            HealthSampleUpload(
                user_id: userID,
                external_id: entry.id,
                type: "app_lean_mass",
                start_at: entry.measuredAt,
                end_at: entry.measuredAt,
                value: entry.kilograms,
                unit: "kg",
                source: "Health Tracker (manual)"
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("health_samples")
            .upsert(rows, onConflict: "user_id,external_id")
            .execute()
    }

    private func syncHeight(userID: UUID, profile: ProfileStore) async throws {
        let remote: [HeightDownload] = try await client.from("health_samples")
            .select("external_id,start_at,value")
            .eq("user_id", value: userID.uuidString)
            .eq("type", value: "app_height")
            .order("start_at", ascending: false)
            .limit(1)
            .execute()
            .value
        try profile.mergeRemote(remote.first.map {
            HeightEntry(id: $0.external_id, measuredAt: $0.start_at, centimeters: $0.value)
        })
        guard let height = profile.manualHeight else { return }
        let row = HealthSampleUpload(
            user_id: userID,
            external_id: height.id,
            type: "app_height",
            start_at: height.measuredAt,
            end_at: height.measuredAt,
            value: height.centimeters,
            unit: "cm",
            source: "Health Tracker (manual)"
        )
        try await client.from("health_samples")
            .upsert(row, onConflict: "user_id,external_id")
            .execute()
    }

    private func pullMealEstimates(userID: UUID, into store: MealEstimateStore) async throws {
        let remote: [MealEstimate] = try await client.from("meal_estimates")
            .select("id,meal_id,calories_kcal,protein_g,carbs_g,fat_g,confidence")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        try store.replaceFromCloud(remote)
    }

    private enum SyncError: LocalizedError {
        case missingMealImage
        case invalidMealPath
        var errorDescription: String? {
            switch self {
            case .missingMealImage: "A saved meal photo is missing on this phone"
            case .invalidMealPath: "A remote meal photo has an unexpected storage path"
            }
        }
    }
}
