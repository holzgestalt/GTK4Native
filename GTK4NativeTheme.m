#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSClassicTheme.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4Renderer.h"
#import "GTK4NativeMenu.h"
#import "GTK4NativeFilePanel.h"
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#import "GTK4NativeImages.h"

@interface GTK4NativeTheme : GSClassicTheme
{
  GTK4Renderer _renderer;
  BOOL _available;
  BOOL _backendInitializationPending;
  NSColorList *_nativeColors;
  NSTimer *_desktopTimer;
  CGFloat _desktopScale;
}
- (void)initializeNativeBackend;
@end

static cairo_status_t appendPNG(void *closure, const unsigned char *data, unsigned int size)
{
  [(NSMutableData *)closure appendBytes:data length:size];
  return CAIRO_STATUS_SUCCESS;
}

#if GTK_CHECK_VERSION(4, 10, 0)
typedef struct { BOOL finished; int choice; } GTK4AlertResult;
static void alertChosen(GObject *source, GAsyncResult *result, gpointer data)
{
  GTK4AlertResult *state = data;
  GError *error = NULL;
  int choice = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
  if (!error) state->choice = choice;
  g_clear_error(&error);
  state->finished = YES;
}
#endif

typedef struct { BOOL finished; NSInteger choice; } GTK4SaveResult;
static void saveResponse(GtkButton *button, gpointer data)
{
  GTK4SaveResult *state = data;
  state->choice = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "save-response"));
  state->finished = YES;
}
static gboolean cancelSave(GtkWindow *window, gpointer data)
{
  GTK4SaveResult *state = data;
  state->choice = NSAlertAlternateReturn;
  state->finished = YES;
  return TRUE;
}
static gboolean saveKey(GtkEventControllerKey *controller, guint key, guint code,
                        GdkModifierType modifiers, gpointer data)
{
  if (key != GDK_KEY_Escape) return FALSE;
  cancelSave(NULL, data);
  return TRUE;
}

/* GTK exposes the themed background as a public render node, but has no
 * public border-radius getter. Read only this window's background (no child
 * controls), then mirror its top radii onto the bottom corners. */
static const GskRoundedRect *saveBackgroundOutline(GskRenderNode *node)
{
  switch (gsk_render_node_get_node_type(node)) {
    case GSK_ROUNDED_CLIP_NODE: return gsk_rounded_clip_node_get_clip(node);
    case GSK_BORDER_NODE: return gsk_border_node_get_outline(node);
    case GSK_CONTAINER_NODE:
      for (guint i = 0; i < gsk_container_node_get_n_children(node); i++) {
        const GskRoundedRect *outline = saveBackgroundOutline(gsk_container_node_get_child(node, i));
        if (outline) return outline;
      }
      break;
    default: break;
  }
  return NULL;
}
double GTK4NativeWindowCornerRadius(GtkWidget *widget)
{
  GtkSnapshot *snapshot = gtk_snapshot_new();
  gtk_snapshot_render_background(snapshot, gtk_widget_get_style_context(widget), 0, 0, 1024, 1024);
  GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
  if (!node) return 0;
  const GskRoundedRect *outline = saveBackgroundOutline(node);
  double radius = outline ? outline->corner[GSK_CORNER_TOP_LEFT].width : 0;
  gsk_render_node_unref(node);
  return radius;
}
void GTK4NativeRoundWindowCorners(GtkWidget *window, gpointer unused)
{
  GtkSnapshot *snapshot = gtk_snapshot_new();
  GtkStyleContext *style = gtk_widget_get_style_context(window);
  gtk_snapshot_render_background(snapshot, style, 0, 0, 1024, 1024);
  GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
  if (!node) return;
  const GskRoundedRect *outline = saveBackgroundOutline(node);
  if (outline) {
    graphene_size_t left = outline->corner[GSK_CORNER_TOP_LEFT];
    graphene_size_t right = outline->corner[GSK_CORNER_TOP_RIGHT];
    char css[G_ASCII_DTOSTR_BUF_SIZE * 4 + 420];
    char lx[G_ASCII_DTOSTR_BUF_SIZE], ly[G_ASCII_DTOSTR_BUF_SIZE];
    char rx[G_ASCII_DTOSTR_BUF_SIZE], ry[G_ASCII_DTOSTR_BUF_SIZE];
    g_snprintf(css, sizeof(css),
      "window.document-save-dialog, window.gnustep-native-window { border-bottom-left-radius: %spx %spx; border-bottom-right-radius: %spx %spx; } window.gnustep-native-window.maximized, window.gnustep-native-window.fullscreen, window.gnustep-native-window.tiled { border-radius: 0; }",
      g_ascii_dtostr(lx, sizeof(lx), left.width), g_ascii_dtostr(ly, sizeof(ly), left.height),
      g_ascii_dtostr(rx, sizeof(rx), right.width), g_ascii_dtostr(ry, sizeof(ry), right.height));
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, css, -1);
    gtk_style_context_add_provider(style, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
  }
  gsk_render_node_unref(node);
}

