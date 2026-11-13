#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <math.h>

BOOL GTK4NativeWindowsAvailable(void)
{
  if (g_strcmp0(g_getenv("GTK_CSD"), "0") == 0) return NO;
  if (g_getenv("GTK4_NATIVE_WINDOWS") && !strcmp(g_getenv("GTK4_NATIVE_WINDOWS"), "0")) return NO;
  if (![GSCurrentServer() isKindOfClass:NSClassFromString(@"XGServer")]
      || !GDK_IS_X11_DISPLAY(gdk_display_get_default())) return NO;
  int event, error;
  return XShapeQueryExtension((Display *)[GSCurrentServer() serverDevice], &event, &error);
}
static int nativeDisplayScale(void)
{
  GListModel *monitors = gdk_display_get_monitors(gdk_display_get_default());
  GdkMonitor *monitor = g_list_model_get_item(monitors, 0);
  int scale = monitor ? gdk_monitor_get_scale_factor(monitor) : 1;
  if (monitor) g_object_unref(monitor);
  return MAX(1, scale);
}
GtkWindow *GTK4NativeHostForWindow(NSWindow *window)
{
  NSView *view = [window contentView];
  while ([view superview]) view = [view superview];
  if ([view isKindOfClass:[GTK4NativeWindowDecorationView class]])
    return GTK_WINDOW(((GTK4NativeWindowDecorationView *)view)->_host);
  return NULL;
}
static CGFloat nativeTitleHeight(void)
{
  static CGFloat height;
  if (!height) {
    GtkWidget *host = gtk_window_new();
    g_object_ref_sink(host);
    GtkWidget *bar = gtk_header_bar_new();
    gtk_widget_add_css_class(bar, "default-decoration");
    gtk_window_set_titlebar(GTK_WINDOW(host), bar);
    gtk_widget_realize(host);
    int minimum, natural;
    gtk_widget_measure(bar, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, NULL, NULL);
    height = MAX(1, natural);
    gtk_window_destroy(GTK_WINDOW(host));
    g_object_unref(host);
  }
  return height;
}
static BOOL hostedStyle(NSUInteger style)
{
  return (style & NSTitledWindowMask) && !(style & (NSIconWindowMask | NSMiniWindowMask));
}
static gboolean hostClose(GtkWindow *host, gpointer data)
{
  GTK4NativeWindowDecorationView *view = [(id)data retain];
  NSWindow *owner = [view window];
  if (![NSApp modalWindow] || [NSApp modalWindow] == owner || [owner worksWhenModal])
    [owner performClose:nil];
  [view release];
  return TRUE; // AppKit decides whether an edited document may close.
}
static void hostActive(GObject *host, GParamSpec *spec, gpointer data)
{
  GTK4NativeWindowDecorationView *view = data;
  if (gtk_window_is_active(GTK_WINDOW(host)) && view->_child) {
    NSWindow *window = [view window];
    if ([NSApp modalWindow] && [NSApp modalWindow] != window && ![window worksWhenModal]) return;
    [window makeKeyWindow];
    Display *display = (Display *)[GSServerForWindow(window) serverDevice];
    XWindowAttributes attr;
    if (XGetWindowAttributes(display, view->_child, &attr) && attr.map_state == IsViewable) {
      XSetInputFocus(display, view->_child, RevertToParent, CurrentTime);
      XFlush(display);
    }
  }
}

static gboolean hostContentEvent(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data)
{
  GTK4NativeWindowDecorationView *view = data;
  GdkEventType type = gdk_event_get_event_type(event);
  if (type == GDK_KEY_PRESS || type == GDK_KEY_RELEASE) return TRUE;
  double x, y, dx, dy;
  if (!gdk_event_get_position(event, &x, &y)) return FALSE;
  gtk_native_get_surface_transform(GTK_NATIVE(view->_host), &dx, &dy);
  x -= dx; y -= dy;
  // The embedded AppKit client handles this area. Do not let GtkWindow's
  // gestures claim the same pointer sequence on the ancestor surface.
  graphene_rect_t bounds;
  if (!gtk_widget_compute_bounds(gtk_window_get_child(GTK_WINDOW(view->_host)), view->_host, &bounds)) return FALSE;
  BOOL embedded = x >= 0 && x < gtk_widget_get_width(view->_host)
    && y >= bounds.origin.y && y < gtk_widget_get_height(view->_host);
  if (embedded && type == GDK_BUTTON_PRESS && view->_child) {
    Display *display = (Display *)[GSServerForWindow([view window]) serverDevice];
    XSetInputFocus(display, view->_child, RevertToParent, CurrentTime);
    XFlush(display);
  }
  return embedded;
}

