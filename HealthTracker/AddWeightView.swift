import SwiftUI

struct AddWeightView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var waist: WaistStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    @State private var weightText = ""
    @State private var measuredAt = Date()
    @State private var errorMessage: String?

    private var kilograms: Double? {
        let input = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.filter({ $0 == "." }).count <= 1,
              input.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(input), (20...500).contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Weight (kg)", text: $weightText)
                        .keyboardType(.decimalPad)
                        .accessibilityHint("Enter your measured weight in kilograms")
                    DatePicker("Measured at", selection: $measuredAt, in: ...Date())
                } footer: {
                    Text("Only weights you enter here are used for your weight trend. Apple Health weight is not imported.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Log new weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(kilograms == nil)
                }
            }
            .onAppear { weightText = weights.entries.first.map { String($0.kilograms) } ?? "" }
        }
    }

    private func save() {
        guard let kilograms else { return }
        do {
            try weights.save(kilograms: kilograms, measuredAt: measuredAt)
            dismiss()
            if let userID = auth.userID {
                Task { await sync.refreshValues(userID: userID, weights: weights, waist: waist,
                                                leanMass: leanMass, energy: energy) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
