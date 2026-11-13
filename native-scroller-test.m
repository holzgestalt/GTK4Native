#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <gtk/gtk.h>

@interface ScrollDocument : NSView
{
  BOOL _flipped;
}
- (void)setFlipped:(BOOL)flipped;
@end
@implementation ScrollDocument
- (void)setFlipped:(BOOL)flipped { _flipped = flipped; }
- (BOOL)isFlipped { return _flipped; }
- (void)drawRect:(NSRect)rect
{
  [[NSColor textBackgroundColor] set]; NSRectFill(rect);
  [[NSColor gridColor] set];
  for (int x = 0; x < 1200; x += 40) NSRectFill(NSMakeRect(x, 0, 1, 1000));
  for (int y = 0; y < 1000; y += 40) NSRectFill(NSMakeRect(0, y, 1200, 1));
}
@end

static NSEvent *pointerEvent(NSEventType type, NSScroller *bar, NSPoint local)
{
  return [NSEvent mouseEventWithType:type location:[bar convertPoint:local toView:nil]
    modifierFlags:0 timestamp:[NSDate timeIntervalSinceReferenceDate]
    windowNumber:[[bar window] windowNumber] context:nil eventNumber:1 clickCount:1 pressure:1];
}
static void drag(NSScroller *bar, BOOL horizontal)
{
  NSRect thumb = [bar rectForPart:NSScrollerKnob];
  NSPoint from = NSMakePoint(NSMidX(thumb), NSMidY(thumb));
  NSPoint to = from;
  if (horizontal) to.x += 45; else to.y += 45;
  double before = [bar doubleValue];
  [NSApp postEvent:pointerEvent(NSLeftMouseDragged, bar, to) atStart:NO];
  [NSApp postEvent:pointerEvent(NSLeftMouseUp, bar, to) atStart:NO];
  [bar mouseDown:pointerEvent(NSLeftMouseDown, bar, from)];
  NSCAssert([bar doubleValue] > before + .05, @"dragging must update the normalized value");
  NSCAssert([bar hitPart] == NSScrollerNoPart, @"tracking must finish on release");
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  GSTheme *theme = [GSTheme theme];
  NSCAssert([[theme name] isEqual:@"GTK4Native"], @"the native provider must load");
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(30,30,440,320)
    styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20,20,400,280)];
  [scroll setBorderType:NSNoBorder];
  [scroll setHasVerticalScroller:YES];
  [scroll setHasHorizontalScroller:YES];
  ScrollDocument *document = [[ScrollDocument alloc] initWithFrame:NSMakeRect(0,0,1200,1000)];
  [scroll setDocumentView:document];
  [[window contentView] addSubview:scroll];
  [window orderFront:nil];
  [window display];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
  NSScroller *v = [scroll verticalScroller], *h = [scroll horizontalScroller];
  CGFloat width = [theme defaultScrollerWidth];
  NSCAssert(width > 0 && [NSScroller scrollerWidth] == width, @"GTK must supply the layout width");
  NSCAssert(NSWidth([v frame]) == width && NSHeight([h frame]) == width,
    @"NSScrollView must use native thickness on both axes");
  NSCAssert(NSMaxX([v frame]) == NSWidth([scroll bounds]), @"vertical scroller must be on the right");
  for (NSScroller *bar in @[v, h]) {
    NSRect native;
    NSCAssert([theme getScrollerRect:&native forPart:NSScrollerKnob inScroller:bar],
      @"native geometry must handle this scroller");
    NSCAssert(NSEqualRects(native, [bar rectForPart:NSScrollerKnob]), @"hit geometry must match GTK");
    NSCAssert(NSIsEmptyRect([bar rectForPart:NSScrollerIncrementLine])
      && NSIsEmptyRect([bar rectForPart:NSScrollerDecrementLine]), @"no legacy arrow hit zones");
    NSRect trough = [bar rectForPart:NSScrollerKnobSlot];
    NSCAssert(NSContainsRect([bar bounds], trough) && NSContainsRect(trough, native),
      @"GTK track and thumb must fit within the scroller");
    NSPoint center = NSMakePoint(NSMidX(native), NSMidY(native));
    NSCAssert([bar testPart:[bar convertPoint:center toView:nil]] == NSScrollerKnob,
      @"visible native thumb must be draggable");
  }
  for (int flipped = 0; flipped < 2; flipped++) {
    [document setFlipped:flipped];
    [[scroll contentView] scrollToPoint:NSMakePoint(200,200)];
    [scroll reflectScrolledClipView:[scroll contentView]];
    NSPoint before = [[scroll contentView] bounds].origin;
    id target = [v target]; SEL action = [v action];
    drag(v, NO);
    NSCAssert(fabs([[scroll contentView] bounds].origin.y - before.y) > 1,
      @"vertical drag must scroll flipped and unflipped documents");
    before = [[scroll contentView] bounds].origin;
    drag(h, YES);
    NSCAssert([[scroll contentView] bounds].origin.x > before.x,
      @"horizontal drag must scroll the document");
    NSCAssert([v target] == target && [v action] == action, @"native drawing must preserve target/action");
  }
  // GTK's primary-button preference selects absolute positioning vs paging.
  for (int warps = 0; warps < 2; warps++) {
    g_object_set(gtk_settings_get_default(), "gtk-primary-button-warps-slider", warps, NULL);
    NSCAssert([theme scrollerScrollsByPageForScroller:v] == !warps, @"use GTK's trough-click preference");
    [[scroll contentView] scrollToPoint:NSMakePoint(200,200)];
    [scroll reflectScrolledClipView:[scroll contentView]];
    NSRect trough = [v rectForPart:NSScrollerKnobSlot];
    NSPoint to = NSMakePoint(NSMidX(trough), NSMaxY(trough) - 3);
    double before = [v doubleValue];
    [NSApp postEvent:pointerEvent(NSLeftMouseUp, v, to) atStart:NO];
    [v mouseDown:pointerEvent(NSLeftMouseDown, v, to)];
    NSCAssert([v doubleValue] > before, @"trough clicks must scroll the document");
  }
  [scroll setFrameSize:NSMakeSize(360,240)];
  [scroll tile];
  NSCAssert(NSWidth([v frame]) == width && NSHeight([h frame]) == width, @"resize keeps GTK thickness");
  [window display];
  NSBitmapImageRep *bitmap = [[window contentView] bitmapImageRepForCachingDisplayInRect:[[window contentView] bounds]];
  [[window contentView] cacheDisplayInRect:[[window contentView] bounds] toBitmapImageRep:bitmap];
  NSCAssert([[bitmap representationUsingType:NSPNGFileType properties:@{}]
    writeToFile:@"/tmp/gnustep-gtk4-scrollers.png" atomically:YES], @"scroll view preview must be written");

  [scroll setAutohidesScrollers:YES];
  [document setFrameSize:NSMakeSize(20,20)];
  [scroll reflectScrolledClipView:[scroll contentView]];
  NSCAssert([v superview] == nil && [h superview] == nil, @"unneeded scrollers autohide");
  [document setFrameSize:NSMakeSize(1200,1000)];
  [scroll reflectScrolledClipView:[scroll contentView]];
  NSCAssert([v superview] == scroll && [h superview] == scroll, @"scrollers reappear for large documents");

  [v setKnobProportion:1];
  NSCAssert(![v isEnabled], @"full-page scroller must be disabled");
  [v lockFocus];
  NSCAssert([theme drawNativeScroller:v dirtyRect:[v bounds]], @"disabled scroller uses GTK too");
  [v unlockFocus];
  [window close];
  [document release]; [scroll release]; [window release];
  NSLog(@"GTK scrollers: both axes, flipped documents, dragging, trough clicks, resize, autohide, disabled rendering passed");
  [pool drain];
  return 0;
}
