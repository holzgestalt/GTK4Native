#import "GTK4NativeView.h"
@class GTK4NativeWindowDecorationView;

/* Standalone control peers. Source views keep application state and actions;
   GTK owns rendering, input, focus and accessibility in exposed host regions. */
@interface GTK4NativeControls : NSObject
{
  GTK4NativeWindowDecorationView *_host; // owned by the host
  NSMutableDictionary *_peers;
  NSArray *_rects;
}
- (id)initWithHost:(GTK4NativeWindowDecorationView *)host;
- (NSArray *)update;
- (BOOL)containsPoint:(NSPoint)point;
- (BOOL)hasNativeWidgetForView:(NSView *)view;
- (GtkWidget *)widgetForView:(NSView *)view;
@end
