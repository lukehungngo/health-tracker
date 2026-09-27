import SwiftUI

struct RootView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    var body: some View {
        TabView {
            NavigationStack {
                TodayView()
            }
            .tabItem { Label("Today", systemImage: "heart.text.square") }

            NavigationStack {
                AddMealView()
            }
            .tabItem { Label("Add Meal", systemImage: "camera") }

            NavigationStack {
                HistoryView()
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.teal)
        .task {
            await auth.restore()
            await health.refresh()
            if let userID = auth.userID {
                await sync.run(userID: userID, meals: meals, weights: weights, leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
            }
        }
        .onOpenURL { url in
            Task {
                await auth.handleCallback(url)
                if let userID = auth.userID {
                    await sync.run(userID: userID, meals: meals, weights: weights, leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
                }
            }
        }
    }
}
