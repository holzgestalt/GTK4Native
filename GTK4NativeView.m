#import "GTK4NativeView.h"
#include <objc/runtime.h>
#import "../../src/libs-gui/Source/GSAutoLayoutEngine.h"

/* Native children keep GTK rendering, input and accessibility. Each container
   has its own GNUstep solver, with native intrinsic sizes and font baselines. */
@interface GTK4LayoutProxy : NSView
{
@public
  GtkWidget *native;
}
@end
@implementation GTK4LayoutProxy
- (BOOL)isFlipped { return YES; }
- (NSSize)intrinsicContentSize
{
  if (!native) return NSMakeSize(NSViewNoIntrinsicMetric,NSViewNoIntrinsicMetric);
  int width=0,height=0;
  gtk_widget_measure(native,GTK_ORIENTATION_HORIZONTAL,-1,NULL,&width,NULL,NULL);
  gtk_widget_measure(native,GTK_ORIENTATION_VERTICAL,-1,NULL,&height,NULL,NULL);
  return NSMakeSize(width,height);
}
- (CGFloat)firstBaselineOffsetFromTop
{
  int baseline=-1;
  if (native) gtk_widget_measure(native,GTK_ORIENTATION_VERTICAL,-1,NULL,NULL,NULL,&baseline);
  return MAX(0,baseline);
}
- (CGFloat)baselineOffsetFromBottom
{ return [self intrinsicContentSize].height - [self firstBaselineOffsetFromTop]; }
@end
@interface GTK4Layout : NSObject
{
@public
  GTK4LayoutProxy *root;
  GSAutoLayoutEngine *engine;
  NSArray *sizeConstraints;
}
@end
@implementation GTK4Layout
- (void)dealloc { [engine release]; [root release]; [sizeConstraints release]; [super dealloc]; }
@end
static void releaseLayout(gpointer data) { [(id)data release]; }
typedef struct { GtkLayoutManager parent; } GSNativeLayout;
typedef struct { GtkLayoutManagerClass parent; } GSNativeLayoutClass;
G_DEFINE_TYPE(GSNativeLayout, gs_native_layout, GTK_TYPE_LAYOUT_MANAGER)
static void nativeMeasure(GtkLayoutManager *manager, GtkWidget *widget, GtkOrientation orientation,
  int forSize,int *minimum,int *natural,int *minBaseline,int *natBaseline)
{
  // The enclosing list supplies row heights. Content must not enlarge the
  // row after a lightweight prefetched placeholder becomes visible.
  *minimum = *natural = 0;
  if (minBaseline) *minBaseline = -1;
  if (natBaseline) *natBaseline = -1;
}
static void nativeAllocate(GtkLayoutManager *manager,GtkWidget *widget,int width,int height,int baseline)
{
  GTK4Layout *layout = g_object_get_data(G_OBJECT(widget),"appkit-layout");
  if (!layout) return;
  [layout->engine beginUpdates];
  if (!NSEqualSizes(layout->root.frame.size,NSMakeSize(width,height))) {
    [layout->engine removeConstraints:layout->sizeConstraints];
    [layout->root setFrameSize:NSMakeSize(width,height)];
    for (NSLayoutConstraint *c in layout->sizeConstraints)
      [c setConstant:[c firstAttribute] == NSLayoutAttributeWidth ? width : height];
    [layout->engine addConstraints:layout->sizeConstraints];
  }
  [layout->engine prepareForLayout];
  [layout->engine endUpdates];
  for (GTK4LayoutProxy *proxy in layout->root.subviews) {
    if (!gtk_widget_should_layout(proxy->native)) continue;
    NSRect rect = [layout->engine alignmentRectForView:proxy];
    GtkAllocation allocation = {lround(rect.origin.x),lround(rect.origin.y),
      MAX(0,lround(rect.size.width)),MAX(0,lround(rect.size.height))};
    gtk_widget_size_allocate(proxy->native,&allocation,-1);
  }
}
static void gs_native_layout_class_init(GSNativeLayoutClass *cls)
{
  GTK_LAYOUT_MANAGER_CLASS(cls)->measure = nativeMeasure;
  GTK_LAYOUT_MANAGER_CLASS(cls)->allocate = nativeAllocate;
}
static void gs_native_layout_init(GSNativeLayout *layout) {}
typedef struct { GtkWidget parent; } GSNativeContainer;
typedef struct { GtkWidgetClass parent; } GSNativeContainerClass;
G_DEFINE_TYPE(GSNativeContainer, gs_native_container, GTK_TYPE_WIDGET)
static void containerDispose(GObject *object)
{
  gtk_widget_set_layout_manager(GTK_WIDGET(object),NULL);
  g_object_set_data(G_OBJECT(object),"appkit-layout",NULL);
  GtkWidget *child;
  while ((child=gtk_widget_get_first_child(GTK_WIDGET(object)))) gtk_widget_unparent(child);
  G_OBJECT_CLASS(gs_native_container_parent_class)->dispose(object);
}
static void containerSnapshot(GtkWidget *widget,GtkSnapshot *snapshot)
{
  for (GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child))
    if (gtk_widget_get_visible(child)) gtk_widget_snapshot_child(widget,child,snapshot);
}
static void gs_native_container_class_init(GSNativeContainerClass *cls)
{
  G_OBJECT_CLASS(cls)->dispose=containerDispose;
  GTK_WIDGET_CLASS(cls)->snapshot=containerSnapshot;
}
static void gs_native_container_init(GSNativeContainer *container)
{ gtk_widget_set_layout_manager(GTK_WIDGET(container),g_object_new(gs_native_layout_get_type(),NULL)); }

