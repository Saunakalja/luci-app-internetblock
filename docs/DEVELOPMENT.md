# Build, test and recovery

## Build

Use Linux or WSL2 and a dedicated official OpenWrt 25.12.5 SDK on its Linux
filesystem. Install the SDK prerequisites, then fetch its pinned feeds:

```sh
cd /path/to/openwrt-sdk
./scripts/feeds update base packages luci
cd /path/to/luci-app-internetblock
bash tools/build.sh /path/to/openwrt-sdk
```

The build script changes that SDK's package directory/configuration. Output is
written to `dist/`, including `SHA256SUMS`. Runtime dependencies are declared in
the Makefile; Node.js and Python are test tools, not router dependencies.

## Tests

Use native ucode matching the SDK (revision `85922056`) with its fs module,
Node.js 18+, Python 3, iproute2, nftables and ping:

```sh
UCODE=/path/to/ucode UCODE_MODULES=/path/to/modules bash tools/test.sh
sudo env UCODE=/path/to/ucode UCODE_MODULES=/path/to/modules \
  IB_APK_TOOL=/path/to/sdk/staging_dir/host/bin/apk \
  IB_APK=/path/to/luci-app-internetblock-0.1.0-r8.apk \
  python3 tests/network.py
python3 tools/verify-apk.py /path/to/sdk/staging_dir/host/bin/apk \
  dist/luci-app-internetblock-0.1.0-r8.apk
```

Network tests use disposable namespaces and fictional RFC 5737/benchmark
addresses. UCI/ubus/Wi-Fi inputs are fixtures; nftables and packet forwarding are
real. No test traffic enters the real router's LAN/WAN. All namespaces are
removed on exit. Supplying the APK variables also tests its actual remove hook.

## Firewall ownership

Within `inet fw4`, the app owns `internetblock_forward`, `internetblock_blocked`,
`internetblock_lan` and `internetblock_wan`. The IPv4 drop matches LAN input,
WAN output and source MAC, at forward priority -1 before established acceptance.
It does not hook router input/output. Atomic updates are verified and failures
attempt rollback; errors are visible in LuCI.

## Recovery without a working backend

Stop automatic reconciliation, move the saved fragment out of the include path,
then remove only the app's objects:

```sh
/etc/init.d/internetblock stop
/etc/init.d/internetblock disable
mv -i /etc/internetblock/fw4/policy.nft /etc/internetblock/policy.nft.disabled
nft delete chain inet fw4 internetblock_forward
nft delete set inet fw4 internetblock_blocked
nft delete set inet fw4 internetblock_lan
nft delete set inet fw4 internetblock_wan
```

A missing-object error means it was already absent. `mv -i` asks before replacing
an existing recovery copy. A full firewall reload may discard another package's
temporary rules; avoid it for targeted cleanup. Saved data is included in
OpenWrt's sysupgrade keep list.
