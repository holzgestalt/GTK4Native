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
and GTK4 development headers. The tests additionally require Xvfb/xvfb-run.
Tests build into the ignored `build/tests/` directory by default; override it
with `GTK4_TEST_BUILD_DIR=/absolute/path`. Installation uses the active GNUstep
prefix's theme directory; root access depends on that prefix's permissions.
The workspace prefix used here is writable without root.

The plugin requires these local `libs-gui` commits, or equivalent changes:

- `bb3a532e9`: preserve field-editor transparency in clip views.
- `d956428e8`: add text-field drawing and content-geometry theme hooks.
- `dbb650ddc`: repaint the full text field when editing ends.

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
| Combo boxes, menus, tooltips | AppKit fallback | GTK rendering or actual GTK popup surfaces |
| Scrolling, tables, tabs | AppKit fallback | GTK parts, focus/navigation and content integration |
| Dialogs | AppKit fallback | Desktop portals for file selection; printing integration |

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

The changes span five files in `src/libs-gui`, with no GTK dependency added to
libs-gui itself. The theme requires this patched library; rebuild/install
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
