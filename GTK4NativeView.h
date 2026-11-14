#import <AppKit/AppKit.h>
#include <gtk/gtk.h>
#import <GNUstepGUI/GSNativeView.h>

/* Platform-specific custom views may supply a new, unparented GTK widget.
   Their ordinary Objective-C view remains the model/action sender. */
@protocol GTK4NativeCustomView
- (GtkWidget *)gtk4NativeWidget;
@end

@interface GTK4NativeView : NSObject <GSNativeViewPeer>
{
  NSView *_view;
  GtkWidget *_widget;
  NSMapTable *_widgets;
  BOOL _synchronizing;
  CGFloat _scale;
  BOOL _invalidated;
  BOOL _reflecting;
}
+ (BOOL)supportsView:(NSView *)view;
- (id)initWithView:(NSView *)view scale:(CGFloat)scale;
- (GtkWidget *)widget;
- (NSView *)view;
- (GtkWidget *)widgetForView:(NSView *)view;
- (void)synchronize;
- (void)invalidate;
- (NSRect)configurationFrameForView:(NSView *)view;
@end
