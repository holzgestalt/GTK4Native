#ifndef GTK4_NATIVE_IMAGES_H
#define GTK4_NATIVE_IMAGES_H
#import <AppKit/NSImage.h>

/* Live GTK images use semantic names, preserving themed colors and states. */
const char *GTK4NativeSymbolicIconForImage(NSImage *image);
/* Supply missing AppKit resource objects before an application decodes XIBs. */
void GTK4NativeInstallTemplateImages(void);
#endif
