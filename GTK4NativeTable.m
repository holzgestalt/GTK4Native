#import "GTK4NativeTable.h"
#import "GTK4NativeClip.h"
#import "GTK4NativeWindow.h"

@interface NSTableView (GTK4NativeTablePrivate)
- (id)_prototypeCellViewFromTableColumn:(NSTableColumn *)column;
- (id)_objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
- (CGFloat)_rowHeightForRow:(NSInteger)row;
- (NSTableRowView *)_delegateRowViewForRow:(NSInteger)row;
@end
@interface GTK4NativeTable (Private)
- (NSView *)cellForRow:(NSInteger)row;
- (void)selectionChanged:(NSNotification *)notification;
@end

@interface GTK4NativeRow : NSObject
{
@public
  GTK4NativeTable *_peer;
  GTK4NativeView *_bridge;
  GtkListItem *_item;
  GtkWidget *_box;
  GtkWidget *_expander;
  NSUInteger _generation;
  BOOL _pending;
  BOOL _bound;
}
@end
@implementation GTK4NativeRow
- (void)dealloc { [_bridge release]; [super dealloc]; }
@end
static void releaseRow(gpointer data) { [(id)data release]; }
static void groupToggled(GtkToggleButton *button, gpointer data)
{
  GTK4NativeRow *row = data;
  if (!row->_peer || row->_peer->_synchronizing) return;
  NSOutlineView *outline = (id)row->_peer->_table;
  id item = [outline itemAtRow:gtk_list_item_get_position(row->_item)];
  if ([outline isItemExpanded:item]) [outline collapseItem:item]; else [outline expandItem:item];
}
static void setup(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeRow *row = [GTK4NativeRow new];
  row->_peer = data; row->_item = item;
  row->_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
  row->_expander = gtk_toggle_button_new();
  gtk_button_set_icon_name(GTK_BUTTON(row->_expander), "pan-end-symbolic");
  gtk_widget_add_css_class(row->_expander, "flat");
  gtk_widget_set_visible(row->_expander, FALSE);
  g_signal_connect(row->_expander, "toggled", G_CALLBACK(groupToggled), row);
  gtk_box_append(GTK_BOX(row->_box), row->_expander);
  gtk_list_item_set_child(item, row->_box);
  g_object_set_data_full(G_OBJECT(item), "appkit-row", row, releaseRow);
  [((GTK4NativeTable *)data)->_rows addObject:row];
}
static void populateRow(GTK4NativeTable *peer, GTK4NativeRow *row)
{
  GtkListItem *item = row->_item;
  NSUInteger index = gtk_list_item_get_position(item);
  if (index >= [peer->_table numberOfRows]) return;
  row->_pending = NO;
  NSTableRowView *background = [peer->_table _delegateRowViewForRow:index];
  if (background && [background class] != [NSTableRowView class]) {
    peer->_failed = YES; [peer->_table setNeedsDisplay:YES]; return;
  }
  NSView *source = [peer cellForRow:index];
  NSString *identifier = [source identifier];
  // Rebinding an existing prototype preserves its GTK widgets and constraints.
  if (row->_bridge && row->_generation == peer->_generation && identifier
      && [[row->_bridge.view identifier] isEqual:identifier]
      && [source isKindOfClass:[NSTableCellView class]]) {
    [(NSTableCellView *)row->_bridge.view setObjectValue:[(NSTableCellView *)source objectValue]];
  } else {
    [row->_bridge release]; row->_bridge = nil;
    row->_bridge = [[GTK4NativeView alloc] initWithView:source scale:peer->_scale];
    row->_generation = peer->_generation;
    if (!row->_bridge) {
      peer->_failed = YES; [peer->_table setNeedsDisplay:YES]; return;
    }
    GtkWidget *native = [row->_bridge widget];
    gtk_widget_set_hexpand(native, TRUE);
    gtk_box_append(GTK_BOX(row->_box), native);
  }
  [row->_bridge synchronize];
  gtk_widget_set_size_request([row->_bridge widget], -1,
    MAX(1, ceil([peer->_table _rowHeightForRow:index] * peer->_scale)));
  gtk_widget_set_margin_start(row->_box, 4);
  gtk_widget_set_margin_end(row->_box, 4);
  if ([peer->_table isKindOfClass:[NSOutlineView class]]) {
    NSOutlineView *outline = (id)peer->_table;
    id object = [outline itemAtRow:index];
    BOOL expandable = [outline isExpandable:object];
    peer->_synchronizing = YES;
    gtk_widget_set_visible(row->_expander, expandable);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(row->_expander), [outline isItemExpanded:object]);
    gtk_button_set_icon_name(GTK_BUTTON(row->_expander), [outline isItemExpanded:object] ? "pan-down-symbolic" : "pan-end-symbolic");
    peer->_synchronizing = NO;
    gtk_widget_set_margin_start(row->_box, 4 + MAX(0, [outline levelForRow:index]) * [outline indentationPerLevel] * peer->_scale);
  }
}
static void bindRow(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeTable *peer = data;
  GTK4NativeRow *row = g_object_get_data(G_OBJECT(item), "appkit-row");
  row->_pending = YES;
  row->_bound = YES;
  if (row->_bridge) gtk_widget_set_visible(row->_bridge.widget,FALSE);
  guint position = gtk_list_item_get_position(item);
  gtk_widget_set_size_request(row->_box,-1, position < [peer->_table numberOfRows]
    ? MAX(1,ceil([peer->_table _rowHeightForRow:position] * peer->_scale)) : 1);
}
static void unbindRow(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeRow *row = g_object_get_data(G_OBJECT(item),"appkit-row");
  row->_bound = NO;
}
static void teardownRow(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeTable *peer = data;
  GTK4NativeRow *row = g_object_get_data(G_OBJECT(item),"appkit-row");
  if (!row) return;
  [peer->_rows removeObject:row];
  row->_peer = nil; row->_bound = NO; row->_box = NULL; row->_item = NULL;
  [row->_bridge release]; row->_bridge = nil;
  gtk_list_item_set_child(item,NULL);
  g_object_set_data(G_OBJECT(item),"appkit-row",NULL);
}
static void nativeSelection(GtkSelectionModel *selection, guint position, guint count, gpointer data)
{
  GTK4NativeTable *peer = data;
  if (peer->_synchronizing || !peer->_table) return;
  [peer retain];
  NSTableView *table = [peer->_table retain];
  GtkBitset *selected = gtk_selection_model_get_selection(selection);
  GtkBitsetIter iterator; guint index;
  NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
  if (gtk_bitset_iter_init_first(&iterator, selected, &index)) do {
    [indexes addIndex:index];
  } while (gtk_bitset_iter_next(&iterator, &index));
  gtk_bitset_unref(selected);
  peer->_synchronizing = YES;
  [peer->_table selectRowIndexes:indexes byExtendingSelection:NO];
  [NSApp sendAction:[peer->_table action] to:[peer->_table target] from:peer->_table];
  peer->_synchronizing = NO;
  [peer selectionChanged:nil];
  [table release]; [peer release];
}
static void nativeActivate(GtkListView *list, guint position, gpointer data)
{
  GTK4NativeTable *peer = data;
  if (peer->_table) [NSApp sendAction:[peer->_table doubleAction] to:[peer->_table target] from:peer->_table];
}

