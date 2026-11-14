#import "GTK4NativeControls.h"
#import "GTK4NativeWindow.h"
#import "GTK4NativeClip.h"
#import "GTK4NativeCustomView.h"

@interface GTK4ControlPeer : NSObject
{
@public
  GTK4NativeView *bridge;
  GtkWidget *clip;
  CGFloat scale;
  NSArray *signature;
  BOOL invalidated;
}
- (void)invalidate;
@end
@implementation GTK4ControlPeer
- (void)invalidate
{
  if (invalidated) return; invalidated=YES;
  [bridge invalidate];
  if (clip) { GTK4NativeClipSetChild(clip,NULL); if (gtk_widget_get_parent(clip)) gtk_widget_unparent(clip); }
}
- (void)dealloc
{
  [self invalidate];
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

// A supported document is a single GTK scene, with one stable viewport hole.
// AppKit clip bounds are mirrored for API compatibility, never used to move
// individual native children during native scrolling.
@interface GTK4ScrollPeer : NSObject
{
@public
  NSScrollView *source;
  GTK4NativeView *bridge;
  GtkWidget *scroller;
  GtkWidget *clip;
  CGFloat scale;
  NSArray *signature;
  NSPoint lastOrigin;
  BOOL synchronizing;
  BOOL initialized;
}
- (void)nativeScrolled;
- (void)synchronize;
- (void)invalidate;
@end
static void nativeScrolled(GtkAdjustment *adjustment, gpointer peer) { [(GTK4ScrollPeer *)peer nativeScrolled]; }
@implementation GTK4ScrollPeer
- (void)nativeScrolled
{
  if (synchronizing || !initialized) return;
  NSView *document = source.documentView;
  NSClipView *content = source.contentView;
  CGFloat x = gtk_adjustment_get_value(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(scroller)))/scale;
  CGFloat y = gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller)))/scale;
  if (!document.isFlipped) y = MAX(0, NSHeight(document.bounds)-NSHeight(content.bounds)-y);
  synchronizing = YES;
  [content scrollToPoint:NSMakePoint(x,y)];
  [source reflectScrolledClipView:content];
  lastOrigin = content.bounds.origin;
  synchronizing = NO;
}
- (void)synchronize
{
  [bridge synchronize];
  NSView *document=source.documentView;
  gtk_widget_set_size_request(bridge.widget,MAX(1,lround(NSWidth(document.frame)*scale)),MAX(1,lround(NSHeight(document.frame)*scale)));
  NSClipView *content = source.contentView;
  if (!initialized || !NSEqualPoints(lastOrigin,content.bounds.origin)) {
    GtkAdjustment *h = gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(scroller));
    GtkAdjustment *v = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller));
    if (gtk_adjustment_get_page_size(v) <= 0) return;
    CGFloat y = NSMinY(content.bounds);
    if (!document.isFlipped) y = MAX(0, NSHeight(document.bounds)-NSMaxY(content.bounds));
    synchronizing = YES;
    gtk_adjustment_set_value(h, NSMinX(content.bounds)*scale);
    gtk_adjustment_set_value(v, y*scale);
    lastOrigin = content.bounds.origin;
    initialized = YES;
    synchronizing = NO;
  }
}
- (void)invalidate
{
  initialized = NO;
  [bridge invalidate];
  g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(scroller)), self);
  g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroller)), self);
  GTK4NativeClipSetChild(clip, NULL);
  if (gtk_widget_get_parent(clip)) gtk_widget_unparent(clip);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), NULL);
}
- (void)dealloc
{
  [self invalidate];
  g_object_unref(clip); g_object_unref(scroller);
  [bridge release]; [source release]; [signature release]; [super dealloc];
}
@end

