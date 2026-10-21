# macOS notifications — what Pacer can do with them

Research only, 2026-10-21. Nothing in the app has changed. Sources: the macOS
27.0 SDK headers installed with Xcode (ground truth for what exists), Xcode's
capability catalogue (for entitlements), Apple's Mac Help and developer docs,
and an audit of Pacer's current notification code and its own log.

## Short answers

- **"Show briefly, then go away."** macOS decides this, and the user sets it
  per app. On macOS 27, System Settings → Notifications → Pacer offers
  **Temporary** (gone after about 5 seconds) or **Persistent** (stays until
  dismissed). Older releases call these Banners and Alerts. An app cannot set
  the style, and it cannot change how long a banner stays up. Pacer *can*
  **read** which style the user picked, and it can **remove its own
  notifications at any time**. So a "clear after N minutes" option is possible.
  Whether removing one also takes a Persistent alert off the screen is
  untested.
- **"Replace the old one when a new one comes in."** Yes, fully in Pacer's
  hands: post with the same identifier. The SDK header says the replacement
  *alerts again*, with banner and sound. There is no "update quietly" flag.
  The only way to make a replacement quiet is to send it `.passive` and with no
  sound.
- **Grouping.** `threadIdentifier` works on macOS, so alerts could stack per
  window or per account. The "3 more from Pacer" summary text
  (`categorySummaryFormat`, `summaryArgument`) is iOS-only.
- **Nothing new in UserNotifications for macOS 26 or 27.** The API surface has
  been unchanged since macOS 13, apart from one messaging-only type added in 15.
  The new things in 26 and 27 are *around* notifications: Controls, Spotlight
  snippets, Focus, and on-device models.

## Probably wrong today (found along the way)

1. **Alerts that fire while Pacer is the active app are not shown.** Pacer has
   no `UNUserNotificationCenterDelegate`. The header is explicit (see the quote
   below): without `willPresent`, "the notification will not be presented".
   That bites whenever the dashboard window has focus.
