# Native GTK integration rule

Keep GTK-specific code and compatibility mappings in this repository.
Applications and shared AppKit expose toolkit-neutral APIs and layout data;
they must not acquire GTK dependencies or implement provider-specific selectors.

Use a real GTK window and widget tree wherever possible. GTK owns standard
controls, containers, layout, input, scrolling, split dividers, backgrounds and
borders. Use actual `GtkPaned` and `GtkScrolledWindow` widgets and let GTK draw
them. AppKit drawing is reserved for content with no native GTK equivalent,
hosted inside custom GTK widget containers.
AppKit supplies initial hierarchy, constraints and model state. GTK performs
subsequent measurement and allocation; GTK layout/snapshot callbacks must not
call AppKit layout engines, resize methods or frame setters. Geometry readback
for source APIs happens after GTK's frame and never lays out native widgets.
Scrollbar visibility and autohiding are exclusively GTK's responsibility,
including initial layout before native-peer attachment. AppKit must not run
its autohide algorithm for this provider.
Window resizing also belongs to GTK: bypass AppKit split-delegate allocation
for native peers and map sidebar holding priorities to `GtkPaned` resize flags.
Whole-window scenes fill their viewport; do not enlarge and center them using
a previous allocation's minimum size, which can push the sidebar offscreen.
Keep these scenes as GTK fill overlays so native configure events allocate
them directly, independently of the fixed-coordinate AppKit fallback layer.
Window scenes propagate their native minimum through the overlay to GtkWindow
and its window-manager size hints. Split panes respect child minima. Native
container constraints preserve initially contained controls inside their bounds;
scroll views keep document extents separate from viewport minima. Only minimum
size propagates from a window scene, so enlarging it never locks in that size.
Do not draw window/control
backgrounds or borders in AppKit. Do not snapshot GTK widgets into AppKit to
simulate standard controls. This rule takes precedence over historical drawing
and fallback descriptions below.

> GTK4Native is now an application-linked static provider. AppKit contains no
> GTK4Native or GNUstep appearance classes. Build with
> `bash scripts/build-editglyphdata.sh`, or build the archive with
> `bash scripts/build-themes.sh GTK4Native` and link using
> `native/application-theme.make` / `scripts/theme-config.py GTK4Native --libs`.
> It inherits the external `native/GNUstep` provider for fallback drawing.
> Bundle installation and AppKit-theme build instructions below are historical.

# Native GTK4 widgets for GNUstep

Applications retain their AppKit APIs while the provider builds a live GTK
window and widget hierarchy. Standard controls, split panes and scroll
containers use native GTK widgets for rendering and interaction. AppKit custom
content is hosted inside GTK drawing widgets, with rasterization bounded to
the visible viewport. The source views retain application models, actions,
bindings and compatibility geometry. The theme supplies source API metrics and
colors; it does not paint scroll frames, scrollbars or split dividers.

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
| Push buttons | Live GtkButton/GtkToggleButton in native windows: images/titles, hover, press, focus, disabled/toggle states and Return default action; all 14 gallery bezel samples | Custom input/drawing overrides retain fallback; AppKit still assigns frames |
| Text fields | Full GTK frame/focus snapshots, native padding, transparent editor; custom colors fall back | Native editing, selection/caret styling, IME and accessibility integration |
| Colors | GTK symbolic colors mapped into AppKit's System palette | Live GTK setting changes, per-state text colors |
| Scaling | Cairo device scale and AppKit destination size; tested at 2x | Desktop fractional-scale validation |
| Window decoration | GTK top-level hosts for titled X11/XWayland windows; native titlebar controls and themed rounded frames | Native Wayland content backend; advanced window-style transitions |
| Checkboxes/radio matrices | Live GtkCheckButton indicators, off/on/mixed checkbox states, grouped NSMatrix radios, native input and original target/action senders | Non-radio matrices and custom cells |
| Switches/segments | Live GtkSwitch and linked native segment buttons; select-one, select-any, momentary and disabled segments | Segment popup menus and additional segment-style mappings |
| Combo boxes | Live editable GtkComboBoxText, native chevron/popup, items/data source, original sender/action | Custom/formatter-based text fields retain AppKit editing |
| Menus and choices | Live GtkDropDown for flat text NSPopUpButton selection menus, with selection bindings and item updates; real GTK dropdown/context/positioned menus on X11 | Pull-down/complex NSPopUpButton surfaces, native menubar hosting, Wayland attachment |
| Combo boxes, tooltips | AppKit fallback | GTK rendering or actual GTK popup surfaces |
| Scrollers | Whole GtkScrollbar snapshots, GTK thickness and thumb geometry, disabled/pressed states, GTK trough-click preference | Native GTK input/accessibility hosting, hover, overlay fading |
| Tables | Native GTK list/scroll widgets for supported one-column view-based tables and outlines, with translated compound row controls | Multicolumn/header tables and dedicated framework view adapters |
| Tabs | Live GtkStack with GtkStackSwitcher/GtkStackSidebar, persistent page peers and AppKit delegate/focus handling | Unsupported specialized page content retains fallback |
| Boxes | Live GtkFrame groups with titles/content margins and GtkSeparator | Custom colors/borders, borderless and bottom-title boxes retain fallback |
| Dialogs | GTK native Open/Save choosers, with portal support | Foreign parent-window attachment; printing integration |

