#import <GNUstepGUI/GSWindowDecorationView.h>
#include <gtk/gtk.h>

BOOL GTK4NativeWindowsAvailable(void);
GtkWindow *GTK4NativeHostForWindow(NSWindow *window);
void GTK4NativeRoundWindowCorners(GtkWidget *widget, gpointer unused);
double GTK4NativeWindowCornerRadius(GtkWidget *widget);

@interface GTK4NativeWindowDecorationView : GSWindowDecorationView
{
@public
  GtkWidget *_host;
  GtkWidget *_header;
  GtkWidget *_nativeToolbar;
  GtkWidget *_nativeToolbarItems;
  GtkWidget *_toolbarOverflow;
  NSArray *_toolbarSignature;
  CGFloat _toolbarExtraHeight;
  BOOL _updatingToolbar;
  gint64 _toolbarValidationTime;
  NSTimer *_hostTimer;
  unsigned long _child;
  unsigned long _parent;
  NSRect _lastGeometry;
  BOOL _placing;
  BOOL _wantedVisible;
  BOOL _wasMinimized;
  BOOL _sawNativeNormal;
  NSInteger _nativeLevel;
  NSSize _nativeMinSize;
  NSSize _nativeMaxSize;
  double _shapeRadius;
  int _shapeTitleHeight;
}
- (void)synchronizeNativeWindow:(id)sender;
@end