@implementation GTK4NativeTheme
// GTK marks default actions with its native suggested-action style. The
// inherited GNUstep return-arrow bitmap is not part of the button content.
- (void)setKeyEquivalent:(NSString *)key forButtonCell:(NSButtonCell *)cell
{
  if ([cell image] == [NSImage imageNamed:@"common_ret"]
      || [cell image] == [NSImage imageNamed:@"common_retH"]) {
    [cell setImage:nil];
    if ([cell alternateImage] == [NSImage imageNamed:@"common_retH"]) [cell setAlternateImage:nil];
  }
}

- (id<GSWindowDecorator>)windowDecorator
{
  if (_available && GTK4NativeWindowsAvailable()) return (id)[GTK4NativeWindowDecorationView class];
  return [super windowDecorator];
}

- (BOOL)usesIndividualDocumentSaveAlerts { return _available; }
- (BOOL)runNativeDocumentSaveAlertWithTitle:(NSString *)title message:(NSString *)message
                                  buttons:(NSArray *)buttons result:(NSInteger *)result
{
  if (!_available || ![NSThread isMainThread] || [buttons count] != 3) return NO;
  GTK4SaveResult state = { NO, NSAlertAlternateReturn };
  GtkWidget *window = gtk_window_new();
  g_object_ref_sink(window);
  gtk_window_set_title(GTK_WINDOW(window), [title UTF8String]);
  gtk_window_set_modal(GTK_WINDOW(window), TRUE);
  GtkWindow *parent = GTK4NativeHostForWindow([NSApp keyWindow] ?: [NSApp mainWindow]);
  if (parent) gtk_window_set_transient_for(GTK_WINDOW(window), parent);
  gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
  // A custom titlebar requests GTK client-side decorations. Keep decorations
  // enabled so the theme owns the frame, shadow and corner treatment, while
  // hiding the empty titlebar preserves the compact confirmation layout.
  gtk_window_set_decorated(GTK_WINDOW(window), TRUE);
  GtkWidget *titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_window_set_titlebar(GTK_WINDOW(window), titlebar);
  gtk_widget_set_visible(titlebar, FALSE);
  gtk_widget_add_css_class(window, "document-save-dialog");
  g_signal_connect(window, "map", G_CALLBACK(GTK4NativeRoundWindowCorners), NULL);
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_margin_top(box, 32);
  gtk_widget_set_margin_bottom(box, 24);
  gtk_widget_set_margin_start(box, 24);
  gtk_widget_set_margin_end(box, 24);
  gtk_window_set_child(GTK_WINDOW(window), box);
  GtkWidget *heading = gtk_label_new([title UTF8String]);
  PangoAttrList *attrs = pango_attr_list_new();
  pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
  pango_attr_list_insert(attrs, pango_attr_scale_new(1.5));
  gtk_label_set_attributes(GTK_LABEL(heading), attrs);
  pango_attr_list_unref(attrs);
  gtk_label_set_wrap(GTK_LABEL(heading), TRUE);
  gtk_label_set_justify(GTK_LABEL(heading), GTK_JUSTIFY_CENTER);
  gtk_box_append(GTK_BOX(box), heading);
  GtkWidget *body = gtk_label_new([message UTF8String]);
  gtk_label_set_wrap(GTK_LABEL(body), TRUE);
  gtk_label_set_wrap_mode(GTK_LABEL(body), PANGO_WRAP_WORD_CHAR);
  gtk_label_set_max_width_chars(GTK_LABEL(body), 48);
  gtk_label_set_justify(GTK_LABEL(body), GTK_JUSTIFY_CENTER);
  gtk_box_append(GTK_BOX(box), body);
  GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_box_set_homogeneous(GTK_BOX(row), TRUE);
  gtk_widget_set_margin_top(row, 12);
  gtk_box_append(GTK_BOX(box), row);
  // GNOME order: Cancel, Discard, Save. Return codes retain AppKit semantics.
  int indices[] = {1, 2, 0};
  int codes[] = {NSAlertAlternateReturn, NSAlertOtherReturn, NSAlertDefaultReturn};
  GtkWidget *save = NULL, *cancel = NULL;
  for (int i = 0; i < 3; i++) {
    GtkWidget *button = gtk_button_new_with_label([[buttons objectAtIndex:indices[i]] UTF8String]);
    gtk_widget_set_size_request(button, 120, 48);
    gtk_widget_set_hexpand(button, TRUE);
    if (i == 1) gtk_widget_add_css_class(button, "destructive-action");
    if (i == 2) { gtk_widget_add_css_class(button, "suggested-action"); save = button; }
    if (i == 0) cancel = button;
    g_object_set_data(G_OBJECT(button), "save-response", GINT_TO_POINTER(codes[i]));
    g_signal_connect(button, "clicked", G_CALLBACK(saveResponse), &state);
    gtk_box_append(GTK_BOX(row), button);
  }
  gtk_window_set_default_widget(GTK_WINDOW(window), save);
  gtk_window_set_focus(GTK_WINDOW(window), cancel);
  g_signal_connect(window, "close-request", G_CALLBACK(cancelSave), &state);
  GtkEventController *keys = gtk_event_controller_key_new();
  g_signal_connect(keys, "key-pressed", G_CALLBACK(saveKey), &state);
  gtk_widget_add_controller(window, keys);
  gtk_window_present(GTK_WINDOW(window));
  while (!state.finished) {
    for (int i = 0; i < 64 && g_main_context_pending(NULL); i++)
      g_main_context_iteration(NULL, FALSE);
    [[NSRunLoop currentRunLoop] runMode:NSModalPanelRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  *result = state.choice;
  gtk_window_destroy(GTK_WINDOW(window));
  g_object_unref(window);
  return YES;
}

- (BOOL)runNativeAlertWithTitle:(NSString *)title message:(NSString *)message
                      buttons:(NSArray *)buttons defaultButton:(NSInteger)defaultButton
                 cancelButton:(NSInteger)cancelButton result:(NSInteger *)result
{
#if GTK_CHECK_VERSION(4, 10, 0)
  if (!_available || ![NSThread isMainThread] || ![buttons count]) return NO;
  GtkAlertDialog *dialog = gtk_alert_dialog_new("%s", [(title ?: @"") UTF8String]);
  gtk_alert_dialog_set_detail(dialog, [(message ?: @"") UTF8String]);
  const char **labels = g_new0(const char *, [buttons count] + 1);
  for (NSUInteger i = 0; i < [buttons count]; i++)
    labels[i] = [[buttons objectAtIndex:i] UTF8String];
  gtk_alert_dialog_set_buttons(dialog, labels);
  g_free(labels);
  gtk_alert_dialog_set_default_button(dialog, (int)defaultButton);
  gtk_alert_dialog_set_cancel_button(dialog, (int)cancelButton);
  gtk_alert_dialog_set_modal(dialog, TRUE);
  GTK4AlertResult state = { NO, (int)cancelButton };
  gtk_alert_dialog_choose(dialog, GTK4NativeHostForWindow([NSApp keyWindow] ?: [NSApp mainWindow]), NULL, alertChosen, &state);
  while (!state.finished) {
    for (int i = 0; i < 64 && g_main_context_pending(NULL); i++)
      g_main_context_iteration(NULL, FALSE);
    [[NSRunLoop currentRunLoop] runMode:NSModalPanelRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  *result = state.choice;
  g_object_unref(dialog);
  return YES;
#else
  return NO;
#endif
}

- (NSString *)name { return @"GTK4Native"; }
- (NSDictionary *)infoDictionary
{
  NSMutableDictionary *domain=[NSMutableDictionary dictionaryWithDictionary:@{
    @"NSInterfaceStyleDefault": @"NSWindows95InterfaceStyle",
    @"NSMenuInterfaceStyle": @"NSWindows95InterfaceStyle",
    @"GSSuppressAppIcon": @YES,
    @"GSBackHandlesWindowDecorations": @YES,
    @"GSScrollViewNoInnerBorder": @YES }];
  // AppKit's X11 backend reports 72 DPI unconditionally. Use GDK's desktop
  // scale as a theme default before AppKit lays out windows and loads fonts.
  // Explicit GSScaleFactor values in argument/app/global domains still win.
  if (_available && [GSCurrentServer() isKindOfClass:NSClassFromString(@"XGServer")]) {
    GListModel *monitors=gdk_display_get_monitors(gdk_display_get_default());
    GdkMonitor *monitor=g_list_model_get_item(monitors,0);
    if (monitor) {
      [domain setObject:@(MAX(1,gdk_monitor_get_scale_factor(monitor))) forKey:@"GSScaleFactor"];
      g_object_unref(monitor);
    }
  }
  return @{ @"GSThemeDomain": domain };
}
- (Class)openPanelClass { return _available ? [GTK4NativeOpenPanel class] : [super openPanelClass]; }
- (Class)savePanelClass { return _available ? [GTK4NativeSavePanel class] : [super savePanelClass]; }
- (id)initWithBundle:(NSBundle *)bundle
{
  self = [super initWithBundle:bundle];
  if (self) {
    _backendInitializationPending = YES;
    if (GSCurrentServer()) [self initializeNativeBackend];
  }
  return self;
}
- (void)initializeNativeBackend
{
  if (!_backendInitializationPending || !GSCurrentServer()) return;
  _backendInitializationPending = NO;
  // Select GTK's backend only once AppKit's selected backend is known.
  // An explicitly requested GTK backend still wins.
  if ([GSCurrentServer() isKindOfClass:NSClassFromString(@"XGServer")]
      && !g_getenv("GDK_BACKEND") && !gdk_display_get_default())
    gdk_set_allowed_backends("x11,*");
  _available = gtk4_renderer_init(&_renderer);
  if (!_available) NSLog(@"GTK4Native: GTK could not connect to the display; using GNUstep drawing.");
}
- (void)displayServerDidConnect
{
  if (_backendInitializationPending) {
    [self initializeNativeBackend];
    // Publish native defaults, including desktop scale, before AppKit creates
    // its first graphics context and loads fonts.
    [self activate];
  }
}

- (void)activate
{
  [super activate];
  if(_available) GTK4NativeInstallTemplateImages();
  _desktopScale=GSCurrentServer() ? [[NSScreen mainScreen] userSpaceScaleFactor] : 0;
  if (_available && !_desktopTimer) {
    _desktopTimer=[NSTimer timerWithTimeInterval:0.25 target:self
      selector:@selector(synchronizeDesktopScale:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_desktopTimer forMode:NSRunLoopCommonModes];
  }
}
- (void)synchronizeDesktopScale:(id)sender
{
  if (!GSCurrentServer()) return;
  // GDK must receive XSettings/monitor events even while AppKit owns the loop.
  for (int i=0;i<64 && g_main_context_pending(NULL);i++)
    g_main_context_iteration(NULL,FALSE);
  NSUserDefaults *defs=[NSUserDefaults standardUserDefaults];
  NSMutableDictionary *domain=[[[defs volatileDomainForName:@"GSThemeDomain"] mutableCopy] autorelease];
  NSNumber *factor=[[[self infoDictionary] objectForKey:@"GSThemeDomain"] objectForKey:@"GSScaleFactor"];
  if (!factor || !domain) return;
  if ([[domain objectForKey:@"GSScaleFactor"] isEqual:factor]) return;
  CGFloat oldScale=_desktopScale;
  [domain setObject:factor forKey:@"GSScaleFactor"];
  [defs removeVolatileDomainForName:@"GSThemeDomain"];
  [defs setVolatileDomain:domain forName:@"GSThemeDomain"];
  CGFloat newScale=[[NSScreen mainScreen] userSpaceScaleFactor];
  if (fabs(newScale-oldScale)<0.001) return;
  _desktopScale=newScale;
  for (NSWindow *window in [NSApp windows]) {
    if ([window styleMask] & NSUnscaledWindowMask) continue;
    NSView *content=[window contentView];
    NSSize logicalSize=[content bounds].size;
    NSView *root=[content superview];
    BOOL autoresizes=[root autoresizesSubviews];
    [root setAutoresizesSubviews:NO];
    @try {
      [window setContentSize:logicalSize];
      [root setNeedsDisplay:YES];
      [content setNeedsLayout:YES];
      [content layoutSubtreeIfNeeded];
      [window invalidateCursorRectsForView:content];
    } @finally { [root setAutoresizesSubviews:autoresizes]; }
  }
}
- (void)dealloc
{
  [_desktopTimer invalidate];
  [_nativeColors release];
  gtk4_renderer_clear(&_renderer);
  [super dealloc];
}

- (NSColorList *)colors
{
  if (!_available) return [super colors];
  if (!_nativeColors) {
    NSColorList *base = [super colors];
    if (!base) base = [NSColorList colorListNamed:@"System"];
    _nativeColors = [[NSColorList alloc] initWithName:@"System"];
    for (NSString *key in [base allKeys])
      [_nativeColors setColor:[base colorWithKey:key] forKey:key];
    // Missing symbolic colors retain GNUstep defaults; no palette is invented.
    const char *gtkNames[] = {"theme_bg_color", "theme_fg_color", "theme_base_color",
      "theme_text_color", "theme_fg_color", "theme_selected_bg_color",
      "theme_selected_fg_color", "insensitive_fg_color", "theme_bg_color",
      "theme_base_color", "theme_selected_bg_color", "theme_base_color",
      "accent_bg_color", "borders"};
    NSString *keys[] = {@"windowBackgroundColor", @"controlTextColor", @"textBackgroundColor",
      @"textColor", @"labelColor", @"selectedTextBackgroundColor",
      @"selectedTextColor", @"disabledControlTextColor", @"controlColor",
      @"controlBackgroundColor", @"selectedControlColor", @"_sourceListBackgroundColor",
      @"controlAccentColor", @"separatorColor"};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
      GdkRGBA color;
      BOOL found = gtk4_renderer_color(&_renderer, gtkNames[i], &color);
      if (!found && [keys[i] isEqualToString:@"controlAccentColor"])
        found = gtk4_renderer_color(&_renderer, "theme_selected_bg_color", &color);
      if (found)
        [_nativeColors setColor:[NSColor colorWithCalibratedRed:color.red
          green:color.green blue:color.blue alpha:color.alpha] forKey:keys[i]];
    }
  }
  return _nativeColors;
}

- (BOOL)paintWidget:(GtkWidget *)widget state:(GtkStateFlags)state
             frame:(NSRect)frame view:(NSView *)view
{
  if (!_available || NSIsEmptyRect(frame)) return NO;
  // GNUstep scales its window view transform using userSpaceScaleFactor;
  // backingScaleFactor alone is currently always 1 on this backend.
  CGFloat factor = MAX([[view window] userSpaceScaleFactor],
                       [[view window] backingScaleFactor]);
  int scale = MAX(1, (int)ceil(factor));
  cairo_surface_t *surface = gtk4_renderer_draw(widget, state,
    (int)ceil(frame.size.width), (int)ceil(frame.size.height), scale);
  if (!surface) return NO;
  NSMutableData *data = [NSMutableData data];
  cairo_status_t status = cairo_surface_write_to_png_stream(surface, appendPNG, data);
  cairo_surface_destroy(surface);
  if (status != CAIRO_STATUS_SUCCESS) return NO;
  NSImage *image = [[NSImage alloc] initWithData:data];
  if (!image) return NO;
  [image setSize:frame.size];
  [image drawInRect:frame fromRect:NSZeroRect operation:NSCompositeSourceOver
          fraction:1.0 respectFlipped:YES hints:nil];
  [image release];
  return YES;
}

- (float)defaultScrollerWidth
{
  if (!_available) return [super defaultScrollerWidth];
  int width = gtk4_renderer_scrollbar_width(&_renderer);
  return width > 0 ? width : [super defaultScrollerWidth];
}

- (NSSize)scrollViewBorderSizeForType:(NSBorderType)type
{
  if(!_available) return [super scrollViewBorderSizeForType:type];
  if(type==NSNoBorder) return NSZeroSize;
  GtkBorder border;
  gtk_style_context_get_border(gtk_widget_get_style_context(_renderer.scroll_frame),&border);
  CGFloat sourceScale=[[NSScreen mainScreen] userSpaceScaleFactor];
  CGFloat metricScale=gtk_widget_get_scale_factor(_renderer.window)/MAX(.001,sourceScale);
  return NSMakeSize(MAX(border.left,border.right)*metricScale,MAX(border.top,border.bottom)*metricScale);
}
- (BOOL)scrollViewUsesNativeScrollers:(NSScrollView *)view
{
  // This also applies before GTK connects or a source view gains its peer.
  return YES;
}
- (void)drawScrollViewRect:(NSRect)rect inView:(NSView *)view
{
  // A live GtkScrolledWindow owns the complete frame, background and bars.
  if (!_available) [super drawScrollViewRect:rect inView:view];
}
- (CGFloat)splitViewDividerThickness:(NSSplitView *)view
{
  if(!_available) return [super splitViewDividerThickness:view];
  GtkWidget *separator=_renderer.split_separator[view.isVertical?0:1];
  if(!separator) return 0;
  int minimum=0,natural=0;
  gtk_widget_measure(separator,view.isVertical?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,
    -1,&minimum,&natural,NULL,NULL);
  GtkWindow *host=GTK4NativeHostForWindow(view.window);
  CGFloat nativeScale=gtk_widget_get_scale_factor(host?GTK_WIDGET(host):_renderer.window);
  CGFloat sourceScale=view.window?view.window.userSpaceScaleFactor:[[NSScreen mainScreen] userSpaceScaleFactor];
  return MAX(minimum,natural)*nativeScale/MAX(.001,sourceScale);
}
- (BOOL)drawSplitViewDividerInRect:(NSRect)rect inView:(NSSplitView *)view
{
  // GtkPaned owns separator painting and input; never draw it into AppKit.
  return _available;
}

- (BOOL)prepareScroller:(NSScroller *)scroller geometry:(GTK4ScrollbarGeometry *)geometry
{
  if (!_available) return NO;
  NSRect bounds = [scroller bounds];
  return gtk4_renderer_scrollbar_prepare(&_renderer, NSWidth(bounds) > NSHeight(bounds),
    [scroller doubleValue], [scroller knobProportion], [scroller isEnabled],
    [scroller hitPart] == NSScrollerKnob, ceil(NSWidth(bounds)), ceil(NSHeight(bounds)), geometry);
}

- (BOOL)getScrollerRect:(NSRect *)rect forPart:(NSScrollerPart)part
            inScroller:(NSScroller *)scroller
{
  GTK4ScrollbarGeometry geometry;
  if (![self prepareScroller:scroller geometry:&geometry]) return NO;
  graphene_rect_t r;
  switch (part) {
    case NSScrollerKnob: r = geometry.thumb; break;
    case NSScrollerKnobSlot: r = geometry.trough; break;
    // GTK4 has no stepper arrows. Trough clicks use NSScroller's slot path,
    // which consults scrollerScrollsByPageForScroller: before scrolling.
    default: *rect = NSZeroRect; return YES;
  }
  NSRect bounds = [scroller bounds];
  *rect = NSMakeRect(NSMinX(bounds) + r.origin.x, NSMinY(bounds) + r.origin.y,
                     r.size.width, r.size.height);
  return YES;
}

- (BOOL)drawNativeScroller:(NSScroller *)scroller dirtyRect:(NSRect)rect
{
  // GtkScrolledWindow owns its live scrollbars; AppKit contributes no pixels.
  return _available;
}

- (id<GSNativeTableView>)nativeTableViewForTableView:(NSTableView *)table
{
  return _available ? [GTK4NativeTable peerForTable:table] : nil;
}

- (BOOL)scrollerScrollsByPageForScroller:(NSScroller *)scroller
{
  if (!_available || [[NSUserDefaults standardUserDefaults]
                       objectForKey:@"GSScrollerScrollsByPage"])
    return [super scrollerScrollsByPageForScroller:scroller];
  gboolean warps = FALSE;
  g_object_get(gtk_settings_get_default(), "gtk-primary-button-warps-slider", &warps, NULL);
  return !warps;
}

- (BOOL)handlesButtonStyle:(int)style
{
  if (!_available) return NO;
  switch (style) {
    case NSRoundedBezelStyle:
    case NSRegularSquareBezelStyle:
    case NSThickSquareBezelStyle:
    case NSThickerSquareBezelStyle:
    case NSShadowlessSquareBezelStyle:
    case NSTexturedSquareBezelStyle:
    case NSSmallSquareBezelStyle:
    case NSTexturedRoundedBezelStyle:
    case NSRoundRectBezelStyle:
    case NSRecessedBezelStyle:
    case NSNeXTBezelStyle:
    case NSPushButtonBezelStyle:
      return YES;
    default: return NO;
  }
}

- (void)drawButton:(NSRect)frame in:(NSCell *)cell view:(NSView *)view
             style:(int)style state:(GSThemeControlState)state
{
  // Leave image-only, borderless and specialized bezel types to AppKit.
  if (![self handlesButtonStyle:style]) {
    [super drawButton:frame in:cell view:view style:style state:state];
    return;
  }
  GtkStateFlags flags = GTK_STATE_FLAG_NORMAL;
  if (![cell isEnabled]) flags |= GTK_STATE_FLAG_INSENSITIVE;
  if ([cell isHighlighted]) flags |= GTK_STATE_FLAG_ACTIVE;
  if (state == GSThemeFirstResponderState ||
      state == GSThemeHighlightedFirstResponderState ||
      state == GSThemeSelectedFirstResponderState)
    flags |= GTK_STATE_FLAG_FOCUSED | GTK_STATE_FLAG_FOCUS_VISIBLE;
  if (![self paintWidget:_renderer.button state:flags frame:frame view:view])
    [super drawButton:frame in:cell view:view style:style state:state];
}

- (NSSize)buttonPushInOffsetForCell:(NSCell *)cell
{
  return _available ? NSZeroSize : [super buttonPushInOffsetForCell:cell];
}

- (BOOL)handlesTextFieldCell:(NSTextFieldCell *)cell
{
  return _available && [cell isBezeled] && [cell drawsBackground] &&
    [[cell backgroundColor] isEqual:[NSColor textBackgroundColor]];
}

- (NSRect)textFieldContentRectForCell:(NSTextFieldCell *)cell frame:(NSRect)frame
{
  if (![self handlesTextFieldCell:cell]) return NSZeroRect;
  GtkBorder insets;
  gtk4_renderer_entry_insets(&_renderer, &insets);
  NSRect content = NSMakeRect(frame.origin.x + insets.left,
    frame.origin.y + insets.bottom,
    MAX(0, frame.size.width - insets.left - insets.right),
    MAX(0, frame.size.height - insets.top - insets.bottom));
  CGFloat lineHeight = ceil([[cell font] defaultLineHeightForFont]);
  if (content.size.height > lineHeight) {
    content.origin.y += floor((content.size.height - lineHeight) / 2);
    content.size.height = lineHeight;
  }
  return content;
}

- (void)drawFocusFrame:(NSRect)frame view:(NSView *)view
{
  // GTK has already rendered the focus treatment with the control background.
  if ([view isKindOfClass:[NSTextField class]] &&
      [self handlesTextFieldCell:[(NSTextField *)view cell]]) return;
  if ([view isKindOfClass:[NSButton class]]) {
    NSButton *button = (NSButton *)view;
    if ([button isBordered] && [self handlesButtonStyle:[[button cell] bezelStyle]])
      return;
  }
  [super drawFocusFrame:frame view:view];
}

- (BOOL)drawTextFieldCell:(NSTextFieldCell *)cell frame:(NSRect)frame view:(NSView *)view
{
  // Labels and explicitly custom-colored fields retain their AppKit drawing.
  if (![self handlesTextFieldCell:cell]) return NO;
  GtkStateFlags flags = [cell isEnabled] ? GTK_STATE_FLAG_NORMAL : GTK_STATE_FLAG_INSENSITIVE;
  NSResponder *responder = [[view window] firstResponder];
  if (responder == view ||
      ([responder isKindOfClass:[NSText class]] && [(NSText *)responder delegate] == view))
    flags |= GTK_STATE_FLAG_FOCUSED | GTK_STATE_FLAG_FOCUS_WITHIN | GTK_STATE_FLAG_FOCUS_VISIBLE;
  return [self paintWidget:_renderer.entry state:flags frame:frame view:view];
}

- (GtkStateFlags)menuFlagsForCell:(NSMenuItemCell *)cell state:(GSThemeControlState)state
{
  if (![cell isEnabled]) return GTK_STATE_FLAG_INSENSITIVE;
  if (state == GSThemeHighlightedState || state == GSThemeSelectedState ||
      state == GSThemeHighlightedFirstResponderState || state == GSThemeSelectedFirstResponderState)
    return GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_SELECTED;
  return GTK_STATE_FLAG_NORMAL;
}

- (CGFloat)menuBarHeight
{
  return _available ? gtk4_renderer_natural_height(_renderer.menubar) : [super menuBarHeight];
}
- (CGFloat)menuItemHeight
{
  return _available ? gtk4_renderer_natural_height(_renderer.menu_item) : [super menuItemHeight];
}
- (CGFloat)menuSeparatorHeight
{
  return _available ? gtk4_renderer_natural_height(_renderer.menu_separator) : [super menuSeparatorHeight];
}
- (BOOL)drawsBorderForMenuItemCell:(NSMenuItemCell *)cell state:(GSThemeControlState)state
                   isHorizontal:(BOOL)horizontal
{
  return _available ? NO : [super drawsBorderForMenuItemCell:cell state:state isHorizontal:horizontal];
}
- (void)drawBackgroundForMenuView:(NSMenuView *)view withFrame:(NSRect)bounds
                       dirtyRect:(NSRect)dirty horizontal:(BOOL)horizontal
{
  if (_available) {
    gtk_widget_set_state_flags(_renderer.menubar_item, GTK_STATE_FLAG_NORMAL, TRUE);
    gtk_widget_set_state_flags(_renderer.menu_item, GTK_STATE_FLAG_NORMAL, TRUE);
    if ([self paintWidget:horizontal ? _renderer.menubar : _renderer.menu
                   state:GTK_STATE_FLAG_NORMAL frame:bounds view:view]) return;
  }
  [super drawBackgroundForMenuView:view withFrame:bounds dirtyRect:dirty horizontal:horizontal];
}
- (void)drawBorderAndBackgroundForMenuItemCell:(NSMenuItemCell *)cell withFrame:(NSRect)frame
                                      inView:(NSView *)view state:(GSThemeControlState)state
                                isHorizontal:(BOOL)horizontal
{
  if (!_available) {
    [super drawBorderAndBackgroundForMenuItemCell:cell withFrame:frame inView:view
                                          state:state isHorizontal:horizontal];
    return;
  }
  GtkStateFlags flags = [self menuFlagsForCell:cell state:state];
  // The normal menu surface is already drawn by the parent. Native rows may
  // legitimately have no render node when transparent; never add a stock bevel.
  if (!(flags & GTK_STATE_FLAG_PRELIGHT)) return;
  [self paintWidget:horizontal ? _renderer.menubar_item : _renderer.menu_item
              state:flags frame:frame view:view];
}
- (void)drawSeparatorItemForMenuItemCell:(NSMenuItemCell *)cell withFrame:(NSRect)frame
                                inView:(NSView *)view isHorizontal:(BOOL)horizontal
{
  if (!_available || ![self paintWidget:_renderer.menu_separator state:GTK_STATE_FLAG_NORMAL
                                  frame:frame view:view])
    [super drawSeparatorItemForMenuItemCell:cell withFrame:frame inView:view isHorizontal:horizontal];
}
- (NSColor *)colorNamed:(NSString *)name state:(GSThemeControlState)state
{
  if (_available && [name isEqualToString:@"NSMenuItemText"]) {
    GdkRGBA color;
    GtkStateFlags flags = state == GSThemeDisabledState ? GTK_STATE_FLAG_INSENSITIVE :
      ((state == GSThemeHighlightedState || state == GSThemeSelectedState) ?
        GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_SELECTED : GTK_STATE_FLAG_NORMAL);
    if (gtk4_renderer_foreground(_renderer.menu_item, flags, &color))
      return [NSColor colorWithCalibratedRed:color.red green:color.green blue:color.blue alpha:color.alpha];
  }
  return [super colorNamed:name state:state];
}
- (BOOL)trackMenuView:(NSMenuView *)view withEvent:(NSEvent *)event
{
  return _available && GTK4TrackNativeMenu(view, event);
}
- (void)rightMouseDisplay:(NSMenu *)menu forEvent:(NSEvent *)event
{
  NSPoint point = [[event window] convertBaseToScreen:[event locationInWindow]];
  if (!_available || !GTK4ShowNativeMenu(menu, NSMakeRect(point.x, point.y, 1, 1), [event window]))
    [super rightMouseDisplay:menu forEvent:event];
}
- (BOOL)displayNativePopUpMenu:(NSMenu *)menu atScreenRect:(NSRect)rect forWindow:(NSWindow *)window
{
  return _available && GTK4ShowNativeMenu(menu, rect, window);
}
@end

Class GSThemeProvider_GTK4Native(void)
{
  return [GTK4NativeTheme class];
}
