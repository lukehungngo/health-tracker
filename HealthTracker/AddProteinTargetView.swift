import SwiftUI

struct AddProteinTargetView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var targets: ProteinTargetStore
    @EnvironmentObject private var auth: AuthStore

    @State private var minText = ""
    @State private var maxText = ""
    @State private var recordedAt = Date()
    @State private var errorMessage: String?

    private func parse(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.filter({ $0 == "." }).count <= 1,
              input.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return Double(input)
    }

    private var range: (Double, Double)? {
        guard let minimum = parse(minText), let maximum = parse(maxText),
              minimum >= 20, maximum >= minimum, maximum <= 400 else { return nil }
        return (minimum, maximum)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Minimum (g/day)", text: $minText)
                        .keyboardType(.decimalPad)
                    TextField("Maximum (g/day)", text: $maxText)
                        .keyboardType(.decimalPad)
                    DatePicker("Recorded at", selection: $recordedAt, in: ...Date())
                } footer: {
                    Text("A daily protein reference range, not a meal log or medical prescription. AI can update the same range in Neon; the newest entry appears on Today.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Protein target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(range == nil)
                }
            }
            .onAppear {
                minText = targets.latest.map { String($0.minGrams) } ?? ""
                maxText = targets.latest.map { String($0.maxGrams) } ?? ""
            }
        }
    }

    private func save() {
        guard let range else { return }
        do {
            try targets.save(minGrams: range.0, maxGrams: range.1, recordedAt: recordedAt)
            dismiss()
            if let userID = auth.userID {
                Task { await targets.sync(userID: userID) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
