import Foundation
import HealthKit

enum HealthSyncWindow {
    static func cutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: -12, to: now) ?? now
    }

    static func includes(endAt: Date, since cutoff: Date) -> Bool {
        endAt >= cutoff
    }
}

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
    let image_path: String?
}

private struct ManualMealEstimateUpload: Encodable {
    let id: UUID
    let user_id: UUID
    let meal_id: UUID
    let calories_kcal: Double?
    let protein_g: Double?
    let carbs_g: Double?
    let fat_g: Double?
    let confidence: Double? = nil
    let estimation_metadata = ["source": "manual"]

    private enum CodingKeys: String, CodingKey {
        case id, user_id, meal_id, calories_kcal, protein_g, carbs_g, fat_g,
             confidence, estimation_metadata
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(user_id, forKey: .user_id)
        try values.encode(meal_id, forKey: .meal_id)
        try values.encode(calories_kcal, forKey: .calories_kcal)
        try values.encode(protein_g, forKey: .protein_g)
        try values.encode(carbs_g, forKey: .carbs_g)
        try values.encode(fat_g, forKey: .fat_g)
        try values.encodeNil(forKey: .confidence)
        try values.encode(estimation_metadata, forKey: .estimation_metadata)
    }
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
    let source: String?
}

private struct EnergyDownload: Decodable {
    let external_id: UUID
    let type: String
    let start_at: Date
    let value: Double
    let source: String?
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
    @Published private(set) var isRefreshingValues = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var lastMealSync: Date?
    @Published private(set) var lastValueSync: Date?
    @Published var message: String?
    @Published var mealMessage: String?
    @Published var valueMessage: String?

    private let client = NeonConnection.client
    private let health = HKHealthStore()
    private let batchLimit = 250
    private var mealRefreshQueued = false

