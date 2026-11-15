#import "GTK4NativeMenu.h"
#import "GTK4NativeWindow.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include <gtk/gtk.h>
#include <math.h>
#include <gdk/x11/gdkx.h>
#include <X11/extensions/shape.h>

static Window menuOwnerWindow(NSWindow *owner)
{
  GtkWindow *host=GTK4NativeHostForWindow(owner);
  GdkSurface *surface=host ? gtk_native_get_surface(GTK_NATIVE(host)) : NULL;
  return surface ? gdk_x11_surface_get_xid(surface)
    : (Window)[GSServerForWindow(owner) windowDevice:owner.windowNumber];
}

@interface GTK4MenuSession : NSObject
{
@public
  GtkWidget *anchor;
  GtkWidget *popover;
  GSimpleActionGroup *actions;
  NSMutableArray *items;
  NSDictionary *selection;
  BOOL closed;
  BOOL keyboardDismissal;
  BOOL closedByKeyboard;
  guint submenuCount;
}
- (GMenu *)modelForMenu:(NSMenu *)menu;
@end

static void nativeMenuClosed(GtkPopover *popover, gpointer data)
{
  if (g_getenv("GTK4_MENU_DEBUG")) NSLog(@"GTK native closed: %p", data);
  GTK4MenuSession *session = data;
  session->closedByKeyboard = session->keyboardDismissal;
  session->closed = YES;
}
static void nativeMenuActivated(GSimpleAction *action, GVariant *parameter, gpointer data)
{
  GTK4MenuSession *session = data;
  // GTK may emit closed before activating the chosen action.
  if (session->selection) return;
  NSUInteger index = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(action), "menu-index"));
  session->selection = [[session->items objectAtIndex:index] retain];
  gtk_popover_popdown(GTK_POPOVER(session->popover));
  session->closed = YES;
}
static gboolean nativeMenuKeyPressed(GtkEventControllerKey *controller, guint keyval,
                                    guint keycode, GdkModifierType state, gpointer data)
{
  ((GTK4MenuSession *)data)->keyboardDismissal = keyval == GDK_KEY_Escape;
  return FALSE;
}
static void nativeMenuKeyReleased(GtkEventControllerKey *controller, guint keyval,
                                 guint keycode, GdkModifierType state, gpointer data)
{
  if (keyval == GDK_KEY_Escape) ((GTK4MenuSession *)data)->keyboardDismissal = NO;
}
static void nativeSubmenuState(GSimpleAction *action, GVariant *value, gpointer data)
{
  g_simple_action_set_state(action, value);
}
static gboolean nativeMenuShortcut(GtkWidget *widget, GVariant *arguments, gpointer data)
{
  GAction *action = data;
  if (!g_action_get_enabled(action)) return FALSE;
  g_action_activate(action, NULL);
  return TRUE;
}

