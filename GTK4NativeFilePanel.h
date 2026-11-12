#import <AppKit/AppKit.h>
@interface GTK4NativeOpenPanel : NSOpenPanel
{
  NSArray *_nativePaths;
  BOOL _hasNativeResult;
}
@end
@interface GTK4NativeSavePanel : NSSavePanel
{
  BOOL _hasNativeResult;
}
@end
