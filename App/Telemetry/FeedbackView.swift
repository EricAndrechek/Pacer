import AppKit
import PacerCore
import SwiftUI
import UniformTypeIdentifiers

/// Opens the Send Feedback window from anywhere: the sidebar footer, the
/// menu-bar menu, the Help menu, Settings → Privacy. An AppKit window owned
/// here rather than a SwiftUI `Window` scene, because the menu-bar menu is
/// AppKit and has no `openWindow` to call. One window at a time; reopening
/// after a send starts a fresh form.
@MainActor
final class FeedbackWindow {
    static let shared = FeedbackWindow()
    private var window: NSWindow?

    func show(from source: AnalyticsEvent.ReportProblemSource) {
        // The counter and the event keep their "report a problem" names, so
        // their series carry on past the rename.
        TelemetryCounters.add("ui.report_problem.open")
        Analytics.capture(.reportProblemOpened(from: source))
        if let window, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: FeedbackView(onClose: { [weak self] in
            self?.window?.close()
        }))
        let window = NSWindow(contentViewController: host)
        window.title = FeedbackCopy.windowTitle
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

/// Feedback to Pacer: an idea, a problem, or something else, chosen up top
/// (idea by default, so the window reads as an invitation rather than a fault
/// report).
///
/// Sent to the site's feedback endpoint (`FeedbackSubmission`), which forwards
/// it to Sentry user feedback: the same path whatever the crash-reports toggle
/// says, and no GitHub account needed. A GitHub issue is offered only when
/// that send fails or today's limit is reached. The message is the person's
/// own words, sent on their click, so it is not run through
/// `TelemetryScrubber`; only credentials come out (`FeedbackRedactor`), and
/// the window says how many.
///
/// Attachments are the person's choice per report, three at most: a picture
/// of Pacer's own window (rendered from Pacer's view hierarchy, never a screen
/// capture, and off by default because it shows costs and project names) and
/// any files they pick, 10 MB each.
struct FeedbackView: View {
    enum Phase: Equatable {
        case editing, sending, sent
        /// Not sent, with what to say (`FeedbackCopy.failure`, `tooLarge`).
        case failed(String)
        /// Today's five are spent: only the GitHub issue is left.
        case capped
    }

    /// A file someone picked, measured and typed once, at the pick.
    private struct PickedFile: Equatable {
        let url: URL
        let size: Int
        let contentType: String
    }

    let onClose: () -> Void

    @State private var kind: FeedbackKind
    @State private var phase: Phase
    @State private var message = ""
    @State private var email = ""
    @State private var includeWindow = false
    @State private var files: [PickedFile] = []
    @State private var filesNote: String?
    @FocusState private var editorFocused: Bool

    /// `phase` other than `.editing` is for a diagnostic render, which draws
    /// the failure state without a send to fail.
    init(kind: FeedbackKind = .idea, phase: Phase = .editing, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _kind = State(initialValue: kind)
        _phase = State(initialValue: phase)
    }

