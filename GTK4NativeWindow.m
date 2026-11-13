#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeMenu.h"
#import "GTK4NativeTable.h"
#import <GNUstepGUI/GSToolbarView.h>

// Keep the AppKit view attached for toolbar ownership and validation.
@interface GSWindowDecorationView (GTK4NativeToolbarPrivate)
- (void)addToolbarView:(GSToolbarView *)view;
- (void)removeToolbarView:(GSToolbarView *)view;
- (void)adjustToolbarView:(GSToolbarView *)view;
@end
@interface NSToolbar (GTK4NativePrivate)
- (GSToolbarView *)_toolbarView;
@end
@interface GSToolbarView (GTK4NativePrivate)
- (CGFloat)_heightFromLayout;
@end
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <math.h>

// The desktop sees the GTK host, while AppKit assigns application metadata to
// its embedded X11 child. Preserve that metadata on the visible top-level.
static void copyApplicationProperty(Display *display, Window child, Window host, const char *name)
{
  Atom property = XInternAtom(display, name, False), type;
  int format;
  unsigned long count, remaining;
  unsigned char *data = NULL;
  if (XGetWindowProperty(display, child, property, 0, 0, False, AnyPropertyType,
        &type, &format, &count, &remaining, &data) != Success) return;
  if (data) XFree(data);
  data = NULL;
  if (type == None || remaining == 0) return;
  if (XGetWindowProperty(display, child, property, 0, (remaining + 3) / 4,
        False, AnyPropertyType, &type, &format, &count, &remaining, &data) == Success
      && data && type != None && remaining == 0) {
    XChangeProperty(display, host, property, type, format, PropModeReplace, data, count);
  }
  if (data) XFree(data);
}

