#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The archive switch of the AOT component gates every way a build names it.

cmake/UmlAotArchives.cmake reads LINEAGE24_ACCEPTED_AOT_ARCHIVES from the
accepted AOT descriptor. The rows run its two functions with `cmake -P` on
synthetic descriptors, then check that darwin/cpu/CMakeLists.txt calls them: an
explicit UML_AOT_ARTIFACT in an App Store runtime is a configure error unless
the descriptor says yes, as the accepted artifact is, and the iOS development
runtimes that name an artifact are left alone.
"""

from __future__ import annotations

__import__("sys").dont_write_bytecode = True

import argparse
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ARGUMENTS: argparse.Namespace


def cmake(script: str, **definitions: str) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "probe.cmake"
        path.write_text(
            f'include("{ARGUMENTS.module}")\n{script}\n', encoding="utf-8")
        options = [f"-D{name}={value}" for name, value in definitions.items()]
        return subprocess.run(
            [ARGUMENTS.cmake, *options, "-P", str(path)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=60, check=False)


class ArchiveSwitchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def descriptor(self, text: str | None) -> Path:
        path = self.directory / "accepted-aot.env"
        path.unlink(missing_ok=True)
        if text is not None:
            path.write_text(text, encoding="utf-8")
        return path

    def state(self, descriptor: Path) -> subprocess.CompletedProcess:
        return cmake('uml_aot_archives_state(state "${DESCRIPTOR}")\n'
                     'message("state=${state}")', DESCRIPTOR=str(descriptor))

    def require(self, descriptor: Path) -> subprocess.CompletedProcess:
        return cmake('uml_aot_require_archives("${DESCRIPTOR}" "/artifact")',
                     DESCRIPTOR=str(descriptor))

    def test_the_state_is_what_the_descriptor_says(self) -> None:
        for text, expected in (
            ("LINEAGE24_ACCEPTED_AOT_ARCHIVES='yes'\n", "yes"),
            ("A='1'\nLINEAGE24_ACCEPTED_AOT_ARCHIVES='no'\nB='2'\n", "no"),
            (None, "none"),
        ):
            with self.subTest(expected=expected):
                result = self.state(self.descriptor(text))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"state={expected}", result.stderr)

    def test_a_descriptor_that_states_no_switch_is_refused(self) -> None:
        for text in ("A='1'\n", "LINEAGE24_ACCEPTED_AOT_ARCHIVES='maybe'\n",
                     "LINEAGE24_ACCEPTED_AOT_ARCHIVES=yes\n"):
            with self.subTest(text=text):
                result = self.state(self.descriptor(text))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("LINEAGE24_ACCEPTED_AOT_ARCHIVES of yes or no", result.stderr)

    def test_a_named_artifact_is_taken_only_when_the_switch_is_yes(self) -> None:
        accepted = self.require(self.descriptor("LINEAGE24_ACCEPTED_AOT_ARCHIVES='yes'\n"))
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        refused = self.require(self.descriptor("LINEAGE24_ACCEPTED_AOT_ARCHIVES='no'\n"))
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("sets LINEAGE24_ACCEPTED_AOT_ARCHIVES to no", refused.stderr)
        self.assertIn("/artifact", refused.stderr)
        none = self.require(self.descriptor(None))
        self.assertNotEqual(none.returncode, 0)
        self.assertIn("accepts no AOT artifact", none.stderr)


class WiringTests(unittest.TestCase):
    """darwin/cpu/CMakeLists.txt takes the component under the switch."""

    def setUp(self) -> None:
        self.text = Path(ARGUMENTS.cpu_lists).read_text(encoding="utf-8")

    def test_an_explicit_artifact_in_an_app_store_runtime_calls_the_gate_first(self) -> None:
        explicit = re.search(
            r"if\(UML_APP_STORE_RUNTIME\)\s+include\(UmlAotArchives\)\s+"
            r"uml_aot_require_archives\([^)]*UML_AOT_ARTIFACT[^)]*\)\s+endif\(\)\s+"
            r"set\(UML_AOT_SOURCE artifact\)",
            self.text)
        self.assertIsNotNone(
            explicit, "the explicit artifact branch must gate an App Store runtime before it names the source")

    def test_the_accepted_artifact_reads_the_same_switch(self) -> None:
        self.assertIn("uml_aot_archives_state(_uml_aot_archives", self.text)
        self.assertNotIn("LINEAGE24_ACCEPTED_AOT_ARCHIVES", self.text.replace("(LINEAGE24_ACCEPTED_AOT_ARCHIVES)", ""))

    def test_an_image_blob_is_not_an_archive_input(self) -> None:
        # UML_AOT_IMAGE qualifies a release on macOS and cannot be an iOS product.
        image = re.search(r"if\(UML_AOT_IMAGE\)(.*?)else\(\)", self.text, re.S)
        self.assertIsNotNone(image)
        self.assertIn("NOT UML_TARGET_MACOS", image.group(1))


def main() -> int:
    global ARGUMENTS
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmake", required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--cpu-lists", required=True)
    ARGUMENTS, rest = parser.parse_known_args()
    result = unittest.main(argv=[sys.argv[0], *rest], exit=False).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
