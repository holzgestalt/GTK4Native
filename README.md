# GTK4 control drawing for GNUstep

This is the first working part of a GTK4 platform integration. GNUstep
applications continue to use NSButton and NSTextField. A GSTheme subclass asks
GTK4 to render their frames/backgrounds using its selected GTK theme. These are
GTK-rendered control surfaces, not embedded GTK widgets. No replica CSS, theme
images, or hand-picked widget colors are used.

## Standalone repository build

This directory is an independent Git repository. With a patched GNUstep GUI
installation activated in your shell, build and install the theme with:

```bash
# First source the GNUstep.sh for your installation.
pkg-config --modversion gtk4
make
make install
bash scripts/test.sh
```

Dependencies: GNUstep Make/Base/GUI, libobjc2 for this setup, Clang, pkg-config,
GTK4 with its X11 development interfaces, and Xext/Shape headers. The tests
additionally require Xvfb/xvfb-run and libXtst.so.6 for injected input.
Tests build into the ignored `build/tests/` directory by default; override it
with `GTK4_TEST_BUILD_DIR=/absolute/path`. Installation uses the active GNUstep
prefix's theme directory; root access depends on that prefix's permissions.
The workspace prefix used here is writable without root.

The plugin requires these local `libs-gui` commits, or equivalent changes:

- `bb3a532e9`: preserve field-editor transparency in clip views.
- `d956428e8`: add text-field drawing and content-geometry theme hooks.
- `dbb650ddc`: repaint the full text field when editing ends.

Real native menus additionally require the optional GSTheme menu-tracking and
positioned-popup hooks described below.
The plugin will not work correctly with an unpatched stock GNUstep GUI library.
The following instructions describe the surrounding development workspace;
its setup scripts, core checkouts and sample apps are separate from this repo.

## Build and run

From `/home/georg/Code/gnuStep`, after the core GNUstep stack is built:

```bash
bash scripts/build-gtk4.sh
source env.sh
openapp ./examples/HelloGNUstep/HelloGNUstep.app
```

GTK4Native is installed under the workspace prefix. The sample selects it via
application-local registration defaults, so other apps remain unchanged. Any
application using this patched libs-gui can opt in with `-GSTheme GTK4Native`.
Use `-GSTheme GNUstep` to compare. For a reproducible dark-theme check:

```bash
GTK_THEME=Adwaita:dark openapp ./examples/HelloGNUstep/HelloGNUstep.app
```

Without GTK_THEME, GTK chooses its configured theme. GTK4 is not a universal
Linux control API: KDE/Qt matching still requires a matching GTK theme or a
future Qt platform provider. libadwaita styling is separate from plain GTK4.

## Current coverage

| Area | Implemented | Still needed |
| --- | --- | --- |
| Push buttons | GTK background/frame, pressed, disabled and keyboard-focus flags | Hover tracking, native metrics, default action, custom bezels |
| Text fields | Full GTK frame/focus snapshots, native padding, transparent editor; custom colors fall back | Native editing, selection/caret styling, IME and accessibility integration |
| Colors | GTK symbolic colors mapped into AppKit's System palette | Live GTK setting changes, per-state text colors |
| Scaling | Cairo device scale and AppKit destination size; tested at 2x | Desktop fractional-scale validation |
| Window decoration | Desktop/X11 window manager | Native Wayland backend |
| Checkboxes/radio buttons | AppKit fallback | GTK indicator rendering and state mapping |
| Sliders/progress/steppers | AppKit fallback | GTK renderers, measurements and interaction states |
| Menus | Real GTK dropdown/context/positioned menus on X11, with native layout, text, checkmarks, separators and nested submenus; menu bar surfaces use snapshots | Native menubar hosting, Wayland attachment, NSPopUpButton lifecycle |
| Combo boxes, tooltips | AppKit fallback | GTK rendering or actual GTK popup surfaces |
| Scrolling, tables, tabs | AppKit fallback | GTK parts, focus/navigation and content integration |
| Dialogs | GTK native Open/Save choosers, with portal support | Foreign parent-window attachment; printing integration |

