# Native GTK code stays in this provider; build support comes from libs-gui.
GNUSTEP_THEME_NAME = GTK4Native
GNUSTEP_THEME_OBJC_FILES = GTK4NativeTheme.m GTK4NativeMenu.m GTK4NativeFilePanel.m GTK4NativeWindow.m GTK4NativeView.m GTK4NativeTable.m GTK4NativeControls.m GTK4NativeClip.m GTK4NativeCustomView.m GTK4NativeStepper.m GTK4NativeImages.m
GNUSTEP_THEME_C_FILES = GTK4Renderer.c
GNUSTEP_THEME_ENTRY_SOURCE = GTK4NativeEntry.m
GNUSTEP_THEME_DEPENDENCIES = Classic
GNUSTEP_THEME_EXTRA_LIBS = $(shell pkg-config --libs gtk4-x11 xext)
GS_THEME_BUILD_PC_DIR = $(abspath obj/pkgconfig)
ADDITIONAL_OBJCFLAGS = $(shell pkg-config --cflags gtk4)
ADDITIONAL_CFLAGS = $(shell pkg-config --cflags gtk4)
include $(GNUSTEP_MAKEFILES)/ThemeSupport/provider.make

# Install native SDK support beside the provider, independent of any application.
GTK4_SDK_DIR := $(GNUSTEP_LIBRARIES)/$(GNUSTEP_TARGET_LDIR)/GNUstep/ThemeSDK/GTK4Native
GTK4_SDK_FINAL := $(abspath $(if $(DESTDIR),$(patsubst $(DESTDIR)/%,%,$(GTK4_SDK_DIR)),$(GTK4_SDK_DIR)))
after-install::
	$(MKDIRS) $(GTK4_SDK_DIR)/Compatibility/WebKit
	$(INSTALL_DATA) GTK4NativeView.h $(GTK4_SDK_DIR)/GTK4NativeView.h
	$(INSTALL_DATA) Compatibility/*.h Compatibility/*.m Compatibility/*.py $(GTK4_SDK_DIR)/Compatibility/
	$(INSTALL_DATA) Compatibility/WebKit/*.h $(GTK4_SDK_DIR)/Compatibility/WebKit/
	@printf '%s\n' 'xcode_sdk=$(GTK4_SDK_FINAL)/Compatibility/xcode-sdk.py' >> $(GS_THEME_INSTALL_LIB_DIR)/pkgconfig/$(GS_THEME_PC)
