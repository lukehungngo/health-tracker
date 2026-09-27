import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync
    @State private var showingWeightEntry = false
    @State private var showingLeanMassEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Today")
                        .font(.largeTitle.bold())
                    Text(auth.userID == nil ? "Sign in under Settings to sync with Supabase." : "Connected to Supabase")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let error = health.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let error = weights.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last Health refresh")
                        .font(.headline)
                    Text(health.lastRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet refreshed")
                        .foregroundStyle(.secondary)
                    Text("Last Health upload: \(auth.userID == nil ? "Not signed in" : sync.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet completed")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Last meal refresh: \(auth.userID == nil ? "Not signed in" : sync.lastMealSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet refreshed")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let message = sync.message { Text(message).font(.subheadline) }
                    if let message = sync.mealMessage { Text(message).font(.subheadline) }
                    Button {
                        Task {
                            await health.refresh()
                            if let userID = auth.userID { await sync.run(userID: userID, meals: meals, weights: weights, leanMass: leanMass, profile: profile, mealEstimates: mealEstimates) }
                        }
                    } label: {
                        if health.isRefreshing { ProgressView() }
                        else { Label("Refresh and Sync", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(health.isRefreshing || sync.isSyncing)
                    .frame(minHeight: 44)
                    if let userID = auth.userID {
                        Button {
                            Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
                        } label: {
                            Label("Refresh meals", systemImage: "fork.knife")
                        }
                        .disabled(sync.isRefreshingMeals)
                        .frame(minHeight: 44)
                    }
                }

                VStack(spacing: 12) {
                    metric("Latest weight (entered here)", value: weights.entries.first?.kilograms, format: "%.1f", unit: "kg", icon: "scalemass")
                    if let latest = weights.entries.first {
                        Text("Recorded \(latest.measuredAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        showingWeightEntry = true
                    } label: {
                        Label("Log weight", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    metric("Lean body mass (fat-free)", value: selectedLeanMassKg,
                           format: "%.1f", unit: "kg", icon: "figure.strengthtraining.traditional")
                    Text(leanMass.entries.first != nil ? "Source: entered in this app" :
                            (health.today.appleLeanMassKg != nil ? "Source: Apple Health" : "No lean-mass measurement yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        showingLeanMassEntry = true
                    } label: {
                        Label("Log lean mass", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    metric("Steps", value: health.today.steps, format: "%.0f", unit: "steps", icon: "figure.walk")
                    metric("Active energy", value: health.today.activeKcal, format: "%.0f", unit: "kcal", icon: "flame")
                    metric("Basal energy", value: health.today.basalKcal, format: "%.0f", unit: "kcal", icon: "bolt.heart")
                    metric("Estimated intake to maintain", value: maintenanceEstimate?.kilocalories,
                           format: "%.0f", unit: "kcal/day", icon: "equal.circle")
                    Text("Formula: \(maintenanceEstimate?.formula ?? "needs lean mass, or weight + height + birth date + sex"). Mostly seated-day estimate; not measured burn or a weight-loss target.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let proteinRange {
                        Text("Protein reference to retain lean mass: \(Int(proteinRange.lowerGrams.rounded()))–\(Int(proteinRange.upperGrams.rounded())) g/day")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(proteinRange.basis), for regular resistance training during a calorie deficit. A reference range, not a medical prescription.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    metric("Workouts", value: health.today.workoutMinutes, format: "%.0f", unit: "min", icon: "figure.run")
                    metric("Sleep (last 24h)", value: health.today.sleepMinutes, format: "%.0f", unit: "min", icon: "moon")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Meals logged today")
                        .font(.headline)
                    let todayMeals = meals.meals.filter { Calendar.current.isDateInToday($0.eatenAt) }
                    if todayMeals.isEmpty {
                        Text("No meals yet. Use Add Meal to save a photo and optional note.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Estimated eaten so far: \(Int(mealEstimates.totalCalories(for: todayMeals))) kcal · \(mealEstimates.totalProtein(for: todayMeals).formatted(.number.precision(.fractionLength(0...1)))) g protein")
                            .font(.headline)
                        let pending = mealEstimates.unestimatedCount(for: todayMeals)
                        if pending > 0 {
                            Text("\(pending) meal\(pending == 1 ? "" : "s") without a calorie estimate")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        let missingProtein = mealEstimates.missingProteinCount(for: todayMeals)
                        if missingProtein > 0 {
                            Text("Protein total is partial: \(missingProtein) meal\(missingProtein == 1 ? "" : "s") missing a protein estimate")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(todayMeals) { meal in
                            HStack(spacing: 12) {
                                if let image = meals.image(for: meal) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .accessibilityHidden(true)
                                }
                                VStack(alignment: .leading) {
                                    Text(meal.eatenAt, format: .dateTime.hour().minute())
                                        .font(.subheadline.bold())
                                    Text(meal.note.isEmpty ? "Photo only" : meal.note)
                                        .lineLimit(2)
                                    if let estimate = mealEstimates.estimate(for: meal.id) {
                                        Text("~\(Int(estimate.calories_kcal)) kcal\(estimate.protein_g.map { " · ~\($0.formatted(.number.precision(.fractionLength(0...1)))) g protein" } ?? "") · estimate")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("Awaiting analysis")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingWeightEntry) {
            AddWeightView()
                .environmentObject(weights)
                .environmentObject(leanMass)
                .environmentObject(profile)
                .environmentObject(meals)
                .environmentObject(mealEstimates)
                .environmentObject(auth)
                .environmentObject(sync)
        }
        .sheet(isPresented: $showingLeanMassEntry) {
            AddLeanMassView()
                .environmentObject(leanMass)
                .environmentObject(weights)
                .environmentObject(profile)
                .environmentObject(meals)
                .environmentObject(mealEstimates)
                .environmentObject(auth)
                .environmentObject(sync)
        }
    }

    private var selectedLeanMassKg: Double? {
        leanMass.entries.first?.kilograms ?? health.today.appleLeanMassKg
    }

    private var maintenanceEstimate: MaintenanceEstimate? {
        MaintenanceEnergy.dailyEstimate(
            leanMassKg: selectedLeanMassKg,
            weightKg: weights.entries.first?.kilograms,
            heightCm: profile.selectedHeightCm(appleHeightCm: health.today.appleHeightCm),
            birthDate: profile.selectedBirthDate(appleBirthDate: health.today.appleBirthDate),
            sex: profile.selectedSex(appleSex: health.today.appleSex)
        )
    }

    private var proteinRange: ProteinRange? {
        ProteinRecommendation.dailyRange(leanMassKg: selectedLeanMassKg,
                                         weightKg: weights.entries.first?.kilograms)
    }

    private func metric(_ title: String, value: Double?, format: String, unit: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value.map { String(format: format, $0) + " " + unit } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(16)
        .frame(minHeight: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
