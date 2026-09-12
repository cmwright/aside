import Foundation

/// How hard the backend should work on the transcript. Matches the `cleanup` field of the
/// HTTP contract exactly.
enum CleanupLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case light
    case medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None — raw transcript"
        case .light: return "Light — punctuation, capitalization, dictionary"
        case .medium: return "Medium — also fillers, false starts, grammar"
        }
    }
}
