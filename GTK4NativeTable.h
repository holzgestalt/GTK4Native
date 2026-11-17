#import "GTK4NativeView.h"
#import <GNUstepGUI/GSTheme.h>
@class GTK4NativeWindowDecorationView;

@interface GTK4NativeTable : NSObject <GSNativeTableView>
{
@public
  NSTableView *_table; // Table owns the peer; never retained here.
  GTK4NativeWindowDecorationView *_host;
  GtkWidget *_scroller;
  GtkWidget *_clip;
  NSRect _fullHostRect;
  GtkWidget *_list;
  GListStore *_model;
  GtkSelectionModel *_selection;
  NSHashTable *_rows;
  NSRect _hostRect;
  BOOL _synchronizing;
  BOOL _failed;
  BOOL _embedded;
  CGFloat _scale;
  NSUInteger _generation;
}
+ (id)peerForTable:(NSTableView *)table;
- (BOOL)update;
- (void)reloadData;
- (void)scrollRowToVisible:(NSInteger)row;
- (void)invalidate;
- (GtkWidget *)widget;
- (GtkWidget *)embed;
- (void)unembed;
- (NSRect)hostRect;
@end