Hosted button/selection controls use GTK rendering, input, focus, and accessibility;
the AppKit objects keep model state, bindings, target/action and initial layout inputs.
Text editing and other fallback controls still use their existing AppKit
implementations. This does not claim native coverage of all control families.

## Buttons & Selection gallery

Rebuild the gallery to link the updated static provider:

```bash
source env.sh
make -C examples/ControlGallery -j4
openapp ./examples/ControlGallery/ControlGallery.app
bash native/GTK4Native/scripts/test-buttons.sh
```

`GTK4NativeControls` automatically discovers supported controls in ordinary
window content, including controls inside AppKit scroll views and tab pages.
Its clipped native widgets belong to the GTK window content tree. Peers
follow visibility, scrolling, scale and geometry changes and are removed when
source views detach. Native table rows continue to use their own view bridges.
Supported custom application views use the GTK wrapper described below. Controls
with explicit context menus and unsupported families retain their existing behavior. Wheel input over native controls
continues to scroll their enclosing AppKit scroll view.

GTK4NativeView maps the gallery's button bezel variants onto ordinary GTK
buttons, with GTK circular/flat classes and symbolic help/disclosure icons
where appropriate. It does not reproduce macOS-specific bezel artwork. Checkboxes
follow the source cell's mixed-state cycle; radio matrices keep exclusive
selection. Native actions use the original AppKit control as sender and pass
through NSControl's binding/target-action path. Return activates the visible
enabled native default button even when a checkbox has keyboard focus; native
text entries keep their editing activation.

The dedicated suite uses real XTest pointer/keyboard events, tests all 14
bezels and selection families, programmatic state synchronization, scrolling,
detachment, resizing and teardown, and runs in light/dark, 2× and fractional
1.5× modes. It also runs the existing compound-view and native-window regressions.
Logs and actual host-window PNG captures are in `build/gtk4-buttons`.

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
AppKit. A common-mode timer now drains pending GDK events to follow desktop scale
changes, but full frame-clock animation and live GTK color/theme reloads remain
unsupported; restart after changing the GTK theme. GTK colors are captured at theme activation. Font/size
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
alternate or control key mappings retain AppKit tracking. The menu bar itself is still AppKit-hosted. Flat selection NSPopUpButton controls
now use live GtkDropDown widgets; pull-down and complex menus keep this existing
menu-tracking path. Native menu-bar hosting,
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

## Desktop scaling

GTK4Native now uses GDK's startup monitor scale as the default `GSScaleFactor`
for GNUstep's X11 backend. A desktop set to 200% therefore scales AppKit layout,
text, input coordinates and GTK snapshot resolution together. Explicit
`-GSScaleFactor` or saved application/global defaults take precedence. No desktop
preferences or global GNUstep defaults are written by the provider.

