import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            HStack {
                Image(systemName: context.state.isRecording ? "waveform" : "mic.fill")
                    .foregroundStyle(context.state.isRecording ? .red : .purple)
                VStack(alignment: .leading) {
                    Text("Aside").font(.headline)
                    Text(context.isStale ? "Open Aside to resume" : context.state.status).font(.caption)
                }
                Spacer()
                controls(context.state, stale: context.isStale)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "aside://session/start"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("Aside").font(.headline) }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isRecording ? "waveform" : "mic.fill")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Open Aside to resume" : context.state.status)
                        Spacer()
                        controls(context.state, stale: context.isStale)
                    }
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(context.state.isRecording ? .red : .purple)
            } compactTrailing: {
                Image(systemName: context.state.isRecording ? "waveform" : "ellipsis")
            } minimal: {
                Image(systemName: "mic.fill")
            }
            .widgetURL(URL(string: "aside://session/start"))
        }
    }

    @ViewBuilder
    private func controls(_ state: DictationActivityAttributes.ContentState, stale: Bool) -> some View {
        if stale {
            Link("Resume", destination: URL(string: "aside://session/start")!)
        } else if state.status != "Transcribing" {
            Button(intent: LiveDictationIntent(recording: !state.isRecording, recordingID: state.recordingID)) {
                Label(state.isRecording ? "Stop" : "Dictate", systemImage: state.isRecording ? "stop.fill" : "mic.fill")
            }
            .buttonStyle(.bordered)
        }
    }
}
