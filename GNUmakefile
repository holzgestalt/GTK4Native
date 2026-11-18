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