@implementation GTK4NativeTable
+ (id)peerForTable:(NSTableView *)table
{
  if (g_strcmp0(g_getenv("GTK4_NATIVE_TABLES"), "0") == 0 || [table numberOfColumns] != 1
      || [table headerView] != nil || ![table enclosingScrollView]) return nil;
  NSView *decoration = [table window].contentView;
  while ([decoration superview]) decoration = [decoration superview];
  if (![decoration isKindOfClass:[GTK4NativeWindowDecorationView class]]) return nil;
  GTK4NativeWindowDecorationView *host = (id)decoration;
  if (!host->_host || !host->_nativeContent) return nil;
  NSDictionary *prototypes = [table valueForKey:@"_registeredViews"];
  if (![prototypes count]) return nil;
  for (NSView *view in [prototypes allValues]) if (![GTK4NativeView supportsView:view]) return nil;
  GTK4NativeTable *peer = [[[self alloc] init] autorelease];
  peer->_table = table; peer->_host = host;
  peer->_scale = [[table window] userSpaceScaleFactor] / MAX(1, gtk_widget_get_scale_factor(host->_host));
  peer->_rows = [[NSHashTable weakObjectsHashTable] retain];
  peer->_model = g_list_store_new(G_TYPE_OBJECT);
  peer->_selection = [table allowsMultipleSelection]
    ? GTK_SELECTION_MODEL(gtk_multi_selection_new(G_LIST_MODEL(g_object_ref(peer->_model))))
    : GTK_SELECTION_MODEL(gtk_single_selection_new(G_LIST_MODEL(g_object_ref(peer->_model))));
  if (GTK_IS_SINGLE_SELECTION(peer->_selection)) {
    gtk_single_selection_set_autoselect(GTK_SINGLE_SELECTION(peer->_selection), FALSE);
    gtk_single_selection_set_can_unselect(GTK_SINGLE_SELECTION(peer->_selection), [table allowsEmptySelection]);
  }
  GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
  g_signal_connect(factory, "setup", G_CALLBACK(setup), peer);
  g_signal_connect(factory, "bind", G_CALLBACK(bindRow), peer);
  g_signal_connect(factory, "unbind", G_CALLBACK(unbindRow), peer);
  g_signal_connect(factory, "teardown", G_CALLBACK(teardownRow), peer);
  peer->_list = gtk_list_view_new(GTK_SELECTION_MODEL(g_object_ref(peer->_selection)), factory);
  gtk_widget_add_css_class(peer->_list, "navigation-sidebar");
  g_signal_connect(peer->_selection, "selection-changed", G_CALLBACK(nativeSelection), peer);
  g_signal_connect(peer->_list, "activate", G_CALLBACK(nativeActivate), peer);
  peer->_scroller = gtk_scrolled_window_new();
  g_object_ref_sink(peer->_scroller);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(peer->_scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(peer->_scroller), peer->_list);
  peer->_clip = GTK4NativeClipNew(peer->_scroller);
  g_object_ref_sink(peer->_clip);
  gtk_fixed_put(GTK_FIXED(host->_nativeContent), peer->_clip, 0, 0);
  [host->_nativeTables addObject:peer];
  [[NSNotificationCenter defaultCenter] addObserver:peer selector:@selector(selectionChanged:)
    name:[table isKindOfClass:[NSOutlineView class]] ? NSOutlineViewSelectionDidChangeNotification
      : NSTableViewSelectionDidChangeNotification object:table];
  [peer reloadData];
  return peer;
}
- (NSView *)cellForRow:(NSInteger)row
{
  NSTableColumn *column = [[_table tableColumns] objectAtIndex:0];
  id delegate = [_table delegate];
  NSView *view = nil; id value = nil;
  if ([_table isKindOfClass:[NSOutlineView class]]) {
    NSOutlineView *outline = (id)_table;
    value = [outline itemAtRow:row];
    if ([delegate respondsToSelector:@selector(outlineView:viewForTableColumn:item:)])
      view = [delegate outlineView:outline viewForTableColumn:column item:value];
  } else {
    value = [_table _objectValueForTableColumn:column row:row];
    if ([delegate respondsToSelector:@selector(tableView:viewForTableColumn:row:)])
      view = [delegate tableView:_table viewForTableColumn:column row:row];
  }
  if (!view) view = [_table _prototypeCellViewFromTableColumn:column];
  if ([view isKindOfClass:[NSTableCellView class]]) [(NSTableCellView *)view setObjectValue:value];
  return view;
}
- (void)reloadData
{
  if (!_model || !_table) return;
  _generation++;
  _synchronizing = YES;
  guint count = [_table numberOfRows];
  gpointer *items = g_new(gpointer, MAX(count, 1));
  for (guint i = 0; i < count; i++) items[i] = g_object_new(G_TYPE_OBJECT, NULL);
  g_list_store_splice(_model, 0, g_list_model_get_n_items(G_LIST_MODEL(_model)), items, count);
  for (guint i = 0; i < count; i++) g_object_unref(items[i]);
  g_free(items);
  _synchronizing = NO;
  [self selectionChanged:nil];
}
- (void)selectionChanged:(NSNotification *)notification
{
  if (_synchronizing || !_selection || !_table) return;
  _synchronizing = YES;
  GtkBitset *selected = gtk_bitset_new_empty();
  NSIndexSet *indexes = [_table selectedRowIndexes];
  for (NSUInteger index = [indexes firstIndex]; index != NSNotFound; index = [indexes indexGreaterThanIndex:index])
    gtk_bitset_add(selected, index);
  GtkBitset *mask = gtk_bitset_new_range(0, [_table numberOfRows]);
  gtk_selection_model_set_selection(_selection, selected, mask);
  gtk_bitset_unref(selected); gtk_bitset_unref(mask);
  _synchronizing = NO;
}
- (BOOL)update
{
  if (_failed || !_host || !_table || GTK4NativeHostForWindow([_table window]) != GTK_WINDOW(_host->_host)) {
    [self invalidate]; return NO;
  }
  NSScrollView *scroll = [_table enclosingScrollView];
  BOOL visible = scroll && ![_table isHiddenOrHasHiddenAncestor] && [scroll window] == [_table window];
  graphene_rect_t body;
  visible = visible && gtk_widget_get_height(_host->_nativeContent) > 0
    && gtk_widget_compute_bounds(_host->_nativeContent,_host->_host,&body);
  NSRect visibleRect = scroll ? NSIntersectionRect([scroll bounds], [scroll visibleRect]) : NSZeroRect;
  visible = visible && !NSIsEmptyRect(visibleRect);
  gtk_widget_set_visible(_clip, visible);
  if (!visible) { _hostRect = NSZeroRect; return YES; }
  CGFloat factor = [[_table window] userSpaceScaleFactor] / MAX(1,gtk_widget_get_scale_factor(_host->_host));
  if (fabs(_scale-factor) > .001) {
    _scale = factor; _generation++;
    for (GTK4NativeRow *row in [_rows allObjects]) if (row->_bound) row->_pending = YES;
  }
  // Map from the AppKit decoration's window coordinates into the GTK body.
  // The body may also contain an AppKit menu above the content view, so its
  // origin cannot be inferred from contentView.bounds alone.
  NSRect full = [scroll convertRect:[scroll bounds] toView:_host];
  NSRect rect = [scroll convertRect:visibleRect toView:_host];
  NSRect bounds = [_host bounds];
  NSRect nextFullRect = NSMakeRect((NSMinX(full)-NSMinX(bounds))*_scale-body.origin.x,
    ([_host isFlipped] ? NSMinY(full)-NSMinY(bounds) : NSMaxY(bounds)-NSMaxY(full))*_scale-body.origin.y,
    NSWidth(full)*_scale, NSHeight(full)*_scale);
  NSRect nextRect = NSMakeRect((NSMinX(rect)-NSMinX(bounds))*_scale-body.origin.x,
    ([_host isFlipped] ? NSMinY(rect)-NSMinY(bounds) : NSMaxY(bounds)-NSMaxY(rect))*_scale-body.origin.y,
    NSWidth(rect)*_scale, NSHeight(rect)*_scale);
  if (!NSEqualRects(_hostRect,nextRect) || !NSEqualRects(_fullHostRect,nextFullRect)) {
    _hostRect = nextRect; _fullHostRect = nextFullRect;
    gtk_fixed_move(GTK_FIXED(_host->_nativeContent), _clip, NSMinX(_hostRect), NSMinY(_hostRect));
    gtk_widget_set_size_request(_clip, MAX(1,lround(NSWidth(_hostRect))), MAX(1,lround(NSHeight(_hostRect))));
    GtkAllocation allocation = {lround(NSMinX(_fullHostRect)-NSMinX(_hostRect)),
      lround(NSMinY(_fullHostRect)-NSMinY(_hostRect)),
      MAX(1,lround(NSWidth(_fullHostRect))), MAX(1,lround(NSHeight(_fullHostRect)))};
    GTK4NativeClipSetAllocation(_clip,allocation);
  }
  for (GTK4NativeRow *row in [_rows allObjects]) {
    if (!row->_bound || !row->_box) continue;
    graphene_rect_t allocated;
    if (gtk_widget_get_width(row->_box) <= 0 || gtk_widget_get_height(row->_box) <= 0
        || !gtk_widget_compute_bounds(row->_box,_clip,&allocated)
        || allocated.origin.y + allocated.size.height <= 0
        || allocated.origin.y >= gtk_widget_get_height(_clip)) continue;
    // GTK prefetches list items well outside the viewport. Their lightweight
    // placeholders need no Objective-C template/bindings until actually seen.
    if (row->_pending) populateRow(self,row);
    if (row->_bridge) [row->_bridge synchronize];
  }
  return YES;
}
- (void)scrollRowToVisible:(NSInteger)row
{
  if (_list && row >= 0 && row < [_table numberOfRows])
    gtk_list_view_scroll_to(GTK_LIST_VIEW(_list), row, GTK_LIST_SCROLL_FOCUS, NULL);
}
- (GtkWidget *)widget { return _scroller; }
- (NSRect)hostRect { return _hostRect; }
- (void)invalidate
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (_host) [_host->_nativeTables removeObject:self];
  _host = nil; _hostRect = NSZeroRect;
  _table = nil;
  for (GTK4NativeRow *row in [_rows allObjects]) row->_peer = nil;
  if (_selection) g_signal_handlers_disconnect_by_data(_selection,self);
  if (_list) g_signal_handlers_disconnect_by_data(_list,self);
  if (_clip) {
    GTK4NativeClipSetChild(_clip,NULL);
    if (gtk_widget_get_parent(_clip)) gtk_widget_unparent(_clip);
  }
}
- (void)dealloc
{
  [self invalidate];
  if (_clip) g_object_unref(_clip);
  if (_scroller) g_object_unref(_scroller);
  if (_selection) g_object_unref(_selection);
  if (_model) g_object_unref(_model);
  [_rows release]; [super dealloc];
}
@end
