#import <AppKit/AppKit.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeControls.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <cairo-xlib.h>

#define CHECK(value, message) NSCAssert((value), (message))
@interface ButtonPage : NSView
@end
@implementation ButtonPage
- (BOOL)isFlipped { return YES; }
// Exercise the mixed AppKit/custom-drawing fallback with individual peers.
- (void)drawRect:(NSRect)rect { [[NSColor whiteColor] set]; NSRectFill(rect); }
@end
@interface ButtonActions : NSObject
{
@public
  NSInteger count;
  id sender;
  NSInteger segmentAtAction;
  NSInteger popupIndex;
}
- (void)action:(id)value;
@end
@implementation ButtonActions
- (void)action:(id)value
{
  count++; sender = value;
  if ([value isKindOfClass:[NSSegmentedControl class]]) segmentAtAction = [value selectedSegment];
}
@end
static void pump(double seconds)
{
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([end timeIntervalSinceNow] > 0) {
    for (int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask
      untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static void countedClick(GtkWidget *widget, gpointer data) { (*(NSInteger *)data)++; }
static BOOL inViewport(GtkWidget *widget)
{
  if(!gtk_widget_get_mapped(widget)) return NO;
  GtkWidget *scroll=gtk_widget_get_ancestor(widget,GTK_TYPE_SCROLLED_WINDOW);
  if(!scroll) return YES;
  graphene_rect_t bounds,viewport=GRAPHENE_RECT_INIT(0,0,gtk_widget_get_width(scroll),gtk_widget_get_height(scroll));
  return gtk_widget_compute_bounds(widget,scroll,&bounds) && graphene_rect_intersection(&bounds,&viewport,NULL);
}
static Display *input;
static int (*motion)(Display *,int,int,int,unsigned long);
static int (*buttonEvent)(Display *,unsigned int,int,unsigned long);
static int (*keyEvent)(Display *,unsigned int,int,unsigned long);
static void click(GtkWidget *widget, GTK4NativeWindowDecorationView *host)
{
  GtkNative *native = gtk_widget_get_native(widget);
  graphene_rect_t rect;
  CHECK(gtk_widget_compute_bounds(widget, GTK_WIDGET(native), &rect), @"native control bounds");
  double dx,dy; gtk_native_get_surface_transform(native, &dx,&dy);
  int scale = gtk_widget_get_scale_factor(GTK_WIDGET(native)), x,y; Window child;
  Window surface = gdk_x11_surface_get_xid(gtk_native_get_surface(native));
  (void)host;

  XTranslateCoordinates(input,surface,DefaultRootWindow(input),
    lround((rect.origin.x+rect.size.width/2+dx)*scale),
    lround((rect.origin.y+rect.size.height/2+dy)*scale), &x,&y,&child);
  motion(input,-1,x,y,CurrentTime); XFlush(input); pump(.03);
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.04);
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.07);
}
static void key(KeySym symbol)
{
  KeyCode code=XKeysymToKeycode(input,symbol);
  keyEvent(input,code,True,CurrentTime); keyEvent(input,code,False,CurrentTime); XFlush(input); pump(.12);
}
static GtkWidget *findPopover(GtkWidget *widget)
{
  if (GTK_IS_POPOVER(widget)) return widget;
  for (GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=findPopover(child); if (found) return found;
  }
  return NULL;
}
static GtkWidget *findLabel(GtkWidget *widget, const char *text)
{
  if (GTK_IS_LABEL(widget) && !strcmp(gtk_label_get_text(GTK_LABEL(widget)),text) && gtk_widget_get_mapped(widget)) return widget;
  for (GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=findLabel(child,text); if (found) return found;
  }
  return NULL;
}
static NSButton *makeButton(NSView *page, ButtonActions *actions, NSString *title, NSRect frame)
{
  NSButton *b=[[[NSButton alloc] initWithFrame:frame] autorelease];
  [b setTitle:title]; [b setBezelStyle:NSRoundedBezelStyle];
  [b setTarget:actions]; [b setAction:@selector(action:)]; [page addSubview:b]; return b;
}
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  [NSApplication sharedApplication]; [NSApp finishLaunching];
  void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
  motion=dlsym(xtst,"XTestFakeMotionEvent"); buttonEvent=dlsym(xtst,"XTestFakeButtonEvent"); keyEvent=dlsym(xtst,"XTestFakeKeyEvent");
  input=XOpenDisplay(NULL); CHECK(input && motion && buttonEvent && keyEvent,@"XTest input available");
  ButtonActions *actions=[ButtonActions new];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(30,30,1020,760)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO]; [window setTitle:@"Native Buttons & Selection"];
  NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,1020,760)] autorelease];
  [scroll setHasVerticalScroller:YES]; [scroll setAutoresizingMask:NSViewWidthSizable|NSViewHeightSizable];
  [[window contentView] addSubview:scroll];
  ButtonPage *page=[[[ButtonPage alloc] initWithFrame:NSMakeRect(0,0,1000,1200)] autorelease];
  [scroll setDocumentView:page];
  // Exercise native controls nested inside a custom drawing container.
  NSTextView *fallback=[[[NSTextView alloc] initWithFrame:NSZeroRect] autorelease];
  [page addSubview:fallback];
  NSButton *push=makeButton(page,actions,@"Push",NSMakeRect(20,20,140,34));
  NSButton *def=makeButton(page,actions,@"Default",NSMakeRect(180,20,140,34)); [def setKeyEquivalent:@"\r"]; CHECK(!def.image && !def.alternateImage,@"native default button has no Return image");
  NSButton *disabled=makeButton(page,actions,@"Disabled",NSMakeRect(340,20,140,34)); [disabled setEnabled:NO];
  NSButton *toggle=makeButton(page,actions,@"Toggle",NSMakeRect(500,20,140,34)); [toggle setButtonType:NSPushOnPushOffButton];
  NSButton *image=makeButton(page,actions,@"Image + title",NSMakeRect(660,20,280,34));
  [image setImage:[NSImage imageNamed:@"common_Folder"]]; [image setImagePosition:NSImageLeft];
  NSButton *check=makeButton(page,actions,@"Mixed checkbox",NSMakeRect(20,80,250,34));
  [check setButtonType:NSSwitchButton]; [check setAllowsMixedState:YES]; [check setState:NSMixedState];
  NSPopUpButton *popup=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(360,80,300,34) pullsDown:NO] autorelease];
  [popup addItemsWithTitles:@[@"First",@"Second",@"Disabled choice"]];
  [[popup menu] setAutoenablesItems:NO]; [[popup itemAtIndex:2] setEnabled:NO];
  [popup setTarget:actions]; [popup setAction:@selector(action:)]; [page addSubview:popup];
  [popup bind:NSSelectedIndexBinding toObject:actions withKeyPath:@"popupIndex" options:nil];
  NSButtonCell *prototype=[[[NSButtonCell alloc] initTextCell:@""] autorelease]; [prototype setButtonType:NSRadioButton];
  NSMatrix *matrix=[[[NSMatrix alloc] initWithFrame:NSMakeRect(20,140,900,32) mode:NSRadioModeMatrix
    prototype:prototype numberOfRows:1 numberOfColumns:3] autorelease];
  [matrix setCellSize:NSMakeSize(280,28)]; [matrix setTarget:actions]; [matrix setAction:@selector(action:)];
  for (int i=0;i<3;i++) [[matrix cellAtRow:0 column:i] setTitle:[NSString stringWithFormat:@"Radio %d",i+1]];
  [matrix selectCellAtRow:0 column:0]; [page addSubview:matrix];
  NSSwitch *sw=[[[NSSwitch alloc] initWithFrame:NSMakeRect(20,200,80,32)] autorelease];
  [sw setTarget:actions]; [sw setAction:@selector(action:)]; [page addSubview:sw];
  NSSegmentedControl *segments=[[[NSSegmentedControl alloc] initWithFrame:NSMakeRect(180,200,660,34)] autorelease];
  [segments setSegmentCount:3];
  for (int i=0;i<3;i++) { [segments setLabel:[NSString stringWithFormat:@"Segment %d",i+1] forSegment:i]; [segments setWidth:210 forSegment:i]; }
  [segments setSelectedSegment:1]; [segments setEnabled:NO forSegment:2];
  [segments setTarget:actions]; [segments setAction:@selector(action:)]; [page addSubview:segments];
  NSMutableArray *styles=[NSMutableArray array];
  for (int i=0;i<14;i++) {
    NSButton *b=makeButton(page,actions,@"Bezel",NSMakeRect(20+(i%4)*240,280+(i/4)*70,200,36));
    [b setBezelStyle:i+1]; [styles addObject:b];
  }
  NSButton *tiny=makeButton(page,actions,@"+",NSMakeRect(950,200,24,24));
  NSButton *bottom=makeButton(page,actions,@"Bottom",NSMakeRect(20,1030,200,34));
  [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; pump(.7);
  GTK4NativeWindowDecorationView *host=(id)[[window contentView] superview];
  CHECK([host isKindOfClass:[GTK4NativeWindowDecorationView class]],@"native window host");
  GTK4NativeControls *peers=host->_nativeControls;
  GtkWidget *nativePush=[peers widgetForView:push], *nativeCheck=[peers widgetForView:check];
  GtkWidget *nativeMatrix=[peers widgetForView:matrix], *nativeSwitch=[peers widgetForView:sw];
  GtkWidget *nativeSegments=[peers widgetForView:segments];
  NSLog(@"Native types: push=%s check=%s matrix=%s switch=%s segments=%s", nativePush ? G_OBJECT_TYPE_NAME(nativePush) : "nil", nativeCheck ? G_OBJECT_TYPE_NAME(nativeCheck) : "nil", nativeMatrix ? G_OBJECT_TYPE_NAME(nativeMatrix) : "nil", nativeSwitch ? G_OBJECT_TYPE_NAME(nativeSwitch) : "nil", nativeSegments ? G_OBJECT_TYPE_NAME(nativeSegments) : "nil");
  CHECK(GTK_IS_BUTTON(nativePush) && GTK_IS_CHECK_BUTTON(nativeCheck) && GTK_IS_GRID(nativeMatrix)
    && GTK_IS_SWITCH(nativeSwitch) && GTK_IS_BOX(nativeSegments),@"all page control families have real GTK widgets");
  CHECK(gtk_check_button_get_inconsistent(GTK_CHECK_BUTTON(nativeCheck)),@"mixed state native indicator");
  CHECK(GTK_IS_BOX(gtk_button_get_child(GTK_BUTTON([peers widgetForView:image]))),@"native image and label child widgets");
  NSInteger nativeClicks=0;
  g_signal_connect(nativePush,"clicked",G_CALLBACK(countedClick),&nativeClicks);
  NSInteger before=actions->count; click(nativePush,host);
  CHECK(nativeClicks==1,@"pointer goes to GtkButton, not the underlying AppKit button");
  CHECK(actions->count==before+1 && actions->sender==push,@"real pointer activation sends original NSButton once");
  before=actions->count; click([peers widgetForView:disabled],host); CHECK(actions->count==before,@"disabled button ignores pointer");
  click([peers widgetForView:toggle],host); CHECK([(NSButtonCell *)toggle.cell state]==NSOnState,@"toggle on");
  click([peers widgetForView:toggle],host); CHECK([(NSButtonCell *)toggle.cell state]==NSOffState,@"toggle off");
  GtkWidget *dropdown=[peers widgetForView:popup];
  CHECK(GTK_IS_DROP_DOWN(dropdown),@"selection popup is a GtkDropDown");
  before=actions->count; click(dropdown,host);
  GtkWidget *popover=findPopover(dropdown);
  CHECK(popover && gtk_widget_get_mapped(popover),@"real pointer opens dropdown popover");
  GtkWidget *choice=findLabel(popover,"Second");
  CHECK(choice,@"native popup rows are mapped"); click(choice,host);
  CHECK([popup indexOfSelectedItem]==1 && actions->count==before+1 && actions->sender==popup
    && actions->popupIndex==1,@"native popup selection preserves original sender and selected-index binding");
  before=actions->count; click(dropdown,host); key(XK_Home); key(XK_Return); pump(.15);
  CHECK([popup indexOfSelectedItem]==0 && actions->count==before+1 && actions->sender==popup,
    @"native popup keyboard selection wins over the window Return default");
  before=actions->count; gtk_drop_down_set_selected(GTK_DROP_DOWN(dropdown),2); pump(.1);
  CHECK([popup indexOfSelectedItem]==0 && gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown))==0
    && actions->count==before,@"disabled popup row is rejected without an action");
  [actions setValue:@1 forKey:@"popupIndex"]; pump(.12);
  CHECK(gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown))==1 && actions->count==before,@"model updates popup selection silently");
  [popup addItemWithTitle:@"Added choice"]; pump(.1);
  CHECK(g_list_model_get_n_items(gtk_drop_down_get_model(GTK_DROP_DOWN(dropdown)))==4,@"popup model updates after item insertion");
  click(nativeCheck,host); CHECK([(NSButtonCell *)check.cell state]==NSOnState,@"mixed cycles to on");
  click(nativeCheck,host); CHECK([(NSButtonCell *)check.cell state]==NSOffState,@"on cycles to off");
  click(nativeCheck,host); CHECK([(NSButtonCell *)check.cell state]==NSMixedState,@"off cycles to mixed");
  GtkWidget *second=gtk_widget_get_next_sibling(gtk_widget_get_first_child(nativeMatrix));
  before=actions->count; click(second,host);
  CHECK(matrix.selectedColumn==1 && [(NSCell *)[matrix cellAtRow:0 column:0] state]==NSOffState
    && actions->count==before+1 && actions->sender==matrix,@"radio exclusivity and original matrix action");
  gtk_widget_grab_focus(second); XSetInputFocus(input,host->_parent,RevertToParent,CurrentTime); XFlush(input); pump(.1);
  CHECK([peers widgetForView:matrix]==nativeMatrix,@"matrix peer survives native clicks");
  key(XK_Right);
  CHECK(matrix.selectedColumn==2 && actions->sender==matrix,@"native radio arrow-key navigation");
  click(nativeSwitch,host); CHECK([sw integerValue]==NSOnState && actions->sender==sw,@"real native switch input");
  GtkWidget *first=gtk_widget_get_first_child(nativeSegments);
  click(first,host); CHECK(segments.selectedSegment==0 && actions->sender==segments,@"segment selection");
  before=actions->count; click(gtk_widget_get_last_child(nativeSegments),host);
  CHECK(actions->count==before && segments.selectedSegment==0,@"disabled segment ignores input");
  [segments setTrackingMode:NSSegmentSwitchTrackingSelectAny]; pump(.12);
  nativeSegments=[peers widgetForView:segments];
  click(gtk_widget_get_next_sibling(gtk_widget_get_first_child(nativeSegments)),host);
  CHECK([segments isSelectedForSegment:0] && [segments isSelectedForSegment:1],@"select-any retains multiple segments");
  [segments setTrackingMode:NSSegmentSwitchTrackingMomentary]; pump(.12);
  nativeSegments=[peers widgetForView:segments]; click(gtk_widget_get_first_child(nativeSegments),host);
  CHECK(actions->segmentAtAction==0 && ![segments isSelectedForSegment:0],@"momentary segment selected only during action");
  for (NSButton *b in styles) {
    GtkWidget *widget=[peers widgetForView:b]; CHECK(GTK_IS_BUTTON(widget),@"every bezel uses GtkButton");
    NSInteger gtkClicks=0;
    gulong signal=g_signal_connect(widget,"clicked",G_CALLBACK(countedClick),&gtkClicks);
    before=actions->count; click(widget,host); CHECK(gtkClicks==1,@"bezel pointer input is handled by GTK");
    g_signal_handler_disconnect(widget,signal);
    CHECK(actions->count==before+1 && actions->sender==b,@"every bezel takes real native input");
  }
  // Changing segment tracking mode replaces the scene's widget structure.
  nativePush=[peers widgetForView:push]; nativeCheck=[peers widgetForView:check];
  nativeSwitch=[peers widgetForView:sw];
  gtk_widget_grab_focus(nativePush); XSetInputFocus(input,host->_parent,RevertToParent,CurrentTime); XFlush(input); pump(.05);
  before=actions->count; key(XK_space); CHECK(actions->count==before+1 && actions->sender==push,@"native keyboard Space activation");
  CHECK(gtk_window_get_default_widget(GTK_WINDOW(host->_host))==[peers widgetForView:def],@"Return default is a native widget");
  gtk_widget_grab_focus(nativeCheck); before=actions->count; key(XK_Return); pump(.3);
  CHECK(actions->count==before+1 && actions->sender==def,@"Return activates native default button");
  before=actions->count;
  [push setTitle:@"Updated"]; [push setEnabled:NO]; [check setState:NSOnState]; [sw setIntegerValue:NSOffState]; pump(.12);
  CHECK(actions->count==before,@"programmatic state updates do not send actions");
  CHECK(!gtk_widget_is_sensitive(nativePush) && !strcmp(gtk_button_get_label(GTK_BUTTON(nativePush)),"Updated"),@"programmatic title and enabled synchronization");
  CHECK(gtk_check_button_get_active(GTK_CHECK_BUTTON(nativeCheck)) && !gtk_switch_get_active(GTK_SWITCH(nativeSwitch)),@"programmatic checkbox and switch synchronization");
  before=actions->count; click([peers widgetForView:tiny],host);
  CHECK(actions->count==before+1 && actions->sender==tiny,@"undersized source frame still has safe native input");
  click(nativePush,host); // disabled, but its enclosing canvas must still scroll
  buttonEvent(input,5,True,CurrentTime); buttonEvent(input,5,False,CurrentTime); XFlush(input); pump(.15);
  CHECK(NSMinY(scroll.contentView.bounds)>0,@"wheel over native control scrolls enclosing AppKit view");
  [page scrollPoint:NSZeroPoint]; pump(.1);
  CHECK(!inViewport([peers widgetForView:bottom]),@"GTK clips the offscreen widget");
  [page scrollPoint:NSMakePoint(0,700)]; pump(.18);
  CHECK(!inViewport(nativePush) && inViewport([peers widgetForView:bottom]),@"scrolling updates clipping and native visibility");
  before=actions->count; click([peers widgetForView:bottom],host); CHECK(actions->count==before+1 && actions->sender==bottom,@"scrolled native input coordinates");
  [page scrollPoint:NSZeroPoint]; pump(.15);
  const char *preview=getenv("NATIVE_BUTTONS_PREVIEW");
  if (preview) {
    XWindowAttributes attributes; XGetWindowAttributes(input,host->_parent,&attributes);
    cairo_surface_t *source=cairo_xlib_surface_create(input,host->_parent,attributes.visual,attributes.width,attributes.height);
    cairo_surface_t *output=cairo_image_surface_create(CAIRO_FORMAT_RGB24,attributes.width,attributes.height);
    cairo_t *cr=cairo_create(output); cairo_set_source_surface(cr,source,0,0); cairo_paint(cr);
    CHECK(cairo_surface_write_to_png(output,preview)==CAIRO_STATUS_SUCCESS,@"native preview saved");
    cairo_destroy(cr); cairo_surface_destroy(output); cairo_surface_destroy(source);
  }
  [push removeFromSuperview]; pump(.12); CHECK([peers widgetForView:push]==NULL,@"detached view loses native peer");
  [scroll setDocumentView:[[[NSView alloc] initWithFrame:NSMakeRect(0,0,1000,760)] autorelease]]; pump(.12);
  CHECK([peers widgetForView:check]==NULL && gtk_window_get_default_widget(GTK_WINDOW(host->_host))==NULL,@"page change removes widgets and default");
  [scroll setDocumentView:page]; pump(.12); CHECK([peers widgetForView:check]!=NULL,@"reattached page gets native widgets");
  [popup unbind:NSSelectedIndexBinding];
  [window setContentSize:NSMakeSize(900,700)]; pump(.12);
  [window close]; pump(.1);
  NSLog(@"PASS: native dropdown input/binding/model, buttons, all bezels, checkbox states, radio matrix, switch, segmented modes, real pointer/keyboard, synchronization, scrolling, detach, resize and teardown (scale %.2f)",[window userSpaceScaleFactor]);
  [window release]; [actions release]; XCloseDisplay(input); dlclose(xtst); [pool drain]; return 0;
}
