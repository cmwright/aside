import Foundation

/// An Objective-C exception turned into a Swift error, so a framework that raises instead
/// of throwing (AVFAudio's `installTap`, see issue #2) fails the operation rather than
/// aborting the app.
struct ObjCExceptionError: LocalizedError {
    let name: String
    let reason: String

    var errorDescription: String? { reason.isEmpty ? name : reason }
}

enum ObjCException {
    /// Runs `block` under an Objective-C `@try`; a raise becomes a thrown `ObjCExceptionError`.
    /// Only for calls that are pure Objective-C underneath: Swift frames between the raise
    /// and the catch are not unwound, so the block must not own anything that needs cleanup.
    static func catching(_ block: () -> Void) throws {
        if let exception = AsideExceptionCatcher.catchException(in: block) {
            throw ObjCExceptionError(name: exception.name.rawValue, reason: exception.reason ?? "")
        }
    }
}
