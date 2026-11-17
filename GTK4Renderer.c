#include "GTK4Renderer.h"
#include <math.h>

/* An offscreen GtkWindow subclass keeps the widget tree renderable while
 * never presenting its GdkSurface. Use only public GTK subclassing APIs. */
typedef struct { GtkWindow parent; } GTK4SnapshotHost;
typedef struct { GtkWindowClass parent; } GTK4SnapshotHostClass;
G_DEFINE_TYPE(GTK4SnapshotHost, gtk4_snapshot_host, GTK_TYPE_WINDOW)
static void gtk4_snapshot_host_init(GTK4SnapshotHost *self) { (void)self; }
static void gtk4_snapshot_host_class_init(GTK4SnapshotHostClass *klass)
{
  GtkWidgetClass *widget = GTK_WIDGET_CLASS(klass);
  GtkWidgetClass *base = g_type_class_ref(GTK_TYPE_WIDGET);
  // GtkWindow's show/map implementations present a native surface. This host
  // uses the generic widget lifecycle to map only its in-memory widget tree.
  widget->show = base->show;
  widget->hide = base->hide;
  widget->map = base->map;
  widget->unmap = base->unmap;
  g_type_class_unref(base);
}
/* Host GTK's generated popover contents in an ordinary widget, keeping the
 * native popover/contents/menu CSS ancestry without a GdkPopup surface. The
 * contents are returned to their source before either widget is destroyed. */
typedef struct { GtkWidget parent; } GTK4SnapshotMenu;
typedef struct { GtkWidgetClass parent; } GTK4SnapshotMenuClass;
G_DEFINE_TYPE(GTK4SnapshotMenu, gtk4_snapshot_menu, GTK_TYPE_WIDGET)
static void gtk4_snapshot_menu_init(GTK4SnapshotMenu *self) { (void)self; }
static void gtk4_snapshot_menu_measure(GtkWidget *widget, GtkOrientation orientation,
  int for_size, int *minimum, int *natural, int *min_baseline, int *nat_baseline)
{
  gtk_widget_measure(gtk_widget_get_first_child(widget), orientation, for_size,
                    minimum, natural, min_baseline, nat_baseline);
}
static void gtk4_snapshot_menu_allocate(GtkWidget *widget, int width, int height, int baseline)
{
  gtk_widget_allocate(gtk_widget_get_first_child(widget), width, height, baseline, NULL);
}
static void gtk4_snapshot_menu_snapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
  gtk_widget_snapshot_child(widget, gtk_widget_get_first_child(widget), snapshot);
}
static void gtk4_snapshot_menu_class_init(GTK4SnapshotMenuClass *klass)
{
  GtkWidgetClass *widget = GTK_WIDGET_CLASS(klass);
  gtk_widget_class_set_css_name(widget, "popover");
  widget->snapshot = gtk4_snapshot_menu_snapshot;
  widget->measure = gtk4_snapshot_menu_measure;
  widget->size_allocate = gtk4_snapshot_menu_allocate;
}
static GtkWidget *find_css_node(GtkWidget *widget, const char *name)
{
  if (g_str_equal(gtk_widget_get_css_name(widget), name)) return widget;
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
       child = gtk_widget_get_next_sibling(child)) {
    GtkWidget *found = find_css_node(child, name);
    if (found) return found;
  }
  return NULL;
}
G_GNUC_BEGIN_IGNORE_DEPRECATIONS

