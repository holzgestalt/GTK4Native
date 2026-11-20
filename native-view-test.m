#import <AppKit/AppKit.h>
#import "GTK4NativeView.h"

@interface ViewTest : NSObject
{
  NSString *_text;
@public
  NSInteger actions;
  id sender;
}
@property(copy) NSString *text;
- (void)clicked:(id)value;
@end
@implementation ViewTest
@synthesize text = _text;
- (void)clicked:(id)value { actions++; sender = value; }
- (void)dealloc { [_text release]; [super dealloc]; }
@end

static void pump(void)
{
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:.15];
  while ([end timeIntervalSinceNow] > 0) {
    while (g_main_context_pending(NULL)) g_main_context_iteration(NULL, FALSE);
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
  }
}
static graphene_rect_t bounds(GtkWidget *widget, GtkWidget *root)
{
  graphene_rect_t rect;
  NSCAssert(gtk_widget_compute_bounds(widget, root, &rect), @"native widget must be allocated");
  return rect;
}

@interface NativeSwatch : NSView <GTK4NativeCustomView>
@end
static void swatch(GtkDrawingArea *area, cairo_t *context, int width, int height, gpointer data)
{
  cairo_set_source_rgb(context,.2,.5,.8); cairo_paint(context);
}
@implementation NativeSwatch
- (GtkWidget *)gtk4NativeWidget {
  GtkWidget *area = gtk_drawing_area_new();
  gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area),swatch,NULL,NULL);
  return area;
}
@end
@interface UnsupportedDrawing : NSView
@end
@implementation UnsupportedDrawing
- (void)drawRect:(NSRect)rect { [[NSColor redColor] set]; NSRectFill(rect); }
@end

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  gtk_init();
  ViewTest *test = [ViewTest new]; test.text = @"Original";
  NSView *settingsForm=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,400,100)] autorelease];
  NSPopUpButton *theme=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,20,200,24) pullsDown:NO] autorelease];
  [theme addItemWithTitle:@"Default"]; [[theme menu] addItem:[NSMenuItem separatorItem]];
  [theme addItemWithTitle:@"Classic"]; [settingsForm addSubview:theme];
  NSCAssert([GTK4NativeView supportsView:settingsForm],@"a Theme popup separator must not force its surrounding settings form into AppKit drawing");
  NSView *root = [[[NSView alloc] initWithFrame:NSMakeRect(0,0,460,90)] autorelease];
  NSTextField *label = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
  [label setEditable:NO]; [label setStringValue:@"Glyph name"];
  NSTextField *entry = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
  [entry setEditable:YES];
  [entry bind:NSValueBinding toObject:test withKeyPath:@"text" options:nil];
  NSButton *button = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
  [button setTitle:@"Apply"]; [button setTarget:test]; [button setAction:@selector(clicked:)];
  NSImageView *image = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
  [image setImage:[NSImage imageNamed:@"NSAddTemplate"]];
  for (NSView *view in [NSArray arrayWithObjects:label,entry,button,image,nil]) {
    [view setTranslatesAutoresizingMaskIntoConstraints:NO]; [root addSubview:view];
  }
  [root addConstraints:[NSArray arrayWithObjects:
    [[image leftAnchor] constraintEqualToAnchor:root.leftAnchor constant:8],
    [[image centerYAnchor] constraintEqualToAnchor:root.centerYAnchor],
    [[image widthAnchor] constraintEqualToConstant:32], [[image heightAnchor] constraintEqualToConstant:32],
    [[label leftAnchor] constraintEqualToAnchor:image.rightAnchor constant:8],
    [[label topAnchor] constraintEqualToAnchor:root.topAnchor constant:8],
    [[label widthAnchor] constraintEqualToConstant:100], [[label heightAnchor] constraintEqualToConstant:20],
    [[entry leftAnchor] constraintEqualToAnchor:label.leftAnchor],
    [[entry topAnchor] constraintEqualToAnchor:label.bottomAnchor constant:6],
    [[entry rightAnchor] constraintEqualToAnchor:button.leftAnchor constant:-8],
    [[entry heightAnchor] constraintEqualToConstant:34],
    [[button rightAnchor] constraintEqualToAnchor:root.rightAnchor constant:-8],
    [[button centerYAnchor] constraintEqualToAnchor:entry.centerYAnchor],
    [[button widthAnchor] constraintEqualToConstant:80], [[button heightAnchor] constraintEqualToConstant:34],nil]];
  NSLayoutConstraint *softMinimum=[entry.widthAnchor constraintGreaterThanOrEqualToConstant:120];
  NSLayoutConstraint *softTrailing=[label.rightAnchor constraintLessThanOrEqualToAnchor:root.rightAnchor constant:-8];
  softMinimum.priority=500; softTrailing.priority=500;
  [root addConstraints:@[softMinimum,softTrailing]];
  GTK4NativeView *bridge = [[GTK4NativeView alloc] initWithView:root scale:1];
  NSCAssert(bridge != nil, @"a compound AppKit hierarchy must translate");
  GtkWidget *native = bridge.widget;
  NSCAssert(GTK_IS_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager(native)), @"GTK owns compound-view constraints");
  GtkWidget *window = gtk_window_new(); g_object_ref_sink(window);
  gtk_window_set_default_size(GTK_WINDOW(window),460,90);
  gtk_window_set_child(GTK_WINDOW(window),native);
  gtk_window_present(GTK_WINDOW(window)); pump();
  GtkWidget *nativeLabel = [bridge widgetForView:label], *nativeEntry = [bridge widgetForView:entry];
  GtkWidget *nativeButton = [bridge widgetForView:button], *nativeImage = [bridge widgetForView:image];
  NSCAssert(GTK_IS_LABEL(nativeLabel) && GTK_IS_ENTRY(nativeEntry) && GTK_IS_BUTTON(nativeButton)
    && GTK_IS_PICTURE(nativeImage), @"the translated children must be real native GTK widgets");
  graphene_rect_t l = bounds(nativeLabel,native), e = bounds(nativeEntry,native), b = bounds(nativeButton,native), i = bounds(nativeImage,native);
  NSCAssert(fabs(l.origin.x - 48) < 2 && fabs(l.origin.y - 8) < 2
    && fabs(e.origin.x - l.origin.x) < 2 && fabs(e.origin.y - 34) < 2
    && fabs(b.origin.x+b.size.width - (gtk_widget_get_width(native)-8)) < 2
    && fabs(i.size.width - 32) < 2, @"translated constraints preserve the compound arrangement");
  float width = e.size.width;
  gtk_window_set_default_size(GTK_WINDOW(window),640,90); pump();
  e = bounds(nativeEntry,native);
  NSCAssert(e.size.width > width + 150, @"GTK constraints must resize the native entry");
  [bridge synchronize]; // Passive readback runs outside GTK's layout callbacks.
  NSCAssert(fabs(entry.frame.size.width-e.size.width)<2, @"solved GTK geometry is reflected to source views");
  gtk_editable_set_text(GTK_EDITABLE(nativeEntry),"Edited natively");
  NSCAssert([test.text isEqual:@"Edited natively"] && [[entry stringValue] isEqual:test.text], @"native editing must update the original control and binding");
  g_signal_emit_by_name(nativeButton,"clicked");
  NSCAssert(test->actions == 1 && test->sender == button, @"native button actions retain the Objective-C sender");
  test.text = @"Updated externally"; [bridge synchronize];
  NSCAssert(!strcmp(gtk_editable_get_text(GTK_EDITABLE(nativeEntry)),"Updated externally"), @"bound model changes must reach GTK");
  NSCAssert(gtk_picture_get_paintable(GTK_PICTURE(nativeImage)) != NULL, @"NSImage content must reach the native picture");
  NativeSwatch *custom = [[[NativeSwatch alloc] initWithFrame:NSMakeRect(0,0,20,20)] autorelease];
  GTK4NativeView *customBridge = [[GTK4NativeView alloc] initWithView:custom scale:1];
  NSCAssert(customBridge && GTK_IS_DRAWING_AREA(customBridge.widget), @"custom platform drawing may provide a real GTK widget");
  [customBridge release];
  UnsupportedDrawing *unsupported = [[[UnsupportedDrawing alloc] initWithFrame:NSZeroRect] autorelease];
  NSCAssert([GTK4NativeView supportsView:unsupported], @"custom drawing uses a GTK wrapper");
  // Match EditGlyphData's list prototype: a compact, right-aligned Unicode
  // field and an elastic name with a shared baseline but different fonts.
  NSTableCellView *row = [[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,300,21)] autorelease];
  NSTextField *code = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
  NSTextField *name = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
  for (NSTextField *field in @[name,code]) {
    [field setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationVertical];
    [field setEditable:NO]; [field setTranslatesAutoresizingMaskIntoConstraints:NO]; [row addSubview:field];
  }
  [code setFont:[NSFont userFixedPitchFontOfSize:11]]; [code setAlignment:NSRightTextAlignment];
  [name setFont:[NSFont systemFontOfSize:12]];
  [code setStringValue:@"0369"]; [name setStringValue:@"icomb"];
  [code setContentHuggingPriority:251 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [code setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  [code addConstraint:[code.widthAnchor constraintGreaterThanOrEqualToConstant:40]];
  [row addConstraints:@[
    [code.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2],
    [name.leadingAnchor constraintEqualToAnchor:code.trailingAnchor constant:8],
    [row.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
    [name.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [name.firstBaselineAnchor constraintEqualToAnchor:code.firstBaselineAnchor]]];
  GTK4NativeView *rowBridge = [[GTK4NativeView alloc] initWithView:row scale:1];
  gtk_widget_set_hexpand(rowBridge.widget,TRUE);
  gtk_widget_set_size_request(rowBridge.widget,-1,21);
  gtk_window_set_child(GTK_WINDOW(window),rowBridge.widget);
  for (int pass = 0; pass < 12; pass++) {
    [name setStringValue:pass % 2 ? @"aVeryLongGlyphNameThatNeedsEllipsisInANarrowSidebar" : @"icomb"];
    [rowBridge synchronize];
    gtk_window_set_default_size(GTK_WINDOW(window),pass % 3 == 0 ? 180 : pass % 3 == 1 ? 440 : 270,21);
    pump();
    GtkWidget *nc = [rowBridge widgetForView:code], *nn = [rowBridge widgetForView:name];
    PangoLayoutIter *iter = pango_layout_get_iter(gtk_label_get_layout(GTK_LABEL(nn)));
    PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
    NSCAssert(run != NULL, @"native name must have a shaped font run");
    PangoFontDescription *description = pango_font_describe_with_absolute_size(run->item->analysis.font);
    NSCAssert(fabs(pango_font_description_get_size(description)/(double)PANGO_SCALE - name.font.pointSize) < .1,
      @"native font sizes must match AppKit user-space sizes without a second DPI conversion");
    pango_font_description_free(description); pango_layout_iter_free(iter);
    graphene_rect_t c = bounds(nc,rowBridge.widget), n = bounds(nn,rowBridge.widget);
    NSCAssert(c.origin.x == 2 && c.size.width >= 40 && c.size.width < 50
      && fabs(n.origin.x - (c.origin.x+c.size.width+8)) < 2 && n.size.width > 100,
      @"Unicode must stay compact and names must receive the remaining width after resize/rebinding");
    int cx,cy,nx,ny;
    gtk_label_get_layout_offsets(GTK_LABEL(nc),&cx,&cy); gtk_label_get_layout_offsets(GTK_LABEL(nn),&nx,&ny);
    double cb = c.origin.y + cy + pango_layout_get_baseline(gtk_label_get_layout(GTK_LABEL(nc))) / (double)PANGO_SCALE;
    double nb = n.origin.y + ny + pango_layout_get_baseline(gtk_label_get_layout(GTK_LABEL(nn))) / (double)PANGO_SCALE;
    NSCAssert(fabs(cb-nb) < 2, @"different native fonts must share the actual rendered baseline");
  }
  gtk_window_set_child(GTK_WINDOW(window),NULL);
  [rowBridge release];
  // Reattaching an editor can resize its source container before compatibility
  // readback reaches its children. Reuse initial springs, not that mixed state.
  NSView *editor=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,300,200)] autorelease];
  NSView *bar=[[[NSView alloc] initWithFrame:NSMakeRect(0,174,300,26)] autorelease];
  bar.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
  [editor addSubview:bar];
  GTK4NativeView *editorBridge=[[GTK4NativeView alloc] initWithView:editor scale:1];
  gtk_window_set_child(GTK_WINDOW(window),editorBridge.widget);
  gtk_window_set_default_size(GTK_WINDOW(window),300,200); pump();
  [editor setFrameSize:NSMakeSize(300,160)];
  gtk_window_set_child(GTK_WINDOW(window),NULL); [editorBridge release];
  editorBridge=[[GTK4NativeView alloc] initWithView:editor scale:1];
  gtk_window_set_child(GTK_WINDOW(window),editorBridge.widget);
  gtk_window_set_default_size(GTK_WINDOW(window),300,160); pump();
  graphene_rect_t barBounds=bounds([editorBridge widgetForView:bar],editorBridge.widget);
  NSCAssert(fabs(barBounds.origin.y)<1 && fabs(barBounds.size.height-26)<1,
    @"reattached editor keeps its top bar pinned through GTK constraints alone");
  gtk_window_set_child(GTK_WINDOW(window),NULL); [editorBridge release];
  // Ordinary NSViews describe stacks without application-specific subclasses.
  for(int vertical=0;vertical<2;vertical++) {
    NSView *stackRoot=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,300,200)] autorelease];
    NSView *stackBar=[[[NSView alloc] initWithFrame:vertical?NSMakeRect(0,174,300,26):NSMakeRect(0,0,26,200)] autorelease];
    NSView *stackBody=[[[NSView alloc] initWithFrame:vertical?NSMakeRect(0,0,300,174):NSMakeRect(26,0,274,200)] autorelease];
    stackBar.autoresizingMask=vertical?NSViewWidthSizable|NSViewMinYMargin:NSViewHeightSizable;
    stackBody.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [stackRoot addSubview:stackBody]; [stackRoot addSubview:stackBar];
    GTK4NativeView *stackBridge=[[GTK4NativeView alloc] initWithView:stackRoot scale:1];
    NSCAssert(GTK_IS_BOX(stackBridge.widget),@"plain linear containers use GtkBox without marker classes");
    NSCAssert(gtk_orientable_get_orientation(GTK_ORIENTABLE(stackBridge.widget))
      ==(vertical?GTK_ORIENTATION_VERTICAL:GTK_ORIENTATION_HORIZONTAL),@"initial geometry determines stack orientation");
    NSCAssert(gtk_widget_get_first_child(stackBridge.widget)==[stackBridge widgetForView:stackBar],
      @"initial geometry determines stack order, independently of source insertion order");
    gtk_window_set_child(GTK_WINDOW(window),stackBridge.widget);
    gtk_window_set_default_size(GTK_WINDOW(window),300,200); pump();
    int minimum=0,resizedMinimum=0;
    gtk_widget_measure(stackBridge.widget,GTK_ORIENTATION_HORIZONTAL,-1,&minimum,NULL,NULL,NULL);
    gtk_window_set_default_size(GTK_WINDOW(window),420,280); pump();
    gtk_widget_measure(stackBridge.widget,GTK_ORIENTATION_HORIZONTAL,-1,&resizedMinimum,NULL,NULL,NULL);
    NSCAssert(minimum==resizedMinimum,@"plain stack minimum does not grow after window resizing");
    graphene_rect_t barRect=bounds([stackBridge widgetForView:stackBar],stackBridge.widget);
    graphene_rect_t bodyRect=bounds([stackBridge widgetForView:stackBody],stackBridge.widget);
    NSCAssert(vertical?(barRect.origin.y==0 && barRect.size.height==26 && bodyRect.origin.y==26)
      :(barRect.origin.x==0 && barRect.size.width==26 && bodyRect.origin.x==26),
      @"native stack keeps the fixed bar and lets the body fill the resized window");
    gtk_window_set_child(GTK_WINDOW(window),NULL); [stackBridge release];
  }
  NSView *constrained=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,300,200)] autorelease];
  NSView *fixedBar=[[[NSView alloc] initWithFrame:NSMakeRect(0,174,300,26)] autorelease];
  NSView *flexBody=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,300,174)] autorelease];
  fixedBar.translatesAutoresizingMaskIntoConstraints=NO;
  flexBody.translatesAutoresizingMaskIntoConstraints=NO;
  [constrained addSubview:fixedBar]; [constrained addSubview:flexBody];
  [constrained addConstraints:@[
    [fixedBar.topAnchor constraintEqualToAnchor:constrained.topAnchor],
    [fixedBar.leadingAnchor constraintEqualToAnchor:constrained.leadingAnchor],
    [fixedBar.trailingAnchor constraintEqualToAnchor:constrained.trailingAnchor],
    [fixedBar.heightAnchor constraintEqualToConstant:26],
    [flexBody.topAnchor constraintEqualToAnchor:fixedBar.bottomAnchor],
    [flexBody.leadingAnchor constraintEqualToAnchor:constrained.leadingAnchor],
    [flexBody.trailingAnchor constraintEqualToAnchor:constrained.trailingAnchor],
    [flexBody.bottomAnchor constraintEqualToAnchor:constrained.bottomAnchor]
  ]];
  GTK4NativeView *constrainedBridge=[[GTK4NativeView alloc] initWithView:constrained scale:1];
  NSCAssert(GTK_IS_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager(constrainedBridge.widget)),
    @"linear frames without springs retain the explicit constraints");
  gtk_window_set_child(GTK_WINDOW(window),constrainedBridge.widget);
  gtk_window_set_default_size(GTK_WINDOW(window),420,280); pump();
  graphene_rect_t constrainedBody=bounds([constrainedBridge widgetForView:flexBody],constrainedBridge.widget);
  int constrainedMinimum=0;
  gtk_widget_measure(constrainedBridge.widget,GTK_ORIENTATION_HORIZONTAL,-1,&constrainedMinimum,NULL,NULL,NULL);
  NSCAssert(constrainedBody.size.width>=400 && constrainedBody.size.height>=240 && constrainedMinimum<300,
    @"constrained containers reflow without freezing initial child dimensions as window minima");
  gtk_window_set_child(GTK_WINDOW(window),NULL); [constrainedBridge release];
  [entry unbind:NSValueBinding];
  gtk_window_destroy(GTK_WINDOW(window)); g_object_unref(window);
  [bridge release]; [test release];
  NSLog(@"Native compound view: layout, resize, image, editing, binding and action passed");
  [pool drain]; return 0;
}
