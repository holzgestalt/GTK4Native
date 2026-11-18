#import "GTK4NativeImages.h"
#import <Foundation/NSData.h>
#include <gtk/gtk.h>

static const struct { NSString *name; const char *icon; } symbols[] = {
  {@"NSAddTemplate", "list-add-symbolic"},
  {@"NSRemoveTemplate", "list-remove-symbolic"},
  {@"NSFollowLinkFreestandingTemplate", "go-jump-symbolic"},
  {@"NSRefreshTemplate", "view-refresh-symbolic"},
  {@"NSRefreshFreestandingTemplate", "view-refresh-symbolic"},
  {@"NSStopProgressTemplate", "process-stop-symbolic"},
  {@"NSStopProgressFreestandingTemplate", "process-stop-symbolic"},
  {@"NSEnterFullScreenTemplate", "view-fullscreen-symbolic"},
  {@"NSExitFullScreenTemplate", "view-restore-symbolic"},
  {@"NSGoLeftTemplate", "go-previous-symbolic"},
  {@"NSGoRightTemplate", "go-next-symbolic"},
  {@"NSLeftFacingTriangleTemplate", "pan-start-symbolic"},
  {@"NSRightFacingTriangleTemplate", "pan-end-symbolic"},
  {@"NSIconViewTemplate", "view-grid-symbolic"},
  {@"NSListViewTemplate", "view-list-symbolic"},
  {@"NSLockLockedTemplate", "changes-prevent-symbolic"},
  {@"NSLockUnlockedTemplate", "changes-allow-symbolic"},
  {@"NSBluetoothTemplate", "bluetooth-symbolic"},
  {@"NSTouchBarPlayTemplate", "media-playback-start-symbolic"},
  {@"NSTouchBarRecordStopTemplate", "media-playback-stop-symbolic"},
  {@"NSTouchBarPauseTemplate", "media-playback-pause-symbolic"},
  {@"NSTouchBarDeleteTemplate", "user-trash-symbolic"},
  {@"NSTouchBarSearchTemplate", "system-search-symbolic"},
  {@"NSTouchBarSidebarTemplate", "sidebar-show-symbolic"},
};

const char *GTK4NativeSymbolicIconForImage(NSImage *image)
{
  if(!image.isTemplate || !gdk_display_get_default()) return NULL;
  GtkIconTheme *theme=gtk_icon_theme_get_for_display(gdk_display_get_default());
  for(NSUInteger i=0;i<sizeof(symbols)/sizeof(symbols[0]);i++)
    if([image.name isEqual:symbols[i].name] && gtk_icon_theme_has_icon(theme,symbols[i].icon)) return symbols[i].icon;
  return NULL;
}

void GTK4NativeInstallTemplateImages(void)
{
  if(!gdk_display_get_default()) return;
  GtkIconTheme *theme=gtk_icon_theme_get_for_display(gdk_display_get_default());
  for(NSUInteger i=0;i<sizeof(symbols)/sizeof(symbols[0]);i++) {
    if([NSImage imageNamed:symbols[i].name] || !gtk_icon_theme_has_icon(theme,symbols[i].icon)) continue;
    GtkIconPaintable *icon=gtk_icon_theme_lookup_icon(theme,symbols[i].icon,NULL,16,1,
      GTK_TEXT_DIR_NONE,GTK_ICON_LOOKUP_FORCE_SYMBOLIC);
    GFile *file=gtk_icon_paintable_get_file(icon);
    GFileInputStream *stream=file?g_file_read(file,NULL,NULL):NULL;
    GdkPixbuf *pixels=stream?gdk_pixbuf_new_from_stream_at_scale(G_INPUT_STREAM(stream),16,16,TRUE,NULL,NULL):NULL;
    // This raster is only an AppKit resource/printing fallback. Hosted controls
    // keep live GtkImages, never snapshots of GTK controls.
    if(pixels) {
      gchar *png=NULL; gsize length=0;
      if(gdk_pixbuf_save_to_buffer(pixels,&png,&length,"png",NULL,NULL)) {
        NSImage *image=[[NSImage alloc] initWithData:[NSData dataWithBytes:png length:length]];
        [image setTemplate:YES]; [image setName:symbols[i].name];
        [image release]; g_free(png);
      }
      g_object_unref(pixels);
    }
    if(stream) g_object_unref(stream);
    g_object_unref(icon);
  }
}