gboolean gtk4_renderer_init(GTK4Renderer *r)
{
  if (!gtk_init_check()) return FALSE;
  // AppKit currently drives static snapshots without GTK's animation clock.
  // Disable GTK transitions in this process so state changes render immediately
  // instead of getting stuck at the first frame of an animation.
  g_object_set(gtk_settings_get_default(), "gtk-enable-animations", FALSE, NULL);
  r->window = g_object_new(gtk4_snapshot_host_get_type(), NULL);
  gtk_window_set_decorated(GTK_WINDOW(r->window), FALSE);
  g_object_ref_sink(r->window);
  GtkWidget *box = gtk_fixed_new();
  gtk_window_set_child(GTK_WINDOW(r->window), box);
  r->button = gtk_button_new();
  r->entry = gtk_entry_new();
  r->scroll_frame=gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(r->scroll_frame),GTK_POLICY_NEVER,GTK_POLICY_NEVER);
  gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(r->scroll_frame),TRUE);
  gtk_fixed_put(GTK_FIXED(box),r->scroll_frame,0,0);
  for(int i=0;i<2;i++) {
    r->paned[i]=gtk_paned_new(i==0?GTK_ORIENTATION_HORIZONTAL:GTK_ORIENTATION_VERTICAL);
    gtk_paned_set_start_child(GTK_PANED(r->paned[i]),gtk_box_new(GTK_ORIENTATION_VERTICAL,0));
    gtk_paned_set_end_child(GTK_PANED(r->paned[i]),gtk_box_new(GTK_ORIENTATION_VERTICAL,0));
    r->split_separator[i]=find_css_node(r->paned[i],"separator");
    gtk_fixed_put(GTK_FIXED(box),r->paned[i],0,0);
  }
  for (int i = 0; i < 2; i++) {
    r->scrollbars[i] = gtk_scrollbar_new(i == 0 ? GTK_ORIENTATION_HORIZONTAL
                                              : GTK_ORIENTATION_VERTICAL, NULL);
    gtk_widget_add_css_class(r->scrollbars[i], i == 0 ? "bottom" : "right");
    gboolean overlay = TRUE;
    g_object_get(gtk_settings_get_default(), "gtk-overlay-scrolling", &overlay, NULL);
    if (overlay) gtk_widget_add_css_class(r->scrollbars[i], "overlay-indicator");
    gtk_fixed_put(GTK_FIXED(box), r->scrollbars[i], 0, 0);
  }
  gtk_fixed_put(GTK_FIXED(box), r->button, 0, 0);
  gtk_fixed_put(GTK_FIXED(box), r->entry, 0, 0);
  GMenu *model = g_menu_new();
  g_menu_append(model, "", "snapshot.item");
  r->menu_source = gtk_popover_menu_new_from_model(G_MENU_MODEL(model));
  g_object_ref_sink(r->menu_source);
  r->menu = gtk_widget_get_first_child(r->menu_source);
  g_object_ref(r->menu);
  gtk_widget_unparent(r->menu);
  GtkWidget *menuHost = g_object_new(gtk4_snapshot_menu_get_type(), NULL);
  char **menuClasses = gtk_widget_get_css_classes(r->menu_source);
  gtk_widget_set_css_classes(menuHost, (const char **)menuClasses);
  g_strfreev(menuClasses);
  gtk_widget_set_parent(r->menu, menuHost);
  g_object_unref(r->menu);
  r->menu_item = find_css_node(r->menu, "modelbutton");
  gtk_fixed_put(GTK_FIXED(box), menuHost, 0, 0);
  GMenu *barModel = g_menu_new();
  g_menu_append_submenu(barModel, "", G_MENU_MODEL(model));
  r->menubar = gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(barModel));
  r->menubar_item = gtk_widget_get_first_child(r->menubar);
  gtk_fixed_put(GTK_FIXED(box), r->menubar, 0, 0);
  r->menu_separator = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
  gtk_fixed_put(GTK_FIXED(box), r->menu_separator, 0, 0);
  GSimpleActionGroup *actions = g_simple_action_group_new();
  GSimpleAction *action = g_simple_action_new("item", NULL);
  g_action_map_add_action(G_ACTION_MAP(actions), G_ACTION(action));
  gtk_widget_insert_action_group(r->window, "snapshot", G_ACTION_GROUP(actions));
  g_object_unref(action);
  g_object_unref(actions);
  g_object_unref(model);
  g_object_unref(barModel);
  gtk_widget_realize(r->window);
  gtk_widget_set_visible(r->window, TRUE);
  gtk_widget_map(r->window);
  gtk_widget_allocate(r->window, 2048, 2048, -1, NULL);
  for(int i=0;i<2;i++) gtk_widget_allocate(r->paned[i],128,128,-1,NULL);
  return TRUE;
}