static void setApplicationIcon(Display *display, Window host)
{
  // The AppKit backend only sets _NET_WM_ICON when it detects an EWMH
  // window manager. Set it directly on our host, including on bare X servers.
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[[NSApp applicationIconImage] TIFFRepresentation]];
  NSInteger width = [bitmap pixelsWide], height = [bitmap pixelsHigh];
  if (width <= 0 || height <= 0) return;
  NSMutableData *data = [NSMutableData dataWithLength:(2 + width * height) * sizeof(unsigned long)];
  unsigned long *pixels = [data mutableBytes];
  pixels[0] = width; pixels[1] = height;
  for (NSInteger y = 0; y < height; y++) for (NSInteger x = 0; x < width; x++) {
    NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
    unsigned long red = lround([color redComponent] * 255);
    unsigned long green = lround([color greenComponent] * 255);
    unsigned long blue = lround([color blueComponent] * 255);
    unsigned long alpha = lround([color alphaComponent] * 255);
    pixels[2 + y * width + x] = (alpha << 24) | (red << 16) | (green << 8) | blue;
  }
  XChangeProperty(display, host, XInternAtom(display, "_NET_WM_ICON", False),
    XA_CARDINAL, 32, PropModeReplace, (unsigned char *)pixels, 2 + width * height);
}

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
static BOOL nativeToolbarHasFocus(GTK4NativeWindowDecorationView *view)
{
  GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(view->_host));
  return focus && ((view->_nativeToolbar && gtk_widget_is_ancestor(focus, view->_nativeToolbar))
    || (view->_nativeToolbarSearch && gtk_widget_is_ancestor(focus, view->_nativeToolbarSearch))
    || (view->_nativeContent && gtk_widget_is_ancestor(focus, view->_nativeContent)));
}
static void toolbarItemReleased(gpointer item) { [(id)item release]; }
static void toolbarClicked(GtkButton *button, gpointer data)
{
  NSToolbarItem *item = [(id)data retain];
  NSControl *control = (id)[item view];
  if ([control isKindOfClass:[NSButton class]]) {
    NSMenu *menu = [control menu];
    if (menu) {
      GtkNative *native = gtk_widget_get_native(GTK_WIDGET(button));
      GtkWidget *host = GTK_WIDGET(native);
      graphene_rect_t bounds;
      if (gtk_widget_compute_bounds(GTK_WIDGET(button), host, &bounds)) {
        GdkSurface *surface = gtk_native_get_surface(native);
        int scale = gdk_surface_get_scale_factor(surface);
        double dx, dy; gtk_native_get_surface_transform(native, &dx, &dy);
        Display *display = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
        Window root = DefaultRootWindow(display), ignored;
        int x, y; XWindowAttributes attr;
        XGetWindowAttributes(display, root, &attr);
        XTranslateCoordinates(display, gdk_x11_surface_get_xid(surface), root,
          lround((dx + bounds.origin.x) * scale), lround((dy + bounds.origin.y) * scale), &x, &y, &ignored);
        GTK4ShowNativeMenu(menu, NSMakeRect(x, attr.height - y - bounds.size.height * scale,
          bounds.size.width * scale, bounds.size.height * scale), [control window]);
      }
    } else [(NSButton *)control performClick:nil];
    [item release]; return;
  }
  NSToolbar *toolbar = [item toolbar];
  id delegate = [toolbar delegate];
  if ([delegate respondsToSelector:@selector(toolbarSelectableItemIdentifiers:)]
      && [[delegate toolbarSelectableItemIdentifiers:toolbar] containsObject:[item itemIdentifier]])
    [toolbar setSelectedItemIdentifier:[item itemIdentifier]];
  [NSApp sendAction:[item action] to:[item target] from:item];
  [item release];
}
static void toolbarSearchChanged(GtkSearchEntry *entry, gpointer data)
{
  NSSearchField *field = (id)[[(NSToolbarItem *)data view] retain];
  NSString *text = [NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(entry))];
  if (![[field stringValue] isEqual:text]) {
    [field setStringValue:text];
    [field sendAction:[field action] to:[field target]];
  }
  [field release];
}
static void toolbarSegmentClicked(GtkButton *button, gpointer data)
{
  NSToolbarItem *item = [(id)data retain];
  NSSegmentedControl *control = (id)[item view];
  NSInteger segment = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "appkit-segment"));
  if ([control trackingMode] == NSSegmentSwitchTrackingSelectAny)
    [control setSelected:![control isSelectedForSegment:segment] forSegment:segment];
  else [control setSelectedSegment:segment];
  [control sendAction:[control action] to:[control target]];
  [item release];
}
static GtkWidget *toolbarImage(NSImage *image, int scale)
{
  const CGFloat iconSize = 24;
  // Replace standard template bitmaps with semantically equivalent GTK
  // symbolic sources. Unknown names and missing theme icons keep their artwork.
  static const struct { NSString *name; const char *icon; } symbols[] = {
    {@"NSAddTemplate", "list-add-symbolic"},
    {@"NSRemoveTemplate", "list-remove-symbolic"},
    {@"NSRefreshTemplate", "view-refresh-symbolic"},
    {@"NSRefreshFreestandingTemplate", "view-refresh-symbolic"},
    {@"NSStopProgressTemplate", "process-stop-symbolic"},
    {@"NSStopProgressFreestandingTemplate", "process-stop-symbolic"},
    {@"NSEnterFullScreenTemplate", "view-fullscreen-symbolic"},
    {@"NSExitFullScreenTemplate", "view-restore-symbolic"},
    {@"NSGoLeftTemplate", "go-previous-symbolic"},
    {@"NSGoRightTemplate", "go-next-symbolic"},
    {@"NSLeftFacingTriangleTemplate", "pan-start-symbolic"},
    {@"NSRightFacingTriangleTemplate", "pan-end-symbolic"},
    {@"NSIconViewTemplate", "view-grid-symbolic"},
    {@"NSListViewTemplate", "view-list-symbolic"},
    {@"NSLockLockedTemplate", "changes-prevent-symbolic"},
    {@"NSLockUnlockedTemplate", "changes-allow-symbolic"},
    {@"NSBluetoothTemplate", "bluetooth-symbolic"},
  };
  if ([image isTemplate]) {
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gdk_display_get_default());
    for (NSUInteger i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
      if ([[image name] isEqual:symbols[i].name] && gtk_icon_theme_has_icon(theme, symbols[i].icon)) {
        GtkWidget *widget = gtk_image_new_from_icon_name(symbols[i].icon);
        gtk_image_set_pixel_size(GTK_IMAGE(widget), iconSize);
        return widget;
      }
    }
  }
  NSSize size = [image size];
  if (size.width <= 0 || size.height <= 0) return NULL;
  // Render the source at GTK's destination density. TIFFRepresentation can
  // freeze a PDF at its original (often 16-point) resolution before GTK scales it.
  NSCachedImageRep *canvas = [[NSCachedImageRep alloc]
    initWithSize:NSMakeSize(iconSize, iconSize)
    pixelsWide:iconSize * MAX(1, scale) pixelsHigh:iconSize * MAX(1, scale)
    depth:[[NSScreen mainScreen] depth] separate:YES alpha:YES];
  NSBitmapImageRep *rep = nil;
  [[[canvas window] contentView] lockFocus];
  @try {
    NSRect bounds = NSMakeRect(0, 0, iconSize, iconSize);
    NSRectFillUsingOperation(bounds, NSCompositeClear);
    [[NSColor blackColor] set];
    CGFloat fit = MIN(iconSize / size.width, iconSize / size.height);
    NSRect target = NSMakeRect((iconSize - size.width * fit) / 2,
      (iconSize - size.height * fit) / 2, size.width * fit, size.height * fit);
    [image drawInRect:target fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    rep = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:bounds] autorelease];
  } @finally {
    [[[canvas window] contentView] unlockFocus];
    [canvas release];
  }
  NSData *png = [rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
  if (!png) return NULL;
  GBytes *bytes = g_bytes_new([png bytes], [png length]);
  GdkTexture *texture = gdk_texture_new_from_bytes(bytes, NULL);
  g_bytes_unref(bytes);
  if (!texture) return NULL;
  GtkWidget *widget = gtk_image_new_from_paintable(GDK_PAINTABLE(texture));
  gtk_image_set_pixel_size(GTK_IMAGE(widget), 24);
  g_object_unref(texture);
  return widget;
}
static void hostActive(GObject *host, GParamSpec *spec, gpointer data)
{
  GTK4NativeWindowDecorationView *view = data;
  if (gtk_window_is_active(GTK_WINDOW(host)) && view->_child && !nativeToolbarHasFocus(view)) {
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

static void hostFocus(GObject *host, GParamSpec *spec, gpointer data)
{
  GTK4NativeWindowDecorationView *view = data;
  NSWindow *owner = [view window];
  if (!view->_child || !view->_parent || !gtk_widget_get_mapped(view->_host)
      || !nativeToolbarHasFocus(view)) return;
  if ([NSApp modalWindow] && [NSApp modalWindow] != owner && ![owner worksWhenModal]) return;
  [owner makeKeyWindow];
  Display *display = (Display *)[GSServerForWindow(owner) serverDevice];
  XSetInputFocus(display, view->_parent, RevertToParent, CurrentTime);
  XFlush(display);
}

static gboolean hostContentEvent(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer data)
{
  GTK4NativeWindowDecorationView *view = data;
  GdkEventType type = gdk_event_get_event_type(event);
  if (type == GDK_KEY_PRESS || type == GDK_KEY_RELEASE) return !nativeToolbarHasFocus(view);
  double x, y, dx, dy;
  if (!gdk_event_get_position(event, &x, &y)) return FALSE;
  gtk_native_get_surface_transform(GTK_NATIVE(view->_host), &dx, &dy);
  x -= dx; y -= dy;
  // The embedded AppKit client handles this area. Do not let GtkWindow's
  // gestures claim the same pointer sequence on the ancestor surface.
  graphene_rect_t bounds;
  if (!gtk_widget_compute_bounds(gtk_window_get_child(GTK_WINDOW(view->_host)), view->_host, &bounds)) return FALSE;
  for (GTK4NativeTable *peer in [view->_nativeTables allObjects]) {
    NSRect native = [peer hostRect];
    if (!NSIsEmptyRect(native) && NSPointInRect(NSMakePoint(x, y - bounds.origin.y), native)) return FALSE;
  }
  BOOL embedded = x >= 0 && x < gtk_widget_get_width(view->_host)
    && y >= bounds.origin.y && y < gtk_widget_get_height(view->_host);
  if (embedded && type == GDK_BUTTON_PRESS && view->_child) {
    gtk_root_set_focus(GTK_ROOT(view->_host), NULL);
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
    _nativeContent = gtk_fixed_new();
    _nativeTables = [[NSHashTable weakObjectsHashTable] retain];
    GtkWidget *contentOverlay = gtk_overlay_new();
    GtkWidget *background = gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
    gtk_widget_add_css_class(background,"view");
    gtk_overlay_set_child(GTK_OVERLAY(contentOverlay), background);
    gtk_overlay_add_overlay(GTK_OVERLAY(contentOverlay), _nativeContent);
    // Native peers follow AppKit's pane allocation without imposing the last
    // allocation as a new minimum size on the entire GTK window.
    gtk_overlay_set_measure_overlay(GTK_OVERLAY(contentOverlay), _nativeContent, FALSE);
    gtk_window_set_child(GTK_WINDOW(_host), contentOverlay);
    gtk_widget_add_css_class(_host, "gnustep-native-window");
    GtkEventController *contentEvents = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(contentEvents, GTK_PHASE_CAPTURE);
    g_signal_connect(contentEvents, "event", G_CALLBACK(hostContentEvent), self);
    gtk_widget_add_controller(_host, contentEvents);
    g_signal_connect(_host, "map", G_CALLBACK(GTK4NativeRoundWindowCorners), NULL);
    g_signal_connect(_host, "close-request", G_CALLBACK(hostClose), self);
    g_signal_connect(_host, "notify::is-active", G_CALLBACK(hostActive), self);
    g_signal_connect(_host, "notify::focus-widget", G_CALLBACK(hostFocus), self);
  }
  return self;
}
// Unsupported custom views retain the normal AppKit toolbar below the header.
- (BOOL)canHostToolbar
{
  if (!hasToolbar) return NO;
  for (NSToolbarItem *item in [[window toolbar] items])
    if ([item view] && ![[item view] isKindOfClass:[NSSearchField class]]
        && ![[item view] isKindOfClass:[NSButton class]]
        && ![[item view] isKindOfClass:[NSSegmentedControl class]]) return NO;
  return YES;
}
- (void)updateNativeToolbar
{
  if (!_host || _updatingToolbar) return;
  _updatingToolbar = YES;
  @try {
    NSToolbar *toolbar = [window toolbar];
    BOOL native = [self canHostToolbar];
    NSMutableArray *signature = [NSMutableArray arrayWithObjects:
      [NSNumber numberWithBool:native], [NSNumber numberWithInteger:[toolbar displayMode]],
      [NSNumber numberWithInteger:[toolbar sizeMode]],
      [NSNumber numberWithInt:gtk_widget_get_scale_factor(_host)], nil];
    if (native) for (NSToolbarItem *item in [toolbar items]) {
      [signature addObject:[NSArray arrayWithObjects:item, [item label] ?: @"",
        [item toolTip] ?: @"", [NSValue valueWithPointer:[item image]],
        [NSValue valueWithPointer:[item view]], nil]];
    }
    if (![_toolbarSignature isEqual:signature]) {
      BOOL previousNative = _nativeToolbar != NULL;
      BOOL hadSignature = _toolbarSignature != nil;
      [_toolbarSignature release]; _toolbarSignature = [signature copy];
      if (_nativeToolbar) {
        gtk_header_bar_remove(GTK_HEADER_BAR(_header), _nativeToolbar);
        gtk_header_bar_remove(GTK_HEADER_BAR(_header), _nativeToolbarSearch);
        _nativeToolbar = _nativeToolbarItems = _nativeToolbarSearch = _toolbarOverflow = NULL;
      }
      if (native) {
        _nativeToolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        gtk_widget_set_hexpand(_nativeToolbar, TRUE);
        gtk_widget_set_tooltip_text(_nativeToolbar, [[window title] UTF8String]);
        _nativeToolbarItems = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        _nativeToolbarSearch = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *scroller = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_EXTERNAL, GTK_POLICY_NEVER);
        gtk_widget_set_hexpand(scroller, TRUE);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), _nativeToolbarItems);
        gtk_box_append(GTK_BOX(_nativeToolbar), scroller);
        _toolbarOverflow = gtk_menu_button_new();
        gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(_toolbarOverflow), "view-more-symbolic");
        gtk_widget_set_tooltip_text(_toolbarOverflow, "More toolbar actions");
        GtkWidget *popover = gtk_popover_new();
        GtkWidget *overflowItems = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        gtk_popover_set_child(GTK_POPOVER(popover), overflowItems);
        gtk_menu_button_set_popover(GTK_MENU_BUTTON(_toolbarOverflow), popover);
        gtk_box_append(GTK_BOX(_nativeToolbar), _toolbarOverflow);
        for (NSToolbarItem *item in [toolbar items]) {
          NSString *identifier = [item itemIdentifier];
          GtkWidget *widget;
          if ([identifier isEqual:NSToolbarSpaceItemIdentifier] || [identifier isEqual:NSToolbarFlexibleSpaceItemIdentifier]) {
            widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_set_size_request(widget, 12, -1);
            gtk_widget_set_hexpand(widget, [identifier isEqual:NSToolbarFlexibleSpaceItemIdentifier]);
          } else if ([identifier isEqual:NSToolbarSeparatorItemIdentifier]
                     || [identifier isEqual:@"NSToolbarSidebarTrackingSeparatorItemIdentifier"]
                     || (![item view] && ![item image] && ![item action])) {
            widget = gtk_separator_new(GTK_ORIENTATION_VERTICAL);
          } else if ([[item view] isKindOfClass:[NSSegmentedControl class]]) {
            NSSegmentedControl *control = (id)[item view];
            widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_add_css_class(widget, "linked");
            for (NSInteger segment = 0; segment < [control segmentCount]; segment++) {
              GtkWidget *part = gtk_toggle_button_new();
              GtkWidget *image = [control imageForSegment:segment] ? toolbarImage([control imageForSegment:segment], gtk_widget_get_scale_factor(_host)) : NULL;
              if (image) gtk_button_set_child(GTK_BUTTON(part), image);
              else gtk_button_set_label(GTK_BUTTON(part), [[control labelForSegment:segment] UTF8String]);
              gtk_widget_set_tooltip_text(part, [[control labelForSegment:segment] UTF8String]);
              g_object_set_data(G_OBJECT(part), "appkit-segment", GINT_TO_POINTER(segment));
              g_signal_connect(part, "clicked", G_CALLBACK(toolbarSegmentClicked), item);
              gtk_box_append(GTK_BOX(widget), part);
            }
          } else if ([[item view] isKindOfClass:[NSSearchField class]]) {
            widget = gtk_search_entry_new();
            gtk_widget_set_size_request(widget, 120, -1);
            gtk_editable_set_text(GTK_EDITABLE(widget), [[(NSSearchField *)[item view] stringValue] UTF8String]);
            g_signal_connect(widget, "search-changed", G_CALLBACK(toolbarSearchChanged), item);
          } else {
            widget = gtk_button_new();
            gtk_widget_add_css_class(widget, "flat");
            GtkWidget *contents = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
            NSImage *image = [item image];
            if (!image && [[item view] isKindOfClass:[NSButton class]]) image = [(NSButton *)[item view] image];
            BOOL labelOnly = [toolbar displayMode] == NSToolbarDisplayModeLabelOnly;
            GtkWidget *icon = image && !labelOnly ? toolbarImage(image, gtk_widget_get_scale_factor(_host)) : NULL;
            if (icon && !labelOnly) gtk_box_append(GTK_BOX(contents), icon);
            if (!icon || labelOnly || [toolbar displayMode] == NSToolbarDisplayModeIconAndLabel)
              gtk_box_append(GTK_BOX(contents), gtk_label_new([[item label] UTF8String]));
            gtk_button_set_child(GTK_BUTTON(widget), contents);
            g_signal_connect(widget, "clicked", G_CALLBACK(toolbarClicked), item);
          }
          g_object_set_data_full(G_OBJECT(widget), "appkit-toolbar-item", [item retain], toolbarItemReleased);
          gtk_widget_set_tooltip_text(widget, [([item toolTip] ?: [item label]) UTF8String]);
          gtk_box_append(GTK_BOX(GTK_IS_SEARCH_ENTRY(widget) ? _nativeToolbarSearch : _nativeToolbarItems), widget);
          if (GTK_IS_BUTTON(widget)) {
            GtkWidget *overflowItem = gtk_button_new_with_label([[item label] UTF8String]);
            gtk_widget_add_css_class(overflowItem, "flat");
            g_object_set_data_full(G_OBJECT(overflowItem), "appkit-toolbar-item", [item retain], toolbarItemReleased);
            g_signal_connect(overflowItem, "clicked", G_CALLBACK(toolbarClicked), item);
            g_signal_connect_swapped(overflowItem, "clicked", G_CALLBACK(gtk_popover_popdown), popover);
            gtk_box_append(GTK_BOX(overflowItems), overflowItem);
          }
        }
        // Keep GTK's centered title widget; toolbar controls occupy its start side.
        gtk_header_bar_pack_start(GTK_HEADER_BAR(_header), _nativeToolbar);
        gtk_header_bar_pack_end(GTK_HEADER_BAR(_header), _nativeToolbarSearch);
      }
      CGFloat previous = _toolbarExtraHeight;
      int minimum, natural;
      gtk_widget_measure(_header, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, NULL, NULL);
      _toolbarExtraHeight = native ? MAX(0, natural - nativeTitleHeight()) : 0;
      CGFloat difference = _toolbarExtraHeight - previous;
      if (hadSignature && hasToolbar && previousNative != native)
        difference += (native ? -1 : 1) * [[toolbar _toolbarView] _heightFromLayout];
      if (difference) [self changeWindowHeight:difference];
      [self layout];
    }
    if (_nativeToolbar && g_get_monotonic_time() >= _toolbarValidationTime) {
      _toolbarValidationTime = g_get_monotonic_time() + 250000;
      for (NSToolbarItem *item in [toolbar items])
        if ([item autovalidates] && [item action]) [item validate];
    }
    if (_nativeToolbar) {
      int minimum, natural;
      gtk_widget_measure(_nativeToolbarItems, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, NULL, NULL);
      GtkWidget *scroller = gtk_widget_get_first_child(_nativeToolbar);
      int available = gtk_widget_get_width(scroller);
      if (gtk_widget_get_visible(_toolbarOverflow)) available += gtk_widget_get_width(_toolbarOverflow) + 6;
      gtk_widget_set_visible(_toolbarOverflow, natural > available && available > 0);
    }
    if (_toolbarOverflow) {
      GtkWidget *popover = GTK_WIDGET(gtk_menu_button_get_popover(GTK_MENU_BUTTON(_toolbarOverflow)));
      GtkWidget *box = gtk_popover_get_child(GTK_POPOVER(popover));
      for (GtkWidget *widget = gtk_widget_get_first_child(box); widget; widget = gtk_widget_get_next_sibling(widget)) {
        NSToolbarItem *item = g_object_get_data(G_OBJECT(widget), "appkit-toolbar-item");
        gtk_widget_set_sensitive(widget, [item isEnabled]);
      }
    }
    GtkWidget *itemBoxes[] = {_nativeToolbarItems, _nativeToolbarSearch};
    for (int box = 0; box < 2; box++) {
    if (itemBoxes[box]) for (GtkWidget *widget = gtk_widget_get_first_child(itemBoxes[box]); widget; widget = gtk_widget_get_next_sibling(widget)) {
      NSToolbarItem *item = g_object_get_data(G_OBJECT(widget), "appkit-toolbar-item");
      if ([item action] || [item view]) gtk_widget_set_sensitive(widget, [item isEnabled]);
      if ([[item view] isKindOfClass:[NSControl class]]) gtk_widget_set_sensitive(widget, [(NSControl *)[item view] isEnabled]);
      if ([[item view] isKindOfClass:[NSSegmentedControl class]]) {
        NSSegmentedControl *control = (id)[item view];
        NSInteger segment = 0;
        for (GtkWidget *part = gtk_widget_get_first_child(widget); part; part = gtk_widget_get_next_sibling(part), segment++) {
          gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(part), [control trackingMode] != NSSegmentSwitchTrackingMomentary && [control isSelectedForSegment:segment]);
          gtk_widget_set_sensitive(part, [control isEnabledForSegment:segment]);
        }
      }
      if (GTK_IS_SEARCH_ENTRY(widget) && !gtk_widget_has_focus(widget) && !nativeToolbarHasFocus(self)) {
        const char *text = [[(NSSearchField *)[item view] stringValue] UTF8String];
        if (strcmp(gtk_editable_get_text(GTK_EDITABLE(widget)), text ?: ""))
          gtk_editable_set_text(GTK_EDITABLE(widget), text ?: "");
      }
    }
    }
  } @finally { _updatingToolbar = NO; }
}
- (void)layout
{
  BOOL native = [self canHostToolbar];
  BOOL saved = hasToolbar;
  if (native) hasToolbar = NO;
  [super layout];
  hasToolbar = saved;
  if (native) {
    [[[window toolbar] _toolbarView] setHidden:YES];
    for (NSView *view in [self subviews])
      if (view == [window contentView]) {
        NSRect frame = [view frame]; frame.size.height = MAX(0, frame.size.height - _toolbarExtraHeight);
        [view setFrame:frame];
      } else if ([view isKindOfClass:[NSMenuView class]]) {
        NSPoint origin = [view frame].origin; origin.y -= _toolbarExtraHeight; [view setFrameOrigin:origin];
      }
  } else [[[window toolbar] _toolbarView] setHidden:NO];
}
- (NSRect)contentRectForFrameRect:(NSRect)rect styleMask:(NSUInteger)style
{
  NSRect result = [super contentRectForFrameRect:rect styleMask:style];
  if ([self canHostToolbar]) result.size.height += [[[window toolbar] _toolbarView] _heightFromLayout] - _toolbarExtraHeight;
  return result;
}
- (NSRect)frameRectForContentRect:(NSRect)rect styleMask:(NSUInteger)style
{
  if ([self canHostToolbar]) rect.size.height -= [[[window toolbar] _toolbarView] _heightFromLayout] - _toolbarExtraHeight;
  return [super frameRectForContentRect:rect styleMask:style];
}
- (void)addToolbarView:(GSToolbarView *)view
{
  if (!hasToolbar) {
    hasToolbar = YES;
    if ([self canHostToolbar]) {
      [_toolbarSignature release]; _toolbarSignature = nil;
      [self addSubview:view]; [view setHidden:YES];
      [self updateNativeToolbar]; [self layout];
      return;
    }
    hasToolbar = NO;
  }
  [super addToolbarView:view];
}
- (void)removeToolbarView:(GSToolbarView *)view
{
  if (_nativeToolbar) {
    hasToolbar = NO; [view removeFromSuperviewWithoutNeedingDisplay]; [view setHidden:NO];
    [self updateNativeToolbar]; [self layout];
  } else [super removeToolbarView:view];
}
- (void)adjustToolbarView:(GSToolbarView *)view
{
  if (_nativeToolbar) [self updateNativeToolbar];
  else [super adjustToolbarView:view];
}
- (NSUInteger)backendWindowStyleMask { return NSBorderlessWindowMask; }
- (void)setTitle:(NSString *)title
{
  [super setTitle:title];
  if (_host) {
    NSString *nativeTitle = documentEdited ? [title stringByAppendingString:@" •"] : title;
    gtk_window_set_title(GTK_WINDOW(_host), [nativeTitle UTF8String]);
    if (_nativeToolbar) gtk_widget_set_tooltip_text(_nativeToolbar, [nativeTitle UTF8String]);
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
    setApplicationIcon(display, _parent);
    copyApplicationProperty(display, _child, _parent, "WM_CLASS");
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
    // GTK applies its default icon while mapping. Replace it afterwards.
    setApplicationIcon((Display *)[GSServerForWindow(window) serverDevice], _parent);
    copyApplicationProperty((Display *)[GSServerForWindow(window) serverDevice], _child, _parent, "WM_CLASS");
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
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(_host));
    int scale = gdk_surface_get_scale_factor(surface);
    // Toolbar rebuilding also lays out AppKit views. Defer it until GDK and
    // AppKit agree on the scale, before importing any geometry or pane sizes.
    NSNumber *desktopScale = [[[NSUserDefaults standardUserDefaults]
      volatileDomainForName:@"GSThemeDomain"] objectForKey:@"GSScaleFactor"];
    if (desktopScale && fabs(scale - desktopScale.doubleValue) > 0.001) return;
    NSWindow *parentWindow = [window sheetParent] ?: [window parentWindow];
    if (!parentWindow && [NSApp modalWindow] == window && [NSApp mainWindow] != window) parentWindow = [NSApp mainWindow];
    GtkWindow *parent = GTK4NativeHostForWindow(parentWindow);
    if (gtk_window_get_transient_for(GTK_WINDOW(_host)) != parent)
      gtk_window_set_transient_for(GTK_WINDOW(_host), parent);
    BOOL modal = [NSApp modalWindow] == window || [window sheetParent] != nil;
    if (gtk_window_get_modal(GTK_WINDOW(_host)) != modal)
      gtk_window_set_modal(GTK_WINDOW(_host), modal);
    [self updateNativeToolbar];
    NSMutableArray *nativeRects = [NSMutableArray array];
    for (GTK4NativeTable *peer in [_nativeTables allObjects]) {
      if ([peer update] && !NSIsEmptyRect([peer hostRect]))
        [nativeRects addObject:[NSValue valueWithRect:[peer hostRect]]];
    }
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
        MAX(0, ceil(minSize.height / scale - nativeTitleHeight() - _toolbarExtraHeight)));
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
    BOOL geometryChanged = !NSEqualRects(geometry, _lastGeometry);
    BOOL sizeChanged = !NSEqualSizes(geometry.size, _lastGeometry.size);
    NSPoint offset = NSMakePoint(lround(dx*scale),lround(dy*scale));
    BOOL offsetChanged = !NSEqualPoints(offset,_childOffset);
    BOOL shapeChanged = sizeChanged || radius != _shapeRadius || top != _shapeTitleHeight
      || ![_nativeTableRects isEqual:nativeRects];
    if (sizeChanged || offsetChanged) {
      XMoveResizeWindow(display, _child, offset.x, offset.y, width, height);
      _childOffset = offset;
    }
    if (shapeChanged) {
      ASSIGNCOPY(_nativeTableRects, nativeRects);
      // Keep the child in the same coordinates as AppKit's complete window.
      // Its shape exposes GTK's real titlebar and the rounded GTK frame beneath.
      Region shape = XCreateRegion();
      for (int row = MAX(0, top); row < height - 1; row++) {
        int inset = 1;
        double bottom = height - 1 - row;
        if (radius > 0 && bottom < radius) {
          double d = radius - bottom;
          inset = MAX(1, (int)ceil(radius - sqrt(MAX(0, radius * radius - d * d))) + 1);
        }
        if (width > inset * 2) {
          XRectangle strip = {inset,row,width-2*inset,1};
          XUnionRectWithRegion(&strip,shape,shape);
        }
      }
      Region holes = XCreateRegion();
      for (NSValue *value in nativeRects) {
        NSRect rect = [value rectValue];
        XRectangle hole = {floor(NSMinX(rect) * scale), top + floor(NSMinY(rect) * scale),
          ceil(NSWidth(rect) * scale), ceil(NSHeight(rect) * scale)};
        XUnionRectWithRegion(&hole,holes,holes);
      }
      XSubtractRegion(shape,holes,shape);
      // Publish the finished region once. A temporary full-client shape would
      // cover the GTK peer and expose it again on every window movement.
      XShapeCombineRegion(display,_child,ShapeBounding,0,0,shape,ShapeSet);
      XShapeCombineRegion(display,_child,ShapeInput,0,0,shape,ShapeSet);
      XDestroyRegion(holes); XDestroyRegion(shape);
      _shapeRadius = radius;
      _shapeTitleHeight = top;
    }
    if (geometryChanged || offsetChanged) {
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
  for (GTK4NativeTable *peer in [_nativeTables allObjects]) [peer invalidate];
  [_nativeTables release]; [_nativeTableRects release];
  [_hostTimer invalidate];
  [_toolbarSignature release];
  if (_host) {
    gtk_window_destroy(GTK_WINDOW(_host));
    g_object_unref(_host);
  }
  [super dealloc];
}
@end
