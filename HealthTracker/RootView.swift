import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var waist: WaistStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync
    @EnvironmentObject private var dailyEnergy: DailyEnergyStore
    @EnvironmentObject private var proteinTargets: ProteinTargetStore
    @State private var selectedTab = 0
    @State private var historyDate = Date()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView()
            }
            .tabItem { Label("Today", systemImage: "heart.text.square") }
            .tag(0)

            NavigationStack {
                AddMealView()
            }
            .tabItem { Label("Add Meal", systemImage: "camera") }
            .tag(1)

            NavigationStack {
                CalendarView { date in
                    historyDate = date
                    selectedTab = 3
                }
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(2)

            NavigationStack {
                HistoryView(selectedDate: $historyDate)
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(4)
        }
        .tint(.teal)
        .task {
            try? weights.loadIfNeeded()
            try? waist.loadIfNeeded()
            await auth.restore()
            await health.refresh()
            if let userID = auth.userID {
                await sync.run(userID: userID, meals: meals, weights: weights, waist: waist, leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
                await dailyEnergy.loadMonth(.now, userID: userID, force: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                try? weights.loadIfNeeded()
                try? waist.loadIfNeeded()
                if let userID = auth.userID {
                    Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            try? weights.loadIfNeeded()
            try? waist.loadIfNeeded()
        }
        .onChange(of: auth.userID) { _, userID in
            if let userID {
                Task {
                    await proteinTargets.sync(userID: userID)
                    await dailyEnergy.loadMonth(.now, userID: userID)
                }
            } else {
                dailyEnergy.clear()
            }
        }
    }
}
