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

@implementation GTK4NativeView
+ (BOOL)supportsView:(NSView *)view
{
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return YES;
  BOOL control = [view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSImageView class]]
    || [view isKindOfClass:[NSButton class]];
  if (!control && !containerView(view)) return NO;
  if ([view isKindOfClass:[NSPopUpButton class]]) return NO;
  if ([view isKindOfClass:[NSTextField class]] && [(NSTextField *)view isEditable]
      && [(NSTextField *)view formatter]) return NO;
  Class base = [view isKindOfClass:[NSTextField class]] ? [NSTextField class]
    : [view isKindOfClass:[NSImageView class]] ? [NSImageView class]
    : [view isKindOfClass:[NSButton class]] ? [NSButton class] : nil;
  if (base && class_getMethodImplementation([view class],@selector(drawRect:))
      != class_getMethodImplementation(base,@selector(drawRect:))) return NO;
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
  } else if ([view isKindOfClass:[NSButton class]]) {
    NSButton *button = (id)view;
    NSString *imageName = [[button image] name];
    BOOL check = [imageName isEqual:@"NSSwitch"] || [imageName isEqual:@"NSRadioButton"];
    widget = check
      ? gtk_check_button_new() : [(NSButtonCell *)[button cell] showsStateBy] != NSNoCellMask
      ? gtk_toggle_button_new() : gtk_button_new();
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
    if ([view isKindOfClass:[NSControl class]]) gtk_widget_set_sensitive(widget, [(NSControl *)view isEnabled]);
    if ([view isKindOfClass:[NSTextField class]]) {
      const char *text = [[(NSTextField *)view stringValue] UTF8String] ?: "";
      if (GTK_IS_EDITABLE(widget)) {
        if (strcmp(gtk_editable_get_text(GTK_EDITABLE(widget)), text)) gtk_editable_set_text(GTK_EDITABLE(widget), text);
      } else if (GTK_IS_LABEL(widget) && strcmp(gtk_label_get_text(GTK_LABEL(widget)), text)) {
        gtk_label_set_text(GTK_LABEL(widget), text);
      }
    } else if ([view isKindOfClass:[NSButton class]]) {
      NSButton *button = (id)view;
      const char *title = [[button title] UTF8String] ?: "";
      if (GTK_IS_CHECK_BUTTON(widget)) {
        gtk_check_button_set_label(GTK_CHECK_BUTTON(widget), title);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(widget), [button state] != NSOffState);
      } else {
        gtk_button_set_label(GTK_BUTTON(widget), title);
        if (GTK_IS_TOGGLE_BUTTON(widget)) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(widget), [button state] != NSOffState);
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
  if (_synchronizing) return;
  NSControl *control = g_object_get_data(G_OBJECT(widget), "appkit-view");
  if ([control isKindOfClass:[NSButton class]]) {
    if (GTK_IS_CHECK_BUTTON(widget)) [(NSButton *)control setState:gtk_check_button_get_active(GTK_CHECK_BUTTON(widget)) ? NSOnState : NSOffState];
    else if (GTK_IS_TOGGLE_BUTTON(widget)) [(NSButton *)control setState:gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(widget)) ? NSOnState : NSOffState];
  }
  [control sendAction:[control action] to:[control target]];
}
- (void)dealloc
{
  if (_widget) { if (gtk_widget_get_parent(_widget)) gtk_widget_unparent(_widget); g_object_unref(_widget); }
  [_widgets release]; [_view release]; [super dealloc];
}
@end
