#import <AppKit/AppKit.h>

/* Synchronous native popup tracking. NO means the current platform/menu is
 * unsupported and the caller must retain the AppKit path. */
BOOL GTK4TrackNativeMenu(NSMenuView *view, NSEvent *event);
BOOL GTK4ShowNativeMenu(NSMenu *menu, NSRect screenRect, NSWindow *owner);
