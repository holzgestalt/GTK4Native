include $(GNUSTEP_MAKEFILES)/common.make
BUNDLE_NAME = GTK4Native
BUNDLE_EXTENSION = .theme
GTK4Native_PRINCIPAL_CLASS = GTK4NativeTheme
GTK4Native_OBJC_FILES = GTK4NativeTheme.m
GTK4Native_C_FILES = GTK4Renderer.c
GTK4Native_INSTALL_DIR = $(GNUSTEP_LIBRARY)/Themes
ADDITIONAL_OBJCFLAGS = $(shell pkg-config --cflags gtk4)
ADDITIONAL_CFLAGS = $(shell pkg-config --cflags gtk4)
ADDITIONAL_GUI_LIBS = $(shell pkg-config --libs gtk4)
include $(GNUSTEP_MAKEFILES)/bundle.make