@implementation GTK4MenuSession
- (id)init
{
  self = [super init];
  if (self) {
    items = [NSMutableArray new];
    actions = g_simple_action_group_new();
  }
  return self;
}
- (void)dealloc
{
  [selection release];
  [items release];
  g_object_unref(actions);
  [super dealloc];
}
- (GMenu *)modelForMenu:(NSMenu *)menu
{
  [menu update];
  GMenu *model = g_menu_new();
  GMenu *section = g_menu_new();
  for (NSMenuItem *item in [menu itemArray]) {
    if ([item respondsToSelector:@selector(isHidden)] && [(id)item isHidden]) continue;
    if ([item isSeparatorItem]) {
      if (g_menu_model_get_n_items(G_MENU_MODEL(section))) {
        g_menu_append_section(model, NULL, G_MENU_MODEL(section));
        g_object_unref(section);
        section = g_menu_new();
      }
      continue;
    }
    // GMenu labels use '_' as a mnemonic marker; preserve literal underscores.
    NSString *label = [[item title] stringByReplacingOccurrencesOfString:@"_" withString:@"__"];
    GMenuItem *nativeItem;
    if ([item hasSubmenu]) {
      GMenu *submenu = [self modelForMenu:[item submenu]];
      nativeItem = g_menu_item_new_submenu([label UTF8String], G_MENU_MODEL(submenu));
      g_object_unref(submenu);
      NSString *name = [NSString stringWithFormat:@"submenu%u", submenuCount++];
      NSString *detailed = [@"native." stringByAppendingString:name];
      GSimpleAction *openAction = g_simple_action_new_stateful([name UTF8String], NULL,
        g_variant_new_boolean(FALSE));
      g_simple_action_set_enabled(openAction, [item isEnabled]);
      g_signal_connect(openAction, "change-state", G_CALLBACK(nativeSubmenuState), NULL);
      g_action_map_add_action(G_ACTION_MAP(actions), G_ACTION(openAction));
      g_menu_item_set_attribute(nativeItem, "submenu-action", "s", [detailed UTF8String]);
      g_object_unref(openAction);
    } else {
      NSUInteger index = [items count];
      NSString *name = [NSString stringWithFormat:@"item%lu", (unsigned long)index];
      NSString *detailed = [@"native." stringByAppendingString:name];
      [items addObject:@{@"menu":menu, @"item":item}];
      GSimpleAction *action = [item state] == NSOnState ?
        g_simple_action_new_stateful([name UTF8String], NULL, g_variant_new_boolean(TRUE)) :
        g_simple_action_new([name UTF8String], NULL);
      g_simple_action_set_enabled(action, [item isEnabled]);
      g_object_set_data(G_OBJECT(action), "menu-index", GUINT_TO_POINTER((guint)index));
      g_signal_connect(action, "activate", G_CALLBACK(nativeMenuActivated), self);
      g_action_map_add_action(G_ACTION_MAP(actions), G_ACTION(action));
      nativeItem = g_menu_item_new([label UTF8String], [detailed UTF8String]);
      NSString *key = [item keyEquivalent];
      if ([key length]) {
        NSUInteger mask = [item keyEquivalentModifierMask];
        GdkModifierType modifiers = 0;
        if (mask & NSCommandKeyMask) modifiers |= GDK_ALT_MASK;
        if (mask & NSAlternateKeyMask) modifiers |= GDK_ALT_MASK;
        if (mask & NSControlKeyMask) modifiers |= GDK_CONTROL_MASK;
        if (mask & NSShiftKeyMask) modifiers |= GDK_SHIFT_MASK;
        gunichar keyval = g_utf8_get_char([key UTF8String]);
        GtkShortcutController *controller = GTK_SHORTCUT_CONTROLLER(gtk_shortcut_controller_new());
        gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(controller), GTK_PHASE_CAPTURE);
        GtkShortcut *shortcut = gtk_shortcut_new(
          gtk_keyval_trigger_new(gdk_unicode_to_keyval(keyval), modifiers),
          gtk_callback_action_new(nativeMenuShortcut, g_object_ref(action), g_object_unref));
        gtk_shortcut_controller_add_shortcut(controller, shortcut);
        gtk_widget_add_controller(popover, GTK_EVENT_CONTROLLER(controller));
        char *accel = gtk_accelerator_name(gdk_unicode_to_keyval(keyval), modifiers);
        g_menu_item_set_attribute(nativeItem, "accel", "s", accel);
        g_free(accel);
      }
      g_object_unref(action);
    }
    g_menu_append_item(section, nativeItem);
    g_object_unref(nativeItem);
  }
  if (g_menu_model_get_n_items(G_MENU_MODEL(section)))
    g_menu_append_section(model, NULL, G_MENU_MODEL(section));
  g_object_unref(section);
  return model;
}
@end

