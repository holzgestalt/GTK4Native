#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import "GTK4NativeWindow.h"
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
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
static void assertApplicationProperty(Display *display, Window child, Window host, const char *name)
{
  Atom property = XInternAtom(display, name, False), types[2];
  int formats[2];
  unsigned long counts[2], remaining;
  unsigned char *data[2] = {NULL, NULL};
  Window windows[] = {child, host};
  for (int i = 0; i < 2; i++) {
    assert(XGetWindowProperty(display, windows[i], property, 0, 1024 * 1024,
      False, AnyPropertyType, &types[i], &formats[i], &counts[i], &remaining, &data[i]) == Success);
    assert(types[i] != None && counts[i] > 0 && remaining == 0);
  }
  assert(types[0] == types[1] && formats[0] == formats[1] && counts[0] == counts[1]);
  size_t stride = formats[0] == 32 ? sizeof(long) : formats[0] / 8;
  assert(!memcmp(data[0], data[1], counts[0] * stride));
  XFree(data[0]); XFree(data[1]);
}
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
    [control setImage:[NSImage imageNamed:@"common_ToolbarShowFontsItem"] forSegment:0];
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
  const char *iconPath = getenv("NATIVE_WINDOW_APP_ICON");
  if (iconPath) {
    NSImage *icon = [[[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:iconPath]] autorelease];
    assert(icon != nil); [NSApp setApplicationIconImage:icon];
  }
  [NSApp finishLaunching];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 120, 480, 300)
    styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
    backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  [window setTitle:@"Native GTK window test"];
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 220, 300, 30)];
  [field setStringValue:@"AppKit content inside a GTK window"];
  [[window contentView] addSubview:field];
  // This suite exercises the remaining AppKit editor/native-toolbar boundary.
  [[window contentView] addSubview:[[[NSTextView alloc] initWithFrame:NSZeroRect] autorelease]];
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
  XWindowAttributes backendAttributes;
  assert(parent == DefaultRootWindow(display));
  assert(XGetWindowAttributes(display,view->_child,&backendAttributes) && backendAttributes.map_state != IsViewable);
  assert(gtk_widget_get_mapped(view->_host));
  {
    Atom type;
    int format;
    unsigned long items, remaining;
    unsigned char *data = NULL;
    assert(XGetWindowProperty(display, view->_parent, XInternAtom(display, "_NET_WM_ICON", False),
      0, 1024 * 1024, False, AnyPropertyType, &type, &format, &items, &remaining, &data) == Success);
    assert(type == XA_CARDINAL && format == 32 && items > 2 && remaining == 0);
    unsigned long *icon = (unsigned long *)data;
    NSBitmapImageRep *source = [NSBitmapImageRep imageRepWithData:[[NSApp applicationIconImage] TIFFRepresentation]];
    assert(icon[0] == [source pixelsWide] && icon[1] == [source pixelsHigh]);
    assert(items == 2 + icon[0] * icon[1]);
    NSInteger x = icon[0] / 2, y = icon[1] / 2;
    NSColor *color = [[source colorAtX:x y:y] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
    unsigned long expected = ((unsigned long)lround([color alphaComponent] * 255) << 24)
      | ((unsigned long)lround([color redComponent] * 255) << 16)
      | ((unsigned long)lround([color greenComponent] * 255) << 8)
      | (unsigned long)lround([color blueComponent] * 255);
    // Xlib may sign-extend 32-bit property words on a 64-bit platform.
    assert((icon[2 + y * icon[0] + x] & 0xffffffffUL) == expected);
    XFree(data);
  }
  assertApplicationProperty(display, view->_child, view->_parent, "WM_CLASS");
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
  GtkWidget *nativeField=GTK4NativeWidgetForView(field);
  assert(GTK_IS_ENTRY(nativeField) && gtk_widget_is_ancestor(gtk_root_get_focus(GTK_ROOT(view->_host)),nativeField));
  gtk_editable_set_text(GTK_EDITABLE(nativeField),"Edited");
  [window makeFirstResponder:nil];
  assert([[field stringValue] containsString:@"Edited"]);
  // Real host input stays in the native entry and updates the AppKit model.
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
  assert([[field stringValue] containsString:@"a"]);
  // A toolbar becomes real GTK widgets in the titlebar, with original senders.
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"native-test"];
  [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
  [toolbar setDelegate:(id)delegate];
  [window setToolbar:toolbar];
  [toolbar setVisible:YES];
  pump(0.4);
  assert(view->_nativeToolbar && gtk_widget_is_ancestor(view->_nativeToolbar, view->_header));
  assert(titleLabel(view->_header, "Native GTK window test"));
  assert(!gtk_widget_has_css_class(view->_header, "default-decoration"));
  // Match a real GTK header containing a native icon button, including padding.
  GtkWidget *referenceHost = gtk_window_new();
  GtkWidget *referenceHeader = gtk_header_bar_new();
  gtk_window_set_title(GTK_WINDOW(referenceHost), "Reference");
  gtk_window_set_titlebar(GTK_WINDOW(referenceHost), referenceHeader);
  gtk_header_bar_pack_start(GTK_HEADER_BAR(referenceHeader), gtk_button_new_from_icon_name("list-add-symbolic"));
  gtk_widget_realize(referenceHost);
  int minimumHeader, nativeHeaderHeight, toolbarHeaderHeight;
  gtk_widget_measure(referenceHeader, GTK_ORIENTATION_VERTICAL, -1, &minimumHeader, &nativeHeaderHeight, NULL, NULL);
  gtk_widget_measure(view->_header, GTK_ORIENTATION_VERTICAL, -1, &minimumHeader, &toolbarHeaderHeight, NULL, NULL);
  NSLog(@"Header metrics: toolbar=%d native=%d extra=%.0f", toolbarHeaderHeight, nativeHeaderHeight, view->_toolbarExtraHeight);
  assert(toolbarHeaderHeight == nativeHeaderHeight);
  gtk_window_destroy(GTK_WINDOW(referenceHost));
  GtkWidget *nativeButton = gtk_widget_get_first_child(view->_nativeToolbarItems);
  assert(GTK_IS_BUTTON(nativeButton));
  GtkWidget *icon = gtk_widget_get_first_child(gtk_button_get_child(GTK_BUTTON(nativeButton)));
  assert(GTK_IS_IMAGE(icon));
  GdkPaintable *paintable = gtk_image_get_paintable(GTK_IMAGE(icon));
  int iconScale = gtk_widget_get_scale_factor(view->_host);
  assert(GDK_IS_TEXTURE(paintable));
  GtkWidget *referenceImage = gtk_image_new_from_icon_name("list-add-symbolic");
  g_object_ref_sink(referenceImage);
  gtk_image_set_icon_size(GTK_IMAGE(referenceImage), GTK_ICON_SIZE_NORMAL);
  int minimumIconSize, nativeIconSize;
  gtk_widget_measure(referenceImage, GTK_ORIENTATION_HORIZONTAL, -1, &minimumIconSize, &nativeIconSize, NULL, NULL);
  g_object_unref(referenceImage);
  int flatIconSize = lround(nativeIconSize * 1.25);
  int flatIconPadding = (lround(nativeIconSize * 1.5) - flatIconSize) / 2;
  int flatIconFootprint = flatIconSize + 2 * flatIconPadding;
  assert(gdk_texture_get_width(GDK_TEXTURE(paintable)) == flatIconSize * iconScale);
  assert(gdk_texture_get_height(GDK_TEXTURE(paintable)) == flatIconSize * iconScale);
  assert(fabs(toolbarImageDensity - flatIconSize / 16.0 * iconScale) < 0.01);
  int minimumSize, imageWidth, imageHeight;
  gtk_widget_measure(icon, GTK_ORIENTATION_HORIZONTAL, -1, &minimumSize, &imageWidth, NULL, NULL);
  gtk_widget_measure(icon, GTK_ORIENTATION_VERTICAL, -1, &minimumSize, &imageHeight, NULL, NULL);
  assert(imageWidth == flatIconFootprint && imageHeight == flatIconFootprint);
  assert(gtk_widget_get_margin_start(icon) == flatIconPadding);
  assert(gtk_widget_get_margin_end(icon) == flatIconPadding);
  assert(gtk_widget_get_margin_top(icon) == flatIconPadding);
  assert(gtk_widget_get_margin_bottom(icon) == flatIconPadding);
  GtkWidget *referenceButton = gtk_button_new_from_icon_name("list-add-symbolic");
  gtk_widget_add_css_class(referenceButton, "flat");
  gtk_header_bar_pack_start(GTK_HEADER_BAR(view->_header), referenceButton);
  int referenceWidth, referenceHeight, buttonWidth, buttonHeight;
  gtk_widget_measure(referenceButton, GTK_ORIENTATION_HORIZONTAL, -1, &minimumSize, &referenceWidth, NULL, NULL);
  gtk_widget_measure(referenceButton, GTK_ORIENTATION_VERTICAL, -1, &minimumSize, &referenceHeight, NULL, NULL);
  gtk_widget_measure(nativeButton, GTK_ORIENTATION_HORIZONTAL, -1, &minimumSize, &buttonWidth, NULL, NULL);
  gtk_widget_measure(nativeButton, GTK_ORIENTATION_VERTICAL, -1, &minimumSize, &buttonHeight, NULL, NULL);
  NSLog(@"Toolbar metrics: scale=%d icon=%d texture=%d button=%dx%d native=%dx%d", iconScale, imageWidth,
    gdk_texture_get_width(GDK_TEXTURE(paintable)), buttonWidth, buttonHeight, referenceWidth, referenceHeight);
  assert(buttonWidth == referenceWidth && buttonHeight == referenceHeight);
  gtk_header_bar_remove(GTK_HEADER_BAR(view->_header), referenceButton);
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
  // Both toolbar controls and native text entries keep focus in GTK.
  point = [field convertPoint:NSMakePoint(80,15) toView:nil];
  XTranslateCoordinates(display,view->_child,DefaultRootWindow(display),
    lround(point.x),lround([window frame].size.height-point.y),&px,&py,&ignored);
  motion(display,-1,px,py,CurrentTime);
  release = [NSTimer timerWithTimeInterval:.08 target:delegate selector:@selector(releasePointer:) userInfo:nil repeats:NO];
  [[NSRunLoop currentRunLoop] addTimer:release forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:release forMode:NSDefaultRunLoopMode];
  button(display,1,True,CurrentTime); XFlush(display); pump(.2);
  Window focus; int revert; XGetInputFocus(display,&focus,&revert);
  nativeField=GTK4NativeWidgetForView(field);
  assert(focus == view->_parent && gtk_widget_is_ancestor(gtk_root_get_focus(GTK_ROOT(view->_host)),nativeField));
  key(display,XKeysymToKeycode(display,XK_c),True,CurrentTime);
  key(display,XKeysymToKeycode(display,XK_c),False,CurrentTime); XFlush(display); pump(.2);
  assert([[field stringValue] containsString:@"c"]);
  NSSize withToolbar = [[window contentView] frame].size;
  [toolbar setVisible:NO]; pump(0.2);
  assert(!view->_nativeToolbar);
  assert(gtk_widget_has_css_class(view->_header, "default-decoration"));
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
  GtkWidget *segmentIcon = gtk_button_get_child(GTK_BUTTON(gtk_widget_get_first_child(segments)));
  assert(GTK_IS_IMAGE(segmentIcon));
  int segmentWidth;
  gtk_widget_measure(segmentIcon, GTK_ORIENTATION_HORIZONTAL, -1, &minimumSize, &segmentWidth, NULL, NULL);
  assert(segmentWidth == nativeIconSize);
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
  // Exercise the native symbolic replacements, including template names not
  // supplied as files by this AppKit build. Other artwork uses the renderer.
  NSArray *templateNames = @[@"NSAddTemplate", @"NSRemoveTemplate", @"NSRefreshTemplate", @"NSRefreshFreestandingTemplate", @"NSStopProgressTemplate", @"NSStopProgressFreestandingTemplate", @"NSEnterFullScreenTemplate", @"NSExitFullScreenTemplate", @"NSGoLeftTemplate", @"NSGoRightTemplate", @"NSLeftFacingTriangleTemplate", @"NSRightFacingTriangleTemplate", @"NSIconViewTemplate", @"NSListViewTemplate", @"NSLockLockedTemplate", @"NSLockUnlockedTemplate", @"NSBluetoothTemplate", @"NSTouchBarPlayTemplate", @"NSTouchBarRecordStopTemplate", @"NSTouchBarPauseTemplate", @"NSTouchBarDeleteTemplate", @"NSTouchBarSearchTemplate", @"NSTouchBarSidebarTemplate"];
  NSArray *symbolNames = @[@"list-add-symbolic", @"list-remove-symbolic", @"view-refresh-symbolic", @"view-refresh-symbolic", @"process-stop-symbolic", @"process-stop-symbolic", @"view-fullscreen-symbolic", @"view-restore-symbolic", @"go-previous-symbolic", @"go-next-symbolic", @"pan-start-symbolic", @"pan-end-symbolic", @"view-grid-symbolic", @"view-list-symbolic", @"changes-prevent-symbolic", @"changes-allow-symbolic", @"bluetooth-symbolic", @"media-playback-start-symbolic", @"media-playback-stop-symbolic", @"media-playback-pause-symbolic", @"user-trash-symbolic", @"system-search-symbolic", @"sidebar-show-symbolic"];
  for (NSUInteger i = 0; i < [templateNames count]; i++) {
    NSString *name = [templateNames objectAtIndex:i];
    NSImage *image = [NSImage imageNamed:name];
    if (image == nil) {
      image = [[[NSImage alloc] initWithSize:NSMakeSize(16, 16)] autorelease];
      [image setName:name]; [image setTemplate:YES];
    }
    assert(image != nil);
    [firstItem setImage:image]; pump(0.1);
    GtkWidget *symbolButton = gtk_widget_get_first_child(view->_nativeToolbarItems);
    GtkWidget *symbol = gtk_widget_get_first_child(gtk_button_get_child(GTK_BUTTON(symbolButton)));
    assert(GTK_IS_IMAGE(symbol));
    assert(gtk_image_get_storage_type(GTK_IMAGE(symbol)) == GTK_IMAGE_ICON_NAME);
    assert(!strcmp(gtk_image_get_icon_name(GTK_IMAGE(symbol)), [[symbolNames objectAtIndex:i] UTF8String]));
    assert(gtk_image_get_pixel_size(GTK_IMAGE(symbol)) == flatIconSize);
    int minimum, natural;
    gtk_widget_measure(symbol, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, NULL, NULL);
    assert(natural == flatIconFootprint);
  }
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
  assert(parent == DefaultRootWindow(display) && gtk_widget_get_mapped(view->_host));
  assert(XGetWindowAttributes(display,view->_child,&backendAttributes) && backendAttributes.map_state != IsViewable);
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
