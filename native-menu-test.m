#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <GNUstepGUI/GSDisplayServer.h>
#include <cairo-xlib.h>
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <X11/keysym.h>
#include <dlfcn.h>

static int activations;
static BOOL dispatchedAfterClose;
static BOOL appKitTimerFired;
static BOOL cancelMenu;
static BOOL pointerMenu;
static BOOL nestedMenu;
static int (*fakeButton)(Display *, unsigned int, int, unsigned long);
static int (*fakeMotion)(Display *, int, int, int, unsigned long);
static void *xtst;
static int (*fakeKey)(Display *, unsigned int, int, unsigned long);

@interface MenuTarget : NSObject
- (void)choose:(id)sender;
- (void)timer:(NSTimer *)timer;
@end
@implementation MenuTarget
- (void)choose:(id)sender {
  activations++;
  dispatchedAfterClose = YES;
  GListModel *windows = gtk_window_get_toplevels();
  for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
    GtkWidget *window = g_list_model_get_item(windows, i);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
    if (surface && gdk_surface_get_mapped(surface)
        && !gtk_widget_has_css_class(window, "gnustep-native-window")) dispatchedAfterClose = NO;
    g_object_unref(window);
  }
}
- (void)timer:(NSTimer *)timer { appKitTimerFired = YES; }
@end