@implementation GTK4NativeWindowDecorationView
+ (void)offsets:(float *)l :(float *)r :(float *)t :(float *)b forStyleMask:(NSUInteger)style
{
  if (!hostedStyle(style)) {
    [GSBackendWindowDecorationView offsets:l :r :t :b forStyleMask:style];
    return;
  }
  *l = *r = *b = 0;
  *t = nativeTitleHeight() * nativeDisplayScale();
}
+ (CGFloat)minFrameWidthWithTitle:(NSString *)title styleMask:(NSUInteger)style
{
  return hostedStyle(style) ? 240 * nativeDisplayScale() : 0;
}
+ (id)newWindowDecorationViewWithFrame:(NSRect)frame window:(NSWindow *)window
{
  if (!hostedStyle([window styleMask]))
    return (id)[[GSBackendWindowDecorationView alloc] initWithFrame:frame window:window];
  return [[self alloc] initWithFrame:frame window:window];
}
- (id)initWithFrame:(NSRect)frame window:(NSWindow *)owner
{
  if ((self = [super initWithFrame:frame window:owner])) {
    _host = gtk_window_new();
    g_object_ref_sink(_host);
    gtk_window_set_title(GTK_WINDOW(_host), [[owner title] UTF8String]);
    gtk_window_set_deletable(GTK_WINDOW(_host), ([owner styleMask] & NSClosableWindowMask) != 0);
    gtk_window_set_resizable(GTK_WINDOW(_host), ([owner styleMask] & NSResizableWindowMask) != 0);
    _header = gtk_header_bar_new();
    gtk_widget_add_css_class(_header, "default-decoration");
    gtk_window_set_titlebar(GTK_WINDOW(_host), _header);
    char *layout = NULL;
    g_object_get(gtk_settings_get_default(), "gtk-decoration-layout", &layout, NULL);
    if (layout) {
      char **sides = g_strsplit(layout, ":", 2);
      GString *filtered = g_string_new("");
      for (int side = 0; sides[side]; side++) {
        if (side) g_string_append_c(filtered, ':');
        char **controls = g_strsplit(sides[side], ",", -1);
        BOOL first = YES;
        for (int i = 0; controls[i]; i++) {
          if (!strcmp(controls[i], "minimize") && !([owner styleMask] & NSMiniaturizableWindowMask)) continue;
          if (!strcmp(controls[i], "maximize") && !([owner styleMask] & NSResizableWindowMask)) continue;
          if (!strcmp(controls[i], "close") && !([owner styleMask] & NSClosableWindowMask)) continue;
          if (!first) g_string_append_c(filtered, ',');
          g_string_append(filtered, controls[i]); first = NO;
        }
        g_strfreev(controls);
      }
      gtk_header_bar_set_decoration_layout(GTK_HEADER_BAR(_header), filtered->str);
      g_string_free(filtered, TRUE);
      g_strfreev(sides);
      g_free(layout);
    }
    // The empty GTK content establishes layout; the AppKit X11 child covers it.
    gtk_window_set_child(GTK_WINDOW(_host), gtk_drawing_area_new());
    gtk_widget_add_css_class(_host, "gnustep-native-window");
    GtkEventController *contentEvents = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(contentEvents, GTK_PHASE_CAPTURE);
    g_signal_connect(contentEvents, "event", G_CALLBACK(hostContentEvent), self);
    gtk_widget_add_controller(_host, contentEvents);
    g_signal_connect(_host, "map", G_CALLBACK(GTK4NativeRoundWindowCorners), NULL);
    g_signal_connect(_host, "close-request", G_CALLBACK(hostClose), self);
    g_signal_connect(_host, "notify::is-active", G_CALLBACK(hostActive), self);
  }
  return self;
}
- (NSUInteger)backendWindowStyleMask { return NSBorderlessWindowMask; }
- (void)setTitle:(NSString *)title
{
  [super setTitle:title];
  if (_host) {
    NSString *nativeTitle = documentEdited ? [title stringByAppendingString:@" •"] : title;
    gtk_window_set_title(GTK_WINDOW(_host), [nativeTitle UTF8String]);
  }
}
- (void)setDocumentEdited:(BOOL)edited
{
  [super setDocumentEdited:edited];
  NSString *title = [window title];
  if (edited) title = [title stringByAppendingString:@" •"];
  gtk_window_set_title(GTK_WINDOW(_host), [title UTF8String]);
}
- (void)setWindowNumber:(int)number
{
  if (!number && _child) {
    [_hostTimer invalidate];
    _hostTimer = nil;
    Display *display = (Display *)[GSServerForWindow(window) serverDevice];
    XUnmapWindow(display, _child);
    XReparentWindow(display, _child, DefaultRootWindow(display), 0, 0);
    XSync(display, False); // Detach before GTK destroys its parent surface.
    _child = 0;
    _parent = 0;
    _lastGeometry = NSZeroRect;
    _wasMinimized = _sawNativeNormal = NO;
    gtk_widget_set_visible(_host, FALSE);
  }
  [super setWindowNumber:number];
  if (number && !_child) {
    GSDisplayServer *server = GSServerForWindow(window);
    _child = (unsigned long)[server windowDevice:number];
    gtk_widget_realize(_host);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(_host));
    _parent = gdk_x11_surface_get_xid(surface);
    Display *display = (Display *)[server serverDevice];
    XReparentWindow(display, _child, _parent, 0, 0);
    XSync(display, False);
    _hostTimer = [NSTimer timerWithTimeInterval:0.01 target:self
      selector:@selector(synchronizeNativeWindow:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_hostTimer forMode:NSRunLoopCommonModes];
    [[NSRunLoop mainRunLoop] addTimer:_hostTimer forMode:NSModalPanelRunLoopMode];
    [[NSRunLoop mainRunLoop] addTimer:_hostTimer forMode:NSEventTrackingRunLoopMode];
    [self placeNativeWindow:[window frame]];
  }
}
- (BOOL)placeNativeWindow:(NSRect)frame
{
  if (!_host || !_parent) return NO;
  CGFloat scale = gdk_surface_get_scale_factor(gtk_native_get_surface(GTK_NATIVE(_host)));
  GtkBorder border, padding;
  gtk_style_context_get_border(gtk_widget_get_style_context(_host), &border);
  gtk_style_context_get_padding(gtk_widget_get_style_context(_host), &padding);
  gtk_window_set_default_size(GTK_WINDOW(_host), MAX(1, lround(frame.size.width / scale) + border.left + border.right + padding.left + padding.right),
    MAX(1, lround(frame.size.height / scale) + border.top + border.bottom + padding.top + padding.bottom));
  double dx, dy;
  gtk_native_get_surface_transform(GTK_NATIVE(_host), &dx, &dy);
  Display *display = (Display *)[GSServerForWindow(window) serverDevice];
  XWindowAttributes root;
  XGetWindowAttributes(display, DefaultRootWindow(display), &root);
  XMoveWindow(display, _parent, lround(frame.origin.x - dx * scale),
    lround(root.height - NSMaxY(frame) - dy * scale));
  XFlush(display);
  NSRect old = [window frame];
  if (!NSEqualRects(old, frame)) {
    BOOL resized = !NSEqualSizes(old.size, frame.size);
    NSEvent *event = [NSEvent otherEventWithType:NSAppKitDefined location:frame.origin
      modifierFlags:0 timestamp:0 windowNumber:[window windowNumber] context:nil
      subtype:resized ? GSAppKitWindowResized : GSAppKitWindowMoved
      data1:resized ? frame.size.width : frame.origin.x
      data2:resized ? frame.size.height : frame.origin.y];
    [window sendEvent:event];
  }
  return YES;
}
- (BOOL)orderNativeWindow:(NSInteger)place relativeTo:(NSInteger)other
{
  if (!_child) return NO;
  Display *display = (Display *)[GSServerForWindow(window) serverDevice];
  _wantedVisible = place != NSWindowOut;
  if (place == NSWindowOut) {
    gtk_widget_set_visible(_host, FALSE);
    XUnmapWindow(display, _child);
  } else {
    NSWindow *owner = [window sheetParent] ?: [window parentWindow];
    if (!owner && [NSApp modalWindow] == window && [NSApp mainWindow] != window) owner = [NSApp mainWindow];
    gtk_window_set_transient_for(GTK_WINDOW(_host), GTK4NativeHostForWindow(owner));
    gtk_window_set_modal(GTK_WINDOW(_host), [NSApp modalWindow] == window || [window sheetParent] != nil);
    gtk_window_present(GTK_WINDOW(_host));
    // Map the child only after GTK has allocated and painted its host.
    // Mapping an unshaped child first can occlude GTK's initial frame clock.
    if (other > 0) {
      GtkWindow *sibling = GTK4NativeHostForWindow([NSApp windowWithWindowNumber:other]);
      if (sibling) {
        Window siblingID = gdk_x11_surface_get_xid(gtk_native_get_surface(GTK_NATIVE(sibling)));
        XEvent request = {0};
        request.xclient.type = ClientMessage;
        request.xclient.window = _parent;
        request.xclient.message_type = XInternAtom(display, "_NET_RESTACK_WINDOW", False);
        request.xclient.format = 32;
        request.xclient.data.l[0] = 1;
        request.xclient.data.l[1] = siblingID;
        request.xclient.data.l[2] = place == NSWindowBelow ? Below : Above;
        XSendEvent(display, DefaultRootWindow(display), False,
          SubstructureRedirectMask | SubstructureNotifyMask, &request);
      }
    } else if (place == NSWindowBelow) XLowerWindow(display, _parent);
    [self synchronizeNativeWindow:nil];
  }
  XFlush(display);
  return YES;
}
- (BOOL)miniaturizeNativeWindow
{
  if (!_host) return NO;
  gtk_window_minimize(GTK_WINDOW(_host));
  return YES;
}
- (void)synchronizeNativeWindow:(id)sender
{
  if (_placing || !_child || !_wantedVisible) return;
  [self retain];
  _placing = YES;
  @try {
    for (int i = 0; i < 64 && g_main_context_pending(NULL); i++)
      g_main_context_iteration(NULL, FALSE);
    if (!_child) return;
    NSWindow *parentWindow = [window sheetParent] ?: [window parentWindow];
    if (!parentWindow && [NSApp modalWindow] == window && [NSApp mainWindow] != window) parentWindow = [NSApp mainWindow];
    GtkWindow *parent = GTK4NativeHostForWindow(parentWindow);
    if (gtk_window_get_transient_for(GTK_WINDOW(_host)) != parent)
      gtk_window_set_transient_for(GTK_WINDOW(_host), parent);
    BOOL modal = [NSApp modalWindow] == window || [window sheetParent] != nil;
    if (gtk_window_get_modal(GTK_WINDOW(_host)) != modal)
      gtk_window_set_modal(GTK_WINDOW(_host), modal);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(_host));
    BOOL minimized = (gdk_toplevel_get_state(GDK_TOPLEVEL(surface)) & GDK_TOPLEVEL_STATE_MINIMIZED) != 0;
    if (!minimized && gtk_widget_get_mapped(_host)) _sawNativeNormal = YES;
    if (_sawNativeNormal && minimized != _wasMinimized) {
      _wasMinimized = minimized;
      NSEvent *event = [NSEvent otherEventWithType:NSAppKitDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:[window windowNumber] context:nil
        subtype:minimized ? GSAppKitWindowMiniaturize : GSAppKitWindowDeminiaturize data1:0 data2:0];
      [NSApp postEvent:event atStart:NO];
    }
    if (!gtk_widget_get_mapped(_host)) { _placing = NO; return; }
    double dx, dy;
    gtk_native_get_surface_transform(GTK_NATIVE(_host), &dx, &dy);
    double alpha = [window alphaValue];
    if (fabs(gtk_widget_get_opacity(_host) - alpha) > 0.001) gtk_widget_set_opacity(_host, alpha);
    int scale = gdk_surface_get_scale_factor(gtk_native_get_surface(GTK_NATIVE(_host)));
    // GDK reports a new scale before the theme updates AppKit's logical scale.
    // Importing host geometry in between turns the scale change into a resize.
    NSNumber *desktopScale = [[[NSUserDefaults standardUserDefaults]
      volatileDomainForName:@"GSThemeDomain"] objectForKey:@"GSScaleFactor"];
    if (desktopScale && fabs(scale - desktopScale.doubleValue) > 0.001) return;
    int width = gtk_widget_get_width(_host) * scale;
    int height = gtk_widget_get_height(_host) * scale;
    if (width < 1 || height < 1) { _placing = NO; return; }
    Display *display = (Display *)[GSServerForWindow(window) serverDevice];
    Window root = DefaultRootWindow(display), unused;
    NSInteger level = [window level];
    if (level != _nativeLevel) {
      const char *atoms[] = {"_NET_WM_STATE_ABOVE", "_NET_WM_STATE_BELOW"};
      for (int i = 0; i < 2; i++) {
        XEvent request = {0};
        request.xclient.type = ClientMessage;
        request.xclient.window = _parent;
        request.xclient.message_type = XInternAtom(display, "_NET_WM_STATE", False);
        request.xclient.format = 32;
        request.xclient.data.l[0] = i == 0 ? level > NSNormalWindowLevel : level < NSNormalWindowLevel;
        request.xclient.data.l[1] = XInternAtom(display, atoms[i], False);
        request.xclient.data.l[3] = 1;
        XSendEvent(display, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &request);
      }
      _nativeLevel = level;
    }
    NSSize minSize = [window minSize], maxSize = [window maxSize];
    if (!NSEqualSizes(minSize, _nativeMinSize) || !NSEqualSizes(maxSize, _nativeMaxSize)) {
      GtkWidget *content = gtk_window_get_child(GTK_WINDOW(_host));
      gtk_widget_set_size_request(content, MAX(0, ceil(minSize.width / scale)),
        MAX(0, ceil(minSize.height / scale - nativeTitleHeight())));
      XSizeHints hints;
      long supplied;
      if (XGetWMNormalHints(display, _parent, &hints, &supplied)) {
        hints.flags |= PMaxSize;
        hints.max_width = MIN(65535, MAX(1, maxSize.width));
        hints.max_height = MIN(65535, MAX(1, maxSize.height));
        XSetWMNormalHints(display, _parent, &hints);
      }
      _nativeMinSize = minSize;
      _nativeMaxSize = maxSize;
    }
    int x, y;
    XTranslateCoordinates(display, _parent, root, lround(dx * scale), lround(dy * scale), &x, &y, &unused);
    NSRect geometry = NSMakeRect(x, y, width, height);
    graphene_rect_t contentBounds;
    if (!gtk_widget_compute_bounds(gtk_window_get_child(GTK_WINDOW(_host)), _host, &contentBounds)) return;
    int top = lround(contentBounds.origin.y * scale);
    double radius = GTK4NativeWindowCornerRadius(_host) * scale;
    if (gtk_window_is_maximized(GTK_WINDOW(_host)) || gtk_window_is_fullscreen(GTK_WINDOW(_host))) radius = 0;
    if (!NSEqualRects(geometry, _lastGeometry) || radius != _shapeRadius || top != _shapeTitleHeight) {
      // Keep the child in the same coordinates as AppKit's complete window.
      // Its shape exposes GTK's real titlebar and the rounded GTK frame beneath.
      XMoveResizeWindow(display, _child, lround(dx * scale), lround(dy * scale), width, height);
      XRectangle *rows = g_new(XRectangle, height);
      int count = 0;
      for (int row = MAX(0, top); row < height - 1; row++) {
        int inset = 1;
        double bottom = height - 1 - row;
        if (radius > 0 && bottom < radius) {
          double d = radius - bottom;
          inset = MAX(1, (int)ceil(radius - sqrt(MAX(0, radius * radius - d * d))) + 1);
        }
        if (width > inset * 2) rows[count++] = (XRectangle){inset, row, width - 2 * inset, 1};
      }
      XShapeCombineRectangles(display, _child, ShapeBounding, 0, 0, rows, count, ShapeSet, YXBanded);
      XShapeCombineRectangles(display, _child, ShapeInput, 0, 0, rows, count, ShapeSet, YXBanded);
      g_free(rows);
      // Parent moves do not configure the child: synthesize the ICCCM root-space
      // configure so the normal backend updates frame, backing store and layout.
      XEvent event = {0};
      event.xconfigure.type = ConfigureNotify;
      event.xconfigure.display = display;
      event.xconfigure.event = _child;
      event.xconfigure.window = _child;
      event.xconfigure.x = x;
      event.xconfigure.y = y;
      event.xconfigure.width = width;
      event.xconfigure.height = height;
      XSendEvent(display, _child, False, StructureNotifyMask, &event);
      XFlush(display);
      _lastGeometry = geometry;
      _shapeRadius = radius;
      _shapeTitleHeight = top;
    }
    XWindowAttributes childAttributes;
    if (XGetWindowAttributes(display, _child, &childAttributes) && childAttributes.map_state != IsViewable) {
      XMapWindow(display, _child);
      XFlush(display);
    }
    if (gtk_window_is_active(GTK_WINDOW(_host))) {
      Window focus;
      int revert;
      XGetInputFocus(display, &focus, &revert);
      if (focus == _parent) hostActive(G_OBJECT(_host), NULL, self);
    }
  } @finally {
    _placing = NO;
    [self release];
  }
}
- (void)dealloc
{
  [_hostTimer invalidate];
  if (_host) {
    gtk_window_destroy(GTK_WINDOW(_host));
    g_object_unref(_host);
  }
  [super dealloc];
}
@end
