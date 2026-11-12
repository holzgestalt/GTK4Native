#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>

/* Explicitly select an unavailable GTK display while AppKit still uses Xvfb. */
int main(void)
{
  @autoreleasepool {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{@"GSTheme":@"GTK4Native"}];
    [NSApplication sharedApplication];
    GSTheme *theme = [GSTheme theme];
    NSCAssert([NSStringFromClass([theme class]) isEqualToString:@"GTK4NativeTheme"],
      @"exercise the theme's unavailable-GTK fallback");
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,200,24)];
    NSCAssert(![theme drawTextFieldCell:[field cell] frame:[field bounds] view:field],
      @"unavailable GTK declines drawing");
    NSCAssert(NSIsEmptyRect([theme textFieldContentRectForCell:[field cell] frame:[field bounds]]),
      @"unavailable GTK retains AppKit geometry");
    NSTextView *editor = [[NSTextView alloc] initWithFrame:[field bounds]];
    [[field cell] setUpFieldEditorAttributes:editor];
    NSCAssert([editor drawsBackground], @"unavailable GTK retains opaque editing");
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Fallback"];
    NSCAssert(![theme displayNativePopUpMenu:menu atScreenRect:NSZeroRect forWindow:nil],
      @"unavailable GTK declines native menus");
    [menu release]; [editor release]; [field release];
    NSLog(@"Unavailable GTK display passed: AppKit drawing, geometry, editing and menu fallback");
  }
  return 0;
}
