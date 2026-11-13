#ifndef GTK4_RENDERER_H
#define GTK4_RENDERER_H
#include <gtk/gtk.h>
/* All calls belong to the AppKit/GTK main thread. The native host surface never gets mapped. */
typedef struct {
  GtkWidget *window;
  GtkWidget *button;
  GtkWidget *entry;
  GtkWidget *scrollbars[2];
  GtkWidget *menu;
  GtkWidget *menu_source;
  GtkWidget *menu_item;
  GtkWidget *menubar;
  GtkWidget *menubar_item;
  GtkWidget *menu_separator;
} GTK4Renderer;
/* A real GtkScrollbar supplies CSS, minimum thumb size and range geometry.
 * Index 0 is horizontal, 1 is vertical. All dimensions are GTK logical units. */
typedef struct {
  graphene_rect_t trough;
  graphene_rect_t thumb;
} GTK4ScrollbarGeometry;
int gtk4_renderer_scrollbar_width(GTK4Renderer *renderer);
gboolean gtk4_renderer_scrollbar_prepare(GTK4Renderer *renderer, gboolean horizontal,
  double value, double proportion, gboolean enabled, gboolean pressed,
  int width, int height, GTK4ScrollbarGeometry *geometry);
gboolean gtk4_renderer_init(GTK4Renderer *renderer);
gboolean gtk4_renderer_color(GTK4Renderer *renderer, const char *name, GdkRGBA *color);
void gtk4_renderer_entry_insets(GTK4Renderer *renderer, GtkBorder *insets);
int gtk4_renderer_natural_height(GtkWidget *widget);
gboolean gtk4_renderer_foreground(GtkWidget *widget, GtkStateFlags state, GdkRGBA *color);
void gtk4_renderer_clear(GTK4Renderer *renderer);
cairo_surface_t *gtk4_renderer_draw(GtkWidget *widget, GtkStateFlags state,
                                   int width, int height, int scale);
#endif