AppKit records the scale alongside saved window frames so restoring a window
saved at 100% retains its logical size at 200%. Legacy frames without scale
metadata are treated as 100%. GTK popup anchor sizes are converted from X11
pixels to GTK logical coordinates.

The provider polls GDK events through an AppKit common-mode timer and follows
live scale changes on GDK's first monitor. Existing windows retain their logical
content size while their pixel dimensions, layout and DPI description update.
Mixed-DPI transitions between individual monitors and fractional Wayland backing
scales are not implemented; this remains one integer scale for the process.

`live-scaling-test.m` installs programmatic constraints and changes GDK's X11 scale
1→2→1→2→1 in the same process. It verifies constrained geometry and resize reflow,
and the test script rejects negative-size warnings. EditGlyphData's live-scale
variant additionally exercises its actual XIB-loaded document window and its
decoded constraints.

`scaling-test.m` checks 100%, 200%, explicit overrides, window/view pixel geometry,
field-editor transparency, capture dimensions and saved-frame migration. The
normal test script runs these cases. To exercise EditGlyphData at 200%:

```sh
GDK_SCALE=2 XVFB_SCREEN=2560x2048x24 bash scripts/test-editglyphdata.sh
```

## GTK scenes and custom AppKit view wrappers

Supported complete window contents now use a single GTK scene, including nested
scroll views. Standard controls become GTK controls; custom application views
become GSAppKitWidget children. Each custom wrapper draws only its own drawRect:
content into a cached bitmap texture, then snapshots its native children above it.
GTK owns allocation, hit testing, clipping, scrolling, focus and event controllers.
There are no per-control X windows or moving holes within a complete native scene.
Custom views can still supply gtk4NativeWidget to provide their own GTK rendering.

Filling containers and unambiguous linear springs/struts arrangements of ordinary
NSViews use GtkBox. Constraint-only forms and table rows retain GtkConstraintLayout.
Initial frames determine stack order; no application marker classes or
provider-specific selectors are needed. AppKit frame
springs/struts become native equations, intrinsic preferences use GTK constraint
guides, and text baselines are translated through GTK font measurements. Native
control minima take precedence over undersized XIB slots. Solved geometry is
reflected to source views only after GTK finishes its frame, for coordinate
conversion and API calls. GTK measure, allocation and snapshot callbacks never
run AppKit layout or set source frames.
Initial springs/struts are preserved across scene replacement and reparenting;
partially reflected source geometry never becomes a new layout template.
The previous shadow NSViews and GNUstep solver have been removed from this path.

AppKit's generic GSNativeView peer API has no GTK or theme dependency. It routes
invalidation straight to a registered peer, suppresses duplicate backing-store
drawing and AppKit layout for owned views, and transfers programmatic focus to the
native widget. Ordinary providers keep their existing behavior without a peer.
Dirty-region queries remain meaningful inside native custom drawing. Printing and caching with an explicit non-window context retains the AppKit path.

GTK pointer/drag/key controllers translate events to the original custom responder.
A native child owns its own pointer sequence; the parent does not handle it again.
Responder code runs outside GTK callbacks so application tracking/modal loops can
continue pumping GTK. A generic native-event source lets a custom AppKit tracking
loop consume already-captured events without a second hit test or duplicate action.
Custom insertText: views receive GTK IM commits. Views detach/unregister immediately.

This is a supported-hierarchy integration, not a replacement for every AppKit
facility. Framework NSTextView, customized field-editor text fields, OpenGL views, rulers and unsupported table/standard
control families still need dedicated adapters and keep the mixed path. Custom
tracking-area details, drag-and-drop registration, full accessibility semantics,
and positioned marked-text composition are additional integration work. Custom
painting currently uses an offscreen bitmap context and uploads the cached texture
when dirty; it is not a direct Cairo graphics-port adapter.

