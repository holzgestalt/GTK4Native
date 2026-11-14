#import "GTK4NativeView.h"
#import "GTK4NativeCustomView.h"
#import "GTK4NativeClip.h"
#include <objc/runtime.h>
/* GTK owns allocation, including translated AppKit constraints and intrinsic
   preferences. AppKit views remain the model/responder objects. */
typedef struct { GtkWidget parent; } GSNativeContainer;
typedef struct { GtkWidgetClass parent; } GSNativeContainerClass;
G_DEFINE_TYPE(GSNativeContainer, gs_native_container, GTK_TYPE_WIDGET)
static void containerDispose(GObject *object)
{
  gtk_widget_set_layout_manager(GTK_WIDGET(object),NULL);
  GtkWidget *child;
  while ((child=gtk_widget_get_first_child(GTK_WIDGET(object)))) gtk_widget_unparent(child);
  G_OBJECT_CLASS(gs_native_container_parent_class)->dispose(object);
}
static void containerSnapshot(GtkWidget *widget,GtkSnapshot *snapshot)
{
  id bridge=g_object_get_data(G_OBJECT(widget),"appkit-bridge");
  if (bridge) [bridge performSelector:@selector(reflectContainer:) withObject:[NSValue valueWithPointer:widget]];
  for (GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child))
    if (gtk_widget_get_visible(child)) gtk_widget_snapshot_child(widget,child,snapshot);
}
static void gs_native_container_class_init(GSNativeContainerClass *cls)
{
  G_OBJECT_CLASS(cls)->dispose=containerDispose;
  GTK_WIDGET_CLASS(cls)->snapshot=containerSnapshot;
}
static void gs_native_container_init(GSNativeContainer *container)
{ gtk_widget_set_layout_manager(GTK_WIDGET(container),gtk_constraint_layout_new()); }

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
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return NO;
  return [view class] == [NSView class] || [view class] == [NSTableCellView class] ||
    (GTK4NativeCanWrapView(view) && ![view isKindOfClass:[NSControl class]]
      && class_getMethodImplementation([view class], @selector(drawRect:)) == class_getMethodImplementation([NSView class], @selector(drawRect:))
      && class_getMethodImplementation([view class], @selector(mouseDown:)) == class_getMethodImplementation([NSView class], @selector(mouseDown:)));
}

static BOOL customView(NSView *view)
{
  if (!GTK4NativeCanWrapView(view) || containerView(view)) return NO;
  Class base = [view isKindOfClass:[NSButton class]] ? [NSButton class]
    : [view isKindOfClass:[NSTextField class]] ? [NSTextField class]
    : [view isKindOfClass:[NSImageView class]] ? [NSImageView class]
    : [view isKindOfClass:[NSSwitch class]] ? [NSSwitch class]
    : [view isKindOfClass:[NSSegmentedControl class]] ? [NSSegmentedControl class]
    : [view isKindOfClass:[NSMatrix class]] ? [NSMatrix class] : Nil;
  return !base || class_getMethodImplementation(view.class,@selector(drawRect:)) != class_getMethodImplementation(base,@selector(drawRect:))
    || class_getMethodImplementation(view.class,@selector(mouseDown:)) != class_getMethodImplementation(base,@selector(mouseDown:));
}
static BOOL layoutContainer(NSView *view) { return containerView(view) || customView(view); }
@interface GTK4NativeView (Private)
- (GtkWidget *)build:(NSView *)view;
- (void)configureNativeLayout:(NSView *)view;
- (void)entryChanged:(GtkWidget *)widget;
- (void)scrollChanged:(GtkWidget *)widget;
- (void)activate:(GtkWidget *)widget;
@end
static void entryChanged(GtkEditable *editable, gpointer bridge) { [(GTK4NativeView *)bridge entryChanged:GTK_WIDGET(editable)]; }
static void activated(GtkWidget *widget, gpointer bridge) { [(GTK4NativeView *)bridge activate:widget]; }

static void scrollChanged(GtkAdjustment *adjustment,gpointer bridge)
{
  GtkWidget *widget=g_object_get_data(G_OBJECT(adjustment),"appkit-scroll-widget");
  [(GTK4NativeView *)bridge scrollChanged:widget];
}
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
  if(g_object_get_data(G_OBJECT(widget),"appkit-bridge")==bridge) g_object_set_data(G_OBJECT(widget),"appkit-bridge",NULL);
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child))
    disconnectBridgeCallbacks(child, bridge);
}

