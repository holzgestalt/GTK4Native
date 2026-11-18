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
// Exercise native containers inside a custom GTK-hosted document.
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
static void countedNativeClick(GtkWidget *widget,gpointer data) { (*(NSInteger *)data)++; }
@interface TabDelegate : NSObject
{
@public
  NSInteger should,will,did;
  BOOL reject;
}
@end
@implementation TabDelegate
- (BOOL)tabView:(NSTabView *)tabs shouldSelectTabViewItem:(NSTabViewItem *)item { should++; return !reject; }
- (void)tabView:(NSTabView *)tabs willSelectTabViewItem:(NSTabViewItem *)item { will++; }
- (void)tabView:(NSTabView *)tabs didSelectTabViewItem:(NSTabViewItem *)item { did++; }
@end
static GtkWidget *findType(GtkWidget *widget,GType type)
{
  if(G_TYPE_CHECK_INSTANCE_TYPE(widget,type)) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=findType(child,type); if(found) return found;
  }
  return NULL;
}
static GtkWidget *findLabel(GtkWidget *widget,const char *text)
{
  if(GTK_IS_LABEL(widget) && !strcmp(gtk_label_get_text(GTK_LABEL(widget)),text)) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=findLabel(child,text); if(found) return found;
  }
  return NULL;
}
static NSButton *addButton(NSView *view,ButtonActions *actions,NSString *title)
{
  NSButton *button=[[[NSButton alloc] initWithFrame:NSMakeRect(15,15,180,36)] autorelease];
  [button setTitle:title]; [button setBezelStyle:NSRoundedBezelStyle];
  [button setTarget:actions]; [button setAction:@selector(action:)]; [view addSubview:button];
  return button;
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
  // Keep this suite on the mixed-content path; complete scenes have their own test.
  NSTextView *fallback=[[[NSTextView alloc] initWithFrame:NSZeroRect] autorelease];
  [page addSubview:fallback];

  NSTabView *tabs=[[[NSTabView alloc] initWithFrame:NSMakeRect(20,20,700,240)] autorelease];
  NSMutableArray *items=[NSMutableArray array],*buttons=[NSMutableArray array];
  for(NSInteger i=0;i<3;i++) {
    NSTabViewItem *item=[[[NSTabViewItem alloc] initWithIdentifier:@(i)] autorelease];
    [item setLabel:@[@"General",@"Details",@"Advanced"][i]];
    NSView *content=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,660,180)] autorelease];
    NSBox *inner=[[[NSBox alloc] initWithFrame:NSMakeRect(12,12,330,110)] autorelease];
    [inner setTitle:@"Nested group"]; [content addSubview:inner];
    NSButton *button=addButton(inner.contentView,actions,[NSString stringWithFormat:@"Page %ld action",(long)i]);
    [buttons addObject:button]; [item setView:content]; [item setInitialFirstResponder:button];
    [tabs addTabViewItem:item]; [items addObject:item];
  }
  [page addSubview:tabs];
  TabDelegate *delegate=[TabDelegate new]; [tabs setDelegate:delegate];
  NSBox *box=[[[NSBox alloc] initWithFrame:NSMakeRect(20,290,330,140)] autorelease];
  [box setTitle:@"Group title"]; [box setContentViewMargins:NSMakeSize(9,11)];
  NSButton *grouped=addButton(box.contentView,actions,@"Grouped action"); [page addSubview:box];
  NSBox *separator=[[[NSBox alloc] initWithFrame:NSMakeRect(20,450,700,2)] autorelease];
  [separator setBoxType:NSBoxSeparator]; [page addSubview:separator];
  NSBox *custom=[[[NSBox alloc] initWithFrame:NSMakeRect(390,290,330,140)] autorelease];
  [custom setBoxType:NSBoxCustom]; [custom setFillColor:[NSColor magentaColor]]; [page addSubview:custom];
  CHECK([GTK4NativeView supportsView:custom],@"custom source boxes retain native container layout");
  NSTabView *unsupported=[[[NSTabView alloc] initWithFrame:NSMakeRect(0,0,300,180)] autorelease];
  NSTabViewItem *unsupportedItem=[[[NSTabViewItem alloc] initWithIdentifier:@"unsupported"] autorelease];
  [unsupportedItem setView:[[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,200,100)] autorelease]];
  [unsupported addTabViewItem:unsupportedItem];
  CHECK([GTK4NativeView supportsView:unsupported],@"rich text tab content can use the custom GTK drawing adapter");
  [window makeKeyAndOrderFront:nil]; pump(.35);
  GTK4NativeWindowDecorationView *host=(id)[[window contentView] superview];
  GTK4NativeControls *peers=host->_nativeControls;
  GtkWidget *nativeTabs=[peers widgetForView:tabs],*stack=findType(nativeTabs,GTK_TYPE_STACK);
  CHECK(GTK_IS_STACK(stack) && findType(nativeTabs,GTK_TYPE_STACK_SWITCHER),@"tabs use a real GTK stack and switcher");
  CHECK(GTK_IS_FRAME([peers widgetForView:box]) && GTK_IS_SEPARATOR([peers widgetForView:separator]),@"boxes use GtkFrame and separators use GtkSeparator");
  CHECK(GTK_IS_FRAME([peers widgetForView:custom]),@"GTK owns source box backgrounds and borders");
  GtkWidget *firstButton=[peers widgetForView:buttons[0]];
  CHECK(firstButton && [peers widgetForView:buttons[1]] && [peers widgetForView:buttons[2]],@"all tab pages have stable native child peers");
  CHECK(gtk_widget_get_mapped(firstButton) && !gtk_widget_get_mapped([peers widgetForView:buttons[1]]),@"only selected tab content is mapped");
  delegate->should=delegate->will=delegate->did=0;
  GtkWidget *details=findLabel(nativeTabs,"Details"); CHECK(details,@"native tab label exists"); click(details,host);
  CHECK(tabs.selectedTabViewItem==items[1] && delegate->should==1 && delegate->will==1 && delegate->did==1,@"real tab click follows AppKit delegate selection once");
  CHECK([peers widgetForView:tabs]==nativeTabs && [peers widgetForView:buttons[0]]==firstButton,@"tab selection preserves widgets instead of rebuilding scene");
  CHECK(!gtk_widget_get_mapped(firstButton) && gtk_widget_get_mapped([peers widgetForView:buttons[1]]),@"GTK owns selected page visibility");
  NSInteger before=actions->count; click([peers widgetForView:buttons[1]],host);
  CHECK(actions->count==before+1 && actions->sender==buttons[1],@"nested tab/box content sends original control action");
  delegate->reject=YES; click(findLabel(nativeTabs,"Advanced"),host);
  CHECK(tabs.selectedTabViewItem==items[1] && delegate->should==2 && delegate->will==1 && delegate->did==1,@"delegate veto restores GTK selection without duplicate callbacks");
  CHECK(g_object_get_data(G_OBJECT(gtk_stack_get_visible_child(GTK_STACK(stack))),"appkit-tab-item")==items[1],@"stack agrees with vetoed AppKit selection");
  delegate->reject=NO; [tabs selectTabViewItem:items[0]]; pump(.15);
  CHECK(delegate->should==3 && delegate->will==2 && delegate->did==2 && gtk_widget_get_mapped(firstButton),@"programmatic selection synchronizes without duplicate delegate calls");
  NSInteger nativeClicks=0;
  g_signal_connect(firstButton,"clicked",G_CALLBACK(countedNativeClick),&nativeClicks);
  before=actions->count; key(XK_space);
  CHECK(actions->count==before+1 && actions->sender==buttons[0] && nativeClicks==1,@"programmatic tab selection focuses its native initial responder for keyboard input");
  g_signal_handlers_disconnect_by_data(firstButton,&nativeClicks);
  [items[1] setLabel:@"Renamed details"]; pump(.15);
  CHECK([peers widgetForView:tabs]==nativeTabs && findLabel(nativeTabs,"Renamed details"),@"tab labels update without replacing widgets");
  GtkWidget *nativeBox=[peers widgetForView:box]; before=actions->count; click([peers widgetForView:grouped],host);
  CHECK(actions->count==before+1 && actions->sender==grouped,@"framed child handles real input");
  [box setTitle:@"Renamed group"]; [box setContentViewMargins:NSMakeSize(15,17)]; pump(.15);
  CHECK([peers widgetForView:box]==nativeBox && !strcmp(gtk_frame_get_label(GTK_FRAME(nativeBox)),"Renamed group"),@"frame title updates without rebuilding");
  GtkWidget *nativeContent=[peers widgetForView:box.contentView];
  CHECK(gtk_widget_get_margin_start(nativeContent)==lround(15*[window userSpaceScaleFactor]/gtk_widget_get_scale_factor(nativeContent)),@"native frame honors source content margins");
  graphene_rect_t contentBounds;
  CHECK(gtk_widget_compute_bounds(nativeContent,nativeBox,&contentBounds) && contentBounds.origin.x>=0 && contentBounds.origin.y>=0
    && contentBounds.origin.x+contentBounds.size.width<=gtk_widget_get_width(nativeBox)
    && contentBounds.origin.y+contentBounds.size.height<=gtk_widget_get_height(nativeBox),@"native box clips and lays out content inside its frame");
  NSTabViewItem *added=[[[NSTabViewItem alloc] initWithIdentifier:@"added"] autorelease];
  [added setLabel:@"Added"]; NSView *addedView=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,660,180)] autorelease];
  NSButton *addedButton=addButton(addedView,actions,@"Added page action"); [added setView:addedView];
  [tabs insertTabViewItem:added atIndex:0]; pump(.15);
  nativeTabs=[peers widgetForView:tabs]; stack=findType(nativeTabs,GTK_TYPE_STACK);
  CHECK([peers widgetForView:addedButton] && tabs.selectedTabViewItem==items[0],@"inserting tab registers content and preserves selection");
  [tabs selectTabViewItem:added]; pump(.15); before=actions->count; click([peers widgetForView:addedButton],host);
  CHECK(actions->count==before+1 && actions->sender==addedButton,@"new page is interactive");
  [tabs removeTabViewItem:added]; pump(.15);
  CHECK(![peers widgetForView:addedButton] && tabs.selectedTabViewItem!=added,@"removing selected tab retires old peers and selects replacement");
  for(NSNumber *type in @[@(NSBottomTabsBezelBorder),@(NSLeftTabsBezelBorder),@(NSRightTabsBezelBorder),@(NSNoTabsNoBorder),@(NSTopTabsBezelBorder)]) {
    [tabs setTabViewType:type.integerValue]; pump(.15);
    nativeTabs=[peers widgetForView:tabs]; stack=findType(nativeTabs,GTK_TYPE_STACK);
    CHECK(stack,@"every native tab placement retains a GtkStack");
    if(type.integerValue==NSLeftTabsBezelBorder || type.integerValue==NSRightTabsBezelBorder)
      CHECK(findType(nativeTabs,GTK_TYPE_STACK_SIDEBAR),@"side tabs use GTK sidebar navigation");
    CHECK(gtk_stack_get_visible_child(GTK_STACK(stack))==[peers widgetForView:tabs.selectedTabViewItem.view],@"tab placement preserves selected page");
  }
  NSView *replacement=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,300,100)] autorelease];
  NSButton *replacementButton=addButton(replacement,actions,@"Replacement group action");
  [box setContentView:replacement]; pump(.15);
  CHECK(![peers widgetForView:grouped] && [peers widgetForView:replacementButton],@"box content replacement retires and creates peers");
  [box setTitlePosition:NSNoTitle]; pump(.1);
  CHECK(!gtk_frame_get_label(GTK_FRAME([peers widgetForView:box])),@"untitled box has no native title");
  [tabs setFrameSize:NSMakeSize(800,270)]; pump(.15);
  CHECK([peers widgetForView:tabs] && [peers widgetForView:tabs.selectedTabViewItem.view],@"resized tabs retain native content");
  nativeTabs=[peers widgetForView:tabs];
  [page scrollPoint:NSMakePoint(0,120)]; pump(.15);
  GtkWidget *viewport=gtk_widget_get_ancestor(nativeTabs,GTK_TYPE_SCROLLED_WINDOW);
  graphene_rect_t tabBounds,visibleBounds;
  graphene_rect_t viewportBounds=GRAPHENE_RECT_INIT(0,0,gtk_widget_get_width(viewport),gtk_widget_get_height(viewport));
  CHECK(gtk_widget_compute_bounds(nativeTabs,viewport,&tabBounds)
    && graphene_rect_intersection(&tabBounds,&viewportBounds,&visibleBounds)
    && visibleBounds.size.height<tabBounds.size.height
    && [peers widgetForView:tabs]==nativeTabs,@"outer GTK viewport clips tabs without rebuilding their native allocation");
  [page scrollPoint:NSZeroPoint]; pump(.15);
  [tabs removeFromSuperview]; [box removeFromSuperview]; pump(.15);
  CHECK(![peers widgetForView:tabs] && ![peers widgetForView:buttons[0]] && ![peers widgetForView:replacementButton],@"container detach clears descendant peers");
  [tabs setDelegate:nil]; [window close]; pump(.1);
  NSWindow *scene=[[NSWindow alloc] initWithContentRect:NSMakeRect(30,30,920,600)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [scene setReleasedWhenClosed:NO];
  [tabs setFrame:NSMakeRect(20,290,800,270)]; [[scene contentView] addSubview:tabs];
  [box setFrame:NSMakeRect(20,80,330,140)]; [[scene contentView] addSubview:box];
  [scene makeKeyAndOrderFront:nil]; pump(.3);
  GTK4NativeWindowDecorationView *sceneHost=(id)[[scene contentView] superview];
  GTK4NativeControls *scenePeers=sceneHost->_nativeControls;
  GtkWidget *sceneRoot=[scenePeers widgetForView:scene.contentView];
  CHECK(sceneRoot && [scenePeers widgetForView:tabs] && GTK_IS_FRAME([scenePeers widgetForView:box]),@"tabs and boxes also participate in a whole native GTK scene");
  GtkWidget *sceneTabs=[scenePeers widgetForView:tabs];
  click(findLabel(sceneTabs,"Renamed details"),sceneHost);
  CHECK(tabs.selectedTabViewItem==items[1] && [scenePeers widgetForView:scene.contentView]==sceneRoot,@"whole scene stays stable during native tab selection");
  [scene setContentSize:NSMakeSize(1020,680)]; pump(.2);
  CHECK([scenePeers widgetForView:scene.contentView]==sceneRoot,@"GTK layout handles whole-scene resize without recreating containers");
  before=actions->count; click([scenePeers widgetForView:buttons[1]],sceneHost);
  CHECK(actions->count==before+1 && actions->sender==buttons[1],@"nested input remains aligned after whole scene resize");
  [scene close]; pump(.1); [scene release];
  NSLog(@"PASS: GTK stack/frame, nested input, stable tab pages, delegate veto, labels, insertion/removal, orientations, margins, content replacement, fallback and teardown");
  [delegate release]; [window release]; [actions release]; XCloseDisplay(input); dlclose(xtst); [pool drain]; return 0;
}