static BOOL nativeKeyMappingsSupported(void)
{
  // The GTK accelerator bridge currently implements the XGServer defaults.
  // Keep AppKit's own event conversion for customized physical modifiers.
  NSDictionary *supported = @{@"GSFirstCommandKey":@"Alt_L",
    @"GSSecondCommandKey":@"NoSymbol", @"GSFirstAlternateKey":@"Alt_R",
    @"GSSecondAlternateKey":@"NoSymbol", @"GSFirstControlKey":@"Control_L",
    @"GSSecondControlKey":@"Control_R"};
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  for (NSString *key in supported) {
    NSString *configured = [defaults stringForKey:key];
    if (configured && ![configured isEqualToString:[supported objectForKey:key]]) return NO;
  }
  return YES;
}

static BOOL GTK4RunNativeMenu(NSMenu *menu, NSRect rect, NSWindow *owner, BOOL *maySwitch)
{
  if (maySwitch) *maySwitch = NO;
  GdkDisplay *display = gdk_display_get_default();
  if (!display || !GDK_IS_X11_DISPLAY(display) || !menu || !owner) return NO;
  if (!nativeKeyMappingsSupported()) return NO;
  GSDisplayServer *appServer = GSServerForWindow(owner);
  // windowDevice/serverDevice are backend-specific opaque handles. They are
  // XIDs/Display* only on XGServer (including its Cairo/Xlib subclasses).
  if (![appServer isKindOfClass:NSClassFromString(@"XGServer")]
      || ![appServer serverDevice] || ![appServer windowDevice:[owner windowNumber]])
    return NO;
  int shapeEvent, shapeError;
  if (!XShapeQueryExtension(gdk_x11_display_get_xdisplay(display), &shapeEvent, &shapeError))
    return NO;
  if ([[menu delegate] respondsToSelector:@selector(menuWillOpen:)])
    [[menu delegate] menuWillOpen:menu];
  GTK4MenuSession *session = [GTK4MenuSession new];
  session->anchor = gtk_window_new();
  g_object_ref_sink(session->anchor);
  gtk_window_set_decorated(GTK_WINDOW(session->anchor), FALSE);
  gtk_window_set_resizable(GTK_WINDOW(session->anchor), FALSE);
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_window_set_child(GTK_WINDOW(session->anchor), box);
  session->popover = gtk_popover_menu_new_from_model_full(NULL, GTK_POPOVER_MENU_NESTED);
  gtk_popover_set_has_arrow(GTK_POPOVER(session->popover), FALSE);
  gtk_widget_set_halign(session->popover, GTK_ALIGN_START);
  gtk_widget_set_parent(session->popover, box);
  gtk_popover_set_position(GTK_POPOVER(session->popover), GTK_POS_BOTTOM);
  GtkEventController *keys = gtk_event_controller_key_new();
  gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
  g_signal_connect(keys, "key-pressed", G_CALLBACK(nativeMenuKeyPressed), session);
  g_signal_connect(keys, "key-released", G_CALLBACK(nativeMenuKeyReleased), session);
  gtk_widget_add_controller(session->popover, keys);
  gtk_widget_insert_action_group(session->anchor, "native", G_ACTION_GROUP(session->actions));
  GMenu *model = [session modelForMenu:menu];
  gtk_popover_menu_set_menu_model(GTK_POPOVER_MENU(session->popover), G_MENU_MODEL(model));
  g_object_unref(model);
  g_signal_connect(session->popover, "closed", G_CALLBACK(nativeMenuClosed), session);
  gtk_widget_realize(session->anchor);
  GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(session->anchor));
  // AppKit screen/base coordinates are X11 pixels; GTK sizes are logical.
  int gtkScale=MAX(1,gdk_surface_get_scale_factor(surface));
  int anchorWidth=MAX(1,(int)ceil(rect.size.width/gtkScale));
  gtk_window_set_default_size(GTK_WINDOW(session->anchor), anchorWidth, 1);
  Display *xdisplay = gdk_x11_display_get_xdisplay(display);
  Window xid = gdk_x11_surface_get_xid(surface);
  Window ownerXid = menuOwnerWindow(owner);
  XSetTransientForHint(xdisplay, xid, ownerXid);
  // A menu click can arrive before the WM's focus-in notification. Focus the
  // owning application client, never the disposable GTK anchor.
  XWindowAttributes ownerAttributes;
  if(XGetWindowAttributes(xdisplay,ownerXid,&ownerAttributes) && ownerAttributes.map_state==IsViewable)
    XSetInputFocus(xdisplay, ownerXid, RevertToParent, CurrentTime);
  XSync(xdisplay, False);
  // This is an input/positioning anchor, not an application toplevel. Do not
  // let a WM relocate it or let compositor opacity propagate to the popup.
  XSetWindowAttributes settings;
  settings.override_redirect = True;
  XChangeWindowAttributes(xdisplay, xid, CWOverrideRedirect, &settings);
  XShapeCombineRectangles(xdisplay, xid, ShapeBounding, 0, 0, NULL, 0, ShapeSet, Unsorted);
  XWindowAttributes screen;
  XGetWindowAttributes(xdisplay,DefaultRootWindow(xdisplay),&screen);
  int x=lround(rect.origin.x);
  int y=lround(screen.height-rect.origin.y);
  // Map without asking the window manager to activate this helper. The
  // application's window keeps X input focus throughout menu tracking.
  gtk_widget_set_visible(session->anchor, TRUE);
  // Mapping is asynchronous under a window manager. A popover cannot acquire
  // its grab until its parent's native surface really exists on screen.
  gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
  while (!gdk_surface_get_mapped(surface) && g_get_monotonic_time() < deadline) {
    while (g_main_context_iteration(NULL, FALSE)) {}
    [[NSRunLoop currentRunLoop] runMode:NSEventTrackingRunLoopMode
                            beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.008]];
  }
  if (!gdk_surface_get_mapped(surface)) {
    gtk_widget_unparent(session->popover);
    gtk_window_destroy(GTK_WINDOW(session->anchor));
    g_object_unref(session->anchor);
    [session release];
    return NO;
  }
  // GTK's initial map may rewrite toplevel hints; apply the foreign AppKit
  // parent after that map so the compositor can associate its popup grab.
  XSetTransientForHint(xdisplay, xid, ownerXid);
  XMoveWindow(xdisplay, xid, x, y);
  XSync(xdisplay, False);
  while (g_main_context_iteration(NULL, FALSE)) {}
  if (g_getenv("GTK4_MENU_DEBUG")) {
    Window transient = None; XGetTransientForHint(xdisplay,xid,&transient);
    NSLog(@"GTK native anchor: X11=(%d,%d) mapped=%d parent=0x%lx owner=0x%lx", x, y,
      gdk_surface_get_mapped(surface),(unsigned long)transient,(unsigned long)ownerXid);
  }
  GdkRectangle pointing = {0, 0, anchorWidth, 1};
  gtk_popover_set_pointing_to(GTK_POPOVER(session->popover), &pointing);
  // The opening press creates an implicit grab on AppKit's X connection.
  // GTK uses another connection and cannot acquire its popup grab until that
  // implicit grab is released. Flush that connection before presenting GTK.
  [appServer releasemouse];
  XSync((Display *)[appServer serverDevice], False);
  gtk_popover_popup(GTK_POPOVER(session->popover));
  // GtkPopover now owns its seat grab; do not layer an independent core-X
  // keyboard grab over GTK's input lifecycle.
  @try {
    while (!session->closed) {
      @autoreleasepool {
        while (g_main_context_iteration(NULL, FALSE)) {}
        [[NSRunLoop currentRunLoop] runMode:NSEventTrackingRunLoopMode
                                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.008]];
      }
    }
  } @finally {
    gtk_widget_unparent(session->popover);
    gtk_window_destroy(GTK_WINDOW(session->anchor));
    g_object_unref(session->anchor);
  }
  if ([[menu delegate] respondsToSelector:@selector(menuDidClose:)])
    [[menu delegate] menuDidClose:menu];
  // Close GTK's grab before a target opens a modal dialog or terminates.
  if (maySwitch) *maySwitch = session->selection == nil && !session->closedByKeyboard;
  NSMenu *selectedMenu = [session->selection objectForKey:@"menu"];
  NSMenuItem *selectedItem = [session->selection objectForKey:@"item"];
  NSInteger index = [selectedMenu indexOfItem:selectedItem];
  @try {
    if (selectedItem && index != NSNotFound && index >= 0 && index < [selectedMenu numberOfItems])
      [selectedMenu performActionForItemAtIndex:index];
  } @finally {
    [session release];
  }
  return YES;
}

