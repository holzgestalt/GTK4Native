#import <AppKit/AppKit.h>
#import "GTK4NativeWindow.h"
#import "GTK4NativeTable.h"
#include <gdk/x11/gdkx.h>
#include <dlfcn.h>

@interface NSTableView (OutlinePrototype)
- (void)_registerPrototypeViews:(NSArray *)views;
@end
static NSTableCellView *cell(void)
{
  NSTableCellView *view=[[[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,260,24)] autorelease];
  view.identifier=@"Row";
  NSTextField *label=[[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,260,24)] autorelease];
  label.editable=NO; label.bezeled=NO; label.drawsBackground=NO;
  label.autoresizingMask=NSViewWidthSizable;
  [view addSubview:label]; view.textField=label;
  [label bind:NSValueBinding toObject:view withKeyPath:@"objectValue" options:nil];
  return view;
}
@interface OutlineData : NSObject { @public NSUInteger templates; }
@end
@implementation OutlineData
- (NSArray *)children:(id)item
{
  if(!item) return @[@"Before",@"Folder",@"After A",@"After B",@"After C"];
  if([item isEqual:@"Folder"]) return @[@"Nested",@"Child A",@"Child B"];
  if([item isEqual:@"Nested"]) return @[@"Grandchild A",@"Grandchild B"];
  return @[];
}
- (NSInteger)outlineView:(NSOutlineView *)view numberOfChildrenOfItem:(id)item { return [self children:item].count; }
- (id)outlineView:(NSOutlineView *)view child:(NSInteger)index ofItem:(id)item { return [self children:item][index]; }
- (BOOL)outlineView:(NSOutlineView *)view isItemExpandable:(id)item { return [self children:item].count>0; }
- (NSView *)outlineView:(NSOutlineView *)view viewForTableColumn:(NSTableColumn *)column item:(id)item
{ templates++; return cell(); }
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
static GtkWidget *labelFor(GtkWidget *widget,const char *title)
{
  if(GTK_IS_LABEL(widget) && !strcmp(gtk_label_get_text(GTK_LABEL(widget)),title)) return widget;
  for(GtkWidget *child=gtk_widget_get_first_child(widget);child;child=gtk_widget_get_next_sibling(child)) {
    GtkWidget *found=labelFor(child,title); if(found) return found;
  }
  return NULL;
}
static GtkWidget *disclosure(GtkWidget *label)
{
  for(GtkWidget *row=label;row;row=gtk_widget_get_parent(row)) {
    GtkWidget *child=gtk_widget_get_first_child(row);
    if(child && gtk_widget_has_css_class(child,"gnustep-disclosure")) return child;
  }
  return NULL;
}
static void click(GtkWidget *widget,GtkWidget *host)
{
  NSCAssert(widget && gtk_widget_get_mapped(widget),@"native disclosure is mapped");
  graphene_rect_t bounds;
  NSCAssert(gtk_widget_compute_bounds(widget,host,&bounds),@"native disclosure coordinates");
  GdkSurface *surface=gtk_native_get_surface(GTK_NATIVE(host));
  Display *display=gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  double dx,dy; gtk_native_get_surface_transform(GTK_NATIVE(host),&dx,&dy);
  int scale=gdk_surface_get_scale_factor(surface),x,y; Window ignored;
  XTranslateCoordinates(display,gdk_x11_surface_get_xid(surface),DefaultRootWindow(display),
    lround((dx+bounds.origin.x+bounds.size.width/2)*scale),lround((dy+bounds.origin.y+bounds.size.height/2)*scale),&x,&y,&ignored);
  void *xtst=dlopen("libXtst.so.6",RTLD_NOW);
  int (*motion)(Display *,int,int,int,unsigned long)=dlsym(xtst,"XTestFakeMotionEvent");
  int (*button)(Display *,unsigned int,int,unsigned long)=dlsym(xtst,"XTestFakeButtonEvent");
  NSCAssert(motion && button,@"native pointer functions");
  motion(display,-1,x,y,CurrentTime); button(display,1,True,CurrentTime); button(display,1,False,CurrentTime); XFlush(display);
  pump(.25); dlclose(xtst);
}
typedef struct { guint events,position,removed,added; } Changes;
static void changed(GListModel *model,guint position,guint removed,guint added,gpointer data)
{ Changes *changes=data; changes->events++; changes->position=position; changes->removed=removed; changes->added=added; }
static void unmapped(GtkWidget *widget,gpointer count) { (*(NSUInteger *)count)++; }
static void painted(GdkFrameClock *clock,gpointer count) { (*(NSUInteger *)count)++; }
int main(void)
{
  @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp finishLaunching];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(40,40,500,500)
      styleMask:NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:[window.contentView bounds]] autorelease];
    scroll.hasVerticalScroller=YES; scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    NSOutlineView *outline=[[[NSOutlineView alloc] initWithFrame:NSMakeRect(0,0,480,480)] autorelease];
    NSTableColumn *column=[[[NSTableColumn alloc] initWithIdentifier:@"Name"] autorelease];
    [outline addTableColumn:column]; outline.outlineTableColumn=column; outline.headerView=nil;
    outline.rowHeight=24; [outline _registerPrototypeViews:@[cell()]];
    OutlineData *data=[OutlineData new]; outline.dataSource=(id)data; outline.delegate=(id)data;
    scroll.documentView=outline; [window.contentView addSubview:scroll]; [outline reloadData];
    [window makeKeyAndOrderFront:nil]; pump(.5);
    GTK4NativeTable *peer=[outline valueForKey:@"_nativeTableView"];
    NSCAssert(peer && peer->_embedded,@"outline has a native embedded model");
    GtkWidget *before=labelFor(peer->_list,"Before"),*after=labelFor(peer->_list,"After A");
    NSCAssert(before && after,@"surrounding native rows are populated");
    g_object_ref(before); g_object_ref(after);
    NSUInteger unmaps=0;
    gulong unmapSignals[]={g_signal_connect(before,"unmap",G_CALLBACK(unmapped),&unmaps),
      g_signal_connect(after,"unmap",G_CALLBACK(unmapped),&unmaps),g_signal_connect(peer->_list,"unmap",G_CALLBACK(unmapped),&unmaps)};
    Changes changes={0}; gulong modelSignal=g_signal_connect(peer->_model,"items-changed",G_CALLBACK(changed),&changes);
    [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:3] byExtendingSelection:NO]; pump(.1);
    NSUInteger templates=data->templates;
    for(int cycle=0;cycle<3;cycle++) {
      changes=(Changes){0};
      click(disclosure(labelFor(peer->_list,"Folder")),GTK_WIDGET(GTK4NativeHostForWindow(window)));
      NSCAssert([outline isItemExpanded:@"Folder"] && outline.numberOfRows==8,@"native disclosure expands the subtree");
      NSCAssert(changes.events==1 && changes.position==2 && changes.removed==0 && changes.added==3,@"expanding only inserts child rows");
      NSCAssert(labelFor(peer->_list,"Before")==before && labelFor(peer->_list,"After A")==after && unmaps==0,
        @"expanding preserves surrounding mapped row widgets");
      NSCAssert([[outline itemAtRow:outline.selectedRow] isEqual:@"After B"],@"expanding preserves selection by item");
      NSCAssert(gtk_single_selection_get_selected(GTK_SINGLE_SELECTION(peer->_selection))==outline.selectedRow,@"native selection follows the selected item after insertion");
      changes=(Changes){0};
      click(disclosure(labelFor(peer->_list,"Folder")),GTK_WIDGET(GTK4NativeHostForWindow(window)));
      NSCAssert(![outline isItemExpanded:@"Folder"] && outline.numberOfRows==5,@"native disclosure collapses the subtree");
      NSCAssert(changes.events==1 && changes.position==2 && changes.removed==3 && changes.added==0,@"collapsing only removes child rows");
      NSCAssert(labelFor(peer->_list,"Before")==before && labelFor(peer->_list,"After A")==after && unmaps==0,
        @"collapsing preserves surrounding mapped row widgets");
      NSCAssert([[outline itemAtRow:outline.selectedRow] isEqual:@"After B"]
        && gtk_single_selection_get_selected(GTK_SINGLE_SELECTION(peer->_selection))==outline.selectedRow,@"collapse preserves AppKit and GTK selection");
    }
    [outline expandItem:@"Folder" expandChildren:YES]; pump(.3);
    NSCAssert([outline isItemExpanded:@"Nested"] && outline.numberOfRows==10 && unmaps==0,@"recursive expansion preserves surrounding rows");
    [outline collapseItem:@"Folder" collapseChildren:YES]; pump(.3);
    NSCAssert(outline.numberOfRows==5 && unmaps==0,@"recursive collapse preserves surrounding rows");
    NSUInteger beforeReload=data->templates;
    NSCAssert(beforeReload-templates==14,@"only inserted child items request new cell content");
    [outline reloadData]; pump(.3);
    NSCAssert(data->templates>beforeReload,@"explicit reloads still refresh delegate-provided content");
    NSUInteger frames=0;
    GdkFrameClock *clock=gtk_widget_get_frame_clock(peer->_list);
    gulong frameSignal=g_signal_connect(clock,"after-paint",G_CALLBACK(painted),&frames);
    pump(.4); g_signal_handler_disconnect(clock,frameSignal);
    NSCAssert(frames<=2,@"unchanged disclosure icons leave GTK idle");
    NSLog(@"PASS: native disclosure inserts/removes only subtree rows; zero surrounding unmaps; %lu templates for new children; selection, recursion, explicit reload and teardown",(unsigned long)(beforeReload-templates));
    g_signal_handler_disconnect(peer->_model,modelSignal);
    g_signal_handler_disconnect(before,unmapSignals[0]); g_signal_handler_disconnect(after,unmapSignals[1]); g_signal_handler_disconnect(peer->_list,unmapSignals[2]);
    g_object_unref(before);g_object_unref(after);
    [window close]; [window release]; [data release];
  }
  return 0;
}
