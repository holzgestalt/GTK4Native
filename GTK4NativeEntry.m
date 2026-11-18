#import <Foundation/NSObject.h>
extern Class GSThemeProvider_GTK4Native(void);
__attribute__((visibility("default")))
Class GSApplicationThemeClass(void)
{
  return GSThemeProvider_GTK4Native();
}
