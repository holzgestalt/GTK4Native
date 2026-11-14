#ifndef GTK4_NATIVE_CLIP_H
#define GTK4_NATIVE_CLIP_H
#include <gtk/gtk.h>

/* A clip has no child-driven minimum. Allocation describes the full child
   relative to the visible viewport, including a negative offset when clipped. */
GtkWidget *GTK4NativeClipNew(GtkWidget *child);
/* A row viewport fills its allocation without measuring/changing its child. */
GtkWidget *GTK4NativeClipNewFilling(GtkWidget *child);
void GTK4NativeClipSetChild(GtkWidget *clip, GtkWidget *child);
void GTK4NativeClipSetAllocation(GtkWidget *clip, GtkAllocation allocation);
#endif
