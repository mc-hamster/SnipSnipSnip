import SwiftUI

struct VideoPermissionRecoveryView: View {
    @ObservedObject var video: VideoWorkflowModel
    let recovery: VideoStartRecovery

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(recovery.needsMicrophoneAccess ? "Microphone Access Is Needed" : "Video Could Not Start", systemImage: recovery.needsMicrophoneAccess ? "mic.slash" : "exclamationmark.triangle")
                .font(.title3.weight(.semibold))
            Text(recovery.needsMicrophoneAccess
                 ? "Microphone access is needed for narration. You can open Microphone settings and enable access, or record this Video without narration."
                 : recovery.message)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your recording preferences are unchanged. Try Again returns to the selected recording source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if recovery.needsMicrophoneAccess {
                Button("Open Microphone Settings", action: video.openMicrophoneSettings)
                Button("Record Without Microphone") { video.retryVideoStart(withoutMicrophone: true) }
            }
            HStack {
                Button("Not Now", action: video.dismissVideoStartRecovery)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { video.retryVideoStart() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .accessibilityIdentifier("video.permissionRecovery")
    }
}
