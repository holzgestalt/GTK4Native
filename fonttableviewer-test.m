#import <AppKit/AppKit.h>
#import "GSWindowController.h"
#import "GSFontInfo.h"
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#include <gdk/x11/gdkx.h>
#include <dlfcn.h>
#include <cairo-xlib.h>
#include <X11/keysym.h>
#import <objc/runtime.h>
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
static int (*keyEvent)(Display *,unsigned int,int,unsigned long);
static void key(KeySym symbol,BOOL down) {
  keyEvent(input,XKeysymToKeycode(input,symbol),down,CurrentTime); XFlush(input);
}
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
      if(!strcmp(G_OBJECT_TYPE_NAME(parent),"GtkColumnViewCellWidget") || !strcmp(G_OBJECT_TYPE_NAME(parent),"GtkListItemWidget")) return parent;
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
  GtkBorder margins; gtk_style_context_get_margin(gtk_widget_get_style_context(cell),&margins);
  int before=lround(cellBounds.size.width)+margins.left+margins.right,viewport=gtk_widget_get_width(peer->_scroller);
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
  gtk_style_context_get_margin(gtk_widget_get_style_context(cell),&margins);
  int after=lround(cellBounds.size.width)+margins.left+margins.right,nextViewport=gtk_widget_get_width(peer->_scroller);
  NSLog(@"List resize while held: viewport %d -> %d, cell %d -> %d",viewport,nextViewport,before,after);
  NSCAssert(abs(nextViewport-viewport)>20,@"Pane width changes while held");
  NSCAssert(abs((after-before)-(nextViewport-viewport))<=3,@"Native cell follows the viewport while held");
  NSCAssert(abs(after-nextViewport)<=4,@"Native column fills its viewport");
  button(1,NO);
}
static GtkWidget *toolbarControl(GtkWidget *widget,SEL action) {
  NSToolbarItem *item=g_object_get_data(G_OBJECT(widget),"appkit-toolbar-item");
  if(item && sel_isEqual(item.action,action)) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=toolbarControl(child,action); if(found) return found;
  }
  return NULL;
}
static GtkWidget *searchEntry(GtkWidget *widget) {
  if(GTK_IS_SEARCH_ENTRY(widget)) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=searchEntry(child); if(found) return found;
  }
  return NULL;
}
static void click(GtkWidget *widget) {
  NSCAssert(widget && gtk_widget_get_mapped(widget),@"Native toolbar control is visible");
  move(widget,gtk_widget_get_width(widget)/2.,gtk_widget_get_height(widget)/2.); button(1,YES); button(1,NO);
}
static void modelChanged(GListModel *model,guint position,guint removed,guint added,gpointer value) { (*(NSUInteger *)value)++; }
int main(int argc, char **argv) {
 @autoreleasepool {
  @try {
    [NSApplication sharedApplication];
    GSWindowController *controller = [GSWindowController new];
    NSCAssert(controller.window && controller.fontList && controller.tableList && controller.contentList, @"XIB outlets loaded");
    NSCAssert(controller.window.toolbar.items.count==4 && controller.searchField,@"Modern XIB toolbar and search outlets");
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
    NSView *decoration=controller.window.contentView;
    while(decoration.superview) decoration=decoration.superview;
    GtkWidget *toolbar=((GTK4NativeWindowDecorationView *)decoration)->_nativeToolbar;
    NSCAssert(toolbar && gtk_widget_get_mapped(toolbar),@"Modern toolbar is native GTK");
    graphene_rect_t barBounds,bodyBounds;
    NSCAssert(gtk_widget_compute_bounds(toolbar,GTK_WIDGET(host),&barBounds)
      && gtk_widget_compute_bounds(GTK4NativeWidgetForView(controller.splitView),GTK_WIDGET(host),&bodyBounds),@"Toolbar bounds");
    NSCAssert(barBounds.origin.y+barBounds.size.height<=bodyBounds.origin.y+1,@"Toolbar is above the panes");
    NSCAssert(GTK_IS_PANED(GTK4NativeWidgetForView(controller.splitView)), @"Real GtkPaned root");
    GTK4NativeTable *fontPeer=[controller.fontList valueForKey:@"_nativeTableView"];
    GTK4NativeTable *tablePeer=[controller.tableList valueForKey:@"_nativeTableView"];
    GTK4NativeTable *contentPeer=[controller.contentList valueForKey:@"_nativeTableView"];
    NSCAssert(fontPeer && tablePeer && contentPeer, @"Native table peers");
    NSCAssert((GTK_IS_COLUMN_VIEW(fontPeer->_list) || GTK_IS_LIST_VIEW(fontPeer->_list)) && GTK_IS_COLUMN_VIEW(tablePeer->_list) && GTK_IS_COLUMN_VIEW(contentPeer->_list), @"Real GTK column views");
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
    keyEvent=dlsym(xtst,"XTestFakeKeyEvent");
    NSCAssert(motion && buttonEvent && keyEvent,@"XTest input");
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
    GtkWidget *search=searchEntry(GTK_WIDGET(host));
    NSInteger unfiltered=controller.contentList.numberOfRows;
    click(search);
    for(const char *text="units";*text;text++) { key(*text,YES); key(*text,NO); }
    pump(.5);
    NSLog(@"Search native=%s source=%@ sensitive=%d delegate=%@ rows=%ld/%ld",gtk_editable_get_text(GTK_EDITABLE(search)),controller.searchField.stringValue,gtk_widget_is_sensitive(search),controller.searchField.delegate,(long)controller.contentList.numberOfRows,(long)unfiltered);
    NSCAssert([controller.searchField.stringValue isEqualToString:@"units"] && controller.contentList.numberOfRows>0
      && controller.contentList.numberOfRows<unfiltered,@"Native toolbar search filters decoded rows");
    key(XK_Control_L,YES); key(XK_a,YES); key(XK_a,NO); key(XK_Control_L,NO);
    key(XK_BackSpace,YES); key(XK_BackSpace,NO); pump(.5);
    NSCAssert(controller.contentList.numberOfRows==unfiltered,@"Clearing native search restores rows");
    id oldFont=font.oTFont;
    click(toolbarControl(toolbar,@selector(reloadFonts:))); pump(.3);
    NSCAssert(font.oTFont && font.oTFont!=oldFont && controller.fontList.numberOfRows==1,@"Native Reload toolbar action");
    GtkWidget *segments=toolbarControl(toolbar,@selector(addRemoveAction:));
    NSCAssert(segments && GTK_IS_BOX(segments),@"Native Add/Remove toolbar segments");
    GtkWidget *add=gtk_widget_get_first_child(segments);
    GtkWidget *remove=gtk_widget_get_next_sibling(add);
    NSCAssert(GTK_IS_TOGGLE_BUTTON(add) && GTK_IS_TOGGLE_BUTTON(remove),@"Both toolbar segments exist");
    NSToolbarItem *segmentItem=g_object_get_data(G_OBJECT(segments),"appkit-toolbar-item");
    NSSegmentedControl *segmentControl=(id)segmentItem.view;
    NSLog(@"Remove before action=%@ target=%@ selected=%ld fonts=%lu",NSStringFromSelector(segmentControl.action),segmentControl.target,(long)segmentControl.selectedSegment,(unsigned long)controller.fontsArray.selectedObjects.count);
    click(remove); pump(.2);
    NSLog(@"Remove after selected=%ld rows=%ld objects=%lu",(long)segmentControl.selectedSegment,(long)controller.fontList.numberOfRows,(unsigned long)[(NSArray *)controller.fontsArray.arrangedObjects count]);
    NSCAssert(controller.fontList.numberOfRows==0,@"Native Remove toolbar action");
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