The sample's label and text, control events, field editor, keyboard navigation,
layout and accessibility remain AppKit implementations. No claim of native GTK
input semantics or full basic-control coverage is made yet.

## GNUstep change

The existing GSTheme button hook is reused. NSTextFieldCell previously drew its
own background after its superclass's border drawing, preventing a theme from
rendering a complete entry frame. The optional `drawTextFieldCell:frame:view:`
hook returns YES if handled; otherwise the original drawing path runs.
`textFieldContentRectForCell:frame:` supplies GTK padding and centered content
bounds; returning NSZeroRect retains stock geometry and opaque editing. Native
fields use a transparent field editor and report nonopaque rounded corners.
NSCell now preserves the editor's background transparency in its enclosing
NSClipView, preventing the clip from obscuring the native background.
NSTextField invalidates the full control when its editor is removed, clearing
native focus outlines outside the editor's content rectangle on Tab/blur.

The drawing and menu hooks add no GTK dependency to libs-gui itself. The theme requires this patched library; rebuild/install
libs-gui before loading it. The controls do not require application-specific
subclasses or swizzling. The build script prefers source headers to previously
installed headers when compiling new theme APIs.

The theme's GSThemeDomain selects in-window menus, desktop-drawn decorations and
GSSuppressAppIcon. The last setting hides GNUstep's separate application-icon
window, which is distinct from the application's menu.

## Rendering implementation and limits

GTK4Renderer owns real GTK button and entry objects in a custom offscreen
GtkWindow subclass. The host uses the generic GtkWidget show/map lifecycle,
without GtkWindow's native-surface presentation. Its in-memory widget tree is
mapped so GTK can snapshot it; its GdkSurface remains unmapped. The renderer
allocates each control, calls gtk_widget_snapshot_child, and draws the resulting
GskRenderNode to Cairo. Full widget snapshots include native CSS outlines that
the earlier gtk_render_background/frame/focus path omitted. No private GTK
symbols are used. Style-context APIs still supply padding and symbolic colors;
those particular APIs are deprecated in GTK 4.10 and remain a future maintenance
consideration.

The Cairo result is transferred into AppKit through an in-memory PNG; a cache or
pixel-buffer bridge is needed before production use. GTK resources are accessed
on AppKit's main thread. GTK animations are disabled in the GNUstep process so
snapshot states take effect immediately; without a running frame clock they
could stay at the starting frame. GTK's GLib loop is not yet integrated with
AppKit, so live settings changes and animations are not supported; restart after
changing themes. GTK colors are captured at theme activation. Font/size
overrides are still controlled by AppKit/the app.

The current GNUstep backend remains X11/XWayland. GTK4 drawing alone does not
make GNUstep a native Wayland client. Embedding actual GTK4 controls requires a
GTK-owned window/view hierarchy and coordinated input, focus, lifecycle and
accessibility, rather than the old GtkSocket/GtkPlug embedding approach removed
in GTK4.

## Validation

```bash
bash scripts/test-gtk4.sh
```

Renderer checks exercise nonempty output, distinct normal/pressed/disabled
button states, distinct focused/unfocused entry surfaces, 2x entry dimensions,
invalid sizes and an unmapped native host surface.
AppKit checks assert actual loading of GTK4NativeTheme, the new text-field hook,
custom-background fallback, a dark AppKit background under Adwaita:dark,
application-icon suppression, in-window menus, a real active field editor and
clip view remaining transparent, native padding, and stock-theme fallback.
A real Tab key event moves focus to the button; backing-store pixels immediately
after the normal dirty-region repaint must equal those from a clean redraw.
This regression failed before the full-field invalidation fix and passes in
both light and dark modes.
Both suites run under Adwaita light/dark with Xvfb. The integration preview is
written to `/tmp/gnustep-gtk4-integration.png`. Real desktop interaction,
accessibility, live settings and fractional scaling still need validation.

References:
- https://docs.gtk.org/gtk4/migrating-3to4.html
- https://docs.gtk.org/gtk4/func.render_background.html
- https://docs.gtk.org/gtk4/class.WidgetPaintable.html

## Matched window-decoration comparison

