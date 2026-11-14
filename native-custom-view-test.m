#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeControls.h"
#import "GTK4NativeCustomView.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#define CHECK(c,m) NSCAssert((c),(m))
@interface WrappedCanvas : NSView
{
@public
  NSInteger draws,moves,downs,ups,drags,keys,actions;
  BOOL blue;
  id lastSender;
  NSPoint point;
  NSRect lastDirty;
  BOOL dirtyQueryCorrect;
}
- (void)clicked:(id)sender;
@end
@implementation WrappedCanvas
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)rect
{
  draws++; lastDirty=rect;
  const NSRect *rects=NULL; NSInteger count=0; [self getRectsBeingDrawn:&rects count:&count];
  dirtyQueryCorrect=count==1 && NSEqualRects(rects[0],rect);
  [(blue?[NSColor blueColor]:[NSColor redColor]) set]; NSRectFill(rect);
}
- (void)mouseMoved:(NSEvent *)event { moves++; point=[self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDown:(NSEvent *)event { downs++; point=[self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseUp:(NSEvent *)event { ups++; }
- (void)mouseDragged:(NSEvent *)event { drags++; point=[self convertPoint:event.locationInWindow fromView:nil]; }
- (void)keyDown:(NSEvent *)event { if([event.characters isEqual:@"a"]) keys++; }
- (void)clicked:(id)sender { actions++; lastSender=sender; }
@end
@interface WrappedControl : NSControl { @public BOOL selected; }
@end
@implementation WrappedControl
+ (Class)cellClass { return [NSActionCell class]; }
- (void)drawRect:(NSRect)rect { [(selected?[NSColor greenColor]:[NSColor yellowColor]) set]; NSRectFill(rect); }
- (void)mouseDown:(NSEvent *)event { selected=YES; [self setNeedsDisplay:YES]; }
- (void)mouseUp:(NSEvent *)event { [self sendAction:self.action to:self.target]; }
@end
@interface TrackingCanvas : WrappedCanvas { @public NSInteger tracked; }
@end
@implementation TrackingCanvas
- (void)mouseDown:(NSEvent *)event
{
  NSEvent *next=[self.window nextEventMatchingMask:NSLeftMouseUpMask
    untilDate:[NSDate dateWithTimeIntervalSinceNow:2] inMode:NSEventTrackingRunLoopMode dequeue:YES];
  if(next) tracked++;
}
@end
@interface TextCanvas : WrappedCanvas { @public NSString *text; }
@end
@implementation TextCanvas
- (void)insertText:(id)value { [text release]; text=[value copy]; }
- (void)dealloc { [text release]; [super dealloc]; }
@end
static Display *display;
static int (*motionEvent)(Display*,int,int,int,unsigned long);
static int (*buttonEvent)(Display*,unsigned int,int,unsigned long);
static int (*keyEvent)(Display*,unsigned int,int,unsigned long);
static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while(end.timeIntervalSinceNow>0) {
    for(int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.003] inMode:NSDefaultRunLoopMode dequeue:YES];
    if(event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static void position(GtkWidget *widget,double localX,double localY,int *x,int *y)
{
  GtkNative *native=gtk_widget_get_native(widget); GdkSurface *surface=gtk_native_get_surface(native);
  graphene_point_t local=GRAPHENE_POINT_INIT(localX,localY),root;
  CHECK(gtk_widget_compute_point(widget,GTK_WIDGET(native),&local,&root),@"custom child has native geometry");
  int scale=gdk_surface_get_scale_factor(surface); Window child;
  double dx,dy; gtk_native_get_surface_transform(native,&dx,&dy);
  XTranslateCoordinates(display,gdk_x11_surface_get_xid(surface),DefaultRootWindow(display),
    lround((root.x+dx)*scale),lround((root.y+dy)*scale),x,y,&child);
}
static void move(GtkWidget *widget,double x,double y)
{ int rootX,rootY; position(widget,x,y,&rootX,&rootY); motionEvent(display,-1,rootX,rootY,CurrentTime); XFlush(display); pump(.06); }
static void click(GtkWidget *widget,double x,double y)
{
  move(widget,x,y); buttonEvent(display,1,True,CurrentTime); XFlush(display); pump(.04);
  buttonEvent(display,1,False,CurrentTime); XFlush(display); pump(.06);
}
static unsigned long pixel(GtkWidget *widget,double x,double y)
{
  int rootX,rootY; position(widget,x,y,&rootX,&rootY); XSync(display,False);
  XImage *image=XGetImage(display,DefaultRootWindow(display),rootX,rootY,1,1,AllPlanes,ZPixmap);
  CHECK(image,@"native custom pixels are visible"); unsigned long value=XGetPixel(image,0,0)&0xffffff; XDestroyImage(image); return value;
}
int main(void)
{
  NSAutoreleasePool *pool=[NSAutoreleasePool new]; [NSApplication sharedApplication]; [NSApp finishLaunching];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,700,600)
    styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO;
  WrappedCanvas *canvas=[[[WrappedCanvas alloc] initWithFrame:NSMakeRect(20,280,640,280)] autorelease];
  canvas.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
  [window.contentView addSubview:canvas];
  NSButton *button=[[[NSButton alloc] initWithFrame:NSMakeRect(20,20,150,36)] autorelease];
  button.title=@"Native child"; button.target=canvas; button.action=@selector(clicked:); [canvas addSubview:button];
  NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(20,20,430,230)] autorelease];
  scroll.hasVerticalScroller=YES;
  WrappedCanvas *document=[[[WrappedCanvas alloc] initWithFrame:NSMakeRect(0,0,420,900)] autorelease];
  scroll.documentView=document; [window.contentView addSubview:scroll];
  TextCanvas *text=[[[TextCanvas alloc] initWithFrame:NSMakeRect(480,20,170,170)] autorelease];
  [window.contentView addSubview:text];
  TrackingCanvas *tracking=[[[TrackingCanvas alloc] initWithFrame:NSMakeRect(480,235,170,35)] autorelease];
  [window.contentView addSubview:tracking];
  WrappedControl *customControl=[[[WrappedControl alloc] initWithFrame:NSMakeRect(480,200,170,30)] autorelease];
  customControl.target=canvas; customControl.action=@selector(clicked:);
  [window.contentView addSubview:customControl];
  [window makeKeyAndOrderFront:nil]; pump(.6);
  GTK4NativeWindowDecorationView *host=(id)[window.contentView superview];
  GTK4NativeControls *peers=host->_nativeControls;
  GtkWidget *root=[peers widgetForView:window.contentView],*native=[peers widgetForView:canvas];
  GtkWidget *nativeButton=[peers widgetForView:button],*nativeScroll=[peers widgetForView:scroll];
  CGFloat factor=window.userSpaceScaleFactor/gtk_widget_get_scale_factor(native);
  CHECK(root && GTK4NativeIsCustomView(native) && GTK_IS_BUTTON(nativeButton) && GTK_IS_SCROLLED_WINDOW(nativeScroll),
    @"complete window hosts custom drawing, native controls and nested scrolling in GTK");
  CHECK(host->_nativeTableRects.count==1,@"complete native window has one stable content region");
  CHECK([GSNativeViewPeerForView(canvas) ownsLayoutForNativeView:canvas],@"native peer owns custom layout");
  CHECK(GTK_IS_CONSTRAINT_LAYOUT(gtk_widget_get_layout_manager(native)),@"custom children use GTK layout");
  display=gdk_x11_display_get_xdisplay(gtk_widget_get_display(native));
  void *lib=dlopen("libXtst.so.6",RTLD_NOW); CHECK(lib,@"real input support");
  motionEvent=dlsym(lib,"XTestFakeMotionEvent"); buttonEvent=dlsym(lib,"XTestFakeButtonEvent"); keyEvent=dlsym(lib,"XTestFakeKeyEvent");
  CHECK(pixel(native,250,100)==0xff0000,@"custom AppKit drawing reaches GTK pixels");
  NSInteger before=canvas->draws;
  host->_placing=YES;
  canvas->blue=YES; [canvas setNeedsDisplayInRect:NSMakeRect(200,80,80,60)]; pump(.12);
  CHECK(pixel(native,250*factor,100*factor)==0x0000ff && pixel(native,180*factor,100*factor)==0xff0000,@"dirty drawing updates only its region with host synchronization disabled");
  CHECK(canvas->dirtyQueryCorrect,@"custom dirty-region queries report the native draw rectangle");
  CHECK(canvas->draws==before+1,@"custom draw runs once in GTK without duplicate AppKit backing drawing");
  move(native,250,100);
  CHECK(canvas->moves>0 && fabs(canvas->point.x-250/factor)<2 && fabs(canvas->point.y-100/factor)<2,@"GTK motion translates to source coordinates");
  click(native,250,100);
  CHECK(canvas->downs==1 && canvas->ups==1 && window.firstResponder==canvas,@"GTK click and focus reach custom responder");
  keyEvent(display,XKeysymToKeycode(display,XK_a),True,CurrentTime); keyEvent(display,XKeysymToKeycode(display,XK_a),False,CurrentTime); XFlush(display); pump(.1);
  CHECK(canvas->keys==1,@"GTK keyboard focus sends custom key events");
  move(native,250,100); buttonEvent(display,1,True,CurrentTime); XFlush(display); pump(.03);
  move(native,290,120); buttonEvent(display,1,False,CurrentTime); XFlush(display); pump(.05);
  CHECK(canvas->drags>0,@"GTK drag delivers custom responder events");
  NSInteger downs=canvas->downs;
  click(nativeButton,20,15); CHECK(canvas->actions==1 && canvas->lastSender==button && canvas->downs==downs,@"GTK hit testing gives nested native child its event");
  GtkWidget *nativeControl=[peers widgetForView:customControl];
  CHECK(GTK4NativeIsCustomView(nativeControl),@"custom NSControl subclasses use the common wrapper");
  click(nativeControl,40,15);
  CHECK(customControl->selected && canvas->actions==2 && canvas->lastSender==customControl,
    @"custom control input preserves model state and original target/action sender");
  GtkWidget *nativeText=[peers widgetForView:text]; click(nativeText,40,40);
  keyEvent(display,XKeysymToKeycode(display,XK_b),True,CurrentTime); keyEvent(display,XKeysymToKeycode(display,XK_b),False,CurrentTime); XFlush(display); pump(.1);
  CHECK([text->text isEqual:@"b"],@"GTK IM context commits text to a custom input view");
  // Tracking loops use the normal host timer to pump GDK while AppKit waits.
  host->_placing=NO;
  GtkWidget *nativeTracking=[peers widgetForView:tracking];
  move(nativeTracking,40,15);
  buttonEvent(display,1,True,CurrentTime); buttonEvent(display,1,False,100); XFlush(display); pump(.3);
  CHECK(tracking->tracked==1,@"custom AppKit tracking loops keep GTK pumping and receive the release event");
  GtkAdjustment *v=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(nativeScroll));
  gtk_adjustment_set_value(v,180*factor); pump(.1);
  CHECK(NSMinY(scroll.contentView.bounds)>170,@"nested GTK scrolling mirrors AppKit source clip bounds");
  host->_placing=NO;
  NSSize old=canvas.frame.size; [window setContentSize:NSMakeSize(820,680)]; pump(.4);
  CHECK(canvas.frame.size.width>old.width+100 && canvas.frame.size.height>old.height+60,@"GTK springs and struts resize custom source geometry");
  [window.contentView setSubviews:@[]]; pump(.15);
  CHECK(GSNativeViewPeerForView(canvas)==nil,@"detachment unregisters native source callbacks");
  [window close]; pump(.1); [window release]; dlclose(lib);
  NSLog(@"PASS: native scene, custom pixels/dirty regions, direct invalidation, GTK layout, nested controls/scrolling, mouse/drag/key/focus/text input and teardown");
  [pool drain]; return 0;
}
