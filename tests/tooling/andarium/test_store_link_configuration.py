#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the App Store notice is built into the TestFlight configuration alone.

The notice (a card on Home and on Welcome, and a row in Info, that point a TestFlight
tester to the App Store version; Andarium/README.md#app-store-notice) reads the
App Store identifier of the ignored Review.local.xcconfig (REVIEW_APP_ID). The bundle
check sees a built bundle; this binds the build settings that decide it. It resolves
each configuration's settings with xcodebuild, with the identifier stated on the
command line, and fails when:

- STORE_LINK_ID, the TESTFLIGHT_STORE_LINK compilation condition, the Info.plist
  definition or the String Catalog table is on in any configuration but TestFlight;
- TestFlight does not take its identifier from REVIEW_APP_ID, or builds the notice
  with no identifier;
- REVIEW_ID (Review on the App Store, and the rating prompt that shares its switch)
  is set anywhere but AppStore, or AppStore takes the notice's identifier; or
- the AndariumPreview target takes the local file's identifier instead of the
  command line's arrangement alone.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import json
import subprocess
import sys
from pathlib import Path

PROJECT = "Andarium/Andarium.xcodeproj"
CATALOG = "StoreLink.xcstrings"
CONDITION = "TESTFLIGHT_STORE_LINK"
# Made up: the check never reads the maker's own value.
LOCAL_ID = "id1234567890"
ARRANGED_ID = "id0000000000"
CONFIGURATIONS = ("AppStore", "Debug", "Release", "TestFlight")


def settings(root: Path, target: str, configuration: str, *overrides: str) -> dict[str, str]:
    """The resolved build settings of a target in a configuration."""
    done = subprocess.run(
        ["xcrun", "xcodebuild", "-project", str(root / PROJECT), "-target", target,
         "-configuration", configuration, "-showBuildSettings", "-json", *overrides],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120, check=False)
    if done.returncode != 0:
        raise SystemExit(f"{target} {configuration}: xcodebuild -showBuildSettings failed:\n{done.stderr}")
    return json.loads(done.stdout)[0]["buildSettings"]


def notice_problems(where: str, resolved: dict[str, str], identifier: str) -> list[str]:
    """What differs in a target's resolved settings from having the notice built in with `identifier`
    (or, for an empty one, from having none of it)."""
    found = []
    conditions = resolved.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
    excluded = resolved.get("EXCLUDED_SOURCE_FILE_NAMES", "").split()
    plist = resolved.get("INFOPLIST_PREPROCESSOR_DEFINITIONS", "").split()
    if resolved.get("STORE_LINK_ID", "") != identifier:
        found.append(f"{where}: STORE_LINK_ID is {resolved.get('STORE_LINK_ID')!r}, not {identifier!r}")
    if identifier:
        if CONDITION not in conditions or "NO_TESTFLIGHT_STORE_LINK" in conditions:
            found.append(f"{where}: does not compile the notice in: {conditions}")
        if CATALOG in excluded:
            found.append(f"{where}: leaves the notice's String Catalog table out of the build")
        if f"{CONDITION}=1" not in plist:
            found.append(f"{where}: Info.plist does not take the identifier under its own key")
    else:
        if CONDITION in conditions or "NO_TESTFLIGHT_STORE_LINK" not in conditions:
            found.append(f"{where}: compiles the notice in with no identifier: {conditions}")
        if CATALOG not in excluded:
            found.append(f"{where}: has the notice's String Catalog table in the build")
        if f"{CONDITION}=1" in plist or f"{CONDITION}_NONE=1" not in plist:
            found.append(f"{where}: Info.plist has the identifier's key")
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    options = parser.parse_args()
    root = options.root
    failures: list[str] = []

    # The local file's identifier, stated on the command line as the maker's file would have it. Only
    # TestFlight takes it; Review on the App Store (REVIEW_ID) is AppStore's alone.
    for configuration in CONFIGURATIONS:
        where = f"{configuration} (a local identifier)"
        resolved = settings(root, "Andarium", configuration, f"REVIEW_APP_ID={LOCAL_ID}")
        failures += notice_problems(where, resolved, LOCAL_ID if configuration == "TestFlight" else "")
        want_review = LOCAL_ID if configuration == "AppStore" else ""
        if resolved.get("REVIEW_ID", "") != want_review:
            failures.append(f"{where}: REVIEW_ID is {resolved.get('REVIEW_ID')!r}, not {want_review!r}")
        if configuration == "TestFlight":
            conditions = resolved.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
            if "APP_REVIEW" in conditions:
                failures.append(f"{where}: TestFlight has Review on the App Store")

    # No local identifier: no notice anywhere, TestFlight included (a fork, a sideload).
    for configuration in CONFIGURATIONS:
        where = f"{configuration} (no local identifier)"
        resolved = settings(root, "Andarium", configuration, "REVIEW_APP_ID=")
        failures += notice_problems(where, resolved, "")

    # The arrangement of the tests and the captures: a Debug build takes the notice from the command
    # line alone, and the local file's identifier does not reach it.
    for configuration in ("Debug", "Release"):
        resolved = settings(root, "Andarium", configuration, f"STORE_LINK_ID={ARRANGED_ID}",
                            f"REVIEW_APP_ID={LOCAL_ID}")
        failures += notice_problems(f"{configuration} (arranged)", resolved, ARRANGED_ID)

    # AndariumPreview names the setting empty itself: the arrangement alone builds the notice in.
    for configuration in ("Debug", "TestFlight"):
        where = f"AndariumPreview {configuration}"
        resolved = settings(root, "AndariumPreview", configuration, f"REVIEW_APP_ID={LOCAL_ID}")
        failures += notice_problems(f"{where} (a local identifier)", resolved, "")
        resolved = settings(root, "AndariumPreview", configuration, f"STORE_LINK_ID={ARRANGED_ID}")
        failures += notice_problems(f"{where} (arranged)", resolved, ARRANGED_ID)

    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
