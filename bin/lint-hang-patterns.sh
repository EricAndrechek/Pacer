#!/usr/bin/env bash
# lint-hang-patterns.sh — flag the code shapes behind Pacer's production hangs
# and the 0.9.0 crash, before they ship again.
#
# Every rule here is a pattern Sentry has already reported from a user's Mac:
#
#   un-sync               A synchronous UNUserNotificationCenter remove/get/set
#                         call outside an off-main wrapper. They wait on the
#                         notification daemon over XPC: 2 s+ on the main thread
#                         at launch (PACER-1G).
#   query-always-mounted  `@Query` in a view that never unmounts (menu bar,
#                         window shell and toolbar, Now strip, delegate-hosted
#                         views). `@Query` re-fetches on every save of its
#                         context, on the main thread (PACER-19, #408).
#   formatter-in-body     A formatter or regex built, or a date string parsed,
#                         inside a view body or another `some View`/
#                         `ChartContent` builder: once per mark, per body pass
#                         (PACER-1E, PACER-1D).
#   fetch-in-body         A SwiftData fetch inside a view builder: on the main
#                         context, on every body pass.
#   stderr-write          `FileHandle.standardError.write` and friends. A
#                         synchronous stderr write on the main thread hung
#                         (PACER-15); FileHandle's on a GCD worker overflowed its
#                         512 KB stack (the 0.9.0 crash). Use `Log.write`.
#   smappservice-status   `SMAppService.….status` (and `currentStatus()` outside
#                         its wrapper): a synchronous XPC call to smd, 2 s+ on
#                         main (PACER-N). Use `LoginItemController.statusOffMain`.
#   main-sync             `DispatchQueue.main.sync`: deadlocks when already on
#                         main, and blocks the caller on a busy main thread.
#   terminate-call        `NSApp.terminate`. Pacer answers `.terminateLater` and
#                         replies from a main-actor Task; called inside a
#                         main-queue block or a main-actor Task, terminate's
#                         nested run loop never services the main queue, so the
#                         reply never comes (the SIGTERM handler, found by the
#                         on-machine relauncher check). Every call says why its
#                         context is safe: an AppKit action, or a run-loop block.
#
# It is a grep, not a compiler: it reads the source line by line and knows
# nothing about actors. That is the point — it is fast enough for every push
# and has no false negatives for these exact shapes. A site that is fine for a
# reason the grep cannot see carries an allow marker, on the line or the line
# directly above it:
#
#     // lint:allow <rule> <why it is fine here>
#
# The reason is required; a marker without one is itself a finding. Code that
# another branch owns and is already fixing goes in the baseline
# (bin/lint-hang-patterns.baseline) instead, matched on its source text, so the
# entry stops matching — and is reported as stale — once the fix lands.
#
# Usage: bin/lint-hang-patterns.sh [file ...]   (default: App Widgets PacerCore/Sources)
#        bin/lint-hang-patterns.sh --self-test   (the rules against a fixture)
# Exit:  0 clean, 1 findings.

set -euo pipefail

cd "$(dirname "$0")/.."
BASELINE="bin/lint-hang-patterns.baseline"

