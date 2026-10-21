#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk=$(realpath "${1:?Usage: tools/build.sh SDK_DIRECTORY [OUTPUT_DIRECTORY]}")
output=${2:-"$repo/dist"}
test -f "$sdk/rules.mk" && test -x "$sdk/scripts/feeds" || { echo 'Not an OpenWrt SDK' >&2; exit 1; }
target="$sdk/package/luci-app-internetblock"
mkdir -p "$target/root" "$target/htdocs" "$output"
cp "$repo/Makefile" "$target/Makefile"
cp "$repo/LICENSE" "$target/LICENSE"
rsync -a --delete "$repo/root/" "$target/root/"
rsync -a --delete "$repo/htdocs/" "$target/htdocs/"
cd "$sdk"
./scripts/feeds install luci-base rpcd ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus nftables-json iw ip-tiny
test -f .config || : > .config
if ! grep -qx 'CONFIG_PACKAGE_luci-app-internetblock=m' .config || \
	! grep -qx 'CONFIG_USE_APK=y' .config || grep -qE '^CONFIG_ALL(_KMODS|_NONSHARED)?=y$' .config; then
	sed -i -e '/^CONFIG_ALL=/d' -e '/^CONFIG_ALL_KMODS=/d' -e '/^CONFIG_ALL_NONSHARED=/d' \
		-e '/^# CONFIG_ALL\( is\|_KMODS is\|_NONSHARED is\)/d' \
		-e '/^CONFIG_USE_APK=/d' -e '/^CONFIG_PACKAGE_luci-app-internetblock=/d' .config
	printf '\n# CONFIG_ALL is not set\n# CONFIG_ALL_KMODS is not set\n# CONFIG_ALL_NONSHARED is not set\nCONFIG_USE_APK=y\nCONFIG_PACKAGE_luci-app-internetblock=m\n' >> .config
	make defconfig
fi
# This package has no compiled target code. Keep dependency metadata, but do
# not rebuild firmware/kernel packages merely to package scripts and resources.
make package/luci-app-internetblock/clean V=s NO_DEPS=1
make package/luci-app-internetblock/compile V=s NO_DEPS=1 -j2
find bin/packages -name 'luci-app-internetblock-*.apk' -exec cp '{}' "$output/" \;
cd "$output"
test -n "$(find . -maxdepth 1 -name 'luci-app-internetblock-*.apk' -print -quit)"
sha256sum luci-app-internetblock-*.apk > SHA256SUMS
cat SHA256SUMS
