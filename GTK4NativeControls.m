#import "GTK4NativeControls.h"
#import "GTK4NativeWindow.h"
#import "GTK4NativeClip.h"

@interface GTK4ControlPeer : NSObject
{
@public
  GTK4NativeView *bridge;
  GtkWidget *clip;
  CGFloat scale;
  NSArray *signature;
}
@end
@implementation GTK4ControlPeer
- (void)dealloc
{
  if (clip) {
    // GTK may retain the clipping widget for an in-flight frame. Disconnect its
    // child now, before releasing the bridge can unparent the source widget.
    GTK4NativeClipSetChild(clip, NULL);
    if (gtk_widget_get_parent(clip)) gtk_widget_unparent(clip);
    g_object_unref(clip);
  }
  [bridge release]; [signature release]; [super dealloc];
}
@end

static BOOL buttonControl(NSView *view)
{
  return [view isKindOfClass:[NSButton class]]
    || [view isKindOfClass:[NSSwitch class]] || [view isKindOfClass:[NSSegmentedControl class]]
    || [view isKindOfClass:[NSMatrix class]];
}
static NSArray *structure(NSView *view)
{
  if ([view isKindOfClass:[NSMatrix class]]) {
    NSMatrix *m = (id)view;
    // Cell identity matters: replacing a matrix cell invalidates GTK callbacks.
    return @[@([m numberOfRows]), @([m numberOfColumns]), [[[m cells] copy] autorelease], [NSValue valueWithSize:m.cellSize], [NSValue valueWithSize:m.intercellSpacing]];
  }
  if ([view isKindOfClass:[NSSegmentedControl class]])
    return @[@([(NSSegmentedControl *)view segmentCount]), @([(NSSegmentedControl *)view trackingMode])];
  if ([view isKindOfClass:[NSPopUpButton class]]) return @[@([(NSPopUpButton *)view pullsDown])];
  if ([view isKindOfClass:[NSButton class]]) {
    NSButtonCell *cell = [(NSButton *)view cell];
    return @[[[cell image] name] ?: @"", @([cell showsStateBy])];
  }
  return @[];
}
static NSValue *key(NSView *view) { return [NSValue valueWithPointer:view]; }

static void releaseScrollSource(gpointer source, GClosure *closure) { [(id)source release]; }
static gboolean controlScroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer source)
{
  NSView *view = source;
  NSScrollView *scroll = [view enclosingScrollView];
  NSWindow *window = [view window];
  if (!scroll || !window) return FALSE;
  GdkModifierType state = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller));
  NSUInteger modifiers = 0;
  if (state & GDK_SHIFT_MASK) modifiers |= NSShiftKeyMask;
  if (state & GDK_ALT_MASK) modifiers |= NSAlternateKeyMask;
  if (state & GDK_CONTROL_MASK) modifiers |= NSControlKeyMask;
  if (gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_SURFACE) {
    GtkWidget *widget = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
    CGFloat factor = [window userSpaceScaleFactor] / MAX(1, gtk_widget_get_scale_factor(widget));
    dx /= MAX(.001, [scroll horizontalLineScroll] * factor);
    dy /= MAX(.001, [scroll verticalLineScroll] * factor);
  }
  NSEvent *event = [NSEvent mouseEventWithType:NSScrollWheel
    location:[view convertPoint:NSZeroPoint toView:nil] modifierFlags:modifiers
    timestamp:g_get_monotonic_time()/1e6 windowNumber:[window windowNumber]
    context:nil eventNumber:0 clickCount:0 pressure:0 buttonNumber:0 deltaX:dx deltaY:-dy deltaZ:0];
  [scroll scrollWheel:event];
  return TRUE;
}

