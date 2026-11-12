#import "GTK4NativeFilePanel.h"
#include <gtk/gtk.h>

/* GtkFileChooserNative can use the desktop portal and otherwise supplies GTK's
 * real chooser. Never emulate accessory views or silently ignore delegates. */
static BOOL canUseNative(NSSavePanel *panel)
{
  if ([panel showsHiddenFiles] || [panel accessoryView] || [panel delegate] || !gdk_display_get_default()) return NO;
  if ([panel isKindOfClass:[NSOpenPanel class]]) {
    NSOpenPanel *open = (NSOpenPanel *)panel;
    if ([open canChooseDirectories] == [open canChooseFiles]) return NO;
  }
  return YES;
}

static void responded(GtkNativeDialog *dialog, int response, gpointer data)
{
  *(int *)data = response;
}

static NSArray *choose(NSSavePanel *panel, NSString *directory, NSString *name)
{
  BOOL open = [panel isKindOfClass:[NSOpenPanel class]];
  GtkFileChooserAction action = open ? GTK_FILE_CHOOSER_ACTION_OPEN : GTK_FILE_CHOOSER_ACTION_SAVE;
  if (open && [(NSOpenPanel *)panel canChooseDirectories]) action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER;
  GtkFileChooserNative *native = gtk_file_chooser_native_new([[panel title] UTF8String],
    NULL, action, [[panel prompt] UTF8String], "_Cancel");
  GtkFileChooser *chooser = GTK_FILE_CHOOSER(native);
  if (open) gtk_file_chooser_set_select_multiple(chooser, [(NSOpenPanel *)panel allowsMultipleSelection]);
  gtk_file_chooser_set_create_folders(chooser, [panel canCreateDirectories]);
  if ([directory length]) {
    GFile *folder = g_file_new_for_path([directory fileSystemRepresentation]);
    gtk_file_chooser_set_current_folder(chooser, folder, NULL);
    g_object_unref(folder);
  }
  if (!open && [name length]) {
    if (![name pathExtension].length && [[panel allowedFileTypes] count])
      name = [name stringByAppendingPathExtension:[[panel allowedFileTypes] objectAtIndex:0]];
    gtk_file_chooser_set_current_name(chooser, [name UTF8String]);
  }
  if ([[panel allowedFileTypes] count] && action != GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER) {
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, [[[panel allowedFileTypes] componentsJoinedByString:@", "] UTF8String]);
    for (NSString *type in [panel allowedFileTypes])
      gtk_file_filter_add_pattern(filter, [[@"*." stringByAppendingString:type] UTF8String]);
    gtk_file_chooser_add_filter(chooser, filter);
    g_object_unref(filter);
    if ([panel allowsOtherFileTypes]) {
      filter = gtk_file_filter_new();
      gtk_file_filter_set_name(filter, "All files");
      gtk_file_filter_add_pattern(filter, "*");
      gtk_file_chooser_add_filter(chooser, filter);
      g_object_unref(filter);
    }
  }
  int response = GTK_RESPONSE_NONE;
  g_signal_connect(native, "response", G_CALLBACK(responded), &response);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(native), TRUE);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(native));
  /* Service timers, but do not dispatch AppKit input into the document while
   * GTK owns this modal interaction. */
  while (response == GTK_RESPONSE_NONE) {
    while (g_main_context_iteration(NULL, FALSE)) {}
    [[NSRunLoop currentRunLoop] runMode:NSModalPanelRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  NSMutableArray *paths = [NSMutableArray array];
  if (response == GTK_RESPONSE_ACCEPT) {
    GListModel *files = gtk_file_chooser_get_files(chooser);
    for (guint i = 0; i < g_list_model_get_n_items(files); i++) {
      GFile *file = g_list_model_get_item(files, i);
      char *path = g_file_get_path(file);
      if (path) [paths addObject:[[NSFileManager defaultManager]
        stringWithFileSystemRepresentation:path length:strlen(path)]];
      g_free(path);
      g_object_unref(file);
    }
    g_object_unref(files);
  }
  gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(native));
  g_object_unref(native);
  return paths;
}

/* Both legacy document APIs and modern completion APIs pass through here.
 * Return exactly the path GTK confirmed, particularly for overwrite safety. */
#define NATIVE_PANEL_METHODS \
- (NSString *)filename { return _hasNativeResult ? (_fullFileName ?: @"") : [super filename]; } \
- (NSInteger)runModalForDirectory:(NSString *)path file:(NSString *)name { \
  return [self runModalForDirectory:path file:name relativeToWindow:nil]; \
} \
- (NSInteger)runModalForDirectory:(NSString *)path file:(NSString *)name relativeToWindow:(NSWindow *)window { \
  _hasNativeResult = NO; \
  if (!canUseNative(self)) return [super runModalForDirectory:path file:name relativeToWindow:window]; \
  NSArray *paths = choose(self, path ?: [self directory], name); \
  [self nativeSelection:paths]; _hasNativeResult = YES; \
  return [paths count] ? NSFileHandlingPanelOKButton : NSFileHandlingPanelCancelButton; \
} \
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(GSSavePanelCompletionHandler)handler { \
  _hasNativeResult = NO; \
  if (!canUseNative(self)) { [super beginSheetModalForWindow:window completionHandler:handler]; return; } \
  NSInteger result = [self runModal]; if (handler) handler(result); \
} \
- (void)beginWithCompletionHandler:(GSSavePanelCompletionHandler)handler { \
  _hasNativeResult = NO; \
  if (!canUseNative(self)) { [super beginWithCompletionHandler:handler]; return; } \
  NSInteger result = [self runModal]; if (handler) handler(result); \
} \
- (void)beginSheetForDirectory:(NSString *)path file:(NSString *)name modalForWindow:(NSWindow *)window modalDelegate:(id)delegate didEndSelector:(SEL)selector contextInfo:(void *)context { \
  _hasNativeResult = NO; \
  if (!canUseNative(self)) { [super beginSheetForDirectory:path file:name modalForWindow:window modalDelegate:delegate didEndSelector:selector contextInfo:context]; return; } \
  NSInteger result = [self runModalForDirectory:path file:name relativeToWindow:window]; \
  if (delegate && selector) { \
    void (*callback)(id, SEL, id, NSInteger, void *) = (void *)[delegate methodForSelector:selector]; \
    callback(delegate, selector, self, result, context); \
  } \
}

@implementation GTK4NativeSavePanel
- (void)nativeSelection:(NSArray *)paths
{
  ASSIGN(_fullFileName, [paths firstObject]);
  if ([paths count]) ASSIGN(_directory, [_fullFileName stringByDeletingLastPathComponent]);
}
NATIVE_PANEL_METHODS
@end

@implementation GTK4NativeOpenPanel
- (void)dealloc { [_nativePaths release]; [super dealloc]; }
- (void)nativeSelection:(NSArray *)paths
{
  ASSIGN(_nativePaths, paths);
  ASSIGN(_fullFileName, [paths firstObject]);
  if ([paths count]) ASSIGN(_directory, [_fullFileName stringByDeletingLastPathComponent]);
}
- (NSArray *)filenames { return _hasNativeResult ? _nativePaths : [super filenames]; }
- (NSArray *)URLs
{
  if (!_hasNativeResult) return [super URLs];
  NSMutableArray *urls = [NSMutableArray array];
  for (NSString *path in _nativePaths) [urls addObject:[NSURL fileURLWithPath:path]];
  return urls;
}
NATIVE_PANEL_METHODS
@end
