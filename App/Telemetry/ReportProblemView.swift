import AppKit
import PacerCore
@preconcurrency import Sentry
import SwiftUI
import UniformTypeIdentifiers

/// Opens the Report a Problem window from anywhere: the Help menu, the
/// menu-bar menu, Settings → Privacy. An AppKit window owned here rather than
/// a SwiftUI `Window` scene, because the menu-bar menu is AppKit and has no
/// `openWindow` to call. One window at a time; reopening after a send starts a
/// fresh form.
@MainActor
final class ReportProblemWindow {
    static let shared = ReportProblemWindow()
    private var window: NSWindow?

    func show() {
        TelemetryCounters.add("ui.report_problem.open")
        if let window, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: ReportProblemView(onClose: { [weak self] in
            self?.window?.close()
        }))
        let window = NSWindow(contentViewController: host)
        window.title = "Report a Problem"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        // A user-initiated command, like About: activating is what brings the
        // window forward from accessory (menu-bar only) mode.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// A problem report to Pacer's Sentry project, the in-app twin of
/// `pacer feedback`. Sent as Sentry user feedback, so it lands beside the
/// crashes from the same Mac and release. Counts as a crash report for the
/// Settings → Privacy toggle; with that off (or no SDK, e.g. a build from
/// source) it offers a GitHub issue instead.
///
/// Attachments are the person's choice per report: a picture of Pacer's own
/// window (rendered from Pacer's view hierarchy, never a screen capture, and
/// off by default because it shows costs and project names) and any files
/// they pick.
struct ReportProblemView: View {
    let onClose: () -> Void
    @State private var message = ""
    @State private var email = ""
    @State private var includeWindow = false
    @State private var files: [URL] = []
    @State private var sent = false

    private var canSend: Bool {
        TelemetryController.shared.isRunning && TelemetryController.crashAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sent {
                Text("Sent. Thank you.")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction) }
            } else {
                TextEditor(text: $message)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                TextField("Email (optional, for a reply)", text: $email)
                if canSend {
                    Toggle("Include a picture of Pacer's window", isOn: $includeWindow)
                    HStack {
                        Button("Add File…", action: addFiles)
                        Text(files.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !files.isEmpty {
                            Button("Remove") { files = [] }.buttonStyle(.link).font(.caption)
                        }
                    }
                } else {
                    Text("Crash reports are off in Settings → Privacy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: onClose)
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
        .frame(width: 460, height: sent ? 120 : 340)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { files.append(contentsOf: panel.urls) }
    }

    private func send() {
        var attachments: [Attachment] = []
        if includeWindow, let png = Self.mainWindowPNG() {
            attachments.append(Attachment(data: png, filename: "pacer-window.png", contentType: "image/png"))
        }
        // Sentry caps attachments; 10 MB each keeps a stray video from
        // failing the whole report.
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count <= 10 * 1024 * 1024 else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            attachments.append(Attachment(data: data, filename: url.lastPathComponent, contentType: type))
        }
        let address = email.trimmingCharacters(in: .whitespaces)
        // The email is the one personal detail a person can choose to give,
        // so a reply is possible; it is not scrubbed out of its own field.
        let feedback = SentryFeedback(message: TelemetryScrubber.scrub(message), name: nil,
                                      email: address.isEmpty ? nil : address, source: .custom,
                                      attachments: attachments.isEmpty ? nil : attachments)
        SentrySDK.capture(feedback: feedback)
        Telemetry.breadcrumb("feedback", "problem report sent")
        sent = true
    }

    /// Pacer's dashboard window, drawn from its own view hierarchy into a PNG.
    /// Not a screen capture: nothing outside Pacer's window can appear in it.
    private static func mainWindowPNG() -> Data? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.title != "Report a Problem" && $0.contentView != nil }
        guard let view = (candidates.first { $0.isMainWindow } ?? candidates.max { $0.frame.width < $1.frame.width })?
                .contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func openIssue() {
        var parts = URLComponents(string: "https://github.com/ericandrechek/Pacer/issues/new")!
        parts.queryItems = [URLQueryItem(name: "body", value: TelemetryScrubber.scrub(message))]
        if let url = parts.url { NSWorkspace.shared.open(url) }
        onClose()
    }
}
