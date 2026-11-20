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
+ (id)peerForTable:(NSTableView *)table inWindow:(NSWindow *)window;
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
  gint64 _bindFrame;
  GObject *_representedItem;
  NSTableColumn *_column;
  GtkWidget *_label;
}
@end
@implementation GTK4NativeRow
- (void)dealloc { [_column release]; if(_representedItem) g_object_unref(_representedItem); [_bridge release]; [super dealloc]; }
@end
@interface GTK4NativeColumn : NSObject {
@public
  GTK4NativeTable *_peer;
  NSTableColumn *_column;
}
@end
@implementation GTK4NativeColumn
- (void)dealloc { [_column release]; [super dealloc]; }
@end
static void releaseRow(gpointer data) { [(id)data release]; }
static void groupToggled(GtkButton *button, gpointer data)
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
  /* A plain disclosure triangle: GTK's default button minimum (34px) and a
   * toggle button's checked background do not belong in an outline row. */
  GdkDisplay *display = gdk_display_get_default();
  if (display && !g_object_get_data(G_OBJECT(display), "appkit-disclosure-style")) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider,
      "button.gnustep-disclosure { min-width: 16px; min-height: 16px; padding: 0; margin: 0; }", -1);
    gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_set_data_full(G_OBJECT(display), "appkit-disclosure-style", provider, g_object_unref);
  }
  row->_expander = gtk_button_new_from_icon_name("pan-end-symbolic");
  gtk_widget_add_css_class(row->_expander, "flat");
  gtk_widget_add_css_class(row->_expander, "gnustep-disclosure");
  gtk_widget_set_valign(row->_expander, GTK_ALIGN_CENTER);
  gtk_widget_set_focusable(row->_expander, FALSE);
  gtk_widget_set_visible(row->_expander, FALSE);
  g_signal_connect(row->_expander, "clicked", G_CALLBACK(groupToggled), row);
  gtk_box_append(GTK_BOX(row->_box), row->_expander);
  gtk_list_item_set_child(item, row->_box);
  g_object_set_data_full(G_OBJECT(item), "appkit-row", row, releaseRow);
  [((GTK4NativeTable *)data)->_rows addObject:row];
}
static void setupColumn(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeColumn *column = data;
  setup(factory,item,column->_peer);
  GTK4NativeRow *row = g_object_get_data(G_OBJECT(item),"appkit-row");
  row->_column = [column->_column retain];
  row->_label = gtk_label_new("");
  gtk_label_set_xalign(GTK_LABEL(row->_label),0);
  gtk_label_set_ellipsize(GTK_LABEL(row->_label),PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand(row->_label,TRUE);
  gtk_box_append(GTK_BOX(row->_box),row->_label);
}
static void updateOutlineRow(GTK4NativeTable *peer,GTK4NativeRow *row)
{
  if(![peer->_table isKindOfClass:NSOutlineView.class]
      || (row->_column && row->_column != [(NSOutlineView *)peer->_table outlineTableColumn])) return;
  NSUInteger index=gtk_list_item_get_position(row->_item);
  if(index>=[peer->_table numberOfRows]) return;
  NSOutlineView *outline=(id)peer->_table;
  id object=[outline itemAtRow:index];
  BOOL expandable=[outline isExpandable:object],synchronizing=peer->_synchronizing;
  peer->_synchronizing=YES;
  // Leaves retain the triangle's space so siblings share the same text edge.
  gtk_widget_set_visible(row->_expander,TRUE);
  gtk_widget_set_opacity(row->_expander,expandable?1:0);
  gtk_widget_set_sensitive(row->_expander,expandable);
  const char *icon=[outline isItemExpanded:object]?"pan-down-symbolic":"pan-end-symbolic";
  if(g_strcmp0(gtk_button_get_icon_name(GTK_BUTTON(row->_expander)),icon))
    gtk_button_set_icon_name(GTK_BUTTON(row->_expander),icon);
  peer->_synchronizing=synchronizing;
  gtk_widget_set_margin_start(row->_box,4+MAX(0,[outline levelForRow:index])*outline.indentationPerLevel*peer->_scale);
}
static void populateRow(GTK4NativeTable *peer, GTK4NativeRow *row)
{
  GtkListItem *item = row->_item;
  NSUInteger index = gtk_list_item_get_position(item);
  if (index >= [peer->_table numberOfRows]) return;
  row->_pending = NO;
  if (row->_column) {
    id value = [peer->_table _objectValueForTableColumn:row->_column row:index];
    // Cocoa view-based lists bind their prototype to a content-array object.
    NSDictionary *binding = [peer->_table infoForBinding:NSContentBinding];
    if (!value && binding) {
      NSArray *content = [binding[NSObservedObjectKey] valueForKeyPath:binding[NSObservedKeyPathKey]];
      if (index < content.count) value = content[index];
    }
    NSView *prototype = [peer->_table _prototypeCellViewFromTableColumn:row->_column];
    if ([prototype isKindOfClass:NSTableCellView.class]) {
      [(NSTableCellView *)prototype setObjectValue:value];
      value = [[(NSTableCellView *)prototype textField] stringValue];
    }
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] : [value description];
    gtk_label_set_text(GTK_LABEL(row->_label),[text UTF8String] ?: "");
    row->_generation = peer->_generation;
    g_set_object(&row->_representedItem,gtk_list_item_get_item(item));
    updateOutlineRow(peer,row);
    return;
  }
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
  g_set_object(&row->_representedItem,gtk_list_item_get_item(item));
  gtk_widget_set_size_request([row->_bridge widget], -1,
    MAX(1, ceil([peer->_table _rowHeightForRow:index] * peer->_scale)));
  gtk_widget_set_margin_start(row->_box, 4);
  gtk_widget_set_margin_end(row->_box, 4);
  updateOutlineRow(peer,row);
}
static void bindRow(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{
  GTK4NativeTable *peer = data;
  GTK4NativeRow *row = g_object_get_data(G_OBJECT(item), "appkit-row");
  row->_bound = YES;
  // Text columns are ordinary GTK labels: bind their model values immediately.
  // They need no AppKit view construction or layout, and an idle newly shown
  // tab may not request another frame to run the deferred custom-row path.
  if(row->_column) populateRow(peer,row);
  // A position change can rebind an unchanged model item. Keep its existing
  // content visible; only a different item needs deferred population.
  else if(!row->_bridge || row->_representedItem!=gtk_list_item_get_item(item) || row->_generation!=peer->_generation) {
    row->_pending=YES;
    GdkFrameClock *clock=gtk_widget_get_frame_clock(row->_box);
    row->_bindFrame=clock?gdk_frame_clock_get_frame_counter(clock):-1;
    if(row->_bridge) gtk_widget_set_visible(row->_bridge.widget,FALSE);
  }
  guint position = gtk_list_item_get_position(item);
  gtk_widget_set_size_request(row->_box,-1, position < [peer->_table numberOfRows]
    ? MAX(1,ceil([peer->_table _rowHeightForRow:position] * peer->_scale)) : 1);
}
static void bindColumn(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{ bindRow(factory,item,((GTK4NativeColumn *)data)->_peer); }
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

static void teardownColumn(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data)
{ teardownRow(factory,item,((GTK4NativeColumn *)data)->_peer); }

/* Inactive tab pages remain logical scene children. Ordinary detached views
 * do not: preserving those peers would keep removed widgets hosted. */
static BOOL sceneContainsTable(NSView *view, NSTableView *table)
{
  if (view == table) return YES;
  BOOL tabPages=[view isKindOfClass:[NSTabView class]];
  for (NSView *child in GTK4NativeChildrenForView(view))
    if ((tabPages || child.superview==view) && sceneContainsTable(child, table)) return YES;
  return NO;
}

@implementation GTK4NativeTable
+ (id)attachedPeerForTable:(NSTableView *)table
{ return [self attachedPeerForTable:table inWindow:table.window]; }
+ (id)attachedPeerForTable:(NSTableView *)table inWindow:(NSWindow *)window
{
  id peer = [table valueForKey:@"_nativeTableView"];
  if (!peer) {
    peer = [self peerForTable:table inWindow:window];
    if (peer) [table setValue:peer forKey:@"_nativeTableView"];
  }
  return peer;
}
+ (id)peerForTable:(NSTableView *)table
{ return [self peerForTable:table inWindow:table.window]; }
+ (id)peerForTable:(NSTableView *)table inWindow:(NSWindow *)window
{
  if (g_strcmp0(g_getenv("GTK4_NATIVE_TABLES"), "0") == 0 || ![table numberOfColumns]
      || ![table enclosingScrollView]) return nil;
  NSView *decoration = window.contentView;
  while ([decoration superview]) decoration = [decoration superview];
  if (![decoration isKindOfClass:[GTK4NativeWindowDecorationView class]]) return nil;
  GTK4NativeWindowDecorationView *host = (id)decoration;
  if (!host->_host || !host->_nativeContent) return nil;
  NSDictionary *prototypes = [table valueForKey:@"_registeredViews"];
  BOOL columnView = [table headerView] != nil || table.numberOfColumns != 1 || !prototypes.count;
  if (columnView) {
    for (NSTableColumn *column in table.tableColumns) if ([column isEditable]) return nil;
    for (NSView *view in prototypes.allValues) {
      if (![view isKindOfClass:NSTableCellView.class] || view.subviews.count != 1
          || view.subviews.firstObject != [(NSTableCellView *)view textField]) return nil;
    }
  }
  if (!columnView) for (NSView *view in [prototypes allValues]) if (![GTK4NativeView supportsView:view]) return nil;
  GTK4NativeTable *peer = [[[self alloc] init] autorelease];
  peer->_table = table; peer->_host = host;
  peer->_scale = [window userSpaceScaleFactor] / MAX(1, gtk_widget_get_scale_factor(host->_host));
  peer->_rows = [[NSHashTable weakObjectsHashTable] retain];
  peer->_model = g_list_store_new(G_TYPE_OBJECT);
  peer->_selection = [table allowsMultipleSelection]
    ? GTK_SELECTION_MODEL(gtk_multi_selection_new(G_LIST_MODEL(g_object_ref(peer->_model))))
    : GTK_SELECTION_MODEL(gtk_single_selection_new(G_LIST_MODEL(g_object_ref(peer->_model))));
  if (GTK_IS_SINGLE_SELECTION(peer->_selection)) {
    gtk_single_selection_set_autoselect(GTK_SINGLE_SELECTION(peer->_selection), FALSE);
    gtk_single_selection_set_can_unselect(GTK_SINGLE_SELECTION(peer->_selection), [table allowsEmptySelection]);
  }
  if (columnView) {
    peer->_list = gtk_column_view_new(GTK_SELECTION_MODEL(g_object_ref(peer->_selection)));
    gtk_column_view_set_show_column_separators(GTK_COLUMN_VIEW(peer->_list),TRUE);
    for (NSTableColumn *column in table.tableColumns) {
      GTK4NativeColumn *context = [GTK4NativeColumn new];
      context->_peer = peer; context->_column = [column retain];
      GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
      g_object_set_data_full(G_OBJECT(factory),"appkit-column-context",context,releaseRow);
      g_signal_connect(factory,"setup",G_CALLBACK(setupColumn),context);
      g_signal_connect(factory,"bind",G_CALLBACK(bindColumn),context);
      g_signal_connect(factory,"unbind",G_CALLBACK(unbindRow),context);
      g_signal_connect(factory,"teardown",G_CALLBACK(teardownColumn),context);
      GtkColumnViewColumn *native = gtk_column_view_column_new([[column.headerCell stringValue] UTF8String],factory);
      g_object_set_data(G_OBJECT(native),"appkit-column",column);
      // A single-column list fills its viewport in both directions. An initial
      // AppKit column width must not become a permanent GTK allocation/minimum.
      BOOL fillsViewport = table.numberOfColumns == 1;
      gtk_column_view_column_set_fixed_width(native,fillsViewport ? -1 : MAX(30,ceil(column.width*peer->_scale)));
      gtk_column_view_column_set_expand(native,fillsViewport);
      gtk_column_view_column_set_resizable(native,TRUE);
      gtk_column_view_column_set_visible(native,![column isHidden]);
      gtk_column_view_append_column(GTK_COLUMN_VIEW(peer->_list),native);
      g_object_unref(native);
    }
  } else {
  GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
  g_signal_connect(factory, "setup", G_CALLBACK(setup), peer);
  g_signal_connect(factory, "bind", G_CALLBACK(bindRow), peer);
  g_signal_connect(factory, "unbind", G_CALLBACK(unbindRow), peer);
  g_signal_connect(factory, "teardown", G_CALLBACK(teardownRow), peer);
  peer->_list = gtk_list_view_new(GTK_SELECTION_MODEL(g_object_ref(peer->_selection)), factory);
  }
  gtk_widget_add_css_class(peer->_list, "navigation-sidebar");
  if ([table respondsToSelector:@selector(gtk4NativeCompactRows)] &&
      [(id<GTK4NativeAppearanceHints>)table gtk4NativeCompactRows]) {
    GdkDisplay *display = gdk_display_get_default();
    if (!g_object_get_data(G_OBJECT(display), "appkit-compact-list-style")) {
      GtkCssProvider *provider = gtk_css_provider_new();
      gtk_css_provider_load_from_data(provider,
        "listview.gnustep-compact-list > row { min-height: 0; padding: 2px 4px; }", -1);
      gtk_style_context_add_provider_for_display(display, GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
      g_object_set_data_full(G_OBJECT(display), "appkit-compact-list-style", provider, g_object_unref);
    }
    gtk_widget_add_css_class(peer->_list, "gnustep-compact-list");
  }
  g_signal_connect(peer->_selection, "selection-changed", G_CALLBACK(nativeSelection), peer);
  g_signal_connect(peer->_list, "activate", G_CALLBACK(nativeActivate), peer);
  peer->_scroller = gtk_scrolled_window_new();
  g_object_ref_sink(peer->_scroller);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(peer->_scroller), columnView ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(peer->_scroller), peer->_list);
  peer->_clip = GTK4NativeClipNew(peer->_scroller);
  g_object_ref_sink(peer->_clip);
  gtk_fixed_put(GTK_FIXED(host->_nativeContent), peer->_clip, 0, 0);
  [host->_nativeTables addObject:peer];
  [[NSNotificationCenter defaultCenter] addObserver:peer selector:@selector(selectionChanged:)
    name:[table isKindOfClass:[NSOutlineView class]] ? NSOutlineViewSelectionDidChangeNotification
      : NSTableViewSelectionDidChangeNotification object:table];
  if([table isKindOfClass:NSOutlineView.class]) {
    for(NSString *name in @[NSOutlineViewItemWillExpandNotification,NSOutlineViewItemWillCollapseNotification,
        NSOutlineViewItemDidExpandNotification,NSOutlineViewItemDidCollapseNotification])
      [[NSNotificationCenter defaultCenter] addObserver:peer selector:@selector(disclosureChanged:) name:name object:table];
  }
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
    if (!value) {
      NSDictionary *binding = [_table infoForBinding:NSContentBinding];
      NSArray *content = [binding[NSObservedObjectKey] valueForKeyPath:binding[NSObservedKeyPathKey]];
      if ((NSUInteger)row < content.count) value = content[row];
    }
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
  BOOL outline=[_table isKindOfClass:NSOutlineView.class];
  BOOL disclosure=outline && _outlineDisclosureChanged;
  if(!disclosure) _generation++;
  BOOL synchronizing=_synchronizing;
  _synchronizing = YES;
  guint count = [_table numberOfRows];
  guint oldCount=g_list_model_get_n_items(G_LIST_MODEL(_model)),prefix=0,suffix=0;
  if(outline) {
    NSMutableArray *next=[NSMutableArray arrayWithCapacity:count];
    for(guint i=0;i<count;i++) [next addObject:[(NSOutlineView *)_table itemAtRow:i]];
    while(prefix<MIN(oldCount,count) && _outlineItems[prefix]==next[prefix]) prefix++;
    while(suffix<MIN(oldCount,count)-prefix && _outlineItems[oldCount-1-suffix]==next[count-1-suffix]) suffix++;
    ASSIGNCOPY(_outlineItems,next);
  }
  guint added=count-prefix-suffix,removed=oldCount-prefix-suffix;
  gpointer *items=g_new(gpointer,MAX(added,1));
  for(guint i=0;i<added;i++) items[i]=g_object_new(G_TYPE_OBJECT,NULL);
  if(added || removed) g_list_store_splice(_model,prefix,removed,items,added);
  for(guint i=0;i<added;i++) g_object_unref(items[i]);
  g_free(items);
  if(outline && !disclosure) for(GTK4NativeRow *row in [_rows allObjects]) if(row->_bound) row->_pending=YES;
  _synchronizing = synchronizing;
  [self selectionChanged:nil];
}
- (void)disclosureChanged:(NSNotification *)notification
{
  // Recursive expansion can issue several reloads before the host updates.
  // They all describe disclosure changes, not requests to recreate row views.
  _outlineDisclosureChanged=YES;
}
- (void)selectionChanged:(NSNotification *)notification
{
  if (_synchronizing || !_selection || !_table) return;
  _synchronizing = YES;
  NSIndexSet *indexes = [_table selectedRowIndexes];
  if(GTK_IS_SINGLE_SELECTION(_selection)) {
    NSUInteger selected=indexes.firstIndex;
    gtk_single_selection_set_selected(GTK_SINGLE_SELECTION(_selection),selected==NSNotFound || selected>=g_list_model_get_n_items(G_LIST_MODEL(_selection))?GTK_INVALID_LIST_POSITION:(guint)selected);
    _synchronizing=NO;
    return;
  }
  GtkBitset *selected = gtk_bitset_new_empty();
  for (NSUInteger index = [indexes firstIndex]; index != NSNotFound; index = [indexes indexGreaterThanIndex:index])
    if(index<g_list_model_get_n_items(G_LIST_MODEL(_selection))) gtk_bitset_add(selected, index);
  GtkBitset *mask = gtk_bitset_new_range(0, g_list_model_get_n_items(G_LIST_MODEL(_selection)));
  gtk_selection_model_set_selection(_selection, selected, mask);
  gtk_bitset_unref(selected); gtk_bitset_unref(mask);
  _synchronizing = NO;
}
- (BOOL)preservesPeerForWindow:(NSWindow *)window
{
  if (!_embedded || !_host || !_table || _failed) return NO;
  if (window) return GTK4NativeHostForWindow(window)==GTK_WINDOW(_host->_host);
  return sceneContainsTable([[_host window] contentView], _table);
}
- (BOOL)update
{
  // NSTabView detaches inactive AppKit pages. Their GTK widgets and models
  // still belong to the scene; a temporary nil window must not destroy them.
  if(_table && !_table.window && [self preservesPeerForWindow:nil]) return YES;
  if (_failed || !_host || !_table || GTK4NativeHostForWindow([_table window]) != GTK_WINDOW(_host->_host)) {
    [self invalidate]; return NO;
  }
  NSScrollView *scroll = [_table enclosingScrollView];
  _outlineDisclosureChanged=NO;
  if (GTK_IS_COLUMN_VIEW(_list)) {
    GListModel *columns = gtk_column_view_get_columns(GTK_COLUMN_VIEW(_list));
    for (guint i=0; i<g_list_model_get_n_items(columns); i++) {
      GtkColumnViewColumn *native = g_list_model_get_item(columns,i);
      NSTableColumn *column = g_object_get_data(G_OBJECT(native),"appkit-column");
      gtk_column_view_column_set_visible(native,![column isHidden]);
      gtk_column_view_column_set_title(native,[[column.headerCell stringValue] UTF8String]);
      g_object_unref(native);
    }
  }
  gtk_scrolled_window_set_has_frame(GTK_SCROLLED_WINDOW(_scroller),scroll.borderType!=NSNoBorder);
  if (_embedded) {
    graphene_rect_t allocated;
    if (gtk_widget_compute_bounds(_scroller,_host->_nativeContent,&allocated))
      _hostRect=NSMakeRect(allocated.origin.x,allocated.origin.y,allocated.size.width,allocated.size.height);
    for (GTK4NativeRow *row in [_rows allObjects]) {
      if (!row->_bound || !row->_box || !gtk_widget_get_mapped(row->_box)
          || gtk_widget_get_width(row->_box)<=0 || gtk_widget_get_height(row->_box)<=0) continue;
      GdkFrameClock *clock=gtk_widget_get_frame_clock(row->_box);
      if(!row->_column && clock && gdk_frame_clock_get_frame_counter(clock)<=row->_bindFrame) continue;
      graphene_rect_t rowRect;
      if (!gtk_widget_compute_bounds(row->_box,_scroller,&rowRect)
          || rowRect.origin.y+rowRect.size.height<=0 || rowRect.origin.y>=gtk_widget_get_height(_scroller)) continue;
      if (row->_pending) populateRow(self,row);
      updateOutlineRow(self,row);
      if (row->_bridge) [row->_bridge synchronize];
    }
    return YES;
  }
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
  nextRect=NSMakeRect(lround(nextRect.origin.x),lround(nextRect.origin.y),
    MAX(1,lround(nextRect.size.width)),MAX(1,lround(nextRect.size.height)));
  NSColor *background=[[_table backgroundColor] colorUsingColorSpaceName:NSDeviceRGBColorSpace];
  if(background) {
    GdkRGBA color={background.redComponent,background.greenComponent,background.blueComponent,background.alphaComponent};
    GTK4NativeClipSetBackground(_clip,&color);
  }
  if (!NSEqualRects(_hostRect,nextRect) || !NSEqualRects(_fullHostRect,nextFullRect)) {
    _hostRect = nextRect; _fullHostRect = nextFullRect;
    GtkAllocation allocation = {lround(NSMinX(_fullHostRect)-NSMinX(_hostRect)),
      lround(NSMinY(_fullHostRect)-NSMinY(_hostRect)),
      MAX(1,lround(NSWidth(_fullHostRect))), MAX(1,lround(NSHeight(_fullHostRect)))};
    GTK4NativeClipSetAllocation(_clip,allocation);
    GtkAllocation placement={NSMinX(_hostRect),NSMinY(_hostRect),NSWidth(_hostRect),NSHeight(_hostRect)};
    GTK4NativeClipPlace(_clip,_host->_nativeContent,placement);
  }
  for (GTK4NativeRow *row in [_rows allObjects]) {
    if (!row->_bound || !row->_box) continue;
    GdkFrameClock *clock=gtk_widget_get_frame_clock(row->_box);
    if(!row->_column && clock && gdk_frame_clock_get_frame_counter(clock)<=row->_bindFrame) continue;
    graphene_rect_t allocated;
    if (gtk_widget_get_width(row->_box) <= 0 || gtk_widget_get_height(row->_box) <= 0
        || !gtk_widget_compute_bounds(row->_box,_clip,&allocated)
        || allocated.origin.y + allocated.size.height <= 0
        || allocated.origin.y >= gtk_widget_get_height(_clip)) continue;
    // GTK prefetches list items well outside the viewport. Their lightweight
    // placeholders need no Objective-C template/bindings until actually seen.
    if (row->_pending) populateRow(self,row);
    updateOutlineRow(self,row);
    if (row->_bridge) [row->_bridge synchronize];
  }
  return YES;
}
- (void)scrollRowToVisible:(NSInteger)row
{
  if (_list && row >= 0 && row < [_table numberOfRows]) {
    if (GTK_IS_COLUMN_VIEW(_list)) gtk_column_view_scroll_to(GTK_COLUMN_VIEW(_list),row,NULL,GTK_LIST_SCROLL_FOCUS,NULL);
    else gtk_list_view_scroll_to(GTK_LIST_VIEW(_list), row, GTK_LIST_SCROLL_FOCUS, NULL);
  }
}
- (GtkWidget *)widget { return _scroller; }
- (GtkWidget *)embed
{
  _embedded=YES;
  GTK4NativeClipSetChild(_clip,NULL);
  GTK4NativeDetachWidget(_scroller);
  if (gtk_widget_get_parent(_clip)) gtk_widget_unparent(_clip);
  return _scroller;
}
- (void)unembed
{
  if (!_embedded) return;
  _embedded=NO;
  GTK4NativeDetachWidget(_scroller);
  if (!_host || !_table) return;
  GTK4NativeClipSetChild(_clip,_scroller);
  gtk_widget_set_visible(_scroller,TRUE);
  gtk_fixed_put(GTK_FIXED(_host->_nativeContent),_clip,0,0);
  _hostRect=NSZeroRect; _fullHostRect=NSZeroRect;
}
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
  [_outlineItems release]; [_rows release]; [super dealloc];
}
@end
