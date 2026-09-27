import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var dailyEnergy: DailyEnergyStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var sync: CloudSync
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onSelectDate: (Date) -> Void
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now))!

    private var calendar: Calendar { .current }
    private var days: [Date] {
        guard let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
    }
    private var leadingDays: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button { changeMonth(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous month")
                    Spacer()
                    Text(month, format: .dateTime.month(.wide).year())
                        .font(.title2.bold())
                    Spacer()
                    Button { changeMonth(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Next month")
                    .disabled(calendar.compare(month, to: .now, toGranularity: .month) != .orderedAscending)
                }
                .tint(.teal)

                HStack(spacing: 12) {
                    Text("↓ Intake")
                    Text("↑ Burned")
                    Text("— No meal log")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("− Deficit")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.green.opacity(0.16), in: Capsule())
                    Text("+ Surplus")
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.red.opacity(0.16), in: Capsule())
                }
                .font(.caption)

                if dailyEnergy.isLoading { ProgressView("Loading energy") }
                if let error = dailyEnergy.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                }

                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            ForEach(days, id: \.self) { date in
                                dayButton(date, now: timeline.date, compact: false)
                            }
                        }
                    } else {
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(0..<7, id: \.self) { index in
                                Text(weekdayName(index))
                                    .font(.caption2.bold())
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(0..<leadingDays, id: \.self) { _ in Color.clear.frame(height: 72) }
                            ForEach(days, id: \.self) { date in
                                dayButton(date, now: timeline.date, compact: true)
                            }
                        }
                    }
                }
                if auth.userID == nil {
                    Text("Sign in under Settings to load burned energy.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Intake is logged meals, not the maintenance target. Burned combines recorded energy with estimates for uncovered hours (00:00–07:00 assumed sleep, otherwise seated activity). Today ends at the current time. Tap a date for its breakdown and effective target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Calendar")
        .refreshable { await refresh() }
        .task(id: month) {
            if let userID = auth.userID {
                await dailyEnergy.loadMonth(month, userID: userID)
            }
        }
        .onChange(of: sync.lastSuccess) { _, _ in
            if let userID = auth.userID {
                Task { await dailyEnergy.loadMonth(month, userID: userID, force: true) }
            }
        }
    }

    private func dayButton(_ date: Date, now: Date, compact: Bool) -> some View {
        let dayMeals = meals.meals.filter { calendar.isDate($0.eatenAt, inSameDayAs: date) }
        let intake = mealEstimates.totalCalories(for: dayMeals)
        let pending = mealEstimates.unestimatedCount(for: dayMeals)
        let outtake = dailyEnergy.summary(for: date, now: now, weights: weights.entries)
        let future = date > now
        let balance = CalorieBalance.evaluate(mealCount: dayMeals.count, missingEstimates: pending,
                                              intakeKcal: intake, burned: outtake,
                                              future: future).direction
        let background = balance < 0 ? Color.green.opacity(0.16)
            : balance > 0 ? Color.red.opacity(0.16)
            : calendar.isDateInToday(date) ? Color.teal.opacity(0.15)
            : Color(.secondarySystemGroupedBackground)
        let balanceLabel = balance < 0 ? "deficit" : balance > 0 ? "surplus" : "unclassified"
        let intakeText = dayMeals.isEmpty ? "—" : shortKcal(intake)
        let outtakeText = outtake.map { shortKcal($0.totalKcal) } ?? "—"
        return Button { onSelectDate(date) } label: {
            if compact {
                VStack(spacing: 3) {
                    HStack(spacing: 1) {
                        Text(date, format: .dateTime.day())
                        if balance != 0 { Text(balance < 0 ? "−" : "+") }
                    }
                    .font(.caption.bold())
                    Text(future ? "" : "↓\(intakeText)")
                        .foregroundStyle(.primary)
                    Text(future ? "" : "↑\(outtakeText)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack {
                    Text(date, format: .dateTime.weekday(.abbreviated).day()).fontWeight(.semibold)
                    Spacer()
                    Text(future ? "" : "↓ \(intakeText) · ↑ \(outtakeText) kcal \(balance < 0 ? "− deficit" : balance > 0 ? "+ surplus" : "")")
                        .monospacedDigit()
                }
                .frame(minHeight: 48)
                .padding(.horizontal, 12)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted)). \(dayMeals.isEmpty ? "No meal log" : "Intake \(Int(intake)) kilocalories\(pending > 0 ? ", incomplete" : "")"). Burned \(outtake.map { "\(Int($0.totalKcal)) kilocalories, including \(Int($0.estimatedKcal)) estimated" } ?? "not loaded"). Balance \(balanceLabel). Open history.")
    }

    private func shortKcal(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fk", value / 1000) : String(Int(value))
    }

    private func weekdayName(_ index: Int) -> String {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return symbols[(calendar.firstWeekday - 1 + index) % 7]
    }

    private func changeMonth(_ offset: Int) {
        if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
    }

    private func refresh() async {
        guard let userID = auth.userID else { return }
        await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates)
        await dailyEnergy.loadMonth(month, userID: userID, force: true)
    }
}
