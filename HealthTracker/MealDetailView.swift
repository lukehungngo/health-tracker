import SwiftUI

struct MealDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var estimates: MealEstimateStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    let mealID: UUID
    @State private var isEditing = false
    @State private var note = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case note, calories, protein, carbs, fat }

    private var meal: Meal? { meals.meals.first { $0.id == mealID } }
    private var estimate: MealEstimate? { estimates.estimate(for: mealID) }

    var body: some View {
        NavigationStack {
            Form {
                if let meal {
                    Section {
                        LabeledContent("Logged", value: meal.eatenAt.formatted(date: .abbreviated, time: .shortened))
                        if let image = meals.image(for: meal) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 360)
                                .accessibilityLabel("Meal photo")
                        }
                    }
                    Section("Note") {
                        if isEditing {
                            TextField("Describe this meal", text: $note, axis: .vertical)
                                .lineLimit(3...10)
                                .focused($focusedField, equals: .note)
                                .accessibilityLabel("Meal note")
                        } else {
                            Text(meal.note.isEmpty ? "No note" : meal.note)
                                .foregroundStyle(meal.note.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                        }
                    }
                    Section("Nutrition") {
                        if isEditing {
                            numberField("Calories", unit: "kcal", text: $calories, field: .calories)
                            numberField("Protein", unit: "g", text: $protein, field: .protein)
                            numberField("Carbs", unit: "g", text: $carbs, field: .carbs)
                            numberField("Fat", unit: "g", text: $fat, field: .fat)
                            Text("Leave a value blank if it is unknown. At least one nutrition value is needed to create an estimate.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Calories", value: formatted(estimate?.calories_kcal, unit: "kcal"))
                            LabeledContent("Protein", value: formatted(estimate?.protein_g, unit: "g"))
                            LabeledContent("Carbs", value: formatted(estimate?.carbs_g, unit: "g"))
                            LabeledContent("Fat", value: formatted(estimate?.fat_g, unit: "g"))
                        }
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    if let syncMessage = sync.mealMessage, !isEditing {
                        Section { Text(syncMessage).foregroundStyle(.secondary) }
                    }
                } else {
                    Text("This meal is no longer available.")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit meal" : "Meal log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "Cancel" : "Close") {
                        if isEditing {
                            focusedField = nil
                            isEditing = false
                            errorMessage = nil
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Save") { save() }.fontWeight(.semibold)
                    } else if meal != nil {
                        Button("Edit") { startEditing() }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func numberField(_ title: String, unit: String, text: Binding<String>, field: Field) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("Optional", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .accessibilityLabel(title)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "Not entered"
    }

    private func startEditing() {
        guard let meal else { return }
        note = meal.note
        calories = estimate?.calories_kcal.map { String($0) } ?? ""
        protein = estimate?.protein_g.map { String($0) } ?? ""
        carbs = estimate?.carbs_g.map { String($0) } ?? ""
        fat = estimate?.fat_g.map { String($0) } ?? ""
        errorMessage = nil
        isEditing = true
    }

    private func parsed(_ text: String, limit: Double) -> (valid: Bool, value: Double?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return (true, nil) }
        let number = Double(clean.replacingOccurrences(of: ",", with: "."))
        guard let number, number.isFinite, (0...limit).contains(number) else { return (false, nil) }
        return (true, number)
    }

    private func save() {
        guard let meal else { return }
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meal.imageName != nil || !cleanNote.isEmpty else {
            errorMessage = "Add a note to keep this text-only meal."
            return
        }
        let kcal = parsed(calories, limit: 20_000)
        let proteinValue = parsed(protein, limit: 2_000)
        let carbsValue = parsed(carbs, limit: 2_000)
        let fatValue = parsed(fat, limit: 2_000)
        guard kcal.valid, proteinValue.valid, carbsValue.valid, fatValue.valid else {
            errorMessage = "Use non-negative numbers (kcal up to 20,000; grams up to 2,000)."
            return
        }
        let nutritionChanged = kcal.value != estimate?.calories_kcal ||
            proteinValue.value != estimate?.protein_g ||
            carbsValue.value != estimate?.carbs_g || fatValue.value != estimate?.fat_g
        guard !nutritionChanged || [kcal.value, proteinValue.value, carbsValue.value, fatValue.value]
            .contains(where: { $0 != nil }) else {
            errorMessage = "Keep at least one nutrition value; clearing an estimate is not supported yet."
            return
        }
        do {
            if nutritionChanged {
                try estimates.saveManual(mealID: mealID, calories: kcal.value, protein: proteinValue.value,
                                         carbs: carbsValue.value, fat: fatValue.value)
            }
            try meals.updateNote(id: mealID, note: cleanNote)
            focusedField = nil
            errorMessage = nil
            isEditing = false
            if let userID = auth.userID {
                Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: estimates) }
            }
        } catch {
            errorMessage = "Meal could not be saved: \(error.localizedDescription)"
        }
    }
}
