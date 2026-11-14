#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <cairo-xlib.h>

#define CHECK(condition,message) NSCAssert((condition),(message))
@interface NSTableView (ScrollLayoutPrototype)
- (void)_registerPrototypeViews:(NSArray *)views;
@end
@interface ScrollLayoutPage : NSView
@end
@implementation ScrollLayoutPage
- (BOOL)isFlipped { return YES; }
@end
@interface ScrollLayoutSentinel : NSView
@end
@implementation ScrollLayoutSentinel
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)rect { [[NSColor magentaColor] set]; NSRectFill(rect); }
@end
@interface ScrollLayoutData : NSObject <NSTableViewDataSource,NSTableViewDelegate>
@end
@implementation ScrollLayoutData
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return 80; }
- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{ return [NSString stringWithFormat:@"Row %ld",(long)row+1]; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  NSTableCellView *cell=[[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,500,34)] autorelease];
  NSTextField *label=[[[NSTextField alloc] initWithFrame:NSMakeRect(12,7,470,22)] autorelease];
  [label setEditable:NO]; [label setBezeled:NO]; [label setDrawsBackground:NO];
  [label setStringValue:[self tableView:table objectValueForTableColumn:column row:row]];
  [cell addSubview:label]; [cell setTextField:label]; return cell;
}
@end
static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([end timeIntervalSinceNow]>0) {
    for (int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.005]
      inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static void clipped(GtkWidget *widget, GTK4NativeTable *peer, NSScrollView *inner,
  GTK4NativeWindowDecorationView *host, BOOL partial)
{
  NSRect visible=NSIntersectionRect(inner.bounds,inner.visibleRect);
  CGFloat factor=[inner.window userSpaceScaleFactor]/MAX(1,gtk_widget_get_scale_factor(host->_host));
  CHECK(fabs(NSWidth(peer.hostRect)-NSWidth(visible)*factor)<1.1
    && fabs(NSHeight(peer.hostRect)-NSHeight(visible)*factor)<1.1,@"native cutout follows ancestor visible rect");
  CHECK(gtk_widget_get_overflow(peer->_clip)==GTK_OVERFLOW_HIDDEN,@"native table has a GTK clip");
  CHECK(labs(gtk_widget_get_height(widget)-lround(NSHeight(inner.bounds)*factor))<=1,
    @"outer clipping preserves the full inner viewport allocation");
  if (partial) CHECK(NSHeight(peer.hostRect)<gtk_widget_get_height(widget)-20,@"partial visibility does not shrink the table viewport");
}
static unsigned long sample(NSView *view, GTK4NativeWindowDecorationView *host)
{
  NSPoint point=[view convertPoint:NSMakePoint(NSMidX(view.bounds),NSMidY(view.bounds)) toView:host];
  CGFloat factor=[view.window userSpaceScaleFactor]/MAX(1,gtk_widget_get_scale_factor(host->_host));
  double dx,dy; gtk_native_get_surface_transform(GTK_NATIVE(host->_host),&dx,&dy);
  int scale=gtk_widget_get_scale_factor(host->_host);
  int x=lround(((point.x-NSMinX(host.bounds))*factor+dx)*scale);
  int y=lround(((host.isFlipped ? point.y-NSMinY(host.bounds) : NSMaxY(host.bounds)-point.y)*factor+dy)*scale);
  Display *display=(Display *)[GSServerForWindow(view.window) serverDevice];
  XSync(display,False);
  XImage *image=XGetImage(display,host->_parent,x,y,1,1,AllPlanes,ZPixmap);
  CHECK(image,@"sample visible host pixel");
  unsigned long pixel=XGetPixel(image,0,0)&0xffffff; XDestroyImage(image); return pixel;
}
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  [NSApplication sharedApplication]; [NSApp finishLaunching];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(20,20,680,700)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  NSScrollView *outer=[[[NSScrollView alloc] initWithFrame:NSMakeRect(20,100,620,400)] autorelease];
  [outer setHasVerticalScroller:YES]; [window.contentView addSubview:outer];
  ScrollLayoutPage *page=[[[ScrollLayoutPage alloc] initWithFrame:NSMakeRect(0,0,600,1100)] autorelease];
  [outer setDocumentView:page];
  NSScrollView *inner=[[[NSScrollView alloc] initWithFrame:NSMakeRect(20,80,550,250)] autorelease];
  [inner setHasVerticalScroller:YES]; [page addSubview:inner];
  ScrollLayoutSentinel *sentinel=[[[ScrollLayoutSentinel alloc] initWithFrame:NSMakeRect(50,500,500,80)] autorelease];
  [window.contentView addSubview:sentinel];
  NSTableView *table=[[[NSTableView alloc] initWithFrame:NSMakeRect(0,0,530,2720)] autorelease];
  NSTableColumn *column=[[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
  [column setWidth:520]; [table addTableColumn:column]; [table setHeaderView:nil]; [table setRowHeight:34];
  NSTableCellView *prototype=[[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,500,34)] autorelease];
  [prototype setIdentifier:@"row"]; [table _registerPrototypeViews:@[prototype]];
  ScrollLayoutData *data=[ScrollLayoutData new];
  [table setDataSource:data]; [table setDelegate:data]; [inner setDocumentView:table];
  [table reloadData]; [page scrollPoint:NSZeroPoint];
  [window makeKeyAndOrderFront:nil]; pump(.6);
  GTK4NativeWindowDecorationView *host=(id)[window.contentView superview];
  GTK4NativeTable *peer=[table valueForKey:@"_nativeTableView"];
  CHECK(peer,@"view-based table uses a native peer");
  GtkWidget *widget=peer.widget;
  clipped(widget,peer,inner,host,NO);
  CHECK(sample(sentinel,host)==0xff00ff,@"sentinel above outer viewport is visible");
  double originalPage=gtk_adjustment_get_page_size(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)));
  [page scrollPoint:NSMakePoint(0,160)]; pump(.25);
  clipped(widget,peer,inner,host,YES);
  CHECK(sample(sentinel,host)==0xff00ff,@"native table cannot paint over content outside outer viewport");
  CHECK(fabs(gtk_adjustment_get_page_size(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)))-originalPage)<1,
    @"clipping does not change the table's own scroll page");
  [page scrollPoint:NSMakePoint(0,600)]; pump(.2);
  CHECK(NSIsEmptyRect(peer.hostRect) && !gtk_widget_get_mapped(widget),@"fully clipped table removes its drawing/input cutout");
  [page scrollPoint:NSZeroPoint]; pump(.2); clipped(widget,peer,inner,host,NO);
  CHECK(gtk_widget_get_mapped(widget),@"table reappears when scrolled back");
  [outer setFrameSize:NSMakeSize(480,300)];
  ScrollLayoutSentinel *right=[[[ScrollLayoutSentinel alloc] initWithFrame:NSMakeRect(500,100,150,300)] autorelease];
  [window.contentView addSubview:right];
  [window display]; pump(.2);
  CHECK(sample(right,host)==0xff00ff,@"table is clipped horizontally after outer viewport resize");
  clipped(widget,peer,inner,host,YES);
  const char *path=getenv("NATIVE_SCROLL_LAYOUT_PREVIEW");
  if (path) {
    Display *display=(Display *)[GSServerForWindow(window) serverDevice];
    XWindowAttributes attr; XGetWindowAttributes(display,host->_parent,&attr);
    cairo_surface_t *source=cairo_xlib_surface_create(display,host->_parent,attr.visual,attr.width,attr.height);
    cairo_surface_t *output=cairo_image_surface_create(CAIRO_FORMAT_RGB24,attr.width,attr.height);
    cairo_t *cr=cairo_create(output); cairo_set_source_surface(cr,source,0,0); cairo_paint(cr);
    CHECK(cairo_surface_write_to_png(output,path)==CAIRO_STATUS_SUCCESS,@"preview saved");
    cairo_destroy(cr); cairo_surface_destroy(output); cairo_surface_destroy(source);
  }
  [outer setDocumentView:[[[NSView alloc] initWithFrame:NSMakeRect(0,0,400,300)] autorelease]]; pump(.2);
  CHECK(gtk_widget_get_first_child(host->_nativeContent)==NULL,@"detaching page removes native table clip");
  [table setDelegate:nil]; [table setDataSource:nil]; [data release];
  [window close]; [window release];
  NSLog(@"PASS: nested native table clipping, physical sentinel pixels, full viewport preservation, hiding, resize and detach");
  [pool drain]; return 0;
}
