#if os(iOS)
import ActivityKit
import Foundation

struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var status: String
        var recordingID: String?
    }
    var sessionID: UUID
}
#endif
