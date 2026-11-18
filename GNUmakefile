shared = no
include $(GNUSTEP_MAKEFILES)/common.make
LIBRARY_NAME = libgnustep-theme-GTK4Native
libgnustep-theme-GTK4Native_OBJC_FILES = GTK4NativeTheme.m GTK4NativeMenu.m GTK4NativeFilePanel.m GTK4NativeWindow.m GTK4NativeView.m GTK4NativeTable.m GTK4NativeControls.m GTK4NativeClip.m GTK4NativeCustomView.m GTK4NativeStepper.m GTK4NativeImages.m
libgnustep-theme-GTK4Native_C_FILES = GTK4Renderer.c
ADDITIONAL_INCLUDE_DIRS += -I../GNUstep -I../../src/libs-gui/Source -I../../src/libs-gui/Headers -I../../src/libs-gui/Headers/Additions
ADDITIONAL_OBJCFLAGS = $(shell pkg-config --cflags gtk4)
ADDITIONAL_CFLAGS = $(shell pkg-config --cflags gtk4)
include $(GNUSTEP_MAKEFILES)/library.make
