#import <AppKit/AppKit.h>
#import "GSWindowController.h"
#import "GSFontInfo.h"
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#include <gdk/x11/gdkx.h>
#include <dlfcn.h>
#include <cairo-xlib.h>
@interface GSWindowController (FontViewerTest)
- (BOOL)readFontInfo:(FTVFontInfo *)font error:(NSError **)error;
@end
static void pump(double seconds) {
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (end.timeIntervalSinceNow > 0) {
    for (int i=0; i<64 && g_main_context_pending(NULL); i++) g_main_context_iteration(NULL,FALSE);
    NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static Display *input;
static int (*motion)(Display *,int,int,int,unsigned long);
static int (*buttonEvent)(Display *,unsigned int,int,unsigned long);
static void move(GtkWidget *widget, double x, double y) {
  GtkNative *native=gtk_widget_get_native(widget);
  graphene_rect_t bounds;
  NSCAssert(gtk_widget_compute_bounds(widget,GTK_WIDGET(native),&bounds),@"Native bounds");
  double dx,dy; gtk_native_get_surface_transform(native,&dx,&dy);
  GdkSurface *surface=gtk_native_get_surface(native);
  int scale=gdk_surface_get_scale_factor(surface),rx,ry; Window child;
  XTranslateCoordinates(input,gdk_x11_surface_get_xid(surface),DefaultRootWindow(input),
    lround((bounds.origin.x+x+dx)*scale),lround((bounds.origin.y+y+dy)*scale),&rx,&ry,&child);
  motion(input,-1,rx,ry,CurrentTime); XFlush(input); pump(.05);
}
static void button(unsigned int which, BOOL down) {
  buttonEvent(input,which,down,CurrentTime); XFlush(input); pump(.08);
}
static GtkWidget *closeButton(GtkWidget *widget) {
  if(GTK_IS_BUTTON(widget) && gtk_widget_has_css_class(widget,"close")) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=closeButton(child); if(found) return found;
  }
  return NULL;
}
static GtkWidget *cellForText(GtkWidget *widget,const char *text) {
  if(GTK_IS_LABEL(widget) && !strcmp(gtk_label_get_text(GTK_LABEL(widget)),text)) {
    for(GtkWidget *parent=gtk_widget_get_parent(widget);parent;parent=gtk_widget_get_parent(parent))
      if(!strcmp(G_OBJECT_TYPE_NAME(parent),"GtkColumnViewCellWidget")) return parent;
  }
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=cellForText(child,text); if(found) return found;
  }
  return NULL;
}
static void dragListPane(GtkWidget *split,GTK4NativeTable *peer,const char *text,int delta) {
  GtkWidget *cell=cellForText(peer->_list,text);
  NSCAssert(cell,@"Native list cell exists");
  graphene_rect_t cellBounds;
  NSCAssert(gtk_widget_compute_bounds(cell,peer->_scroller,&cellBounds),@"Cell border bounds");
  int before=lround(cellBounds.size.width),viewport=gtk_widget_get_width(peer->_scroller);
  GtkWidget *start=gtk_paned_get_start_child(GTK_PANED(split));
  GtkWidget *end=gtk_paned_get_end_child(GTK_PANED(split));
  graphene_rect_t left,right;
  NSCAssert(gtk_widget_compute_bounds(start,split,&left) && gtk_widget_compute_bounds(end,split,&right),@"Pane bounds");
  double divider=(left.origin.x+left.size.width+right.origin.x)/2;
  move(split,divider,gtk_widget_get_height(split)/2); button(1,YES);
  for(int i=1;i<=8;i++) move(split,divider+delta*i/8.,gtk_widget_get_height(split)/2);
  cell=cellForText(peer->_list,text);
  NSCAssert(cell,@"Native list cell remains visible while dragging");
  NSCAssert(gtk_widget_compute_bounds(cell,peer->_scroller,&cellBounds),@"Resized cell border bounds");
  int after=lround(cellBounds.size.width),nextViewport=gtk_widget_get_width(peer->_scroller);
  NSLog(@"List resize while held: viewport %d -> %d, cell %d -> %d",viewport,nextViewport,before,after);
  NSCAssert(abs(nextViewport-viewport)>20,@"Pane width changes while held");
  NSCAssert(abs((after-before)-(nextViewport-viewport))<=3,@"Native cell follows the viewport while held");
  NSCAssert(abs(after-nextViewport)<=4,@"Native column fills its viewport");
  button(1,NO);
}
static void modelChanged(GListModel *model,guint position,guint removed,guint added,gpointer value) { (*(NSUInteger *)value)++; }
int main(int argc, char **argv) {
 @autoreleasepool {
  @try {
    [NSApplication sharedApplication];
    GSWindowController *controller = [GSWindowController new];
    NSCAssert(controller.window && controller.fontList && controller.tableList && controller.contentList, @"XIB outlets loaded");
    [controller showWindow:nil];
    pump(.5);
    FTVFontInfo *font = [FTVFontInfo new];
    font.path = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
    NSError *error = nil;
    NSCAssert([controller readFontInfo:font error:&error], @"Font parses");
    NSCAssert(font.tables.count > 10, @"Font tables decoded");
    [controller addFontInfo:font];
    [controller.fontsArray setSelectionIndex:0];
    [controller fontListDidChange];
    pump(.4);
    NSCAssert(controller.fontList.numberOfRows == 1, @"Font list binding");
    NSCAssert(controller.tableList.numberOfRows > 10, @"Table list binding");
    [controller.tableArray setSelectionIndex:[controller.tableNames indexOfObject:@"head"]];
    [controller tableListDidChange];
    pump(.4);
    NSCAssert(controller.contentList.numberOfRows > 0, @"Decoded table outline");
    GtkWindow *host = GTK4NativeHostForWindow(controller.window);
    NSCAssert(host && gtk_widget_get_mapped(GTK_WIDGET(host)), @"Real GTK window");
    NSCAssert(GTK_IS_PANED(GTK4NativeWidgetForView(controller.splitView)), @"Real GtkPaned root");
    GTK4NativeTable *fontPeer=[controller.fontList valueForKey:@"_nativeTableView"];
    GTK4NativeTable *tablePeer=[controller.tableList valueForKey:@"_nativeTableView"];
    GTK4NativeTable *contentPeer=[controller.contentList valueForKey:@"_nativeTableView"];
    NSCAssert(fontPeer && tablePeer && contentPeer, @"Native table peers");
    NSCAssert(GTK_IS_COLUMN_VIEW(fontPeer->_list) && GTK_IS_COLUMN_VIEW(tablePeer->_list) && GTK_IS_COLUMN_VIEW(contentPeer->_list), @"Real GTK column views");
    input=gdk_x11_display_get_xdisplay(gtk_widget_get_display(GTK_WIDGET(host)));
    NSString *capture=[NSProcessInfo processInfo].environment[@"FTV_SCREENSHOT"];
    if(capture) {
      GdkSurface *surface=gtk_native_get_surface(GTK_NATIVE(host));
      Window window=gdk_x11_surface_get_xid(surface); XWindowAttributes attr; XGetWindowAttributes(input,window,&attr);
      cairo_surface_t *source=cairo_xlib_surface_create(input,window,attr.visual,attr.width,attr.height);
      cairo_surface_t *png=cairo_image_surface_create(CAIRO_FORMAT_ARGB32,attr.width,attr.height);
      cairo_t *cr=cairo_create(png); cairo_set_source_surface(cr,source,0,0); cairo_paint(cr);
      cairo_surface_write_to_png(png,capture.fileSystemRepresentation);
      cairo_destroy(cr); cairo_surface_destroy(png); cairo_surface_destroy(source);
    }
    void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
    motion=dlsym(xtst,"XTestFakeMotionEvent"); buttonEvent=dlsym(xtst,"XTestFakeButtonEvent");
    NSCAssert(motion && buttonEvent,@"XTest input");
    input=gdk_x11_display_get_xdisplay(gtk_widget_get_display(GTK_WIDGET(host)));
    GtkWidget *split=GTK4NativeWidgetForView(controller.splitView);
    id fontModel=font.oTFont;
    NSUInteger reloads=0;
    gulong changed=g_signal_connect(contentPeer->_model,"items-changed",G_CALLBACK(modelChanged),&reloads);
    dragListPane(split,fontPeer,font.name.UTF8String,48);
    GtkWidget *middleSplit=GTK4NativeWidgetForView(controller.contentView);
    NSCAssert(GTK_IS_PANED(middleSplit),@"Middle pane uses a native split");
    dragListPane(middleSplit,tablePeer,"head",-48);
    NSCAssert(font.oTFont==fontModel && reloads==0 && [controller.contentList valueForKey:@"_nativeTableView"]==contentPeer,@"Dragging preserves models and native tables");
    g_signal_handler_disconnect(contentPeer->_model,changed);
    GtkAdjustment *adjustment=gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(tablePeer->_scroller));
    double before=gtk_adjustment_get_value(adjustment);
    move(tablePeer->_scroller,40,100);
    for(int i=0;i<5;i++) { button(5,YES); button(5,NO); }
    NSCAssert(gtk_adjustment_get_value(adjustment)>before,@"Native wheel scrolling");
    NSLog(@"CHECK FontTableViewer: %@, %lu tables, %ld outline rows, GTK window and panes",font.name,(unsigned long)font.tables.count,(long)controller.contentList.numberOfRows);
    GtkWidget *close=closeButton(GTK_WIDGET(host));
    NSCAssert(close,@"Native close button");
    move(close,gtk_widget_get_width(close)/2,gtk_widget_get_height(close)/2); button(1,YES); button(1,NO);
    pump(.2);
    NSCAssert(![controller.window isVisible],@"Window closes through GTK input");
    NSLog(@"PASS FontTableViewer: native drag, scroll and close");
    return 0;
  } @catch (NSException *e) { NSLog(@"FAIL: %@\n%@", e, e.callStackSymbols); return 1; }
 }
}
