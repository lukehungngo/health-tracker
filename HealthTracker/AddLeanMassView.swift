import SwiftUI

struct AddLeanMassView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    @State private var valueText = ""
    @State private var measuredAt = Date()
    @State private var errorMessage: String?

    private var kilograms: Double? {
        let input = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.filter({ $0 == "." }).count <= 1,
              input.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(input), (10...200).contains(value),
              weights.entries.first.map({ value <= $0.kilograms }) ?? true else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Lean body mass (kg)", text: $valueText)
                        .keyboardType(.decimalPad)
                    DatePicker("Measured at", selection: $measuredAt, in: ...Date())
                } footer: {
                    Text("Enter fat-free/lean body mass from your scale or body-composition report, not skeletal muscle mass. It must not exceed your body weight. Height stays in Settings.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Log lean mass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(kilograms == nil)
                }
            }
        }
    }

    private func save() {
        guard let kilograms else { return }
        do {
            try leanMass.save(kilograms: kilograms, measuredAt: measuredAt,
                              latestWeightKg: weights.entries.first?.kilograms)
            dismiss()
            if let userID = auth.userID {
                Task {
                    await sync.run(userID: userID, meals: meals, weights: weights,
                                   leanMass: leanMass, profile: profile, mealEstimates: mealEstimates)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
