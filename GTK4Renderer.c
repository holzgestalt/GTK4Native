#include "GTK4Renderer.h"

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
