#import <AppKit/AppKit.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeControls.h"
#import "GTK4NativeStepper.h"
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
static double entryFontSize(GtkWidget *entry)
{
  PangoAttrList *attrs=gtk_entry_get_attributes(GTK_ENTRY(entry));
  PangoAttrIterator *iterator=pango_attr_list_get_iterator(attrs);
  PangoAttrFontDesc *font=(PangoAttrFontDesc *)pango_attr_iterator_get(iterator,PANGO_ATTR_FONT_DESC);
  double size=font && pango_font_description_get_size_is_absolute(font->desc)
    ?pango_font_description_get_size(font->desc)/(double)PANGO_SCALE:-1;
  pango_attr_iterator_destroy(iterator); return size;
}
static void checkComboFont(GtkWidget *combo,double expected)
{
  CHECK(fabs(entryFontSize(gtk_combo_box_get_child(GTK_COMBO_BOX(combo)))-expected)<.01,@"combo editor honors AppKit font size without extra DPI scaling");
  GList *cells=gtk_cell_layout_get_cells(GTK_CELL_LAYOUT(combo));
  for(GList *cell=cells;cell;cell=cell->next) if(GTK_IS_CELL_RENDERER_TEXT(cell->data)) {
    PangoFontDescription *font=NULL; g_object_get(cell->data,"font-desc",&font,NULL);
    CHECK(font && pango_font_description_get_size_is_absolute(font)
      && fabs(pango_font_description_get_size(font)/(double)PANGO_SCALE-expected)<.01,@"native popup uses the same source font as the combo editor");
    pango_font_description_free(font);
  }
  g_list_free(cells);
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
  // Exercise native controls inside a custom GTK-hosted document.
  NSTextView *fallback=[[[NSTextView alloc] initWithFrame:NSZeroRect] autorelease];
  [page addSubview:fallback];

  NSComboBox *combo=[[[NSComboBox alloc] initWithFrame:NSMakeRect(20,20,320,24)] autorelease];
  [combo addItemsWithObjectValues:@[@"First",@"Second",@"Third"]];
  [combo selectItemAtIndex:0]; [combo setStringValue:@"First"];
  [combo setTarget:actions]; [combo setAction:@selector(action:)]; [page addSubview:combo];
  NSSlider *slider=[[[NSSlider alloc] initWithFrame:NSMakeRect(20,100,420,56)] autorelease];
  [slider setMinValue:10]; [slider setMaxValue:110]; [slider setDoubleValue:40];
  [slider setContinuous:YES]; [slider setTarget:actions]; [slider setAction:@selector(action:)]; [page addSubview:slider];
  NSSlider *vertical=[[[NSSlider alloc] initWithFrame:NSMakeRect(480,80,56,180)] autorelease];
  [vertical setDoubleValue:.4]; [page addSubview:vertical];
  NSSlider *circular=[[[NSSlider alloc] initWithFrame:NSMakeRect(580,100,110,70)] autorelease];
  [circular.cell setSliderType:NSCircularSlider]; [page addSubview:circular];
  NSStepper *stepper=[[[NSStepper alloc] initWithFrame:NSMakeRect(550,210,120,36)] autorelease];
  [stepper setGtk4NativeUsesSpinButton:YES];
  [stepper setMinValue:0]; [stepper setMaxValue:10]; [stepper setIncrement:2]; [stepper setDoubleValue:4];
  [stepper setTarget:actions]; [stepper setAction:@selector(action:)]; [page addSubview:stepper];
  NSTextField *neighbor=[[[NSTextField alloc] initWithFrame:NSMakeRect(700,210,100,34)] autorelease];
  [neighbor setStringValue:@"Separate field"]; [page addSubview:neighbor];
  NSStepper *compactSource=[[[NSStepper alloc] initWithFrame:NSMakeRect(804,210,24,34)] autorelease];
  [compactSource setMinValue:0]; [compactSource setMaxValue:10]; [compactSource setIncrement:2]; [compactSource setDoubleValue:4];
  [compactSource setTarget:actions]; [compactSource setAction:@selector(action:)]; [page addSubview:compactSource];
  NSProgressIndicator *progress=[[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20,210,420,24)] autorelease];
  [progress setIndeterminate:NO]; [progress setMinValue:10]; [progress setMaxValue:110]; [progress setDoubleValue:35]; [page addSubview:progress];
  NSProgressIndicator *pulse=[[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20,260,420,24)] autorelease];
  [pulse setUsesThreadedAnimation:NO]; [pulse startAnimation:nil]; [page addSubview:pulse];
  NSProgressIndicator *spinner=[[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20,320,40,40)] autorelease];
  [spinner setStyle:NSProgressIndicatorSpinningStyle]; [spinner startAnimation:nil]; [page addSubview:spinner];
  [window makeKeyAndOrderFront:nil]; pump(.3);
  GTK4NativeWindowDecorationView *host=(id)[[window contentView] superview];
  GTK4NativeControls *peers=host->_nativeControls;
  GtkWidget *nativeCombo=[peers widgetForView:combo], *nativeSlider=[peers widgetForView:slider];
  CHECK(GTK_IS_COMBO_BOX_TEXT(nativeCombo),@"combo is a native editable GTK combo");
  double nativeScale=[window userSpaceScaleFactor]/gtk_widget_get_scale_factor(nativeCombo);
  checkComboFont(nativeCombo,combo.font.pointSize*nativeScale);
  NSFont *originalFont=[[combo.font retain] autorelease];
  [combo setFont:[NSFont systemFontOfSize:11]]; pump(.1);
  checkComboFont(nativeCombo,11*nativeScale);
  [combo setFont:originalFont]; pump(.1);
  checkComboFont(nativeCombo,originalFont.pointSize*nativeScale);
  graphene_rect_t comboBounds;
  GtkWidget *comboClip=gtk_widget_get_parent(nativeCombo);
  CHECK(gtk_widget_compute_bounds(nativeCombo,comboClip,&comboBounds)
    && comboBounds.origin.y>=0 && comboBounds.origin.y+comboBounds.size.height<=gtk_widget_get_height(comboClip),
    @"24-point XIB-sized combo includes its complete top and bottom borders");
  CHECK(GTK_IS_SCALE(nativeSlider) && GTK_IS_SCALE([peers widgetForView:vertical]) && GTK_IS_SCALE([peers widgetForView:circular]),@"all slider styles use native scales");
  CHECK(GTK_IS_PROGRESS_BAR([peers widgetForView:progress]) && GTK_IS_PROGRESS_BAR([peers widgetForView:pulse]) && GTK_IS_SPINNER([peers widgetForView:spinner]),@"native progress widget families");
  NSInteger before=actions->count;
  gtk_combo_box_set_active(GTK_COMBO_BOX(nativeCombo),1); pump(.1);
  CHECK(combo.indexOfSelectedItem==1 && [combo.stringValue isEqual:@"Second"] && actions->count==before+1 && actions->sender==combo,@"combo selection updates source and sends one original-sender action");
  GtkWidget *entry=gtk_combo_box_get_child(GTK_COMBO_BOX(nativeCombo));
  CHECK([window makeFirstResponder:combo],@"native combo accepts AppKit focus");
  gtk_editable_set_text(GTK_EDITABLE(entry),"Typed value"); pump(.1);
  CHECK([combo.stringValue isEqual:@"Typed value"],@"freeform editing reaches AppKit");
  before=actions->count; g_signal_emit_by_name(entry,"activate");
  CHECK(actions->count==before+1 && actions->sender==combo,@"entry Return sends combo action");
  [combo addItemWithObjectValue:@"Fourth"]; [combo setStringValue:@"Programmatic"]; pump(.1);
  CHECK(!strcmp(gtk_editable_get_text(GTK_EDITABLE(entry)),"Programmatic") && actions->count==before+1,@"model and text synchronize silently");
  gtk_combo_box_popup(GTK_COMBO_BOX(nativeCombo)); pump(.1);
  CHECK(findPopover(nativeCombo) && gtk_widget_get_mapped(findPopover(nativeCombo)),@"combo popup is GTK native");
  before=actions->count;
  key(XK_Down); key(XK_Return); pump(.1);
  CHECK(combo.indexOfSelectedItem>=0 && [combo.stringValue isEqual:[combo itemObjectValueAtIndex:combo.indexOfSelectedItem]] && actions->count==before+1,@"real keyboard selects a native popup item once");
  before=actions->count; gtk_range_set_value(GTK_RANGE(nativeSlider),63);
  CHECK(slider.doubleValue==63 && actions->count==before+1 && actions->sender==slider,@"native slider value and action");
  [slider setNumberOfTickMarks:6]; [slider setAllowsTickMarkValuesOnly:YES]; pump(.1);
  gtk_range_set_value(GTK_RANGE(nativeSlider),46);
  CHECK(slider.doubleValue==50 && gtk_range_get_value(GTK_RANGE(nativeSlider))==50,@"tick-only source and GTK values agree");
  [slider setAllowsTickMarkValuesOnly:NO]; [slider setContinuous:NO]; pump(.1);
  before=actions->count; click(nativeSlider,host);
  CHECK(actions->count==before+1,@"noncontinuous pointer interaction sends exactly one action");
  [slider setEnabled:NO]; [slider setDoubleValue:80]; before=actions->count; pump(.1);
  CHECK(!gtk_widget_get_sensitive(nativeSlider) && gtk_range_get_value(GTK_RANGE(nativeSlider))==80 && actions->count==before,@"programmatic disabled slider synchronization is silent");
  [slider setMinValue:110]; [slider setMaxValue:110]; pump(.1);
  CHECK(!gtk_widget_get_sensitive(nativeSlider),@"zero range has a safe disabled GTK scale");
  GtkWidget *nativeStepper=[peers widgetForView:stepper];
  CHECK(GTK_IS_SPIN_BUTTON(nativeStepper),@"stepper uses native GtkSpinButton");
  graphene_rect_t stepperBounds;
  GtkWidget *stepperClip=gtk_widget_get_parent(nativeStepper);
  CHECK(gtk_widget_compute_bounds(nativeStepper,stepperClip,&stepperBounds)
    && stepperBounds.origin.x>=0 && stepperBounds.origin.y>=0
    && stepperBounds.origin.x+stepperBounds.size.width<=gtk_widget_get_width(stepperClip)
    && stepperBounds.origin.y+stepperBounds.size.height<=gtk_widget_get_height(stepperClip),@"native spin button fits its source frame");
  before=actions->count;
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_FORWARD,0);
  CHECK(stepper.doubleValue==6 && actions->count==before+1 && actions->sender==stepper,@"stepper increment sends one original-sender action");
  [stepper setDoubleValue:10]; [stepper setValueWraps:YES]; before=actions->count; pump(.1);
  CHECK(gtk_spin_button_get_value(GTK_SPIN_BUTTON(nativeStepper))==10 && actions->count==before,@"programmatic stepper synchronization is silent");
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_FORWARD,0);
  CHECK(stepper.doubleValue==0,@"stepper wraps forward at its maximum");
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_BACKWARD,0);
  CHECK(stepper.doubleValue==10,@"stepper wraps backward at its minimum");
  [stepper setValueWraps:NO]; before=actions->count; pump(.1);
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_FORWARD,0);
  CHECK(stepper.doubleValue==10 && actions->count==before,@"nonwrapping stepper stops at maximum without duplicate action");
  [stepper setDoubleValue:0]; [stepper setAutorepeat:NO]; pump(.1);
  GtkWidget *up=NULL;
  for(GtkWidget *child=gtk_widget_get_first_child(nativeStepper);child;child=gtk_widget_get_next_sibling(child))
    if(gtk_widget_has_css_class(child,"up")) up=child;
  CHECK(up,@"GTK provides native increment button");
  before=actions->count; click(up,host);
  CHECK(stepper.doubleValue==2 && actions->count==before+1,@"real pointer increments native stepper once");
  before=actions->count;
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.85);
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.1);
  CHECK(stepper.doubleValue==4 && actions->count==before+1,@"autorepeat disabled allows one step per held press");
  [stepper setValueWraps:YES]; [stepper setAutorepeat:YES]; pump(.1); before=actions->count;
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.85);
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.1);
  CHECK(actions->count>before+1,@"autorepeat enabled uses native press-and-hold repetition");
  [stepper setEnabled:NO]; pump(.1); before=actions->count; double oldValue=stepper.doubleValue;
  click(up,host);
  CHECK(!gtk_widget_is_sensitive(nativeStepper) && stepper.doubleValue==oldValue && actions->count==before,@"disabled stepper ignores input");
  [stepper setEnabled:YES]; [stepper setMinValue:2.5]; [stepper setMaxValue:4.5]; [stepper setIncrement:.25]; [stepper setDoubleValue:3]; pump(.1);
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_FORWARD,0);
  CHECK(stepper.doubleValue==3.25 && gtk_spin_button_get_digits(GTK_SPIN_BUTTON(nativeStepper))>=2,@"fractional increments keep their precision");
  NSMutableDictionary *model=[NSMutableDictionary dictionaryWithObject:@3.25 forKey:@"value"];
  [stepper bind:NSValueBinding toObject:model withKeyPath:@"value" options:nil]; pump(.1);
  gtk_spin_button_spin(GTK_SPIN_BUTTON(nativeStepper),GTK_SPIN_STEP_FORWARD,0);
  CHECK([[model objectForKey:@"value"] doubleValue]==3.5,@"native stepper reverses AppKit value binding");
  [stepper unbind:NSValueBinding];
  gtk_widget_grab_focus(nativeStepper); before=actions->count; key(XK_Up);
  CHECK(stepper.doubleValue==3.75 && actions->count==before+1,@"keyboard increment uses original stepper action");
  gtk_editable_set_text(GTK_EDITABLE(nativeStepper),"4.25"); gtk_spin_button_update(GTK_SPIN_BUTTON(nativeStepper));
  CHECK(stepper.doubleValue==4.25,@"native numeric entry commits to source stepper");
  [stepper setMaxValue:2.5]; pump(.1);
  CHECK(!gtk_widget_get_sensitive(nativeStepper),@"zero-range stepper is safely disabled");
  GtkWidget *compact=[peers widgetForView:compactSource];
  CHECK(GTK4NativeIsStepper(compact) && !GTK_IS_EDITABLE(compact),@"default stepper is compact and has no implicit text field");
  NSRect originalFrame=NSMakeRect(804,210,24,34);
  graphene_rect_t compactBounds;
  GtkWidget *compactClip=gtk_widget_get_parent(compact);
  CHECK(NSEqualRects(compactSource.frame,originalFrame) && NSMaxX(neighbor.frame)<NSMinX(compactSource.frame),@"original stepper and adjacent field frames remain unchanged");
  CHECK(gtk_widget_compute_bounds(compact,compactClip,&compactBounds)
    && fabs(compactBounds.size.width-NSWidth(originalFrame)*nativeScale)<=1
    && fabs(compactBounds.size.height-NSHeight(originalFrame)*nativeScale)<=1
    && compactBounds.origin.x>=0 && compactBounds.origin.y>=0
    && compactBounds.origin.x+compactBounds.size.width<=gtk_widget_get_width(compactClip)
    && compactBounds.origin.y+compactBounds.size.height<=gtk_widget_get_height(compactClip),@"compact widget keeps its original narrow allocation inside the native document");
  before=actions->count; GTK4NativeStepperStep(compact,1);
  CHECK(compactSource.doubleValue==6 && actions->count==before+1 && actions->sender==compactSource,@"compact stepper preserves increment and original sender");
  [compactSource setDoubleValue:10]; [compactSource setValueWraps:YES]; before=actions->count; pump(.1);
  CHECK(GTK4NativeStepperGetValue(compact)==10 && actions->count==before,@"compact programmatic changes are silent");
  GTK4NativeStepperStep(compact,1); CHECK(compactSource.doubleValue==0,@"compact forward wrap");
  GTK4NativeStepperStep(compact,-1); CHECK(compactSource.doubleValue==10,@"compact backward wrap");
  [compactSource setValueWraps:NO]; pump(.1); before=actions->count;
  GTK4NativeStepperStep(compact,1); CHECK(compactSource.doubleValue==10 && actions->count==before,@"compact stops at bound without a duplicate action");
  [compactSource setDoubleValue:0]; [compactSource setAutorepeat:NO]; pump(.1);
  GtkWidget *compactUp=gtk_widget_get_first_child(compact);
  before=actions->count; click(compactUp,host);
  CHECK(compactSource.doubleValue==2 && actions->count==before+1,@"real pointer targets upper half of compact stepper");
  before=actions->count;
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.85);
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.1);
  CHECK(compactSource.doubleValue==4 && actions->count==before+1,@"compact autorepeat off means one action per held press");
  [compactSource setValueWraps:YES]; [compactSource setAutorepeat:YES]; pump(.1); before=actions->count;
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.85);
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.1);
  CHECK(actions->count>before+1,@"compact GTK widget owns hold repetition");
  [compactSource setEnabled:NO]; pump(.1); before=actions->count;
  double compactValue=compactSource.doubleValue; click(compactUp,host);
  CHECK(actions->count==before && compactSource.doubleValue==compactValue,@"disabled compact stepper ignores input");
  [compactSource setEnabled:YES]; [compactSource setMinValue:2.5]; [compactSource setMaxValue:4.5];
  [compactSource setIncrement:.25]; [compactSource setDoubleValue:3]; pump(.1);
  gtk_widget_grab_focus(compact); before=actions->count; key(XK_Up);
  CHECK(compactSource.doubleValue==3.25 && actions->count==before+1,@"compact keyboard input preserves fractional increments");
  NSMutableDictionary *compactModel=[NSMutableDictionary dictionaryWithObject:@3.25 forKey:@"value"];
  [compactSource bind:NSValueBinding toObject:compactModel withKeyPath:@"value" options:nil]; pump(.1);
  GTK4NativeStepperStep(compact,1);
  CHECK([[compactModel objectForKey:@"value"] doubleValue]==3.5,@"compact stepper reverses value bindings");
  [compactSource unbind:NSValueBinding];
  [compactSource setFrameSize:NSMakeSize(120,36)]; [compactSource setGtk4NativeUsesSpinButton:YES]; pump(.15);
  CHECK(GTK_IS_SPIN_BUTTON([peers widgetForView:compactSource]),@"explicit presentation opt-in creates native spin button");
  [compactSource setFrame:originalFrame]; [compactSource setGtk4NativeUsesSpinButton:NO]; pump(.15);
  compact=[peers widgetForView:compactSource];
  CHECK(GTK4NativeIsStepper(compact) && NSEqualRects(compactSource.frame,originalFrame),@"returning to compact presentation restores original geometry");
  [compactSource setMinValue:0]; [compactSource setMaxValue:10]; [compactSource setDoubleValue:0]; [compactSource setIncrement:1]; pump(.1);
  compactUp=gtk_widget_get_first_child(compact); click(compactUp,host);
  buttonEvent(input,1,True,CurrentTime); XFlush(input); pump(.1);
  [compactSource removeFromSuperview]; pump(.1); before=actions->count; pump(.65);
  CHECK(![peers widgetForView:compactSource] && actions->count==before,@"detaching compact stepper cancels hold timer");
  buttonEvent(input,1,False,CurrentTime); XFlush(input); pump(.1);
  CHECK(fabs(gtk_progress_bar_get_fraction(GTK_PROGRESS_BAR([peers widgetForView:progress]))-.25)<.001,@"progress fraction honors nonzero minimum");
  CHECK(!g_object_get_data(G_OBJECT([peers widgetForView:progress]),"appkit-progress-tick"),@"determinate progress has no frame callback");
  CHECK(g_object_get_data(G_OBJECT([peers widgetForView:pulse]),"appkit-progress-tick"),@"indeterminate progress pulses on GTK frame clock");
  CHECK(pulse.isAnimating && ![pulse valueForKey:@"_timer"] && ![spinner valueForKey:@"_timer"],@"GTK owns animation without AppKit timer");
  CHECK(gtk_spinner_get_spinning(GTK_SPINNER([peers widgetForView:spinner])),@"spinner animates natively");
  [spinner stopAnimation:nil]; pump(.1);
  CHECK(![peers widgetForView:spinner] || !gtk_widget_get_visible([peers widgetForView:spinner]),@"stopped spinner hides");
  [spinner setDisplayedWhenStopped:YES]; pump(.1);
  CHECK(gtk_widget_get_visible([peers widgetForView:spinner]),@"displayedWhenStopped synchronizes");
  [spinner setIndeterminate:NO]; [spinner setDoubleValue:65]; pump(.15);
  CHECK(GTK_IS_PROGRESS_BAR([peers widgetForView:spinner]),@"determinate spinning variant maps to GTK progress bar");
  int progressMinimum=0;
  GtkWidget *linearProgress=[peers widgetForView:spinner];
  gtk_widget_measure(linearProgress,GTK_ORIENTATION_HORIZONTAL,-1,&progressMinimum,NULL,NULL,NULL);
  CHECK(gtk_widget_get_width(linearProgress)>=progressMinimum,@"progress presentation changes retain the native themed minimum width");
  [pulse removeFromSuperview]; pump(.1);
  CHECK(!GSNativeViewPeerForView(pulse) && [pulse valueForKey:@"_timer"],@"detached animation returns to AppKit lifecycle");
  [pulse stopAnimation:nil];
  [window close]; pump(.1);
  NSLog(@"PASS: compact stepper/geometry/input/repeat/binding/teardown and opt-in spin button, combo/menu/editing, sliders/actions/ticks/zero-range, progress/spinner/animation lifecycle");
  [window release]; [actions release]; XCloseDisplay(input); dlclose(xtst); [pool drain]; return 0;
}
