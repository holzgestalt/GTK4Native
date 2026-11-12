#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>

static NSData *captureRect(NSView *view, NSRect rect)
{
  [view lockFocus];
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithFocusedViewRect:rect];
  [view unlockFocus];
  NSCAssert(bitmap != nil, @"Capture existing backing-store pixels without redrawing");
  NSData *data = [NSData dataWithBytes:[bitmap bitmapData]
                              length:[bitmap bytesPerRow] * [bitmap pixelsHigh]];
  [bitmap release];
  return data;
}

static BOOL focusOverlayChangesPixels(GSTheme *theme, NSButton *button)
{
  NSRect bounds = NSMakeRect(0, 0, 160, 36);
  NSImage *image = [[NSImage alloc] initWithSize:bounds.size];
  [image lockFocus];
  [[NSColor whiteColor] set];
  NSRectFill(bounds);
  NSBitmapImageRep *before = [[NSBitmapImageRep alloc] initWithFocusedViewRect:bounds];
  [theme drawFocusFrame:NSInsetRect(bounds, 4, 4) view:button];
  NSBitmapImageRep *after = [[NSBitmapImageRep alloc] initWithFocusedViewRect:bounds];
  NSData *a = [NSData dataWithBytes:[before bitmapData]
                           length:[before bytesPerRow] * [before pixelsHigh]];
  NSData *b = [NSData dataWithBytes:[after bitmapData]
                           length:[after bytesPerRow] * [after pixelsHigh]];
  BOOL changed = ![a isEqualToData:b];
  [before release];
  [after release];
  [image unlockFocus];
  [image release];
  return changed;
}

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  [[NSUserDefaults standardUserDefaults] registerDefaults:
    [NSDictionary dictionaryWithObjectsAndKeys:@"GTK4Native", @"GSTheme", nil]];
  [NSApplication sharedApplication];
  NSColor *windowColor = [[NSColor windowBackgroundColor] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
  NSCAssert(windowColor != nil, @"Theme colors must resolve");
  if ([[[[NSProcessInfo processInfo] environment] objectForKey:@"GTK_THEME"] hasSuffix:@":dark"])
    NSCAssert([windowColor redComponent] < 0.4, @"Dark GTK theme must supply a dark AppKit background");
  GSTheme *theme = [GSTheme theme];
  NSCAssert([NSStringFromClass([theme class]) isEqualToString:@"GTK4NativeTheme"],
            @"GTK4 theme must actually load, not silently fall back");
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 36)];
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(380, 160)];
  [image lockFocus];
  [[NSColor windowBackgroundColor] set];
  NSRectFill(NSMakeRect(0, 0, 380, 160));
  NSCAssert([theme drawTextFieldCell:[field cell] frame:NSMakeRect(20, 100, 340, 36)
                              view:field], @"Standard text field must use GTK rendering");
  [field setBackgroundColor:[NSColor redColor]];
  NSCAssert(![theme drawTextFieldCell:[field cell] frame:NSMakeRect(20, 100, 340, 36)
                               view:field], @"Custom colors must retain AppKit drawing");
  NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(200, 30, 160, 36)];
  [button setBezelStyle:NSRoundedBezelStyle];
  [button setTitle:@"GTK4 button"];
  // Draw cell explicitly at its destination in this offscreen image.
  [[button cell] drawWithFrame:NSMakeRect(200, 30, 160, 36) inView:button];
  [image unlockFocus];
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
  NSData *png = [bitmap representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]];
  NSCAssert([png writeToFile:@"/tmp/gnustep-gtk4-integration.png" atomically:YES], @"Capture must succeed");
  NSCAssert([[NSUserDefaults standardUserDefaults] boolForKey:@"GSSuppressAppIcon"],
            @"Native theme must suppress the separate GNUstep app-icon window");
  NSCAssert(![[NSApp iconWindow] isVisible], @"App icon must not float on the desktop");
  NSCAssert(NSInterfaceStyleForKey(@"NSMenuInterfaceStyle", nil) == NSWindows95InterfaceStyle,
            @"Theme must use the in-window menu layout");

  NSMenu *nativeMenu = [[NSMenu alloc] initWithTitle:@"Renderer test"];
  [nativeMenu setAutoenablesItems:NO];
  id firstItem = [nativeMenu addItemWithTitle:@"Open" action:NULL keyEquivalent:@"o"];
  [firstItem setEnabled:YES];
  [nativeMenu addItem:[NSMenuItem separatorItem]];
  id disabledItem = [nativeMenu addItemWithTitle:@"Unavailable" action:NULL keyEquivalent:@""];
  [disabledItem setEnabled:NO];
  NSMenuView *menuView = [[NSMenuView alloc] initWithFrame:NSMakeRect(0,0,240,100)];
  [menuView setHorizontal:NO];
  [menuView setMenu:nativeMenu];
  [menuView sizeToFit];
  [menuView setHighlightedItemIndex:0];
  NSMenuItemCell *menuCell = [menuView menuItemCellForItemAtIndex:0];
  NSCAssert(![theme drawsBorderForMenuItemCell:menuCell state:GSThemeHighlightedState isHorizontal:NO],
            @"GTK menu rows must not receive a GNUstep bevel");
  NSCAssert([theme menuItemHeight] >= 24 && [theme menuBarHeight] >= 24,
            @"Menu sizing must come from GTK widgets");
  NSImage *menuImage = [[NSImage alloc] initWithSize:[menuView bounds].size];
  [menuImage lockFocus];
  [menuView drawRect:[menuView bounds]];
  [menuImage unlockFocus];
  NSBitmapImageRep *menuBitmap = [NSBitmapImageRep imageRepWithData:[menuImage TIFFRepresentation]];
  [[menuBitmap representationUsingType:NSPNGFileType properties:@{}]
    writeToFile:@"/tmp/gnustep-gtk4-menu.png" atomically:YES];
  [menuImage release];
  [menuView release];
  [nativeMenu release];

  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 160)
    styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
  [window setReleasedWhenClosed:NO];
  [field setBackgroundColor:[NSColor textBackgroundColor]];
  [field setFrame:NSMakeRect(20, 60, 340, 34)];
  [[window contentView] addSubview:field];
  [button setFrame:NSMakeRect(200, 10, 160, 36)];
  [[window contentView] addSubview:button];
  [field setNextKeyView:button];
  [button setNextKeyView:field];
  [window makeKeyAndOrderFront:nil];
  [window makeFirstResponder:field];
  [window display];
  NSText *editor = [field currentEditor];
  NSCAssert(editor != nil, @"Exercise a real active field editor");
  NSCAssert(![editor drawsBackground], @"Editor must not cover the GTK background");
  NSCAssert([[editor superview] isKindOfClass:[NSClipView class]], @"Editor uses a clip view");
  NSCAssert(![(NSClipView *)[editor superview] drawsBackground], @"Clip view must be transparent too");
  NSCAssert(![[field cell] isOpaque], @"GTK rounded corners must retain background transparency");
  NSRect content = [[field cell] titleRectForBounds:[field bounds]];
  NSCAssert(content.origin.x > 5 && content.size.height < 32,
            @"Native GTK padding and vertical centering must be used");
  NSBitmapImageRep *focused = [field bitmapImageRepForCachingDisplayInRect:[field bounds]];
  [field cacheDisplayInRect:[field bounds] toBitmapImageRep:focused];
  [[focused representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]]
    writeToFile:@"/tmp/gnustep-gtk4-focused.png" atomically:YES];
  NSEvent *tab = [NSEvent keyEventWithType:NSKeyDown location:NSZeroPoint modifierFlags:0
    timestamp:0 windowNumber:[window windowNumber] context:nil
    characters:@"\t" charactersIgnoringModifiers:@"\t" isARepeat:NO keyCode:23];
  [window sendEvent:tab];
  NSCAssert([window firstResponder] == button, @"Tab must move focus from entry to button");
  [window displayIfNeeded];
  NSCAssert(!focusOverlayChangesPixels(theme, button),
            @"GTK buttons must not receive a second AppKit dotted focus indicator");
  [button setBezelStyle:NSShadowlessSquareBezelStyle];
  NSCAssert(focusOverlayChangesPixels(theme, button),
            @"Buttons using AppKit fallback must retain their focus indicator");
  [button setBezelStyle:NSRoundedBezelStyle];
  NSData *afterTab = captureRect([window contentView], [field frame]);
  [[window contentView] setNeedsDisplay:YES];
  [window displayIfNeeded];
  NSData *cleanBlurred = captureRect([window contentView], [field frame]);
  NSCAssert([afterTab isEqualToData:cleanBlurred],
            @"Tab must remove the entire focus outline without needing a forced repaint");
  [window makeFirstResponder:nil];
  [window orderOut:nil];

  [GSTheme setTheme:[GSTheme loadThemeNamed:@"GNUstep"]];
  NSCAssert([GSTheme theme] == theme, @"Runtime switching must retain the built-in provider");
  [window release];

  NSLog(@"GTK4 checks passed: theme load, custom-color fallback, hidden app icon, in-window menus, active editor transparency, native padding, fixed build-time provider");
  [button release];
  [image release];
  [field release];
  [pool drain];
  return 0;
}