2. **`.timeSensitive` is requested without the entitlement.** Most of Pacer's
   alerts ask for `.timeSensitive` (thresholds, early reset, spend, project
   budget, custom rules, imminent burn). It does not have
   `com.apple.developer.usernotifications.time-sensitive`.
   - The entitlement is open to **Developer ID with no Apple approval**
     (Xcode's capability catalogue).
   - The old authorization option for it is deprecated with the note "Use
     time-sensitive entitlement".
   - So these alerts very likely behave as `.active` and do not break through
     Focus. Checking costs no screen time: read
     `notificationSettings().timeSensitiveSetting` from inside Pacer.
3. **Clicking an alert goes nowhere in particular.** There is no `didReceive`
   handler, no `userInfo`, no categories and no actions. What a click does to an
   LSUIElement app with no window open is untested.
4. **Nothing is ever replaced or cleared.** Every alert has a unique identifier
   (dedup key = identifier, `NotificationCoordinator.swift:201`). Burn-rate
   tiers are kept distinct on purpose (`:478`). So 50 → 75 → 90% leaves three
   entries, and they stay after the window resets.
   - The real log shows about 15–20 alerts a day.
   - It shows **bursts on account switches**: three posted within 40 ms, when a
     switch lands on an account already past several thresholds.
5. *Latent, not live:* the dedup key embeds the exact `resetsAt`. That value
   jitters by a second between polls (AGENTS.md rule 9), so the same threshold
   could in principle fire twice in one cycle. It has never happened (0 of 49
   alerts in the log), because `AlertCrossingState` also needs an upward
   crossing. Worth fixing if the identifiers change anyway.

## The menu — what we could experiment with

### Notification behaviour (UserNotifications, all macOS ≤ 13, so fine on 15.0+)

| Idea | How | Effort | Notes |
|---|---|---|---|
| **Latest only per window** | one identifier per window + account; 90% replaces 75% | S | Re-alerts by design; keeps dedup as-is (dedup lives in `ClaudeCodeMeta`, not in the identifier) |
| **Clear on reset** | `removeDeliveredNotifications` for a window's warnings when it resets, or let the reset notice replace them | S | Stale "you're at 95%" disappears once it is no longer true |
| **Clear after N minutes** | in-process timer → `removeDeliveredNotifications` | S | Pacer is always running, so the timer is reliable. Effect on an on-screen Persistent alert: untested |
| **Stack per window/account** | `threadIdentifier = "five_hour#<acct>"` | S | Keeps history but collapsed. How Notification Center's "Automatic" grouping treats it: untested |
| **Escalating loudness** | 50% `.passive` silent → 75% `.active` → 90% `.timeSensitive` + sound | S | Needs the entitlement (above) for the top tier to mean anything |
| **Severity ordering** | `relevanceScore` 0–1 from the % (`UNNotificationContent.h:84`) | S | Header: "sorting" across the app's notifications. Visible effect on macOS: untested |
| **Foreground policy** | delegate `willPresent` → `[.banner, .list, .sound]`, or suppress only when the dashboard already shows that window | S | Apple's guidance is to decide by "whether the information … is otherwise visible" |
| **Buttons on the alert** | categories + `UNNotificationAction` with SF Symbol icons (macOS 12): *Mute this window until reset*, *Snooze 1 h*, *Open Pacer* | M | Needs the delegate's `didReceive`; registered before launch returns |
| **Click opens the right place** | `userInfo` carries window + account; click → dashboard scoped to it | S–M | |
| **Picture in the alert** | `UNNotificationAttachment` of a rendered gauge or pace chart PNG (Pacer already renders off-screen) | M | Thumbnail rendering on Mac and size limits: untested |
| **Live chart in the expanded alert** | `UNNotificationContentExtension` (UserNotificationsUI, macOS 11) | L | New appex target. The header says it is re-called when a new alert with the same `threadIdentifier` arrives, so it can update in place |
| **Scheduled alerts** | `UNCalendarNotificationTrigger` at `resetsAt`, delivered by the system even if Pacer has quit; replace or cancel when the reset moves | S–M | e.g. "5-hour window just reset". The system caps how many can be pending |
| **Show the macOS setting in Pacer** | read `alertStyle` (Temporary/Persistent), `timeSensitiveSetting`, `notificationCenterSetting`; show them next to the existing "Open System Settings" link | S | Answers "why did/didn't it stay on screen?" in one line |
| **Settings button inside System Settings** | authorize with `.providesAppNotificationSettings`, handle `openSettingsFor` → Pacer's Settings tab | S | Adds "Pacer Notification Settings…" to the system pane |
| **Own sounds** | short sound files in the bundle (`Library/Sounds` or bundle), one per severity | S | Length limits on Mac: untested |
| **Per-Focus behaviour** | `SetFocusFilterIntent` (App Intents, macOS 13): e.g. a "Work" Focus raises the threshold or goes quiet | S–M | `filterCriteria` on the content (macOS 13) exists but has no documentation in the SDK |

### Around notifications (new surfaces)

| Idea | Availability | Effort | Notes |
|---|---|---|---|
| **Control: "Mute alerts 1 h" / "5h 62%" button** in Control Center or the menu bar | `ControlWidget`, macOS 26 (WidgetKit swiftinterface:1139) | S–M | Lives in the existing widget extension. Gate with `@available(macOS 26, *)`. The only glanceable surface that is also an action |
| **Interactive widget button** (Mute / Refresh on PaceGauges) | App Intents widgets, macOS 14 | S–M | |
| **Status in Spotlight** | `SnippetIntent`, macOS 26 | S | The intents already exist; mostly view code |
| **Status item that widens only when it matters** | no new API | S | macOS 27 folds menu bar items into an overflow (web report), so a narrow item survives better. No animation (AGENTS.md anti-pattern 1) |
| **Spoken alert** (opt-in) / VoiceOver announcement | `AVSpeechSynthesizer`; `NSAccessibilityAnnouncementRequested` | S | |
| **On-device wording / daily summary** | Foundation Models, macOS 26 (eligible Macs only) | S–M | Optional polish with a template fallback. Never route numbers through the model |
| Dock badge | `NSDockTile` / `setBadgeCount` | S | Only visible while the window is open (Dock icon is `.regular` only then). Low value |

### Not available, so don't plan on it

- **Live Activities from a Mac app.** ActivityKit's `Activity` is
  `@available(macOS, unavailable)`. macOS 26's menu bar only mirrors an
  iPhone's. That would need the iOS companion.
- **Smart widget rotation.** `RelevanceConfiguration` is macOS-unavailable.
- **AlarmKit.** Not in the macOS SDK.
- **Critical alerts.** The entitlement needs Apple's approval, and the
  critical-sound APIs are iOS/watchOS-only.
- **Setting the alert style or banner duration.** Both are the user's. The
  only known duration knob is an undocumented per-machine `defaults` key for
  Notification Center. Pacer has no business writing it.
- **Summary text for a stack** (`categorySummaryFormat`, `summaryArgument`).
  iOS-only.

## What changed by release

- **macOS 15.** UserNotifications added only
  `UNNotificationAttributedMessageContext` (messaging). Widgets gained accented
  rendering mode, so check Pacer's widgets under tinted desktops.
- **macOS 26.** No UserNotifications changes. New around it: Controls on Mac,
  push-updated widgets (needs APNs, poor fit for a local app), `SnippetIntent`,
  Foundation Models, and Shortcuts automations on Mac (web report: time,
  folder, app open/quit, Focus triggers; no app-defined triggers, so a Shortcut
  can't listen for a Pacer threshold directly).
- **macOS 27.** No UserNotifications changes in the SDK.
  - Mac Help calls the styles **Temporary** and **Persistent**.
  - Apple Intelligence summaries are a per-app toggle, and the "Reduce
    Interruptions" Focus lets through what "may need prompt attention". No
    documented way for an app to influence either.
  - New `systemExtraLargePortrait` widget family.
  - A menu bar overflow for status items (web report).
  - Unconfirmed beta coverage mentions new Shortcuts notification automations,
    which are worth a look if they let a Shortcut react to an app's
    notifications.

## Open questions — need one prepared run on a real Mac

These cannot be settled from headers or the web:

1. A same-identifier replacement: does it replay the sound and banner on macOS
   (the header says it alerts), and does a `.passive` replacement stay quiet?
2. Does `removeDeliveredNotifications` take a **Persistent** alert off the
   screen, and how fast?
3. Does `.passive` show any banner on Mac, or go straight to Notification
   Center?
4. When does an LSUIElement / `.accessory` app count as "foreground" for
   `willPresent`? Window open but not focused? Popover open?
5. How do `threadIdentifier` stacks look under each grouping setting
   (Automatic / By Application / Off)?
6. Do attachments render as a thumbnail, and do actions show as buttons or an
   Options menu?
7. Is `timeSensitiveSetting` `.notSupported` for today's build? This one needs
   no screen: an env-gated probe inside Pacer can log it.

**How to test without disturbing anything.** Use a tiny scratch app with its
**own bundle id**, so experiments never touch Pacer's real notification
settings or history. It posts a fixed sequence and reports a **verdict, not a
photograph**:

- `getDeliveredNotifications` for what Notification Center holds;
- the window server's window list (owner `NotificationCenter`, bounds only) for
  what is on screen.

This is the same shape AGENTS.md asks for after the tooltip harness: it posts
banners on the owner's screen but takes no input, focus or windows, and it
runs once, scripted, with his go-ahead for that run. Question 7 can go first,
since it needs nothing on screen.

## Sources

SDK: `MacOSX27.0.sdk`, `UserNotifications.framework/Headers`.

- `UNUserNotificationCenter.h:62`: "Calling -addNotificationRequest: will
  replace an existing notification request with the same identifier. A
  notification request with the identifier as an existing delivered
  notifications will alert for the new notification request and replace the
  existing delivered notification when it is triggered."
- `UNUserNotificationCenter.h:96`: "The method will be called on the delegate
  only if the application is in the foreground. If the method is not
  implemented or the handler is not called in a timely manner then the
  notification will not be presented. … This decision should be based on
  whether the information in the notification is otherwise visible to the
  user."
- `UNUserNotificationCenter.h:99`: the `didReceive` delegate "must be set
  before the application returns from application:didFinishLaunching…".
- `UNNotificationContent.h:21–31`: interruption levels.
  - Passive: "does not light up screen or play sound".
  - Time Sensitive: "may be presented during Do Not Disturb".
  - Critical: "always presented".
- `UNNotificationContent.h:60, 84, 86`: `threadIdentifier` (macOS),
  `relevanceScore` (macOS 12), `filterCriteria` (macOS 13). Lines 69/75:
  `summaryArgument*` is iOS-only, deprecated and "ignored".
- `UNNotificationCategory.h:58`: `categorySummaryFormat` is `ios(12.0)` only.
- `UNNotificationContentExtension.h:117–121`: re-called for a new alert with a
  matching `threadIdentifier`.
- `UNNotificationAttributedMessageContext.h:15`: the only macOS 15 addition.
- `ActivityKit … macos.swiftinterface`: `Activity` is
  `@available(macOS, unavailable)`.
- `WidgetKit … macos.swiftinterface`:
  - `:1139` `ControlWidget*` is macOS 26.
  - `:255` `RelevanceConfiguration` is macOS-unavailable.
  - `:820` `WidgetPushHandler` is macOS 26.
  - `:940` `systemExtraLargePortrait`.
- Xcode `DVTPortalCachedPortalCapabilities.json`, `USERNOTIFICATIONS_TIMESENSITIVE`:
  supports macOS and Developer ID, `distributionApprovalRequired: false`.

Web:

- Mac Help, notification settings (macOS 27): https://support.apple.com/guide/mac-help/notifications-settings-mh40583/mac
- Mac Help, Apple Intelligence notifications: https://support.apple.com/guide/mac-help/mchldf5e4cb6
- `UNNotificationRequest.identifier`: https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier
- WWDC21 "Send communication and Time Sensitive notifications" (interruption levels, relevance): https://developer.apple.com/videos/play/wwdc2021/10091
- No WWDC24–26 session on notifications turned up. That isn't proof there
  isn't one.

Pacer:

- `App/Notifications/NotificationCoordinator.swift` (every post site goes
  through `post()` and logs `[Notify] posted <id>`)
- `App/Notifications/AlertMonitor.swift`
- `App/Pacer.entitlements`
- `App/Info.plist`: no `NSUserNotificationAlertStyle`, so the system default
  applies.
