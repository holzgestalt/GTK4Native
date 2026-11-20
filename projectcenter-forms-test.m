#import <AppKit/AppKit.h>
#import "PCAppController.h"
#import <ProjectCenter/PCProjectManager.h>
#import <ProjectCenter/PCProject.h>
#import <ProjectCenter/PCProjectWindow.h>
#import <ProjectCenter/PCProjectBuilder.h>
#import "Framework/PCXcodeProjectEditor.h"
#import "Framework/PCXcodeProject.h"
#import "GTK4NativeView.h"
#import "GTK4NativeWindow.h"
#include <objc/runtime.h>
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <cairo-xlib.h>

#define CHECK(value,message) NSCAssert((value),(message))
static NSView *trackedForm;
static BOOL tracking;
static NSUInteger appKitAllocations;
static NSRect (*originalAlignment)(id,SEL,NSView *);
static NSRect alignment(id engine,SEL selector,NSView *view)
{
  if(tracking && (view==trackedForm || [view isDescendantOf:trackedForm])) appKitAllocations++;
  return originalAlignment(engine,selector,view);
}
static void pump(double seconds)
{
  NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
  while(end.timeIntervalSinceNow>0) {
    for(int i=0;i<64 && g_main_context_pending(NULL);i++)g_main_context_iteration(NULL,FALSE);
    NSEvent *event=[NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];
    if(event)[NSApp sendEvent:event]; [NSApp updateWindows];
  }
}
static Display *input;
static int (*motion)(Display *,int,int,int,unsigned long);
static int (*buttonEvent)(Display *,unsigned int,int,unsigned long);
static int (*keyEvent)(Display *,unsigned int,int,unsigned long);
static void move(GtkWidget *widget,double x,double y)
{
  GtkNative *native=gtk_widget_get_native(widget); graphene_rect_t rect;
  CHECK(gtk_widget_compute_bounds(widget,GTK_WIDGET(native),&rect),@"native pointer bounds");
  double dx,dy;gtk_native_get_surface_transform(native,&dx,&dy);
  int scale=gtk_widget_get_scale_factor(widget),rx,ry;Window child;
  XTranslateCoordinates(input,gdk_x11_surface_get_xid(gtk_native_get_surface(native)),DefaultRootWindow(input),
    lround((rect.origin.x+x+dx)*scale),lround((rect.origin.y+y+dy)*scale),&rx,&ry,&child);
  motion(input,-1,rx,ry,CurrentTime);XFlush(input);pump(.03);
}
static void click(GtkWidget *widget)
{
  move(widget,gtk_widget_get_width(widget)/2.,gtk_widget_get_height(widget)/2.);
  buttonEvent(input,1,True,CurrentTime);buttonEvent(input,1,False,CurrentTime);XFlush(input);pump(.15);
}
static GtkWidget *findPopover(GtkWidget *widget)
{
  if(GTK_IS_POPOVER(widget))return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=findPopover(child);if(found)return found;
  }
  return NULL;
}
static void checkRows(NSView *form)
{
  GtkWidget *nativeForm=GTK4NativeWidgetForView(form);
  CHECK(nativeForm,@"General form is native");
  double previous=0;NSUInteger fields=0,popups=0;
  for(NSView *row in form.subviews) {
    GtkWidget *nativeRow=GTK4NativeWidgetForView(row);graphene_rect_t r;
    CHECK(nativeRow && gtk_widget_compute_bounds(nativeRow,nativeForm,&r),@"row is natively allocated");
    CHECK(r.origin.y>=previous+3,@"rows keep a positive gap between measured native bounds");
    previous=r.origin.y+r.size.height;
    for(NSView *control in row.subviews) {
      GtkWidget *widget=GTK4NativeWidgetForView(control);graphene_rect_t c;
      CHECK(widget && gtk_widget_compute_bounds(widget,nativeRow,&c),@"form child is native");
      int minimum=0;gtk_widget_measure(widget,GTK_ORIENTATION_VERTICAL,-1,&minimum,NULL,NULL,NULL);
      CHECK(c.origin.y>=-.6 && c.origin.y+c.size.height<=r.size.height+.6
        && c.size.height>=minimum-.6,@"row contains the complete native control without compression or overlap");
      if([control isKindOfClass:NSTextField.class] && [(NSTextField *)control isEditable]) {
        CHECK(GTK_IS_ENTRY(widget),@"editable values use GtkEntry");fields++;
        CHECK(c.origin.x+c.size.width<=r.size.width+.6 && fabs(c.origin.x+c.size.width-r.size.width)<1.1,
          @"editable fields follow the row's trailing edge");
      }
      if([control isKindOfClass:NSPopUpButton.class]) {
        CHECK(GTK_IS_DROP_DOWN(widget),@"choices use GtkDropDown");popups++;
        double factor=[control.window userSpaceScaleFactor]/gtk_widget_get_scale_factor(widget);
        CHECK(c.size.height<=30*MAX(1,factor),@"native popup retains compact desktop-control height");
      }
    }
  }
  CHECK(fields>=4 && popups>=3,@"the actual application target General form was checked");
  NSLog(@"CHECK General rows: %lu native entries, %lu native choices, no overlaps",fields,popups);
}
static void capture(NSWindow *window,NSString *path)
{
  GtkWidget *host=GTK_WIDGET(GTK4NativeHostForWindow(window));
  GdkSurface *surface=gtk_native_get_surface(GTK_NATIVE(host));
  Window xid=gdk_x11_surface_get_xid(surface);XWindowAttributes attr;XGetWindowAttributes(input,xid,&attr);
  cairo_surface_t *source=cairo_xlib_surface_create(input,xid,attr.visual,attr.width,attr.height);
  cairo_surface_t *png=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,attr.width,attr.height);
  cairo_t *cr=cairo_create(png);cairo_set_source_surface(cr,source,0,0);cairo_paint(cr);
  CHECK(cairo_surface_write_to_png(png,path.fileSystemRepresentation)==CAIRO_STATUS_SUCCESS,@"native screenshot written");
  cairo_destroy(cr);cairo_surface_destroy(png);cairo_surface_destroy(source);
}
static GLogWriterOutput measurementLog(GLogLevelFlags level,const GLogField *fields,gsize count,gpointer data)
{
  for(gsize i=0;i<count;i++) if(!strcmp(fields[i].key,"MESSAGE")) {
    const char *message=fields[i].value, *start=strstr(message,"GSNativeContainer ");
    if(start) {
      void *pointer=NULL;
      if(sscanf(start,"GSNativeContainer %p",&pointer)==1 && pointer && G_IS_OBJECT(pointer)) {
        id source=g_object_get_data(G_OBJECT(pointer),"appkit-view");
        NSLog(@"Measurement source %@, parent %@, %lu constraints",NSStringFromClass([source class]),
          NSStringFromClass([[source superview]class]),(unsigned long)[[source constraints]count]);
      }
    }
  }
  return g_log_writer_default(level,fields,count,data);
}
int main(int argc,char **argv)
{
  @autoreleasepool {
    g_log_set_writer_func(measurementLog,NULL,NULL);
    [NSApplication sharedApplication];
    [[NSUserDefaults standardUserDefaults]setVolatileDomain:@{@"UseTearOffWindows":@"NO"} forName:NSArgumentDomain];
    PCAppController *controller=[PCAppController new];
    PCProject *project=[[controller projectManager]openProjectAt:[NSString stringWithUTF8String:argv[1]] makeActive:YES];
    CHECK(project,@"open the real application Xcode project");pump(.4);
    [[project projectWindow]showProjectOverview];pump(.5);
    PCXcodeProjectEditor *editor=[[project projectWindow]xcodeProjectEditor];
    NSScrollView *scroll=[editor valueForKey:@"generalScroll"];
    trackedForm=scroll.documentView;
    NSWindow *window=[editor view].window;
    GtkWindow *host=GTK4NativeHostForWindow(window);
    Method method=class_getInstanceMethod(NSClassFromString(@"GSAutoLayoutEngine"),@selector(alignmentRectForView:));
    originalAlignment=(void *)method_setImplementation(method,(IMP)alignment);tracking=YES;
    void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
    input=XOpenDisplay(NULL);motion=dlsym(xtst,"XTestFakeMotionEvent");buttonEvent=dlsym(xtst,"XTestFakeButtonEvent");keyEvent=dlsym(xtst,"XTestFakeKeyEvent");
    CHECK(input && motion && buttonEvent && keyEvent,@"native test input available");
    checkRows(trackedForm);
    GtkWidget *choice=NULL;
    for(NSView *row in trackedForm.subviews) for(NSView *control in row.subviews)
      if(!choice && [control isKindOfClass:NSPopUpButton.class])choice=GTK4NativeWidgetForView(control);
    click(choice);CHECK(findPopover(choice) && gtk_widget_get_mapped(findPopover(choice)),@"native popup opens with real pointer input");
    KeyCode escape=XKeysymToKeycode(input,XK_Escape);keyEvent(input,escape,True,CurrentTime);keyEvent(input,escape,False,CurrentTime);XFlush(input);pump(.15);
    int width=gtk_widget_get_width(GTK_WIDGET(host)),height=gtk_widget_get_height(GTK_WIDGET(host));
    for(NSNumber *delta in @[@160,@(-100),@0]) {
      gtk_window_set_default_size(host,width+delta.intValue,height);pump(.3);checkRows(trackedForm);
    }
    GtkWidget *nativeScroll=GTK4NativeWidgetForView(scroll);
    GtkAdjustment *adjustment=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(nativeScroll));
    move(nativeScroll,gtk_widget_get_width(nativeScroll)/2.,gtk_widget_get_height(nativeScroll)/2.);
    double before=gtk_adjustment_get_value(adjustment);
    for(int i=0;i<5;i++){buttonEvent(input,5,True,CurrentTime);buttonEvent(input,5,False,CurrentTime);}XFlush(input);pump(.2);
    CHECK(gtk_adjustment_get_upper(adjustment)<=gtk_adjustment_get_page_size(adjustment)
      || gtk_adjustment_get_value(adjustment)>before,@"native wheel input scrolls measured form content");
    CHECK(appKitAllocations==0,@"AppKit's layout engine never allocates General controls during native input or resize");
    if(getenv("PC_FORMS_SCREENSHOT"))capture(window,[NSString stringWithUTF8String:getenv("PC_FORMS_SCREENSHOT")]);
    tracking=NO;method_setImplementation(method,(IMP)originalAlignment);
    if(getenv("PC_FORMS_BUILD")) {
      PCProjectBuilder *builder=[project projectBuilder];[builder startBuild:nil];
      NSTask *task=[builder valueForKey:@"makeTask"];
      CHECK([[task.environment objectForKey:@"GNUSTEP_APPLICATION_THEME"]isEqual:@"GTK4Native"],@"ProjectCenter passes the selected theme into the real build task");
      NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:120];
      while(builder.isBuilding && deadline.timeIntervalSinceNow>0)pump(.05);
      if(builder.isBuilding || !builder.buildSucceeded) NSLog(@"Build output:\n%@",[[builder valueForKey:@"logOutput"]string]);
      CHECK(!builder.isBuilding && builder.buildSucceeded,@"EditGlyphData builds successfully through ProjectCenter");
      NSLog(@"CHECK selected provider reached the real EditGlyphData build");
    }
    [window close];pump(.1);XCloseDisplay(input);dlclose(xtst);
    NSLog(@"PASS ProjectCenter forms: native bounds/spacing, compact controls, resizing, pointer popup/wheel, no AppKit layout");
  }
  return 0;
}
