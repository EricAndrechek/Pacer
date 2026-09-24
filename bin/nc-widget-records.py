#!/usr/bin/env python3
"""Place widgets in Notification Center by writing its preferences — CI only.

    nc-widget-records.py <in.plist> <out.plist> <container-bundle-id> \
                         <extension-bundle-id> <kind>:<family> ...

Reads Notification Center's preferences (`defaults export`), replaces
`widgets.instances` with one record per <kind>:<family> (small|medium|large),
in order, and writes the result for `defaults import`.

Why: WidgetKit Simulator renders only a widget's small family, and the README
shows most of Pacer's widgets at medium. Notification Center renders any
family, with the system's own chrome — it only has to be told the widgets are
there. Each record is what adding a widget by hand stores: a bplist of
{uuid, widget}, `widget` being an NSKeyedArchiver'd CHSWidget. A widget with
no configuration intent stores a null `intent2`, as Apple's own do.
"""
import plistlib
import sys
import uuid
from plistlib import UID

FAMILIES = {"small": 1, "medium": 2, "large": 3}


def chs_widget(container, extension, kind, family):
    objects = [
        "$null",
        {"$class": UID(6), "family": family, "kind": UID(5), "extensionIdentity": UID(2),
         "intent2": UID(0), "personaIdentifier": UID(0), "activityIdentifier": UID(0)},
        {"$class": UID(7), "containerBundleIdentifier": UID(4),
         "extensionBundleIdentifier": UID(3), "deviceIdentifier": UID(0)},
        extension,
        container,
        kind,
        {"$classname": "CHSWidget", "$classes": ["CHSWidget", "NSObject"]},
        {"$classname": "CHSExtensionIdentity", "$classes": ["CHSExtensionIdentity", "NSObject"]},
    ]
    archive = {"$version": 100000, "$archiver": "NSKeyedArchiver",
               "$top": {"root": UID(1)}, "$objects": objects}
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)


def main(argv):
    if len(argv) < 6:
        sys.exit(__doc__)
    src, dst, container, extension, *specs = argv[1:]
    try:
        with open(src, "rb") as f:
            prefs = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        prefs = {}
    instances = []
    for spec in specs:
        kind, _, family = spec.rpartition(":")
        record = {"uuid": str(uuid.uuid4()).upper(),
                  "widget": chs_widget(container, extension, kind, FAMILIES[family])}
        instances.append(plistlib.dumps(record, fmt=plistlib.FMT_BINARY))
    widgets = prefs.setdefault("widgets", {})
    widgets["instances"] = instances
    widgets.setdefault("vers", 1)
    with open(dst, "wb") as f:
        plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)


if __name__ == "__main__":
    main(sys.argv)
