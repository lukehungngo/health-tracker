import Foundation

struct HeightEntry: Codable {
    let id: UUID
    let measuredAt: Date
    let centimeters: Double
}

enum FormulaSex: String, Codable, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    var id: String { rawValue }
}

private struct FormulaOverrides: Codable {
    var birthDate: Date?
    var sex: FormulaSex?
    var useManualBirthDate: Bool
    var useManualSex: Bool
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var manualHeight: HeightEntry?
    @Published var useManualHeight: Bool {
        didSet { UserDefaults.standard.set(useManualHeight, forKey: preferenceKey) }
    }
    @Published var errorMessage: String?
    @Published private(set) var manualBirthDate: Date?
    @Published private(set) var manualSex: FormulaSex?
    @Published private(set) var useManualBirthDate = false
    @Published private(set) var useManualSex = false

    private let indexURL: URL
    private let overridesURL: URL
    private let preferenceKey = "use-manual-height"

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Profile", isDirectory: true)
        indexURL = directory.appendingPathComponent("height.json")
        overridesURL = directory.appendingPathComponent("formula-overrides.json")
        useManualHeight = UserDefaults.standard.bool(forKey: preferenceKey)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                manualHeight = try JSONDecoder().decode(HeightEntry.self, from: Data(contentsOf: indexURL))
            }
            if FileManager.default.fileExists(atPath: overridesURL.path) {
                let saved = try JSONDecoder().decode(FormulaOverrides.self, from: Data(contentsOf: overridesURL))
                manualBirthDate = saved.birthDate
                manualSex = saved.sex
                useManualBirthDate = saved.useManualBirthDate
                useManualSex = saved.useManualSex
            }
        } catch {
            errorMessage = "Saved height could not be loaded: \(error.localizedDescription)"
        }
    }

    func saveManual(centimeters: Double) throws {
        guard centimeters.isFinite, (100...250).contains(centimeters) else { throw HeightError.invalidHeight }
        let entry = HeightEntry(id: UUID(), measuredAt: Date(), centimeters: centimeters)
        try JSONEncoder().encode(entry).write(to: indexURL, options: [.atomic, .completeFileProtection])
        manualHeight = entry
        useManualHeight = true
    }

    func mergeRemote(_ entry: HeightEntry?) throws {
        guard let entry, entry.measuredAt > (manualHeight?.measuredAt ?? .distantPast) else { return }
        guard entry.centimeters.isFinite, (100...250).contains(entry.centimeters) else { throw HeightError.invalidHeight }
        try JSONEncoder().encode(entry).write(to: indexURL, options: [.atomic, .completeFileProtection])
        manualHeight = entry
        if UserDefaults.standard.object(forKey: preferenceKey) == nil { useManualHeight = true }
    }

    func selectedHeightCm(appleHeightCm: Double?) -> Double? {
        useManualHeight ? manualHeight?.centimeters : appleHeightCm
    }

    func selectedBirthDate(appleBirthDate: Date?) -> Date? {
        useManualBirthDate ? manualBirthDate : appleBirthDate
    }

    func selectedSex(appleSex: FormulaSex?) -> FormulaSex? {
        useManualSex ? manualSex : appleSex
    }

    func saveFormulaOverrides(birthDate: Date, sex: FormulaSex) throws {
        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
        guard (18...120).contains(age), birthDate <= Date() else { throw HeightError.invalidBirthDate }
        let saved = FormulaOverrides(birthDate: birthDate, sex: sex,
                                     useManualBirthDate: true, useManualSex: true)
        try JSONEncoder().encode(saved).write(to: overridesURL, options: [.atomic, .completeFileProtection])
        manualBirthDate = birthDate
        manualSex = sex
        useManualBirthDate = true
        useManualSex = true
    }

    func useAppleDemographics() throws {
        let saved = FormulaOverrides(birthDate: manualBirthDate, sex: manualSex,
                                     useManualBirthDate: false, useManualSex: false)
        try JSONEncoder().encode(saved).write(to: overridesURL, options: [.atomic, .completeFileProtection])
        useManualBirthDate = false
        useManualSex = false
    }

    private enum HeightError: LocalizedError {
        case invalidHeight
        case invalidBirthDate
        var errorDescription: String? {
            switch self {
            case .invalidHeight: "Enter a height from 100 to 250 cm."
            case .invalidBirthDate: "Enter a date of birth for an age from 18 to 120 years."
            }
        }
    }
}
