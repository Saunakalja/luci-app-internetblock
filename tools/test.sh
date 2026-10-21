#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo"
if [ -n "${UCODE_MODULES:-}" ]; then
	"${UCODE:-ucode}" -L "$UCODE_MODULES" tests/core.uc
else
	"${UCODE:-ucode}" tests/core.uc
fi
node --check htdocs/luci-static/resources/view/internetblock/devices.js
node tests/frontend.cjs
python3 tests/worker.py
for script in root/usr/libexec/internetblock root/usr/libexec/internetblock-worker \
	root/usr/libexec/rpcd/luci.internetblock root/etc/init.d/internetblock tools/build.sh; do
	sh -n "$script"
done
python3 -c 'import json,pathlib; [json.loads(p.read_text()) for p in pathlib.Path("root").rglob("*.json")]; print("PASS: JSON and shell syntax")'
