import importlib.util
import os
import unittest

_spec = importlib.util.spec_from_file_location(
    "filer", os.path.join(os.path.dirname(os.path.abspath(__file__)), "sentry-issues-to-github.py"))
filer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(filer)

USER_ID = "u-7f3a91c2d4e5"
IP = "203.0.113.42"
UUID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
HEX = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
SECRETS = [USER_ID, IP, UUID, HEX, "/Users/someone", "someone", "jane@example.com",
           "MacBook-of-Jane", "/private/var", "breadcrumb-text", "secret-header"]

ISSUE = {
    "id": "123456", "shortId": "PACER-7A", "level": "fatal", "type": "error",
    "title": "EXC_BAD_ACCESS: crash in /Users/someone/Code/Pacer/Foo.swift",
    "count": "42", "userCount": 3,
    "firstSeen": "2026-10-30T12:34:56Z", "lastSeen": "2026-11-02T01:02:03Z",
    "permalink": "https://ericandrechek.sentry.io/issues/123456/",
    "firstRelease": {"version": "pacer@0.8.1+81"},
}

def frame(fn, module="PacerCore.Scanner", in_app=True, path="/Users/someone/Code/Foo.swift"):
    return {"function": fn, "module": module, "package": "/Applications/Pacer.app/Contents/MacOS/Pacer",
            "inApp": in_app, "filename": path}

EVENT = {
    "release": "pacer@0.8.1+81",
    "user": {"id": USER_ID, "ip_address": IP, "geo": {"city": "Springfield"}, "username": "someone"},
    "contexts": {"os": {"name": "macOS", "version": "26.1"},
                 "device": {"name": "MacBook-of-Jane", "model": "Mac15,3"}},
    "tags": [{"key": "release", "value": "pacer@0.8.1+81"},
             {"key": "device.name", "value": "MacBook-of-Jane"},
             {"key": "user", "value": f"id:{USER_ID}"}],
    "request": {"headers": [["X", "secret-header"]]},
    "breadcrumbs": {"values": [{"message": "breadcrumb-text /Users/someone/x"}]},
    "entries": [{"type": "exception", "data": {"values": [{
        "type": "EXC_BAD_ACCESS",
        "value": f"Fault at /Users/someone/Library/x.sqlite for {UUID} by jane@example.com "
                 f"from {IP} token {HEX} at /private/var/folders/ab/T/y",
        "mechanism": {"type": "mach"},
        "stacktrace": {"frames": [frame("main"), frame("system", in_app=False),
                                  frame("ScanCoordinator.runScanCycle()"), frame("Persister.save()")]},
    }]}}],
}

class Tests(unittest.TestCase):
    def test_body_has_no_identifying_data(self):
        body = filer.render_body(ISSUE, EVENT)
        title = filer.make_title(ISSUE)
        for s in SECRETS:
            self.assertNotIn(s, body, s)
            self.assertNotIn(s, title, s)
        self.assertNotIn("/Users", body)
        self.assertNotIn("Springfield", body)

    def test_body_has_expected_fields(self):
        body = filer.render_body(ISSUE, EVENT)
        for want in ["Level: fatal", "First seen: 2026-10-30", "Last seen: 2026-11-02",
                     "Events: 42", "Macs affected: 3", "`pacer@0.8.1+81`", "macOS 26.1",
                     "EXC_BAD_ACCESS", "https://ericandrechek.sentry.io/issues/123456/",
                     "Filed automatically"]:
            self.assertIn(want, body)

    def test_frames_in_app_only_top_first_basename(self):
        body = filer.render_body(ISSUE, EVENT)
        self.assertLess(body.index("Persister.save()"), body.index("ScanCoordinator.runScanCycle()"))
        self.assertNotIn("system", body)
        self.assertNotIn("/Applications", body)
        self.assertIn("[PacerCore.Scanner]", body)

    def test_frame_cap(self):
        ev = {"entries": [{"type": "exception", "data": {"values": [{
            "type": "E", "value": "v",
            "stacktrace": {"frames": [frame(f"f{i}") for i in range(40)]}}]}}]}
        body = filer.render_body(ISSUE, ev)
        self.assertEqual(body.count("  [PacerCore.Scanner]"), 25)
        self.assertIn("15 more", body)

    def test_title_and_labels(self):
        self.assertTrue(filer.make_title(ISSUE).startswith("[Sentry PACER-7A] "))
        self.assertLessEqual(len(filer.make_title({**ISSUE, "title": "x" * 500})), 120)
        self.assertEqual(filer.labels_for(ISSUE, EVENT), ["sentry", "crash"])
        hang = {**ISSUE, "level": "error", "title": "App Hanging for at least 2000 ms"}
        self.assertEqual(filer.labels_for(hang, {}), ["sentry", "freeze"])
        mech = {"entries": [{"type": "exception", "data": {"values": [
            {"type": "X", "mechanism": {"type": "AppHang"}}]}}]}
        self.assertIn("freeze", filer.labels_for({**ISSUE, "level": "error", "title": "t"}, mech))
        mx = {**ISSUE, "level": "warning", "title": "MXCPUException: cpu"}
        self.assertEqual(filer.labels_for(mx, {}), ["sentry", "resource"])
        self.assertEqual(filer.labels_for({**ISSUE, "level": "error", "title": "boring"}, {}), ["sentry"])

    def test_scrub(self):
        self.assertEqual(filer.scrub("a@b.com"), "<email>")
        self.assertNotIn("@nobody", filer.scrub("ping @nobody"))
        self.assertNotIn("```", filer.scrub("a```b"))

    def test_missing_event_still_renders(self):
        body = filer.render_body(ISSUE, None)
        self.assertIn("Macs affected: 3", body)
        self.assertNotIn("/Users", body)

if __name__ == "__main__":
    unittest.main()
