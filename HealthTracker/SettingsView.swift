import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var health: HealthStore
    @EnvironmentObject private var meals: MealStore
    @EnvironmentObject private var mealEstimates: MealEstimateStore
    @EnvironmentObject private var weights: WeightStore
    @EnvironmentObject private var leanMass: LeanMassStore
    @EnvironmentObject private var energy: EnergyStore
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var sync: CloudSync

    @State private var email = ""
    @State private var password = ""
    @State private var heightText = ""
    @State private var birthDateOverride = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var genderOverride: FormulaGender?
    @State private var manualDemographics = false
    @State private var heightMessage: String?
    @State private var demographicsMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: auth.userID == nil ? "Signed out" : "Signed in")
                if let signedInEmail = auth.email {
                    LabeledContent("Account", value: signedInEmail)
                    Button {
                        Task {
                            await health.refresh()
                            if let userID = auth.userID {
                                await sync.run(userID: userID, meals: meals, weights: weights,
                                               leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
                            }
                        }
                    } label: {
                        Label("Sync Health + cloud", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(sync.isSyncing || health.isRefreshing)
                    Button {
                        if let userID = auth.userID {
                            Task { await sync.refreshMeals(userID: userID, meals: meals, mealEstimates: mealEstimates) }
                        }
                    } label: {
                        Label("Refresh meals only", systemImage: "fork.knife")
                    }
                    .disabled(sync.isRefreshingMeals)
                    Button {
                        if let userID = auth.userID {
                            Task {
                                await sync.refreshValues(userID: userID, weights: weights,
                                                         leanMass: leanMass, energy: energy)
                            }
                        }
                    } label: {
                        Label("Refresh body values", systemImage: "arrow.down.circle")
                    }
                    .disabled(sync.isRefreshingValues)
                    LabeledContent("Last meal refresh", value: sync.lastMealSync?
                        .formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                    LabeledContent("Last body values refresh", value: sync.lastValueSync?
                        .formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                    LabeledContent("Last Health upload", value: sync.lastSuccess?
                        .formatted(date: .abbreviated, time: .shortened) ?? "Not yet completed")
                    Button("Sign Out") { Task { await auth.signOut() } }
                        .disabled(auth.isBusy)
                } else {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button("Sign In") { Task { await signIn() } }
                        .disabled(auth.isBusy || email.isEmpty || password.isEmpty)
                    Button("Create Account") { Task { await signUp() } }
                        .disabled(auth.isBusy || email.isEmpty || password.isEmpty)
                }
                if let message = auth.message { Text(message).foregroundStyle(.secondary) }
                if let message = sync.mealMessage { Text(message).foregroundStyle(.secondary) }
                if let message = sync.valueMessage { Text(message).foregroundStyle(.secondary) }
                if let message = sync.message { Text(message).foregroundStyle(.secondary) }
            } header: {
                Text("Account & sync")
            } footer: {
                Text("Meals can refresh while a longer HealthKit upload is running. Background sync is best-effort; iOS does not guarantee an exact hourly wake-up.")
            }

            Section {
                LabeledContent("HealthKit on this iPhone", value: health.isAvailable ? "Available" : "Unavailable")
                Button("Review Health permissions") {
                    Task { await health.requestAccess() }
                }
                .disabled(!health.isAvailable)
                if let lastRefresh = health.lastRefresh {
                    LabeledContent("Last local read", value: lastRefresh.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = health.errorMessage { Text(error).foregroundStyle(.red) }
            } header: {
                Text("Apple Health")
            } footer: {
#if targetEnvironment(simulator)
                Text("HealthKit reads are disabled in this Simulator build. Cloud meals, estimates, and History can still be tested here; use the signed iPhone build for Apple Health data.")
#else
                Text("Available means the device supports HealthKit; it does not mean every data type is authorized. Review permissions if a value stays blank.")
#endif
            }

            Section {
                LabeledContent("Apple Health", value: health.today.appleHeightCm.map {
                    "\($0.formatted(.number.precision(.fractionLength(0)))) cm"
                } ?? "No value")
                Picker("Height source", selection: $profile.useManualHeight) {
                    Text("Apple Health").tag(false)
                    Text("Enter here").tag(true)
                }
                .pickerStyle(.segmented)
                if profile.useManualHeight {
                    TextField("Height in cm", text: $heightText)
                        .keyboardType(.decimalPad)
                    Button("Save height") { saveHeight() }
                        .disabled(parsedHeight == nil)
                    if profile.manualHeight == nil {
                        Text("Enter and save a height to use the manual source.")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Height used", value: profile.selectedHeightCm(appleHeightCm: health.today.appleHeightCm)
                    .map { "\($0.formatted(.number.precision(.fractionLength(0)))) cm" } ?? "Missing")
                if let heightMessage { Text(heightMessage).foregroundStyle(.secondary) }
            } header: {
                Text("Height")
            } footer: {
                Text("Height is configured here, not on Today. If Apple Health has no value, choose Enter here and save one.")
            }

            Section {
                LabeledContent("Apple Health birth date", value: health.today.appleBirthDate?
                    .formatted(date: .abbreviated, time: .omitted) ?? "No value")
                LabeledContent("Apple Health gender", value: health.today.appleGender?.rawValue ?? "No value")
                Picker("Profile source", selection: $manualDemographics) {
                    Text("Apple Health").tag(false)
                    Text("Enter here").tag(true)
                }
                .pickerStyle(.segmented)
                if manualDemographics {
                    DatePicker("Birth date", selection: $birthDateOverride,
                               in: ...Date(), displayedComponents: .date)
                    Picker("Gender for formula", selection: $genderOverride) {
                        Text("Choose").tag(nil as FormulaGender?)
                        ForEach(FormulaGender.allCases) { gender in
                            Text(gender.rawValue).tag(Optional(gender))
                        }
                    }
                    Button("Save manual profile") { saveFormulaOverrides() }
                        .disabled(genderOverride == nil)
                    if !profile.useManualBirthDate && !profile.useManualGender {
                        Text("Manual values take effect only after Save.")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Profile used", value: activeDemographics)
                if let demographicsMessage { Text(demographicsMessage).foregroundStyle(.secondary) }
            } header: {
                Text("Age & gender for calorie formula")
            } footer: {
                Text("Gender here selects the calorie formula's male/female coefficient; it is not a statement about your identity. The app reads Apple Health unless you save a manual override. Switching back does not delete it.")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            heightText = profile.manualHeight.map { String($0.centimeters) } ?? ""
            birthDateOverride = profile.manualBirthDate ?? health.today.appleBirthDate
                ?? (Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date())
            genderOverride = profile.manualGender ?? health.today.appleGender
            manualDemographics = profile.useManualBirthDate || profile.useManualGender
        }
        .onChange(of: manualDemographics) { _, manual in
            guard !manual else { return }
            do {
                try profile.useAppleDemographics()
                demographicsMessage = "Using Apple Health birth date and gender when available."
            } catch {
                demographicsMessage = error.localizedDescription
            }
        }
    }

    private var activeDemographics: String {
        let date = profile.selectedBirthDate(appleBirthDate: health.today.appleBirthDate)
        let gender = profile.selectedGender(appleGender: health.today.appleGender)
        guard let date, let gender else { return "Missing" }
        let source = profile.useManualBirthDate || profile.useManualGender ? "manual" : "Apple Health"
        return "\(date.formatted(date: .abbreviated, time: .omitted)), \(gender.rawValue) (\(source))"
    }

    private var parsedHeight: Double? {
        let normalized = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), (100...250).contains(value) else { return nil }
        return value
    }

    private func saveHeight() {
        guard let centimeters = parsedHeight else { return }
        do {
            try profile.saveManual(centimeters: centimeters)
            heightMessage = "Height saved on this iPhone. Sync Health + cloud uploads it."
        } catch {
            heightMessage = error.localizedDescription
        }
    }

    private func saveFormulaOverrides() {
        guard let gender = genderOverride else { return }
        do {
            try profile.saveFormulaOverrides(birthDate: birthDateOverride, gender: gender)
            demographicsMessage = "Manual birth date and gender are now used for the formula."
        } catch {
            demographicsMessage = error.localizedDescription
        }
    }

    private func signIn() async {
        await auth.signIn(email: email, password: password)
        if let userID = auth.userID {
            password = ""
            await sync.run(userID: userID, meals: meals, weights: weights,
                           leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
        }
    }

    private func signUp() async {
        await auth.signUp(email: email, password: password)
        if let userID = auth.userID {
            password = ""
            await sync.run(userID: userID, meals: meals, weights: weights,
                           leanMass: leanMass, energy: energy, profile: profile, mealEstimates: mealEstimates)
        }
    }

}
