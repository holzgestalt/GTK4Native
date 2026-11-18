#import "GTK4NativeView.h"
#import "GTK4NativeCustomView.h"
#import "GTK4NativeClip.h"
#import "GTK4NativeStepper.h"
#import "GTK4NativeTable.h"
#include <objc/runtime.h>
static char layoutInputKey;
// Retain the initial spring/strut coordinate system across native scene
// replacement and reparenting. Compatibility readback must not become new
// layout input when only part of the source hierarchy has caught up.
static NSArray *layoutInput(NSView *view)
{
  NSArray *input=objc_getAssociatedObject(view,&layoutInputKey);
  if(!input || !NSEqualRects([input[2] rectValue],view.frame)) {
    input=@[[NSValue valueWithRect:view.frame],
      [NSValue valueWithSize:view.superview?view.superview.bounds.size:NSZeroSize],
      [NSValue valueWithRect:view.frame]];
    objc_setAssociatedObject(view,&layoutInputKey,input,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return input;
}
static void rememberReflectedFrame(NSView *view)
{
  NSArray *input=objc_getAssociatedObject(view,&layoutInputKey);
  if(input) objc_setAssociatedObject(view,&layoutInputKey,
    @[input[0],input[1],[NSValue valueWithRect:view.frame]],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static CGFloat splitHoldingPriority(NSSplitViewItem *item)
{
  if(item.holdingPriority>0) return item.holdingPriority;
  // Nibs and compatibility controllers may set a role on a default-initialized
  // item without supplying its role's usual holding priority.
  return item.behavior==NSSplitViewItemBehaviorSidebar?260
    : item.behavior==NSSplitViewItemBehaviorContentList?255:250;
}
static BOOL splitPaneResizes(NSSplitView *split,NSUInteger index)
{
  id delegate=split.delegate;
  NSView *pane=split.subviews[index];
  if([delegate respondsToSelector:@selector(splitView:shouldAdjustSizeOfSubview:)])
    return [delegate splitView:split shouldAdjustSizeOfSubview:pane];
  if([delegate isKindOfClass:[NSSplitViewController class]]) {
    NSArray *items=[delegate splitViewItems];
    if(items.count==split.subviews.count) {
      CGFloat lowest=CGFLOAT_MAX;
      for(NSSplitViewItem *item in items) lowest=MIN(lowest,splitHoldingPriority(item));
      return splitHoldingPriority(items[index])<=lowest;
    }
  }
  if([delegate respondsToSelector:@selector(splitView:resizeSubviewsWithOldSize:)])
    return (pane.autoresizingMask&(split.isVertical?NSViewWidthSizable:NSViewHeightSizable))!=0;
  return YES;
}
// Compile AppKit's sizing policy once. GTK enforces these minima itself while
// dragging or resizing, without consulting delegates during allocation.
static CGFloat splitPaneMinimum(NSSplitView *split,NSUInteger index)
{
  NSView *pane=split.subviews[index];
  NSLayoutAttribute axis=split.isVertical?NSLayoutAttributeWidth:NSLayoutAttributeHeight;
  CGFloat minimum=0;
  for(NSLayoutConstraint *c in [pane.constraints arrayByAddingObjectsFromArray:split.constraints])
    if(c.firstItem==pane && !c.secondItem && c.firstAttribute==axis
        && c.priority>=1000 && c.relation!=NSLayoutRelationLessThanOrEqual)
      minimum=MAX(minimum,c.constant);
  id delegate=split.delegate;
  if([delegate isKindOfClass:[NSSplitViewController class]]) {
    NSArray *items=[delegate splitViewItems];
    if(index<items.count) minimum=MAX(minimum,[(NSSplitViewItem *)items[index] minimumThickness]);
  }
  return minimum;
}
static void splitMinimumRequest(GtkWidget *widget,BOOL vertical,CGFloat minimum,CGFloat scale)
{
  int width,height; gtk_widget_get_size_request(widget,&width,&height);
  if(vertical) width=MAX(width,lround(minimum*scale));
  else height=MAX(height,lround(minimum*scale));
  gtk_widget_set_size_request(widget,width,height);
}
// GTK 4.18's soft-inequality path unrefs its error variable twice. Use a
// nonnegative slack guide and a soft equality instead; all solving stays in GTK.
// Upstream fix: gtkconstraintsolver.c, gtk_constraint_solver_new_expression().
static GtkConstraint *nativeConstraint(GtkConstraintLayout *layout,gpointer target,GtkConstraintAttribute targetAttr,
  GtkConstraintRelation relation,gpointer source,GtkConstraintAttribute sourceAttr,double multiplier,double constant,int strength)
{
  if(gtk_get_major_version()==4 && gtk_get_minor_version()<=18
      && relation!=GTK_CONSTRAINT_RELATION_EQ && strength!=GTK_CONSTRAINT_STRENGTH_REQUIRED) {
    GtkConstraintGuide *slack=gtk_constraint_guide_new();
    gtk_constraint_guide_set_strength(slack,GTK_CONSTRAINT_STRENGTH_WEAK);
    gtk_constraint_layout_add_guide(layout,slack);
    GtkConstraintAttribute bound=relation==GTK_CONSTRAINT_RELATION_GE?GTK_CONSTRAINT_ATTRIBUTE_LEFT:GTK_CONSTRAINT_ATTRIBUTE_RIGHT;
    GtkConstraintAttribute edge=relation==GTK_CONSTRAINT_RELATION_GE?GTK_CONSTRAINT_ATTRIBUTE_RIGHT:GTK_CONSTRAINT_ATTRIBUTE_LEFT;
    gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(slack,bound,GTK_CONSTRAINT_RELATION_EQ,
      source,sourceAttr,multiplier,constant,GTK_CONSTRAINT_STRENGTH_REQUIRED));
    return gtk_constraint_new(target,targetAttr,GTK_CONSTRAINT_RELATION_EQ,slack,edge,1,0,strength);
  }
  return gtk_constraint_new(target,targetAttr,relation,source,sourceAttr,multiplier,constant,strength);
}
/* GTK owns allocation, including translated AppKit constraints and intrinsic
   preferences. AppKit views remain the model/responder objects. */
typedef struct { GtkWidget parent; } GSNativeContainer;
typedef struct { GtkWidgetClass parent; } GSNativeContainerClass;
G_DEFINE_TYPE(GSNativeContainer, gs_native_container, GTK_TYPE_WIDGET)
static void containerDispose(GObject *object)
{
  GtkWidget *child;
  while ((child=gtk_widget_get_first_child(GTK_WIDGET(object)))) gtk_widget_unparent(child);
  gtk_widget_set_layout_manager(GTK_WIDGET(object),NULL);
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
// Legacy drawing-only view compatibility belongs in the provider.
static BOOL compatibilityView(NSView *view,NSString *className)
{
  Class type=NSClassFromString(className);
  return type && [view isKindOfClass:type];
}
// Compile an unambiguous linear arrangement of ordinary source views to GtkBox.
// Use the initial frames, never partially reflected allocations, for ordering.
// Overlapping forms and compound rows retain their full constraint layout.
static NSArray *linearSubviews(NSView *view,GtkOrientation *orientation)
{
  if(view.class!=NSView.class || view.subviews.count<2) return nil;
  // GtkBox sizing below compiles springs/struts. A constrained child without
  // that sizing model must retain its actual constraint relationships.
  for(NSView *child in view.subviews)
    if(!child.translatesAutoresizingMaskIntoConstraints && child.autoresizingMask==NSViewNotSizable) return nil;
  for(int axis=0;axis<2;axis++) {
    BOOL vertical=axis==0;
    NSArray *children=[view.subviews sortedArrayUsingComparator:^NSComparisonResult(NSView *a,NSView *b) {
      NSArray *ia=layoutInput(a),*ib=layoutInput(b);
      NSRect ra=[ia[0] rectValue],rb=[ib[0] rectValue];
      CGFloat pa=vertical?(view.isFlipped?NSMinY(ra):[ia[1] sizeValue].height-NSMaxY(ra)):NSMinX(ra);
      CGFloat pb=vertical?(view.isFlipped?NSMinY(rb):[ib[1] sizeValue].height-NSMaxY(rb)):NSMinX(rb);
      return pa<pb?NSOrderedAscending:pa>pb?NSOrderedDescending:NSOrderedSame;
    }];
    CGFloat end=-CGFLOAT_MAX,crossStart=-CGFLOAT_MAX,crossEnd=CGFLOAT_MAX;
    BOOL linear=YES;
    for(NSView *child in children) {
      NSArray *input=layoutInput(child); NSRect frame=[input[0] rectValue];
      CGFloat start=vertical?(view.isFlipped?NSMinY(frame):[input[1] sizeValue].height-NSMaxY(frame)):NSMinX(frame);
      if(NSIsEmptyRect(frame) || start<end-.5) { linear=NO; break; }
      end=start+(vertical?NSHeight(frame):NSWidth(frame));
      crossStart=MAX(crossStart,vertical?NSMinX(frame):NSMinY(frame));
      crossEnd=MIN(crossEnd,vertical?NSMaxX(frame):NSMaxY(frame));
    }
    if(linear && crossEnd>crossStart) {
      if(orientation) *orientation=vertical?GTK_ORIENTATION_VERTICAL:GTK_ORIENTATION_HORIZONTAL;
      return children;
    }
  }
  return nil;
}
NSArray *GTK4NativeChildrenForView(NSView *view)
{
  NSArray *linear=linearSubviews(view,NULL);
  if(linear) return linear;
  if([view isKindOfClass:[NSTabView class]]) {
    NSMutableArray *pages=[NSMutableArray array];
    for(NSTabViewItem *item in [(NSTabView *)view tabViewItems])
      if(item.view) [pages addObject:item.view];
    return pages;
  }
  if([view isKindOfClass:[NSBox class]]) {
    NSBox *box=(id)view;
    return box.boxType!=NSBoxSeparator && box.contentView?@[box.contentView]:@[];
  }
  return view.subviews;
}
static BOOL containerView(NSView *view)
{
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) return NO;
  if (compatibilityView(view,@"GSWhiteView")) return YES;
  return [view class] == [NSView class] || [view class] == [NSTableCellView class] ||
    (GTK4NativeCanWrapView(view) && ![view isKindOfClass:[NSControl class]]
      && class_getMethodImplementation([view class], @selector(drawRect:)) == class_getMethodImplementation([NSView class], @selector(drawRect:))
      && class_getMethodImplementation([view class], @selector(mouseDown:)) == class_getMethodImplementation([NSView class], @selector(mouseDown:)));
}

static BOOL customView(NSView *view)
{
  if (!GTK4NativeCanWrapView(view) || containerView(view)) return NO;
  Class base = [view isKindOfClass:[NSTabView class]] ? [NSTabView class]
    : [view isKindOfClass:[NSBox class]] ? [NSBox class]
    : [view isKindOfClass:[NSComboBox class]] ? [NSComboBox class]
    : [view isKindOfClass:[NSStepper class]] ? [NSStepper class]
    : [view isKindOfClass:[NSSlider class]] ? [NSSlider class]
    : [view isKindOfClass:[NSProgressIndicator class]] ? [NSProgressIndicator class]
    : [view isKindOfClass:[NSButton class]] ? [NSButton class]
    : [view isKindOfClass:[NSTextField class]] ? [NSTextField class]
    : [view isKindOfClass:[NSImageView class]] ? [NSImageView class]
    : [view isKindOfClass:[NSSwitch class]] ? [NSSwitch class]
    : [view isKindOfClass:[NSSegmentedControl class]] ? [NSSegmentedControl class]
    : [view isKindOfClass:[NSMatrix class]] ? [NSMatrix class] : Nil;
  return !base || class_getMethodImplementation(view.class,@selector(drawRect:)) != class_getMethodImplementation(base,@selector(drawRect:))
    || class_getMethodImplementation(view.class,@selector(mouseDown:)) != class_getMethodImplementation(base,@selector(mouseDown:));
}
static BOOL layoutContainer(NSView *view) { return containerView(view) || customView(view); }

@interface NSTableView (GTK4NativeScene)
- (id)_nativeTableView;
@end
@interface NSPathCell (GTK4NativeScene)
- (void)_setClickedPathComponentCell:(NSPathComponentCell *)cell;
@end
// NSProgressIndicator is a view rather than an NSControl, but its native
// widget has the same themed minimum-size requirements as other controls.
static BOOL nativeControlSize(NSView *view)
{ return [view isKindOfClass:[NSControl class]] || [view isKindOfClass:[NSProgressIndicator class]]; }
static BOOL drawingLeaf(NSView *view)
{ return [view isKindOfClass:[NSTextView class]] || [view isKindOfClass:[NSTableView class]] || [view isKindOfClass:[NSRulerView class]]; }
static void splitPositionChanged(GObject *paned,GParamSpec *spec,gpointer bridge)
{ g_object_set_data(paned,"appkit-split-moved",GINT_TO_POINTER(1)); }
@interface GTK4NativeView (Private)
- (GtkWidget *)build:(NSView *)view;
- (void)configureNativeLayout:(NSView *)view;
- (void)entryChanged:(GtkWidget *)widget;
- (void)scrollChanged:(GtkWidget *)widget;
- (void)activate:(GtkWidget *)widget;
- (void)sliderChanged:(GtkWidget *)widget;
- (void)stepperChanged:(GtkWidget *)widget;
- (void)tabChanged:(GtkWidget *)stack;
- (void)reflectNativeGeometry;
@end
static void entryChanged(GtkEditable *editable, gpointer bridge) { [(GTK4NativeView *)bridge entryChanged:GTK_WIDGET(editable)]; }
static void entryFocusLeft(GtkEventControllerFocus *controller,gpointer data)
{
  GtkWidget *entry=gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
  g_object_set_data(G_OBJECT(entry),"appkit-entry-edit-model",NULL);
  gtk_widget_queue_draw(entry); // The host synchronizes after GTK's callback.
}
static void activated(GtkWidget *widget, gpointer bridge) { [(GTK4NativeView *)bridge activate:widget]; }
static void pullDownActivated(GtkWidget *widget,gpointer bridge)
{
  GtkWidget *popover=gtk_widget_get_ancestor(widget,GTK_TYPE_POPOVER);
  if(popover) gtk_popover_popdown(GTK_POPOVER(popover));
  [(GTK4NativeView *)bridge activate:widget];
}

static void releaseObject(gpointer object);
// Idle commits run after GTK has finished updating selection/text or a drag.
static gboolean deferredEntry(gpointer data)
{
  GtkWidget *widget=data;
  GTK4NativeView *bridge=g_object_get_data(G_OBJECT(widget),"appkit-bridge");
  if (bridge) {
    [bridge retain];
    NSTextField *source=g_object_get_data(G_OBJECT(widget),"appkit-view");
    if (![[source stringValue] isEqualToString:[NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(widget))]])
      [bridge entryChanged:widget];
    [bridge release];
  }
  return G_SOURCE_REMOVE;
}
static void comboEntryChanged(GtkEditable *editable,gpointer bridge)
{ g_idle_add_full(G_PRIORITY_DEFAULT_IDLE,deferredEntry,g_object_ref(editable),g_object_unref); }
static void sliderChanged(GtkRange *range,gpointer bridge)
{ [(GTK4NativeView *)bridge sliderChanged:GTK_WIDGET(range)]; }
static gboolean sliderRelease(gpointer data)
{
  GtkWidget *widget=data;
  GTK4NativeView *bridge=g_object_get_data(G_OBJECT(widget),"appkit-bridge");
  g_object_set_data(G_OBJECT(widget),"appkit-dragging",NULL);
  if (bridge) {
    NSSlider *slider=g_object_get_data(G_OBJECT(widget),"appkit-view");
    NSNumber *start=g_object_get_data(G_OBJECT(widget),"appkit-drag-value");
    if (!slider.isContinuous && start && start.doubleValue!=slider.doubleValue) [bridge activate:widget];
  }
  return G_SOURCE_REMOVE;
}
static gboolean sliderEvent(GtkEventControllerLegacy *controller,GdkEvent *event,gpointer unused)
{
  GtkWidget *widget=gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
  GdkEventType type=gdk_event_get_event_type(event);
  if(type==GDK_BUTTON_PRESS || type==GDK_TOUCH_BEGIN) {
    g_object_set_data(G_OBJECT(widget),"appkit-dragging",GINT_TO_POINTER(1));
    g_object_set_data_full(G_OBJECT(widget),"appkit-drag-value",[[NSNumber numberWithDouble:gtk_range_get_value(GTK_RANGE(widget))] retain],releaseObject);
  } else if(type==GDK_BUTTON_RELEASE || type==GDK_TOUCH_END || type==GDK_TOUCH_CANCEL) {
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE,sliderRelease,g_object_ref(widget),g_object_unref);
  }
  return FALSE;
}
static void stepperChanged(GtkSpinButton *widget,gpointer bridge)
{ [(GTK4NativeView *)bridge stepperChanged:GTK_WIDGET(widget)]; }
static gboolean stepperEvent(GtkEventControllerLegacy *controller,GdkEvent *event,gpointer unused)
{
  GtkWidget *widget=gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
  GdkEventType type=gdk_event_get_event_type(event);
  if(type==GDK_BUTTON_PRESS || type==GDK_TOUCH_BEGIN) {
    g_object_set_data(G_OBJECT(widget),"appkit-stepper-held",GINT_TO_POINTER(1));
    g_object_set_data(G_OBJECT(widget),"appkit-stepper-stepped",NULL);
  } else if(type==GDK_BUTTON_RELEASE || type==GDK_TOUCH_END || type==GDK_TOUCH_CANCEL) {
    g_object_set_data(G_OBJECT(widget),"appkit-stepper-held",NULL);
  }
  return FALSE;
}
static guint decimalDigits(double value)
{
  for(guint digits=0;digits<8;digits++,value*=10)
    if(fabs(value-round(value))<1e-7) return digits;
  return 8;
}
static gboolean progressTick(GtkWidget *widget,GdkFrameClock *clock,gpointer unused)
{
  NSProgressIndicator *source=g_object_get_data(G_OBJECT(widget),"appkit-view");
  if (!g_object_get_data(G_OBJECT(widget),"appkit-bridge")) return G_SOURCE_REMOVE;
  if (source.isAnimating && source.isIndeterminate && gtk_widget_get_mapped(widget)) {
    gint64 now=gdk_frame_clock_get_frame_time(clock);
    NSNumber *last=g_object_get_data(G_OBJECT(widget),"appkit-pulse-time");
    if (!last || now-last.longLongValue>=MAX(.02,source.animationDelay)*1000000) {
      gtk_progress_bar_pulse(GTK_PROGRESS_BAR(widget));
      g_object_set_data_full(G_OBJECT(widget),"appkit-pulse-time",[[NSNumber numberWithLongLong:now] retain],releaseObject);
    }
  }
  return G_SOURCE_CONTINUE;
}
static void tabChanged(GObject *stack,GParamSpec *spec,gpointer bridge)
{ [(GTK4NativeView *)bridge tabChanged:GTK_WIDGET(stack)]; }
static void scrollChanged(GtkAdjustment *adjustment,gpointer bridge)
{
  GtkWidget *widget=g_object_get_data(G_OBJECT(adjustment),"appkit-scroll-widget");
  // Adjustment clamping can happen inside GTK allocation. Copy the result to
  // AppKit only when the host next synchronizes outside GTK's frame.
  if(widget) g_object_set_data(G_OBJECT(widget),"appkit-scroll-moved",GINT_TO_POINTER(1));
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

// Deliver focus-out while the editor is still sensitive. GtkText inside a
// composite widget otherwise misses that transition when its parent disables.
static void controlSensitive(GtkWidget *widget,gboolean enabled)
{
  if(!enabled && gtk_widget_get_sensitive(widget)) {
    GtkRoot *root=gtk_widget_get_root(widget);
    GtkWidget *focus=root?gtk_root_get_focus(root):NULL;
    if(focus && (focus==widget || gtk_widget_is_ancestor(focus,widget))) gtk_root_set_focus(root,NULL);
  }
  gtk_widget_set_sensitive(widget,enabled);
}
static void entryFont(GtkWidget *entry,NSFont *font,CGFloat scale,GtkWidget *combo)
{
  NSArray *signature=@[font.fontName?:@"",@(font.pointSize),@(scale)];
  if([signature isEqual:(id)g_object_get_data(G_OBJECT(entry),"appkit-entry-font")]) return;
  g_object_set_data_full(G_OBJECT(entry),"appkit-entry-font",[signature copy],releaseObject);
  PangoFontDescription *description=NULL;
  PangoAttrList *attributes=pango_attr_list_new();
  if(font) {
    description=pango_font_description_new();
    if(font.familyName) pango_font_description_set_family(description,font.familyName.UTF8String);
    NSFontTraitMask traits=[[NSFontManager sharedFontManager] traitsOfFont:font];
    pango_font_description_set_weight(description,(traits&NSBoldFontMask)?PANGO_WEIGHT_BOLD:PANGO_WEIGHT_NORMAL);
    pango_font_description_set_style(description,(traits&NSItalicFontMask)?PANGO_STYLE_ITALIC:PANGO_STYLE_NORMAL);
    // AppKit points have already been converted to GTK logical units. Pango
    // point sizes would apply the desktop DPI conversion a second time.
    pango_font_description_set_absolute_size(description,font.pointSize*scale*PANGO_SCALE);
    pango_attr_list_insert(attributes,pango_attr_font_desc_new(description));
  }
  gtk_entry_set_attributes(GTK_ENTRY(entry),attributes);
  pango_attr_list_unref(attributes);
  if(combo) {
    GList *cells=gtk_cell_layout_get_cells(GTK_CELL_LAYOUT(combo));
    for(GList *cell=cells;cell;cell=cell->next)
      if(GTK_IS_CELL_RENDERER_TEXT(cell->data)) g_object_set(cell->data,"font-desc",description,NULL);
    g_list_free(cells);
  }
  if(description) pango_font_description_free(description);
}
static void compactCombo(GtkWidget *widget)
{
  GdkDisplay *display=gtk_widget_get_display(widget);
  if(!g_object_get_data(G_OBJECT(display),"appkit-compact-combo-style")) {
    GtkCssProvider *provider=gtk_css_provider_new();
    // Keep GTK's theme colors, borders, arrow and popup. Only remove the
    // default 34px minimum and vertical padding from AppKit combo peers.
    gtk_css_provider_load_from_data(provider,
      "combobox.gnustep-compact-combo { min-height: 0; }"
      "combobox.gnustep-compact-combo > box > entry,"
      "combobox.gnustep-compact-combo > box > button {"
      " min-height: 0; padding-top: 0; padding-bottom: 0; }",-1);
    gtk_style_context_add_provider_for_display(display,GTK_STYLE_PROVIDER(provider),GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display),"appkit-compact-combo-style",provider,g_object_unref);
  }
  gtk_widget_add_css_class(widget,"gnustep-compact-combo");
}
static void compactEntry(GtkWidget *widget)
{
  // Let GTK fit a constrained XIB slot without clipping its native border or
  // text. Fonts, colors, focus indication and all rendering remain GTK's.
  GdkDisplay *display=gtk_widget_get_display(widget);
  if(!g_object_get_data(G_OBJECT(display),"appkit-compact-entry-style")) {
    GtkCssProvider *provider=gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider,"entry.gnustep-compact-entry { min-height: 0; padding-top: 0; padding-bottom: 0; }",-1);
    gtk_style_context_add_provider_for_display(display,GTK_STYLE_PROVIDER(provider),GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display),"appkit-compact-entry-style",provider,g_object_unref);
  }
  gtk_widget_add_css_class(widget,"gnustep-compact-entry");
}
static BOOL radioCell(NSButtonCell *cell) { return [cell image] && [cell image] == [NSImage imageNamed:@"NSRadioButton"]; }
static BOOL checkCell(NSButtonCell *cell)
{
  return ([cell image] && [cell image] == [NSImage imageNamed:@"NSSwitch"]) || radioCell(cell);
}
static void releaseObject(gpointer object) { [(id)object release]; }
static void pathClicked(GtkButton *button,gpointer data)
{
  id bridge=[(id)data retain];
  NSPathControl *path=[(id)g_object_get_data(G_OBJECT(button),"appkit-path") retain];
  NSPathComponentCell *cell=[(id)g_object_get_data(G_OBJECT(button),"appkit-path-cell") retain];
  @try { [(NSPathCell *)path.cell _setClickedPathComponentCell:cell]; [path sendAction:path.action to:path.target]; }
  @finally { [cell release]; [path release]; [bridge release]; }
}
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

