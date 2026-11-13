#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <assert.h>
#include <dlfcn.h>
#include <X11/keysym.h>
#include <cairo-xlib.h>

static GtkWidget *closeControl(GtkWidget *widget)
{
  if (GTK_IS_BUTTON(widget) && gtk_widget_has_css_class(widget, "close")) return widget;
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
    GtkWidget *found = closeControl(child);
    if (found) return found;
  }
  return NULL;
}
static GtkWidget *titleLabel(GtkWidget *widget, const char *title)
{
  if (GTK_IS_LABEL(widget) && !strcmp(gtk_label_get_text(GTK_LABEL(widget)), title)
      && gtk_widget_get_mapped(widget) && gtk_widget_get_width(widget) > 0) return widget;
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
    GtkWidget *found = titleLabel(child, title);
    if (found) return found;
  }
  return NULL;
}
static void pump(double seconds)
{
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([end timeIntervalSinceNow] > 0) {
    for (int i = 0; i < 64 && g_main_context_pending(NULL); i++) g_main_context_iteration(NULL, FALSE);
    NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask
      untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01] inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
}
static Display *inputDisplay;
static CGFloat toolbarImageDensity;
@interface ToolbarVectorRep : NSImageRep
@end
@implementation ToolbarVectorRep
- (BOOL)draw
{
  NSAffineTransformStruct matrix = [[[NSGraphicsContext currentContext] GSCurrentCTM] transformStruct];
  toolbarImageDensity = hypot(matrix.m11, matrix.m12);
  [[NSColor blackColor] set];
  NSRectFill(NSMakeRect(0, 0, 16, 16));
  return YES;
}
@end
static int (*releaseButton)(Display *, unsigned int, int, unsigned long);

