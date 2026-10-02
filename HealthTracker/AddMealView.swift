import PhotosUI
import SwiftUI
import UIKit

struct AddMealView: View {
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var note = ""
    @State private var showCamera = false
    @State private var isLoadingPhoto = false
    @State private var message: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        Form {
            Section("Photo (optional)") {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Selected meal photo")
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose Photo", systemImage: "photo")
                        .frame(minHeight: 44)
                }
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(minHeight: 44)
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                if isLoadingPhoto { ProgressView("Loading photo") }
            }

            Section("Note (optional)") {
                TextField("For example, rice and fish", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityLabel("Meal note")
                    .focused($noteFocused)
            }

            Section {
                Button("Save Meal") { saveMeal() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled((image == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isLoadingPhoto)
            } footer: {
                Text(auth.userID == nil ? "Saved on this phone. Sign in under Settings to sync." : "Saved on this phone first, then uploaded to Neon.")
            }

            if let message {
                Section {
                    Text(message)
                        .foregroundStyle(message == "Meal saved on this phone." ? Color.secondary : Color.red)
                }
            }
        }
        .navigationTitle("Add Meal")
        .scrollDismissesKeyboard(.interactively)
        .onAppear { message = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { noteFocused = false }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image = $0 }
                .ignoresSafeArea()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task {
                isLoadingPhoto = true
                defer { isLoadingPhoto = false }
                do {
                    guard let data = try await newValue.loadTransferable(type: Data.self),
                          let loaded = UIImage(data: data) else {
                        message = "The selected photo could not be opened. Choose another."
                        return
                    }
                    image = loaded
                    message = nil
                } catch {
                    message = "The selected photo could not be opened: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveMeal() {
        do {
            try meals.save(image: image, note: note)
            noteFocused = false
            self.image = nil
            selectedPhoto = nil
            note = ""
            message = "Meal saved on this phone."
            if let userID = auth.userID {
                Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
            }
        } catch {
            message = "Meal could not be saved: \(error.localizedDescription)"
        }
    }
}
