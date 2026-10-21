# v0.1.0 validation

Date: 2026-10-21. Package: `luci-app-internetblock-0.1.0-r8.apk`.
SHA-256: `df96d9b6be610c4ec477196bde6106cbcdbcddfd1819af2174a0722baaaaaeaa`.

## Automated checks

| Suite | Result |
| --- | --- |
| Discovery, policy and storage | 60 assertions passed |
| LuCI DOM/RPC behavior | 47 assertions passed |
| Collector termination and child reaping | 3 assertions passed |
| Backend, real packets and packaged removal hook | 73 assertions passed |
| APK v3/noarch, GPL metadata, 14 payload files, modes and six hooks | Passed |
| Shell/JSON syntax and Git whitespace | Passed |

The network suite uses a router, two LAN clients and a WAN host in disposable
Linux network namespaces. It verifies existing-flow MAC blocking, address
changes, LAN peer/router access, UDP on the router DNS port, other clients and
router output, saved-policy reload, unblock, rollback, offload refusal,
WAN-down recovery and cleanup without removing foreign firewall rules.

Remove tests cover eligibility, reservation/online/blocked/router rejection,
MAC-only persistence, stale leases/neighbors, RAM loss, collection, active
rediscovery, write failure/rollback and incomplete discovery. UI tests verify
sorted action targets, separate address-group tables, read-only controls and
visible backend errors. Test identities use fictional documentation addresses.

## Build environment

- WSL2 Ubuntu 24.04, native ucode revision `85922056` matching the SDK.
- Official OpenWrt 25.12.5 mediatek/filogic SDK, GCC 14.3.0/musl.
- SDK archive SHA-256:
  `ff4a38a397caa2cfe1c39e18f84ddede14878221b3593c3f2c4cfe24e3ec4c25`.
- SDK apk-tools 3.0.5; pinned base/packages/LuCI feeds.
- Node.js 18 and Python 3; real nftables 1.0.9 in the namespace tests.

See [build/test commands](DEVELOPMENT.md). The whole package is not installed
into the WSL host; packaged hooks are redirected only for platform service paths.

## Physical router

Test target: GL.iNet GL-MT6000, upstream OpenWrt 25.12.5, kernel 6.12.94,
apk 3.0.5, fw4 and nftables-json 1.1.6. Other router/firmware combinations are
not established by these checks.

Earlier v0.1.0 package revisions verified actual apk installation, removal and
reinstallation, procd/rpcd operation, LuCI Block/Allow, persistence through fw4
reload and preservation of unrelated settings/rules. A selected client's direct
internet session stopped while its LAN API remained accessible, then returned
after Allow. The client's unrelated settings were untouched.

After the user's physical reboot, the boot identifier changed, all saved MAC
blocks matched the pre-reboot snapshot, kernel verification passed without
warnings, and remembered devices remained visible. The collector was running
and enabled for boot. No networking settings were changed for this test.

Material light and Bootstrap dark themes were inspected in real LuCI. Seven
columns fit on single device rows without page overflow, status labels retained
their green/red text, and action eligibility was visible. Separate address-group
tables and their shared columns/gap were checked with the light theme.

Anonymous and status-only HTTP RPC sessions could not call write methods;
status-only sessions could read status. Invalid/static Remove requests were
rejected on the router. Successful Remove/rediscovery tests used fictional
devices in namespaces rather than deleting real remembered devices.

R8 adds GPLv3 licensing, notices and the installed license file; enforcement
behavior is unchanged from r7. The final APK is checked byte-for-byte against
the release sources. Release preparation also scans text, APK contents and
public commit metadata for private identities/credentials. The README image
uses fictional device names, IPv4 addresses and MAC addresses.

## Limits

- No power-cut or flash-wear test was performed. Discovery uses batched writes.
- The UDP DNS-port test verifies the local network path, not DHCP allocation or
  dnsmasq's resolver behavior.
- IPv6, flow-offload-enabled enforcement, guest/VPN control, direct zone-device
  overrides and other complex topologies are unsupported by v1.
- A changed MAC, proxy or another LAN gateway can bypass this control.