static GtkConstraintAttribute attribute(NSLayoutAttribute attr)
{
  switch (attr) {
    case NSLayoutAttributeLeft: return GTK_CONSTRAINT_ATTRIBUTE_LEFT;
    case NSLayoutAttributeRight: return GTK_CONSTRAINT_ATTRIBUTE_RIGHT;
    case NSLayoutAttributeLeading: return GTK_CONSTRAINT_ATTRIBUTE_START;
    case NSLayoutAttributeTrailing: return GTK_CONSTRAINT_ATTRIBUTE_END;
    case NSLayoutAttributeTop: return GTK_CONSTRAINT_ATTRIBUTE_TOP;
    case NSLayoutAttributeBottom: return GTK_CONSTRAINT_ATTRIBUTE_BOTTOM;
    case NSLayoutAttributeWidth: return GTK_CONSTRAINT_ATTRIBUTE_WIDTH;
    case NSLayoutAttributeHeight: return GTK_CONSTRAINT_ATTRIBUTE_HEIGHT;
    case NSLayoutAttributeCenterX: return GTK_CONSTRAINT_ATTRIBUTE_CENTER_X;
    case NSLayoutAttributeCenterY: return GTK_CONSTRAINT_ATTRIBUTE_CENTER_Y;
    case NSLayoutAttributeBaseline:
    case NSLayoutAttributeFirstBaseline: return GTK_CONSTRAINT_ATTRIBUTE_BASELINE;
    default: return GTK_CONSTRAINT_ATTRIBUTE_NONE;
  }
}
static BOOL containerView(NSView *view)
{
  return [view class] == [NSView class] || [view class] == [NSTableCellView class];
}

@interface GTK4NativeView (Private)
- (GtkWidget *)build:(NSView *)view;
- (void)configureLayout:(NSView *)view;
- (void)entryChanged:(GtkWidget *)widget;
- (void)activate:(GtkWidget *)widget;
@end
static void entryChanged(GtkEditable *editable, gpointer bridge) { [(GTK4NativeView *)bridge entryChanged:GTK_WIDGET(editable)]; }
static void activated(GtkWidget *widget, gpointer bridge) { [(GTK4NativeView *)bridge activate:widget]; }

