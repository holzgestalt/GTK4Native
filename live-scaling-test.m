#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <assert.h>
#include <math.h>
@interface NSView (ConstraintInspection)
- (NSArray *)constraints;
@end
static void waitForScale(double scale)
{
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
  while ([deadline timeIntervalSinceNow]>0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (fabs([[NSScreen mainScreen] userSpaceScaleFactor]-scale)<0.01) return;
  }
  NSLog(@"Expected scale %g got %g",scale,[[NSScreen mainScreen] userSpaceScaleFactor]);
  assert(0);
}
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new]; [NSApplication sharedApplication];
  NSView *content=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,320,160)] autorelease];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,320,160)
    styleMask:NSTitledWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setContentView:content];
  NSView *child=[[[NSView alloc] initWithFrame:NSZeroRect] autorelease];
  [child setTranslatesAutoresizingMaskIntoConstraints:NO]; [content addSubview:child];
  NSArray *constraints=@[
    [[child leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:12],
    [[child trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-12],
    [[child bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:-8],
    [[child heightAnchor] constraintEqualToConstant:24]];
  [NSLayoutConstraint activateConstraints:constraints]; [content layoutSubtreeIfNeeded];
  NSLog(@"Active constraints=%lu child=%@",(unsigned long)[[content constraints] count],NSStringFromRect([child frame]));
  assert([[content constraints] count]==3 && [[child constraints] count]==1);
  assert(fabs(NSWidth([child frame])-296)<0.1);
  [window makeKeyAndOrderFront:nil];
  for (NSNumber *factor in @[@2,@1,@2,@1]) {
    gdk_x11_display_set_surface_scale(gdk_display_get_default(),[factor intValue]);
    waitForScale([factor doubleValue]);
    NSSize dpi=[[[[NSScreen mainScreen] deviceDescription] objectForKey:NSDeviceResolution] sizeValue];
    assert(fabs(dpi.width-72*[factor doubleValue])<0.1);
    [content layoutSubtreeIfNeeded]; [window display];
    assert(fabs(NSWidth([content bounds])-320)<1);
    assert(fabs(NSWidth([child frame])-296)<1);
    assert(fabs(NSWidth([window frame])-320*[factor doubleValue])<1);
    NSLog(@"Live scale %@ frame=%@ child=%@",factor,NSStringFromRect([window frame]),NSStringFromRect([child frame]));
  }
  [window setContentSize:NSMakeSize(420,180)]; [content layoutSubtreeIfNeeded];
  assert(fabs(NSWidth([child frame])-396)<1);
  NSLog(@"Live scaling and constraint resize checks passed");
  [window orderOut:nil]; [window release]; [pool drain]; return 0;
}
