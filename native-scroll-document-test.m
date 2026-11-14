#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeControls.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>
#include <dlfcn.h>
#define CHECK(c,m) NSCAssert((c),(m))
@interface NativeDocument : NSView
@end
@implementation NativeDocument
- (BOOL)isFlipped { return YES; }
@end
@interface DocumentActions : NSObject { @public int count; id sender; }
- (void)clicked:(id)value;
@end
@implementation DocumentActions
- (void)clicked:(id)value { count++; sender=value; }
@end
static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while (end.timeIntervalSinceNow>0) {
    for (int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.003]
      inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static graphene_rect_t bounds(GtkWidget *widget,GtkWidget *root)
{
  graphene_rect_t rect;
  CHECK(gtk_widget_compute_bounds(widget,root,&rect),@"GTK document child is allocated"); return rect;
}
static void wheel(GtkWidget *widget, int steps)
{
  void *lib=dlopen("libXtst.so.6",RTLD_NOW);
  CHECK(lib,@"XTest available");
  int (*motion)(Display*,int,int,int,unsigned long)=dlsym(lib,"XTestFakeMotionEvent");
  int (*button)(Display*,unsigned int,int,unsigned long)=dlsym(lib,"XTestFakeButtonEvent");
  GtkNative *native=gtk_widget_get_native(widget);
  GdkSurface *surface=gtk_native_get_surface(native);
  Display *display=gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  graphene_rect_t rect=bounds(widget,GTK_WIDGET(native));
  int x,y; Window child;
  int scale=gdk_surface_get_scale_factor(surface);
  XTranslateCoordinates(display,gdk_x11_surface_get_xid(surface),DefaultRootWindow(display),
    lround((rect.origin.x+20)*scale),lround((rect.origin.y+20)*scale),&x,&y,&child);
  motion(display,-1,x,y,CurrentTime);
  for(int i=0;i<steps;i++) { button(display,5,True,CurrentTime); button(display,5,False,CurrentTime); }
  XFlush(display); dlclose(lib);
}
static void hiddenBacking(GTK4NativeWindowDecorationView *host, GtkWidget *scroller)
{
  graphene_rect_t rect=bounds(scroller,host->_host);
  int scale=gtk_widget_get_scale_factor(host->_host);
  int x=lround((rect.origin.x+10)*scale),y=lround((rect.origin.y+10)*scale);
  Display *display=(Display *)[GSServerForWindow(host.window) serverDevice];
  GC gc=XCreateGC(display,host->_child,0,NULL); XSetForeground(display,gc,0xff00ff);
  XFillRectangle(display,host->_child,gc,x,y,3,3); XFreeGC(display,gc); XSync(display,False);
  XImage *image=XGetImage(display,host->_parent,x,y,1,1,AllPlanes,ZPixmap);
  CHECK(image && (XGetPixel(image,0,0)&0xffffff)!=0xff00ff,@"AppKit backing is hidden across the viewport");
  XDestroyImage(image);
}
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new];
  [NSApplication sharedApplication]; [NSApp finishLaunching];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,640,520)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(20,40,580,420)] autorelease];
  [scroll setHasVerticalScroller:YES]; [scroll setHasHorizontalScroller:YES];
  NativeDocument *document=[[[NativeDocument alloc] initWithFrame:NSMakeRect(0,0,750,1200)] autorelease];
  DocumentActions *actions=[DocumentActions new];
  NSButton *first=nil;
  for(int i=0;i<24;i++) {
    NSButton *button=[[[NSButton alloc] initWithFrame:NSMakeRect(20,20+i*46,180,34)] autorelease];
    [button setTitle:[NSString stringWithFormat:@"Button %d",i]];
    [button setTarget:actions]; [button setAction:@selector(clicked:)];
    [document addSubview:button]; if (!first) first=button;
  }
  [scroll setDocumentView:document]; [window.contentView addSubview:scroll];
  [window makeKeyAndOrderFront:nil]; pump(.5);
  GTK4NativeWindowDecorationView *host=(id)[window valueForKey:@"_wv"];
  GtkWidget *native=[host->_nativeControls widgetForView:scroll];
  GtkWidget *child=[host->_nativeControls widgetForView:first];
  CHECK(GTK_IS_SCROLLED_WINDOW(native) && GTK_IS_BUTTON(child),@"whole document uses a real GTK scrolled window");
  GtkWidget *root=gtk_widget_get_parent(child);
  CHECK(GTK_IS_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager(root)),@"GTK owns the document constraint solver");
  CHECK(host->_nativeTableRects.count==1,@"one stable viewport cutout replaces per-control cutouts");
  GtkAdjustment *v=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(native));
  graphene_rect_t original=bounds(child,native);
  NSArray *holes=[host->_nativeTableRects copy];
  // Disable host synchronization: GTK must scroll and paint correctly without
  // waiting for peer placement or publication of new X11 holes.
  host->_placing=YES;
  wheel(native,3); pump(.25);
  CHECK(gtk_adjustment_get_value(v)>20,@"real GTK wheel input scrolls without host synchronization");
  double offset=gtk_adjustment_get_value(v);
  graphene_rect_t moved=bounds(child,native);
  CHECK(fabs(moved.origin.y-original.origin.y+offset)<1.5,@"GTK moves the entire document in the same allocation");
  CHECK([host->_nativeTableRects isEqual:holes],@"native scroll leaves the viewport cutout unchanged");
  CHECK(fabs(NSMinY(scroll.contentView.bounds)-offset/([window userSpaceScaleFactor]/gtk_widget_get_scale_factor(native)))<1.5,
    @"native scroll mirrors AppKit clip bounds");
  hiddenBacking(host,native);
  host->_placing=NO; pump(.15);
  [document scrollPoint:NSMakePoint(30,300)]; pump(.15);
  CHECK(fabs(gtk_adjustment_get_value(v)-300*([window userSpaceScaleFactor]/gtk_widget_get_scale_factor(native)))<2,
    @"programmatic AppKit scrolling reaches GTK");
  g_signal_emit_by_name(child,"clicked");
  CHECK(actions->count==1 && actions->sender==first,@"native document preserves source actions");
  [first setTitle:@"Updated"]; pump(.1);
  CHECK(!strcmp(gtk_button_get_label(GTK_BUTTON(child)),"Updated"),@"source model changes update native controls");
  [scroll setFrameSize:NSMakeSize(480,320)]; pump(.2);
  native=[host->_nativeControls widgetForView:scroll];
  CHECK(gtk_widget_get_width(native)<580*([window userSpaceScaleFactor]/gtk_widget_get_scale_factor(native)),@"native viewport follows resize");
  NSView *replacement=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,600,900)] autorelease];
  NSButton *unflipped=[[[NSButton alloc] initWithFrame:NSMakeRect(20,800,180,34)] autorelease];
  [replacement addSubview:unflipped];
  [scroll setDocumentView:replacement]; pump(.15);
  CHECK([host->_nativeControls widgetForView:first]==NULL,@"page replacement drops old peers");
  CHECK(GTK_IS_SCROLLED_WINDOW([host->_nativeControls widgetForView:scroll]),@"replacement remains GTK hosted");
  GtkWidget *replacementNative=[host->_nativeControls widgetForView:scroll];
  GtkWidget *replacementChild=[host->_nativeControls widgetForView:unflipped];
  graphene_rect_t flipped=bounds(replacementChild,gtk_widget_get_parent(replacementChild));
  CGFloat factor=[window userSpaceScaleFactor]/gtk_widget_get_scale_factor(replacementNative);
  CHECK(fabs(flipped.origin.y-66*factor)<2,@"unflipped source frames convert to native top coordinates");
  [replacement scrollPoint:NSMakePoint(0,100)]; pump(.15);
  GtkAdjustment *replacementV=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(replacementNative));
  CHECK(fabs(gtk_adjustment_get_value(replacementV)-(900-NSMaxY(scroll.contentView.bounds))*factor)<2,
    @"programmatic unflipped scrolling reaches GTK");
  [scroll removeFromSuperview]; pump(.15);
  CHECK([host->_nativeControls widgetForView:scroll]==NULL,@"detach removes complete native document");
  [holes release]; [window close]; pump(.1); [window release]; [actions release];
  NSLog(@"PASS: GTK-owned document layout, real wheel input without host sync, stable viewport, hidden AppKit backing, model/action, resize, replacement and detach");
  [pool drain]; return 0;
}
