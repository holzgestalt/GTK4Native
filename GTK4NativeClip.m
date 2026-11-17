#import "GTK4NativeClip.h"
#include <math.h>
#include <string.h>

// Fixed-size clipping container: GTK's child natural size must not enlarge an
// AppKit viewport or expose the portion scrolled outside it.
typedef struct {
  GtkWidget parent;
  GtkWidget *child;
  GtkAllocation allocation;
  gboolean fill;
  gboolean measureMinimum;
  gboolean hasBackground;
  GdkRGBA background;
} GTK4Clip;
typedef struct { GtkWidgetClass parent; } GTK4ClipClass;
G_DEFINE_TYPE(GTK4Clip, gtk4_native_clip, GTK_TYPE_WIDGET)
static void clipMeasure(GtkWidget *widget, GtkOrientation orientation, int forSize,
  int *minimum, int *natural, int *minimumBaseline, int *naturalBaseline)
{
  GTK4Clip *clip=(GTK4Clip *)widget;
  if(clip->measureMinimum && clip->child) {
    gtk_widget_measure(clip->child,orientation,forSize,minimum,NULL,minimumBaseline,NULL);
    *natural=*minimum;
    if(naturalBaseline) *naturalBaseline=minimumBaseline?*minimumBaseline:-1;
    return;
  }
  *minimum = *natural = 0;
  if (minimumBaseline) *minimumBaseline = -1;
  if (naturalBaseline) *naturalBaseline = -1;
}
static void clipAllocate(GtkWidget *widget, int width, int height, int baseline)
{
  GTK4Clip *clip = (GTK4Clip *)widget;
  if (clip->child) {
    GtkAllocation allocation = clip->allocation;
    if(clip->fill) {
      allocation=(GtkAllocation){0,0,width,height};
      gtk_widget_size_allocate(clip->child,&allocation,-1);
      return;
    }
    int minimumWidth = 0, minimumHeight = 0;
    gtk_widget_measure(clip->child, GTK_ORIENTATION_HORIZONTAL, -1, &minimumWidth, NULL, NULL, NULL);
    int width = MAX(allocation.width, minimumWidth);
    gtk_widget_measure(clip->child, GTK_ORIENTATION_VERTICAL, width, &minimumHeight, NULL, NULL, NULL);
    int height = MAX(allocation.height, minimumHeight);
    // Fixed AppKit frames can be smaller than GTK CSS padding. Allocate GTK
    // safely at its minimum, centered behind the source's clipped rectangle.
    allocation.x -= (width - allocation.width) / 2;
    allocation.y -= (height - allocation.height) / 2;
    allocation.width = width; allocation.height = height;
    gtk_widget_size_allocate(clip->child, &allocation, -1);
  }
}
static void clipSnapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
  GTK4Clip *clip = (GTK4Clip *)widget;
  if(clip->hasBackground) {
    graphene_rect_t rect=GRAPHENE_RECT_INIT(0,0,gtk_widget_get_width(widget),gtk_widget_get_height(widget));
    gtk_snapshot_append_color(snapshot,&clip->background,&rect);
  }
  if (clip->child) gtk_widget_snapshot_child(widget, clip->child, snapshot);
}
static void clipDispose(GObject *object)
{
  GTK4Clip *clip = (GTK4Clip *)object;
  if (clip->child) { gtk_widget_unparent(clip->child); clip->child = NULL; }
  G_OBJECT_CLASS(gtk4_native_clip_parent_class)->dispose(object);
}
static void gtk4_native_clip_class_init(GTK4ClipClass *cls)
{
  G_OBJECT_CLASS(cls)->dispose = clipDispose;
  GTK_WIDGET_CLASS(cls)->measure = clipMeasure;
  GTK_WIDGET_CLASS(cls)->size_allocate = clipAllocate;
  GTK_WIDGET_CLASS(cls)->snapshot = clipSnapshot;
}
static void gtk4_native_clip_init(GTK4Clip *clip)
{
  gtk_widget_set_overflow(GTK_WIDGET(clip), GTK_OVERFLOW_HIDDEN);
}

