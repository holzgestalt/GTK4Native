#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#import "GTK4NativeControls.h"
#import "GTK4Renderer.h"
#import "GTK4NativeCustomView.h"
#import <GNUstepGUI/GSTheme.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>

#define CHECK(c,m) NSCAssert((c),(m))
@interface NSTableView (ResizePrototype)
- (void)_registerPrototypeViews:(NSArray *)views;
@end

@interface ResizeSplit : NSSplitView { @public NSUInteger appKitDraws; } @end
@implementation ResizeSplit
- (void)drawRect:(NSRect)rect { appKitDraws++; [super drawRect:rect]; }
- (void)setFrame:(NSRect)frame
{
  CHECK(!GSNativeViewPeerForView(self) || g_main_depth()==0,@"GTK allocation never sets AppKit split frames");
  [super setFrame:frame];
}
@end
@interface ResizePlain : NSView @end
@implementation ResizePlain
- (void)setFrame:(NSRect)frame
{
  CHECK(!GSNativeViewPeerForView(self) || g_main_depth()==0,@"GTK allocation never sets AppKit container frames");
  [super setFrame:frame];
}
@end
@interface ResizeText : NSTextView
{
@public
  NSUInteger bitmapDraws;
}
@end
@implementation ResizeText
- (void)drawRect:(NSRect)rect
{
  CHECK([[NSGraphicsContext currentContext] isFlipped]==self.isFlipped,@"AppKit text retains its flipped graphics context inside GTK");
  if(![NSGraphicsContext currentContextDrawingToScreen]) bitmapDraws++;
  [super drawRect:rect];
}
@end

static NSTableCellView *rowCell(void)
{
  NSTableCellView *cell=[[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,220,22)] autorelease];
  cell.identifier=@"row";
  NSTextField *label=[[[NSTextField alloc] initWithFrame:NSMakeRect(5,0,210,22)] autorelease];
  [label setEditable:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
  label.autoresizingMask=NSViewWidthSizable;
  [cell addSubview:label]; cell.textField=label;
  [label bind:NSValueBinding toObject:cell withKeyPath:@"objectValue" options:nil];
  return cell;
}
@interface ResizeData : NSObject
{
@public
  NSUInteger templates;
}
@end
@implementation ResizeData
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return 500; }
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{ return [NSString stringWithFormat:@"Row %ld",(long)row]; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{ templates++; return rowCell(); }
- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item { return item ? 0 : 3; }
- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{ return [@[@"One",@"Two",@"Three"] objectAtIndex:index]; }
- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item { return NO; }
- (id)outlineView:(NSOutlineView *)outline objectValueForTableColumn:(NSTableColumn *)column byItem:(id)item { return item; }
- (NSView *)outlineView:(NSOutlineView *)outline viewForTableColumn:(NSTableColumn *)column item:(id)item
{ templates++; return rowCell(); }
@end

static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while(end.timeIntervalSinceNow>0) {
    for(int i=0;g_main_depth()==0 && i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.005]
      inMode:NSEventTrackingRunLoopMode dequeue:YES];
    if(event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static void fits(GtkWidget *widget,NSView *source,GTK4NativeWindowDecorationView *host)
{
  graphene_rect_t actual,body;
  CHECK(gtk_widget_compute_bounds(widget,host->_nativeContent,&actual),@"native viewport is allocated");
  CHECK(gtk_widget_compute_bounds(host->_nativeContent,host->_host,&body),@"host content is allocated");
  NSRect rect=[source convertRect:source.bounds toView:host];
  CGFloat scale=source.window.userSpaceScaleFactor/MAX(1,gtk_widget_get_scale_factor(host->_host));
  CGFloat x=(NSMinX(rect)-NSMinX(host.bounds))*scale-body.origin.x;
  CGFloat y=(host.isFlipped ? NSMinY(rect)-NSMinY(host.bounds) : NSMaxY(host.bounds)-NSMaxY(rect))*scale-body.origin.y;
  if(fabs(actual.origin.x-x)>1 || fabs(actual.origin.y-y)>1
      || fabs(actual.size.width-NSWidth(rect)*scale)>1 || fabs(actual.size.height-NSHeight(rect)*scale)>1)
    NSLog(@"Resize geometry: allocated %.0f,%.0f %.0fx%.0f expected %.0f,%.0f %.0fx%.0f",
      actual.origin.x,actual.origin.y,actual.size.width,actual.size.height,x,y,NSWidth(rect)*scale,NSHeight(rect)*scale);
  CHECK(fabs(actual.origin.x-x)<=1 && fabs(actual.origin.y-y)<=1
    && fabs(actual.size.width-NSWidth(rect)*scale)<=1 && fabs(actual.size.height-NSHeight(rect)*scale)<=1,
    @"native allocation follows the latest AppKit split frame in the same update");
}
static void opaque(GtkWidget *widget,GTK4NativeWindowDecorationView *host)
{
  GtkSnapshot *snapshot=gtk_snapshot_new();
  // Capture the live widget directly. A newly created GtkWidgetPaintable may
  // not yet have received a cached image when its GtkBox parent is unchanged.
  gtk_widget_snapshot_child(gtk_widget_get_parent(widget),widget,snapshot);
  GskRenderNode *node=gtk_snapshot_free_to_node(snapshot);
  CHECK(node,@"native viewport produces a render node");
  graphene_rect_t area;
  CHECK(gtk_widget_compute_bounds(widget,gtk_widget_get_parent(widget),&area),@"snapshot allocation is available");
  GdkTexture *texture=gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(host->_host)),node,&area);
  int width=gdk_texture_get_width(texture),height=gdk_texture_get_height(texture);
  guchar *pixels=g_malloc(width*height*4);
  gdk_texture_download(texture,pixels,width*4);
  /* Empty areas below the short outline and inside plain views must never
   * make the composed window transparent. Ignore text and scrollbar edges. */
  CHECK(pixels[((height*3/4)*width+width/2)*4+3]==255,@"native viewport background is opaque below its content");
  g_free(pixels); g_object_unref(texture); gsk_render_node_unref(node);
}

