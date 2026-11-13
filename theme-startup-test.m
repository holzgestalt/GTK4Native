#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import <GNUstepGUI/GSTheme.h>
#import "GTK4NativeWindow.h"
#include <gdk/x11/gdkx.h>

/* Request the provider before NSApplication establishes the display server.
   GTK4Native's activate previously asked NSScreen for a nonexistent server and
   raised the same NSWindowServerCommunicationException as a real early launch. */
int main(void)
{
  @autoreleasepool {
    NSCAssert(GSCurrentServer() == nil, @"start without an AppKit display connection");
    GSTheme *early = [GSTheme theme];
    NSCAssert([[early name] isEqual:@"GTK4Native"], @"the compiled provider is selected early");
    [early activate];
    NSCAssert(GSCurrentServer() == nil && gdk_display_get_default() == NULL,
      @"early activation must defer GTK until AppKit selects and connects its backend");
    [NSApplication sharedApplication];
    NSCAssert([GSTheme theme] == early && GSCurrentServer() != nil && [[NSScreen screens] count] > 0,
      @"the same provider finishes initialization with a connected screen server");
    NSCAssert(GDK_IS_X11_DISPLAY(gdk_display_get_default()), @"GTK must follow AppKit's selected X11 backend");
    const char *expected = g_getenv("EXPECTED_UI_SCALE");
    CGFloat scale = expected ? g_ascii_strtod(expected,NULL) : 1;
    NSCAssert(fabs([[NSScreen mainScreen] userSpaceScaleFactor]-scale) < .001,
      @"native scale defaults and explicit overrides must be installed before the first context");
    NSCAssert([NSGraphicsContext currentContext] != nil, @"initial graphics context exists");
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,320,160)
      styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(15,40,250,30)] autorelease];
    [field setStringValue:@"Early theme launch"];
    [[window contentView] addSubview:field];
    [window orderFront:nil]; [window display];
    NSCAssert(GTK4NativeHostForWindow(window) != NULL, @"native window hosting remains available after deferred initialization");
    [window close]; [window release];
    NSLog(@"Early theme startup passed: deferred backend initialization, screens, scale and native window");
  }
  return 0;
}
