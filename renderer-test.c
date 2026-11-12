#include "GTK4Renderer.h"
#include <stdint.h>
#include <string.h>

static uint64_t fingerprint(cairo_surface_t *s)
{
  g_assert_nonnull(s);
  g_assert_cmpint(cairo_surface_status(s), ==, CAIRO_STATUS_SUCCESS);
  unsigned char *data = cairo_image_surface_get_data(s);
  int size = cairo_image_surface_get_stride(s) * cairo_image_surface_get_height(s);
  uint64_t hash = 1469598103934665603ULL;
  gboolean visible = FALSE;
  for (int i = 0; i < size; i++) {
    hash = (hash ^ data[i]) * 1099511628211ULL;
    visible |= data[i] != 0;
  }
  g_assert_true(visible);
  return hash;
}

int main(void)
{
  GTK4Renderer r = {0};
  g_assert_true(gtk4_renderer_init(&r));
  g_object_set(gtk_settings_get_default(), "gtk-enable-animations", FALSE, NULL);
  cairo_surface_t *normal = gtk4_renderer_draw(r.button, 0, 146, 36, 1);
  cairo_surface_t *pressed = gtk4_renderer_draw(r.button, GTK_STATE_FLAG_ACTIVE, 146, 36, 1);
  cairo_surface_t *disabled = gtk4_renderer_draw(r.button, GTK_STATE_FLAG_INSENSITIVE, 146, 36, 1);
  cairo_surface_t *plainEntry = gtk4_renderer_draw(r.entry, GTK_STATE_FLAG_NORMAL, 424, 32, 2);
  cairo_surface_t *entry = gtk4_renderer_draw(r.entry, GTK_STATE_FLAG_FOCUSED |
    GTK_STATE_FLAG_FOCUS_WITHIN | GTK_STATE_FLAG_FOCUS_VISIBLE, 424, 32, 2);
  cairo_surface_t *menu = gtk4_renderer_draw(r.menu, GTK_STATE_FLAG_NORMAL, 240, 140, 1);
  cairo_surface_t *menuItem = gtk4_renderer_draw(r.menu_item,
    GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_SELECTED, 220, 30, 1);
  cairo_surface_t *bar = gtk4_renderer_draw(r.menubar, GTK_STATE_FLAG_NORMAL, 300, 28, 2);
  cairo_surface_t *barItem = gtk4_renderer_draw(r.menubar_item,
    GTK_STATE_FLAG_PRELIGHT | GTK_STATE_FLAG_SELECTED, 80, 28, 1);
  cairo_surface_t *separator = gtk4_renderer_draw(r.menu_separator, GTK_STATE_FLAG_NORMAL, 220, 1, 1);
  fingerprint(menu); fingerprint(menuItem); fingerprint(bar); fingerprint(barItem); fingerprint(separator);
  g_assert_cmpint(gtk4_renderer_natural_height(r.menu_item), >, 0);
  GdkRGBA enabledText, disabledText;
  gtk4_renderer_foreground(r.menu_item, GTK_STATE_FLAG_NORMAL, &enabledText);
  gtk4_renderer_foreground(r.menu_item, GTK_STATE_FLAG_INSENSITIVE, &disabledText);
  g_assert_false(gdk_rgba_equal(&enabledText, &disabledText));
  g_assert_false(GTK_IS_NATIVE(gtk_widget_get_parent(r.menu)));
  GdkSurface *popupSurface = gtk_native_get_surface(GTK_NATIVE(r.menu_source));
  g_assert_null(popupSurface);
  GtkWidget *barPopover = gtk_widget_get_last_child(r.menubar_item);
  if (GTK_IS_NATIVE(barPopover)) {
    GdkSurface *barSurface = gtk_native_get_surface(GTK_NATIVE(barPopover));
    if (barSurface) g_assert_false(gdk_surface_get_mapped(barSurface));
  }
  cairo_surface_write_to_png(menu, "/tmp/gtk4-menu.png");
  cairo_surface_destroy(menu); cairo_surface_destroy(menuItem); cairo_surface_destroy(bar);
  cairo_surface_destroy(barItem); cairo_surface_destroy(separator);
  uint64_t a = fingerprint(normal), b = fingerprint(pressed), c = fingerprint(disabled);
  g_assert_true(a != b);
  g_assert_true(a != c);
  g_assert_true(fingerprint(entry) != fingerprint(plainEntry));
  g_assert_cmpint(cairo_image_surface_get_width(entry), ==, 848);
  g_assert_cmpint(cairo_image_surface_get_height(entry), ==, 64);
  g_assert_null(gtk4_renderer_draw(r.button, 0, 0, 36, 1));
  g_assert_false(gdk_surface_get_mapped(gtk_native_get_surface(GTK_NATIVE(r.window))));
  cairo_surface_write_to_png(normal, "/tmp/gtk4-button.png");
  cairo_surface_write_to_png(entry, "/tmp/gtk4-entry.png");
  g_print("GTK theme %s: normal=%" G_GUINT64_FORMAT ", pressed=%" G_GUINT64_FORMAT
          ", disabled=%" G_GUINT64_FORMAT "; entry at 2x; GTK host surface is not mapped\n",
          g_getenv("GTK_THEME"), a, b, c);
  cairo_surface_destroy(normal);
  cairo_surface_destroy(pressed);
  cairo_surface_destroy(disabled);
  cairo_surface_destroy(entry);
  cairo_surface_destroy(plainEntry);
  gtk4_renderer_clear(&r);
  return 0;
}
