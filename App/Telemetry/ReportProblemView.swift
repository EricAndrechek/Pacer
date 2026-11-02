import PacerCore
@preconcurrency import Sentry
import SwiftUI

/// Help → Report a Problem…: a problem report to Pacer's Sentry project, the
/// in-app twin of `pacer feedback`. Sent as Sentry user feedback, so it lands
/// beside the crashes from the same Mac and release. Counts as a crash report
/// for the Settings → Privacy toggle; with that off (or no SDK, e.g. a build
/// from source) it offers a GitHub issue instead.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var email = ""
    @State private var sent = false

    private var canSend: Bool {
        TelemetryController.shared.isRunning && TelemetryController.crashAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem").font(.headline)
            if sent {
                Text("Sent. Thank you.")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                TextField("Email (optional, for a reply)", text: $email)
                if !canSend {
                    Text("Crash reports are off in Settings → Privacy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    if canSend {
                        Button("Send") { send() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Open GitHub Issue") { openIssue() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 300)
    }

    private func send() {
        let text = TelemetryScrubber.scrub(message)
        let address = email.trimmingCharacters(in: .whitespaces)
        // The email is the one personal detail a person can choose to give,
        // so a reply is possible; it is not scrubbed out of its own field.
        let feedback = SentryFeedback(message: text, name: nil,
                                      email: address.isEmpty ? nil : address, source: .custom)
        SentrySDK.capture(feedback: feedback)
        Telemetry.breadcrumb("feedback", "problem report sent")
        sent = true
    }

    private func openIssue() {
        var parts = URLComponents(string: "https://github.com/ericandrechek/Pacer/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: TelemetryScrubber.scrub(message))]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        dismiss()
    }
}
