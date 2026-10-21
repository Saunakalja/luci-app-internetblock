# v0.1.0

First public release of luci-app-internetblock.

- Native LuCI device list with persistent offline devices and per-MAC
  IPv4 LAN-to-WAN Block/Allow controls.
- Remove obsolete offline entries without changing firewall policy.
- Saved blocks survive reboot and fw4 reload; LAN/router services stay available.
- Numeric address sorting, separate address-group tables and colored status.
- GPL-3.0-only, architecture-independent APK; tested on upstream OpenWrt
  25.12.5 with a GL.iNet GL-MT6000.

Install the APK on the router with:

```sh
apk add --allow-untrusted /tmp/luci-app-internetblock-0.1.0-r8.apk
```

Check `SHA256SUMS` first. The APK is unsigned; install only a build you trust.
Refresh LuCI and sign in again if necessary, then open Network → Internet Access.

Requires firewall zones named lan/wan with flow offloading disabled. V1 does
not block IPv6 or control guest/VPN zones. Read the README before installation.
