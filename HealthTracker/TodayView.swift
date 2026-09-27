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
    @State private var showingWeightEntry = false
    @State private var showingLeanMassEntry = false
    @State private var editingEnergy: EnergyKind?

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
                                                            leanMass: leanMass, energy: energy) }
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
                                   detail: "App or AI entry; Apple Health weight is not imported.",
                                   action: { showingWeightEntry = true })
                    editableMetric("Fat-free mass", value: selectedLeanMassKg,
                                   format: "%.1f", unit: "kg", icon: "figure.strengthtraining.traditional",
                                   source: leanMass.entries.first.map { MetricSource.label($0.source) }
                                       ?? (health.today.appleLeanMassKg == nil ? "No value" : "Apple Health"),
                                   recordedAt: leanMass.entries.first?.measuredAt,
                                   detail: "Includes more than skeletal muscle. Check the label on your scale.",
                                   action: { showingLeanMassEntry = true })
                    metric("Steps", value: health.today.steps, format: "%.0f", unit: "steps", icon: "figure.walk")
                    metric("Active energy", value: health.today.activeKcal, format: "%.0f", unit: "kcal", icon: "flame")
                    editableMetric(energy.latest(for: .basal) == nil ? "Basal energy today" : "Estimated basal energy",
                                   value: energy.latest(for: .basal)?.kilocalories ?? health.today.basalKcal,
                                   format: "%.0f", unit: energy.latest(for: .basal) == nil ? "kcal" : "kcal/day",
                                   icon: "bolt.heart",
                                   source: energy.latest(for: .basal).map { MetricSource.label($0.source) }
                                       ?? (health.today.basalKcal == nil ? "No value" : "Apple Health"),
                                   recordedAt: energy.latest(for: .basal)?.recordedAt,
                                   detail: energy.latest(for: .basal) == nil
                                       ? "Apple Health measures today's burn; AI/manual can provide a separate daily estimate."
                                       : "Daily estimate; Apple Health measurements remain unchanged.",
                                   action: { editingEnergy = .basal })
                    editableMetric("Maintenance intake", value: energy.latest(for: .maintenance)?.kilocalories
                                       ?? maintenanceEstimate?.kilocalories,
                                   format: "%.0f", unit: "kcal/day", icon: "equal.circle",
                                   source: energy.latest(for: .maintenance).map { MetricSource.label($0.source) }
                                       ?? (maintenanceEstimate == nil ? "No value" : "Formula"),
                                   recordedAt: energy.latest(for: .maintenance)?.recordedAt,
                                   detail: energy.latest(for: .maintenance) == nil
                                       ? "\(maintenanceEstimate?.formula ?? "Needs body measurements or profile") · seated-day estimate."
                                       : "Latest AI/manual estimate; not measured burn or a weight-loss target.",
                                   action: { editingEnergy = .maintenance })
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
    }

    private var selectedLeanMassKg: Double? {
        leanMass.entries.first?.kilograms ?? health.today.appleLeanMassKg
    }

    private var isAnySyncRunning: Bool {
        sync.isSyncing || sync.isRefreshingValues || sync.isRefreshingMeals || health.isRefreshing
    }

    private var syncError: String? {
        if let error = sync.valueMessage, !sync.isRefreshingValues { return error }
        if let error = sync.mealMessage, !sync.isRefreshingMeals { return error }
        if let error = sync.message, !sync.isSyncing, error != "Health data synced." { return error }
        return health.errorMessage ?? weights.errorMessage
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

    private func editableMetric(_ title: String, value: Double?, format: String, unit: String,
                                icon: String, source: String, recordedAt: Date?, detail: String,
                                action: @escaping () -> Void) -> some View {
        let displayValue = value.map { String(format: format, $0) + " " + unit } ?? "—"
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
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
                Text(displayValue)
                    .font(.title2.bold())
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 4) {
                    Text(source)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    if let recordedAt {
                        Text(recordedAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
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
