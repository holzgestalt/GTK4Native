#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4Renderer.h"
#import "GTK4NativeMenu.h"

@interface GTK4NativeTheme : GSTheme
{
  GTK4Renderer _renderer;
  BOOL _available;
  NSColorList *_nativeColors;
}
@end

static cairo_status_t appendPNG(void *closure, const unsigned char *data, unsigned int size)
{
  [(NSMutableData *)closure appendBytes:data length:size];
  return CAIRO_STATUS_SUCCESS;
}

@implementation GTK4NativeTheme
- (id)initWithBundle:(NSBundle *)bundle
{
  self = [super initWithBundle:bundle];
  if (self) {
    // Match the actual AppKit backend, without changing standalone renderer
    // users or overriding an explicit GTK selection/already-open display.
    if ([GSCurrentServer() isKindOfClass:NSClassFromString(@"XGServer")]
        && !g_getenv("GDK_BACKEND") && !gdk_display_get_default())
      gdk_set_allowed_backends("x11,*");
    _available = gtk4_renderer_init(&_renderer);
    if (!_available) NSLog(@"GTK4Native: GTK could not connect to the display; using GNUstep drawing.");
  }
  return self;
}

- (void)dealloc
{
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
      "theme_base_color", "theme_selected_bg_color", "theme_base_color"};
    NSString *keys[] = {@"windowBackgroundColor", @"controlTextColor", @"textBackgroundColor",
      @"textColor", @"labelColor", @"selectedTextBackgroundColor",
      @"selectedTextColor", @"disabledControlTextColor", @"controlColor",
      @"controlBackgroundColor", @"selectedControlColor", @"_sourceListBackgroundColor"};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
      GdkRGBA color;
      if (gtk4_renderer_color(&_renderer, gtkNames[i], &color))
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
  CGFloat factor = [[view window] backingScaleFactor];
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

- (BOOL)handlesButtonStyle:(int)style
{
  return _available &&
    (style == NSRoundedBezelStyle || style == NSRegularSquareBezelStyle);
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
