#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#import "GTK4NativeControls.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>

#define CHECK(c,m) NSCAssert((c),(m))
@interface NSTableView (ResizePrototype)
- (void)_registerPrototypeViews:(NSArray *)views;
@end

@interface ResizePlain : NSView @end
@implementation ResizePlain @end
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
  GdkPaintable *paintable=gtk_widget_paintable_new(widget);
  GtkSnapshot *snapshot=gtk_snapshot_new();
  int width=gtk_widget_get_width(widget),height=gtk_widget_get_height(widget);
  gdk_paintable_snapshot(paintable,GDK_SNAPSHOT(snapshot),width,height);
  GskRenderNode *node=gtk_snapshot_free_to_node(snapshot);
  CHECK(node,@"native viewport produces a render node");
  graphene_rect_t area=GRAPHENE_RECT_INIT(0,0,width,height);
  GdkTexture *texture=gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(host->_host)),node,&area);
  guchar *pixels=g_malloc(width*height*4);
  gdk_texture_download(texture,pixels,width*4);
  /* Empty areas below the short outline and inside plain views must never
   * make the composed window transparent. Ignore text and scrollbar edges. */
  CHECK(pixels[((height*3/4)*width+width/2)*4+3]==255,@"native viewport background is opaque below its content");
  g_free(pixels); g_object_unref(texture); gsk_render_node_unref(node); g_object_unref(paintable);
}

static int (*movePointer)(Display *,int,int,int,unsigned long);
static int (*pointerButton)(Display *,unsigned int,int,unsigned long);
static void modelChanged(GListModel *model,guint position,guint removed,guint added,gpointer count)
{ (*(NSUInteger *)count)++; }
static gboolean depthProbe(gpointer data)
{
  CHECK(g_main_depth()==1,@"AppKit synchronization does not reenter GTK's active frame");
  return G_SOURCE_REMOVE;
}
static gboolean synchronizeFromGTK(gpointer host)
{
  g_idle_add(depthProbe,NULL);
  [(GTK4NativeWindowDecorationView *)host synchronizeNativeWindow:nil];
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
}
@end
@implementation ResizeDrag
- (void)advance:(NSTimer *)timer
{
  CGFloat width=NSWidth([[split.subviews objectAtIndex:paneIndex] frame]);
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
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,1000,440)
      styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    NSSplitView *split=[[[NSSplitView alloc] initWithFrame:[window.contentView bounds]] autorelease];
    split.vertical=YES; split.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [window.contentView addSubview:split];
    ResizeData *data=[ResizeData new];
    NSScrollView *scrolls[3]; NSTableView *tables[2];
    for(NSUInteger i=0;i<4;i++) {
      NSView *pane;
      if(i<3) {
        NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(i*250,0,245,440)] autorelease];
        scroll.hasVerticalScroller=YES; pane=scroll; scrolls[i]=scroll;
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
    CHECK(picked==host->_appKitContent,@"GTK hit testing routes divider input to its AppKit content widget");
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
      [window displayIfNeeded]; [window flushWindowIfNeeded];
      fits(peers[0]->_clip,scrolls[0],host); fits(peers[1]->_clip,scrolls[1],host);
      fits(gtk_widget_get_parent(scrollWidget),scrolls[2],host);
      fits(gtk_widget_get_parent(plainWidget),plain,host);
      CHECK(G_LIST_MODEL(peers[0]->_model)==models[0] && G_LIST_MODEL(peers[1]->_model)==models[1],@"resizing keeps native list models");
      pump(.025);
    }
    opaque(peers[1]->_clip,host); opaque(gtk_widget_get_parent(scrollWidget),host); opaque(gtk_widget_get_parent(plainWidget),host);
    opaque(host->_nativeBackground,host);
    /* The right pane must use the AppKit drawing adapter during the drag,
     * rather than checking only model frames and native GTK allocations. */
    ResizeText *rightEditor=[[[ResizeText alloc] initWithFrame:scrolls[2].frame] autorelease];
    [rightEditor setString:@"The right editor must reflow and repaint while the divider is held down."];
    [split replaceSubview:scrolls[2] with:rightEditor]; [window display]; pump(.2);
    /* Real GTK pointer events enter AppKit's nested split tracking loop. */
    void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
    CHECK(xtst,@"XTest input library");
    movePointer=dlsym(xtst,"XTestFakeMotionEvent"); pointerButton=dlsym(xtst,"XTestFakeButtonEvent");
    int (*key)(Display *,unsigned int,int,unsigned long)=dlsym(xtst,"XTestFakeKeyEvent");
    CHECK(movePointer && pointerButton && key,@"XTest input functions");
    divider=[split convertPoint:NSMakePoint(NSMaxX([[split.subviews objectAtIndex:1] frame])+split.dividerThickness/2,200) toView:host];
    double dx,dy; gtk_native_get_surface_transform(GTK_NATIVE(host->_host),&dx,&dy);
    int backing=gtk_widget_get_scale_factor(host->_host),x,y; Window unused;
    XTranslateCoordinates(display,host->_parent,DefaultRootWindow(display),
      lround((dx+divider.x*factor)*backing),lround((dy+(NSMaxY(host.bounds)-divider.y)*factor)*backing),&x,&y,&unused);
    ResizeDrag *drag=[ResizeDrag new]; drag->display=display; drag->x=x; drag->y=y; drag->split=split;
    drag->paneIndex=1; drag->rightEditor=rightEditor; drag->previousPaints=rightEditor->bitmapDraws;
    drag->previousWidth=NSWidth([[split.subviews objectAtIndex:1] frame]);
    NSTimer *timer=[NSTimer timerWithTimeInterval:.03 target:drag selector:@selector(advance:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
    movePointer(display,-1,x,y,CurrentTime); pointerButton(display,1,True,CurrentTime); XFlush(display); pump(1.0);
    CHECK(drag->changes>=3,@"real GTK drag resizes AppKit panes before pointer release");
    NSLog(@"During held drag: %lu pane changes, %lu right-editor GTK repaints",(unsigned long)drag->changes,(unsigned long)drag->livePaints);
    CHECK(drag->livePaints>=3,@"right editor repaints into GTK repeatedly before mouse release");
    [timer invalidate]; [drag release];
    fits(peers[0]->_clip,scrolls[0],host); fits(peers[1]->_clip,scrolls[1],host);
    /* Editing a remaining AppKit text view uses the GTK content node too. */
    NSTextView *editor=[[[ResizeText alloc] initWithFrame:NSMakeRect(10,10,120,100)] autorelease];
    [plain addSubview:editor]; [window display]; pump(.2);
    [window makeFirstResponder:editor]; [host focusAppKitContent];
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