static NSArray *structure(NSView *view);
static void documentStructureInternal(NSView *view,NSMutableArray *signature,BOOL root)
{
  id peer=GSNativeViewPeerForView(view);
  NSRect frame=[peer respondsToSelector:@selector(configurationFrameForView:)]?[peer configurationFrameForView:view]:view.frame;
  [signature addObject:@[[NSValue valueWithPointer:view],[NSValue valueWithRect:root?NSZeroRect:frame],
    @(view.isFlipped),@(view.translatesAutoresizingMaskIntoConstraints),@(view.autoresizingMask)]];
  [signature addObject:structure(view)];
  for(NSLayoutConstraint *c in view.constraints)
    [signature addObject:@[[NSValue valueWithPointer:c],@(c.constant),@(c.priority)]];
  if([view class]==[NSScrollView class]) {
    NSScrollView *scroll=(id)view;
    [signature addObject:@[@(scroll.hasHorizontalScroller),@(scroll.hasVerticalScroller),@(scroll.borderType)]];
    if(scroll.documentView) documentStructureInternal(scroll.documentView,signature,YES);
  } else for(NSView *child in view.subviews) documentStructureInternal(child,signature,NO);
}
static void documentStructure(NSView *view,NSMutableArray *signature) { documentStructureInternal(view,signature,YES); }

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
  if ((self = [super init])) { _host = host; _peers = [NSMutableDictionary new]; _scrollPeers = [NSMutableDictionary new]; }
  return self;
}
- (BOOL)hasNativeWidgetForView:(NSView *)view { return [self widgetForView:view] != NULL; }
- (GtkWidget *)widgetForView:(NSView *)view
{
  GTK4ControlPeer *peer = [_peers objectForKey:key(view)];
  if (peer) return [peer->bridge widget];
  for (NSValue *identity in _peers) {
    GTK4ControlPeer *candidate=[_peers objectForKey:identity];
    GtkWidget *widget=[candidate->bridge widgetForView:view]; if(widget) return widget;
  }
  for (GTK4ScrollPeer *scroll in [_scrollPeers allValues]) {
    if (scroll->source == view) return scroll->scroller;
    GtkWidget *widget = [scroll->bridge widgetForView:view];
    if (widget) return widget;
  }
  return NULL;
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
  NSMutableSet *seenScrolls = [NSMutableSet set];
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
    if ([view isKindOfClass:[NSScrollView class]]) {
      NSScrollView *scroll = (id)view;
      NSView *document = scroll.documentView;
      // Headers, rulers and mixed/custom drawing need the existing AppKit path.
      if ([scroll class] == [NSScrollView class] && document && ![scroll rulersVisible]
          && [GTK4NativeView supportsView:document]) {
        NSValue *identity = key(view); [seenScrolls addObject:identity];
        NSMutableArray *next = [NSMutableArray array]; documentStructure(document, next);
        [next addObject:@[@(scroll.hasVerticalScroller), @(scroll.hasHorizontalScroller), @(scroll.borderType)]];
        GTK4ScrollPeer *peer = [_scrollPeers objectForKey:identity];
        if (peer && (fabs(peer->scale-factor) > .001 || ![peer->signature isEqual:next])) {
          [peer invalidate]; [_scrollPeers removeObjectForKey:identity]; peer = nil;
        }
        if (!peer) {
          peer = [GTK4ScrollPeer new]; peer->source = [scroll retain]; peer->scale = factor;
          peer->signature = [next copy];
          peer->bridge = [[GTK4NativeView alloc] initWithView:document scale:factor];
          peer->scroller = gtk_scrolled_window_new(); g_object_ref_sink(peer->scroller);
          gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(peer->scroller),
            scroll.hasHorizontalScroller ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER,
            scroll.hasVerticalScroller ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER);
          gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(peer->scroller), scroll.borderType != NSNoBorder);
          gtk_widget_add_css_class(peer->scroller, "view");
          gtk_widget_set_size_request(peer->bridge.widget, MAX(1,lround(NSWidth(document.frame)*factor)),
            MAX(1,lround(NSHeight(document.frame)*factor)));
          gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(peer->scroller), peer->bridge.widget);
          peer->clip = GTK4NativeClipNew(peer->scroller); g_object_ref_sink(peer->clip);
          gtk_fixed_put(GTK_FIXED(_host->_nativeContent),peer->clip,0,0);
          g_signal_connect(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(peer->scroller)),
            "value-changed",G_CALLBACK(nativeScrolled),peer);
          g_signal_connect(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(peer->scroller)),
            "value-changed",G_CALLBACK(nativeScrolled),peer);
          [_scrollPeers setObject:peer forKey:identity]; [peer release];
        }
        [peer synchronize];
        NSRect visible = NSIntersectionRect(view.bounds, view.visibleRect);
        gtk_widget_set_visible(peer->clip,!NSIsEmptyRect(visible));
        if (!NSIsEmptyRect(visible)) {
          NSRect rect = [view convertRect:visible toView:_host];
          NSRect full = [view convertRect:view.bounds toView:_host];
          NSRect bounds = _host.bounds;
          NSRect hostRect = NSMakeRect((NSMinX(rect)-NSMinX(bounds))*factor-body.origin.x,
            (_host.isFlipped ? NSMinY(rect)-NSMinY(bounds) : NSMaxY(bounds)-NSMaxY(rect))*factor-body.origin.y,
            NSWidth(rect)*factor, NSHeight(rect)*factor);
          GtkAllocation allocation = {lround((NSMinX(full)-NSMinX(rect))*factor),
            lround((_host.isFlipped ? NSMinY(full)-NSMinY(rect) : NSMaxY(rect)-NSMaxY(full))*factor),
            MAX(1,lround(NSWidth(full)*factor)),MAX(1,lround(NSHeight(full)*factor))};
          GTK4NativeClipSetAllocation(peer->clip,allocation);
          gtk_fixed_move(GTK_FIXED(_host->_nativeContent),peer->clip,hostRect.origin.x,hostRect.origin.y);
          gtk_widget_set_size_request(peer->clip,MAX(1,lround(NSWidth(hostRect))),MAX(1,lround(NSHeight(hostRect))));
          [rects addObject:[NSValue valueWithRect:hostRect]];
        }
        NSMutableArray *controls = [NSMutableArray arrayWithObject:document];
        while (controls.count) {
          NSView *control = controls.lastObject; [controls removeLastObject];
          [controls addObjectsFromArray:control.subviews];
          if ([control isKindOfClass:[NSButton class]] && [(NSButton *)control isEnabled]
              && [[(NSButton *)control keyEquivalent] isEqual:@"\r"])
            defaultButton = [peer->bridge widgetForView:control];
        }
        continue;
      }
    }
    BOOL scene=(view==window.contentView);
    BOOL custom=GTK4NativeCanWrapView(view);
    if (!buttonControl(view) && !scene && !custom) { [pending addObjectsFromArray:view.subviews]; continue; }
    if (![GTK4NativeView supportsView:view]) { if(scene || custom) [pending addObjectsFromArray:view.subviews]; continue; }
    NSValue *identity = key(view); [seen addObject:identity];
    GTK4ControlPeer *peer = [_peers objectForKey:identity];
    NSMutableArray *nextSignature=[NSMutableArray array];
    documentStructure(view,nextSignature);
    if (peer && (fabs(peer->scale-factor) > .001 || ![peer->signature isEqual:nextSignature])) {
      [peer invalidate]; [_peers removeObjectForKey:identity]; peer = nil;
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
    NSMutableArray *controls=[NSMutableArray arrayWithObject:view];
    while(controls.count) {
      NSView *control=controls.lastObject; [controls removeLastObject];
      if([control class]==[NSScrollView class]) { id document=[(NSScrollView *)control documentView]; if(document) [controls addObject:document]; }
      else [controls addObjectsFromArray:control.subviews];
      if([control isKindOfClass:[NSButton class]] && [(NSButton *)control isEnabled]
        && [[(NSButton *)control keyEquivalent] isEqual:@"\r"]) defaultButton=[peer->bridge widgetForView:control];
    }
  }
  // Removing the widget also removes GTK focus and stale input hit regions.
  for (NSValue *identity in [[[_peers allKeys] copy] autorelease])
    if (![seen containsObject:identity]) { [[_peers objectForKey:identity] invalidate]; [_peers removeObjectForKey:identity]; }
  for (NSValue *identity in [[[_scrollPeers allKeys] copy] autorelease])
    if (![seenScrolls containsObject:identity]) {
      [[_scrollPeers objectForKey:identity] invalidate];
      [_scrollPeers removeObjectForKey:identity];
    }
  if (gtk_window_get_default_widget(GTK_WINDOW(_host->_host)) != defaultButton)
    gtk_window_set_default_widget(GTK_WINDOW(_host->_host), defaultButton);
  ASSIGNCOPY(_rects, rects);
  return _rects;
}
- (void)dealloc
{
  for (NSValue *identity in _peers) [[_peers objectForKey:identity] invalidate];
  for (GTK4ScrollPeer *peer in [_scrollPeers allValues]) [peer invalidate];
  [_peers release]; [_scrollPeers release]; [_rects release]; [super dealloc];
}
@end