`bash native/GTK4Native/scripts/test-custom-views.sh` checks full scenes with
custom parents/native children, pixel output and partial redraws, direct
invalidation with host synchronization disabled, mouse/drag/key/focus/text input,
nested AppKit tracking loops, scrolling, springs/struts resizing and teardown in
light/dark, 2× and fractional-scale modes. MouseCircle now links GTK4Native and
uses the custom wrapper without changing CircleView.

## GTK-owned scroll documents

A standard NSScrollView whose complete document hierarchy is supported now hosts
one GtkScrolledWindow and one native GTK document tree. This includes the
ControlGallery Buttons & Selection page. Passive NSView subclasses that only
change coordinate flipping are supported; drawing/input overrides, unsupported
controls, visible rulers and custom NSScrollView subclasses retain the mixed
AppKit path. The entire viewport is a GTK widget, including the gaps between controls.
Unadapted content draws in a custom GTK widget; no visible backend surface is used.

GTK handles scrolling, clipping, overlay scrollbars, wheel/kinetic input and
allocation of this tree in the same frame. Translated document constraints run
through GtkConstraintLayout, including frame-based positions expressed as native
constraints. The document path does not create shadow NSViews or use the GNUstep
layout solver. Native table-row translation now uses the same GTK constraint path. A fixed
row viewport keeps GtkListView sizing separate from the row constraint layout.
AppKit objects continue to supply model state, actions and bindings. Native scroll
adjustments mirror source clip bounds, and programmatic AppKit scrolling updates
GTK; neither requires repositioning individual controls. Geometry/structure changes
rebuild the document tree, with immediate invalidation on page replacement/detach.

`native-scroll-document-test.m` freezes host synchronization while sending real
wheel events, verifies GTK child movement and stable viewport allocations, and checks
that AppKit backing pixels cannot show through. It also checks programmatic scroll,
model/action, resize, replacement and detach across light/dark and display scales.
The compound-view suite separately exercises GTK constraint anchors and resizing.
Mixed documents still use individual hosted controls and AppKit scrolling, so the
new scrolling guarantee applies to complete supported document trees.

## Selection popups and nested scroll-view clipping

Plain, non-pull-down `NSPopUpButton` controls use a live `GtkDropDown`, including
the ControlGallery section selector. The GTK string model follows source titles,
item insertion/removal and enabled states. User selection goes through the menu
item's normal action route, preserving selected-index/tag/value bindings and the
original popup action sender. Programmatic updates are silent; resetting a
rejected disabled selection does not generate a second action. Popover-surface
events remain in GTK, and Return inside a popup does not activate the window's
default button. Separators, submenus, custom images and pull-down menus retain
the existing menu implementation. GNUstep's automatically attached arrow image
is not mistaken for a custom item image.

Native table/outline peers now use the same GTK clip container as standalone
controls. The GTK clip and input allocation follow the enclosing scroll
view's `visibleRect`, including clipping by outer scroll views. The contained
GtkScrolledWindow retains its full viewport allocation and gets a negative
offset when partially clipped, avoiding changes to its scroll page/selection
layout. Fully clipped or detached tables stop exposing native regions. Native
row population is also limited to the clipped viewport.

`bash native/GTK4Native/scripts/test-scroll-layout.sh` checks thin transparent
indicator rendering, source scroller interactions and nested table clipping in
light/dark, 2× and fractional 1.5× modes. Pixel sentinels outside the outer
viewport verify vertical and horizontal clipping. The button suite additionally
checks real dropdown mouse/keyboard selection, bindings, disabled choices and
model updates.

## Native split and scroll containers

Scroll views are live `GtkScrolledWindow` widgets, including their frame,
background, scrollbars, clipping, wheel input, overlay behavior and autohiding.
AppKit's requested scrolling axes configure GTK's policies. AppKit never runs
its autohide algorithm for this provider, including before peer attachment.
The theme paints no scroll-view frame, scrollbar or split-divider pixels.
Non-scrolling document axes follow the native viewport instead of imposing a
fixed document minimum on the pane.