static GdkTexture *imageTexture(NSImage *image)
{
  if (!image) return NULL;
  NSData *tiff = [image TIFFRepresentation];
  NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
  NSData *png = [rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
  if (!png) return NULL;
  GBytes *bytes = g_bytes_new([png bytes], [png length]);
  GdkTexture *texture = gdk_texture_new_from_bytes(bytes, NULL);
  g_bytes_unref(bytes);
  return texture;
}

static BOOL radioCell(NSButtonCell *cell) { return [cell image] && [cell image] == [NSImage imageNamed:@"NSRadioButton"]; }
static BOOL checkCell(NSButtonCell *cell)
{
  return ([cell image] && [cell image] == [NSImage imageNamed:@"NSSwitch"]) || radioCell(cell);
}
static void releaseObject(gpointer object) { [(id)object release]; }
static void switchChanged(GObject *widget, GParamSpec *spec, gpointer bridge)
{
  [(GTK4NativeView *)bridge activate:GTK_WIDGET(widget)];
}
// Use ordinary GTK child widgets and symbolic icons; CSS belongs to GTK's theme.
static void buttonContent(GtkWidget *widget, NSString *title, NSImage *image,
  NSCellImagePosition position, NSBezelStyle bezel, CGFloat scale)
{
  NSArray *signature = @[title ?: @"", image ?: (id)[NSNull null], @(position), @(bezel), @(scale)];
  if ([signature isEqual:(id)g_object_get_data(G_OBJECT(widget), "appkit-content")]) return;
  g_object_set_data_full(G_OBJECT(widget), "appkit-content", [signature copy], releaseObject);
  GtkWidget *picture = NULL;
  if (image && position != NSNoImage) {
    GdkTexture *texture = imageTexture(image);
    if (texture) {
      picture = gtk_image_new_from_paintable(GDK_PAINTABLE(texture));
      gtk_image_set_pixel_size(GTK_IMAGE(picture), MAX(1,lround(20 * scale)));
      g_object_unref(texture);
    }
  }
  if (!picture && (bezel == NSHelpButtonBezelStyle || bezel == NSDisclosureBezelStyle
      || bezel == NSRoundedDisclosureBezelStyle))
    picture = gtk_image_new_from_icon_name(bezel == NSHelpButtonBezelStyle ? "help-browser-symbolic" : "pan-end-symbolic");
  if (!picture && [title length] && position != NSImageOnly) {
    gtk_button_set_label(GTK_BUTTON(widget), [title UTF8String]);
  } else {
    GtkWidget *label = [title length] && position != NSImageOnly ? gtk_label_new([title UTF8String]) : NULL;
    GtkWidget *child = NULL;
    if (label && picture) {
      BOOL vertical = position == NSImageAbove || position == NSImageBelow;
      child = gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, 6);
      BOOL after = position == NSImageRight || position == NSImageBelow;
      gtk_box_append(GTK_BOX(child), after ? label : picture);
      gtk_box_append(GTK_BOX(child), after ? picture : label);
    } else child = picture ?: label;
    gtk_button_set_child(GTK_BUTTON(widget), child);
  }
  if (bezel == NSCircularBezelStyle || bezel == NSHelpButtonBezelStyle || bezel == NSRoundedDisclosureBezelStyle)
    gtk_widget_add_css_class(widget, "circular");
  else gtk_widget_remove_css_class(widget, "circular");
  if (bezel == NSShadowlessSquareBezelStyle || bezel == NSRecessedBezelStyle || bezel == NSDisclosureBezelStyle)
    gtk_widget_add_css_class(widget, "flat");
  else gtk_widget_remove_css_class(widget, "flat");
}

static void dropdownChanged(GObject *widget, GParamSpec *spec, gpointer bridge)
{
  [(GTK4NativeView *)bridge activate:GTK_WIDGET(widget)];
}
static void popupItemSetup(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer unused)
{
  GtkWidget *label = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(label), 0);
  gtk_list_item_set_child(item, label);
}
static void popupItemBind(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer unused)
{
  NSPopUpButton *popup = g_object_get_data(G_OBJECT(factory), "appkit-popup");
  guint index = gtk_list_item_get_position(item);
  GtkStringObject *value = gtk_list_item_get_item(item);
  BOOL enabled = index < (guint)[popup numberOfItems] && [[popup itemAtIndex:index] isEnabled];
  GtkWidget *label = gtk_list_item_get_child(item);
  gtk_label_set_text(GTK_LABEL(label), value ? gtk_string_object_get_string(value) : "");
  gtk_widget_set_sensitive(label, enabled);
  gtk_list_item_set_selectable(item, enabled);
  gtk_list_item_set_activatable(item, enabled);
}

static void disconnectBridgeCallbacks(GtkWidget *widget, gpointer bridge)
{
  g_signal_handlers_disconnect_by_data(widget, bridge);
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child))
    disconnectBridgeCallbacks(child, bridge);
}

