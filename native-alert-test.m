#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#include <gtk/gtk.h>
#include <assert.h>

@interface GSTheme (ButtonCoverageTest)
- (BOOL)handlesButtonStyle:(int)style;
@end

static const char *wanted;
static BOOL sawDialog;
static GtkWidget *findButton(GtkWidget *widget)
{
  if (GTK_IS_BUTTON(widget) && g_strcmp0(gtk_button_get_label(GTK_BUTTON(widget)), wanted) == 0)
    return widget;
  for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
       child = gtk_widget_get_next_sibling(child)) {
    GtkWidget *button = findButton(child);
    if (button) return button;
  }
  return NULL;
}
static gboolean respond(gpointer unused)
{
  GListModel *windows = gtk_window_get_toplevels();
  for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
    GtkWindow *window = g_list_model_get_item(windows, i);
    if ((GTK_IS_DIALOG(window) || gtk_widget_has_css_class(GTK_WIDGET(window), "document-save-dialog")) && gtk_widget_get_visible(GTK_WIDGET(window))) {
      if (gtk_widget_has_css_class(GTK_WIDGET(window), "document-save-dialog")) {
        assert(gtk_window_get_decorated(window));
        assert(gtk_window_get_titlebar(window) != NULL);
        assert(!gtk_widget_get_visible(gtk_window_get_titlebar(window)));
        GtkWidget *box = gtk_window_get_child(window);
        GtkWidget *row = gtk_widget_get_last_child(box);
        GtkWidget *first = gtk_widget_get_first_child(row);
        GtkWidget *second = gtk_widget_get_next_sibling(first);
        GtkWidget *third = gtk_widget_get_next_sibling(second);
        assert(g_strcmp0(gtk_button_get_label(GTK_BUTTON(first)), "Cancel") == 0);
        assert(g_strcmp0(gtk_button_get_label(GTK_BUTTON(second)), "Discard") == 0);
        assert(g_strcmp0(gtk_button_get_label(GTK_BUTTON(third)), "Save") == 0);
        assert(gtk_widget_has_css_class(second, "destructive-action"));
        assert(gtk_widget_has_css_class(third, "suggested-action"));
        const char *preview = g_getenv("SAVE_ALERT_PREVIEW");
        static BOOL captured = NO;
        if (preview && !captured && gtk_widget_get_width(GTK_WIDGET(window)) > 0) {
          GdkPaintable *paintable = gtk_widget_paintable_new(GTK_WIDGET(window));
          GtkSnapshot *snapshot = gtk_snapshot_new();
          gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snapshot),
            gtk_widget_get_width(GTK_WIDGET(window)), gtk_widget_get_height(GTK_WIDGET(window)));
          GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
          if (node) {
            GdkTexture *texture = gsk_renderer_render_texture(gtk_native_get_renderer(GTK_NATIVE(window)), node, NULL);
            // If this desktop supplies transparent top corners, the bottom
            // corners must match. Non-composited GTK solid frames stay valid.
            int width = gdk_texture_get_width(texture), height = gdk_texture_get_height(texture);
            gsize stride = width * 4;
            guchar *pixels = g_malloc(stride * height);
            gdk_texture_download(texture, pixels, stride);
            int alpha = G_BYTE_ORDER == G_LITTLE_ENDIAN ? 3 : 0;
            if (pixels[alpha] == 0) {
              assert(pixels[(height - 1) * stride + alpha] == 0);
              assert(pixels[(height - 1) * stride + (width - 1) * 4 + alpha] == 0);
              assert(pixels[(height / 2) * stride + (width / 2) * 4 + alpha] == 255);
            }
            g_free(pixels);
            captured = gdk_texture_save_to_png(texture, preview);
            g_object_unref(texture);
            gsk_render_node_unref(node);
          }
          g_object_unref(paintable);
        }
      }
      GtkWidget *button = wanted ? findButton(GTK_WIDGET(window)) : NULL;
      if (!wanted || button) {
        sawDialog = YES;
        if (button) g_signal_emit_by_name(button, "clicked");
        else gtk_window_close(window);
        g_object_unref(window);
        return G_SOURCE_REMOVE;
      }
    }
    g_object_unref(window);
  }
  return G_SOURCE_CONTINUE;
}
static void selectChoice(const char *label)
{
  wanted = label;
  sawDialog = NO;
  g_timeout_add(30, respond, NULL);
}
@interface TestDocument : NSDocument
{
@public
  BOOL saveSucceeds;
  BOOL saveCalled;
}
@end
@implementation TestDocument
+ (NSArray *)readableTypes { return @[@"public.xml"]; }
- (NSString *)displayName { return @"GlyphData.xml"; }
- (void)saveDocument:(id)sender
{
  saveCalled = YES;
  if (saveSucceeds) [self updateChangeCount:NSChangeCleared];
}
@end
int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [NSUserDefaults setUserLanguages:@[@"English"]];
  [NSApplication sharedApplication];
  assert([[[GSTheme theme] name] isEqual:@"GTK4Native"]);
  const char *labels[] = {"Save", "Cancel", "Don't Save", NULL};
  NSInteger results[] = {NSAlertDefaultReturn, NSAlertAlternateReturn, NSAlertOtherReturn, NSAlertAlternateReturn};
  for (int i = 0; i < 4; i++) {
    selectChoice(labels[i]);
    NSInteger result = NSRunAlertPanel(@"Unsaved changes", @"Save changes to %@?", @"Save", @"Cancel", @"Don't Save", @"GlyphData.xml");
    assert(sawDialog && result == results[i]);
  }
  for (int i = 0; i < 4; i++) {
    TestDocument *doc = [TestDocument new];
    [doc updateChangeCount:NSChangeDone];
    doc->saveSucceeds = (i == 3);
    selectChoice(i == 0 ? "Cancel" : i == 1 ? "Discard" : "Save");
    BOOL closes = [doc canCloseDocument];
    assert(sawDialog);
    assert(closes == (i == 1 || i == 3));
    assert(doc->saveCalled == (i >= 2));
    [doc release];
  }
  // Quitting reviews a dirty document directly, without the old extra alert.
  NSDocumentController *controller = [NSDocumentController new];
  TestDocument *doc = [TestDocument new];
  [doc updateChangeCount:NSChangeDone];
  [controller addDocument:doc];
  selectChoice("Cancel");
  assert(![controller reviewUnsavedDocumentsWithAlertTitle:@"Quit" cancellable:YES]);
  assert(sawDialog && [doc isDocumentEdited]);
  selectChoice("Discard");
  assert([controller reviewUnsavedDocumentsWithAlertTitle:@"Quit" cancellable:YES]);
  assert(sawDialog && !doc->saveCalled);
  [controller removeDocument:doc];
  [doc release];
  [controller release];
  GSTheme *theme = [GSTheme theme];
  for (int style = NSRoundedBezelStyle; style <= NSRoundRectBezelStyle; style++) {
    if (style == NSDisclosureBezelStyle || style == NSCircularBezelStyle || style == NSHelpButtonBezelStyle) continue;
    assert([(id)theme handlesButtonStyle:style]);
  }
  NSLog(@"Native GTK alerts passed: all choices, dismissal, cancelled/failed/successful save and push-button styles");
  [pool drain];
  return 0;
}
