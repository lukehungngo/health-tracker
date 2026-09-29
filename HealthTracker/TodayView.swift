import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync
    @EnvironmentObject private var dailyEnergy: DailyEnergyStore
    @EnvironmentObject private var proteinTargets: ProteinTargetStore
    @State private var showingWeightEntry = false
    @State private var showingLeanMassEntry = false
    @State private var editingEnergy: EnergyKind?
    @State private var showingProteinTarget = false
    @State private var selectedMeal: Meal?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                            .fixedSize()
                        Spacer(minLength: 8)
                        Text(auth.userID == nil ? "Sign in to sync" : "Cloud connected")
                            .fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                        Text(auth.userID == nil ? "Sign in to sync" : "Cloud connected")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body & energy").font(.title2.bold())
                        Text(sync.isRefreshingValues || sync.isRefreshingMeals || sync.isSyncing
                             ? "Syncing…"
                             : sync.lastValueSync.map { "Values updated \($0.formatted(date: .omitted, time: .shortened))" }
                               ?? (auth.userID == nil ? "Sign in to sync" : "Values not yet synced"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        if let userID = auth.userID {
                            Task { await sync.refreshValues(userID: userID, weights: weights,
                                                            leanMass: leanMass, energy: energy)
                                await proteinTargets.sync(userID: userID) }
                        }
                    } label: {
                        if sync.isRefreshingValues || sync.isSyncing {
                            ProgressView().frame(minWidth: 44, minHeight: 44)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .accessibilityLabel("Sync body values")
                    .disabled(auth.userID == nil || isAnySyncRunning)
                    Menu {
                        Button("Refresh meals") {
                            if let userID = auth.userID {
                                Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
                            }
                        }
                        Button("Sync all, including Apple Health") {
                            Task {
                                await health.refresh()
                                if let userID = auth.userID {
                                    await sync.run(userID: userID, meals: meals, weights: weights,
                                                   leanMass: leanMass, energy: energy, profile: profile,
                                                   mealEstimates: mealEstimates)
                                    await dailyEnergy.loadMonth(.now, userID: userID, force: true)
                                    await proteinTargets.sync(userID: userID)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("More sync options")
                    .disabled(auth.userID == nil || isAnySyncRunning)
                }
                if let syncError {
                    Label(syncError, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                VStack(spacing: 12) {
                    editableMetric("Weight", value: weights.entries.first?.kilograms,
                                   format: "%.1f", unit: "kg", icon: "scalemass",
                                   source: weights.entries.first.map { MetricSource.label($0.source) } ?? "No value",
                                   recordedAt: weights.entries.first?.measuredAt,
                                   action: { showingWeightEntry = true })
                    metric("Steps", value: health.today.steps, format: "%.0f", unit: "steps", icon: "figure.walk")
                    metric("Active energy", value: health.today.activeKcal, format: "%.0f", unit: "kcal", icon: "flame")
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        let burned = dailyEnergy.summary(for: timeline.date, now: timeline.date,
                                                         weights: weights.entries)
                        VStack(alignment: .leading, spacing: 4) {
                            metric("Total calories burned", value: burned?.totalKcal,
                                   format: "%.0f", unit: "kcal", icon: "flame.circle")
                            if let burned {
                                Text("\(Int(burned.measuredKcal)) recorded · \(Int(burned.estimatedKcal)) estimated for missing hours")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if burned.isPartial {
                                    Text("Some hours need an earlier app-entered weight to estimate.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        metric("Estimated calorie intake", value: estimatedCaloriesToday,
                               format: "%.0f", unit: "kcal", icon: "fork.knife")
                        if missingCaloriesToday > 0 {
                            Text("\(missingCaloriesToday) meal\(missingCaloriesToday == 1 ? "" : "s") missing a calorie estimate")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        metric("Estimated protein intake", value: estimatedProteinToday,
                               format: "%.1f", unit: "g", icon: "circle.grid.2x2")
                        if missingProteinToday > 0 {
                            Text("\(missingProteinToday) meal\(missingProteinToday == 1 ? "" : "s") missing a protein estimate")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    editableMetric("Fat-free mass", value: selectedLeanMassKg,
                                   format: "%.1f", unit: "kg", icon: "figure.strengthtraining.traditional",
                                   source: leanMass.entries.first.map { MetricSource.label($0.source) }
                                       ?? (health.today.appleLeanMassKg == nil ? "No value" : "Apple Health"),
                                   recordedAt: leanMass.entries.first?.measuredAt,
                                   action: { showingLeanMassEntry = true })
                    editableMetric(energy.latest(for: .basal) == nil ? "Basal energy today" : "Estimated basal energy",
                                   value: energy.latest(for: .basal)?.kilocalories ?? health.today.basalKcal,
                                   format: "%.0f", unit: energy.latest(for: .basal) == nil ? "kcal" : "kcal/day",
                                   icon: "bolt.heart",
                                   source: energy.latest(for: .basal).map { MetricSource.label($0.source) }
                                       ?? (health.today.basalKcal == nil ? "No value" : "Apple Health"),
                                   recordedAt: energy.latest(for: .basal)?.recordedAt,
                                   action: { editingEnergy = .basal })
                    editableMetric("Maintenance intake", value: maintenanceTarget?.kilocalories
                                       ?? maintenanceEstimate?.kilocalories,
                                   format: "%.0f", unit: "kcal/day", icon: "equal.circle",
                                   source: maintenanceTarget.map { MetricSource.label($0.source) }
                                       ?? (maintenanceEstimate == nil ? "No value" : "Formula"),
                                   recordedAt: maintenanceTarget?.recordedAt,
                                   action: { editingEnergy = .maintenance })
                    editableMetric("Protein target",
                                   displayValue: proteinTargetDisplay,
                                   icon: "figure.strengthtraining.traditional",
                                   source: proteinTargets.latest.map { MetricSource.label($0.source) }
                                       ?? (proteinRange == nil ? "No value" : "Formula"),
                                   recordedAt: proteinTargets.latest?.recordedAt,
                                   action: { showingProteinTarget = true })
                    metric("Workouts", value: health.today.workoutMinutes, format: "%.0f", unit: "min", icon: "figure.run")
                    metric("Sleep (last 24h)", value: health.today.sleepMinutes, format: "%.0f", unit: "min", icon: "moon")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Meals logged today")
                        .font(.headline)
                    if todayMeals.isEmpty {
                        Text("No meals yet. Use Add Meal to save a note, photo, or both.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todayMeals) { meal in
                            Button {
                                selectedMeal = meal
                            } label: {
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
                                        Text("\(estimate.calories_kcal.map { "~\(Int($0)) kcal" } ?? "Kcal not entered")\(estimate.protein_g.map { " · ~\($0.formatted(.number.precision(.fractionLength(0...1)))) g protein" } ?? "") · estimate")
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
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .accessibilityLabel("View meal log: \(meal.note.isEmpty ? "Photo only" : meal.note)")
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
        .onChange(of: sync.lastSuccess) { _, _ in
            if let userID = auth.userID {
                Task { await dailyEnergy.loadMonth(.now, userID: userID, force: true) }
            }
        }
        .sheet(isPresented: $showingWeightEntry) {
            AddWeightView()
                .environmentObject(weights)
                .environmentObject(leanMass)
                .environmentObject(energy)
                .environmentObject(profile)
                .environmentObject(meals)
                .environmentObject(mealEstimates)
                .environmentObject(auth)
                .environmentObject(sync)
        }
        .sheet(isPresented: $showingLeanMassEntry) {
            AddLeanMassView()
                .environmentObject(leanMass)
                .environmentObject(energy)
                .environmentObject(weights)
                .environmentObject(profile)
                .environmentObject(meals)
                .environmentObject(mealEstimates)
                .environmentObject(auth)
                .environmentObject(sync)
        }
        .sheet(item: $editingEnergy) { kind in
            AddEnergyView(kind: kind)
                .environmentObject(energy)
                .environmentObject(weights)
                .environmentObject(leanMass)
                .environmentObject(auth)
                .environmentObject(sync)
        }
        .sheet(isPresented: $showingProteinTarget) {
            AddProteinTargetView()
                .environmentObject(proteinTargets)
                .environmentObject(auth)
        }
        .sheet(item: $selectedMeal) { meal in
            MealDetailView(mealID: meal.id)
        }
    }

    private var selectedLeanMassKg: Double? {
        leanMass.entries.first?.kilograms ?? health.today.appleLeanMassKg
    }

    private var todayMeals: [Meal] {
        meals.meals.filter { Calendar.current.isDateInToday($0.eatenAt) }
    }

    private var missingCaloriesToday: Int {
        mealEstimates.unestimatedCount(for: todayMeals)
    }

    private var missingProteinToday: Int {
        mealEstimates.missingProteinCount(for: todayMeals)
    }

    private var estimatedCaloriesToday: Double? {
        todayMeals.count > missingCaloriesToday ? mealEstimates.totalCalories(for: todayMeals) : nil
    }

    private var estimatedProteinToday: Double? {
        todayMeals.count > missingProteinToday ? mealEstimates.totalProtein(for: todayMeals) : nil
    }

    private var isAnySyncRunning: Bool {
        sync.isSyncing || sync.isRefreshingValues || sync.isRefreshingMeals ||
            proteinTargets.isSyncing || health.isRefreshing
    }

    private var syncError: String? {
        if let error = sync.valueMessage, !sync.isRefreshingValues { return error }
        if let error = sync.mealMessage, !sync.isRefreshingMeals { return error }
        if let error = sync.message, !sync.isSyncing, error != "Health data synced." { return error }
        return proteinTargets.errorMessage ?? health.errorMessage ?? weights.errorMessage
    }

    private var maintenanceEstimate: MaintenanceEstimate? {
        MaintenanceEnergy.dailyEstimate(
            leanMassKg: selectedLeanMassKg,
            weightKg: weights.entries.first?.kilograms,
            heightCm: profile.selectedHeightCm(appleHeightCm: health.today.appleHeightCm),
            birthDate: profile.selectedBirthDate(appleBirthDate: health.today.appleBirthDate),
            gender: profile.selectedGender(appleGender: health.today.appleGender)
        )
    }

    private var maintenanceTarget: EnergyEntry? {
        energy.effective(for: .maintenance, on: .now)
    }

    private var proteinRange: ProteinRange? {
        ProteinRecommendation.dailyRange(leanMassKg: selectedLeanMassKg,
                                         weightKg: weights.entries.first?.kilograms)
    }

    private var proteinTargetDisplay: String {
        if let entry = proteinTargets.latest {
            return "\(Int(entry.minGrams.rounded()))–\(Int(entry.maxGrams.rounded())) g/day"
        }
        guard let range = proteinRange else { return "—" }
        return "\(Int(range.lowerGrams.rounded()))–\(Int(range.upperGrams.rounded())) g/day"
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

    private func editableMetric(_ title: String, value: Double?, format: String, unit: String,
                                icon: String, source: String, recordedAt: Date?,
                                action: @escaping () -> Void) -> some View {
        let displayValue = value.map { String(format: format, $0) + " " + unit } ?? "—"
        return editableMetric(title, displayValue: displayValue, icon: icon,
                              source: source, recordedAt: recordedAt, action: action)
    }

    private func editableMetric(_ title: String, displayValue: String, icon: String,
                                source: String, recordedAt: Date?,
                                action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon)
                        .frame(width: 28)
                        .foregroundStyle(.teal)
                        .accessibilityHidden(true)
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.teal)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    Text(source)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    if let recordedAt {
                        Text("Updated \(recordedAt.formatted(.dateTime.day().month().hour().minute()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Text(displayValue)
                    .font(.title2.bold())
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(displayValue), source \(source)")
        .accessibilityHint("Opens the form to log a new value")
    }
}