@implementation GTK4NativeView
+ (BOOL)supportsView:(NSView *)view
{
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return YES;
  BOOL control = [view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSImageView class]]
    || [view isKindOfClass:[NSButton class]] || [view isKindOfClass:[NSSwitch class]]
    || [view isKindOfClass:[NSSegmentedControl class]] || [view isKindOfClass:[NSMatrix class]];
  if (!control && !containerView(view)) return NO;
  if ([view isKindOfClass:[NSPopUpButton class]]) {
    if ([(NSPopUpButton *)view pullsDown]) return NO;
    for (id<NSMenuItem> item in [(NSPopUpButton *)view itemArray])
      if ([item isSeparatorItem] || [item hasSubmenu]
          || ([item image] && [item image] != [NSImage imageNamed:@"common_Nibble"])) return NO;
  }
  // Explicit context menus keep the existing menu-tracking path for now.
  if ([view isKindOfClass:[NSButton class]] && ![view isKindOfClass:[NSPopUpButton class]] && [view menu]) return NO;
  if ([view isKindOfClass:[NSTextField class]] && [(NSTextField *)view isEditable]
      && [(NSTextField *)view formatter]) return NO;
  if ([view isKindOfClass:[NSMatrix class]]) {
    if ([(NSMatrix *)view mode] != NSRadioModeMatrix) return NO;
    for (NSCell *cell in [(NSMatrix *)view cells])
      if (![cell isKindOfClass:[NSButtonCell class]] || !radioCell((id)cell)) return NO;
  }
  Class base = [view isKindOfClass:[NSTextField class]] ? [NSTextField class]
    : [view isKindOfClass:[NSImageView class]] ? [NSImageView class]
    : [view isKindOfClass:[NSPopUpButton class]] ? [NSPopUpButton class]
    : [view isKindOfClass:[NSButton class]] ? [NSButton class]
    : [view isKindOfClass:[NSSwitch class]] ? [NSSwitch class]
    : [view isKindOfClass:[NSSegmentedControl class]] ? [NSSegmentedControl class]
    : [view isKindOfClass:[NSMatrix class]] ? [NSMatrix class] : nil;
  if (base && class_getMethodImplementation([view class],@selector(drawRect:))
      != class_getMethodImplementation(base,@selector(drawRect:))) return NO;
  if (base && class_getMethodImplementation([view class],@selector(mouseDown:))
      != class_getMethodImplementation(base,@selector(mouseDown:))) return NO;
  for (NSLayoutConstraint *constraint in [view constraints]) {
    if (!attribute([constraint firstAttribute]) || ([constraint secondItem] && !attribute([constraint secondAttribute]))) return NO;
    NSView *first = [constraint firstItem], *second = [constraint secondItem];
    // GtkConstraintLayout relates the container and its direct children.
    if (first != view && [first superview] != view) return NO;
    if (second && second != view && [second superview] != view) return NO;
  }
  for (NSView *child in [view subviews]) if (![self supportsView:child]) return NO;
  return YES;
}
- (id)initWithView:(NSView *)view scale:(CGFloat)scale
{
  if (![GTK4NativeView supportsView:view]) { [self release]; return nil; }
  if ((self = [super init])) {
    _view = [view retain]; _scale = scale;
    _widgets = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
      | NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:8];
    _widget = [self build:view];
    if (!_widget) { [self release]; return nil; }
    g_object_ref_sink(_widget);
    [self synchronize];
  }
  return self;
}
- (GtkWidget *)widget { return _widget; }
- (NSView *)view { return _view; }
- (GtkWidget *)widgetForView:(NSView *)view { return [[_widgets objectForKey:view] pointerValue]; }
- (GtkWidget *)build:(NSView *)view
{
  GtkWidget *widget = NULL;
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) widget = [(id<GTK4NativeCustomView>)view gtk4NativeWidget];
  else if ([view isKindOfClass:[NSTextField class]]) {
    NSTextField *field = (id)view;
    widget = [field isEditable] ? gtk_entry_new() : gtk_label_new([[field stringValue] UTF8String]);
    if ([field isEditable]) {
      if ([field isKindOfClass:[NSSecureTextField class]]) gtk_entry_set_visibility(GTK_ENTRY(widget),FALSE);
      g_signal_connect(widget, "changed", G_CALLBACK(entryChanged), self);
      g_signal_connect(widget, "activate", G_CALLBACK(activated), self);
    } else {
      gtk_label_set_xalign(GTK_LABEL(widget), [field alignment] == NSRightTextAlignment ? 1
        : [field alignment] == NSCenterTextAlignment ? .5 : 0);
      gtk_label_set_ellipsize(GTK_LABEL(widget), PANGO_ELLIPSIZE_END);
      gtk_label_set_selectable(GTK_LABEL(widget), [field isSelectable]);
      PangoAttrList *attrs = pango_attr_list_new();
      NSFont *font = [field font];
      if (font) {
        pango_attr_list_insert(attrs, pango_attr_family_new([[font familyName] UTF8String]));
        // AppKit font sizes are user-space units. Pango point sizes would
        // apply its DPI conversion again (typically enlarging text by 4/3).
        pango_attr_list_insert(attrs, pango_attr_size_new_absolute([font pointSize] * _scale * PANGO_SCALE));
      }
      gtk_label_set_attributes(GTK_LABEL(widget), attrs);
      pango_attr_list_unref(attrs);
    }
  } else if ([view isKindOfClass:[NSImageView class]]) {
    widget = gtk_picture_new();
    gtk_picture_set_can_shrink(GTK_PICTURE(widget), TRUE);
    gtk_picture_set_content_fit(GTK_PICTURE(widget), GTK_CONTENT_FIT_CONTAIN);
  } else if ([view isKindOfClass:[NSPopUpButton class]]) {
    widget = gtk_drop_down_new(NULL, NULL);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_object_set_data_full(G_OBJECT(factory), "appkit-popup", [view retain], releaseObject);
    g_signal_connect(factory, "setup", G_CALLBACK(popupItemSetup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(popupItemBind), NULL);
    gtk_drop_down_set_list_factory(GTK_DROP_DOWN(widget), factory);
    g_object_unref(factory);
    g_signal_connect(widget, "notify::selected", G_CALLBACK(dropdownChanged), self);
  } else if ([view isKindOfClass:[NSSwitch class]]) {
    widget = gtk_switch_new();
    gtk_widget_set_halign(widget, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(widget, GTK_ALIGN_CENTER);
    g_signal_connect(widget, "notify::active", G_CALLBACK(switchChanged), self);
  } else if ([view isKindOfClass:[NSSegmentedControl class]]) {
    NSSegmentedControl *segments = (id)view;
    widget = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(widget, "linked");
    for (NSInteger i = 0; i < [segments segmentCount]; i++) {
      GtkWidget *segment = [segments trackingMode] == NSSegmentSwitchTrackingMomentary ? gtk_button_new() : gtk_toggle_button_new();
      g_object_set_data(G_OBJECT(segment), "appkit-view", view);
      g_object_set_data(G_OBJECT(segment), "appkit-segment", GINT_TO_POINTER(i));
      gtk_widget_set_hexpand(segment, TRUE);
      g_signal_connect(segment, "clicked", G_CALLBACK(activated), self);
      gtk_box_append(GTK_BOX(widget), segment);
    }
  } else if ([view isKindOfClass:[NSMatrix class]]) {
    NSMatrix *matrix = (id)view;
    widget = gtk_fixed_new();
    GtkCheckButton *group = NULL;
    for (NSInteger row = 0; row < [matrix numberOfRows]; row++)
      for (NSInteger col = 0; col < [matrix numberOfColumns]; col++) {
        NSButtonCell *cell = [matrix cellAtRow:row column:col];
        GtkWidget *radio = gtk_check_button_new_with_label([[cell title] UTF8String]);
        if (group) gtk_check_button_set_group(GTK_CHECK_BUTTON(radio), group);
        else group = GTK_CHECK_BUTTON(radio);
        g_object_set_data(G_OBJECT(radio), "appkit-view", view);
        g_object_set_data(G_OBJECT(radio), "appkit-cell", cell);
        NSRect rect = [matrix cellFrameAtRow:row column:col];
        if (![matrix isFlipped]) rect.origin.y = NSHeight(matrix.bounds) - NSMaxY(rect);
        gtk_fixed_put(GTK_FIXED(widget), radio, rect.origin.x*_scale, rect.origin.y*_scale);
        gtk_widget_set_size_request(radio, lround(rect.size.width*_scale), lround(rect.size.height*_scale));
        g_signal_connect(radio, "toggled", G_CALLBACK(activated), self);
      }
  } else if ([view isKindOfClass:[NSButton class]]) {
    NSButtonCell *cell = [(NSButton *)view cell];
    widget = checkCell(cell) ? gtk_check_button_new()
      : [cell showsStateBy] != NSNoCellMask ? gtk_toggle_button_new() : gtk_button_new();
    g_signal_connect(widget, GTK_IS_CHECK_BUTTON(widget) ? "toggled" : "clicked", G_CALLBACK(activated), self);
  } else if (containerView(view)) {
    widget = g_object_new(gs_native_container_get_type(), NULL);
  }
  if (!widget) return NULL;
  [_widgets setObject:[NSValue valueWithPointer:widget] forKey:view];
  g_object_set_data(G_OBJECT(widget), "appkit-view", view);
  if ([view identifier]) gtk_widget_set_name(widget, [[view identifier] UTF8String]);
  if (containerView(view)) {
    for (NSView *child in [view subviews]) {
      GtkWidget *nativeChild = [self build:child];
      if (!nativeChild) { g_object_ref_sink(widget); g_object_unref(widget); return NULL; }
      gtk_widget_set_parent(nativeChild, widget);
    }
    [self configureLayout:view];
  }
  return widget;
}
- (void)configureLayout:(NSView *)view
{
  GTK4Layout *layout = [GTK4Layout new];
  layout->root = [[GTK4LayoutProxy alloc] initWithFrame:NSMakeRect(0,0,NSWidth(view.frame)*_scale,NSHeight(view.frame)*_scale)];
  [layout->root setTranslatesAutoresizingMaskIntoConstraints:NO];
  NSMapTable *proxies = [NSMapTable strongToStrongObjectsMapTable];
  [proxies setObject:layout->root forKey:view];
  for (NSView *child in view.subviews) {
    NSRect rect=child.frame;
    if (![view isFlipped]) rect.origin.y=NSHeight(view.bounds)-NSMaxY(rect);
    GTK4LayoutProxy *proxy = [[[GTK4LayoutProxy alloc] initWithFrame:NSMakeRect(rect.origin.x*_scale,
      rect.origin.y*_scale,rect.size.width*_scale,rect.size.height*_scale)] autorelease];
    proxy->native = [self widgetForView:child];
    [proxy setTranslatesAutoresizingMaskIntoConstraints:NO];
    for (int axis=0;axis<2;axis++) {
      NSLayoutConstraintOrientation orientation=axis==0 ? NSLayoutConstraintOrientationHorizontal : NSLayoutConstraintOrientationVertical;
      [proxy setContentHuggingPriority:[child contentHuggingPriorityForOrientation:orientation] forOrientation:orientation];
      [proxy setContentCompressionResistancePriority:[child contentCompressionResistancePriorityForOrientation:orientation] forOrientation:orientation];
    }
    [layout->root addSubview:proxy]; [proxies setObject:proxy forKey:child];
  }
  layout->engine = [GSAutoLayoutEngine new];
  [layout->engine beginUpdates];
  [layout->engine pinContentView:layout->root];
  NSMutableArray *sizes=[NSMutableArray array];
  for (NSLayoutConstraint *c in [layout->engine constraintsForView:layout->root])
    if ([c firstAttribute]==NSLayoutAttributeWidth || [c firstAttribute]==NSLayoutAttributeHeight) [sizes addObject:c];
  layout->sizeConstraints=[sizes copy];
  NSMutableArray *constraints=[NSMutableArray arrayWithArray:view.constraints];
  for (NSView *child in view.subviews) {
    for (NSLayoutConstraint *c in child.constraints)
      if ([c firstItem]==child && ![c secondItem]) [constraints addObject:c];
    if ([child translatesAutoresizingMaskIntoConstraints]) {
      NSView *proxy=[proxies objectForKey:child]; NSRect rect=proxy.frame;
      [layout->engine addConstraints:@[
        [proxy.leftAnchor constraintEqualToAnchor:layout->root.leftAnchor constant:rect.origin.x],
        [proxy.topAnchor constraintEqualToAnchor:layout->root.topAnchor constant:rect.origin.y],
        [proxy.widthAnchor constraintEqualToConstant:rect.size.width],
        [proxy.heightAnchor constraintEqualToConstant:rect.size.height]]];
    }
  }
  for (NSLayoutConstraint *c in constraints) {
    NSLayoutConstraint *copy=[NSLayoutConstraint constraintWithItem:[proxies objectForKey:c.firstItem]
      attribute:c.firstAttribute relatedBy:c.relation toItem:[proxies objectForKey:c.secondItem]
      attribute:c.secondAttribute multiplier:c.multiplier constant:c.constant*_scale];
    [copy setPriority:c.priority]; [layout->engine addConstraint:copy];
  }
  [layout->engine endUpdates];
  g_object_set_data_full(G_OBJECT([self widgetForView:view]),"appkit-layout",layout,releaseLayout);
}
- (void)synchronize
{
  _synchronizing = YES;
  for (NSView *view in _widgets) {
    GtkWidget *widget = [self widgetForView:view];
    gtk_widget_set_visible(widget, ![view isHidden]);
    gtk_widget_set_tooltip_text(widget, [[view toolTip] UTF8String]);
    if ([view isKindOfClass:[NSControl class]]) gtk_widget_set_sensitive(widget, [(NSControl *)view isEnabled]);
    if ([view isKindOfClass:[NSTextField class]]) {
      const char *text = [[(NSTextField *)view stringValue] UTF8String] ?: "";
      if (GTK_IS_EDITABLE(widget)) {
        if (strcmp(gtk_editable_get_text(GTK_EDITABLE(widget)), text)) gtk_editable_set_text(GTK_EDITABLE(widget), text);
      } else if (GTK_IS_LABEL(widget) && strcmp(gtk_label_get_text(GTK_LABEL(widget)), text)) {
        gtk_label_set_text(GTK_LABEL(widget), text);
      }
    } else if ([view isKindOfClass:[NSPopUpButton class]]) {
      NSPopUpButton *popup = (id)view;
      NSMutableArray *signature = [NSMutableArray array];
      for (id<NSMenuItem> item in [popup itemArray])
        [signature addObject:@[[item title] ?: @"", @([item isEnabled])]];
      if (![signature isEqual:(id)g_object_get_data(G_OBJECT(widget), "appkit-popup-items")]) {
        GtkStringList *strings = gtk_string_list_new(NULL);
        for (id<NSMenuItem> item in [popup itemArray]) gtk_string_list_append(strings, [[item title] UTF8String] ?: "");
        gtk_drop_down_set_model(GTK_DROP_DOWN(widget), G_LIST_MODEL(strings));
        g_object_unref(strings);
        g_object_set_data_full(G_OBJECT(widget), "appkit-popup-items", [signature copy], releaseObject);
      }
      NSInteger index = [popup indexOfSelectedItem];
      gtk_drop_down_set_selected(GTK_DROP_DOWN(widget), index >= 0 ? (guint)index : GTK_INVALID_LIST_POSITION);
    } else if ([view isKindOfClass:[NSSwitch class]]) {
      gtk_switch_set_active(GTK_SWITCH(widget), [(NSSwitch *)view integerValue] != NSOffState);
    } else if ([view isKindOfClass:[NSSegmentedControl class]]) {
      NSSegmentedControl *segments = (id)view;
      NSInteger i = 0;
      for (GtkWidget *segment = gtk_widget_get_first_child(widget); segment; segment = gtk_widget_get_next_sibling(segment), i++) {
        gtk_widget_set_sensitive(segment, [segments isEnabled] && [segments isEnabledForSegment:i]);
        NSString *tip = [(NSSegmentedCell *)segments.cell toolTipForSegment:i];
        gtk_widget_set_tooltip_text(segment, [tip UTF8String]);
        buttonContent(segment, [segments labelForSegment:i], [segments imageForSegment:i], NSImageLeft, NSRoundedBezelStyle, _scale);
        CGFloat width = [segments widthForSegment:i];
        gtk_widget_set_size_request(segment, width > 0 ? lround(width*_scale) : -1, -1);
        if (GTK_IS_TOGGLE_BUTTON(segment)) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(segment), [segments isSelectedForSegment:i]);
      }
    } else if ([view isKindOfClass:[NSMatrix class]]) {
      NSMatrix *matrix = (id)view;
      for (GtkWidget *radio = gtk_widget_get_first_child(widget); radio; radio = gtk_widget_get_next_sibling(radio)) {
        NSButtonCell *cell = g_object_get_data(G_OBJECT(radio), "appkit-cell");
        gtk_widget_set_sensitive(radio, [matrix isEnabled] && [cell isEnabled]);
        gtk_check_button_set_label(GTK_CHECK_BUTTON(radio), [[cell title] UTF8String]);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(radio), [cell state] == NSOnState);
      }
    } else if ([view isKindOfClass:[NSButton class]]) {
      NSButton *button = (id)view;
      if (GTK_IS_CHECK_BUTTON(widget)) {
        gtk_check_button_set_label(GTK_CHECK_BUTTON(widget), [[button title] UTF8String]);
        gtk_check_button_set_inconsistent(GTK_CHECK_BUTTON(widget), [(NSButtonCell *)[button cell] state] == NSMixedState);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(widget), [(NSButtonCell *)[button cell] state] == NSOnState);
      } else {
        NSImage *image = [button image];
        NSString *title = [button title];
        if ([(NSButtonCell *)[button cell] state] != NSOffState) {
          if ([button alternateImage]) image = [button alternateImage];
          if ([[button alternateTitle] length]) title = [button alternateTitle];
        }
        buttonContent(widget, title, image, [button imagePosition], [button bezelStyle], _scale);
        BOOL isDefault = [[button keyEquivalent] isEqual:@"\r"];
        if (isDefault) gtk_widget_add_css_class(widget, "suggested-action");
        else gtk_widget_remove_css_class(widget, "suggested-action");
        if (GTK_IS_TOGGLE_BUTTON(widget)) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(widget), [(NSButtonCell *)[button cell] state] != NSOffState);
      }
    } else if ([view isKindOfClass:[NSImageView class]]) {
      NSImage *image = [(NSImageView *)view image];
      if (g_object_get_data(G_OBJECT(widget), "appkit-image") != image) {
        GdkTexture *texture = imageTexture(image);
        gtk_picture_set_paintable(GTK_PICTURE(widget), texture ? GDK_PAINTABLE(texture) : NULL);
        if (texture) g_object_unref(texture);
        g_object_set_data(G_OBJECT(widget), "appkit-image", image);
      }
    }
  }
  _synchronizing = NO;
}
- (void)entryChanged:(GtkWidget *)widget
{
  if (_synchronizing) return;
  NSTextField *field = g_object_get_data(G_OBJECT(widget), "appkit-view");
  NSString *text = [NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(widget))];
  [field setStringValue:text];
  NSDictionary *binding = [field infoForBinding:NSValueBinding];
  id destination = [binding objectForKey:NSObservedObjectKey];
  NSString *key = [binding objectForKey:NSObservedKeyPathKey];
  if (destination && key) {
    id value = text;
    NSDictionary *options = [binding objectForKey:NSOptionsKey];
    NSValueTransformer *transformer = [options objectForKey:NSValueTransformerBindingOption];
    if (!transformer && [options objectForKey:NSValueTransformerNameBindingOption])
      transformer = [NSValueTransformer valueTransformerForName:[options objectForKey:NSValueTransformerNameBindingOption]];
    if (transformer && [[transformer class] allowsReverseTransformation]) value = [transformer reverseTransformedValue:value];
    [destination setValue:value forKeyPath:key];
  }
  if ([field isContinuous]) [field sendAction:[field action] to:[field target]];
}
- (void)activate:(GtkWidget *)widget
{
  if (_synchronizing || !gtk_widget_is_sensitive(widget)) return;
  // An action may enter a modal loop or remove its source view and peer.
  [self retain];
  @try {
    NSControl *control = g_object_get_data(G_OBJECT(widget), "appkit-view");
    if ([control isKindOfClass:[NSPopUpButton class]]) {
      NSPopUpButton *popup = (id)control;
      guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(widget));
      // GObject can queue another notify after a rejected selection is reset.
      // Synchronization is not a second user action.
      if (index == (guint)[popup indexOfSelectedItem]) return;
      if (index < (guint)[popup numberOfItems]) {
        id<NSMenuItem> item = [popup itemAtIndex:index];
        if ([item isEnabled]) {
          [popup selectItemAtIndex:index];
          // Use the menu item's ordinary action path. NSPopUpButtonCell updates
          // selected-index/tag/value bindings before sending the popup action.
          [[popup cell] setControlView:popup];
          if ([item action]) [NSApp sendAction:[item action] to:[item target] from:item];
          else [popup sendAction:[popup action] to:[popup target]];
        }
      }
      [self synchronize];
      return;
    }
    if ([control isKindOfClass:[NSMatrix class]]) {
      if (!gtk_check_button_get_active(GTK_CHECK_BUTTON(widget))) return;
      NSCell *cell = g_object_get_data(G_OBJECT(widget), "appkit-cell");
      [(NSMatrix *)control selectCell:cell];
    } else if ([control isKindOfClass:[NSSegmentedControl class]]) {
      NSSegmentedControl *segments = (id)control;
      NSInteger index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "appkit-segment"));
      BOOL selected = [segments trackingMode] == NSSegmentSwitchTrackingSelectAny
        ? ![segments isSelectedForSegment:index] : YES;
      [(NSSegmentedCell *)segments.cell setSelected:selected forSegment:index];
    } else if ([control isKindOfClass:[NSSwitch class]]) {
      [(NSSwitch *)control setIntegerValue:gtk_switch_get_active(GTK_SWITCH(widget)) ? NSOnState : NSOffState];
    } else if ([control isKindOfClass:[NSButton class]]) {
      NSButton *button = (id)control;
      if (radioCell((id)button.cell)) {
        if (!gtk_check_button_get_active(GTK_CHECK_BUTTON(widget))) return;
        for (NSView *sibling in button.superview.subviews)
          if ([sibling isKindOfClass:[NSButton class]] && radioCell((id)[(NSButton *)sibling cell]))
            [(NSButton *)sibling setState:sibling == button ? NSOnState : NSOffState];
      } else if (GTK_IS_CHECK_BUTTON(widget) || GTK_IS_TOGGLE_BUTTON(widget)) [button setNextState];
    }
    [control sendAction:[control action] to:[control target]];
    if ([control isKindOfClass:[NSSegmentedControl class]]
        && [(NSSegmentedControl *)control trackingMode] == NSSegmentSwitchTrackingMomentary) {
      NSInteger index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "appkit-segment"));
      [(NSSegmentedCell *)control.cell setSelected:NO forSegment:index];
    }
    [self synchronize];
  } @finally { [self release]; }
}
- (void)dealloc
{
  _synchronizing = YES;
  if (_widget) {
    disconnectBridgeCallbacks(_widget, self);
    gtk_widget_set_visible(_widget, FALSE);
    if (gtk_widget_get_parent(_widget)) gtk_widget_unparent(_widget);
    g_object_unref(_widget);
  }
  [_widgets release]; [_view release]; [super dealloc];
}
@end
