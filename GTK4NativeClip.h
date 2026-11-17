#ifndef GTK4_NATIVE_CLIP_H
#define GTK4_NATIVE_CLIP_H
#include <gtk/gtk.h>
void GTK4NativeDetachWidget(GtkWidget *widget);

/* A clip has no child-driven minimum. Allocation describes the full child
   relative to the visible viewport, including a negative offset when clipped. */
GtkWidget *GTK4NativeClipNew(GtkWidget *child);
/* A row viewport fills its allocation without measuring/changing its child. */
GtkWidget *GTK4NativeClipNewFilling(GtkWidget *child);
/* A window scene fills its allocation and propagates the child's minimum.
   Its natural size must not preserve a previous window allocation. */
GtkWidget *GTK4NativeClipNewScene(GtkWidget *child);
void GTK4NativeClipSetChild(GtkWidget *clip, GtkWidget *child);
/* Backdrop for transparent controls exposed through an AppKit surface hole. */
void GTK4NativeClipSetBackground(GtkWidget *clip, const GdkRGBA *color);
void GTK4NativeClipSetAllocation(GtkWidget *clip, GtkAllocation allocation);
/* Commit explicit AppKit geometry before publishing its native surface hole. */
void GTK4NativeClipPlace(GtkWidget *clip, GtkWidget *fixed, GtkAllocation allocation);
#endif
