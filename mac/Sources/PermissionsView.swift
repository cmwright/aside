import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aside needs two permissions.")
                .font(.headline)

            row(
                title: "Microphone",
                detail: "To record while you hold the dictation key.",
                state: permissions.microphone,
                primary: ("Request", { permissions.requestMicrophone() }),
                secondary: ("Open Settings", { permissions.openMicrophoneSettings() })
            )

            row(
                title: "Accessibility",
                detail: "To notice the dictation key and to type the text where your cursor is.",
                state: permissions.accessibility,
                primary: ("Request", { permissions.requestAccessibility() }),
                secondary: ("Open Settings", { permissions.openAccessibilitySettings() })
            )

            Divider()

            Text(Permissions.adHocSigningNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                if permissions.allGranted {
                    Label("All set", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Button("Refresh") { permissions.refresh() }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        // Poll while visible so the rows flip to Granted on their own.
        .onAppear { permissions.beginWatching() }
        .onDisappear { permissions.endWatching() }
    }

    @ViewBuilder
    private func row(
        title: String,
        detail: String,
        state: Permissions.State,
        primary: (String, () -> Void),
        secondary: (String, () -> Void)
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(state == .granted ? Color.green : Color.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text(state.label).font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Button(primary.0, action: primary.1)
                    .disabled(state == .granted)
                Button(secondary.0, action: secondary.1)
            }
        }
    }
}