Split views are live `GtkPaned` widgets containing their native child scenes;
more than two panes use a chain of paned widgets. GTK handles separator input,
layout and painting directly. AppKit's split/pane objects mirror geometry and
retain delegate constraints and programmatic position APIs. Native tables and
outlines are children of this GTK hierarchy, with stable models during dragging.
Only visible native rows need Objective-C templates; GTK's prefetched rows keep
lightweight placeholders.

Nib forms, native documents and table rows use GTK constraint layouts compiled
from their initial AppKit constraints and springs/struts. Radio matrices use
native GTK grids. These containers paint no background or border and do not
invoke the AppKit layout solver while resizing. Compatibility for legacy
background-only application views lives in the provider. Unmatched custom content
and rich text use GTK drawing widgets, rasterizing only their visible viewport.
GTK owns the surrounding standard containers and appearance.

`bash native/GTK4Native/scripts/test-live-resize.sh` exercises native GTK hit
testing, repeated real divider drags with host synchronization disabled, live
editor repaints, stable row models/templates, pane replacement, typing and
closing, in light/dark and at integer/fractional scales. It also verifies that
AppKit autohiding never runs before peer attachment. EditGlyphData's native-table
integration checks the actual application's `GtkPaned`, GTK list selection,
entry typing, resize and hidden backend window. The snapshot renderer remains
available for legacy fallback diagnostics; it does not draw native scroll or
split containers.

## Native alerts and automatic button rendering

On GTK 4.10 or newer, the optional GSTheme modal-alert hook routes
NSRunAlertPanel through GtkAlertDialog. NSDocument's unsaved-changes prompt uses
the dedicated per-document dialog described below. Save, Cancel, Don't Save and window dismissal retain the original AppKit
return codes and document-close logic. GTK supplies the alert widgets; the calling
application/GNUstep supplies the message and translated button text. Older GTK
versions and other themes retain AppKit alerts. NSAlert objects and sheets still
use their existing AppKit implementation. Native alerts currently have no foreign
AppKit parent attachment, as with the file chooser bridge.

Ordinary bordered NSButton push-button bezel styles use GTK rendering automatically
through the shared theme drawing hook, including legacy NeXT/push styles. Apps do
not need to replace their buttons. AppKit still owns their text, input and actions.
Circular, help, disclosure, borderless and icon-specific styles, plus checkboxes
and radio indicators, retain their specialized AppKit rendering.

The native alert regression exercises all three responses, window dismissal and
NSDocument close outcomes for cancellation, discard, failed save and successful
save, in light and dark GTK themes.

### Per-document save confirmation

Unsaved documents use a custom window made from standard GTK4 labels, boxes and
buttons, with a centered heading/message and equal-width Cancel, Discard, Save
actions. GTK's destructive-action and suggested-action classes supply the action
colors from the active theme. No libadwaita, custom CSS, document list or extra
quit-review alert is used. The message identifies the document. Quitting reviews
each document using the existing NSDocument save/close logic; cancellation and
failed saves stop closing. Other providers retain their existing review workflow.

The theme's dedicated document-alert hook uses AppKit return codes; the generic
alert hook remains separate. German translations of the new text live in the
GUI library's normal Localizable.strings resources. Set SAVE_ALERT_PREVIEW to a
PNG path when running native-alert-test to capture the GTK save window.

The save window keeps GTK client-side decorations enabled, with an empty hidden
custom titlebar to retain the compact layout. GTK supplies the corner shape and
shadow from the active theme, without a fixed CSS radius. On non-composited X11
displays GTK uses its solid frame fallback; composited desktops can use rounded
transparent corners. Both the Xvfb behavior and GNOME/XWayland appearance have
been checked.

GTK's stock CSD frame may round only the top corners. For the document-save
window we inspect GTK's rendered window background and mirror its themed top
radii onto the bottom corners using a window-local style provider. There is no
hard-coded radius, and other windows are unaffected. Preview regression checks
verify transparent bottom corners whenever the desktop supplies transparent top
corners.

