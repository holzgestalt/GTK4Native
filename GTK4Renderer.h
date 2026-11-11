#ifndef GTK4_RENDERER_H
#define GTK4_RENDERER_H
#include <gtk/gtk.h>
/* All calls belong to the AppKit/GTK main thread. The native host surface never gets mapped. */
typedef struct {
  GtkWidget *window;
  GtkWidget *button;
  GtkWidget *entry;
} GTK4Renderer;
gboolean gtk4_renderer_init(GTK4Renderer *renderer);
gboolean gtk4_renderer_color(GTK4Renderer *renderer, const char *name, GdkRGBA *color);
void gtk4_renderer_entry_insets(GTK4Renderer *renderer, GtkBorder *insets);
void gtk4_renderer_clear(GTK4Renderer *renderer);
cairo_surface_t *gtk4_renderer_draw(GtkWidget *widget, GtkStateFlags state,
                                   int width, int height, int scale);
#endif
