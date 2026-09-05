include $(TOPDIR)/rules.mk

PKG_NAME:=awg-warp-auto-quic
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/awg-warp-auto-quic
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Local Mini QUIC I1 generator for AmneziaWG
  DEPENDS:=+libmbedtls
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/quic-i1.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -std=c99 -Wall -Wextra -Werror -o $(PKG_BUILD_DIR)/quic-i1 $(PKG_BUILD_DIR)/quic-i1.c $(TARGET_LDFLAGS) -lmbedcrypto
endef

define Package/awg-warp-auto-quic/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/quic-i1 $(1)/usr/bin/quic-i1
endef

$(eval $(call BuildPackage,awg-warp-auto-quic))
