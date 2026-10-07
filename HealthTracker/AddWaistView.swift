import SwiftUI

struct AddWaistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var waist: WaistStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    @FocusState private var valueFocused: Bool
    @State private var valueText = ""
    @State private var measuredAt = Date()
    @State private var errorMessage: String?

    private var centimeters: Double? {
        let input = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.filter({ $0 == "." }).count <= 1,
              input.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(input), WaistStore.isValid(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Waist circumference") {
                        HStack(spacing: 4) {
                            TextField("Value", text: $valueText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($valueFocused)
                                .accessibilityLabel("Waist circumference in centimeters")
                            Text("cm").foregroundStyle(.secondary)
                        }
                        .frame(width: 100)
                    }
                    DatePicker("Measured at", selection: $measuredAt, in: ...Date())
                    if !valueText.isEmpty && centimeters == nil {
                        Text("Enter a value from 30 to 300 cm.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Log waist circumference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(centimeters == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { valueFocused = false }
                }
            }
            .onAppear { valueText = waist.entries.first.map { String($0.centimeters) } ?? "" }
        }
    }

    private func save() {
        guard let centimeters else { return }
        do {
            try waist.save(centimeters: centimeters, measuredAt: measuredAt)
            dismiss()
            if let userID = auth.userID {
                Task {
                    await sync.refreshValues(userID: userID, weights: weights, waist: waist,
                                             leanMass: leanMass, energy: energy)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