## Native GTK window hosts

GTK4Native creates a real GtkWindow with a GtkHeaderBar and owns the complete
visible content tree. Native controls, lists and scroll documents are GTK
widgets in clipped containers. Remaining AppKit drawing, including text editors
and split dividers, is rendered into a custom GTK content widget. Its input and
IME controllers route events through the normal AppKit responder chain. There
is no mapped backend child window and no X11 shape cutout per widget.

The backend window remains unmapped for AppKit window-number, graphics-context
and configure-event compatibility. GTK owns composition, clipping, keyboard
focus, titlebar controls, shadows and the rounded frame. AppKit retains models,
actions, bindings, text editing and document lifecycle. Normal titled windows
use this on XGServer with an X11 GDK display. Borderless windows and unsupported
backends retain their existing path. `GTK4_NATIVE_WINDOWS=0` or `GTK_CSD=0`
selects that path explicitly; this does not make AppKit a Wayland client.

GSWindowDecorationView supplies optional ordering, placement, minimization and
focus hooks. The GTK provider synchronizes model geometry through backend
configure events, including decoration offsets and differing display scales.
Native close requests still call NSWindow.performClose:, preserving document
save cancellation. Transient parents, modal status, level hints, window opacity,
size constraints and minimize/restore state remain synchronized.

Split tracking synchronizes native allocations at AppKit's display boundary.
Window mouse/key input enters AppKit's normal event queue. A mouse-down handler
must not run inside a run-loop performer: its nested tracking loop would prevent
AppKit's autodisplay performers from running until the mouse is released.
The clipping containers apply explicit frame changes before the next GTK frame;
window, table and scroll backgrounds remain opaque while content repaints.
`bash scripts/test-live-resize.sh` checks table/outline, scroll and plain content
geometry, rendered alpha, repeated editor repaints while the divider is held,
real divider dragging, editor keyboard input and the
unmapped backend surface in light/dark, 2× and fractional display scales.

The current bridge targets normal titled windows on X11/XWayland. Full native
Wayland hosting, live decoration/font metric changes, dynamic transitions
between titled and borderless styles and complete fullscreen content-layout
integration remain separate work. The host uses one GDK display scale, matching
the existing provider's scaling model.

`native-window-test.m` exercises the GTK-owned surface, pointer/keyboard text
editing, frame geometry, resize, title updates, hide/show, one-shot backend
recreation, the actual GTK close button and AppKit close refusal. On a desktop
with a window manager, set `NATIVE_WINDOW_WM_TEST=1` to additionally exercise
maximize/restore and minimize/restore. Set `NATIVE_WINDOW_PREVIEW` to capture the
GTK native host, including AppKit drawing in its custom content widget. The desktop tests have passed on
GNOME/XWayland at 200%; EditGlyphData's startup and File→New regression also pass.

## Native header toolbars

The GTK top-level receives the AppKit application's icon through `_NET_WM_ICON`
and inherits the backend window's `WM_CLASS` so desktop launchers and task
switchers identify the application correctly. The icon is reapplied after GTK
maps the host, when GTK would otherwise install its own default icon.

Titled GTK4Native windows place supported toolbars in the GTK header bar using
real GtkButton, linked GtkToggleButton segments, and GtkSearchEntry widgets.
AppKit retains toolbar items, targets, action senders, validation and custom
control state. Button-view actions retain their original NSButton sender;
menu buttons use native GTK popup tracking. Standard separators and flexible
spaces are supported, and narrow headers provide an overflow action menu.
Headers with toolbar controls use GTK's normal header style; the decoration-only
style is restored when the toolbar is hidden. This avoids stacking decoration
padding on top of the controls' native vertical margins.
The GTK window controls remain in the header. Icon-only, label-only and
icon-and-label display modes are supported. GTK keeps the window title visible
in the center of the header, alongside the native toolbar controls.

