import SwiftUI

@MainActor
final class AppServices {
    static let shared = AppServices()
    let health = HealthStore()
    let meals = MealStore()
    let mealEstimates = MealEstimateStore()
    let weights = WeightStore()
    let leanMass = LeanMassStore()
    let profile = ProfileStore()
    let auth = AuthStore()
    let sync = CloudSync()
}

@main
struct HealthTrackerApp: App {
    @UIApplicationDelegateAdaptor(HealthTrackerAppDelegate.self) private var appDelegate
    @StateObject private var health = AppServices.shared.health
    @StateObject private var meals = AppServices.shared.meals
    @StateObject private var mealEstimates = AppServices.shared.mealEstimates
    @StateObject private var weights = AppServices.shared.weights
    @StateObject private var leanMass = AppServices.shared.leanMass
    @StateObject private var profile = AppServices.shared.profile
    @StateObject private var auth = AppServices.shared.auth
    @StateObject private var sync = AppServices.shared.sync

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(health)
                .environmentObject(meals)
                .environmentObject(mealEstimates)
                .environmentObject(weights)
                .environmentObject(leanMass)
                .environmentObject(profile)
                .environmentObject(auth)
                .environmentObject(sync)
        }
    }
}
