import Foundation

struct HeightEntry: Codable {
    let id: UUID
    let measuredAt: Date
    let centimeters: Double
}

enum FormulaGender: String, Codable, CaseIterable, Identifiable {
    case male = "Male"
    case female = "Female"
    var id: String { rawValue }
}

struct FormulaOverrides: Codable {
    var birthDate: Date?
    var gender: FormulaGender?
    var useManualBirthDate: Bool
    var useManualGender: Bool

    private enum CodingKeys: String, CodingKey {
        case birthDate, gender, useManualBirthDate, useManualGender
        case legacySex = "sex"
        case legacyUseManualSex = "useManualSex"
    }

    init(birthDate: Date?, gender: FormulaGender?, useManualBirthDate: Bool, useManualGender: Bool) {
        self.birthDate = birthDate
        self.gender = gender
        self.useManualBirthDate = useManualBirthDate
        self.useManualGender = useManualGender
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        birthDate = try values.decodeIfPresent(Date.self, forKey: .birthDate)
        gender = try values.decodeIfPresent(FormulaGender.self, forKey: .gender)
            ?? values.decodeIfPresent(FormulaGender.self, forKey: .legacySex)
        useManualBirthDate = try values.decode(Bool.self, forKey: .useManualBirthDate)
        useManualGender = try values.decodeIfPresent(Bool.self, forKey: .useManualGender)
            ?? values.decode(Bool.self, forKey: .legacyUseManualSex)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(birthDate, forKey: .birthDate)
        try values.encodeIfPresent(gender, forKey: .gender)
        try values.encode(useManualBirthDate, forKey: .useManualBirthDate)
        try values.encode(useManualGender, forKey: .useManualGender)
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var manualHeight: HeightEntry?
    @Published var useManualHeight: Bool {
        didSet { UserDefaults.standard.set(useManualHeight, forKey: preferenceKey) }
    }
    @Published var errorMessage: String?
    @Published private(set) var manualBirthDate: Date?
    @Published private(set) var manualGender: FormulaGender?
    @Published private(set) var useManualBirthDate = false
    @Published private(set) var useManualGender = false

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
                manualGender = saved.gender
                useManualBirthDate = saved.useManualBirthDate
                useManualGender = saved.useManualGender
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

    func selectedGender(appleGender: FormulaGender?) -> FormulaGender? {
        useManualGender ? manualGender : appleGender
    }

    func saveFormulaOverrides(birthDate: Date, gender: FormulaGender) throws {
        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
        guard (18...120).contains(age), birthDate <= Date() else { throw HeightError.invalidBirthDate }
        let saved = FormulaOverrides(birthDate: birthDate, gender: gender,
                                     useManualBirthDate: true, useManualGender: true)
        try JSONEncoder().encode(saved).write(to: overridesURL, options: [.atomic, .completeFileProtection])
        manualBirthDate = birthDate
        manualGender = gender
        useManualBirthDate = true
        useManualGender = true
    }

    func useAppleDemographics() throws {
        let saved = FormulaOverrides(birthDate: manualBirthDate, gender: manualGender,
                                     useManualBirthDate: false, useManualGender: false)
        try JSONEncoder().encode(saved).write(to: overridesURL, options: [.atomic, .completeFileProtection])
        useManualBirthDate = false
        useManualGender = false
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
