import Foundation

enum MetricSource {
    static let manual = "Health Tracker (manual)"

    static func label(_ source: String) -> String {
        switch source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ai", "chatgpt", "codex": "AI"
        case manual.lowercased(): "Manual"
        default: "Cloud"
        }
    }
}
