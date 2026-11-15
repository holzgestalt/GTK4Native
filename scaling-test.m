#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <GNUstepGUI/GSNativeView.h>
#include <gtk/gtk.h>
#include <assert.h>
#include <math.h>
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  [NSApplication sharedApplication];
  assert([[[GSTheme theme] name] isEqual:@"GTK4Native"]);
  CGFloat expected=atof(getenv("EXPECTED_UI_SCALE") ?: "1");
  assert(fabs([[NSScreen mainScreen] userSpaceScaleFactor]-expected)<0.01);
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,320,160)
    styleMask:NSTitledWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  assert(fabs([window userSpaceScaleFactor]-expected)<0.01);
  NSButton *button=[[[NSButton alloc] initWithFrame:NSMakeRect(20,20,120,32)] autorelease];
  [button setTitle:@"Scaled button"]; [button setBezelStyle:NSRoundedBezelStyle];
  [[window contentView] addSubview:button];
  NSTextField *field=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,80,220,28)] autorelease];
  [field setStringValue:@"Sharp text at desktop scale"]; [[window contentView] addSubview:field];
  [window makeKeyAndOrderFront:nil]; [window display];
  NSRect pixels=[button convertRect:[button bounds] toView:nil];
  assert(fabs(NSWidth(pixels)-120*expected)<0.1);
  NSRect content=[window contentRectForFrameRect:[window frame]];
  assert(fabs(NSWidth(content)-320)<1);
  [window makeFirstResponder:field];
  NSTextView *editor=(NSTextView *)[window firstResponder];
  id<GSNativeViewPeer> native=GSNativeViewPeerForView(field);
  if(native) assert([window firstResponder]==field && [native focusNativeView:field]);
  else assert([editor isKindOfClass:[NSTextView class]] && ![editor drawsBackground]);
  // The capture must preserve device pixel dimensions.
  NSView *view=[window contentView];
  NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:[view bounds]];
  [view cacheDisplayInRect:[view bounds] toBitmapImageRep:rep];
  assert([rep pixelsWide] >= 320*expected-1);
  NSLog(@"Scaling check passed: scale=%g buttonPixels=%g capture=%ldx%ld",expected,NSWidth(pixels),(long)[rep pixelsWide],(long)[rep pixelsHigh]);
  NSUserDefaults *defs=[NSUserDefaults standardUserDefaults];
  NSString *name=@"GTK4ScalingRegression";
  NSString *key=[@"NSWindow Frame " stringByAppendingString:name];
  // Simulate a legacy 100% saved window, then save/restore again at 200%.
  [defs setObject:@"10 20 320 160 0 0 2560 2048" forKey:key];
  [defs removeObjectForKey:[key stringByAppendingString:@" Scale"]];
  [window setContentSize:NSMakeSize(180,100)];
  assert([window setFrameUsingName:name]);
  assert(fabs(NSWidth([window frame])-320*expected)<1);
  [window saveFrameUsingName:name];
  [window setContentSize:NSMakeSize(180,100)];
  assert([window setFrameUsingName:name]);
  assert(fabs(NSWidth([window frame])-320*expected)<1);
  [NSWindow removeFrameUsingName:name];
  assert([defs objectForKey:key]==nil && [defs objectForKey:[key stringByAppendingString:@" Scale"]]==nil);
  [window orderOut:nil]; [window release]; [pool drain]; return 0;
}