    private var attachmentCount: Int { files.count + (includeWindow ? 1 : 0) }
    private var isEmpty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The picked files alone; the window picture is measured at the send.
    private var filesFit: Bool { FeedbackSubmission.attachmentsFit(sizes: files.map(\.size)) }
    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if phase == .sent {
                Text("Sent. Thank you.")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction) }
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 460, height: phase == .sent ? 120 : 420)
        // The cursor waits in the box. Focus alone is not editing, so this
        // never holds an update back (`UpdateInstallPolicy.isEditing`).
        .onAppear { editorFocused = true }
    }

    @ViewBuilder private var form: some View {
        Picker("Kind", selection: $kind) {
            ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        // Read here, so the question follows the choice.
        Text(kind.prompt)
            .font(.headline)
        TextEditor(text: $message)
            .font(.body)
            .frame(minHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .focused($editorFocused)
        TextField("Email (optional, for a reply)", text: $email)
        Toggle("Include a picture of Pacer's window", isOn: $includeWindow)
            .disabled(!includeWindow && attachmentCount >= FeedbackSubmission.maxAttachments)
        HStack {
            Button("Add File…", action: addFiles)
                .disabled(attachmentCount >= FeedbackSubmission.maxAttachments)
            Text(files.map(\.url.lastPathComponent).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !files.isEmpty {
                Button("Remove") { files = []; filesNote = nil }.buttonStyle(.link).font(.caption)
            }
        }
        if let note = currentNote {
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        buttons
    }

    /// The one line under the form: what stops a send, or why it failed.
    private var currentNote: String? {
        switch phase {
        case .failed(let note): return note
        case .capped: return FeedbackCopy.capped
        case .editing, .sending, .sent: break
        }
        if !filesFit { return FeedbackCopy.tooLarge }
        if tooLong { return FeedbackCopy.tooLong }
        return filesNote
    }

    private var tooLong: Bool {
        FeedbackRedactor.redact(message).text.unicodeScalars.count > FeedbackSubmission.maxMessageCharacters
    }

    private var buttons: some View {
        HStack {
            // Counted as typed, so the note is there before Send is.
            if let note = FeedbackCopy.removed(FeedbackRedactor.redact(message).removed) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if phase == .sending { ProgressView().controlSize(.small) }
            Button("Cancel", action: onClose)
            // The fallback, only once the endpoint cannot take this report.
            if isFailed || phase == .capped || !filesFit {
                Button("Open GitHub Issue") { openIssue() }
                    .keyboardShortcut(phase == .capped ? KeyboardShortcut.defaultAction : nil)
            }
            if phase != .capped {
                Button(isFailed ? "Try Again" : "Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty || tooLong || !filesFit || phase == .sending)
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Only what the endpoint accepts; anything else it refuses.
        panel.allowedContentTypes = [.png, .jpeg, .plainText, .json, .quickTimeMovie]
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { url -> PickedFile? in
            guard let type = FeedbackSubmission.contentType(forFileExtension: url.pathExtension) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return PickedFile(url: url, size: size, contentType: type)
        }
        let room = max(0, FeedbackSubmission.maxAttachments - attachmentCount)
        let added = Array(picked.prefix(room))
        files.append(contentsOf: added)
        filesNote = added.count < panel.urls.count ? FeedbackCopy.filesLimit : nil
        if isFailed { phase = .editing }
    }

    private func send() {
        guard !isEmpty, !tooLong, filesFit, phase != .sending else { return }
        // Only the person's own app sends: never a render, a probe or a test.
        guard LaunchMode.isNormalLaunch else { phase = .failed(FeedbackCopy.failure(.failed(status: nil)) ?? ""); return }
        // On the main thread: it draws a window. Everything else goes off it.
        let windowPNG = includeWindow ? Self.mainWindowPNG() : nil
        let sizes = files.map(\.size) + (windowPNG.map { [$0.count] } ?? [])
        // Measured before the budget is spent: too large is fixed by removing
        // a file, not by spending one of the day's five.
        guard FeedbackSubmission.attachmentsFit(sizes: sizes) else { phase = .failed(FeedbackCopy.tooLarge); return }
        // Five a day per Mac: the endpoint is public, and this keeps a stuck
        // key or a repeated click from sending the same report all day.
        guard TelemetryBudget.shared.take(.feedback) else { phase = .capped; return }
        phase = .sending
        let context = FeedbackContext.current()
        let kind = kind
        let files = files
        let text = FeedbackRedactor.redact(message).text
        let email = email
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> FeedbackSender.Outcome in
                var attachments: [FeedbackSubmission.Attachment] = []
                if let windowPNG {
                    attachments.append(.init(filename: "pacer-window.png", contentType: "image/png", data: windowPNG))
                }
                for file in files {
                    guard let data = try? Data(contentsOf: file.url) else { continue }
                    attachments.append(.init(filename: file.url.lastPathComponent, contentType: file.contentType,
                                             data: data))
                }
                let submission = FeedbackSubmission(
                    kind: kind, message: text, email: email, appVersion: context.version.reportVersion,
                    appBuild: context.build, devDescribe: context.version.reportDescribe, macOS: context.macOS,
                    model: context.model, locale: context.locale, installId: context.installId,
                    attachments: attachments)
                // A file that grew since it was picked.
                guard submission.attachmentsFit else { return .failed(status: 413) }
                return await FeedbackSender.send(submission, userAgent: context.userAgent)
            }.value
            switch outcome {
            case .sent:
                Telemetry.breadcrumb("feedback", "feedback sent")
                Analytics.capture(.feedbackSent(kind: kind, via: .site))
                phase = .sent
            case .refused, .rateLimited, .failed:
                Log.write("Feedback", "send failed (\(outcome))")
                phase = .failed(FeedbackCopy.failure(outcome) ?? "")
            }
        }
    }

    /// Pacer's dashboard window, drawn from its own view hierarchy into a PNG.
    /// Not a screen capture: nothing outside Pacer's window can appear in it.
    private static func mainWindowPNG() -> Data? {
        let candidates = NSApp.windows.filter {
            $0.isVisible && $0.title != FeedbackCopy.windowTitle && $0.contentView != nil
        }
        guard let view = (candidates.first { $0.isMainWindow } ?? candidates.max { $0.frame.width < $1.frame.width })?
                .contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func openIssue() {
        var parts = URLComponents(string: "https://github.com/ericandrechek/Pacer/issues/new")!
        // The kind and the text; files are dragged into the issue there.
        parts.queryItems = [URLQueryItem(name: "body", value: kind.report(FeedbackRedactor.redact(message).text))]
        Analytics.capture(.feedbackSent(kind: kind, via: .github))
        if let url = parts.url { NSWorkspace.shared.open(url) }
        onClose()
    }
}

/// What a report says about the Mac it came from, read at the click.
private struct FeedbackContext: Sendable {
    let version: AppVersionLabel
    let build: String
    let macOS: String
    let model: String
    let locale: String?
    let installId: String?

    var userAgent: String { "Pacer/\(version.reportVersion)" }

    @MainActor static func current() -> FeedbackContext {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // The install id only while "Usage data" is on: it ties the report to
        // that install's usage events, which the toggle is the consent for.
        let installId = TelemetryController.analyticsAllowed
            ? AnalyticsIdentity.installId(in: URL(fileURLWithPath: TelemetryController.cacheDirectory))
            : nil
        return FeedbackContext(
            // The real build, not the README run's pinned label.
            version: UpdateStatus.currentVersion,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            macOS: "\(os.majorVersion).\(os.minorVersion)",
            model: DailyCheckIn.sysctlString("hw.model"),
            locale: FeedbackSubmission.locale(Locale.current.identifier),
            installId: installId)
    }
}
