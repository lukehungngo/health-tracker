import HealthKit
import Supabase
import SwiftUI

private struct SyncedWorkout: Decodable, Identifiable {
    let id: UUID
    let start_at: Date
    let duration_seconds: Double
}

private struct SyncedSleep: Decodable {
    let start_at: Date
    let end_at: Date
    let value: Double
}

struct HistoryView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var sync: CloudSync

    @State private var selectedDate = Date()
    @State private var workouts: [SyncedWorkout] = []
    @State private var sleepMinutes: Double?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeLoadID: UUID?

    private var dayMeals: [Meal] {
        meals.meals.filter { Calendar.current.isDate($0.eatenAt, inSameDayAs: selectedDate) }
    }

    private var dayWeights: [WeightEntry] {
        weights.entries.filter { Calendar.current.isDate($0.measuredAt, inSameDayAs: selectedDate) }
    }

    private var dayLeanMass: [LeanMassEntry] {
        leanMass.entries.filter { Calendar.current.isDate($0.measuredAt, inSameDayAs: selectedDate) }
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                Button {
                    Task {
                        if let userID = auth.userID {
                            await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates)
                        }
                        await load()
                    }
                } label: {
                    Label("Refresh this day", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || sync.isRefreshingMeals || auth.userID == nil)
            } footer: {
                Text("Meals refresh independently of a long HealthKit upload. Workouts and recorded sleep are read from Supabase for the selected day; use Sync Now in Settings if HealthKit history is still uploading.")
            }

            if isLoading { ProgressView("Loading history") }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            Section("Weight entered in this app") {
                if dayWeights.isEmpty {
                    Text("No weight entered for this date.").foregroundStyle(.secondary)
                } else {
                    ForEach(dayWeights) { entry in
                        LabeledContent(entry.measuredAt.formatted(date: .omitted, time: .shortened),
                                       value: "\(entry.kilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                    }
                }
            }

            Section("Lean body mass entered in this app") {
                if dayLeanMass.isEmpty {
                    Text("No lean mass entered for this date.").foregroundStyle(.secondary)
                } else {
                    ForEach(dayLeanMass) { entry in
                        LabeledContent(entry.measuredAt.formatted(date: .omitted, time: .shortened),
                                       value: "\(entry.kilograms.formatted(.number.precision(.fractionLength(1)))) kg")
                    }
                }
            }

            Section("Meals") {
                if dayMeals.isEmpty {
                    Text("No meal logged for this date.").foregroundStyle(.secondary)
                } else {
                    Text("Estimated eaten: \(Int(mealEstimates.totalCalories(for: dayMeals))) kcal · \(mealEstimates.totalProtein(for: dayMeals).formatted(.number.precision(.fractionLength(0...1)))) g protein")
                    let pending = mealEstimates.unestimatedCount(for: dayMeals)
                    if pending > 0 {
                        Text("\(pending) meal\(pending == 1 ? "" : "s") awaiting analysis")
                            .foregroundStyle(.secondary)
                    }
                    let missingProtein = mealEstimates.missingProteinCount(for: dayMeals)
                    if missingProtein > 0 {
                        Text("Protein total is partial: \(missingProtein) meal\(missingProtein == 1 ? "" : "s") missing a protein estimate")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dayMeals) { meal in
                        HStack(spacing: 12) {
                            if let image = meals.image(for: meal) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
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
                                }
                            }
                        }
                    }
                }
            }

            Section("Workouts") {
                if workouts.isEmpty {
                    Text("No synced workout for this date.").foregroundStyle(.secondary)
                } else {
                    ForEach(workouts) { workout in
                        LabeledContent(workout.start_at.formatted(date: .omitted, time: .shortened),
                                       value: "\(Int(workout.duration_seconds / 60)) min")
                    }
                }
            }

            Section("Sleep ending on this date") {
                if let sleepMinutes {
                    LabeledContent("Recorded asleep time", value: "\(Int(sleepMinutes)) min")
                } else {
                    Text("No synced sleep stages for this night.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("History")
        .task(id: Calendar.current.startOfDay(for: selectedDate)) { await load() }
    }

    private func load() async {
        guard let userID = auth.userID else {
            workouts = []
            sleepMinutes = nil
            errorMessage = "Sign in under Settings to read cloud history."
            return
        }
        isLoading = true
        errorMessage = nil
        let loadID = UUID()
        activeLoadID = loadID
        defer { if activeLoadID == loadID { isLoading = false } }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let sleepStart = calendar.date(byAdding: .hour, value: -12, to: start),
              let sleepEnd = calendar.date(byAdding: .hour, value: 12, to: start) else { return }
        do {
            let loadedWorkouts: [SyncedWorkout] = try await SupabaseConnection.client.from("workouts")
                .select("id,start_at,duration_seconds")
                .eq("user_id", value: userID.uuidString)
                .gte("start_at", value: start.ISO8601Format())
                .lt("start_at", value: end.ISO8601Format())
                .order("start_at", ascending: false)
                .execute()
                .value
            let loadedSleep: [SyncedSleep] = try await SupabaseConnection.client.from("health_samples")
                .select("start_at,end_at,value")
                .eq("user_id", value: userID.uuidString)
                .eq("type", value: HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
                .lt("start_at", value: sleepEnd.ISO8601Format())
                .gt("end_at", value: sleepStart.ISO8601Format())
                .execute()
                .value
            guard !Task.isCancelled, activeLoadID == loadID else { return }
            workouts = loadedWorkouts
            sleepMinutes = Self.asleepMinutes(loadedSleep, from: sleepStart, to: sleepEnd)
        } catch {
            guard !Task.isCancelled, activeLoadID == loadID, !(error is CancellationError) else { return }
            workouts = []
            sleepMinutes = nil
            errorMessage = "Cloud history could not be loaded: \(error.localizedDescription)"
        }
    }

    private static func asleepMinutes(_ samples: [SyncedSleep], from start: Date, to end: Date) -> Double? {
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        let intervals = samples.filter { asleep.contains(Int($0.value)) }
            .map { (max($0.start_at, start), min($0.end_at, end)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var seconds: TimeInterval = 0
        var coveredUntil = start
        for (begin, finish) in intervals where finish > coveredUntil {
            seconds += finish.timeIntervalSince(max(begin, coveredUntil))
            coveredUntil = finish
        }
        return seconds == 0 ? nil : seconds / 60
    }
}