BOOL GTK4ShowNativeMenu(NSMenu *menu, NSRect rect, NSWindow *owner)
{
  return GTK4RunNativeMenu(menu, rect, owner, NULL);
}

BOOL GTK4TrackNativeMenu(NSMenuView *view, NSEvent *event)
{
  NSMenu *menu = [view menu];
  if (g_getenv("GTK4_MENU_DEBUG")) NSLog(@"GTK native track: menu=%@ horizontal=%d eventWindow=%@ location=%@", [menu title], [view isHorizontal], [event window], NSStringFromPoint([event locationInWindow]));
  // NSPopUpButtonCell owns a separate attach/track/dismiss lifecycle. Keep its
  // existing path until that lifecycle also has a synchronous native hook.
  if ([menu _ownedByPopUp]) return NO;
  if ([view isHorizontal]) {
    NSWindow *owner = [view window];
    NSPoint point = [view convertPoint:[event locationInWindow] fromView:nil];
    NSInteger index = [view indexOfItemAtPoint:point];
    while (index >= 0 && index < [menu numberOfItems]) {
      NSMenuItem *item = [menu itemAtIndex:index];
      if (![item isEnabled] || ![item hasSubmenu]) return NO;
      if (g_getenv("GTK4_MENU_DEBUG")) NSLog(@"GTK native hit: %@ enabled=%d submenu=%d", [item title], [item isEnabled], [item hasSubmenu]);
      NSRect rect = [view convertRect:[view rectOfItemAtIndex:index] toView:nil];
      rect = [owner convertRectToScreen:rect];
      BOOL maySwitch = NO;
      if (!GTK4RunNativeMenu([item submenu], rect, owner, &maySwitch)) return NO;
      if (!maySwitch) return YES;
      // An outside press over another heading belongs to the same menu-bar
      // interaction. GTK has consumed that press, so do not depend on replay
      // through the other X connection to open the next submenu.
      Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
      Window ownerXid = menuOwnerWindow(owner);
      Window root, child; int rx, ry, wx, wy; unsigned int mask;
      if (!ownerXid || !XQueryPointer(display,ownerXid,&root,&child,&rx,&ry,&wx,&wy,&mask)) return YES;
      XWindowAttributes attributes;
      if (!XGetWindowAttributes(display,ownerXid,&attributes)) return YES;
      XWindowAttributes rootAttributes;
      if(!XGetWindowAttributes(display,root,&rootAttributes)) return YES;
      NSPoint base=[owner convertScreenToBase:NSMakePoint(rx,rootAttributes.height-ry)];
      point = [view convertPoint:base fromView:nil];
      if (!NSPointInRect(point,[view bounds])) return YES;
      NSInteger next = [view indexOfItemAtPoint:point];
      if (next < 0 || next == index || next >= [menu numberOfItems]) return YES;
      NSMenuItem *nextItem = [menu itemAtIndex:next];
      if (![nextItem isEnabled] || ![nextItem hasSubmenu]) return YES;
      index = next;
    }
    return NO;
  }
  NSPoint point = [[event window] convertBaseToScreen:[event locationInWindow]];
  return GTK4ShowNativeMenu(menu, NSMakeRect(point.x, point.y, 1, 1), [event window]);
}