int gtk4_renderer_scrollbar_width(GTK4Renderer *r)
{
  int result = 0;
  for (int i = 0; i < 2; i++) {
    int minimum, natural;
    gtk_widget_measure(r->scrollbars[i], i == 0 ? GTK_ORIENTATION_VERTICAL
                                               : GTK_ORIENTATION_HORIZONTAL,
                       -1, &minimum, &natural, NULL, NULL);
    result = MAX(result, MAX(minimum, natural));
  }
  return result;
}

gboolean gtk4_renderer_scrollbar_prepare(GTK4Renderer *r, gboolean horizontal,
  double value, double proportion, gboolean enabled, gboolean pressed,
  int width, int height, GTK4ScrollbarGeometry *geometry)
{
  if (width <= 0 || height <= 0 || !isfinite(value) || !isfinite(proportion))
    return FALSE;
  GtkWidget *bar = r->scrollbars[horizontal ? 0 : 1];
  /* Inspect GTK's public widget hierarchy, with a type check. Fall back if
   * GTK ever changes this implementation instead of relying on private APIs. */
  GtkWidget *range = gtk_widget_get_first_child(bar);
  if (!GTK_IS_RANGE(range)) return FALSE;
  proportion = CLAMP(proportion, 0.0, 1.0);
  GtkAdjustment *adjustment = gtk_scrollbar_get_adjustment(GTK_SCROLLBAR(bar));
  gtk_adjustment_configure(adjustment, CLAMP(value, 0.0, 1.0) * (1 - proportion),
    0, 1, proportion * 0.1, proportion * 0.9, proportion);
  gtk_widget_set_sensitive(bar, enabled && proportion < 1);
  GtkStateFlags flags = enabled && proportion < 1 ? GTK_STATE_FLAG_NORMAL
                                                 : GTK_STATE_FLAG_INSENSITIVE;
  if (pressed && enabled && proportion < 1)
    flags |= GTK_STATE_FLAG_ACTIVE | GTK_STATE_FLAG_PRELIGHT;
  gtk_widget_set_state_flags(bar, flags, TRUE);
  GtkWidget *slider = find_css_node(range, "slider");
  if (slider) gtk_widget_set_state_flags(slider,
    pressed ? GTK_STATE_FLAG_ACTIVE | GTK_STATE_FLAG_PRELIGHT : GTK_STATE_FLAG_NORMAL, TRUE);
  int minimum, natural;
  gtk_widget_measure(bar, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, NULL, NULL);
  if (width < minimum) return FALSE;
  gtk_widget_measure(bar, GTK_ORIENTATION_VERTICAL, width, &minimum, &natural, NULL, NULL);
  if (height < minimum) return FALSE;
  gtk_widget_allocate(bar, width, height, -1, NULL);
  graphene_rect_t rangeBounds;
  if (!gtk_widget_compute_bounds(range, bar, &rangeBounds)) return FALSE;
  GtkWidget *trough = find_css_node(range, "trough");
  if (!trough || !slider
      || !gtk_widget_compute_bounds(trough, bar, &geometry->trough)
      || !gtk_widget_compute_bounds(slider, bar, &geometry->thumb)) return FALSE;
  /* Use the range's full cross-axis hit area, not only the narrow painted
   * slider. GTK keeps that area draggable beside the visible thumb too. */
  if (horizontal) {
    geometry->thumb.origin.y = geometry->trough.origin.y = rangeBounds.origin.y;
    geometry->thumb.size.height = geometry->trough.size.height = rangeBounds.size.height;
  } else {
    geometry->thumb.origin.x = geometry->trough.origin.x = rangeBounds.origin.x;
    geometry->thumb.size.width = geometry->trough.size.width = rangeBounds.size.width;
  }
  /* CSS borders and pixel rounding may extend the slider one pixel past
   * its trough at the endpoint. Hit geometry covers the visible portion. */
  graphene_rect_t clipped;
  graphene_rect_intersection(&geometry->thumb, &geometry->trough, &clipped);
  geometry->thumb = clipped;
  return TRUE;
}

