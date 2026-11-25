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
        // The heading inside says what this is; the bar above it stays, for
        // the close button and for dragging, without a second title or a
        // line under it. The title is still the window's name in the Window
        // menu and to VoiceOver.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
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
/// Laid out as a composer, not a form. A heading that says who reads it, the
/// kind, then one box: the words, with what is attached and the two ways to
/// attach in its foot, so the extras are in reach and out of the way. Under
/// it the email and Send on one line. A one-line idea is: type, Send.
///
/// Sent to the site's feedback endpoint (`FeedbackSubmission`), which forwards
/// it to Sentry user feedback: the same path whatever the crash-reports toggle
/// says, and no GitHub account needed. A GitHub issue is offered only when
/// that send fails or today's limit is reached. The message is the person's
/// own words, sent on their click, so it is not run through
/// `TelemetryScrubber`; only credentials come out (`FeedbackRedactor`), of the
/// message and of any text or JSON file attached, and the window says how many.
///
/// Attachments are the person's choice per report, three at most: a picture
/// of Pacer's dashboard window (rendered from its own view hierarchy, never a
/// screen capture, and off by default because it shows costs and project
/// names) and any files they pick, 8 MB in all once encoded.
struct FeedbackView: View {
    enum Phase: Equatable {
        case editing, sending, sent
        /// Not sent, with what to say (`FeedbackCopy.failure`, `tooLarge`).
        case failed(String)
        /// Today's five are spent: only the GitHub issue is left.
        case capped
    }

    /// A file someone picked, read, typed and (for text) redacted once, after
    /// the pick and off the main thread. Its bytes are what is sent.
    private struct PickedFile: Equatable, Sendable {
        let filename: String
        let contentType: String
        let data: Data
        /// Credentials taken out of a text or JSON file.
        let removed: Int
    }

    let onClose: () -> Void
    /// A diagnostic render's filled-in window: a message, the window picture
    /// and a file, none of them real.
    private let isSample: Bool

    @State private var kind: FeedbackKind
    @State private var phase: Phase
    @State private var message = ""
    /// `FeedbackRedactor.redact(message)`, kept current by `.onChange(of:
    /// message)`: the body reads it three times, and a long paste is not worth
    /// three passes of a dozen patterns per keystroke.
    @State private var redaction = FeedbackRedactor.redact("")
    @State private var email = ""
    @State private var includeWindow = false
    /// The dashboard is on screen, so there is a window to picture. Refreshed
    /// when any window opens, closes, hides or comes forward.
    @State private var dashboardOpen = false
    @State private var files: [PickedFile] = []
    @State private var filesNote: String?
    @FocusState private var editorFocused: Bool

    /// `phase` other than `.editing` and `sample` are for a diagnostic render,
    /// which draws the failure, sent and filled-in states without a send.
    init(kind: FeedbackKind = .idea, phase: Phase = .editing, sample: Bool = false,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        isSample = sample
        _kind = State(initialValue: kind)
        _phase = State(initialValue: phase)
        if sample {
            let text = "The weekly chart goes back to Monday when I switch accounts. Token: sk-ant-api03-\(String(repeating: "a", count: 40))"
            _message = State(initialValue: text)
            _redaction = State(initialValue: FeedbackRedactor.redact(text))
            _email = State(initialValue: "sam@example.com")
            _includeWindow = State(initialValue: true)
            _files = State(initialValue: [PickedFile(filename: "Pacer.err.log", contentType: "text/plain",
                                                     data: Data("log".utf8), removed: 0)])
        }
    }

