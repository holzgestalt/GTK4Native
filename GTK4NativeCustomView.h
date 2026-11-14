#import <AppKit/AppKit.h>
#include <gtk/gtk.h>
/* Custom AppKit drawing lives inside a GTK scene node. No child X window. */
BOOL GTK4NativeCanWrapView(NSView *view);
GtkWidget *GTK4NativeCustomViewNew(NSView *view, CGFloat scale);
BOOL GTK4NativeIsCustomView(GtkWidget *widget);
void GTK4NativeCustomViewInvalidate(GtkWidget *widget, NSRect rect);