static void pathContent(GtkWidget *widget,NSPathControl *path,gpointer bridge,CGFloat scale)
{
  NSMutableArray *signature=[NSMutableArray array];
  for(NSPathComponentCell *cell in path.pathComponentCells)
    [signature addObject:@[[NSValue valueWithPointer:cell],cell.title?:@"",cell.URL?:[NSNull null]]];
  if(![signature isEqual:(id)g_object_get_data(G_OBJECT(widget),"appkit-path-components")]) {
    GtkWidget *child;
    while((child=gtk_widget_get_first_child(widget))) gtk_box_remove(GTK_BOX(widget),child);
    NSUInteger index=0;
    for(NSPathComponentCell *cell in path.pathComponentCells) {
      if(index++) gtk_box_append(GTK_BOX(widget),gtk_image_new_from_icon_name("pan-end-symbolic"));
      GtkWidget *button=gtk_button_new(); gtk_widget_add_css_class(button,"flat");
      buttonContent(button,cell.title?:@"",cell.image,NSImageLeft,NSRoundRectBezelStyle,scale);
      gtk_widget_set_focusable(button,FALSE);
      g_object_set_data(G_OBJECT(button),"appkit-path",path);
      g_object_set_data_full(G_OBJECT(button),"appkit-path-cell",[cell retain],releaseObject);
      g_signal_connect(button,"clicked",G_CALLBACK(pathClicked),bridge);
      gtk_box_append(GTK_BOX(widget),button);
    }
    g_object_set_data_full(G_OBJECT(widget),"appkit-path-components",[signature copy],releaseObject);
  }
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
  if ([view isKindOfClass:[NSTableView class]] && g_strcmp0(g_getenv("GTK4_NATIVE_TABLES"),"0")==0) return NO;
  if (drawingLeaf(view)) return YES;
  if ([view isKindOfClass:[NSSplitView class]]) {
    for (NSView *pane in view.subviews) if (![self supportsView:pane]) return NO;
    return YES;
  }
  if ([view isKindOfClass:[NSScrollView class]]) {
    NSScrollView *scroll=(id)view;
    return scroll.documentView && [self supportsView:scroll.documentView];
  }
  if([view isKindOfClass:[NSPathControl class]]) return [(NSPathControl *)view pathStyle]==NSPathStyleStandard;
  BOOL control = [view isKindOfClass:[NSTabView class]] || [view isKindOfClass:[NSBox class]] || [view isKindOfClass:[NSStepper class]] || [view isKindOfClass:[NSSlider class]] || [view isKindOfClass:[NSProgressIndicator class]] || [view isKindOfClass:[NSTextField class]] || [view isKindOfClass:[NSImageView class]]
    || [view isKindOfClass:[NSButton class]] || [view isKindOfClass:[NSSwitch class]]
    || [view isKindOfClass:[NSSegmentedControl class]] || [view isKindOfClass:[NSMatrix class]];
  if([view isKindOfClass:[NSBox class]]) {
    NSBox *box=(id)view;
    // Explicit colors/custom borders have no GtkFrame equivalent.
    if(box.boxType==NSBoxSeparator && [(NSView *)box.contentView subviews].count) return NO;
    if(box.boxType!=NSBoxSeparator && box.titlePosition>=NSAboveBottom) return NO;
  }
  BOOL wrapped=customView(view);
  if (!control && !containerView(view) && !wrapped) return NO;
  if ([view isKindOfClass:[NSPopUpButton class]]) {
    for (id<NSMenuItem> item in [(NSPopUpButton *)view itemArray])
      if ([item hasSubmenu] || (![(NSPopUpButton *)view pullsDown] && ([item isSeparatorItem]
          || ([item image] && [item image] != [NSImage imageNamed:@"common_Nibble"])))) return NO;
  }
  // Explicit context menus keep the existing menu-tracking path for now.
  if ([view isKindOfClass:[NSButton class]] && ![view isKindOfClass:[NSPopUpButton class]] && [view menu]) return NO;
  if ([view isKindOfClass:[NSTextField class]] && [(NSTextField *)view isEditable]
      && [(NSTextField *)view formatter] && ![[(NSTextField *)view formatter] isKindOfClass:[NSNumberFormatter class]]) return NO;
  if ([view isKindOfClass:[NSMatrix class]]) {
    if ([(NSMatrix *)view mode] != NSRadioModeMatrix) return NO;
    for (NSCell *cell in [(NSMatrix *)view cells])
      if (![cell isKindOfClass:[NSButtonCell class]] || !radioCell((id)cell)) return NO;
  }
  Class base = [view isKindOfClass:[NSTabView class]] ? [NSTabView class]
    : [view isKindOfClass:[NSBox class]] ? [NSBox class]
    : [view isKindOfClass:[NSComboBox class]] ? [NSComboBox class]
    : [view isKindOfClass:[NSStepper class]] ? [NSStepper class]
    : [view isKindOfClass:[NSSlider class]] ? [NSSlider class]
    : [view isKindOfClass:[NSProgressIndicator class]] ? [NSProgressIndicator class]
    : [view isKindOfClass:[NSTextField class]] ? [NSTextField class]
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
  for (NSView *child in GTK4NativeChildrenForView(view)) if (![self supportsView:child]) return NO;
  return YES;
}
- (id)initWithView:(NSView *)view scale:(CGFloat)scale
{
  if (![GTK4NativeView supportsView:view]) { [self release]; return nil; }
  if ((self = [super init])) {
    _view = [view retain]; _scale = scale;
    _embeddedTables=[NSMutableArray new];
    _widgets = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
      | NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory capacity:8];
    _widget = [self build:view];
    if (!_widget) { [self release]; return nil; }
    g_object_ref_sink(_widget);
    for (GTK4NativeTable *table in _embeddedTables) if (table.widget==_widget) _borrowedRoot=YES;
    [self synchronize];
    for (NSView *source in _widgets) {
      if ([source isKindOfClass:[NSTableView class]] && [source valueForKey:@"_nativeTableView"]) continue;
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
  NSArray *input=layoutInput(view);
  GtkWidget *widget = NULL;
  if ([view respondsToSelector:@selector(gtk4NativeWidget)]) widget = [(id<GTK4NativeCustomView>)view gtk4NativeWidget];
  else if ([view isKindOfClass:[NSSplitView class]]) {
    NSSplitView *split=(id)view;
    NSArray *panes=split.subviews;
    if(panes.count<2) {
      widget=gtk_paned_new(split.isVertical?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL);
      gtk_paned_set_shrink_start_child(GTK_PANED(widget),FALSE);
      gtk_paned_set_shrink_end_child(GTK_PANED(widget),FALSE);
      if(panes.count) {
        GtkWidget *child=[self build:panes[0]];
        gtk_paned_set_start_child(GTK_PANED(widget),child);
        g_object_set_data(G_OBJECT(child),"appkit-content-owner",view);
      }
    } else {
    GtkWidget *previous=NULL;
    for (NSUInteger i=0;i+1<panes.count;i++) {
      GtkWidget *paned=gtk_paned_new(split.isVertical?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL);
      g_object_set_data(G_OBJECT(paned),"appkit-view",view);
      g_object_set_data(G_OBJECT(paned),"appkit-split-index",GUINT_TO_POINTER(i));
      g_object_set_data(G_OBJECT(paned),"appkit-bridge",self);
      NSView *pane=panes[i];
      GtkWidget *child=[self build:pane];
      CGFloat startMinimum=splitPaneMinimum(split,i),endMinimum=0;
      for(NSUInteger remaining=i+1;remaining<panes.count;remaining++)
        endMinimum+=splitPaneMinimum(split,remaining);
      CGFloat extent=split.isVertical?NSWidth(split.bounds):NSHeight(split.bounds);
      CGFloat offset=split.isVertical?NSMinX(pane.frame):NSMinY(pane.frame);
      id delegate=split.delegate;
      if([delegate respondsToSelector:@selector(splitView:constrainMinCoordinate:ofSubviewAt:)])
        startMinimum=MAX(startMinimum,[delegate splitView:split constrainMinCoordinate:offset ofSubviewAt:i]-offset);
      if([delegate respondsToSelector:@selector(splitView:constrainMaxCoordinate:ofSubviewAt:)])
        endMinimum=MAX(endMinimum,extent-[delegate splitView:split constrainMaxCoordinate:extent ofSubviewAt:i]);
      splitMinimumRequest(child,split.isVertical,startMinimum,_scale);
      g_object_set_data(G_OBJECT(paned),"appkit-end-minimum",GINT_TO_POINTER(MAX(0,lround(endMinimum*_scale))));
      gtk_paned_set_shrink_start_child(GTK_PANED(paned),FALSE);
      gtk_paned_set_shrink_end_child(GTK_PANED(paned),FALSE);
      gtk_paned_set_start_child(GTK_PANED(paned),child);
      g_object_set_data(G_OBJECT(child),"appkit-content-owner",view);
      gtk_paned_set_resize_start_child(GTK_PANED(paned),splitPaneResizes(split,i));
      BOOL resizeEnd=NO;
      for(NSUInteger remaining=i+1;remaining<panes.count;remaining++)
        resizeEnd|=splitPaneResizes(split,remaining);
      gtk_paned_set_resize_end_child(GTK_PANED(paned),resizeEnd);
      CGFloat size=split.isVertical?NSWidth(pane.frame):NSHeight(pane.frame);
      gtk_paned_set_position(GTK_PANED(paned),lround(size*_scale));
      if (previous) {
        splitMinimumRequest(paned,split.isVertical,GPOINTER_TO_INT(g_object_get_data(G_OBJECT(previous),"appkit-end-minimum")),1);
        gtk_paned_set_end_child(GTK_PANED(previous),paned);
      } else widget=paned;
      previous=paned;
      g_signal_connect(paned,"notify::position",G_CALLBACK(splitPositionChanged),self);
    }
    GtkWidget *last=[self build:panes.lastObject];
    splitMinimumRequest(last,split.isVertical,GPOINTER_TO_INT(g_object_get_data(G_OBJECT(previous),"appkit-end-minimum")),1);
    gtk_paned_set_end_child(GTK_PANED(previous),last);
    g_object_set_data(G_OBJECT(last),"appkit-content-owner",view);
    }
    g_object_set_data_full(G_OBJECT(widget),"appkit-split-panes",[panes copy],releaseObject);
  }
  else if ([view isKindOfClass:[NSScrollView class]]) {
    NSScrollView *scroll=(id)view;
    GTK4NativeTable *table=[scroll.documentView isKindOfClass:[NSTableView class]]?[(NSTableView *)scroll.documentView _nativeTableView]:nil;
    if (table) {
      widget=[table embed];
      [_embeddedTables addObject:table];
      [_widgets setObject:[NSValue valueWithPointer:table->_list] forKey:scroll.documentView];
      g_object_set_data(G_OBJECT(widget),"appkit-native-table",table);
    } else {
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
    if(scroll.rulersVisible) {
      GtkWidget *scroller=widget,*grid=gtk_grid_new();
      gtk_widget_set_hexpand(scroller,TRUE); gtk_widget_set_vexpand(scroller,TRUE);
      gtk_grid_attach(GTK_GRID(grid),scroller,1,1,1,1);
      if(scroll.hasVerticalRuler && scroll.verticalRulerView) {
        GtkWidget *ruler=[self build:scroll.verticalRulerView];
        gtk_widget_set_size_request(ruler,MAX(1,lround(NSWidth(scroll.verticalRulerView.frame)*_scale)),-1);
        gtk_grid_attach(GTK_GRID(grid),ruler,0,1,1,1);
      }
      if(scroll.hasHorizontalRuler && scroll.horizontalRulerView) {
        GtkWidget *ruler=[self build:scroll.horizontalRulerView];
        gtk_widget_set_size_request(ruler,-1,MAX(1,lround(NSHeight(scroll.horizontalRulerView.frame)*_scale)));
        gtk_grid_attach(GTK_GRID(grid),ruler,1,0,1,1);
      }
      g_object_set_data(G_OBJECT(scroller),"appkit-view",view);
      g_object_set_data(G_OBJECT(scroller),"appkit-bridge",self);
      g_object_set_data(G_OBJECT(grid),"appkit-scroll-widget",scroller);
      widget=grid;
    }
  }
  else if ([view isKindOfClass:[NSTabView class]]) {
    NSTabView *tabs=(id)view;
    BOOL side=tabs.tabViewType==NSLeftTabsBezelBorder || tabs.tabViewType==NSRightTabsBezelBorder;
    BOOL after=tabs.tabViewType==NSBottomTabsBezelBorder || tabs.tabViewType==NSRightTabsBezelBorder;
    widget=gtk_box_new(side?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,0);
    GtkWidget *stack=gtk_stack_new();
    gtk_stack_set_hhomogeneous(GTK_STACK(stack),FALSE);
    gtk_stack_set_vhomogeneous(GTK_STACK(stack),FALSE);
    gtk_stack_set_transition_type(GTK_STACK(stack),GTK_STACK_TRANSITION_TYPE_NONE);
    gtk_widget_set_hexpand(stack,TRUE); gtk_widget_set_vexpand(stack,TRUE);
    gtk_widget_set_overflow(stack,GTK_OVERFLOW_HIDDEN);
    g_object_set_data(G_OBJECT(widget),"appkit-tab-stack",stack);
    g_object_set_data(G_OBJECT(stack),"appkit-view",view);
    g_object_set_data(G_OBJECT(stack),"appkit-bridge",self);
    g_object_set_data_full(G_OBJECT(stack),"appkit-tab-items",[tabs.tabViewItems copy],releaseObject);
    NSUInteger index=0;
    for(NSTabViewItem *item in tabs.tabViewItems) {
      GtkWidget *page=item.view?[self build:item.view]:g_object_new(gs_native_container_get_type(),NULL);
      NSString *name=[NSString stringWithFormat:@"tab-%lu",(unsigned long)index++];
      GtkStackPage *stackPage=gtk_stack_add_titled(GTK_STACK(stack),page,name.UTF8String,(item.label?:@"").UTF8String);
      g_object_set_data(G_OBJECT(page),"appkit-tab-item",item);
      if(item.view) g_object_set_data(G_OBJECT(page),"appkit-content-owner",view);
      (void)stackPage;
    }
    GtkWidget *navigation=side?gtk_stack_sidebar_new():gtk_stack_switcher_new();
    if(side) gtk_stack_sidebar_set_stack(GTK_STACK_SIDEBAR(navigation),GTK_STACK(stack));
    else {
      gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(navigation),GTK_STACK(stack));
      gtk_widget_set_halign(navigation,GTK_ALIGN_START);
    }
    g_object_set_data(G_OBJECT(widget),"appkit-tab-navigation",navigation);
    gtk_widget_set_visible(navigation,tabs.tabViewType<=NSRightTabsBezelBorder && tabs.tabViewItems.count>0);
    GtkWidget *body=stack;
    if(tabs.tabViewType!=NSNoTabsNoBorder) {
      body=gtk_frame_new(NULL); gtk_frame_set_child(GTK_FRAME(body),stack);
      gtk_widget_set_hexpand(body,TRUE); gtk_widget_set_vexpand(body,TRUE);
    }
    gtk_box_append(GTK_BOX(widget),after?body:navigation);
    gtk_box_append(GTK_BOX(widget),after?navigation:body);
    g_signal_connect(stack,"notify::visible-child",G_CALLBACK(tabChanged),self);
  }
  else if ([view isKindOfClass:[NSBox class]]) {
    NSBox *box=(id)view;
    if(box.boxType==NSBoxSeparator)
      widget=gtk_separator_new(NSWidth(box.bounds)>=NSHeight(box.bounds)?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL);
    else {
      widget=box.borderType==NSNoBorder?gtk_box_new(GTK_ORIENTATION_VERTICAL,0)
        :gtk_frame_new(box.titlePosition==NSNoTitle?NULL:(box.title?:@"").UTF8String);
      if(box.contentView) {
        GtkWidget *content=[self build:box.contentView];
        gtk_widget_set_margin_start(content,MAX(0,lround(box.contentViewMargins.width*_scale)));
        gtk_widget_set_margin_end(content,MAX(0,lround(box.contentViewMargins.width*_scale)));
        gtk_widget_set_margin_top(content,MAX(0,lround(box.contentViewMargins.height*_scale)));
        gtk_widget_set_margin_bottom(content,MAX(0,lround(box.contentViewMargins.height*_scale)));
        gtk_widget_set_hexpand(content,TRUE); gtk_widget_set_vexpand(content,TRUE);
        g_object_set_data(G_OBJECT(content),"appkit-content-owner",view);
        if(GTK_IS_FRAME(widget)) gtk_frame_set_child(GTK_FRAME(widget),content);
        else gtk_box_append(GTK_BOX(widget),content);
        g_object_set_data(G_OBJECT(widget),"appkit-box-content",content);
      }
    }
  }
  else if ([view isKindOfClass:[NSPathControl class]]) {
    widget=gtk_box_new(GTK_ORIENTATION_HORIZONTAL,0);
    pathContent(widget,(NSPathControl *)view,self,_scale);
  }
  else if (customView(view) || drawingLeaf(view)) widget=GTK4NativeCustomViewNew(view,_scale);
  else if ([view isKindOfClass:[NSComboBox class]]) {
    widget=gtk_combo_box_text_new_with_entry();
    compactCombo(widget);
    GtkWidget *entry=gtk_combo_box_get_child(GTK_COMBO_BOX(widget));
    entryFont(entry,[(NSComboBox *)view font],_scale,widget);
    g_object_set_data(G_OBJECT(entry),"appkit-view",view);
    g_object_set_data(G_OBJECT(entry),"appkit-bridge",self);
    g_signal_connect(entry,"changed",G_CALLBACK(comboEntryChanged),self);
    g_signal_connect(entry,"activate",G_CALLBACK(activated),self);
    g_signal_connect(widget,"changed",G_CALLBACK(activated),self);
  } else if ([view isKindOfClass:[NSStepper class]]) {
    if(![(NSStepper *)view gtk4NativeUsesSpinButton]) {
      widget=GTK4NativeStepperNew(_scale);
      g_signal_connect(widget,"value-changed",G_CALLBACK(stepperChanged),self);
    } else {
      widget=gtk_spin_button_new_with_range(0,100,1);
      gtk_spin_button_set_numeric(GTK_SPIN_BUTTON(widget),TRUE);
      gtk_spin_button_set_update_policy(GTK_SPIN_BUTTON(widget),GTK_UPDATE_IF_VALID);
      gtk_spin_button_set_climb_rate(GTK_SPIN_BUTTON(widget),0);
      gtk_editable_set_width_chars(GTK_EDITABLE(widget),4);
      g_signal_connect(widget,"value-changed",G_CALLBACK(stepperChanged),self);
      GtkEventController *events=gtk_event_controller_legacy_new();
      gtk_event_controller_set_propagation_phase(events,GTK_PHASE_CAPTURE);
      g_signal_connect(events,"event",G_CALLBACK(stepperEvent),NULL);
      gtk_widget_add_controller(widget,events);
    }
  } else if ([view isKindOfClass:[NSSlider class]]) {
    BOOL vertical=NSHeight(view.bounds)>NSWidth(view.bounds) && [(NSSliderCell *)[(NSSlider *)view cell] sliderType]!=NSCircularSlider;
    widget=gtk_scale_new_with_range(vertical?GTK_ORIENTATION_VERTICAL:GTK_ORIENTATION_HORIZONTAL,0,1,.01);
    gtk_scale_set_draw_value(GTK_SCALE(widget),FALSE);
    gtk_range_set_inverted(GTK_RANGE(widget),vertical);
    g_signal_connect(widget,"value-changed",G_CALLBACK(sliderChanged),self);
    GtkEventController *events=gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(events,GTK_PHASE_CAPTURE);
    g_signal_connect(events,"event",G_CALLBACK(sliderEvent),NULL);
    gtk_widget_add_controller(widget,events);
  } else if ([view isKindOfClass:[NSProgressIndicator class]]) {
    NSProgressIndicator *progress=(id)view;
    widget=progress.style==NSProgressIndicatorSpinningStyle && progress.isIndeterminate?gtk_spinner_new():gtk_progress_bar_new();
  }
  else if ([view isKindOfClass:[NSTextField class]]) {
    NSTextField *field = (id)view;
    widget = [field isEditable] ? gtk_entry_new() : gtk_label_new([[field stringValue] UTF8String]);
    if ([field isEditable]) {
      compactEntry(widget);
      entryFont(widget,field.font,_scale,NULL);
      if ([field isKindOfClass:[NSSecureTextField class]]) gtk_entry_set_visibility(GTK_ENTRY(widget),FALSE);
      g_signal_connect(widget, "changed", G_CALLBACK(entryChanged), self);
      g_signal_connect(widget, "activate", G_CALLBACK(activated), self);
      GtkEventController *focus=gtk_event_controller_focus_new();
      g_signal_connect(focus,"leave",G_CALLBACK(entryFocusLeft),NULL);
      gtk_widget_add_controller(widget,focus);
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
    if ([view respondsToSelector:@selector(gtk4NativeIconName)]) {
      widget = gtk_image_new();
      gtk_widget_set_valign(widget, GTK_ALIGN_CENTER);
    } else {
      widget = gtk_picture_new();
      gtk_picture_set_can_shrink(GTK_PICTURE(widget), TRUE);
      gtk_picture_set_content_fit(GTK_PICTURE(widget), GTK_CONTENT_FIT_CONTAIN);
    }
  } else if ([view isKindOfClass:[NSPopUpButton class]]) {
    if([(NSPopUpButton *)view pullsDown]) widget=gtk_menu_button_new();
    else {
    widget = gtk_drop_down_new(NULL, NULL);
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_object_set_data_full(G_OBJECT(factory), "appkit-popup", [view retain], releaseObject);
    g_signal_connect(factory, "setup", G_CALLBACK(popupItemSetup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(popupItemBind), NULL);
    gtk_drop_down_set_list_factory(GTK_DROP_DOWN(widget), factory);
    g_object_unref(factory);
    g_signal_connect(widget, "notify::selected", G_CALLBACK(dropdownChanged), self);
    }
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
    widget = gtk_grid_new();
    gtk_grid_set_column_homogeneous(GTK_GRID(widget),TRUE);
    gtk_grid_set_row_homogeneous(GTK_GRID(widget),TRUE);
    gtk_grid_set_column_spacing(GTK_GRID(widget),MAX(0,lround(matrix.intercellSpacing.width*_scale)));
    gtk_grid_set_row_spacing(GTK_GRID(widget),MAX(0,lround(matrix.intercellSpacing.height*_scale)));
    GtkCheckButton *group = NULL;
    for (NSInteger row = 0; row < [matrix numberOfRows]; row++)
      for (NSInteger col = 0; col < [matrix numberOfColumns]; col++) {
        NSButtonCell *cell = [matrix cellAtRow:row column:col];
        GtkWidget *radio = gtk_check_button_new_with_label([[cell title] UTF8String]);
        if (group) gtk_check_button_set_group(GTK_CHECK_BUTTON(radio), group);
        else group = GTK_CHECK_BUTTON(radio);
        g_object_set_data(G_OBJECT(radio), "appkit-view", view);
        g_object_set_data(G_OBJECT(radio), "appkit-cell", cell);
        gtk_widget_set_hexpand(radio,TRUE);
        gtk_widget_set_vexpand(radio,TRUE);
        gtk_grid_attach(GTK_GRID(widget),radio,(int)col,(int)row,1,1);
        g_signal_connect(radio, "toggled", G_CALLBACK(activated), self);
      }
  } else if ([view isKindOfClass:[NSButton class]]) {
    NSButtonCell *cell = [(NSButton *)view cell];
    widget = checkCell(cell) ? gtk_check_button_new()
      : [cell showsStateBy] != NSNoCellMask ? gtk_toggle_button_new() : gtk_button_new();
    NSButton *button=(id)view;
    if(GTK_IS_CHECK_BUTTON(widget)) gtk_check_button_set_label(GTK_CHECK_BUTTON(widget),button.title.UTF8String);
    else buttonContent(widget,button.title,button.image,button.imagePosition,button.bezelStyle,_scale);
    g_signal_connect(widget, GTK_IS_CHECK_BUTTON(widget) ? "toggled" : "clicked", G_CALLBACK(activated), self);
  } else if (containerView(view)) {
    BOOL fillingChild=NO;
    if(view.constraints.count==0 && view.subviews.count==1) {
      NSView *child=view.subviews[0]; NSArray *childInput=layoutInput(child);
      NSRect rect=[childInput[0] rectValue]; NSSize parent=[childInput[1] sizeValue];
      fillingChild=child.translatesAutoresizingMaskIntoConstraints
        && (child.autoresizingMask&(NSViewWidthSizable|NSViewHeightSizable))==(NSViewWidthSizable|NSViewHeightSizable)
        && fabs(rect.origin.x)<1 && fabs(rect.origin.y)<1
        && fabs(rect.size.width-parent.width)<1 && fabs(rect.size.height-parent.height)<1;
    }
    GtkOrientation stackOrientation=GTK_ORIENTATION_VERTICAL;
    NSArray *linear=linearSubviews(view,&stackOrientation);
    if(linear || fillingChild) {
      BOOL vertical=fillingChild || stackOrientation==GTK_ORIENTATION_VERTICAL;
      widget=gtk_box_new(vertical?GTK_ORIENTATION_VERTICAL:GTK_ORIENTATION_HORIZONTAL,0);
      g_object_set_data(G_OBJECT(widget),"appkit-native-stack",GINT_TO_POINTER(1));
    } else widget = g_object_new(gs_native_container_get_type(), NULL);
  }
  if (!widget) return NULL;
  [_widgets setObject:[NSValue valueWithPointer:widget] forKey:view];
  g_object_set_data(G_OBJECT(widget), "appkit-view", view);
  g_object_set_data_full(G_OBJECT(widget),"appkit-source-frame",[input[0] retain],releaseObject);
  g_object_set_data_full(G_OBJECT(widget),"appkit-reflected-frame",[[NSValue valueWithRect:view.frame] retain],releaseObject);
  if ([view identifier]) gtk_widget_set_name(widget, [[view identifier] UTF8String]);
  g_object_set_data(G_OBJECT(widget),"appkit-bridge",self);
  if (layoutContainer(view) && ![view isKindOfClass:[NSSplitView class]] && !drawingLeaf(view)) {
    BOOL stack=g_object_get_data(G_OBJECT(widget),"appkit-native-stack")!=NULL;
    CGFloat previousEnd=0;
    if (customView(view) && !stack) gtk_widget_set_layout_manager(widget,gtk_constraint_layout_new());
    for (NSView *child in GTK4NativeChildrenForView(view)) {
      GtkWidget *nativeChild = [self build:child];
      if (!nativeChild) { g_object_ref_sink(widget); g_object_unref(widget); return NULL; }
      if(stack) {
        BOOL vertical=gtk_orientable_get_orientation(GTK_ORIENTABLE(widget))==GTK_ORIENTATION_VERTICAL;
        gtk_widget_set_hexpand(nativeChild,(child.autoresizingMask&NSViewWidthSizable)!=0);
        gtk_widget_set_vexpand(nativeChild,(child.autoresizingMask&NSViewHeightSizable)!=0);
        NSRect initial=[layoutInput(child)[0] rectValue];
        NSSize parentSize=[layoutInput(child)[1] sizeValue];
        NSUInteger mask=child.autoresizingMask;
        CGFloat top=view.isFlipped?NSMinY(initial):parentSize.height-NSMaxY(initial);
        if(vertical) {
          gtk_widget_set_margin_top(nativeChild,MAX(0,lround((top-previousEnd)*_scale)));
          previousEnd=top+NSHeight(initial);
          gtk_widget_set_margin_start(nativeChild,(mask&NSViewMinXMargin)?0:MAX(0,lround(NSMinX(initial)*_scale)));
          gtk_widget_set_margin_end(nativeChild,(mask&NSViewMaxXMargin)?0:MAX(0,lround((parentSize.width-NSMaxX(initial))*_scale)));
          if(!(mask&NSViewWidthSizable)) gtk_widget_set_halign(nativeChild,(mask&NSViewMinXMargin)?((mask&NSViewMaxXMargin)?GTK_ALIGN_CENTER:GTK_ALIGN_END):GTK_ALIGN_START);
        } else {
          gtk_widget_set_margin_start(nativeChild,MAX(0,lround((NSMinX(initial)-previousEnd)*_scale)));
          previousEnd=NSMaxX(initial);
          BOOL topFlexible=(mask&(view.isFlipped?NSViewMinYMargin:NSViewMaxYMargin))!=0;
          BOOL bottomFlexible=(mask&(view.isFlipped?NSViewMaxYMargin:NSViewMinYMargin))!=0;
          gtk_widget_set_margin_top(nativeChild,topFlexible?0:MAX(0,lround(top*_scale)));
          gtk_widget_set_margin_bottom(nativeChild,bottomFlexible?0:MAX(0,lround((parentSize.height-top-NSHeight(initial))*_scale)));
          if(!(mask&NSViewHeightSizable)) gtk_widget_set_valign(nativeChild,topFlexible?(bottomFlexible?GTK_ALIGN_CENTER:GTK_ALIGN_END):GTK_ALIGN_START);
        }
        int minimumWidth,minimumHeight;
        gtk_widget_get_size_request(nativeChild,&minimumWidth,&minimumHeight);
        if(!(mask&NSViewWidthSizable)) minimumWidth=MAX(minimumWidth,lround(NSWidth(initial)*_scale));
        if(!(mask&NSViewHeightSizable)) minimumHeight=MAX(minimumHeight,lround(NSHeight(initial)*_scale));
        for(NSLayoutConstraint *constraint in child.constraints)
          if(constraint.firstItem==child && !constraint.secondItem && constraint.priority>=1000
              && constraint.relation!=NSLayoutRelationLessThanOrEqual) {
            if(constraint.firstAttribute==NSLayoutAttributeWidth) minimumWidth=MAX(minimumWidth,lround(constraint.constant*_scale));
            if(constraint.firstAttribute==NSLayoutAttributeHeight) minimumHeight=MAX(minimumHeight,lround(constraint.constant*_scale));
          }
        gtk_widget_set_size_request(nativeChild,minimumWidth,minimumHeight);
        gtk_box_append(GTK_BOX(widget),nativeChild);
      } else gtk_widget_set_parent(nativeChild, widget);
    }
    if(!stack) [self configureNativeLayout:view];
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
  // Allocation uses a local origin of (0,0); measurement must solve in that
  // same coordinate system instead of letting container edges float.
  gtk_constraint_layout_add_constraint(layout,gtk_constraint_new_constant(NULL,GTK_CONSTRAINT_ATTRIBUTE_LEFT,
    GTK_CONSTRAINT_RELATION_EQ,0,GTK_CONSTRAINT_STRENGTH_REQUIRED));
  gtk_constraint_layout_add_constraint(layout,gtk_constraint_new_constant(NULL,GTK_CONSTRAINT_ATTRIBUTE_TOP,
    GTK_CONSTRAINT_RELATION_EQ,0,GTK_CONSTRAINT_STRENGTH_REQUIRED));
  NSMutableArray *constraints = [NSMutableArray arrayWithArray:view.constraints];
  for (NSView *child in view.subviews) {
    GtkWidget *widget = [self widgetForView:child];
    NSArray *input=layoutInput(child);
    NSRect initial=[input[0] rectValue]; NSSize parentSize=[input[1] sizeValue];
    if(![view isKindOfClass:[NSTableCellView class]] && !NSIsEmptyRect(initial)
        && NSMinX(initial)>=0 && NSMinY(initial)>=0
        && NSMaxX(initial)<=parentSize.width && NSMaxY(initial)<=parentSize.height) {
      // GtkConstraintLayout does not implicitly keep children inside their
      // container. Preserve containment for content initially placed inside;
      // these equations also let GTK derive the window's true minimum size.
      GtkConstraintAttribute edges[]={GTK_CONSTRAINT_ATTRIBUTE_LEFT,GTK_CONSTRAINT_ATTRIBUTE_TOP,
        GTK_CONSTRAINT_ATTRIBUTE_RIGHT,GTK_CONSTRAINT_ATTRIBUTE_BOTTOM};
      for(int edge=0;edge<4;edge++)
        gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(widget,edges[edge],
          edge<2?GTK_CONSTRAINT_RELATION_GE:GTK_CONSTRAINT_RELATION_LE,
          NULL,edges[edge],1,0,GTK_CONSTRAINT_STRENGTH_REQUIRED));
    }
    for (NSLayoutConstraint *c in child.constraints)
      if (c.firstItem == child && !c.secondItem) [constraints addObject:c];
    for(int axis=0;axis<2;axis++) {
      GtkOrientation orientation=axis==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL;
      NSLayoutConstraintOrientation sourceAxis=axis==0?NSLayoutConstraintOrientationHorizontal:NSLayoutConstraintOrientationVertical;
      // Native minima and initial source preferences become GTK guides.
      if (!nativeControlSize(child) && [child contentHuggingPriorityForOrientation:sourceAxis]==250
          && [child contentCompressionResistancePriorityForOrientation:sourceAxis]==750) continue;
      int nativeMinimum=0,natural=0; gtk_widget_measure(widget,orientation,-1,&nativeMinimum,&natural,NULL,NULL);
      GtkConstraintAttribute attr=axis==0?GTK_CONSTRAINT_ATTRIBUTE_WIDTH:GTK_CONSTRAINT_ATTRIBUTE_HEIGHT;
      CGFloat minimum=nativeMinimum;
      for(NSLayoutConstraint *c in constraints)
        if(c.firstItem==child && !c.secondItem && c.firstAttribute==(axis==0?NSLayoutAttributeWidth:NSLayoutAttributeHeight)
            && c.priority>=1000 && c.relation!=NSLayoutRelationLessThanOrEqual) minimum=MAX(minimum,c.constant*_scale);
      natural=MAX(natural,lround(minimum));
      NSLayoutPriority hugging=[child contentHuggingPriorityForOrientation:sourceAxis];
      NSLayoutPriority resistance=[child contentCompressionResistancePriorityForOrientation:sourceAxis];
      if(resistance>=1000) {
        // Required compression resistance is a lower bound, not a soft stay
        // at the smaller hugging priority. Captions must keep their text width.
        g_object_set_data(G_OBJECT(widget),axis==0?"appkit-compression-min-h":"appkit-compression-min-v",
          GINT_TO_POINTER(lround(minimum)+1));
        minimum=MAX(minimum,natural);
      }
      GtkConstraintGuide *guide=gtk_constraint_guide_new();
      gtk_constraint_guide_set_min_size(guide,axis==0?lround(minimum):0,axis==1?lround(minimum):0);
      gtk_constraint_guide_set_nat_size(guide,axis==0?natural:0,axis==1?natural:0);
      gtk_constraint_guide_set_max_size(guide,G_MAXINT,G_MAXINT);
      if(axis==0 && [view isKindOfClass:[NSTableCellView class]]
          && [child isKindOfClass:[NSTextField class]] && [(NSTextField *)child alignment]==NSRightTextAlignment) {
        // Keep compact value columns at their template width while names grow.
        int maximum=MAX(MAX(1,lround(minimum)),lround(NSWidth(child.frame)*_scale));
        natural=MIN(natural,maximum);
        gtk_constraint_guide_set_nat_size(guide,natural,0);
        gtk_constraint_guide_set_max_size(guide,maximum,G_MAXINT);
      }
      gtk_constraint_guide_set_strength(guide,MAX(1,(int)MIN(hugging,resistance)*1000));
      gtk_constraint_layout_add_guide(layout,guide);
      g_object_set_data(G_OBJECT(widget),axis==0?"appkit-hugging-h":"appkit-hugging-v",guide);
      gtk_constraint_layout_add_constraint(layout,gtk_constraint_new(widget,attr,GTK_CONSTRAINT_RELATION_EQ,
        guide,attr,1,0,GTK_CONSTRAINT_STRENGTH_REQUIRED));
    }
    if (child.translatesAutoresizingMaskIntoConstraints) {
      NSArray *input=layoutInput(child);
      NSRect rect = [input[0] rectValue];
      NSSize initialParentSize=[input[1] sizeValue];
      if (!view.isFlipped) rect.origin.y = initialParentSize.height - NSMaxY(rect);
      CGFloat parentSize[]={initialParentSize.width,initialParentSize.height};
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
        CGFloat size=sizes[axis];
        if(!flex[axis][1] && nativeControlSize(child)) {
          int minimum=0; gtk_widget_measure(widget,axis==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,-1,&minimum,NULL,NULL,NULL);
          size=MAX(size,minimum/_scale);
        }
        for(int i=0;i<2;i++) {
          CGFloat weight=flex[axis][i] ? (total>0?lengths[i]/total:1.0/MAX(1,count)) : 0;
          // An unchanged frame in an unflipped source view is bottom anchored.
          if(axis==1 && i==0 && !view.isFlipped && count==0) weight=1;
          CGFloat constant=(i==0?positions[axis]-weight*(size-sizes[axis]):size)-parentSize[axis]*weight;
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
    // XIB control slots may be smaller than GTK's theme minimum. Preserve the
    // native control's padding instead of forcing a negative child allocation.
    if(first && !c.secondItem && nativeControlSize(c.firstItem)
        && (firstAttr==GTK_CONSTRAINT_ATTRIBUTE_WIDTH || firstAttr==GTK_CONSTRAINT_ATTRIBUTE_HEIGHT)
        && relation!=GTK_CONSTRAINT_RELATION_LE) {
      int minimum=0;
      gtk_widget_measure(GTK_WIDGET(first),firstAttr==GTK_CONSTRAINT_ATTRIBUTE_WIDTH?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,-1,&minimum,NULL,NULL,NULL);
      constant=MAX(constant,minimum);
    }
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
    gtk_constraint_layout_add_constraint(layout,nativeConstraint(layout,first,firstAttr,relation,
      second,secondAttr,multiplier,constant,strength));
  }
}
- (void)synchronize
{
  if (_invalidated || _synchronizing) return;
  [self retain];
  _synchronizing = YES;
  @try {
  [self reflectNativeGeometry];
  for (NSView *view in _widgets) {
    if(_invalidated) break;
    GtkWidget *widget = [self widgetForView:view];
    if ([view isKindOfClass:[NSTableView class]] && [view valueForKey:@"_nativeTableView"]) continue;
    gtk_widget_set_visible(widget, ![view isHidden]);
    gtk_widget_set_tooltip_text(widget, [[view toolTip] UTF8String]);
    if ([view isKindOfClass:[NSControl class]]) controlSensitive(widget, [(NSControl *)view isEnabled]);
    if ([view isKindOfClass:[NSRulerView class]]) {
      NSRulerView *ruler=(id)view;
      int thickness=MAX(1,lround((ruler.ruleThickness+ruler.reservedThicknessForMarkers+ruler.reservedThicknessForAccessoryView)*_scale));
      gtk_widget_set_size_request(widget,ruler.orientation==NSVerticalRuler?thickness:-1,ruler.orientation==NSHorizontalRuler?thickness:-1);
    }
    if (GTK4NativeIsCustomView(widget)) continue;
    if ([view isKindOfClass:[NSSplitView class]]) {
      NSSplitView *split=(id)view;
      if (![split.subviews isEqual:(id)g_object_get_data(G_OBJECT(widget),"appkit-split-panes")]) continue;
      GtkWidget *paned=widget;
      BOOL positionChanged=NO,nativeMoved=NO;
      for (NSUInteger i=0;i+1<split.subviews.count;i++) {
        nativeMoved|=g_object_get_data(G_OBJECT(paned),"appkit-split-moved")!=NULL;
        g_object_set_data(G_OBJECT(paned),"appkit-split-moved",NULL);
        NSView *pane=split.subviews[i];
        GtkWidget *child=[self widgetForView:pane];
        NSValue *last=g_object_get_data(G_OBJECT(child),"appkit-reflected-frame");
        if (!last || !NSEqualRects(last.rectValue,pane.frame)) {
          gtk_paned_set_position(GTK_PANED(paned),lround((split.isVertical?NSWidth(pane.frame):NSHeight(pane.frame))*_scale));
          positionChanged=YES;
        }
        paned=gtk_paned_get_end_child(GTK_PANED(paned));
      }
      if(positionChanged) for(NSView *pane in split.subviews) {
        GtkWidget *child=[self widgetForView:pane];
        g_object_set_data_full(G_OBJECT(child),"appkit-reflected-frame",[[NSValue valueWithRect:pane.frame] retain],releaseObject);
      }
      if(nativeMoved && !positionChanged && g_main_depth()==0)
        [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:split];
    } else if([view isKindOfClass:[NSTabView class]]) {
      NSTabView *tabs=(id)view;
      GtkWidget *stack=g_object_get_data(G_OBJECT(widget),"appkit-tab-stack");
      GtkWidget *navigation=g_object_get_data(G_OBJECT(widget),"appkit-tab-navigation");
      NSArray *items=g_object_get_data(G_OBJECT(stack),"appkit-tab-items");
      gtk_widget_set_visible(navigation,tabs.tabViewType<=NSRightTabsBezelBorder && items.count>0);
      for(NSUInteger i=0;i<items.count;i++) {
        NSTabViewItem *item=items[i];
        NSString *name=[NSString stringWithFormat:@"tab-%lu",(unsigned long)i];
        GtkWidget *page=gtk_stack_get_child_by_name(GTK_STACK(stack),name.UTF8String);
        gtk_stack_page_set_title(gtk_stack_get_page(GTK_STACK(stack),page),(item.label?:@"").UTF8String);
        if(item==tabs.selectedTabViewItem && gtk_stack_get_visible_child(GTK_STACK(stack))!=page)
          gtk_stack_set_visible_child(GTK_STACK(stack),page);
      }
      gtk_widget_set_visible(stack,tabs.selectedTabViewItem!=nil);
    } else if([view isKindOfClass:[NSBox class]]) {
      NSBox *box=(id)view;
      if(GTK_IS_FRAME(widget)) {
        const char *title=box.titlePosition==NSNoTitle?NULL:(box.title?:@"").UTF8String;
        if(g_strcmp0(gtk_frame_get_label(GTK_FRAME(widget)),title)) gtk_frame_set_label(GTK_FRAME(widget),title);
        GtkWidget *content=gtk_frame_get_child(GTK_FRAME(widget));
        if(content) {
          int horizontal=MAX(0,lround(box.contentViewMargins.width*_scale));
          int vertical=MAX(0,lround(box.contentViewMargins.height*_scale));
          gtk_widget_set_margin_start(content,horizontal); gtk_widget_set_margin_end(content,horizontal);
          gtk_widget_set_margin_top(content,vertical); gtk_widget_set_margin_bottom(content,vertical);
        }
      }
      else {
        GtkWidget *content=g_object_get_data(G_OBJECT(widget),"appkit-box-content");
        if(content) {
          gtk_widget_set_margin_start(content,MAX(0,lround(box.contentViewMargins.width*_scale)));
          gtk_widget_set_margin_end(content,MAX(0,lround(box.contentViewMargins.width*_scale)));
          gtk_widget_set_margin_top(content,MAX(0,lround(box.contentViewMargins.height*_scale)));
          gtk_widget_set_margin_bottom(content,MAX(0,lround(box.contentViewMargins.height*_scale)));
        }
      }
    } else if ([view isKindOfClass:[NSScrollView class]]) {
      NSScrollView *scroll=(id)view; NSView *document=scroll.documentView;
      if(!GTK_IS_SCROLLED_WINDOW(widget)) widget=g_object_get_data(G_OBJECT(widget),"appkit-scroll-widget");
      GTK4NativeTable *table=g_object_get_data(G_OBJECT(widget),"appkit-native-table");
      if (table) { [table update]; continue; }
      GtkWidget *nativeDocument=[self widgetForView:document];
      if (!nativeDocument) { gtk_widget_set_visible(widget,FALSE); continue; }
      gtk_widget_set_size_request(nativeDocument,
        scroll.hasHorizontalScroller?MAX(1,lround(NSWidth(document.frame)*_scale)):-1,
        scroll.hasVerticalScroller?MAX(1,lround(NSHeight(document.frame)*_scale)):-1);
      GtkAdjustment *h=gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget));
      GtkAdjustment *v=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget));
      NSValue *last=g_object_get_data(G_OBJECT(widget),"appkit-scroll-origin");
      if(g_main_depth()==0 && g_object_get_data(G_OBJECT(widget),"appkit-scroll-moved")) {
        g_object_set_data(G_OBJECT(widget),"appkit-scroll-moved",NULL);
        if(last && NSEqualPoints(last.pointValue,scroll.contentView.bounds.origin)) [self scrollChanged:widget];
        last=g_object_get_data(G_OBJECT(widget),"appkit-scroll-origin");
      }
      if (gtk_adjustment_get_page_size(v)>0 && (!last || !NSEqualPoints(last.pointValue,scroll.contentView.bounds.origin))) {
        NSRect bounds=scroll.contentView.bounds;
        gtk_adjustment_set_value(h,NSMinX(bounds)*_scale);
        gtk_adjustment_set_value(v,(document.isFlipped?NSMinY(bounds):MAX(0,NSHeight(document.bounds)-NSMaxY(bounds)))*_scale);
        g_object_set_data_full(G_OBJECT(widget),"appkit-scroll-origin",[[NSValue valueWithPoint:bounds.origin] retain],releaseObject);
      }
    } else if ([view isKindOfClass:[NSPathControl class]]) {
      if(!GTK_IS_BOX(widget)) continue;
      NSPathControl *path=(id)view;
      pathContent(widget,path,self,_scale);
    } else if ([view isKindOfClass:[NSComboBox class]]) {
      NSComboBox *combo=(id)view;
      [combo.cell setControlView:combo];
      NSMutableArray *items=[NSMutableArray array];
      NSInteger count=combo.usesDataSource?[[combo dataSource] numberOfItemsInComboBox:combo]:combo.numberOfItems;
      for(NSInteger i=0;i<count;i++) {
        id value=combo.usesDataSource?[[combo dataSource] comboBox:combo objectValueForItemAtIndex:i]:[combo itemObjectValueAtIndex:i];
        [items addObject:[value description]?:@""];
      }
      BOOL changed=![items isEqual:(id)g_object_get_data(G_OBJECT(widget),"appkit-combo-items")];
      if(changed) {
        gtk_combo_box_text_remove_all(GTK_COMBO_BOX_TEXT(widget));
        for(NSString *item in items) gtk_combo_box_text_append_text(GTK_COMBO_BOX_TEXT(widget),item.UTF8String);
        g_object_set_data_full(G_OBJECT(widget),"appkit-combo-items",[items copy],releaseObject);
      }
      NSNumber *previous=g_object_get_data(G_OBJECT(widget),"appkit-combo-index");
      if(changed || !previous || previous.integerValue!=combo.indexOfSelectedItem)
        gtk_combo_box_set_active(GTK_COMBO_BOX(widget),(int)combo.indexOfSelectedItem);
      g_object_set_data_full(G_OBJECT(widget),"appkit-combo-index",[@(combo.indexOfSelectedItem) retain],releaseObject);
      GtkEditable *entry=GTK_EDITABLE(gtk_combo_box_get_child(GTK_COMBO_BOX(widget)));
      entryFont(GTK_WIDGET(entry),combo.font,_scale,widget);
      gtk_editable_set_editable(entry,combo.isEditable);
      const char *text=combo.stringValue.UTF8String?:"";
      if(strcmp(gtk_editable_get_text(entry),text)) gtk_editable_set_text(entry,text);
    } else if ([view isKindOfClass:[NSStepper class]]) {
      NSStepper *stepper=(id)view;
      double lower=stepper.minValue,upper=MAX(lower,stepper.maxValue);
      if(GTK4NativeIsStepper(widget)) {
        GTK4NativeStepperConfigure(widget,lower,upper,stepper.increment,stepper.doubleValue,stepper.valueWraps,stepper.autorepeat);
        controlSensitive(widget,stepper.isEnabled && upper>lower && stepper.increment!=0);
        continue;
      }
      double increment=fabs(stepper.increment);
      if(!(increment>0)) increment=1;
      guint digits=MAX(decimalDigits(increment),MAX(decimalDigits(lower),decimalDigits(stepper.doubleValue)));
      gtk_spin_button_set_digits(GTK_SPIN_BUTTON(widget),digits);
      gtk_adjustment_configure(gtk_spin_button_get_adjustment(GTK_SPIN_BUTTON(widget)),
        stepper.doubleValue,lower,upper,increment,increment*10,0);
      gtk_spin_button_set_wrap(GTK_SPIN_BUTTON(widget),stepper.valueWraps);
      controlSensitive(widget,stepper.isEnabled && upper>lower);
    } else if ([view isKindOfClass:[NSSlider class]]) {
      NSSlider *slider=(id)view;
      double lower=slider.minValue, upper=slider.maxValue, range=MAX(0,upper-lower);
      gtk_range_set_range(GTK_RANGE(widget),lower,range>0?upper:lower+1);
      gtk_range_set_increments(GTK_RANGE(widget),range>0?range/100:1,range>0?range/10:1);
      gtk_widget_set_sensitive(widget,slider.isEnabled && range>0);
      gtk_range_set_value(GTK_RANGE(widget),slider.doubleValue);
      NSArray *marks=@[@(slider.numberOfTickMarks),@(slider.tickMarkPosition),@(lower),@(upper)];
      if(![marks isEqual:(id)g_object_get_data(G_OBJECT(widget),"appkit-slider-marks")]) {
        gtk_scale_clear_marks(GTK_SCALE(widget));
        BOOL vertical=gtk_orientable_get_orientation(GTK_ORIENTABLE(widget))==GTK_ORIENTATION_VERTICAL;
        GtkPositionType position=vertical?(slider.tickMarkPosition==NSTickMarkLeft?GTK_POS_LEFT:GTK_POS_RIGHT)
          :(slider.tickMarkPosition==NSTickMarkAbove?GTK_POS_TOP:GTK_POS_BOTTOM);
        for(NSInteger i=0;i<slider.numberOfTickMarks;i++) gtk_scale_add_mark(GTK_SCALE(widget),[slider tickMarkValueAtIndex:i],position,NULL);
        g_object_set_data_full(G_OBJECT(widget),"appkit-slider-marks",[marks copy],releaseObject);
      }
    } else if ([view isKindOfClass:[NSProgressIndicator class]]) {
      NSProgressIndicator *progress=(id)view;
      if(GTK_IS_SPINNER(widget)) gtk_spinner_set_spinning(GTK_SPINNER(widget),progress.isAnimating);
      else {
        guint tick=GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(widget),"appkit-progress-tick"));
        if(progress.isIndeterminate && progress.isAnimating && !tick) {
          gtk_progress_bar_pulse(GTK_PROGRESS_BAR(widget));
          tick=gtk_widget_add_tick_callback(widget,progressTick,NULL,NULL);
          g_object_set_data(G_OBJECT(widget),"appkit-progress-tick",GUINT_TO_POINTER(tick));
        } else if((!progress.isIndeterminate || !progress.isAnimating) && tick) {
          gtk_widget_remove_tick_callback(widget,tick);
          g_object_set_data(G_OBJECT(widget),"appkit-progress-tick",NULL);
          g_object_set_data(G_OBJECT(widget),"appkit-pulse-time",NULL);
        }
        gtk_orientable_set_orientation(GTK_ORIENTABLE(widget),progress.isVertical?GTK_ORIENTATION_VERTICAL:GTK_ORIENTATION_HORIZONTAL);
        gtk_progress_bar_set_inverted(GTK_PROGRESS_BAR(widget),progress.isVertical);
        if(!progress.isIndeterminate || !progress.isAnimating) {
          double range=progress.maxValue-progress.minValue;
          gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(widget),range>0?CLAMP((progress.doubleValue-progress.minValue)/range,0,1):0);
        }
      }
    } else if ([view isKindOfClass:[NSTextField class]]) {
      const char *text = [[(NSTextField *)view stringValue] UTF8String] ?: "";
      if (GTK_IS_EDITABLE(widget)) {
        if(GTK_IS_ENTRY(widget)) entryFont(widget,[(NSTextField *)view font],_scale,NULL);
        id edited=g_object_get_data(G_OBJECT(widget),"appkit-entry-edit-model");
        if ((!edited || ![edited isEqual:[(NSTextField *)view objectValue]])
            && strcmp(gtk_editable_get_text(GTK_EDITABLE(widget)), text)) gtk_editable_set_text(GTK_EDITABLE(widget), text);
      } else if (GTK_IS_LABEL(widget) && strcmp(gtk_label_get_text(GTK_LABEL(widget)), text)) {
        gtk_label_set_text(GTK_LABEL(widget), text);
      }
      for(int axis=0;axis<2;axis++) {
        GtkConstraintGuide *guide=g_object_get_data(G_OBJECT(widget),axis==0?"appkit-hugging-h":"appkit-hugging-v");
        if(!guide) continue;
        int minimumWidth=0,minimumHeight=0,maximumWidth=G_MAXINT,maximumHeight=G_MAXINT,natural=0;
        gtk_constraint_guide_get_min_size(guide,&minimumWidth,&minimumHeight);
        gtk_constraint_guide_get_max_size(guide,&maximumWidth,&maximumHeight);
        gtk_widget_measure(widget,axis==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,-1,NULL,&natural,NULL,NULL);
        gpointer compression=g_object_get_data(G_OBJECT(widget),axis==0?"appkit-compression-min-h":"appkit-compression-min-v");
        if(compression) {
          int minimum=MAX(GPOINTER_TO_INT(compression)-1,natural);
          if(axis==0) minimumWidth=minimum; else minimumHeight=minimum;
          gtk_constraint_guide_set_min_size(guide,minimumWidth,minimumHeight);
        }
        natural=MIN(natural,axis==0?maximumWidth:maximumHeight);
        gtk_constraint_guide_set_nat_size(guide,axis==0?MAX(minimumWidth,natural):0,axis==1?MAX(minimumHeight,natural):0);
      }
    } else if ([view isKindOfClass:[NSPopUpButton class]]) {
      NSPopUpButton *popup = (id)view;
      NSMutableArray *signature = [NSMutableArray array];
      for (id<NSMenuItem> item in [popup itemArray])
        [signature addObject:@[[item title] ?: @"", @([item isEnabled])]];
      if(GTK_IS_MENU_BUTTON(widget)) {
        if(![signature isEqual:(id)g_object_get_data(G_OBJECT(widget),"appkit-popup-items")]) {
          GtkWidget *popover=gtk_popover_new(),*menu=gtk_box_new(GTK_ORIENTATION_VERTICAL,0);
          gtk_widget_add_css_class(popover,"menu");
          gtk_popover_set_has_arrow(GTK_POPOVER(popover),FALSE);
          for(NSInteger i=1;i<popup.numberOfItems;i++) {
            NSMenuItem *item=[popup itemAtIndex:i];
            if(item.isSeparatorItem) { gtk_box_append(GTK_BOX(menu),gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)); continue; }
            GtkWidget *button=gtk_button_new(); gtk_widget_add_css_class(button,"flat");
            buttonContent(button,item.title,item.image,NSImageLeft,NSRoundRectBezelStyle,_scale);
            gtk_widget_set_sensitive(button,item.isEnabled);
            g_object_set_data(G_OBJECT(button),"appkit-view",view);
            g_object_set_data(G_OBJECT(button),"appkit-popup-index",GUINT_TO_POINTER(i+1));
            g_signal_connect(button,"clicked",G_CALLBACK(pullDownActivated),self);
            gtk_box_append(GTK_BOX(menu),button);
          }
          gtk_popover_set_child(GTK_POPOVER(popover),menu);
          gtk_menu_button_set_popover(GTK_MENU_BUTTON(widget),popover);
          g_object_set_data_full(G_OBJECT(widget),"appkit-popup-items",[signature copy],releaseObject);
        }
        gtk_menu_button_set_label(GTK_MENU_BUTTON(widget),popup.numberOfItems?[[popup itemAtIndex:0].title UTF8String]:"");
        continue;
      }
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
      gtk_grid_set_column_spacing(GTK_GRID(widget),MAX(0,lround(matrix.intercellSpacing.width*_scale)));
      gtk_grid_set_row_spacing(GTK_GRID(widget),MAX(0,lround(matrix.intercellSpacing.height*_scale)));
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
      if (GTK_IS_IMAGE(widget)) {
        NSString *name = [(id<GTK4NativeAppearanceHints>)view gtk4NativeIconName];
        if ([name length]) {
          if (g_strcmp0(gtk_image_get_icon_name(GTK_IMAGE(widget)), [name UTF8String]))
            gtk_image_set_from_icon_name(GTK_IMAGE(widget), [name UTF8String]);
          g_object_set_data(G_OBJECT(widget), "appkit-image", NULL);
        } else {
          NSImage *image = [(NSImageView *)view image];
          int size = MAX(1,lround(MIN(NSWidth([view bounds]),NSHeight([view bounds])) * _scale));
          if (g_object_get_data(G_OBJECT(widget), "appkit-image") != image
              || GPOINTER_TO_INT(g_object_get_data(G_OBJECT(widget), "appkit-image-size")) != size
              || gtk_image_get_storage_type(GTK_IMAGE(widget)) != GTK_IMAGE_PAINTABLE) {
            GdkTexture *texture = imageTexture(image);
            /* GtkImage uses a paintable's intrinsic size; pixel-size only
             * scales named icons. Fit custom artwork to the AppKit image box. */
            if (texture) {
              GdkPixbuf *pixels = gdk_pixbuf_get_from_texture(texture);
              if (pixels) {
                GdkPixbuf *scaled = gdk_pixbuf_scale_simple(pixels,size,size,GDK_INTERP_BILINEAR);
                g_object_unref(texture);
                texture = scaled ? gdk_texture_new_for_pixbuf(scaled) : NULL;
                if (scaled) g_object_unref(scaled);
                g_object_unref(pixels);
              }
            }
            gtk_image_set_from_paintable(GTK_IMAGE(widget), texture ? GDK_PAINTABLE(texture) : NULL);
            if (texture) g_object_unref(texture);
            g_object_set_data(G_OBJECT(widget), "appkit-image", image);
            g_object_set_data(G_OBJECT(widget), "appkit-image-size", GINT_TO_POINTER(size));
          }
        }
        gtk_image_set_pixel_size(GTK_IMAGE(widget), MAX(1,lround(MIN(NSWidth([view bounds]),NSHeight([view bounds])) * _scale)));
        continue;
      }
      NSImage *image = [(NSImageView *)view image];
      if (g_object_get_data(G_OBJECT(widget), "appkit-image") != image) {
        GdkTexture *texture = imageTexture(image);
        gtk_picture_set_paintable(GTK_PICTURE(widget), texture ? GDK_PAINTABLE(texture) : NULL);
        if (texture) g_object_unref(texture);
        g_object_set_data(G_OBJECT(widget), "appkit-image", image);
      }
    }
  }
  } @finally { _synchronizing = NO; [self release]; }
}
- (void)tabChanged:(GtkWidget *)stack
{
  if(_synchronizing || _invalidated) return;
  [self retain];
  @try {
    NSTabView *tabs=g_object_get_data(G_OBJECT(stack),"appkit-view");
    GtkWidget *page=gtk_stack_get_visible_child(GTK_STACK(stack));
    NSTabViewItem *item=page?g_object_get_data(G_OBJECT(page),"appkit-tab-item"):nil;
    if(item && [tabs.tabViewItems containsObject:item] && item!=tabs.selectedTabViewItem) {
      _synchronizing=YES;
      @try { [tabs selectTabViewItem:item]; }
      @finally { _synchronizing=NO; }
    }
    // AppKit's delegate may veto or replace the selection.
    [self synchronize];
  } @finally { [self release]; }
}
// Read back geometry after GTK has finished its frame. These model copies do
// not solve constraints or allocate widgets; GTK remains the layout owner.
- (void)reflectNativeGeometry
{
  if(_reflecting || _invalidated || g_main_depth()>0
      || !gtk_widget_get_mapped(_widget) || gtk_widget_get_width(_widget)<=0 || gtk_widget_get_height(_widget)<=0) return;
  _reflecting=YES;
  @try {
    if(gtk_widget_get_mapped(_widget)) {
      NSValue *last=g_object_get_data(G_OBJECT(_widget),"appkit-reflected-frame");
      if(!last || NSEqualRects(last.rectValue,_view.frame)) {
        [_view setFrameSize:NSMakeSize(gtk_widget_get_width(_widget)/_scale,gtk_widget_get_height(_widget)/_scale)];
        rememberReflectedFrame(_view);
        g_object_set_data_full(G_OBJECT(_widget),"appkit-reflected-frame",[[NSValue valueWithRect:_view.frame] retain],releaseObject);
      }
    }
    NSMutableArray *pending=[NSMutableArray arrayWithObject:_view];
    while(pending.count && !_invalidated) {
      NSView *parent=[pending objectAtIndex:0]; [pending removeObjectAtIndex:0];
      GtkWidget *nativeParent=[self widgetForView:parent]; if(!nativeParent) continue;
      if([parent isKindOfClass:[NSTableView class]]) continue;
      NSArray *children=[parent isKindOfClass:[NSScrollView class]]
        ? ([(NSScrollView *)parent documentView]?@[[ (NSScrollView *)parent documentView]]:@[])
        : GTK4NativeChildrenForView(parent);
      for(NSView *child in children) {
        GtkWidget *native=[self widgetForView:child]; graphene_rect_t rect;
        if(!native || !gtk_widget_get_mapped(native) || gtk_widget_get_allocated_width(native)<=0
            || gtk_widget_get_allocated_height(native)<=0 || [child isKindOfClass:[NSTableView class]]) continue;
        [pending addObject:child];
        NSValue *expected=g_object_get_data(G_OBJECT(native),"appkit-reflected-frame");
        if(!expected) expected=g_object_get_data(G_OBJECT(native),"appkit-source-frame");
        if(expected && !NSEqualRects(expected.rectValue,child.frame)) continue;
        if(!gtk_widget_compute_bounds(native,nativeParent,&rect)) continue;
        NSRect frame=NSMakeRect(rect.origin.x/_scale,rect.origin.y/_scale,rect.size.width/_scale,rect.size.height/_scale);
        if([parent isKindOfClass:[NSScrollView class]]) frame.origin=child.frame.origin;
        else if(!parent.isFlipped) frame.origin.y=NSHeight(parent.bounds)-NSMaxY(frame);
        if(!NSEqualRects(frame,child.frame)) [child setFrame:frame];
        rememberReflectedFrame(child);
        g_object_set_data_full(G_OBJECT(native),"appkit-reflected-frame",[[NSValue valueWithRect:child.frame] retain],releaseObject);
      }
    }
  } @finally { _reflecting=NO; }
}
- (void)stepperChanged:(GtkWidget *)widget
{
  if (_synchronizing || _invalidated || !gtk_widget_is_sensitive(widget)) return;
  [self retain];
  @try {
    NSStepper *stepper=g_object_get_data(G_OBJECT(widget),"appkit-view");
    BOOL compact=GTK4NativeIsStepper(widget);
    BOOL held=!compact && g_object_get_data(G_OBJECT(widget),"appkit-stepper-held")!=NULL;
    if(held && !stepper.autorepeat && g_object_get_data(G_OBJECT(widget),"appkit-stepper-stepped")) {
      _synchronizing=YES;
      gtk_spin_button_set_value(GTK_SPIN_BUTTON(widget),stepper.doubleValue);
      _synchronizing=NO;
      return;
    }
    double value=compact?GTK4NativeStepperGetValue(widget):gtk_spin_button_get_value(GTK_SPIN_BUTTON(widget));
    if(value==stepper.doubleValue) return;
    _synchronizing=YES;
    [stepper setDoubleValue:value];
    _synchronizing=NO;
    if(held) g_object_set_data(G_OBJECT(widget),"appkit-stepper-stepped",GINT_TO_POINTER(1));
    [self activate:widget];
  } @finally { _synchronizing=NO; [self release]; }
}
- (void)sliderChanged:(GtkWidget *)widget
{
  if (_synchronizing || _invalidated) return;
  [self retain];
  NSSlider *slider=g_object_get_data(G_OBJECT(widget),"appkit-view");
  double value=gtk_range_get_value(GTK_RANGE(widget));
  if(slider.allowsTickMarkValuesOnly && slider.numberOfTickMarks) value=[slider closestTickMarkValueToValue:value];
  _synchronizing=YES;
  [slider setDoubleValue:value];
  gtk_range_set_value(GTK_RANGE(widget),value);
  _synchronizing=NO;
  if(slider.isContinuous || !g_object_get_data(G_OBJECT(widget),"appkit-dragging")) [self activate:widget];
  [self release];
}
- (void)entryChanged:(GtkWidget *)widget
{
  if (_synchronizing || _invalidated) return;
  [self retain]; _synchronizing=YES;
  @try {
  NSTextField *field = g_object_get_data(G_OBJECT(widget), "appkit-view");
  NSString *text = [NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(widget))];
  id parsed=text;
  if (field.formatter) {
    BOOL valid=[field.formatter getObjectValue:&parsed forString:text errorDescription:NULL];
    g_object_set_data_full(G_OBJECT(widget),"appkit-entry-edit-model",[field.objectValue retain],releaseObject);
    if (!valid) return; // Preserve an incomplete numeric edit in GtkEntry.
    [field setObjectValue:parsed];
    g_object_set_data_full(G_OBJECT(widget),"appkit-entry-edit-model",[field.objectValue retain],releaseObject);
  } else [field setStringValue:text];
  NSDictionary *binding = [field infoForBinding:NSValueBinding];
  id destination = [binding objectForKey:NSObservedObjectKey];
  NSString *key = [binding objectForKey:NSObservedKeyPathKey];
  if (destination && key) {
    id value = parsed;
    NSDictionary *options = [binding objectForKey:NSOptionsKey];
    NSValueTransformer *transformer = [options objectForKey:NSValueTransformerBindingOption];
    if (!transformer && [options objectForKey:NSValueTransformerNameBindingOption])
      transformer = [NSValueTransformer valueTransformerForName:[options objectForKey:NSValueTransformerNameBindingOption]];
    if (transformer && [[transformer class] allowsReverseTransformation]) value = [transformer reverseTransformedValue:value];
    [destination setValue:value forKeyPath:key];
  }
  if ([field isContinuous]) [field sendAction:[field action] to:[field target]];
  } @finally { _synchronizing=NO; [self release]; }
}
- (void)activate:(GtkWidget *)widget
{
  if (_synchronizing || !gtk_widget_is_sensitive(widget)) return;
  // An action may enter a modal loop or remove its source view and peer.
  [self retain];
  @try {
    NSControl *control = g_object_get_data(G_OBJECT(widget), "appkit-view");
    if ([control isKindOfClass:[NSComboBox class]]) {
      NSComboBox *combo=(id)control;
      if(GTK_IS_COMBO_BOX(widget)) {
        NSInteger index=gtk_combo_box_get_active(GTK_COMBO_BOX(widget));
        if(index<0) return;
        GtkWidget *entry=gtk_combo_box_get_child(GTK_COMBO_BOX(widget));
        NSString *text=[NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(entry))];
        if(index==combo.indexOfSelectedItem && [combo.stringValue isEqual:text]) return;
        [combo setStringValue:text];
        [combo.cell setControlView:combo];
        [combo selectItemAtIndex:index];
      } else [combo setStringValue:[NSString stringWithUTF8String:gtk_editable_get_text(GTK_EDITABLE(widget))]];
    }
    if ([control isKindOfClass:[NSPopUpButton class]]) {
      NSPopUpButton *popup = (id)control;
      guint index = GTK_IS_DROP_DOWN(widget)?gtk_drop_down_get_selected(GTK_DROP_DOWN(widget))
        :GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(widget),"appkit-popup-index"))-1;
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
  if (_invalidated || g_main_depth()>0 || !g_object_get_data(G_OBJECT(widget),"appkit-scroll-origin")) return;
  NSScrollView *scroll=g_object_get_data(G_OBJECT(widget),"appkit-view");
  NSView *document=scroll.documentView; NSClipView *clip=scroll.contentView;
  double x=gtk_adjustment_get_value(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget)))/_scale;
  double y=gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)))/_scale;
  if(!document.isFlipped) y=MAX(0,NSHeight(document.bounds)-NSHeight(clip.bounds)-y);
  BOOL synchronizing=_synchronizing;
  _synchronizing=YES;
  @try { [clip scrollToPoint:NSMakePoint(x,y)]; [scroll reflectScrolledClipView:clip]; }
  @finally { _synchronizing=synchronizing; }
  g_object_set_data_full(G_OBJECT(widget),"appkit-scroll-origin",[[NSValue valueWithPoint:clip.bounds.origin] retain],releaseObject);
  GtkWidget *nativeDocument=[self widgetForView:document];
  if (GTK4NativeIsCustomView(nativeDocument)) GTK4NativeCustomViewInvalidate(nativeDocument,document.bounds);
}
- (NSRect)configurationFrameForView:(NSView *)view
{
  return [layoutInput(view)[0] rectValue];
}
- (void)invalidateNativeView:(NSView *)view inRect:(NSRect)rect
{
  if (_invalidated) return;
  GtkWidget *widget=[self widgetForView:view];
  if (GTK4NativeIsCustomView(widget)) GTK4NativeCustomViewInvalidate(widget,rect);
  else {
    // Geometry reflection can invalidate AppKit views while GTK is allocating
    // or snapshotting this same tree. Never mutate widget state reentrantly;
    // the host synchronizes model changes after GTK's frame has completed.
    if (widget) gtk_widget_queue_draw(widget);
  }
}
- (BOOL)ownsLayoutForNativeView:(NSView *)view { return !_invalidated; }
- (BOOL)ownsBackgroundForNativeView:(NSView *)view { return !_invalidated; }
- (void)layoutNativeView:(NSView *)view
{
  if (_reflecting || _invalidated) return;
  GtkWidget *widget=[self widgetForView:view];
  if(widget) {
    gtk_widget_queue_allocate(widget);
  }
}
- (BOOL)ownsAnimationForNativeView:(NSView *)view
{
  GtkWidget *widget=[self widgetForView:view];
  return !_invalidated && widget && (GTK_IS_SPINNER(widget) || GTK_IS_PROGRESS_BAR(widget));
}
- (BOOL)focusNativeView:(NSView *)view
{
  GtkWidget *widget=[self widgetForView:view];
  return !_invalidated && widget && gtk_widget_grab_focus(widget);
}
- (void)invalidate
{
  if (_invalidated) return;
  _invalidated=YES;
  for (NSView *view in _widgets) {
    if (GSNativeViewPeerForView(view)==self) GSSetNativeViewPeer(view,nil);
    GtkWidget *widget=[self widgetForView:view];
    GtkWidget *scrollWidget=g_object_get_data(G_OBJECT(widget),"appkit-scroll-widget");
    if(scrollWidget) {
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(scrollWidget)),self);
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scrollWidget)),self);
    }
    guint tick=GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(widget),"appkit-progress-tick"));
    if(tick) { gtk_widget_remove_tick_callback(widget,tick); g_object_set_data(G_OBJECT(widget),"appkit-progress-tick",NULL); }
    g_object_set_data(G_OBJECT(widget),"appkit-bridge",NULL);
    if(GTK_IS_SCROLLED_WINDOW(widget)) {
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_hadjustment(GTK_SCROLLED_WINDOW(widget)),self);
      g_signal_handlers_disconnect_by_data(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)),self);
    }
  }
  if (_widget) { disconnectBridgeCallbacks(_widget,self); gtk_widget_set_visible(_widget,FALSE); }
  // Constraint layouts share their native root's solver. Detach our managers
  // while the tree is still rooted, before unparenting recursively tears down
  // that solver. Embedded list rows belong to their own bridges and are kept.
  for(NSView *view in _widgets) {
    GtkWidget *widget=[self widgetForView:view];
    if(GTK_IS_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager(widget)))
      gtk_widget_set_layout_manager(widget,NULL);
  }
  for (GTK4NativeTable *table in _embeddedTables) [table unembed];
}
- (void)dealloc
{
  [self invalidate];
  _synchronizing = YES;
  if (_widget) {
    if (!_borrowedRoot) {
    disconnectBridgeCallbacks(_widget, self);
    gtk_widget_set_visible(_widget, FALSE);
    GTK4NativeDetachWidget(_widget);
    }
    g_object_unref(_widget);
  }
  [_embeddedTables release]; [_widgets release]; [_view release]; [super dealloc];
}
@end