Segmented controls and small toolbar items use GTK's normal icon size (16
logical pixels with Adwaita). Regular borderless buttons use larger artwork
(20 logical pixels with Adwaita), inset by 2 pixels on every side to preserve
the original 24-pixel icon footprint inside the same native button frame. NSImage
backing dimensions multiply the logical icon size once by the GTK display scale.
This preserves PDF detail and selects suitable bitmap representations before
creating the GTK texture. Display-scale changes regenerate the toolbar textures.
Standard template icons with direct equivalents use GTK's scalable symbolic
artwork in the native header: Add/Remove, Refresh and Stop (including freestanding
variants), Enter/Exit Full Screen, left/right navigation arrows and triangles,
icon/list views, locked/unlocked padlocks, and Bluetooth. These follow GTK's
foreground color in light and dark themes. Other images and templates whose
replacement is unavailable in the GTK icon theme retain the NSImage renderer.

Arbitrary custom views retain the AppKit toolbar below the titlebar. Native
header toolbars do not currently provide drag-and-drop customization. This uses
the existing X11/XWayland GTK host; disabling native window hosting retains the
ordinary AppKit toolbar. The native-window regression covers pointer activation,
original action senders, search keyboard input, segmented/button views, disabled
states, overflow, display modes, visibility and custom-view fallback transitions
in light/dark GTK themes and at 200% scale.

## Native compound table rows

Supported one-column, headerless, view-based tables and outlines now use a real
`GtkScrolledWindow` and `GtkListView`. Existing registered AppKit row prototypes
remain the source of the hierarchy, layout, bindings, and action senders. The
bridge translates ordinary NSView/NSTableCellView containers, read-only and
editable NSTextFields, NSImageViews, buttons, toggles, and checkboxes into real
GTK widgets. It does not capture AppKit row images. A GTK layout manager uses
GtkConstraintLayout for each container, with native GTK intrinsic sizes and
font baseline measurements. It preserves supported anchors,
dimensions, baselines, equalities/inequalities, constants, multipliers, and AppKit
constraint, hugging and compression priorities. Native font metrics can still
differ from macOS. GTK constraints are retained across row binding and width changes. The enclosing list supplies
row heights, so populating a placeholder does not change the scroll geometry.
Constraints between a container and its immediate children are supported,
including nested containers. Unsupported hierarchies keep the AppKit path.

GTK's list items are recycled. AppKit row prototypes and bindings are constructed
only for allocated visible items; GTK's offscreen prefetch placeholders stay
lightweight. Model reload, outline expansion/collapse, selection, activation,
programmatic scrolling, control properties, text bindings, and target/action are
bridged to the original Objective-C objects. Native entry editing updates the
original control and reversible value binding. Editable fields with formatters,
popup buttons, unsupported custom drawing, custom row backgrounds, and tables
with headers or multiple columns retain AppKit rendering. The current prototype
is intended for standard compound rows; it is not a complete native replacement
for every AppKit control or editing/delegate behavior.

Platform-specific custom content can implement `GTK4NativeCustomView` from
`GTK4NativeView.h` and return a new unparented GtkWidget from `gtk4NativeWidget`.
For example, return a GtkDrawingArea with a Cairo draw callback for custom
artwork. The bridge owns the widget and retains its Objective-C source view.
This also allows a compound cell to include platform drawing alongside translated
text fields, images, and buttons.

Native peers and the AppKit fallback widget share the GTK content container.
GTK handles their stacking and hit testing; the backend window stays unmapped.
Explicit peer allocations and AppKit display updates keep them together during
pane dragging. GTK and AppKit scales must agree before importing geometry or
rebuilding toolbars. Native positions include any AppKit menu above the content.

Set `GTK4_NATIVE_TABLES=0` before launching to select the existing AppKit table
path. Unsupported window hosts also use that path. The independent compound-view
regression checks real GTK widget types, translated layout and resize, NSImage
content, native text editing and bindings, Objective-C action senders, and a
platform drawing widget. The EditGlyphData native-table regression opens the
full GlyphData.xml, switches both row templates, resizes, injects real X11 clicks
and keyboard navigation, verifies native input and teardown, and moves the
window over a contrasting background to check for exposed windows underneath.