gboolean gtk4_renderer_color(GTK4Renderer *r, const char *name, GdkRGBA *color)
{
  return gtk_style_context_lookup_color(gtk_widget_get_style_context(r->window), name, color);
}

void gtk4_renderer_entry_insets(GTK4Renderer *r, GtkBorder *insets)
{
  GtkStyleContext *context = gtk_widget_get_style_context(r->entry);
  GtkBorder border, padding;
  gtk_style_context_get_border(context, &border);
  gtk_style_context_get_padding(context, &padding);
  *insets = (GtkBorder){border.left + padding.left, border.right + padding.right,
                        border.top + padding.top, border.bottom + padding.bottom};
}

int gtk4_renderer_natural_height(GtkWidget *widget)
{
  int minimum, natural;
  gtk_widget_measure(widget, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, NULL, NULL);
  return natural;
}
gboolean gtk4_renderer_foreground(GtkWidget *widget, GtkStateFlags state, GdkRGBA *color)
{
  if (!widget) return FALSE;
  gtk_widget_set_state_flags(widget, state, TRUE);
  gtk_widget_get_color(widget, color);
  return TRUE;
}

void gtk4_renderer_clear(GTK4Renderer *r)
{
  if (r->menu_source) {
    g_object_ref(r->menu);
    gtk_widget_unparent(r->menu);
    gtk_widget_set_parent(r->menu, r->menu_source);
    g_object_unref(r->menu);
    g_object_unref(r->menu_source);
  }
  if (r->window) {
    gtk_window_destroy(GTK_WINDOW(r->window));
    g_object_unref(r->window);
  }
  *r = (GTK4Renderer){0};
}

cairo_surface_t *gtk4_renderer_draw(GtkWidget *widget, GtkStateFlags state,
                                   int width, int height, int scale)
{
  if (width <= 0 || height <= 0 || scale < 1) return NULL;
  // Resolve the state while unmapped, so snapshots do not depend on a running
  // animation/frame clock. AppKit supplies its own interaction state.
  gtk_widget_unmap(widget);
  gtk_widget_set_state_flags(widget, state, TRUE);
  if (GTK_IS_SCROLLBAR(widget)) {
    GtkWidget *slider = find_css_node(widget, "slider");
    // Unmapping clears GTK gesture states. Apply AppKit's current interaction
    // state afterwards so the native slider CSS sees hover/active flags.
    if (slider) gtk_widget_set_state_flags(slider,
      state & (GTK_STATE_FLAG_ACTIVE | GTK_STATE_FLAG_PRELIGHT), TRUE);
  }
  int minimum, natural;
  gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1,
                     &minimum, &natural, NULL, NULL);
  gtk_widget_map(widget);
  gtk_widget_allocate(widget, width, height, -1, NULL);
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
                                                       width * scale, height * scale);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return NULL;
  }
  cairo_surface_set_device_scale(surface, scale, scale);
  cairo_t *cr = cairo_create(surface);
  GtkSnapshot *snapshot = gtk_snapshot_new();
  gtk_widget_snapshot_child(gtk_widget_get_parent(widget), widget, snapshot);
  GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
  if (!node) {
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return NULL;
  }
  gsk_render_node_draw(node, cr);
  gsk_render_node_unref(node);
  cairo_destroy(cr);
  cairo_surface_flush(surface);
  return surface;
}
G_GNUC_END_IGNORE_DEPRECATIONS
