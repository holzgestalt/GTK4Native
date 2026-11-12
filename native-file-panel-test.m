#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <gtk/gtk.h>
#include <assert.h>

static gboolean cancelChooser(gpointer data)
{
  GListModel *windows = gtk_window_get_toplevels();
  for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
    GtkWindow *window = g_list_model_get_item(windows, i);
    if (GTK_IS_FILE_CHOOSER(window) && gtk_widget_get_visible(GTK_WIDGET(window))) {
      GtkWidget *accept = gtk_dialog_get_widget_for_response(GTK_DIALOG(window), GTK_RESPONSE_ACCEPT);
      assert(GTK_IS_BUTTON(accept));
      const char *label = gtk_button_get_label(GTK_BUTTON(accept));
      GtkFileChooserAction action = gtk_file_chooser_get_action(GTK_FILE_CHOOSER(window));
      GString *plain = g_string_new("");
      for (const char *c = label; c && *c; c++) if (*c != '_') g_string_append_c(plain, *c);
      BOOL german = g_strcmp0(g_getenv("FILE_PANEL_TEST_LANGUAGE"), "de") == 0;
      const char *expected = action == GTK_FILE_CHOOSER_ACTION_SAVE
        ? (german ? "Speichern" : "Save") : (german ? "Öffnen" : "Open");
      assert(g_strcmp0(plain->str, expected) == 0);
      g_string_free(plain, TRUE);
      *(BOOL *)data = YES;
      gtk_dialog_response(GTK_DIALOG(window), GTK_RESPONSE_CANCEL);
      g_object_unref(window);
      return G_SOURCE_REMOVE;
    }
    g_object_unref(window);
  }
  return G_SOURCE_CONTINUE;
}
int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"GSTheme": @"GTK4Native"}];
  [NSApplication sharedApplication];
  assert([[[GSTheme theme] className] isEqual:@"GTK4NativeTheme"]);
  NSArray *panels = @[[NSOpenPanel openPanel], [NSSavePanel savePanel]];
  for (NSSavePanel *panel in panels) {
    assert([[panel className] hasPrefix:@"GTK4Native"]);
    [panel setAllowedFileTypes:@[@"xml"]];
    NSLog(@"Panel %@ accessory %@ delegate %@", panel, [panel accessoryView], [panel delegate]);
    BOOL sawChooser = NO;
    g_timeout_add(25, cancelChooser, &sawChooser);
    assert([panel runModalForDirectory:@"/tmp" file:@"GlyphData.xml"] == NSCancelButton);
    assert(sawChooser);
    assert([[panel filename] length] == 0);
    if ([panel isKindOfClass:[NSOpenPanel class]])
      assert([[(NSOpenPanel *)panel URLs] count] == 0);
  }
  NSLog(@"Native open/save choosers displayed and cancelled successfully");
  [pool drain];
  return 0;
}
