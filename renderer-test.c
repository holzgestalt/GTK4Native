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
