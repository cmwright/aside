// ActivityKit predates strict Sendable annotations. All access is owned here,
// with updates and ending serialized by the task chain.
@preconcurrency import ActivityKit
import UIKit

/// No transcript is exposed on the Lock Screen. An activity is requested in the
/// foreground and then updated as the existing audio session runs in the background.
@MainActor
final class DictationActivityController {
    private var activity: Activity<DictationActivityAttributes>?
    private var updateTask: Task<Void, Never>?
    private var contentState: DictationActivityAttributes.ContentState?
    private var refreshedAt = Date.distantPast

    func start(recordingID: UUID?, isRecording: Bool) {
        let state = DictationActivityAttributes.ContentState(isRecording: isRecording,
            status: isRecording ? "Listening" : "Ready to dictate", recordingID: recordingID?.uuidString)
        contentState = state
        refreshedAt = Date()
        if let activity {
            enqueueUpdate(activity, state: state)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            activity = try Activity.request(attributes: DictationActivityAttributes(sessionID: UUID()),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
        } catch {
            Log.app.notice("Live Activity unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(isRecording: Bool, status: String) {
        guard let activity else { return }
        guard var state = contentState else { return }
        state.isRecording = isRecording
        state.status = status
        contentState = state
        enqueueUpdate(activity, state: state)
    }

    private func enqueueUpdate(_ activity: Activity<DictationActivityAttributes>,
                               state: DictationActivityAttributes.ContentState) {
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120)))
        }
    }

    func refresh() {
        guard Date().timeIntervalSince(refreshedAt) >= 30, let activity, let contentState else { return }
        refreshedAt = Date()
        enqueueUpdate(activity, state: contentState)
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        let previous = updateTask
        updateTask = Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func removeAbandonedActivities() {
        for activity in Activity<DictationActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