GtkWidget *GTK4NativeClipNew(GtkWidget *child)
{
  GtkWidget *widget = g_object_new(gtk4_native_clip_get_type(), NULL);
  GTK4NativeClipSetChild(widget, child);
  return widget;
}
void GTK4NativeDetachWidget(GtkWidget *widget)
{
  GtkWidget *parent=gtk_widget_get_parent(widget);
  if (!parent) return;
  if (G_TYPE_CHECK_INSTANCE_TYPE(parent,gtk4_native_clip_get_type())) GTK4NativeClipSetChild(parent,NULL);
  else if (GTK_IS_PANED(parent)) {
    if (gtk_paned_get_start_child(GTK_PANED(parent))==widget) gtk_paned_set_start_child(GTK_PANED(parent),NULL);
    else gtk_paned_set_end_child(GTK_PANED(parent),NULL);
  } else if (GTK_IS_OVERLAY(parent)) {
    if(gtk_overlay_get_child(GTK_OVERLAY(parent))==widget) gtk_overlay_set_child(GTK_OVERLAY(parent),NULL);
    else gtk_overlay_remove_overlay(GTK_OVERLAY(parent),widget);
  } else if (GTK_IS_SCROLLED_WINDOW(parent)) gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(parent),NULL);
  else if (GTK_IS_VIEWPORT(parent)) gtk_viewport_set_child(GTK_VIEWPORT(parent),NULL);
  else if (GTK_IS_BOX(parent)) gtk_box_remove(GTK_BOX(parent),widget);
  else if (GTK_IS_FIXED(parent)) gtk_fixed_remove(GTK_FIXED(parent),widget);
  else gtk_widget_unparent(widget);
}
GtkWidget *GTK4NativeClipNewFilling(GtkWidget *child)
{
  GtkWidget *widget=GTK4NativeClipNew(child);
  ((GTK4Clip *)widget)->fill=TRUE;
  return widget;
}
GtkWidget *GTK4NativeClipNewScene(GtkWidget *child)
{
  GtkWidget *widget=GTK4NativeClipNewFilling(child);
  ((GTK4Clip *)widget)->measureMinimum=TRUE;
  return widget;
}
void GTK4NativeClipSetChild(GtkWidget *widget, GtkWidget *child)
{
  GTK4Clip *clip = (GTK4Clip *)widget;
  if (clip->child == child) return;
  GtkWidget *old = clip->child;
  clip->child = NULL;
  if (old) gtk_widget_unparent(old);
  clip->child = child;
  if (child) gtk_widget_set_parent(child, widget);
  gtk_widget_queue_allocate(widget);
}
void GTK4NativeClipSetAllocation(GtkWidget *widget, GtkAllocation allocation)
{
  GTK4Clip *clip = (GTK4Clip *)widget;
  if (memcmp(&clip->allocation, &allocation, sizeof(allocation))) {
    clip->allocation = allocation;
    gtk_widget_queue_allocate(widget);
  }
}

void GTK4NativeClipPlace(GtkWidget *widget,GtkWidget *fixed,GtkAllocation allocation)
{
  gtk_fixed_move(GTK_FIXED(fixed),widget,allocation.x,allocation.y);
  gtk_widget_set_size_request(widget,allocation.width,allocation.height);
  /* Size requests only schedule GTK's next layout phase. The AppKit child
   * cutout is updated now, so its native replacement needs the new allocation
   * now too. GtkFixed will retain the same geometry on its next frame. */
  if(gtk_widget_get_visible(widget)) gtk_widget_size_allocate(widget,&allocation,-1);
}

void GTK4NativeClipSetBackground(GtkWidget *widget,const GdkRGBA *color)
{
  GTK4Clip *clip=(GTK4Clip *)widget;
  if(clip->hasBackground==(color!=NULL) && (!color || gdk_rgba_equal(&clip->background,color))) return;
  clip->hasBackground=color!=NULL;
  if(color) clip->background=*color;
  gtk_widget_queue_draw(widget);
}
