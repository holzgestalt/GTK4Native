#import <AppKit/AppKit.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeView.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <dlfcn.h>

@interface ColorActions : NSObject
{
@public
  NSUInteger count;
  id sender;
}
- (void)changed:(id)value;
@end
@implementation ColorActions
- (void)changed:(id)value { count++; sender=value; }
@end
static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while(end.timeIntervalSinceNow>0) {
    for(int i=0;i<64 && g_main_context_pending(NULL);i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.005]
      inMode:NSDefaultRunLoopMode dequeue:YES];
    if(event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static GdkRGBA rgba(GtkWidget *widget)
{
#if GTK_CHECK_VERSION(4,10,0)
  return *gtk_color_dialog_button_get_rgba(GTK_COLOR_DIALOG_BUTTON(widget));
#else
  GdkRGBA result; gtk_color_chooser_get_rgba(GTK_COLOR_CHOOSER(widget),&result); return result;
#endif
}
static void painted(GdkFrameClock *clock,gpointer data) { (*(NSUInteger *)data)++; }
static void click(GtkWidget *widget)
{
  void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
  int (*motion)(Display *,int,int,int,unsigned long)=dlsym(xtst,"XTestFakeMotionEvent");
  int (*button)(Display *,unsigned int,int,unsigned long)=dlsym(xtst,"XTestFakeButtonEvent");
  Display *input=XOpenDisplay(NULL);
  NSCAssert(input && motion && button,@"XTest input available");
  GtkNative *native=gtk_widget_get_native(widget);
  graphene_rect_t bounds;
  NSCAssert(gtk_widget_compute_bounds(widget,GTK_WIDGET(native),&bounds),@"native bounds available");
  double dx,dy; gtk_native_get_surface_transform(native,&dx,&dy);
  int scale=gtk_widget_get_scale_factor(widget),x,y; Window child;
  XTranslateCoordinates(input,gdk_x11_surface_get_xid(gtk_native_get_surface(native)),DefaultRootWindow(input),
    lround((bounds.origin.x+bounds.size.width/2+dx)*scale),
    lround((bounds.origin.y+bounds.size.height/2+dy)*scale),&x,&y,&child);
  motion(input,-1,x,y,CurrentTime); XFlush(input); pump(.05);
  button(input,1,True,CurrentTime); button(input,1,False,CurrentTime); XFlush(input); pump(.4);
  XCloseDisplay(input); dlclose(xtst);
}
int main(void)
{
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp finishLaunching];
    ColorActions *actions=[ColorActions new];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(40,40,400,300)
      styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:[[window contentView] bounds]] autorelease];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; scroll.hasVerticalScroller=YES;
    [window.contentView addSubview:scroll];
    NSView *form=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,380,400)] autorelease];
    form.autoresizingMask=NSViewWidthSizable; scroll.documentView=form;
    NSTextField *entry=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,250,180,24)] autorelease];
    entry.stringValue=@"Native inspector"; [form addSubview:entry];
    NSColorWell *well=[[[NSColorWell alloc] initWithFrame:NSMakeRect(220,250,64,22)] autorelease];
    well.color=[NSColor colorWithCalibratedRed:.2 green:.4 blue:.6 alpha:.8];
    well.target=actions; well.action=@selector(changed:); [form addSubview:well];
    NSCAssert([GTK4NativeView supportsView:window.contentView],@"color wells keep the entire form native");
    [window makeKeyAndOrderFront:nil]; pump(.5);
    GtkWidget *native=GTK4NativeWidgetForView(well);
#if GTK_CHECK_VERSION(4,10,0)
    NSCAssert(GTK_IS_COLOR_DIALOG_BUTTON(native),@"native GTK color dialog button");
#else
    NSCAssert(GTK_IS_COLOR_BUTTON(native),@"native GTK color button");
#endif
    NSCAssert(GTK_IS_ENTRY(GTK4NativeWidgetForView(entry)),@"neighboring inspector field stays native");
    GdkRGBA color=rgba(native);
    NSCAssert(fabs(color.red-.2)<.001 && fabs(color.alpha-.8)<.001 && actions->count==0,@"initial color and alpha synchronize silently");
    well.color=[NSColor colorWithCalibratedWhite:.3 alpha:.5]; pump(.15); color=rgba(native);
    NSCAssert(fabs(color.green-.3)<.001 && fabs(color.alpha-.5)<.001 && actions->count==0,@"programmatic color conversion sends no action");
    GdkRGBA chosen={.7,.6,.5,.4};
#if GTK_CHECK_VERSION(4,10,0)
    gtk_color_dialog_button_set_rgba(GTK_COLOR_DIALOG_BUTTON(native),&chosen);
#else
    gtk_color_chooser_set_rgba(GTK_COLOR_CHOOSER(native),&chosen); g_signal_emit_by_name(native,"color-set");
#endif
    NSColor *result=[well.color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    NSCAssert(fabs(result.redComponent-.7)<.001 && fabs(result.alphaComponent-.4)<.001
      && actions->count==1 && actions->sender==well,@"native color change updates model and sends one original-sender action");
    well.enabled=NO; pump(.1);
    NSCAssert(!gtk_widget_get_sensitive(native),@"disabled color well uses GTK sensitivity");
    well.enabled=YES; pump(.2);
    click(native);
    GListModel *windows=gtk_window_get_toplevels(); GtkWindow *dialog=NULL;
    GTK4NativeWindowDecorationView *host=(id)[window.contentView superview];
    for(guint i=0;i<g_list_model_get_n_items(windows);i++) {
      GtkWindow *candidate=g_list_model_get_item(windows,i);
      if(GTK_WIDGET(candidate)!=host->_host && gtk_widget_get_visible(GTK_WIDGET(candidate))) dialog=candidate;
      else g_object_unref(candidate);
    }
    NSCAssert(dialog,@"real pointer input opens a GTK color chooser");
    NSCAssert(GTK_IS_DIALOG(dialog),@"GTK chooser provides native dialog responses");
    GtkWidget *cancel=gtk_dialog_get_widget_for_response(GTK_DIALOG(dialog),GTK_RESPONSE_CANCEL);
    NSCAssert(cancel,@"GTK chooser supplies a cancel button");
    click(cancel); g_object_unref(dialog); pump(.3);
    NSCAssert(actions->count==1,@"canceling the native chooser preserves color without an action");
    GdkFrameClock *clock=gtk_widget_get_frame_clock(native); NSUInteger frames=0;
    gulong signal=g_signal_connect(clock,"after-paint",G_CALLBACK(painted),&frames);
    pump(.5); frames=0; pump(.5);
    NSCAssert(frames<=2,@"unchanged color synchronization stays idle");
    g_signal_handler_disconnect(clock,signal);
    [window close]; [window release]; [actions release]; pump(.1);
    NSLog(@"Native color well passed: native form, color/alpha, actions, disabled state, pointer chooser, cancel, idle, close");
  }
  return 0;
}
