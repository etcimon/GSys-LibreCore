# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

include $(TOPDIR)/rules.mk

PKG_NAME:=g6lc-egl-probe
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/g6lc-egl-probe
  SECTION:=utils
  CATEGORY:=Utilities
  DEPENDS:=+libmesa +libmesadri-virtio-gpu
  TITLE:=Minimal EGL/GLES2 probe for the unchanged Mesa virgl path
endef

define Package/g6lc-egl-probe/description
  Opens the virtio DRM device through GBM, creates an EGL/GLES2 context,
  draws a triangle, and reports the Mesa renderer. An opt-in companion
  utility exercises unchanged-driver ioctl error paths for capture/audit.
  This exercises the unchanged guest driver without adding a display server.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -DEGL_NO_X11 $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/g6lc-egl-probe \
		$(PKG_BUILD_DIR)/g6lc_egl_probe.c \
		-lEGL -lGLESv2 -lgbm
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/g6lc-virgl-negprobe \
		$(PKG_BUILD_DIR)/g6lc_virgl_negprobe.c
endef

define Package/g6lc-egl-probe/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/g6lc-egl-probe $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/g6lc-virgl-negprobe $(1)/usr/bin/
endef

$(eval $(call BuildPackage,g6lc-egl-probe))
