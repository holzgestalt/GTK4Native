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

void gtk4_renderer_clear(GTK4Renderer *r)
{
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