static void key(Display *display, KeySym symbol)
{
  unsigned int code = XKeysymToKeycode(display, symbol);
  fakeKey(display, code, True, CurrentTime);
  fakeKey(display, code, False, CurrentTime);
}
static gboolean finishSubmenu(gpointer unused)
{
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  key(display, XK_Home); key(display, XK_Return); XFlush(display);
  return G_SOURCE_REMOVE;
}
static gboolean input(gpointer unused)
{
  GListModel *windows = gtk_window_get_toplevels();
  GtkWidget *window = NULL, *popup = NULL;
  for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
    GtkWidget *candidate = g_list_model_get_item(windows, i);
    GtkWidget *child = gtk_window_get_child(GTK_WINDOW(candidate));
    GtkWidget *first = child ? gtk_widget_get_first_child(child) : NULL;
    if (first && GTK_IS_POPOVER_MENU(first)) { window = candidate; popup = first; break; }
    g_object_unref(candidate);
  }
  g_assert_nonnull(window);
  g_assert_true(GTK_IS_POPOVER_MENU(popup));
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(popup));
  g_assert_true(gdk_surface_get_mapped(surface));
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  if (!cancelMenu) {
    Window xid = gdk_x11_surface_get_xid(surface);
    XWindowAttributes attributes;
    XGetWindowAttributes(display, xid, &attributes);
    cairo_surface_t *pixels = cairo_xlib_surface_create(display, xid, attributes.visual,
      attributes.width, attributes.height);
    cairo_surface_write_to_png(pixels, "/tmp/gtk4-native-menu.png");
    cairo_surface_destroy(pixels);
  }
  // Production tracking must establish focus itself; the test must not
  // repair a broken popup before exercising its keyboard handling.
  if (pointerMenu) {
    int x, y; Window child;
    XTranslateCoordinates(display, gdk_x11_surface_get_xid(surface), DefaultRootWindow(display),
      0, 0, &x, &y, &child);
    fakeMotion(display, -1, x + 30, y + 20, CurrentTime);
    fakeButton(display, 1, True, CurrentTime);
    fakeButton(display, 1, False, CurrentTime);
  } else if (nestedMenu) {
    key(display, XK_Home); key(display, XK_Down); key(display, XK_Right);
    g_timeout_add(100, finishSubmenu, NULL);
  } else if (cancelMenu) key(display, XK_Escape);
  else { key(display, XK_Home); key(display, XK_Return); }
  XFlush(display);
  g_object_unref(window);
  return G_SOURCE_REMOVE;
}
static gboolean failTimeout(gpointer unused)
{
  g_error("Native menu failed to handle keyboard input");
  return G_SOURCE_REMOVE;
}
int main(void)
{
  @autoreleasepool {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"GSTheme":@"GTK4Native"}];
    [NSApplication sharedApplication];
    NSCAssert([NSStringFromClass([[GSTheme theme] class]) isEqualToString:@"GTK4NativeTheme"],
      @"test must exercise the installed native-menu theme");
    g_assert_true(gtk_init_check());
    xtst = dlopen("libXtst.so.6", RTLD_NOW);
    g_assert_nonnull(xtst);
    fakeKey = dlsym(xtst, "XTestFakeKeyEvent");
    g_assert_nonnull(fakeKey);
    fakeButton = dlsym(xtst, "XTestFakeButtonEvent");
    fakeMotion = dlsym(xtst, "XTestFakeMotionEvent");
    g_assert_nonnull(fakeButton); g_assert_nonnull(fakeMotion);
    NSWindow *owner = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,400,300)
      styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [owner setReleasedWhenClosed:NO];
    [owner makeKeyAndOrderFront:nil];
    MenuTarget *target = [MenuTarget new];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Native GTK menu"];
    [menu setAutoenablesItems:NO];
    NSMenuItem *item = [menu addItemWithTitle:@"Choose" action:@selector(choose:) keyEquivalent:@""];
    [item setTarget:target];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *disabled = [menu addItemWithTitle:@"Disabled" action:@selector(choose:) keyEquivalent:@""];
    [disabled setTarget:target]; [disabled setEnabled:NO];
    NSMenu *more = [[NSMenu alloc] initWithTitle:@"More"];
    [more setAutoenablesItems:NO];
    id nested = [more addItemWithTitle:@"Nested action" action:@selector(choose:) keyEquivalent:@""];
    [nested setTarget:target];
    NSMenuItem *moreItem = [[NSMenuItem alloc] initWithTitle:@"More" action:NULL keyEquivalent:@""];
    [moreItem setSubmenu:more]; [menu addItem:moreItem]; [moreItem release]; [more release];
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@"Bar"];
    NSMenuItem *file = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    [file setSubmenu:menu]; [bar addItem:file]; [file release];
    NSMenuView *view = [[NSMenuView alloc] initWithFrame:NSMakeRect(0,250,400,30)];
    [view setMenu:bar]; [view setHorizontal:YES];
    [[owner contentView] addSubview:view]; [view sizeToFit];
    NSRect first = [view rectOfItemAtIndex:0];
    NSPoint location = [view convertPoint:NSMakePoint(NSMidX(first), NSMidY(first)) toView:nil];
    NSEvent *click = [NSEvent mouseEventWithType:NSLeftMouseDown location:location modifierFlags:0
      timestamp:0 windowNumber:[owner windowNumber] context:nil eventNumber:0 clickCount:1 pressure:1];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *savedArguments = [[defaults volatileDomainForName:NSArgumentDomain] copy];
    NSMutableDictionary *arguments = [NSMutableDictionary dictionaryWithDictionary:savedArguments];
    [arguments setObject:@"Control_L" forKey:@"GSFirstCommandKey"];
    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
    NSCAssert(![[GSTheme theme] displayNativePopUpMenu:menu atScreenRect:NSZeroRect forWindow:owner],
      @"custom physical modifiers must retain AppKit tracking");
    [defaults setVolatileDomain:savedArguments forName:NSArgumentDomain];
    [savedArguments release];
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.02 target:target selector:@selector(timer:)
      userInfo:nil repeats:NO];
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode];
    guint timeout = g_timeout_add(3000, failTimeout, NULL);
    g_timeout_add(150, input, NULL);
    NSCAssert([view trackWithEvent:click], @"native popup is handled");
    g_source_remove(timeout);
    NSCAssert(activations == 1, @"native keyboard selection dispatches exactly once");
    NSCAssert(dispatchedAfterClose, @"action runs after GTK releases its windows and grab");
    NSCAssert(appKitTimerFired, @"AppKit timers continue during native tracking");
    cancelMenu = YES;
    timeout = g_timeout_add(3000, failTimeout, NULL);
    g_timeout_add(150, input, NULL);
    NSCAssert([view trackWithEvent:click], @"cancel is handled");
    g_source_remove(timeout);
    NSCAssert(activations == 1, @"Escape closes without dispatching an action");
    pointerMenu = YES;
    timeout = g_timeout_add(3000, failTimeout, NULL);
    g_timeout_add(150, input, NULL);
    NSCAssert([view trackWithEvent:click], @"pointer tracking is handled");
    g_source_remove(timeout);
    NSCAssert(activations == 2, @"native pointer click dispatches exactly once");
    timeout = g_timeout_add(3000, failTimeout, NULL);
    g_timeout_add(150, input, NULL);
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(40,100) inView:[owner contentView]];
    g_source_remove(timeout);
    NSCAssert(activations == 3, @"explicitly positioned menus also use native tracking");
    pointerMenu = NO; cancelMenu = NO; nestedMenu = YES;
    timeout = g_timeout_add(3000, failTimeout, NULL);
    g_timeout_add(150, input, NULL);
    NSCAssert([view trackWithEvent:click], @"nested menu tracking is handled");
    g_source_remove(timeout);
    NSCAssert(activations == 4, @"keyboard navigation opens a submenu and dispatches its action");
    NSLog(@"Native GTK menu passed: mapped popup, keyboard activation, cancellation, timer integration, cleanup");
    [view removeFromSuperview]; [view release]; [bar release];
    [menu release]; [target release]; [owner orderOut:nil]; [owner release];
    dlclose(xtst);
  }
  return 0;
}