    func run(userID: UUID, meals: MealStore, weights: WeightStore, leanMass: LeanMassStore, energy: EnergyStore, profile: ProfileStore,
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
            try await syncEnergy(userID: userID, energy: energy)
            lastValueSync = Date()
            try await syncHeight(userID: userID, profile: profile)
            try await syncHealth(userID: userID)
            lastSuccess = Date()
            UserDefaults.standard.set(lastSuccess, forKey: lastSuccessKey)
            message = "Health data synced."
        } catch {
            message = "Health sync stopped: \(error.localizedDescription). Tap Sync Now to retry."
        }
    }

    func refreshValues(userID: UUID, weights: WeightStore, leanMass: LeanMassStore,
                       energy: EnergyStore) async {
        guard !isRefreshingValues else { return }
        isRefreshingValues = true
        valueMessage = "Refreshing body values…"
        defer { isRefreshingValues = false }
        do {
            try await syncWeights(userID: userID, weights: weights)
            try await syncLeanMass(userID: userID, leanMass: leanMass)
            try await syncEnergy(userID: userID, energy: energy)
            lastValueSync = Date()
            valueMessage = nil
        } catch {
            valueMessage = "Body values could not sync: \(error.localizedDescription). Tap Refresh values to retry."
        }
    }

    func refreshMeals(userID: UUID, meals: MealStore, mealEstimates: MealEstimateStore) async {
        guard !isRefreshingMeals else {
            mealRefreshQueued = true
            return
        }
        let key = "last-meal-sync.\(userID.uuidString)"
        lastMealSync = UserDefaults.standard.object(forKey: key) as? Date
        isRefreshingMeals = true
        mealMessage = "Refreshing meals…"
        defer {
            isRefreshingMeals = false
            if mealRefreshQueued {
                mealRefreshQueued = false
                Task { await refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
            }
        }
        do {
            try await syncMeals(userID: userID, meals: meals)
            try await syncMealEstimates(userID: userID, into: mealEstimates)
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
        let cutoff = HealthSyncWindow.cutoff(now: Date(), calendar: .current)
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .height, .bodyFatPercentage, .leanBodyMass, .stepCount,
            .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
            .heartRate, .restingHeartRate
        ]
        // Prioritize the records missing from History before a large quantity-sample backfill.
        try await sync(type: .workoutType(), userID: userID, since: cutoff)
        let sampleTypes: [HKSampleType] = [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!]
            + quantityIDs.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        for type in sampleTypes {
            try await sync(type: type, userID: userID, since: cutoff)
        }
#endif
    }

    private func sync(type: HKSampleType, userID: UUID, since cutoff: Date) async throws {
        let key = "health-anchor.\(userID.uuidString).\(type.identifier)"
        var anchor = try savedAnchor(for: key)

        while true {
            let batch = try await changes(for: type, after: anchor, since: cutoff)
            if batch.samples.isEmpty && batch.deleted.isEmpty { break }
            let recentSamples = batch.samples.filter {
                HealthSyncWindow.includes(endAt: $0.endDate, since: cutoff)
            }

            if type.identifier == HKObjectType.workoutType().identifier {
                let rows = recentSamples.compactMap { $0 as? HKWorkout }.compactMap { workout -> WorkoutUpload? in
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
                let rows = recentSamples.compactMap { sample -> HealthSampleUpload? in
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

    private func changes(for type: HKSampleType, after anchor: HKQueryAnchor?, since cutoff: Date) async throws
        -> (samples: [HKSample], deleted: [HKDeletedObject], anchor: HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: cutoff, end: nil,
                                                        options: .strictEndDate)
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: batchLimit) {
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
        for meal in remote {
            var imageData: Data?
            if let path = meal.image_path, !path.isEmpty {
                guard path.hasPrefix("\(userID.uuidString.lowercased())/") else {
                    throw SyncError.invalidMealPath
                }
                if meals.needsRemoteImage(id: meal.id, path: path) {
                    imageData = try await NeonMealImages.download(path: path)
                }
            }
            try meals.importRemote(id: meal.id, eatenAt: meal.eaten_at, note: meal.note,
                                   imageData: imageData, imagePath: meal.image_path)
        }
        let remoteIDs = Set(remote.map(\.id))
        for meal in meals.meals where !remoteIDs.contains(meal.id) || meal.pendingUpload {
            var path = meal.remoteImagePath
            if let imageName = meal.imageName, path == nil {
                guard let data = meals.imageData(for: meal) else { throw SyncError.missingMealImage }
                path = "\(userID.uuidString.lowercased())/\(imageName)"
                try await NeonMealImages.upload(path: path!, data: data)
            }
            let row = MealUpload(id: meal.id, user_id: userID, eaten_at: meal.eatenAt,
                                 note: meal.note, image_path: path)
            try await client.from("meals").upsert(row, onConflict: "id").execute()
            try meals.markUploaded(meal, remoteImagePath: path)
        }
    }

    private func syncWeights(userID: UUID, weights: WeightStore) async throws {
        let remote: [ManualMassDownload] = try await client.from("health_samples")
            .select("external_id,start_at,value,source")
            .eq("user_id", value: userID.uuidString)
            .eq("type", value: "app_weight")
            .execute()
            .value
        try weights.merge(remote.map {
            WeightEntry(id: $0.external_id, measuredAt: $0.start_at, kilograms: $0.value,
                        source: $0.source ?? "Cloud", pendingUpload: false)
        })
        let pending = weights.pendingEntries
        let rows = pending.map { entry in
            HealthSampleUpload(
                user_id: userID,
                external_id: entry.id,
                type: "app_weight",
                start_at: entry.measuredAt,
                end_at: entry.measuredAt,
                value: entry.kilograms,
                unit: "kg",
                source: entry.source
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("health_samples")
            .upsert(rows, onConflict: "user_id,external_id")
            .execute()
        try weights.markUploaded(Set(pending.map(\.id)))
    }

    private func syncLeanMass(userID: UUID, leanMass: LeanMassStore) async throws {
        let remote: [ManualMassDownload] = try await client.from("health_samples")
            .select("external_id,start_at,value,source")
            .eq("user_id", value: userID.uuidString)
            .eq("type", value: "app_lean_mass")
            .execute()
            .value
        try leanMass.merge(remote.map {
            LeanMassEntry(id: $0.external_id, measuredAt: $0.start_at, kilograms: $0.value,
                          source: $0.source ?? "Cloud", pendingUpload: false)
        })
        let pending = leanMass.pendingEntries
        let rows = pending.map { entry in
            HealthSampleUpload(
                user_id: userID,
                external_id: entry.id,
                type: "app_lean_mass",
                start_at: entry.measuredAt,
                end_at: entry.measuredAt,
                value: entry.kilograms,
                unit: "kg",
                source: entry.source
            )
        }
        guard !rows.isEmpty else { return }
        try await client.from("health_samples")
            .upsert(rows, onConflict: "user_id,external_id")
            .execute()
        try leanMass.markUploaded(Set(pending.map(\.id)))
    }

    private func syncEnergy(userID: UUID, energy: EnergyStore) async throws {
        var remote: [EnergyEntry] = []
        for kind in EnergyKind.allCases {
            let rows: [EnergyDownload] = try await client.from("health_samples")
                .select("external_id,type,start_at,value,source")
                .eq("user_id", value: userID.uuidString)
                .eq("type", value: kind.rawValue)
                .execute()
                .value
            remote += rows.compactMap { row in
                guard let kind = EnergyKind(rawValue: row.type) else { return nil }
                return EnergyEntry(id: row.external_id, kind: kind, recordedAt: row.start_at,
                                   kilocalories: row.value, source: row.source ?? "Cloud",
                                   pendingUpload: false)
            }
        }
        try energy.merge(remote)
        let pending = energy.pendingEntries
        guard !pending.isEmpty else { return }
        let rows = pending.map { entry in
            HealthSampleUpload(user_id: userID, external_id: entry.id, type: entry.kind.rawValue,
                               start_at: entry.recordedAt, end_at: entry.recordedAt,
                               value: entry.kilocalories, unit: "kcal/day", source: entry.source)
        }
        try await client.from("health_samples")
            .upsert(rows, onConflict: "user_id,external_id")
            .execute()
        try energy.markUploaded(Set(pending.map(\.id)))
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

    private func syncMealEstimates(userID: UUID, into store: MealEstimateStore) async throws {
        let remote: [MealEstimate] = try await client.from("meal_estimates")
            .select("id,meal_id,calories_kcal,protein_g,carbs_g,fat_g,confidence")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        try store.replaceFromCloud(remote)
        let remoteByMeal = Dictionary(uniqueKeysWithValues: remote.map { ($0.meal_id, $0) })
        for estimate in store.pendingEstimates {
            let remoteID = remoteByMeal[estimate.meal_id]?.id ?? estimate.id
            let row = ManualMealEstimateUpload(id: remoteID, user_id: userID,
                                               meal_id: estimate.meal_id,
                                               calories_kcal: estimate.calories_kcal,
                                               protein_g: estimate.protein_g,
                                               carbs_g: estimate.carbs_g, fat_g: estimate.fat_g)
            if remoteByMeal[estimate.meal_id] != nil {
                try await client.from("meal_estimates")
                    .update(row)
                    .eq("id", value: remoteID.uuidString)
                    .eq("user_id", value: userID.uuidString)
                    .execute()
            } else {
                try await client.from("meal_estimates").insert(row).execute()
            }
            try store.markUploaded(estimate, remoteID: remoteID)
        }
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