@interface WindowDelegate : NSObject
{
@public
  BOOL allowClose;
  int closeRequests;
  int toolbarClicks;
  BOOL disableToolbarAction;
  id toolbarSender;
}
@end
@implementation WindowDelegate
- (void)releasePointer:(NSTimer *)timer { releaseButton(inputDisplay, 1, False, CurrentTime); XFlush(inputDisplay); }
- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar { return [NSArray arrayWithObject:@"action"]; }
- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [NSArray arrayWithObjects:@"action", @"search", @"segments", @"custom", @"button", nil]; }
- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)identifier willBeInsertedIntoToolbar:(BOOL)insert
{
  NSToolbarItem *item = [identifier isEqual:@"search"]
    ? [[[NSSearchToolbarItem alloc] initWithItemIdentifier:identifier] autorelease]
    : [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];
  if ([identifier isEqual:@"segments"]) {
    NSSegmentedControl *control = [[[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 70, 24)] autorelease];
    [control setSegmentCount:2]; [control setLabel:@"A" forSegment:0]; [control setLabel:@"B" forSegment:1];
    [control setTarget:self]; [control setAction:@selector(toolbarAction:)]; [item setView:control];
  } else if ([identifier isEqual:@"custom"]) {
    [item setView:[[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 30, 24)] autorelease]];
  } else if ([identifier isEqual:@"button"]) {
    NSButton *control = [[[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 24)] autorelease];
    [control setTarget:self]; [control setAction:@selector(toolbarAction:)]; [item setView:control];
  }
  [item setLabel:@"Run action"]; [item setImage:[NSImage imageNamed:@"common_ToolbarShowFontsItem"]];
  if ([identifier isEqual:@"action"]) {
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(16, 16)] autorelease];
    ToolbarVectorRep *rep = [[[ToolbarVectorRep alloc] init] autorelease];
    [rep setSize:NSMakeSize(16, 16)];
    [rep setPixelsWide:NSImageRepMatchesDevice]; [rep setPixelsHigh:NSImageRepMatchesDevice];
    [image addRepresentation:rep]; [item setImage:image];
  }
  [item setTarget:self]; [item setAction:@selector(toolbarAction:)]; return item;
}
- (BOOL)validateToolbarItem:(NSToolbarItem *)item { return !disableToolbarAction; }
- (void)toolbarAction:(id)sender { toolbarClicks++; toolbarSender = sender; }
- (BOOL)windowShouldClose:(id)sender { closeRequests++; return allowClose; }
@end
int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSApplication sharedApplication];
  [NSApp finishLaunching];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 120, 480, 300)
    styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
    backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  [window setTitle:@"Native GTK window test"];
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 220, 300, 30)];
  [field setStringValue:@"AppKit content inside a GTK window"];
  [[window contentView] addSubview:field];
  WindowDelegate *delegate = [WindowDelegate new];
  [window setDelegate:delegate];
  [NSApp activateIgnoringOtherApps:YES];
  [window makeKeyAndOrderFront:nil];
  pump(1.0);
  NSView *rootView = [[window contentView] superview];
  assert([rootView isKindOfClass:[GTK4NativeWindowDecorationView class]]);
  GTK4NativeWindowDecorationView *view = (id)rootView;
  Display *display = (Display *)[GSCurrentServer() serverDevice];
  Window root, parent, *children;
  unsigned int count;
  XQueryTree(display, view->_child, &root, &parent, &children, &count);
  if (children) XFree(children);
  assert(parent == view->_parent);
  assert(gtk_widget_get_mapped(view->_host));
  assert(gtk_widget_get_height(view->_header) > 0);
  const char *preview = g_getenv("NATIVE_WINDOW_PREVIEW");
  if (preview) {
    XWindowAttributes attr;
    XGetWindowAttributes(display, view->_parent, &attr);
    cairo_surface_t *surface = cairo_xlib_surface_create(display, view->_parent, attr.visual, attr.width, attr.height);
    cairo_surface_write_to_png(surface, preview);
    cairo_surface_destroy(surface);
  }

  NSLog(@"AppKit frame %@ native %dx%d content %@", NSStringFromRect([window frame]),
    gtk_widget_get_width(view->_host), gtk_widget_get_height(view->_host), NSStringFromRect([[window contentView] frame]));
  assert(fabs([window frame].size.width - gtk_widget_get_width(view->_host) * gdk_surface_get_scale_factor(gtk_native_get_surface(GTK_NATIVE(view->_host)))) < 2);
  [window makeFirstResponder:field];
  assert([window fieldEditor:NO forObject:field] == [window firstResponder]);
  [[window fieldEditor:NO forObject:field] insertText:@"Edited"];
  [window makeFirstResponder:nil];
  assert([[field stringValue] containsString:@"Edited"]);
  // Real X11 pointer and keyboard events must reach AppKit through its child.
  void *xtst = dlopen("libXtst.so.6", RTLD_NOW);
  assert(xtst);
  int (*motion)(Display *, int, int, int, unsigned long) = dlsym(xtst, "XTestFakeMotionEvent");
  int (*button)(Display *, unsigned int, int, unsigned long) = dlsym(xtst, "XTestFakeButtonEvent");
  int (*key)(Display *, unsigned int, int, unsigned long) = dlsym(xtst, "XTestFakeKeyEvent");
  assert(motion && button && key);
  [field setStringValue:@""];
  NSPoint point = [field convertPoint:NSMakePoint(80, 15) toView:nil];
  int px, py; Window ignored;
  double dx, dy;
  XTranslateCoordinates(display, view->_child, DefaultRootWindow(display),
    lround(point.x), lround([window frame].size.height - point.y), &px, &py, &ignored);
  motion(display, -1, px, py, CurrentTime);
  inputDisplay = display; releaseButton = button;
  NSTimer *release = [NSTimer timerWithTimeInterval:0.08 target:delegate selector:@selector(releasePointer:) userInfo:nil repeats:NO];
  [[NSRunLoop currentRunLoop] addTimer:release forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:release forMode:NSDefaultRunLoopMode];
  button(display, 1, True, CurrentTime); XFlush(display);
  pump(0.2);
  key(display, XKeysymToKeycode(display, XK_a), True, CurrentTime);
  key(display, XKeysymToKeycode(display, XK_a), False, CurrentTime); XFlush(display);
  pump(0.2);
  assert([[[window fieldEditor:NO forObject:field] string] containsString:@"a"]);
  // A toolbar becomes real GTK widgets in the titlebar, with original senders.
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"native-test"];
  [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
  [toolbar setDelegate:(id)delegate];
  [window setToolbar:toolbar];
  [toolbar setVisible:YES];
  pump(0.4);
  assert(view->_nativeToolbar && gtk_widget_is_ancestor(view->_nativeToolbar, view->_header));
  assert(titleLabel(view->_header, "Native GTK window test"));
  GtkWidget *nativeButton = gtk_widget_get_first_child(view->_nativeToolbarItems);
  assert(GTK_IS_BUTTON(nativeButton));
  GtkWidget *icon = gtk_widget_get_first_child(gtk_button_get_child(GTK_BUTTON(nativeButton)));
  assert(GTK_IS_IMAGE(icon));
  GdkPaintable *paintable = gtk_image_get_paintable(GTK_IMAGE(icon));
  int iconScale = gtk_widget_get_scale_factor(view->_host);
  assert(GDK_IS_TEXTURE(paintable));
  assert(gdk_texture_get_width(GDK_TEXTURE(paintable)) == 24 * iconScale);
  assert(gdk_texture_get_height(GDK_TEXTURE(paintable)) == 24 * iconScale);
  assert(fabs(toolbarImageDensity - 1.5 * iconScale) < 0.01);
  graphene_rect_t buttonBounds, contentBounds;
  assert(gtk_widget_compute_bounds(nativeButton, view->_host, &buttonBounds));
  assert(gtk_widget_compute_bounds(gtk_window_get_child(GTK_WINDOW(view->_host)), view->_host, &contentBounds));
  assert(buttonBounds.origin.y < contentBounds.origin.y);
  gtk_native_get_surface_transform(GTK_NATIVE(view->_host), &dx, &dy);
  int toolbarScale = gdk_surface_get_scale_factor(gtk_native_get_surface(GTK_NATIVE(view->_host)));
  XTranslateCoordinates(display, view->_parent, DefaultRootWindow(display),
    lround((dx + buttonBounds.origin.x + buttonBounds.size.width / 2) * toolbarScale),
    lround((dy + buttonBounds.origin.y + buttonBounds.size.height / 2) * toolbarScale), &px, &py, &ignored);
  motion(display, -1, px, py, CurrentTime);
  button(display, 1, True, CurrentTime); XFlush(display); pump(0.08);
  button(display, 1, False, CurrentTime); XFlush(display); pump(0.2);
  assert(delegate->toolbarClicks == 1);
  assert([delegate->toolbarSender isKindOfClass:[NSToolbarItem class]]);
  assert([[[delegate->toolbarSender toolbar] identifier] isEqual:@"native-test"]);
  NSSize withToolbar = [[window contentView] frame].size;
  [toolbar setVisible:NO]; pump(0.2);
  assert(!view->_nativeToolbar);
  [toolbar setVisible:YES]; pump(0.2);
  assert(view->_nativeToolbar);
  assert(NSEqualSizes(withToolbar, [[window contentView] frame].size));
  [toolbar insertItemWithItemIdentifier:@"search" atIndex:1]; pump(0.2);
  GtkWidget *search = gtk_widget_get_last_child(view->_nativeToolbarSearch);
  assert(GTK_IS_SEARCH_ENTRY(search));
  assert(gtk_widget_compute_bounds(search, view->_host, &buttonBounds));
  XTranslateCoordinates(display, view->_parent, DefaultRootWindow(display),
    lround((dx + buttonBounds.origin.x + buttonBounds.size.width / 2) * toolbarScale),
    lround((dy + buttonBounds.origin.y + buttonBounds.size.height / 2) * toolbarScale), &px, &py, &ignored);
  motion(display, -1, px, py, CurrentTime);
  button(display, 1, True, CurrentTime); XFlush(display); pump(0.08);
  button(display, 1, False, CurrentTime); XFlush(display); pump(0.1);
  key(display, XKeysymToKeycode(display, XK_b), True, CurrentTime);
  key(display, XKeysymToKeycode(display, XK_b), False, CurrentTime); XFlush(display); pump(0.5);
  NSSearchField *searchField = (id)[[[toolbar items] objectAtIndex:1] view];
  assert([[searchField stringValue] containsString:@"b"]);
  assert(delegate->toolbarSender == searchField);
  [toolbar insertItemWithItemIdentifier:@"segments" atIndex:2]; pump(0.2);
  GtkWidget *segments = gtk_widget_get_last_child(view->_nativeToolbarItems);
  assert(GTK_IS_BOX(segments));
  g_signal_emit_by_name(gtk_widget_get_last_child(segments), "clicked"); pump(0.1);
  NSSegmentedControl *segmentControl = (id)[[[toolbar items] objectAtIndex:2] view];
  assert([segmentControl selectedSegment] == 1 && delegate->toolbarSender == segmentControl);
  [toolbar insertItemWithItemIdentifier:@"button" atIndex:3]; pump(0.2);
  g_signal_emit_by_name(gtk_widget_get_last_child(view->_nativeToolbarItems), "clicked"); pump(0.1);
  assert(delegate->toolbarSender == [[[toolbar items] objectAtIndex:3] view]);
  [toolbar insertItemWithItemIdentifier:@"custom" atIndex:4]; pump(0.2);
  assert(!view->_nativeToolbar);
  [toolbar removeItemAtIndex:4]; pump(0.3);
  assert(view->_nativeToolbar);
  for (int i = 0; i < 3; i++) [toolbar removeItemAtIndex:1];
  pump(0.2);
  assert(NSEqualSizes(withToolbar, [[window contentView] frame].size));
  [toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel]; pump(0.2);
  [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly]; pump(0.2);
  assert(NSEqualSizes(withToolbar, [[window contentView] frame].size));
  NSToolbarItem *firstItem = [[toolbar items] objectAtIndex:0];
  delegate->disableToolbarAction = YES; [toolbar validateVisibleItems]; pump(0.3);
  assert(!gtk_widget_is_sensitive(gtk_widget_get_first_child(view->_nativeToolbarItems)));
  delegate->disableToolbarAction = NO; [toolbar validateVisibleItems]; pump(0.3);
  assert(gtk_widget_is_sensitive(gtk_widget_get_first_child(view->_nativeToolbarItems)));
  CGFloat narrowWidth = [window frame].size.width;
  [firstItem setLabel:@"A toolbar action with a deliberately very long title that needs the overflow menu in a narrow window"];
  [toolbar setDisplayMode:NSToolbarDisplayModeLabelOnly]; pump(0.3);
  assert(gtk_widget_get_visible(view->_toolbarOverflow));
  assert(fabs([window frame].size.width - narrowWidth) < 2);
  [firstItem setLabel:@"Run action"]; [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly]; pump(0.2);
  NSRect before = [window frame];
  NSRect next = before;
  next.origin.x += 40; next.size.width += 80; next.size.height += 40;
  [window setFrame:next display:YES];
  pump(0.5);
  NSLog(@"After resize %@ requested %@", NSStringFromRect([window frame]), NSStringFromRect(next));
  assert(fabs([window frame].size.width - next.size.width) < 2);
  if (g_getenv("NATIVE_WINDOW_WM_TEST")) {
    gtk_window_maximize(GTK_WINDOW(view->_host)); pump(0.7);
    assert(gtk_window_is_maximized(GTK_WINDOW(view->_host)));
    assert(GTK4NativeWindowCornerRadius(view->_host) == 0);
    gtk_window_unmaximize(GTK_WINDOW(view->_host)); pump(0.7);
    assert(!gtk_window_is_maximized(GTK_WINDOW(view->_host)));
    gtk_window_minimize(GTK_WINDOW(view->_host)); pump(0.7);
    assert([window isMiniaturized]);
    gtk_window_unminimize(GTK_WINDOW(view->_host)); gtk_window_present(GTK_WINDOW(view->_host)); pump(0.7);
    assert(![window isMiniaturized] && [window isVisible]);
  }
  [window setTitle:@"Updated native title"];
  assert(!strcmp(gtk_window_get_title(GTK_WINDOW(view->_host)), "Updated native title"));
  pump(0.1);
  assert(titleLabel(view->_header, "Updated native title"));
  [window setDocumentEdited:YES]; pump(0.1);
  assert(titleLabel(view->_header, "Updated native title •"));
  [window setDocumentEdited:NO]; pump(0.1);
  assert(titleLabel(view->_header, "Updated native title"));
  [window orderOut:nil]; pump(0.1);
  assert(!gtk_widget_get_visible(view->_host));
  [window makeKeyAndOrderFront:nil]; pump(0.3);
  assert(gtk_widget_get_visible(view->_host));
  [window setOneShot:YES];
  [window orderOut:nil]; pump(0.1);
  [window makeKeyAndOrderFront:nil]; pump(0.3);
  XQueryTree(display, view->_child, &root, &parent, &children, &count);
  if (children) XFree(children);
  assert(parent == view->_parent && gtk_widget_get_mapped(view->_host));
  GtkWidget *close = closeControl(view->_header);
  assert(close);
  graphene_rect_t closeBounds;
  assert(gtk_widget_compute_bounds(close, view->_host, &closeBounds));
  gtk_native_get_surface_transform(GTK_NATIVE(view->_host), &dx, &dy);
  int nativeScale = gdk_surface_get_scale_factor(gtk_native_get_surface(GTK_NATIVE(view->_host)));
  XTranslateCoordinates(display, view->_parent, DefaultRootWindow(display),
    lround((dx + closeBounds.origin.x + closeBounds.size.width / 2) * nativeScale),
    lround((dy + closeBounds.origin.y + closeBounds.size.height / 2) * nativeScale), &px, &py, &ignored);
  motion(display, -1, px, py, CurrentTime);
  button(display, 1, True, CurrentTime); XFlush(display);
  pump(0.08);
  button(display, 1, False, CurrentTime); XFlush(display);
  pump(0.2);
  assert(delegate->closeRequests == 1 && [window isVisible]);
  delegate->allowClose = YES;
  gtk_window_close(GTK_WINDOW(view->_host)); pump(0.1);
  assert(delegate->closeRequests == 2 && ![window isVisible]);
  [window setDelegate:nil];
  [toolbar release];
  [window release]; [field release]; [delegate release];
  dlclose(xtst);
  pump(0.1);
  NSLog(@"Native GTK window host passed: ownership, layout, editing, resize, title, hide/show and close delegation");
  [pool drain];
  return 0;
}
