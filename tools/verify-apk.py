#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
"""Inspect an SDK-produced APK without installing or running its scripts."""
import argparse
from pathlib import Path
import re
import stat
import subprocess
import tempfile


def scripts_from_dump(text):
    scripts = {}
    current = None
    for line in text.splitlines():
        match = re.match(r"^  ([a-z]+-[a-z]+): \|$", line)
        if match:
            current = match[1]
            scripts[current] = ""
        elif current and line.startswith("    "):
            scripts[current] += line[4:] + "\n"
        elif current:
            current = None
    return scripts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("apk_tool", type=Path)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    dump = subprocess.check_output([str(args.apk_tool), "adbdump", str(args.package)], text=True)
    assert dump.startswith("#%SCHEMA: 676B6370"), "Not a real APK v3 package"
    assert re.search(r"^  name: luci-app-internetblock$", dump, re.M)
    assert re.search(r"^  arch: noarch$", dump, re.M), "Package must be architecture independent"
    assert re.search(r"^  license: GPL-3.0-only$", dump, re.M), "Missing project license metadata"
    assert re.search(r"^    - firewall4$", dump, re.M), "Missing fw4 dependency"
    scripts = scripts_from_dump(dump)
    for phase in ("pre-install", "post-install", "pre-deinstall", "post-deinstall", "pre-upgrade", "post-upgrade"):
        assert phase in scripts, f"Missing {phase} hook"
        subprocess.run(["sh", "-n"], input=scripts[phase], text=True, check=True)
    assert "internetblock cleanup" in scripts["pre-deinstall"]
    assert "nft delete chain inet fw4 internetblock_forward" in scripts["post-deinstall"]
    assert "flush ruleset" not in scripts["post-deinstall"]
    assert "internetblock_blocked internetblock_lan internetblock_wan" in scripts["post-deinstall"]
    with tempfile.TemporaryDirectory(prefix="ib-apk-inspect-") as temporary:
        root = Path(temporary)
        subprocess.run([str(args.apk_tool), "extract", "--allow-untrusted", "--no-chown", "--destination", temporary, str(args.package)], check=True)
        expected = {str(p.relative_to(repo / "root")): p for p in (repo / "root").rglob("*") if p.is_file()}
        view = "www/luci-static/resources/view/internetblock/devices.js"
        expected[view] = repo / "htdocs/luci-static/resources/view/internetblock/devices.js"
        css = "www/luci-static/resources/view/internetblock/devices.css"
        expected[css] = repo / "htdocs/luci-static/resources/view/internetblock/devices.css"
        expected["usr/share/licenses/luci-app-internetblock/LICENSE"] = repo / "LICENSE"
        executables = {"etc/init.d/internetblock", "usr/libexec/internetblock", "usr/libexec/internetblock-worker", "usr/libexec/rpcd/luci.internetblock"}
        for relative, source in expected.items():
            packaged = root / relative
            assert packaged.read_bytes() == source.read_bytes(), f"Stale or missing payload: {relative}"
            mode = stat.S_IMODE(packaged.stat().st_mode)
            assert mode == (0o755 if relative in executables else 0o644), f"Unsafe/wrong mode: {relative} {mode:o}"
        for packaged in root.rglob("*"):
            relative = str(packaged.relative_to(root))
            assert not stat.S_IMODE(packaged.stat().st_mode) & 0o022, f"Writable by non-owner: {relative}"
            if packaged.is_file():
                assert relative in expected or relative.startswith("lib/apk/packages/"), f"Unexpected package file: {relative}"
    print(f"PASS: APK v3/noarch, {len(expected)} current payload files, safe modes and six lifecycle hooks")


if __name__ == "__main__":
    main()
