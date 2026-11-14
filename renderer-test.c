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
  int thickness = gtk4_renderer_scrollbar_width(&r);
  g_assert_cmpint(thickness, >, 0);
  if (gtk_widget_has_css_class(r.scrollbars[1], "overlay-indicator")) {
    GtkWidget *regular = gtk_scrollbar_new(GTK_ORIENTATION_VERTICAL, NULL);
    g_object_ref_sink(regular);
    int minimum, natural;
    gtk_widget_measure(regular,GTK_ORIENTATION_HORIZONTAL,-1,&minimum,&natural,NULL,NULL);
    g_assert_cmpint(thickness, <, MAX(minimum,natural));
    g_object_unref(regular);
  }
  for (int axis = 0; axis < 2; axis++) {
    gboolean horizontal = axis == 0;
    int width = horizontal ? 240 : thickness;
    int height = horizontal ? thickness : 240;
    GTK4ScrollbarGeometry first, last, small, large;
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, 0, .25, TRUE, FALSE,
      width, height, &first));
    cairo_surface_t *firstImage = gtk4_renderer_draw(r.scrollbars[axis], 0, width, height, 1);
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, 1, .25, TRUE, FALSE,
      width, height, &last));
    if (gtk_widget_has_css_class(r.scrollbars[axis], "overlay-indicator")) {
      cairo_surface_flush(firstImage);
      int x = horizontal ? 210 : width/2, y = horizontal ? height/2 : 210;
      unsigned char *pixel = cairo_image_surface_get_data(firstImage) + y*cairo_image_surface_get_stride(firstImage) + x*4;
      uint32_t color; memcpy(&color,pixel,4);
      g_assert_cmpuint(color >> 24, ==, 0); // no opaque track away from the thumb
    }
    cairo_surface_t *lastImage = gtk4_renderer_draw(r.scrollbars[axis], 0, width, height, 1);
    g_assert_true(fingerprint(firstImage) != fingerprint(lastImage));
    float firstPosition = horizontal ? first.thumb.origin.x : first.thumb.origin.y;
    float lastPosition = horizontal ? last.thumb.origin.x : last.thumb.origin.y;
    g_assert_cmpfloat(lastPosition, >, firstPosition);
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, .5, .001, TRUE, FALSE,
      width, height, &small));
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, .5, .8, TRUE, FALSE,
      width, height, &large));
    float smallLength = horizontal ? small.thumb.size.width : small.thumb.size.height;
    float largeLength = horizontal ? large.thumb.size.width : large.thumb.size.height;
    g_assert_cmpfloat(smallLength, >, 0);
    g_assert_cmpfloat(largeLength, >, smallLength);
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, .5, .25, TRUE, FALSE,
      width, height, &small));
    cairo_surface_t *resting = gtk4_renderer_draw(r.scrollbars[axis], 0, width, height, 1);
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, .5, .25, TRUE, TRUE,
      width, height, &small));
    cairo_surface_t *dragging = gtk4_renderer_draw(r.scrollbars[axis],
      GTK_STATE_FLAG_ACTIVE | GTK_STATE_FLAG_PRELIGHT, width, height, 1);
    // GTK's thin indicator CSS uses a constant color until its scrolled
    // window adds hovering/dragging classes; state flags alone need not differ.
    uint64_t draggingHash = fingerprint(dragging);
    if (!gtk_widget_has_css_class(r.scrollbars[axis], "overlay-indicator"))
      g_assert_true(fingerprint(resting) != draggingHash);
    uint64_t restingHash = fingerprint(resting);
    cairo_surface_destroy(resting); cairo_surface_destroy(dragging);
    cairo_surface_t *scaled = gtk4_renderer_draw(r.scrollbars[axis], 0, width, height, 2);
    g_assert_cmpint(cairo_image_surface_get_width(scaled), ==, width * 2);
    g_assert_cmpint(cairo_image_surface_get_height(scaled), ==, height * 2);
    g_assert_true(gtk4_renderer_scrollbar_prepare(&r, horizontal, .5, .25, FALSE, FALSE,
      width, height, &small));
    cairo_surface_t *disabledBar = gtk4_renderer_draw(r.scrollbars[axis], GTK_STATE_FLAG_INSENSITIVE,
      width, height, 1);
    uint64_t disabledHash = fingerprint(disabledBar);
    if (!gtk_widget_has_css_class(r.scrollbars[axis], "overlay-indicator"))
      g_assert_true(disabledHash != restingHash);
    g_assert_false(gtk_widget_is_sensitive(r.scrollbars[axis]));
    g_assert_false(gtk4_renderer_scrollbar_prepare(&r, horizontal, 0, .25, TRUE, FALSE,
      0, height, &small));
    cairo_surface_write_to_png(lastImage, horizontal ? "/tmp/gtk4-scrollbar-horizontal.png"
                                                   : "/tmp/gtk4-scrollbar-vertical.png");
    cairo_surface_destroy(firstImage); cairo_surface_destroy(lastImage);
    cairo_surface_destroy(scaled); cairo_surface_destroy(disabledBar);
  }
  g_assert_false(gdk_surface_get_mapped(gtk_native_get_surface(GTK_NATIVE(r.window))));
  g_print("Native GTK scrollbar rendering, geometry, proportions, disabled state and 2x scaling passed\n");
  gtk4_renderer_clear(&r);
  return 0;
}