# The rules against a fixture with a known answer, so a change to the awk
# cannot quietly stop a rule from firing.
if [[ "${1:-}" == "--self-test" ]]; then
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cat > "$dir/Fixture.swift" <<'SWIFT'
import SwiftUI
struct A: View {
    var body: some View {
        let f = DateFormatter()
        Text(f.string(from: .now))
        // lint:allow formatter-in-body the fixture says so
        let g = NumberFormatter()
        let d = ISO8601DateFormatter().date(from: "x")
        let rows = try? context.fetch(FetchDescriptor<Foo>())
    }
    private static let fine = DateFormatter()
    private var chip: some View {
        Text("\(Self.parse.date(from: key))")
    }
}
func f() {
    center.removeDeliveredNotifications(withIdentifiers: ids)
    OffMainQueue.notifications.run { center.setNotificationCategories(c) }
    center.getDeliveredNotifications { delivered in
        center.removeDeliveredNotifications(withIdentifiers: stale)
    }
    Task.detached {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    await center.deliveredNotifications()
    DispatchQueue.main.sync { }
    let s = SMAppService.mainApp.status
    FileHandle.standardError.write(Data("x".utf8)) // lint:allow stderr-write
    let msg = "FileHandle.standardError.write is only a string"
    /// SMAppService.mainApp.status in a doc comment
    NSApp.terminate(nil)
    // lint:allow terminate-call an NSMenu action, called from event handling
    NSApplication.shared.terminate(self)
}
SWIFT
    expected=$'4 formatter-in-body\n8 formatter-in-body\n9 fetch-in-body\n13 formatter-in-body\n17 un-sync\n19 un-sync\n26 main-sync\n27 smappservice-status\n28 allow-without-reason\n28 stderr-write\n31 terminate-call'
    actual=$(bin/lint-hang-patterns.sh "$dir/Fixture.swift" 2>/dev/null \
        | sed -nE 's/^[^:]+:([0-9]+): \[([a-z-]+)\].*/\1 \2/p' || true)
    if [[ "$actual" == "$expected" ]]; then
        echo "lint-hang-patterns self-test: ok"; exit 0
    fi
    echo "lint-hang-patterns self-test FAILED"
    diff <(echo "$expected") <(echo "$actual") || true
    exit 1
fi

if (($#)); then
    files=("$@")
else
    files=()
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find App Widgets PacerCore/Sources -name '*.swift' -print0 | sort -z)
fi

baseline_file="$BASELINE"
[[ -f "$baseline_file" ]] || baseline_file=/dev/null

# The view files that stay mounted for the life of the process or the window,
# whatever tab is showing. A view moved into one of these must not hold a
# `@Query`; a new always-mounted file belongs on this list.
always_mounted='^App/(ContentView\.swift|Views/MenuBar[A-Za-z]*\.swift|Views/AccountScopeControl\.swift|Views/NowStrip\.swift|Background/[A-Za-z]+\.swift|Notifications/[A-Za-z]+\.swift)$'

awk -v baseline="$baseline_file" -v always_mounted="$always_mounted" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Source text with string literals blanked and any trailing // comment cut,
# so neither a doc comment nor a log message can trip a rule.
function code_of(line,    c) {
    c = line
    gsub(/\\\\/, "", c)
    gsub(/\\"/, "", c)
    gsub(/"[^"]*"/, "\"\"", c)
    sub(/\/\/.*$/, "", c)
    return c
}

# Source text with only a trailing // comment cut. Strings are kept, so a
# formatter built inside an interpolation ("\\(DateFormatter()…)") is seen.
# A "//" with no space before it (a URL) is not a comment.
function code_keep_strings(line,    c) {
    c = line
    sub(/(^|[ \t])\/\/.*$/, "", c)
    return c
}

function count(s, ch,    n, i) {
    n = 0
    for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
    return n
}

# An allow marker for `rule` on this line or the one above.
function allowed(rule, line, prev) {
    return (line ~ ("lint:allow " rule "[ \t]+[^ \t]")) || (prev ~ ("lint:allow " rule "[ \t]+[^ \t]"))
}

function report(rule, msg,    key) {
    key = rule "\t" FILENAME "\t" trim($0)
    if (key in base) { base_hit[key] = 1; suppressed++; return }
    printf "%s:%d: [%s] %s\n    %s\n", FILENAME, FNR, rule, msg, trim($0)
    findings++
}

BEGIN {
    findings = 0; suppressed = 0
    while ((getline b < baseline) > 0) {
        if (b ~ /^[ \t]*(#|$)/) continue
        base[b] = 1; base_order[++nbase] = b
    }
    un_sync = "\\.(removePendingNotificationRequests|removeDeliveredNotifications|removeAllPendingNotificationRequests|removeAllDeliveredNotifications|getDeliveredNotifications|getPendingNotificationRequests|getNotificationSettings|getNotificationCategories|setNotificationCategories)[ \t]*[({]"
    off_main = "OffMainQueue\\.[A-Za-z]+\\.run|Task\\.detached|DispatchQueue\\.global|\\.async[ \t]*[({]|get(Delivered|Pending)[A-Za-z]*[ \t]*[({]"
    formatter = "(DateFormatter|ISO8601DateFormatter|NumberFormatter|RelativeDateTimeFormatter|DateComponentsFormatter|DateIntervalFormatter|ByteCountFormatter|MeasurementFormatter|ListFormatter|PersonNameComponentsFormatter)[ \t]*\\([ \t]*\\)|NSRegularExpression[ \t]*\\(|try!?[ \t]+Regex[ \t]*\\(|\\.date\\(from:"
    builder_open = "(var|func)[^=]*some[ \t]+(View|ChartContent|AxisContent|ToolbarContent|Scene|Commands)[^=]*\\{[ \t]*$"
}

FNR == 1 {
    in_block = 0; in_multi = 0; depth = 0; builder_depth = -1; nwrap = 0; prev = ""
    mounted = (FILENAME ~ always_mounted)
    is_cli = (FILENAME ~ /^PacerCore\/Sources\/PacerPace\//)
    is_login_wrapper = (FILENAME ~ /LoginItemController\.swift$/)
}

{
    raw = $0
    # Multi-line string literals: skip what is inside them.
    if (in_multi) {
        if (count(raw, "\"") >= 3 && raw ~ /"""/) in_multi = 0
        prev = raw; next
    }
    # Block comments.
    if (in_block) {
        if (raw ~ /\*\//) in_block = 0
        prev = raw; next
    }
    if (raw ~ /^[ \t]*\/\*/ && raw !~ /\*\//) { in_block = 1; prev = raw; next }
    # Whole-line comments carry markers, never code.
    if (raw ~ /^[ \t]*\/\//) {
        if (raw ~ /lint:allow [a-z-]+[ \t]*$/) report("allow-without-reason", "a lint:allow marker needs a reason after the rule")
        prev = raw; next
    }

    c = code_of(raw)
    # A line that opens a multi-line string literal: check what precedes it, then skip the body.
    n3 = gsub(/"""/, "\"\"\"", raw)
    if (n3 % 2 == 1) in_multi = 1

    if (raw ~ /lint:allow [a-z-]+[ \t]*$/) report("allow-without-reason", "a lint:allow marker needs a reason after the rule")

    opens = count(c, "{"); closes = count(c, "}")

    # un-sync. Wrapped when the call sits inside the braces of an off-main
    # opener (OffMainQueue.….run, Task.detached, a global/own queue .async,
    # a get…Notifications completion), or follows one on its own line.
    if (c ~ un_sync && c !~ /await/) {
        match(c, un_sync)
        before = substr(c, 1, RSTART - 1)
        wrapped = (before ~ off_main && before !~ /main\.async/) || nwrap > 0
        if (!wrapped && !allowed("un-sync", raw, prev))
            report("un-sync", "synchronous UNUserNotificationCenter call; it waits on the notification daemon over XPC. Run it off the main thread (OffMainQueue.notifications.run) or use the async API")
    }
    # An opener whose brace stays open: everything until it closes is off main.
    if (c ~ off_main && c !~ /main\.async/ && opens > closes) wrap_depth[++nwrap] = depth

    # query-always-mounted
    if (mounted && (c ~ /^[ \t]*@Query([ \t(]|$)/ || c ~ /=[ \t]*Query[ \t]*\(/) && !allowed("query-always-mounted", raw, prev))
        report("query-always-mounted", "@Query in an always-mounted view re-fetches on every save, on the main thread. Read on a signal (RateLimitWriteSignal, .pacerScanCycleDidComplete) off the main thread instead")

    # View-builder scope, by brace depth.
    if (builder_depth < 0 && c ~ builder_open) builder_depth = depth
    in_builder = (builder_depth >= 0)
    if (in_builder) {
        if (code_keep_strings(raw) ~ formatter && !allowed("formatter-in-body", raw, prev))
            report("formatter-in-body", "formatter, regex or date parse built inside a view builder runs on every body pass (and per mark in a chart). Hoist it to a static, or compute it once per data change")
        if (c ~ /\.(fetch|fetchCount)[ \t]*\(/ && !allowed("fetch-in-body", raw, prev))
            report("fetch-in-body", "SwiftData fetch inside a view builder runs on every body pass, on the main context. Load it off the main thread on a data-change signal")
    }
    depth += opens - closes
    if (builder_depth >= 0 && depth <= builder_depth) builder_depth = -1
    while (nwrap > 0 && depth <= wrap_depth[nwrap]) nwrap--

    # stderr-write (the CLI library writes its own output by design)
    if (!is_cli && c ~ /FileHandle\.standard(Error|Output)\.write|fputs[ \t]*\(.*std(err|out)|fwrite[ \t]*\(.*std(err|out)/ && !allowed("stderr-write", raw, prev))
        report("stderr-write", "synchronous stdio write: hung on main (PACER-15) and overflowed a GCD worker stack (0.9.0 crash). Use Log.write")

    # smappservice-status
    if ((c ~ /SMAppService[A-Za-z.()]*\.status([^A-Za-z]|$)/ || (!is_login_wrapper && c ~ /LoginItemController\.currentStatus[ \t]*\(/)) && !allowed("smappservice-status", raw, prev))
        report("smappservice-status", "SMAppService status is a synchronous XPC call to smd (PACER-N). Use LoginItemController.statusOffMain()")

    # main-sync
    if (c ~ /DispatchQueue\.main\.sync[ \t]*[({]/ && !allowed("main-sync", raw, prev))
        report("main-sync", "DispatchQueue.main.sync deadlocks on main and blocks on a busy main thread. Hop with await MainActor.run or main.async")

    # terminate-call
    if (c ~ /(NSApp|NSApplication\.shared)\.terminate[ \t]*\(/ && !allowed("terminate-call", raw, prev))
        report("terminate-call", "NSApp.terminate inside a main-queue block or main-actor Task never gets its .terminateLater reply. Call it from an AppKit action or CFRunLoopPerformBlock, and say which")

    prev = raw
}

END {
    stale = 0
    for (i = 1; i <= nbase; i++) {
        k = base_order[i]
        if (!(k in base_hit)) {
            split(k, parts, "\t")
            printf "warning: stale baseline entry (no longer matches; delete it from %s): [%s] %s: %s\n", baseline, parts[1], parts[2], parts[3]
            stale++
        }
    }
    printf "lint-hang-patterns: %d finding(s), %d baselined, %d stale baseline entr%s\n", findings, suppressed, stale, (stale == 1 ? "y" : "ies") > "/dev/stderr"
    exit (findings > 0 ? 1 : 0)
}
' "${files[@]}"
