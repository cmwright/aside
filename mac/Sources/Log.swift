import Foundation
import os

/// Central logger. Transcript text is never logged at default level — only lengths and
/// timings — so a user's dictation never ends up in the unified log.
enum Log {
    static let subsystem = "com.codywright.aside"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let asr = Logger(subsystem: subsystem, category: "asr")
}