    private var attachmentCount: Int { files.count + (includeWindow ? 1 : 0) }
    private var isEmpty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The picked files alone; the window picture is measured at the send.
    private var filesFit: Bool { FeedbackSubmission.attachmentsFit(sizes: files.map(\.data.count)) }
    private var emailIsValid: Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty || FeedbackSubmission.isEmail(address)
    }
    private var tooLong: Bool {
        redaction.text.unicodeScalars.count > FeedbackSubmission.maxMessageCharacters
    }
    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var body: some View {
        Group {
            if phase == .sent {
                sent
            } else {
                form
            }
        }
        .frame(width: 480, height: phase == .sent ? 220 : 344)
        // The cursor waits in the box. Focus alone is not editing, so this
        // never holds an update back (`UpdateInstallPolicy.isEditing`).
        .onAppear {
            editorFocused = true
            refreshDashboardOpen()
        }
        .onChange(of: message) { _, new in redaction = FeedbackRedactor.redact(new) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            // After the close, which this notification comes just before.
            DispatchQueue.main.async { refreshDashboardOpen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
            refreshDashboardOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            refreshDashboardOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            refreshDashboardOpen()
        }
    }

    private var sent: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .padding(.bottom, 2)
            Text(FeedbackCopy.sentTitle)
                .font(.title2)
                .fontWeight(.semibold)
            Text(FeedbackCopy.sentDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("PacerLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FeedbackCopy.heading)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(FeedbackCopy.subheading)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Kind", selection: $kind) {
                ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            composer
            if let note = currentNote {
                // A send that did not go through is a warning; a limit or an
                // unfinished email is only a note.
                Label(note, systemImage: noteIsWarning ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(noteIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(.horizontal, 22)
        // Under the window's own (empty) title bar.
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// The words, and in the same box what goes with them. The editor takes
    /// the height the window has left, so an attachment or a note below
    /// borrows from it rather than moving the window.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                // The editor insets its own text five points.
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
                .frame(minHeight: 64, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    // Read here, so the question follows the choice.
                    Text(kind.prompt)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .opacity(message.isEmpty ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(kind.prompt)
            attachments
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(editorFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                              lineWidth: editorFocused ? 1.5 : 1)
        )
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachmentCount > 0 {
                HStack(spacing: 6) {
                    if includeWindow {
                        AttachmentChip(title: FeedbackCopy.windowAttachment, systemImage: "macwindow") {
                            includeWindow = false
                            attachmentRemoved()
                        }
                    }
                    ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                        AttachmentChip(title: file.filename, systemImage: Self.symbol(for: file.contentType)) {
                            if files.indices.contains(index) { files.remove(at: index) }
                            attachmentRemoved()
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                Button(action: addFiles) {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        Text(FeedbackCopy.attachFile)
                    }
                }
                .disabled(attachmentCount >= FeedbackSubmission.maxAttachments)
                Button {
                    includeWindow = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow.badge.plus")
                        Text(FeedbackCopy.attachWindow)
                    }
                }
                .disabled(!dashboardOpen || includeWindow || attachmentCount >= FeedbackSubmission.maxAttachments)
                .help(dashboardOpen ? FeedbackCopy.attachWindowHelp : FeedbackCopy.attachWindowClosedHelp)
                Spacer(minLength: 0)
                // Counted as typed (and as files are added), so the note is
                // there before Send is.
                let removed = redaction.removed + files.reduce(0) { $0 + $1.removed }
                if let note = FeedbackCopy.removed(removed) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 9)
    }

    private static func symbol(for contentType: String) -> String {
        if contentType.hasPrefix("image/") { return "photo" }
        if contentType.hasPrefix("video/") { return "film" }
        return "doc.text"
    }

    /// One fewer to send: the limit note no longer holds, and a send that
    /// failed for size can be tried again.
    private func attachmentRemoved() {
        filesNote = nil
        if isFailed { phase = .editing }
    }

    /// The one line above the buttons: what stops a send, or why it failed.
    private var currentNote: String? {
        switch phase {
        case .failed(let note): return note
        case .capped: return FeedbackCopy.capped
        case .editing, .sending, .sent: break
        }
        if !filesFit { return FeedbackCopy.tooLarge }
        if tooLong { return FeedbackCopy.tooLong }
        if !emailIsValid { return FeedbackCopy.badEmail }
        return filesNote
    }

    private var noteIsWarning: Bool { isFailed || phase == .capped || !filesFit }

    private var actions: some View {
        HStack(spacing: 8) {
            TextField(FeedbackCopy.emailPrompt, text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .frame(minWidth: 140)
            if phase == .sending { ProgressView().controlSize(.small) }
            // The fallback, only once the endpoint cannot take this report.
            if isFailed || phase == .capped || !filesFit {
                Button("Open GitHub Issue") { openIssue() }
                    .keyboardShortcut(phase == .capped ? KeyboardShortcut.defaultAction : nil)
            }
            if phase != .capped {
                Button {
                    send()
                } label: {
                    Text(isFailed ? "Try Again" : "Send").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isEmpty || tooLong || !filesFit || !emailIsValid || phase == .sending)
            }
        }
    }

    private func refreshDashboardOpen() {
        guard !isSample else { dashboardOpen = true; return }
        dashboardOpen = Self.dashboardWindow() != nil
        if !dashboardOpen { includeWindow = false }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Only what the endpoint accepts; anything else it refuses.
        panel.allowedContentTypes = [.png, .jpeg, .plainText, .json, .quickTimeMovie]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        let room = max(0, FeedbackSubmission.maxAttachments - attachmentCount)
        if isFailed { phase = .editing }
        // Read off the main thread: a file can be 8 MB, and redacting a large
        // log is a few passes over it.
        Task { @MainActor in
            let picked = await Task.detached(priority: .userInitiated) { Self.read(urls) }.value
            let added = Array(picked.prefix(room))
            files.append(contentsOf: added)
            filesNote = added.count < urls.count ? FeedbackCopy.filesLimit : nil
        }
    }

    /// The files that can go: an accepted type, not empty, 8 MB or less, read
    /// whole; text and JSON with their credentials taken out.
    private nonisolated static func read(_ urls: [URL]) -> [PickedFile] {
        urls.compactMap { url -> PickedFile? in
            guard let type = FeedbackSubmission.contentType(forFileExtension: url.pathExtension),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= FeedbackSubmission.maxAttachmentBytes,
                  var data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
            var removed = 0
            if type == "text/plain" || type == "application/json", let text = String(data: data, encoding: .utf8) {
                let clean = FeedbackRedactor.redact(text)
                data = Data(clean.text.utf8)
                removed = clean.removed
            }
            return PickedFile(filename: FeedbackSubmission.cleanFilename(url.lastPathComponent),
                              contentType: type, data: data, removed: removed)
        }
    }

    private func send() {
        guard !isEmpty, !tooLong, filesFit, emailIsValid, phase != .sending else { return }
        // Only the person's own app sends: never a render, a probe or a test.
        guard LaunchMode.isNormalLaunch else { phase = .failed(FeedbackCopy.failure(.failed(status: nil)) ?? ""); return }
        // On the main thread: it draws a window. Everything else goes off it.
        let windowPNG = includeWindow ? Self.dashboardPNG() : nil
        var attachments = files.map {
            FeedbackSubmission.Attachment(filename: $0.filename, contentType: $0.contentType, data: $0.data)
        }
        if let windowPNG {
            attachments.insert(.init(filename: "pacer-window.png", contentType: "image/png", data: windowPNG), at: 0)
        }
        let context = FeedbackContext.current()
        let submission = FeedbackSubmission(
            kind: kind, message: redaction.text, email: email, appVersion: context.version.reportVersion,
            appBuild: context.build, devDescribe: context.version.reportDescribe, macOS: context.macOS,
            model: context.model, locale: context.locale, installId: context.installId,
            attachments: attachments)
        // Measured before the budget is spent: too large is fixed by removing
        // a file, not by spending one of the day's five.
        guard submission.attachmentsFit else { phase = .failed(FeedbackCopy.tooLarge); return }
        // Five a day per Mac: the endpoint is public, and this keeps a stuck
        // key or a repeated click from sending the same report all day.
        guard TelemetryBudget.shared.take(.feedback) else { phase = .capped; return }
        phase = .sending
        let kind = kind
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                await FeedbackSender.send(submission, userAgent: context.userAgent)
            }.value
            switch outcome {
            case .sent:
                Telemetry.breadcrumb("feedback", "feedback sent")
                Analytics.capture(.feedbackSent(kind: kind, via: .site))
                phase = .sent
            case .refused, .rateLimited, .failed:
                // Only what the server kept, or rate-limited, spends one of
                // the day's five; a report it never took is given back, so
                // fixing it or coming back online can still send.
                if outcome != .rateLimited { TelemetryBudget.shared.refund(.feedback) }
                Log.write("Feedback", "send failed (\(outcome))")
                phase = .failed(FeedbackCopy.failure(outcome) ?? "")
            }
        }
    }

    /// The dashboard window, by the identity the app registered for it
    /// (`MainWindowPlacement.isDashboard`), when it is on screen.
    private static func dashboardWindow() -> NSWindow? {
        NSApp.windows.first { MainWindowPlacement.isDashboard($0) && $0.isVisible && $0.contentView != nil }
    }

    /// The dashboard, drawn from its own view hierarchy into a PNG. Not a
    /// screen capture: nothing outside Pacer's window can appear in it.
    private static func dashboardPNG() -> Data? {
        guard let view = dashboardWindow()?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func openIssue() {
        var parts = URLComponents(string: "https://github.com/ericandrechek/Pacer/issues/new")!
        // The kind and the text; files are dragged into the issue there.
        parts.queryItems = [URLQueryItem(name: "body", value: kind.report(redaction.text))]
        Analytics.capture(.feedbackSent(kind: kind, via: .github))
        if let url = parts.url { NSWorkspace.shared.open(url) }
        onClose()
    }
}

/// Something attached, with a way to take it back off.
private struct AttachmentChip: View {
    let title: String
    let systemImage: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            // As wide as its name, up to a limit: a long file name loses its
            // middle rather than pushing the next chip out of the box.
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120)
                .fixedSize()
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove \(title)")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
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