### Initialization before the display connection

The theme may be requested before `[NSApplication sharedApplication]` connects
to the display server. GTK4Native defers GTK/backend resources in that case and
does not query NSScreen from early activation. AppKit calls the generic
`GSTheme displayServerDidConnect` hook immediately after establishing its
GSDisplayServer, before creating the first graphics context or loading fonts.
The GTK provider then selects the matching GDK backend and publishes native
scale defaults. Explicit GTK backend and AppKit scale overrides still win.
This prevents the launch-time `Unable to retrieve list of screens from window
server` exception when a theme is initialized early. The regression requests
and activates the theme before NSApplication exists, then verifies connected
screens, backend choice, scaling and native window creation at 1x, 2x and an
explicit scale override. The standalone C renderer's initialization is unchanged.

### Keyboard focus between native controls and AppKit content

GTK owns focus for both native controls and the custom content widget used by
AppKit editors. The generic `focusNativeWindow` decorator hook prevents the
backend from focusing its unmapped window. `focusAppKitContent` selects the GTK
content widget while preserving AppKit's first responder and modal rules.

The native-window regression tests real toolbar-to-editor clicks and typing.
EditGlyphData's full-file regression also types in a detail field after native
sidebar navigation and after adding a glyph with the real native plus button,
and verifies programmatic refocusing of an already active AppKit field editor.

### Closing individual native windows

Desktop window managers list GTK hosts in `_NET_CLIENT_LIST_STACKING`, while
AppKit owns their unmapped backend windows. The backend's ordered-window list
can therefore omit all of the application's windows. NSApplication now decides
whether the last main window closed from its own window registry, counting
visible, miniaturized and application-hidden windows. It rechecks when the
delayed quit callback runs, so a newly opened window also prevents an obsolete
quit request. The existing delegate/default policy still applies after the
actual last main window closes.

EditGlyphData's native-close test installs this host-only stacking list under
Xvfb. Without it, a bare X server's fallback list masks the failure. The test
checks document isolation, close notifications, surviving mapped GTK hosts,
edited-document Discard, and actual last-window termination.

NSTabView uses GtkStack with GtkStackSwitcher (top/bottom) or GtkStackSidebar
(left/right). No-tab styles hide navigation. All page peers remain alive across
selection changes; native changes go through AppKit's should/will/did-select
delegate path, including vetoes. Page additions/removals replace the native
structure; label and selection changes synchronize in place.

Standard NSBox groups use GtkFrame, including live titles, content margins,
nested native controls and content-view replacement. Separators use
GtkSeparator. Custom-color/border boxes, borderless or bottom-title boxes, and
containers with unsupported specialized content retain their fallback adapter.
Run `bash scripts/test-containers.sh` for native input, delegate, layout,
scrolling and teardown checks at light/dark, 2× and fractional scales.

AppKit combo peers remove only GTK's default vertical minimum/padding, so
original 24-point UI/XIB frames retain their complete native borders, chevron
and popup. Transparent peer containers use their containing AppKit window/pane
background (including scroll backgrounds and explicit matrix fills), rather
than exposing a white GTK content-view backdrop.

Native combo editors and popup items use the NSComboBox font (family, style and
absolute size), including live font changes. AppKit point sizes convert once
to GTK logical units; Pango's additional point-to-DPI scaling is avoided.
Native editable text fields use the same font mapping.

GTK 4.18 compatibility: optional inequalities are translated to a nonnegative
slack guide plus a soft equality. This avoids the double unref in that version's
soft-inequality error-variable path while keeping measurement, solving and
allocation in GTK. See [GTK 4.18's solver](https://github.com/GNOME/gtk/blob/4.18.6/gtk/gtkconstraintsolver.c#L898)
and the corrected ownership in [upstream GTK](https://github.com/GNOME/gtk/blob/main/gtk/gtkconstraintsolver.c#L898).
