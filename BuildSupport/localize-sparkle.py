#!/usr/bin/env python3
"""Customize one string in the embedded copy; never modify the shared Sparkle SDK."""
import json
import plistlib
import sys
from pathlib import Path


def main():
    framework = Path(sys.argv[1])
    catalog = json.loads(Path(sys.argv[2]).read_text())
    if framework.is_symlink() or not str(framework.resolve()).endswith("/Contents/Frameworks/Sparkle.framework"):
        raise SystemExit("Expected an app's embedded Sparkle.framework")
    resources = framework / "Versions/B/Resources"
    info = plistlib.loads((resources / "Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != "2.9.6":
        raise SystemExit("Review automatic-update copy when changing the Sparkle pin")
    key = "Automatically download and install updates in the future"
    copy_key = "Install Updates Automatically (New characters are continually added.)"
    translations = catalog["strings"][copy_key]["localizations"]
    # Sparkle 2.9.6 uses Base for English and zh_CN for Simplified Chinese.
    for locale, folder in [("en", "Base"), ("ko", "ko"), ("ja", "ja"), ("zh-Hans", "zh_CN")]:
        path = resources / (folder + ".lproj") / "Sparkle.strings"
        strings = plistlib.loads(path.read_bytes())
        if key not in strings:
            raise SystemExit("Automatic-update checkbox string missing: " + folder)
        strings[key] = translations[locale]["stringUnit"]["value"]
        path.write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY, sort_keys=False))
    print("Customized Sparkle automatic-update copy in four embedded localizations")


if __name__ == "__main__":
    main()
