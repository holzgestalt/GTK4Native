#import <AppKit/AppKit.h>
#include <gtk/gtk.h>
#import <GNUstepGUI/GSNativeView.h>

/* Platform-specific custom views may supply a new, unparented GTK widget.
   Their ordinary Objective-C view remains the model/action sender. */
@protocol GTK4NativeCustomView
- (GtkWidget *)gtk4NativeWidget;
@end

/* Optional appearance hints; AppKit retains model state and bindings. */
@protocol GTK4NativeAppearanceHints
@optional
/* A nil/empty name uses the NSImageView's image instead of a themed symbol. */
- (NSString *)gtk4NativeIconName;
- (BOOL)gtk4NativeCompactRows;
@end

/* Logical children include inactive tab pages, which AppKit detaches. */
NSArray *GTK4NativeChildrenForView(NSView *view);
NSArray *GTK4NativeStructureForView(NSView *view);
BOOL GTK4NativeIsStandardTableCell(NSView *view);

@interface GTK4NativeView : NSObject <GSNativeViewPeer>
{
  NSView *_view;
  GtkWidget *_widget;
  NSMapTable *_widgets;
  BOOL _synchronizing;
  CGFloat _scale;
  BOOL _invalidated;
  BOOL _reflecting;
  NSMutableArray *_embeddedTables;
  NSMapTable *_paneScenes;
  BOOL _borrowedRoot;
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
