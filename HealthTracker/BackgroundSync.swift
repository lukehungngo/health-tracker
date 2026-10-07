import BackgroundTasks
import HealthKit
import UIKit

final class BackgroundSync {
    static let shared = BackgroundSync()
    static let refreshIdentifier = "com.personal.healthtracker.ursehfspdrzpuytymbrn.refresh"

    private let health = HKHealthStore()
    private var observers: [HKObserverQuery] = []

    private var sampleTypes: [HKSampleType] {
        let quantities: [HKQuantityTypeIdentifier] = [
            .bodyFatPercentage, .leanBodyMass, .stepCount,
            .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
            .heartRate, .restingHeartRate
        ]
        return quantities.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
            + [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, .workoutType()]
    }

    func registerAtLaunch() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            self.handle(task)
        }
        scheduleRefresh()
#if targetEnvironment(simulator)
        return
#else
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for type in sampleTypes {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, _ in
                Task { @MainActor in
                    await self.catchUp()
                    completion()
                }
            }
            observers.append(observer)
            health.execute(observer)
        }
#endif
    }

    func enableHealthDelivery() async throws {
#if targetEnvironment(simulator)
        return
#else
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for type in sampleTypes {
            try await health.enableBackgroundDelivery(for: type, frequency: .hourly)
        }
#endif
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            await catchUp()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    @MainActor
    private func catchUp() async {
        let services = AppServices.shared
        await services.auth.restore()
        guard let userID = services.auth.userID else { return }
        await services.sync.run(userID: userID, meals: services.meals, weights: services.weights,
                                waist: services.waist, leanMass: services.leanMass, energy: services.energy,
                                profile: services.profile, mealEstimates: services.mealEstimates)
        await services.proteinTargets.sync(userID: userID)
        await services.health.refresh()
    }
}

final class HealthTrackerAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundSync.shared.registerAtLaunch()
        return true
    }
}