Close both existing sample processes, then run:

```bash
bash /home/georg/Code/gnuStep/scripts/compare-apps.sh
```

This launches both applications with GDK_BACKEND=x11 and GTK_CSD=0, matching the
current GNUstep X11 backend and using desktop-drawn title bars for both. It
preserves the configured GTK theme. Running the GTK executable directly retains
GTK's normal backend/decoration choices (often Wayland with GTK-drawn title bars
on GNOME); those can differ in title-bar color and radius despite both being
legitimate native decoration styles. The comparison launcher does not change
system settings or the reference app's normal defaults.

## Development findings

See [LEARNINGS.md](docs/LEARNINGS.md) for setup discoveries, the snapshot-host
approach, editor transparency, the Tab repaint regression, and suppression of
duplicate AppKit focus indicators on GTK-drawn buttons.

## Menu snapshots and XIB field defaults

Menus use GtkPopoverMenu-generated contents/model-button rows and a real
GtkPopoverMenuBar. A non-native snapshot host preserves the popover CSS node
name and GTK-supplied classes while hosting the generated contents. The contents
are returned to their original popover before cleanup. No custom CSS or hand-drawn
menu bevels are used. Snapshots cover normal backgrounds, highlighted rows and
separators for the AppKit-hosted bar and fallback menus. AppKit retains labels,
shortcuts and tracking on those fallback paths; native dropdowns use the bridge
below. Snapshot tests check GTK-derived dimensions and that the snapshot host
presents no helper surface.
This uses GTK's generated widget tree and needs validation on other GTK versions.

The shared GNUstep XIB decoder now defaults a bezeled entry's omitted
NSDrawsBackground value to YES, only for NSTextFieldCell subclasses. Explicit NO
remains transparent, other cell classes are unaffected, and labels remain
transparent. This fixes EditGlyphData's Group, Description and Decompose entries
without changing the original XIBs or allowing the theme to override intentional
transparent/custom-colored fields.

## Real GTK popup menus on X11

GTK4NativeMenu now converts NSMenu trees into GMenu/GSimpleAction trees and
presents a real GtkPopoverMenu (with nested submenus). This path supplies GTK's
actual text, spacing, indicators, separators, tracking and keyboard navigation.
Menu actions are sent through NSMenu.performActionForItemAtIndex: after GTK's
input grab and popup windows have been destroyed, preserving the original target,
sender, notifications and popup selection behavior. Escape/outside dismissal does
not dispatch an action. AppKit tracking-mode timers continue while GLib runs.

The patched GSTheme API adds optional trackMenuView:withEvent: and
displayNativePopUpMenu:atScreenRect:forWindow: hooks. Stock themes return NO.
NSMenuView consults the tracker before taking its AppKit mouse grab; explicitly
positioned NSMenu popups consult the second hook before showing an AppKit window.
The GTK theme also handles context menus directly.

The positioning bridge currently needs X11: an unmanaged, empty-shaped GTK anchor
positions the real GdkPopup beside the AppKit window using the owning X11 client
window coordinates. It does not rely on compositor opacity or WM placement. The
bridge verifies the AppKit backend is XGServer before interpreting opaque backend
handles, and requires an X11 GDK display plus the X Shape extension. The theme
prefers X11 only when AppKit uses X11, GTK has no display yet and GDK_BACKEND is
unset; the standalone renderer never selects a backend. Explicit GDK_BACKEND
settings still win. Unsupported backends/displays and customized GNUstep command,
alternate or control key mappings retain AppKit tracking. The menu bar itself is still AppKit-hosted and standard
NSPopUpButton controls retain their existing lifecycle. Native menu-bar hosting,
Wayland foreign-window attachment and full live menu-model synchronization remain
separate work.

Tests use libXtst.so.6 (Debian package libxtst6, test-only) to send actual X11
keyboard and pointer events through the installed theme's GNUstep hooks. They
verify a real mapped GTK popup, keyboard/pointer selection, Escape cancellation,
nested submenu navigation, explicitly positioned menus, action dispatch after
cleanup, and AppKit timers. Both Adwaita light and dark pass.

