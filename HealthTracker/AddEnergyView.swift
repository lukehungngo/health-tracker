import SwiftUI

struct AddEnergyView: View {
    let kind: EnergyKind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    @State private var valueText = ""
    @State private var recordedAt = Date()
    @State private var errorMessage: String?

    private var kilocalories: Double? {
        let input = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.filter({ $0 == "." }).count <= 1,
              input.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(input), (400...10_000).contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Energy (kcal/day)", text: $valueText)
                        .keyboardType(.decimalPad)
                        .accessibilityHint("Enter an estimated daily energy amount in kilocalories")
                    DatePicker("Recorded at", selection: $recordedAt, in: ...Date())
                } footer: {
                    Text(kind == .basal
                         ? "This is a daily basal estimate. It does not change Apple Health's measured basal energy."
                         : "This is your estimated daily intake to maintain weight, not a weight-loss target. A newer entry replaces it on Today.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(kilocalories == nil)
                }
            }
            .onAppear {
                valueText = energy.latest(for: kind).map { String($0.kilocalories) } ?? ""
            }
        }
    }

    private func save() {
        guard let kilocalories else { return }
        do {
            try energy.save(kind: kind, kilocalories: kilocalories, recordedAt: recordedAt)
            dismiss()
            if let userID = auth.userID {
                Task {
                    await sync.refreshValues(userID: userID, weights: weights,
                                             leanMass: leanMass, energy: energy)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
