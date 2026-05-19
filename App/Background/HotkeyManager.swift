import AppKit
import Carbon

/// Global hotkey registration using the Carbon `RegisterEventHotKey`
/// API. SwiftUI's `keyboardShortcut` modifier only works while Pacer is
/// the foreground app; a global hotkey reaches us regardless of which
/// app has focus, which is the whole point — the user wants to peek at
/// Pacer's dashboard without leaving their editor / browser.
///
/// Default binding is ⌥⌘P. We register at app launch; the hotkey fires
/// `.pacerHotkeyToggleWindow` on the main queue, which
/// `PacerAppDelegate` translates into the same "bring main window
/// forward + activate" flow used by the status-menu "Open Pacer" item.
///
/// Carbon hotkey APIs are stable on macOS 15 (despite Carbon's general
/// deprecation) and are what every major menu-bar app uses for global
/// shortcuts — there's no Swift / AppKit replacement. The trampoline
/// dance is unavoidable because `InstallEventHandlerProc` is a C
/// callback that can't capture Swift state directly.
@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    /// `OSType` derived from the 4-byte "PCR1" tag — uniquely
    /// identifies our hotkey within the application's hotkey set.
    /// Other apps' hotkeys live under their own signatures so there
    /// is no collision risk.
    private static let signature: OSType = {
        let bytes: [UInt8] = [80, 67, 82, 49]  // "PCR1"
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }()
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isRegistered = false

    /// Default binding: ⌥⌘P. Easy to remember (P for Pacer), unused by
    /// macOS-system shortcuts and by every major app on a typical
    /// developer's machine.
    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_P)
    static let defaultModifierFlags: UInt32 = UInt32(cmdKey | optionKey)

    private init() {}

    /// Register the default global hotkey. Idempotent — calling twice
    /// is a no-op. Logs and returns silently on failure (the user
    /// can still reach Pacer via the menu bar / Dock).
    func registerDefaultHotkey() {
        guard !isRegistered else { return }

        // Install the global event handler first so the OS has
        // somewhere to dispatch the press before the RegisterEventHotKey
        // call completes.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                // Hop to the main queue for the SwiftUI / NotificationCenter
                // work. The Carbon callback fires on whatever thread the
                // OS uses, and `NSApp.activate` is not thread-safe.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .pacerHotkeyToggleWindow,
                        object: nil
                    )
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            log("InstallEventHandler failed (status=\(handlerStatus))")
            return
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let registerStatus = RegisterEventHotKey(
            Self.defaultKeyCode,
            Self.defaultModifierFlags,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            isRegistered = true
            log("registered ⌥⌘P")
        } else {
            // Most common failure: another app has the same chord
            // registered. Carbon returns `eventHotKeyExistsErr`
            // (-9878) in that case. We log and continue — the user
            // can still launch via the menu bar.
            log("RegisterEventHotKey failed (status=\(registerStatus))")
            if let ref = eventHandlerRef {
                RemoveEventHandler(ref)
                eventHandlerRef = nil
            }
        }
    }

    /// Unregister and tear down. Called on app termination (best-
    /// effort; the OS reclaims hotkeys when the process exits).
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        isRegistered = false
    }

    private func log(_ message: String) {
        // FileHandle write avoids pulling PacerCore.Log into the
        // hotkey path; we want this to work even if PacerCore isn't
        // fully bootstrapped.
        FileHandle.standardError.write(Data("[Pacer/Hotkey] \(message)\n".utf8))
    }
}

extension Notification.Name {
    /// Posted by `HotkeyManager` when the user presses the registered
    /// global hotkey. `PacerAppDelegate` observes this and brings the
    /// main window forward (or hides it if it's already key and
    /// frontmost — toggle behavior matches the user's expectation
    /// from menu-bar app conventions).
    static let pacerHotkeyToggleWindow = Notification.Name("PacerHotkeyToggleWindow")
}