The bridge waits for the anchor's GdkSurface to map before opening the popup and
keeps X input focus on the owning AppKit window. The helper is mapped without
requesting desktop activation; it receives menu keyboard input through a grab
instead of becoming the focused toplevel. Tests must not repair popup focus. The app regression
`GNUstep/menu-click-test.m` sends a real XTest click to File in the actual XIB-loaded
window, then selects New through GTK and checks that a second document exists.
It runs with the app startup suite. This regression was also run on the GNOME/
XWayland desktop, where the panel makes NSScreen.frame differ from the X11 root
height; the bridge and test use owner-relative X11 coordinates instead.

The repeated-open regression runs with GTK4_MENU_FOCUS_TEST=1. It opens File,
dismisses it with Escape, verifies that tracking has returned to the default
run-loop mode and that X focus is still the owning app window, then repeats this
three times. This is included in scripts/test-editglyphdata.sh and has also passed
on GNOME/XWayland. The old helper-focus/restore-previous-window implementation
failed this desktop check by returning focus to another application.

### Opening-click and menu-bar handoff

The press which opens a menu leaves an implicit pointer grab on GNUstep's X11
connection. GTK uses a different connection. Before presenting the popover, the
bridge now releases the AppKit-side grab through GSDisplayServer.releasemouse and
synchronizes that connection. GTK then owns its complete seat-grab lifecycle; an
additional independent XGrabKeyboard is no longer layered on top of GTK.

The app click regression can hold the opening button for a realistic interval
(GTK4_MENU_PRESS_MS=150). Instant press/release pairs previously hid this failure.
Held-click coverage now includes File, Edit, Window and Help. The test activates
its own window so an overlapping instance cannot receive the injected input.

Clicks on another bar heading while a popup is open are handled in the same
tracking interaction: after GTK dismisses the current popup, the bridge checks the
bar hit and opens the next menu instead of relying on cross-connection event
replay. Keyboard dismissal is tracked separately so Escape cannot reopen a menu
just because the pointer rests over another heading. GTK4_MENU_SWITCH_TEST=1
checks File-to-Edit switching against the actual GTK model's first item title,
then Escape with the pointer moved back over File. Both new regressions are in
scripts/test-editglyphdata.sh and have passed on GNOME/XWayland.

## Shared GNUstep compatibility audit

The default drawing/content hooks return NO/NSZeroRect and the native-menu hooks
return NO. Existing GSTheme subclasses inherit AppKit behavior. No GTK or X11
dependencies, theme selection or platform defaults are added to the shared GUI
library, and libs-back is unchanged. Explicit text-field colors/transparency and
unsupported controls retain AppKit drawing.

The workspace's `scripts/test-gnustep-compatibility.sh` runs 29 stock-theme
executables with 169 assertions, including existing menu, toolbar, split-view,
XIB and table-cell regressions plus accepting/declining custom themes. Tests use
isolated defaults. `scripts/test-editglyphdata.sh` also starts the complete app
with `-GSTheme GNUstep` and verifies the original field drawing path.

Theme tests cover light/dark Adwaita, an unavailable explicit GTK display,
automatic X11 selection and fallback for custom physical modifier mappings.
Other GNUstep backends and third-party theme bundles have not been run here;
native Wayland menus, live model updates and complete accelerator customization
remain future work. See the workspace's LEARNINGS.md for the consolidated audit
and build commands.

## Native file selection

The theme supplies NSOpenPanel/NSSavePanel subclasses through the existing
GSTheme class hooks. GtkFileChooserNative selects a desktop portal where
available, otherwise GTK displays its file chooser. File filters, initial
directory/name, multiple files and folder selection are supported. GTK confirms
overwrites; the bridge returns the exact confirmed path without adding an
extension afterward. Suggested save names receive the default extension.

Accessory views, delegates, mixed file/folder selection and explicit hidden-file
display retain GNUstep panels. Completion and legacy sheet callbacks currently
run after a blocking native modal interaction. Foreign AppKit parent-window
attachment is not implemented yet. Tests isolate the session bus so a portal
cannot open a dialog outside the temporary X display.
