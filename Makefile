# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Saunakalja
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-internetblock
PKG_VERSION:=0.1.0
PKG_RELEASE:=8
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-internetblock
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Simple LAN device internet access switches
  PKGARCH:=all
  DEPENDS:=+luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +firewall4 +nftables-json +iw +ip-tiny
endef

define Package/luci-app-internetblock/description
  A native LuCI table for persistent IPv4 LAN-to-WAN blocking by device MAC.
endef

define Build/Compile
endef

define Package/luci-app-internetblock/install
	$(INSTALL_DIR) $(1)
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/internetblock
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/internetblock/devices.js $(1)/www/luci-static/resources/view/internetblock/
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/internetblock/devices.css $(1)/www/luci-static/resources/view/internetblock/
	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-app-internetblock
	$(INSTALL_DATA) ./LICENSE $(1)/usr/share/licenses/luci-app-internetblock/LICENSE
	find $(1) -type d -exec chmod 0755 {} +
	find $(1) -type f -exec chmod 0644 {} +
	chmod 0755 $(1)/etc/init.d/internetblock $(1)/usr/libexec/internetblock $(1)/usr/libexec/internetblock-worker $(1)/usr/libexec/rpcd/luci.internetblock
endef

define Package/luci-app-internetblock/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
for zone in lan wan; do
	uci -q show firewall | grep -q "\.name='$$zone'$$" || {
		echo "internetblock v1 requires firewall zones named lan and wan" >&2
		exit 1
	}
done
exit 0
endef

define Package/luci-app-internetblock/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/libexec/internetblock init || exit 1
/etc/init.d/internetblock enable
/etc/init.d/internetblock restart || exit 1
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
exit 0
endef

define Package/luci-app-internetblock/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/internetblock stop || exit 1
/usr/libexec/internetblock cleanup || exit 1
/etc/init.d/internetblock disable
exit 0
endef

define Package/luci-app-internetblock/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if nft list chain inet fw4 internetblock_forward >/dev/null 2>&1; then
	nft delete chain inet fw4 internetblock_forward || exit 1
fi
for set in internetblock_blocked internetblock_lan internetblock_wan; do
	if nft list set inet fw4 "$$set" >/dev/null 2>&1; then
		nft delete set inet fw4 "$$set" || exit 1
	fi
done
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
if [ -d /tmp/internetblock ] && [ ! -L /tmp/internetblock ]; then
	rm -f /tmp/internetblock/seen.json /tmp/internetblock/seen.json.tmp /tmp/internetblock/last-flush /tmp/internetblock/last-flush.tmp /tmp/internetblock/nft.error
	rmdir /tmp/internetblock 2>/dev/null || true
fi
rm -f /var/lock/internetblock.lock
exit 0
endef

$(eval $(call BuildPackage,luci-app-internetblock))