@implementation GTK4NativeControls
- (id)initWithHost:(GTK4NativeWindowDecorationView *)host
{
  if ((self = [super init])) { _host = host; _peers = [NSMutableDictionary new]; }
  return self;
}
- (BOOL)hasNativeWidgetForView:(NSView *)view { return [self widgetForView:view] != NULL; }
- (GtkWidget *)widgetForView:(NSView *)view
{
  GTK4ControlPeer *peer = [_peers objectForKey:key(view)];
  return peer ? [peer->bridge widget] : NULL;
}
- (BOOL)containsPoint:(NSPoint)point
{
  for (NSValue *value in _rects) if (NSPointInRect(point, [value rectValue])) return YES;
  return NO;
}
- (NSArray *)update
{
  NSMutableArray *rects = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  NSMutableArray *pending = [NSMutableArray array];
  NSWindow *window = [_host window];
  if ([window contentView]) [pending addObject:[window contentView]];
  graphene_rect_t body;
  if (!gtk_widget_compute_bounds(_host->_nativeContent, _host->_host, &body)) return @[];
  CGFloat factor = [window userSpaceScaleFactor] / MAX(1, gtk_widget_get_scale_factor(_host->_host));
  GtkWidget *defaultButton = NULL;
  while ([pending count]) {
    NSView *view = [[[pending lastObject] retain] autorelease]; [pending removeLastObject];
    if ([view isHiddenOrHasHiddenAncestor]) continue;
    // Native tables translate their own descendants. Cell-based table controls
    // and custom-drawn button subclasses keep their existing fallback.
    if ([view isKindOfClass:[NSTableView class]]) continue;
    if (!buttonControl(view)) { [pending addObjectsFromArray:[view subviews]]; continue; }
    if (![GTK4NativeView supportsView:view]) continue;
    NSValue *identity = key(view); [seen addObject:identity];
    GTK4ControlPeer *peer = [_peers objectForKey:identity];
    NSArray *nextSignature = structure(view);
    if (peer && (fabs(peer->scale-factor) > .001 || ![peer->signature isEqual:nextSignature])) {
      [_peers removeObjectForKey:identity]; peer = nil;
    }
    if (!peer) {
      peer = [[GTK4ControlPeer alloc] init];
      peer->scale = factor; peer->signature = [nextSignature copy];
      peer->bridge = [[GTK4NativeView alloc] initWithView:view scale:factor];
      if (!peer->bridge) { [peer release]; continue; }
      peer->clip = GTK4NativeClipNew([peer->bridge widget]); g_object_ref_sink(peer->clip);
      GtkEventController *scrollEvents = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
      g_signal_connect_data(scrollEvents, "scroll", G_CALLBACK(controlScroll), [view retain], releaseScrollSource, 0);
      gtk_widget_add_controller(peer->clip, scrollEvents);
      gtk_fixed_put(GTK_FIXED(_host->_nativeContent), peer->clip, 0, 0);
      [_peers setObject:peer forKey:identity];
      [peer release];
    }
    [peer->bridge synchronize];
    NSRect visible = NSIntersectionRect([view bounds], [view visibleRect]);
    BOOL show = !NSIsEmptyRect(visible);
    gtk_widget_set_visible(peer->clip, show);
    if (!show) continue;
    NSRect rect = [view convertRect:visible toView:_host];
    NSRect full = [view convertRect:[view bounds] toView:_host];
    NSRect bounds = [_host bounds];
    NSRect hostRect = NSMakeRect((NSMinX(rect)-NSMinX(bounds))*factor-body.origin.x,
      ([_host isFlipped] ? NSMinY(rect)-NSMinY(bounds) : NSMaxY(bounds)-NSMaxY(rect))*factor-body.origin.y,
      NSWidth(rect)*factor, NSHeight(rect)*factor);
    CGFloat left = (NSMinX(full)-NSMinX(rect))*factor;
    CGFloat top = ([_host isFlipped] ? NSMinY(full)-NSMinY(rect) : NSMaxY(rect)-NSMaxY(full))*factor;
    GtkAllocation allocation = {lround(left), lround(top), MAX(1,lround(NSWidth(full)*factor)), MAX(1,lround(NSHeight(full)*factor))};
    GTK4NativeClipSetAllocation(peer->clip, allocation);
    gtk_fixed_move(GTK_FIXED(_host->_nativeContent), peer->clip, hostRect.origin.x, hostRect.origin.y);
    gtk_widget_set_size_request(peer->clip, MAX(1,lround(hostRect.size.width)), MAX(1,lround(hostRect.size.height)));
    [rects addObject:[NSValue valueWithRect:hostRect]];
    if ([view isKindOfClass:[NSButton class]] && [(NSButton *)view isEnabled]
        && [[(NSButton *)view keyEquivalent] isEqual:@"\r"]) defaultButton = [peer->bridge widget];
  }
  // Removing the widget also removes GTK focus and stale input hit regions.
  for (NSValue *identity in [[[_peers allKeys] copy] autorelease])
    if (![seen containsObject:identity]) [_peers removeObjectForKey:identity];
  if (gtk_window_get_default_widget(GTK_WINDOW(_host->_host)) != defaultButton)
    gtk_window_set_default_widget(GTK_WINDOW(_host->_host), defaultButton);
  ASSIGNCOPY(_rects, rects);
  return _rects;
}
- (void)dealloc
{
  [_peers release]; [_rects release]; [super dealloc];
}
@end