@implementation GTK4NativeView
+ (BOOL)supportsView:(NSView *)view
{
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return YES;
  if ([view class]==[NSScrollView class]) {
    NSScrollView *scroll=(id)view;
    return !scroll.rulersVisible && scroll.documentView && [self supportsView:scroll.documentView];
  }
  if([view isKindOfClass:[NSTextField class]] && view.class!=[NSTextField class] && view.class!=[NSSecureTextField class]) return NO;
  BOOL control = [view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSImageView class]]
    || [view isKindOfClass:[NSButton class]] || [view isKindOfClass:[NSSwitch class]]
    || [view isKindOfClass:[NSSegmentedControl class]] || [view isKindOfClass:[NSMatrix class]];
  BOOL wrapped=customView(view);
  if (!control && !containerView(view) && !wrapped) return NO;
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
  if (base && !wrapped && class_getMethodImplementation([view class],@selector(drawRect:))
      != class_getMethodImplementation(base,@selector(drawRect:))) return NO;
  if (base && !wrapped && class_getMethodImplementation([view class],@selector(mouseDown:))
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
    for (NSView *source in _widgets) {
      GSSetNativeViewPeer(source,self);
      [source setNeedsDisplay:NO];
    }
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
  else if ([view class]==[NSScrollView class]) {
    NSScrollView *scroll=(id)view;
    widget=gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(widget),scroll.hasHorizontalScroller?GTK_POLICY_AUTOMATIC:GTK_POLICY_NEVER,
      scroll.hasVerticalScroller?GTK_POLICY_AUTOMATIC:GTK_POLICY_NEVER);
    gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(widget),scroll.borderType!=NSNoBorder);
    gtk_widget_add_css_class(widget,"view");
    GtkWidget *document=[self build:scroll.documentView];
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(widget),document);
    GtkAdjustment *h=gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget));
    GtkAdjustment *v=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget));
    g_object_set_data(G_OBJECT(h),"appkit-scroll-widget",widget); g_object_set_data(G_OBJECT(v),"appkit-scroll-widget",widget);
    g_signal_connect(h,"value-changed",G_CALLBACK(scrollChanged),self); g_signal_connect(v,"value-changed",G_CALLBACK(scrollChanged),self);
  }
  else if (customView(view)) widget=GTK4NativeCustomViewNew(view,_scale);
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
        if ([[NSFontManager sharedFontManager] traitsOfFont:font] & NSBoldFontMask)
          pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_BOLD));
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
  g_object_set_data_full(G_OBJECT(widget),"appkit-source-frame",[[NSValue valueWithRect:view.frame] retain],releaseObject);
  if ([view identifier]) gtk_widget_set_name(widget, [[view identifier] UTF8String]);
  g_object_set_data(G_OBJECT(widget),"appkit-bridge",self);
  if (layoutContainer(view)) {
    if (customView(view)) gtk_widget_set_layout_manager(widget,gtk_constraint_layout_new());
    for (NSView *child in [view subviews]) {
      GtkWidget *nativeChild = [self build:child];
      if (!nativeChild) { g_object_ref_sink(widget); g_object_unref(widget); return NULL; }
      gtk_widget_set_parent(nativeChild, widget);
    }
    [self configureNativeLayout:view];
  }
  if([view isKindOfClass:[NSTableCellView class]]) {
    // GtkListView owns row sizing. Do not let constraint-layout measurement
    // feed a row's natural-size solve back into list allocation. GTK still
    // allocates every child through the inner constraint layout.
    GtkWidget *viewport=GTK4NativeClipNewFilling(widget);
    g_object_set_data(G_OBJECT(viewport),"appkit-view",view);
    g_object_set_data(G_OBJECT(viewport),"appkit-bridge",self);
    g_object_set_data_full(G_OBJECT(viewport),"appkit-source-frame",[[NSValue valueWithRect:view.frame] retain],releaseObject);
    [_widgets setObject:[NSValue valueWithPointer:viewport] forKey:view];
    widget=viewport;
  }
  return widget;
}
// Whole native documents use GTK's own constraint solver. No shadow NSViews
// or GNUstep layout engine participate in allocation or scrolling.
- (void)configureNativeLayout:(NSView *)view
{
  GtkConstraintLayout *layout = GTK_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager([self widgetForView:view]));
  NSMutableArray *constraints = [NSMutableArray arrayWithArray:view.constraints];
  for (NSView *child in view.subviews) {
    GtkWidget *widget = [self widgetForView:child];
    for (NSLayoutConstraint *c in child.constraints)
      if (c.firstItem == child && !c.secondItem) [constraints addObject:c];
    for(int axis=0;axis<2;axis++) {
      GtkOrientation orientation=axis==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL;
      NSLayoutConstraintOrientation sourceAxis=axis==0?NSLayoutConstraintOrientationHorizontal:NSLayoutConstraintOrientationVertical;
      // GTK already supplies ordinary intrinsic preferences. Add explicit
      // source preferences when the application changes their priorities.
      if ([child contentHuggingPriorityForOrientation:sourceAxis]==250
          && [child contentCompressionResistancePriorityForOrientation:sourceAxis]==750) continue;
      int natural=0; gtk_widget_measure(widget,orientation,-1,NULL,&natural,NULL,NULL);
      GtkConstraintAttribute attr=axis==0?GTK_CONSTRAINT_ATTRIBUTE_WIDTH:GTK_CONSTRAINT_ATTRIBUTE_HEIGHT;
      CGFloat minimum=0;
      for(NSLayoutConstraint *c in constraints)
        if(c.firstItem==child && !c.secondItem && c.firstAttribute==(axis==0?NSLayoutAttributeWidth:NSLayoutAttributeHeight)
            && c.priority>=1000 && c.relation!=NSLayoutRelationLessThanOrEqual) minimum=MAX(minimum,c.constant*_scale);
      natural=MAX(natural,lround(minimum));
      NSLayoutPriority hugging=[child contentHuggingPriorityForOrientation:sourceAxis];
      NSLayoutPriority resistance=[child contentCompressionResistancePriorityForOrientation:sourceAxis];
      GtkConstraintGuide *guide=gtk_constraint_guide_new();
      gtk_constraint_guide_set_min_size(guide,axis==0?lround(minimum):0,axis==1?lround(minimum):0);
      gtk_constraint_guide_set_nat_size(guide,axis==0?natural:0,axis==1?natural:0);
      gtk_constraint_guide_set_max_size(guide,G_MAXINT,G_MAXINT);
      gtk_constraint_guide_set_strength(guide,MAX(1,(int)MIN(hugging,resistance)*1000));
      gtk_constraint_layout_add_guide(layout,guide);
      gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(widget,attr,GTK_CONSTRAINT_RELATION_EQ,
        guide,attr,1,0,GTK_CONSTRAINT_STRENGTH_REQUIRED));
    }
    if (child.translatesAutoresizingMaskIntoConstraints) {
      NSRect rect = child.frame;
      if (!view.isFlipped) rect.origin.y = NSHeight(view.bounds) - NSMaxY(rect);
      CGFloat parentSize[]={NSWidth(view.bounds),NSHeight(view.bounds)};
      CGFloat positions[]={rect.origin.x,rect.origin.y},sizes[]={rect.size.width,rect.size.height};
      NSUInteger mask=child.autoresizingMask;
      BOOL flex[2][3]={{(mask&NSViewMinXMargin)!=0,(mask&NSViewWidthSizable)!=0,(mask&NSViewMaxXMargin)!=0},
        {(mask&(view.isFlipped?NSViewMinYMargin:NSViewMaxYMargin))!=0,(mask&NSViewHeightSizable)!=0,
         (mask&(view.isFlipped?NSViewMaxYMargin:NSViewMinYMargin))!=0}};
      GtkConstraintAttribute positionsAttr[]={GTK_CONSTRAINT_ATTRIBUTE_LEFT,GTK_CONSTRAINT_ATTRIBUTE_TOP};
      GtkConstraintAttribute sizesAttr[]={GTK_CONSTRAINT_ATTRIBUTE_WIDTH,GTK_CONSTRAINT_ATTRIBUTE_HEIGHT};
      for(int axis=0;axis<2;axis++) {
        CGFloat lengths[]={MAX(0,positions[axis]),MAX(0,sizes[axis]),MAX(0,parentSize[axis]-positions[axis]-sizes[axis])};
        CGFloat total=0; int count=0;
        for(int i=0;i<3;i++) if(flex[axis][i]) { total+=lengths[i]; count++; }
        for(int i=0;i<2;i++) {
          CGFloat weight=flex[axis][i] ? (total>0?lengths[i]/total:1.0/MAX(1,count)) : 0;
          CGFloat constant=(i==0?positions[axis]:sizes[axis])-parentSize[axis]*weight;
          gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(widget,i==0?positionsAttr[axis]:sizesAttr[axis],
            GTK_CONSTRAINT_RELATION_EQ,NULL,weight>0?sizesAttr[axis]:GTK_CONSTRAINT_ATTRIBUTE_NONE,
            weight>0?weight:1,constant*_scale,GTK_CONSTRAINT_STRENGTH_REQUIRED));
        }
      }
    }
  }
  for (NSLayoutConstraint *c in constraints) {
    gpointer first = c.firstItem == view ? NULL : [self widgetForView:c.firstItem];
    gpointer second = c.secondItem == view ? NULL : [self widgetForView:c.secondItem];
    GtkConstraintRelation relation = c.relation == NSLayoutRelationEqual ? GTK_CONSTRAINT_RELATION_EQ
      : c.relation == NSLayoutRelationLessThanOrEqual ? GTK_CONSTRAINT_RELATION_LE : GTK_CONSTRAINT_RELATION_GE;
    int strength = c.priority >= 1000 ? GTK_CONSTRAINT_STRENGTH_REQUIRED : MAX(1, (int)c.priority*1000);
    GtkConstraintAttribute firstAttr=attribute(c.firstAttribute);
    GtkConstraintAttribute secondAttr=c.secondItem?attribute(c.secondAttribute):GTK_CONSTRAINT_ATTRIBUTE_NONE;
    double constant=c.constant*_scale;
    // GtkConstraintLayout's baseline variable does not position GtkLabel text
    // in the installed GTK. Express the font-measured baseline through TOP.
    if(firstAttr==GTK_CONSTRAINT_ATTRIBUTE_BASELINE) {
      int baseline=-1; if(first) gtk_widget_measure(GTK_WIDGET(first),GTK_ORIENTATION_VERTICAL,-1,NULL,NULL,NULL,&baseline);
      constant-=MAX(0,baseline); firstAttr=GTK_CONSTRAINT_ATTRIBUTE_TOP;
    }
    if(secondAttr==GTK_CONSTRAINT_ATTRIBUTE_BASELINE) {
      int baseline=-1; if(second) gtk_widget_measure(GTK_WIDGET(second),GTK_ORIENTATION_VERTICAL,-1,NULL,NULL,NULL,&baseline);
      constant+=c.multiplier*MAX(0,baseline); secondAttr=GTK_CONSTRAINT_ATTRIBUTE_TOP;
    }
    double multiplier=c.multiplier;
    // Keep the child as GTK's target. Parent-target equations from nibs are
    // algebraically equivalent, but compete with the container's edit size.
    if(!first && second && multiplier!=0) {
      gpointer target=second; second=first; first=target;
      GtkConstraintAttribute attr=firstAttr; firstAttr=secondAttr; secondAttr=attr;
      constant=-constant/multiplier;
      if(multiplier>0 && relation!=GTK_CONSTRAINT_RELATION_EQ)
        relation=relation==GTK_CONSTRAINT_RELATION_GE?GTK_CONSTRAINT_RELATION_LE:GTK_CONSTRAINT_RELATION_GE;
      multiplier=1.0/multiplier;
    }
    gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(first,firstAttr,relation,
      second,secondAttr,multiplier,constant,strength));
  }
}
- (void)synchronize
{
  if (_invalidated || _synchronizing) return;
  _synchronizing = YES;
  for (NSView *view in _widgets) {
    GtkWidget *widget = [self widgetForView:view];
    gtk_widget_set_visible(widget, ![view isHidden]);
    gtk_widget_set_tooltip_text(widget, [[view toolTip] UTF8String]);
    if ([view isKindOfClass:[NSControl class]]) gtk_widget_set_sensitive(widget, [(NSControl *)view isEnabled]);
    if (GTK4NativeIsCustomView(widget)) continue;
    if ([view class]==[NSScrollView class]) {
      NSScrollView *scroll=(id)view; NSView *document=scroll.documentView;
      GtkWidget *nativeDocument=[self widgetForView:document];
      if (!nativeDocument) { gtk_widget_set_visible(widget,FALSE); continue; }
      gtk_widget_set_size_request(nativeDocument,MAX(1,lround(NSWidth(document.frame)*_scale)),MAX(1,lround(NSHeight(document.frame)*_scale)));
      GtkAdjustment *h=gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget));
      GtkAdjustment *v=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget));
      NSValue *last=g_object_get_data(G_OBJECT(widget),"appkit-scroll-origin");
      if (gtk_adjustment_get_page_size(v)>0 && (!last || !NSEqualPoints(last.pointValue,scroll.contentView.bounds.origin))) {
        NSRect bounds=scroll.contentView.bounds;
        gtk_adjustment_set_value(h,NSMinX(bounds)*_scale);
        gtk_adjustment_set_value(v,(document.isFlipped?NSMinY(bounds):MAX(0,NSHeight(document.bounds)-NSMaxY(bounds)))*_scale);
        g_object_set_data_full(G_OBJECT(widget),"appkit-scroll-origin",[[NSValue valueWithPoint:bounds.origin] retain],releaseObject);
      }
    } else if ([view isKindOfClass:[NSTextField class]]) {
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
- (void)scrollChanged:(GtkWidget *)widget
{
  if (_synchronizing || _invalidated || !g_object_get_data(G_OBJECT(widget),"appkit-scroll-origin")) return;
  NSScrollView *scroll=g_object_get_data(G_OBJECT(widget),"appkit-view");
  NSView *document=scroll.documentView; NSClipView *clip=scroll.contentView;
  double x=gtk_adjustment_get_value(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget)))/_scale;
  double y=gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)))/_scale;
  if(!document.isFlipped) y=MAX(0,NSHeight(document.bounds)-NSHeight(clip.bounds)-y);
  _synchronizing=YES;
  @try { [clip scrollToPoint:NSMakePoint(x,y)]; [scroll reflectScrolledClipView:clip]; }
  @finally { _synchronizing=NO; }
  g_object_set_data_full(G_OBJECT(widget),"appkit-scroll-origin",[[NSValue valueWithPoint:clip.bounds.origin] retain],releaseObject);
}
- (NSRect)configurationFrameForView:(NSView *)view
{
  GtkWidget *widget=[self widgetForView:view];
  NSValue *reflected=widget?g_object_get_data(G_OBJECT(widget),"appkit-reflected-frame"):nil;
  NSValue *original=widget?g_object_get_data(G_OBJECT(widget),"appkit-source-frame"):nil;
  return reflected && original && NSEqualRects(reflected.rectValue,view.frame)?original.rectValue:view.frame;
}
- (void)invalidateNativeView:(NSView *)view inRect:(NSRect)rect
{
  if (_invalidated) return;
  GtkWidget *widget=[self widgetForView:view];
  if (GTK4NativeIsCustomView(widget)) GTK4NativeCustomViewInvalidate(widget,rect);
  else { [self synchronize]; if (widget) gtk_widget_queue_draw(widget); }
}
- (BOOL)ownsLayoutForNativeView:(NSView *)view { return !_invalidated; }
- (void)layoutNativeView:(NSView *)view
{
  if (_reflecting || _invalidated) return;
  GtkWidget *widget=[self widgetForView:view]; if (widget) gtk_widget_queue_allocate(widget);
}
- (BOOL)focusNativeView:(NSView *)view
{
  GtkWidget *widget=[self widgetForView:view];
  return !_invalidated && widget && gtk_widget_grab_focus(widget);
}
- (void)reflectContainer:(NSValue *)value
{
  if (_reflecting || _invalidated) return;
  GtkWidget *widget=value.pointerValue;
  NSView *parent=g_object_get_data(G_OBJECT(widget),"appkit-view");
  _reflecting=YES;
  @try {
    for (NSView *view in parent.subviews) {
      GtkWidget *child=[self widgetForView:view]; graphene_rect_t rect;
      if (!child || !gtk_widget_should_layout(child) || !gtk_widget_compute_bounds(child,widget,&rect)
          || rect.size.width<=0 || rect.size.height<=0) continue;
      NSValue *expected=g_object_get_data(G_OBJECT(child),"appkit-reflected-frame");
      if(!expected) expected=g_object_get_data(G_OBJECT(child),"appkit-source-frame");
      // An application geometry change wins until its native constraints are
      // rebuilt. An in-flight snapshot must not restore the previous frame.
      if(expected && !NSEqualRects(view.frame,expected.rectValue)) continue;
      NSRect frame=NSMakeRect(rect.origin.x/_scale,rect.origin.y/_scale,rect.size.width/_scale,rect.size.height/_scale);
      if (!parent.isFlipped) frame.origin.y=NSHeight(parent.bounds)-NSMaxY(frame);
      if (!NSEqualRects(view.frame,frame)) [view setFrame:frame];
      g_object_set_data_full(G_OBJECT(child),"appkit-reflected-frame",[[NSValue valueWithRect:view.frame] retain],releaseObject);
    }
  } @finally { _reflecting=NO; }
}
- (void)invalidate
{
  if (_invalidated) return;
  _invalidated=YES;
  for (NSView *view in _widgets) {
    if (GSNativeViewPeerForView(view)==self) GSSetNativeViewPeer(view,nil);
    GtkWidget *widget=[self widgetForView:view];
    g_object_set_data(G_OBJECT(widget),"appkit-bridge",NULL);
    if(GTK_IS_SCROLLED_WINDOW(widget)) {
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget)),self);
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)),self);
    }
  }
  if (_widget) { disconnectBridgeCallbacks(_widget,self); gtk_widget_set_visible(_widget,FALSE); }
}
- (void)dealloc
{
  [self invalidate];
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