static int (*movePointer)(Display *,int,int,int,unsigned long);
static int (*pointerButton)(Display *,unsigned int,int,unsigned long);
static void modelChanged(GListModel *model,guint position,guint removed,guint added,gpointer count)
{ (*(NSUInteger *)count)++; }
static void unmapped(GtkWidget *widget,gpointer count) { (*(NSUInteger *)count)++; }
static gboolean depthProbe(gpointer data)
{
  CHECK(g_main_depth()==1,@"AppKit synchronization does not reenter GTK's active frame");
  return G_SOURCE_REMOVE;
}
static gboolean synchronizeFromGTK(gpointer host)
{
  g_idle_add(depthProbe,NULL);
  GTK4NativeWindowDecorationView *decoration=host;
  NSView *content=decoration.window.contentView;
  GtkWidget *native=[decoration->_nativeControls widgetForView:content];
  NSButton *temporary=[[[NSButton alloc] initWithFrame:NSMakeRect(0,0,50,20)] autorelease];
  [content addSubview:temporary];
  [decoration synchronizeNativeWindow:nil];
  CHECK([decoration->_nativeControls widgetForView:content]==native,
    @"synchronization inside GTK callbacks never replaces the active widget tree");
  [temporary removeFromSuperview];
  return G_SOURCE_REMOVE;
}
@interface ResizeDrag : NSObject
{
@public
  Display *display;
  int x,y;
  NSUInteger step,changes;
  NSUInteger paneIndex,livePaints,previousPaints;
  ResizeText *rightEditor;
  NSSplitView *split;
  CGFloat previousWidth;
  GtkWidget *nativePane;
}
@end
@implementation ResizeDrag
- (void)advance:(NSTimer *)timer
{
  CGFloat width=gtk_widget_get_width(nativePane);
  if(fabs(width-previousWidth)>1) changes++;
  if(rightEditor && rightEditor->bitmapDraws>previousPaints) livePaints++;
  if(rightEditor) previousPaints=rightEditor->bitmapDraws;
  previousWidth=width;
  step++;
  if(step<14) movePointer(display,-1,x+(step<7?step:14-step)*6,y,CurrentTime);
  else { pointerButton(display,1,False,CurrentTime); [timer invalidate]; }
  XFlush(display);
}
@end
int main(void)
{
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp finishLaunching];
    GTK4Renderer reference={0};
    CHECK(gtk4_renderer_init(&reference),@"GTK reference widgets initialize");
    GtkBorder frameBorder;
    gtk_style_context_get_border(gtk_widget_get_style_context(reference.scroll_frame),&frameBorder);
    CGFloat metricScale=gtk_widget_get_scale_factor(reference.window)/[[NSScreen mainScreen] userSpaceScaleFactor];
    NSSize expectedBorder=NSMakeSize(MAX(frameBorder.left,frameBorder.right)*metricScale,MAX(frameBorder.top,frameBorder.bottom)*metricScale);
    CHECK(NSEqualSizes([[GSTheme theme] scrollViewBorderSizeForType:NSBezelBorder],expectedBorder),@"scroll layout uses GTK scrolled-window border metrics");
    NSSize content=[NSScrollView contentSizeForFrameSize:NSMakeSize(100,80) hasHorizontalScroller:NO hasVerticalScroller:NO borderType:NSBezelBorder];
    CHECK(NSEqualSizes(content,NSMakeSize(100-2*expectedBorder.width,80-2*expectedBorder.height)),@"AppKit scroll content matches GTK frame insets");
    for(int axis=0;axis<2;axis++) {
      NSSplitView *probe=[[[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,100,100)] autorelease];
      [probe setVertical:axis==0];
      int minimum=0,natural=0;
      gtk_widget_measure(reference.split_separator[axis],axis==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL,
        -1,&minimum,&natural,NULL,NULL);
      CHECK(fabs([[GSTheme theme] splitViewDividerThickness:probe]-MAX(minimum,natural)*metricScale)<.01,@"split separator metrics convert GTK units to AppKit units");
      CHECK(fabs(probe.dividerThickness-MAX(minimum,natural)*metricScale)<.01,@"split thickness matches the actual GTK separator at this scale");
    }
    gtk4_renderer_clear(&reference);
    NSScrollView *unhosted=[[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,210.5,160.5)] autorelease];
    unhosted.hasVerticalScroller=YES; unhosted.hasHorizontalScroller=YES;
    unhosted.autohidesScrollers=YES;
    NSView *document=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,100,100)] autorelease];
    document.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    unhosted.documentView=document;
    NSView *verticalParent=unhosted.verticalScroller.superview,*horizontalParent=unhosted.horizontalScroller.superview;
    for(int step=0;step<20;step++) {
      [document setFrameSize:step%2?NSMakeSize(700,900):NSMakeSize(50,50)];
      [unhosted reflectScrolledClipView:unhosted.contentView];
      CHECK(unhosted.verticalScroller.superview==verticalParent
        && unhosted.horizontalScroller.superview==horizontalParent,@"GTK provider never runs AppKit autohiding, even before peer attachment");
    }
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,1000,440)
      styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    ResizeSplit *split=[[[ResizeSplit alloc] initWithFrame:[window.contentView bounds]] autorelease];
    split.vertical=YES; split.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [window.contentView addSubview:split];
    ResizeData *data=[ResizeData new];
    NSScrollView *scrolls[3]; NSTableView *tables[2];
    for(NSUInteger i=0;i<4;i++) {
      NSView *pane;
      if(i<3) {
        NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(i*250,0,245,440)] autorelease];
        scroll.hasVerticalScroller=YES; pane=scroll; scrolls[i]=scroll;
        scroll.borderType=i==0?NSBezelBorder:NSNoBorder;
        if(i<2) {
          NSTableView *table=i ? [[[NSOutlineView alloc] initWithFrame:NSMakeRect(0,0,240,440)] autorelease]
            : [[[NSTableView alloc] initWithFrame:NSMakeRect(0,0,240,11000)] autorelease];
          NSTableColumn *column=[[[NSTableColumn alloc] initWithIdentifier:@"row"] autorelease];
          column.width=230; [table addTableColumn:column]; table.headerView=nil; table.rowHeight=22;
          table.autoresizingMask=NSViewWidthSizable; [table _registerPrototypeViews:@[rowCell()]];
          table.delegate=(id)data; table.dataSource=(id)data;
          if(i) [(NSOutlineView *)table setOutlineTableColumn:column];
          scroll.documentView=table; [table reloadData]; tables[i]=table;
        } else {
          NSView *document=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,230,900)] autorelease];
          scroll.documentView=document;
        }
      } else pane=[[[ResizePlain alloc] initWithFrame:NSMakeRect(750,0,245,440)] autorelease];
      [split addSubview:pane];
    }
    [split adjustSubviews]; [window makeKeyAndOrderFront:nil]; pump(.5);
    GTK4NativeWindowDecorationView *host=(id)[window.contentView superview];
    GTK4NativeTable *peers[2]={[tables[0] valueForKey:@"_nativeTableView"],[tables[1] valueForKey:@"_nativeTableView"]};
    CHECK(peers[0] && peers[1],@"table and outline use native peers");
    CHECK(gtk_scrolled_window_get_has_frame(GTK_SCROLLED_WINDOW(peers[0].widget))
      && !gtk_scrolled_window_get_has_frame(GTK_SCROLLED_WINDOW(peers[1].widget)),@"native scroll views use GTK frames only when requested");
    g_idle_add(synchronizeFromGTK,host);
    while(g_main_context_pending(NULL)) g_main_context_iteration(NULL,FALSE);
    XWindowAttributes backend;
    Display *display=(Display *)[GSServerForWindow(window) serverDevice];
    CHECK(XGetWindowAttributes(display,host->_child,&backend) && backend.map_state!=IsViewable,
      @"GTK owns the complete visible window; the backend surface stays unmapped");
    NSPoint divider=[split convertPoint:NSMakePoint(NSMaxX([[split.subviews objectAtIndex:0] frame])+split.dividerThickness/2,200) toView:host];
    CGFloat factor=window.userSpaceScaleFactor/MAX(1,gtk_widget_get_scale_factor(host->_host));
    GtkWidget *picked=gtk_widget_pick(host->_host,divider.x*factor,(NSMaxY(host.bounds)-divider.y)*factor,GTK_PICK_DEFAULT);
    NSLog(@"Divider GTK target: %s",picked?G_OBJECT_TYPE_NAME(picked):"none");
    if(!picked) NSLog(@"Divider source=%@ split=%@ root=%@ host=%@ native=%dx%d",NSStringFromPoint(divider),NSStringFromRect(split.frame),NSStringFromRect([window.contentView frame]),NSStringFromRect(host.bounds),gtk_widget_get_width(host->_host),gtk_widget_get_height(host->_host));
    CHECK(picked && !GTK4NativeIsCustomView(picked),@"GTK hit testing routes divider input directly to GTK");
    GListModel *models[2]={G_LIST_MODEL(peers[0]->_model),G_LIST_MODEL(peers[1]->_model)};
    NSUInteger reloads=0,templates=data->templates;
    gulong handlers[2]={g_signal_connect(models[0],"items-changed",G_CALLBACK(modelChanged),&reloads),
      g_signal_connect(models[1],"items-changed",G_CALLBACK(modelChanged),&reloads)};
    GtkWidget *scrollWidget=[host->_nativeControls widgetForView:scrolls[2]];
    NSView *plain=[split.subviews objectAtIndex:3];
    GtkWidget *plainWidget=[host->_nativeControls widgetForView:plain];
    CHECK(scrollWidget && plainWidget,@"scroll document and plain content use native scenes");
    /* Catch geometry lag without allowing the polling timer or frame clock
     * to hide it. This is the update boundary used during mouse tracking. */
    for(NSUInteger step=0;step<12;step++) {
      [split setPosition:180+(step%4)*25 ofDividerAtIndex:0];
      [split setPosition:530+(step%3)*20 ofDividerAtIndex:1];
      [split setPosition:770+(step%2)*35 ofDividerAtIndex:2];
      [split setNeedsDisplay:YES];
      [window displayIfNeeded]; [window flushWindowIfNeeded]; pump(.04);
      if(getenv("GTK4_RESIZE_TRACE")) {
        GtkWidget *paned=[host->_nativeControls widgetForView:split];
        for(NSUInteger i=0;i<split.subviews.count;i++) {
          NSView *pane=split.subviews[i];
          NSLog(@"step %lu pane %lu %@ paned position %d",(unsigned long)step,(unsigned long)i,NSStringFromRect(pane.frame),GTK_IS_PANED(paned)?gtk_paned_get_position(GTK_PANED(paned)):-1);
          if(GTK_IS_PANED(paned)) paned=gtk_paned_get_end_child(GTK_PANED(paned));
        }
      }
      fits(peers[0].widget,scrolls[0],host); fits(peers[1].widget,scrolls[1],host);
      fits(scrollWidget,scrolls[2],host);
      fits(plainWidget,plain,host);
      CHECK(G_LIST_MODEL(peers[0]->_model)==models[0] && G_LIST_MODEL(peers[1]->_model)==models[1],@"resizing keeps native list models");
      pump(.025);
    }
    NSUInteger unmaps=0;
    gulong unmapHandlers[2]={g_signal_connect(peers[0]->_list,"unmap",G_CALLBACK(unmapped),&unmaps),
      g_signal_connect(peers[1]->_list,"unmap",G_CALLBACK(unmapped),&unmaps)};
    GtkWidget *stableSplit=[host->_nativeControls widgetForView:split];
    GtkWidget *stableLists[2]={peers[0]->_list,peers[1]->_list};
    NSUInteger oldTemplates=data->templates;
    for(NSUInteger change=0;change<4;change++) {
      NSButton *content=[[[NSButton alloc] initWithFrame:NSMakeRect(10,10,130,28)] autorelease];
      content.title=[NSString stringWithFormat:@"Editor %lu",(unsigned long)change];
      [plain addSubview:content]; pump(.12);
      CHECK(GTK_IS_BUTTON([host->_nativeControls widgetForView:content]),@"new pane content is attached to GTK");
      CHECK([host->_nativeControls widgetForView:split]==stableSplit && peers[0]->_list==stableLists[0]
        && peers[1]->_list==stableLists[1],@"replacing editor content keeps its sibling widgets");
      [content removeFromSuperview]; pump(.12);
    }
    CHECK(unmaps==0 && reloads==0 && data->templates==oldTemplates,
      @"editor content changes never unmap, reload or recreate sibling table rows");
    for(int i=0;i<2;i++) g_signal_handler_disconnect(stableLists[i],unmapHandlers[i]);
    opaque(peers[1].widget,host);
    opaque(host->_nativeBackground,host);
    /* The right pane must use the AppKit drawing adapter during the drag,
     * rather than checking only model frames and native GTK allocations. */
    ResizeText *rightEditor=[[[ResizeText alloc] initWithFrame:scrolls[2].frame] autorelease];
    [rightEditor setString:@"The right editor must reflow and repaint while the divider is held down."];
    [split replaceSubview:scrolls[2] with:rightEditor]; [window display]; pump(.2);
    /* GTK handles divider input and layout without AppKit tracking. */
    void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
    CHECK(xtst,@"XTest input library");
    movePointer=dlsym(xtst,"XTestFakeMotionEvent"); pointerButton=dlsym(xtst,"XTestFakeButtonEvent");
    int (*key)(Display *,unsigned int,int,unsigned long)=dlsym(xtst,"XTestFakeKeyEvent");
    CHECK(movePointer && pointerButton && key,@"XTest input functions");
    GtkWidget *nativeSplit=[host->_nativeControls widgetForView:split];
    CHECK(GTK_IS_PANED(nativeSplit),@"the split is a live GtkPaned");
    CHECK(peers[0]->_embedded && peers[1]->_embedded
      && gtk_widget_is_ancestor(peers[0].widget,nativeSplit)
      && gtk_widget_is_ancestor(peers[1].widget,nativeSplit),@"native tables belong to the GTK pane hierarchy");
    NSUInteger splitDraws=split->appKitDraws;
    const char *roundsValue=getenv("GTK4_DRAG_ROUNDS");
    int rounds=roundsValue?MAX(1,atoi(roundsValue)):3;
    NSUInteger dragTemplates=data->templates;
    for(int round=0;round<rounds;round++) {
    divider=[split convertPoint:NSMakePoint(NSMaxX([[split.subviews objectAtIndex:1] frame])+split.dividerThickness/2,200) toView:host];
    double dx,dy; gtk_native_get_surface_transform(GTK_NATIVE(host->_host),&dx,&dy);
    int backing=gtk_widget_get_scale_factor(host->_host),x,y; Window unused;
    XTranslateCoordinates(display,host->_parent,DefaultRootWindow(display),
      floor((dx+divider.x*factor)*backing),floor((dy+(NSMaxY(host.bounds)-divider.y)*factor)*backing),&x,&y,&unused);
    ResizeDrag *drag=[ResizeDrag new]; drag->display=display; drag->x=x; drag->y=y; drag->split=split;
    drag->paneIndex=1; drag->rightEditor=rightEditor; drag->previousPaints=rightEditor->bitmapDraws;
    drag->nativePane=[host->_nativeControls widgetForView:split.subviews[1]];
    drag->previousWidth=gtk_widget_get_width(drag->nativePane);
    NSTimer *timer=[NSTimer timerWithTimeInterval:.03 target:drag selector:@selector(advance:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
    host->_placing=YES; // No host geometry polling or widget-tree synchronization.
    movePointer(display,-1,x,y,CurrentTime); pointerButton(display,1,True,CurrentTime); XFlush(display); pump(1.0);
    host->_placing=NO;
    CHECK(drag->changes>=3,@"GTK allocates panes before pointer release without AppKit synchronization");
    NSLog(@"During held drag: %lu pane changes, %lu right-editor GTK repaints",(unsigned long)drag->changes,(unsigned long)drag->livePaints);
    CHECK(drag->livePaints>=3,@"right editor repaints into GTK repeatedly before mouse release");
    [timer invalidate]; [drag release];
    /* The final mouse-up can finish the nested tracking loop after pump's
     * deadline. Commit its last layout at the normal display boundary. */
    [window displayIfNeeded]; [window flushWindowIfNeeded]; pump(.1);
    fits(peers[0].widget,scrolls[0],host); fits(peers[1].widget,scrolls[1],host);
    CHECK([host->_nativeControls widgetForView:split]==nativeSplit,@"dragging preserves the live GTK tree");
    CHECK(split->appKitDraws==splitDraws,@"AppKit does not paint split backgrounds or dividers");
    }
    CHECK(data->templates==dragTemplates,@"native dragging does not rebuild table row templates");
    /* Editing a remaining AppKit text view uses the GTK content node too. */
    NSTextView *editor=[[[ResizeText alloc] initWithFrame:NSMakeRect(10,10,120,100)] autorelease];
    [plain addSubview:editor]; [window display]; pump(.2);
    [window makeFirstResponder:editor]; gtk_widget_grab_focus([host->_nativeControls widgetForView:editor]);
    XSetInputFocus(display,host->_parent,RevertToParent,CurrentTime);
    key(display,XKeysymToKeycode(display,XK_a),True,CurrentTime);
    key(display,XKeysymToKeycode(display,XK_a),False,CurrentTime); XFlush(display); pump(.2);
    CHECK([[editor string] containsString:@"a"],@"GTK keyboard and input-method events reach the AppKit editor");
    CHECK(XGetWindowAttributes(display,host->_child,&backend) && backend.map_state!=IsViewable,@"editing never maps the backend window");
    CHECK(reloads==0,@"divider dragging does not reload native table or outline models");
    NSLog(@"Resize work: %lu model reloads, %lu additional row templates",(unsigned long)reloads,(unsigned long)(data->templates-templates));
    g_signal_handler_disconnect(models[0],handlers[0]); g_signal_handler_disconnect(models[1],handlers[1]);
    [window close]; [window release]; [data release];
    NSLog(@"PASS: GTK-owned window, real divider dragging and editor input, table/outline geometry, scroll scene and content opacity");
  }
  return 0;
}
