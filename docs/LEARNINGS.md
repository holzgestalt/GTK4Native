> These findings describe the surrounding GNUstep development workspace.
> This copy is included with the GTK4Native repository for reference; workspace
> setup scripts and sample apps are maintained outside this repository.

# GNUstep and GTK4 integration findings

Recorded 11 November 2026. These notes capture what we observed while building
this workspace and comparing the GNUstep sample with a standalone GTK4 app.
The current implementation is an experimental drawing integration.

## Direction and current boundaries

The goal is to keep GNUstep's Objective-C application APIs while using platform
controls or platform-rendered surfaces wherever possible. Styling should come
from the configured platform theme instead of copied images or custom CSS.

The first implementation is a `GSTheme` plugin, `GTK4Native`. Applications still
use `NSButton` and `NSTextField`. GTK4 renders their control surfaces; AppKit
continues to handle text, editing, events, keyboard navigation and accessibility.
This is not equivalent to embedding actual GTK controls. Other basic controls
still use GNUstep's original drawing.

GTK4 styling does not automatically mean Qt/KDE styling, and plain GTK4 is not
libadwaita. A future platform-provider design may need more than one toolkit.

## Workspace and build setup

The host is Debian 13 (trixie), arm64. The installed tools include Clang 19,
CMake 3.31.6 and GTK4 4.18.6 development headers.

Initially APT had only the Codex application repository enabled. The Debian DVD
source was commented out. That explained why packages such as Git and Clang had
no installation candidates. `scripts/enable-debian-sources.sh` adds Debian's
trixie, trixie-updates and trixie-security main repositories, using the installed
Debian archive keyring and preserving other sources.

This account could not install packages with sudo. `scripts/setup.sh --su`
uses the root password for package installation, then clones as the normal user
so source checkouts remain user-owned. Builds install into the workspace's
`install/` prefix without root access. Source `env.sh` in development terminals.

Sources are independent repositories under `src/`: libobjc2, libdispatch,
tools-make, libs-base, libs-gui, libs-back, apps-gorm and apps-projectcenter.
GNUstep uses the modern Objective-C runtime and the Cairo/X11 backend here.

### Installed headers can hide source changes

The existing gnustep-make configuration placed the installed include directory
before the GUI source headers. Rebuilding new GSTheme methods then picked up an
older installed GSTheme.h. Struct-returning methods failed to compile; methods
with simpler return values could produce misleading declaration warnings.

`scripts/build-gtk4.sh` explicitly puts the GUI source headers first in
CPPFLAGS. The full build script uses `-idirafter` for the prefix include path.
When changing GNUstep itself, inspect the compiler's actual include ordering,
and rebuild/install the core library before rebuilding its theme plugin.

## Window decorations, menus and the floating icon

Three separate things initially looked like one appearance problem:

| Element | Finding | Current setting |
| --- | --- | --- |
| Window title bar | GTK's own decorations and desktop/window-manager decorations can have different colors and corner radii | Matched comparison uses X11 with `GTK_CSD=0` |
| Application menu | GNUstep defaults can create a separate NeXT-style menu | `NSMenuInterfaceStyle` and `NSInterfaceStyleDefault` use `NSWindows95InterfaceStyle` |
| Floating application icon | GNUstep also creates a separate application-icon window; it is independent of the menu | `GSSuppressAppIcon=YES` |

The floating tile was initially misidentified as a menu. Changing menu layout
alone did not remove it. Inspect the window's role before changing rendering.

`GSBackHandlesWindowDecorations=YES` delegates GNUstep window decoration to its
backend/window manager. `GTK4NativeInfo.plist` supplies these appearance defaults
through GSThemeDomain. They do not overwrite explicit user preferences.

`scripts/compare-apps.sh` sets `GDK_BACKEND=x11` and `GTK_CSD=0` for both sample
processes. This controls the display/decoration difference during comparison;
it does not change desktop settings. The standalone GTK executable retains its
normal backend and decoration choices when launched directly.

Close existing sample processes before comparing rebuilt versions. An existing
GTK application instance can retain its original launch environment.

## Use full GTK widget snapshots for control drawing

The initial `gtk_render_background`, `gtk_render_frame` and `gtk_render_focus`
implementation did not reproduce the actual GTK entry's complete focus outline.
Rendering a widget's background and border was insufficient.

The current path is:

1. Create real GTK button and entry objects inside an offscreen host.
2. Apply the AppKit control state and allocate the GTK widget.
3. Call `gtk_widget_snapshot_child` to obtain the complete GTK render node.
4. Draw that GskRenderNode into a scaled Cairo surface.
5. Transfer the resulting image into AppKit.

GTK snapshots require a mapped widget tree. An ordinary unmapped GtkWindow,
a paintable with no rendered content, or directly calling the widget's snapshot
virtual method did not provide the complete native drawing we needed.

The custom GtkWindow host uses the generic GtkWidget show/map lifecycle instead
of GtkWindow's surface-presentation lifecycle. Its in-memory tree is mapped, but
its GdkSurface remains unmapped. Tests check the native surface, not merely the
widget's mapped flag. This avoids displaying another GTK window. The technique
uses public subclassing APIs, but still needs validation across GTK versions.

GTK animations are disabled in the GNUstep process for now. Without an integrated
GTK frame clock, a focus transition could remain at its initial appearance.
Static snapshots must immediately represent the requested interaction state.
This does not change animation settings in the separate GTK comparison app.

The renderer no longer uses the deprecated GTK background/frame/focus drawing
functions. Style-context APIs used for symbolic colors and padding are still
deprecated and remain a maintenance issue. The current in-memory PNG transfer
also needs a pixel-buffer bridge or caching before production use.

## A text field includes more than its cell background

A native-looking entry needs its border, background, padding, text placement,
editor and clip view to cooperate.

- `drawTextFieldCell:frame:view:` lets the theme draw the frame/background. The
  default theme returns NO and keeps the original drawing path.
- `textFieldContentRectForCell:frame:` supplies GTK-derived insets and vertically
  centered content bounds. NSZeroRect keeps the original AppKit behavior.
- The field editor must be transparent so it does not paint a rectangle over
  GTK's background.
- The editor's NSClipView must also preserve that transparency. Making only the
  editor transparent left another opaque layer behind it.
- The cell reports nonopaque drawing for native rounded corners so the parent
  background can show through them.
- Custom-colored fields retain their original AppKit drawing.

GTK symbolic colors are mapped into an NSColorList named **System**. Using a
different list name triggered an NSColor assertion during theme activation.
Fonts, glyphs, selection and caret rendering still belong to AppKit, so exact
text-rendering parity with GtkEntry is not yet established.

## Focus has both drawing and invalidation requirements

### Remnants after Tab

Tabbing from the field to the button initially left pieces of the blue outline.
Removing the editor invalidated its content rectangle, which did not cover the
field's whole native focus treatment.

`NSTextField` now marks the entire control as needing display when its editor
is removed in `abortEditing`. This clears the outline during normal repainting.
Forcing a full redraw manually hid the bug; it was not a sufficient test.

The regression sends an actual Tab key event, verifies that the button becomes
first responder, and captures the existing window backing-store pixels after
normal dirty-region painting. Those pixels must match a subsequent clean redraw.
The test failed before the fix and passes in light and dark modes afterward.

### Blue ring plus black dotted inset

The GTK snapshot already contained the button's blue focus ring. AppKit then
added its own dotted focus frame, producing two indicators.

`GTK4NativeTheme` suppresses `drawFocusFrame:view:` only for text fields and
bordered button styles that it renders through GTK. Unsupported button styles
keep their AppKit indicator. Drawing and focus suppression share the same
supported-button-style decision.

A pixel regression checks that the extra focus-frame pass changes no pixels
for a GTK-drawn button, while it still changes pixels for a fallback button.
It failed before the fix and passes afterward. Do not disable AppKit focus
indicators globally: controls still using AppKit need them.

## Validation and practical commands

From `/home/georg/Code/gnuStep`:

```bash
# Rebuild patched libs-gui, install the GTK4 theme, and build the sample.
bash scripts/build-gtk4.sh

# Build the standalone native GTK4 reference.
make -C examples/HelloGTK4

# Run rendering and integration checks on virtual X displays.
bash scripts/test-gtk4.sh

# After closing old instances, launch both with matching decorations.
bash scripts/compare-apps.sh
```

The suites run with Adwaita light and dark themes. Tests force the X11 backend
so an inherited Wayland session does not bypass the temporary Xvfb display.
They cover rendering states, 2x surfaces, the unmapped host surface, actual theme
loading, custom-color fallback, hidden application icon, in-window menus,
transparent active editing, native padding, stock-theme behavior and both focus
regressions above.

The native reference uses actual GtkButton, GtkEntry, GtkLabel and menu widgets,
without custom CSS. Keep comparing real interaction and focused/unfocused states;
a successful startup or a screenshot of an unfocused control misses important
integration problems.

## Remaining work

Other controls, hover tracking, default-button behavior, native sizing and fonts,
live theme changes, GLib/AppKit event-loop coordination, animations, input methods,
accessibility and actual native-widget hosting remain unfinished. Test fractional
scaling and other desktops/themes before claiming broad native appearance.
GTK rendering alone does not turn the existing X11 backend into a Wayland backend.

Implementation and coverage details are in `native/GTK4Native/README.md`.
The two regression suites are `renderer-test.c` and `integration-test.m` in that
directory. The modified GNUstep sources are GSTheme.h, GSThemeDrawing.m,
NSCell.m, NSTextFieldCell.m and NSTextField.m in `src/libs-gui`.

References used during implementation:

- [GNUstep Linux build guide](https://developer.gnustep.org/Guides/Setup/Linux/building-linux.html)
- [GTK application environment and decoration settings](https://docs.gtk.org/gtk4/running.html)
- [GTK widget snapshots](https://docs.gtk.org/gtk4/method.Widget.snapshot_child.html)
- [GTK WidgetPaintable](https://docs.gtk.org/gtk4/class.WidgetPaintable.html)
- [GTK4 migration guide](https://docs.gtk.org/gtk4/migrating-3to4.html)

## Standalone native button and selection controls

Live row translation alone did not make ordinary NSButton controls native.
`GTK4NativeControls` now discovers supported control leaves below a window's
content view and embeds them in the existing GTK body, sharing its X11 cutout
publication and focus routing with native tables. It skips table descendants
and custom drawing/mouse-handler overrides. Clip allocation is independent of
GTK child natural sizes, so scrolling or a partly visible control cannot grow
the host or paint over neighboring AppKit content. Native peers retain source
views only while attached and recreate on structural or scale changes.

Indicator image names are aliases: comparing `[image name]` with `NSSwitch` or
`NSRadioButton` misclassified standard checkbox/radio cells. Compare with the
canonical `imageNamed:` object instead. Poll state through typed NSButtonCell
references: this build's NSButton state forwarding otherwise asks its untyped
cell for an unsigned NSSwitch-style selector and the runtime warns each tick.
Switch state uses integerValue, keeping its unsigned state API out of that path.

A clipping GtkWidget can outlive its peer through GTK's in-flight frame refs.
Releasing the bridge first unparented its child while the clip still held a raw
pointer, failing the next snapshot. Peer teardown must clear the clip's child
and unparent it explicitly before releasing the bridge. Dynamic segmented
tracking-mode changes reproduce this failure without that order.

GtkCheckButton consumes Return to toggle itself before GtkWindow's default
activation. A native capture key controller preserves AppKit's Return-default
contract for hosted button/selection focus while excluding native text entries.
Actions still use NSControl sendAction so value bindings reverse normally and
the original control remains the sender. The source cell defines the checkbox
cycle (mixed→on→off→mixed here), rather than hard-coding a different cycle.

`native-buttons-test.m` uses real pointer and keyboard events for all 14 bezel
styles, mixed checkbox cycling, radio exclusivity, switches, segment tracking
modes, disabled input and Return defaults. It also checks synchronization,
scroll clipping/input coordinates, detach/reattach, resize and close. The
script runs light, dark, 2× and 1.5× plus existing native view/window checks.

Wheel events in a native cutout no longer reach the enclosing AppKit scroll
view automatically. A GTK scroll controller forwards wheel/smooth deltas and
modifiers to that source scroll view; surface-unit deltas account for the
AppKit/GDK scale ratio and configured line steps. The real-input test scrolls
with the pointer over a disabled native button, then clicks a newly revealed
control. GTK clicked-signal counters also prove that native buttons, including
every bezel variant, receive the pointer sequence rather than the backing
AppKit views.

## Dropdowns, narrow scrollbar indicators and nested table clipping

NSPopUpButton's selected NSMenuItem carries the cell's canonical common_Nibble
arrow image. Rejecting all item images silently rejected ordinary selection
popups. Flat selection popups now translate to GtkDropDown; actual custom
images/separators/submenus and pull-down menus retain existing tracking. The
source menu item action preserves the cell's selection-binding reverse updates,
with setControlView established before routing the action. GObject can re-emit
notify::selected after resetting a disabled choice; ignoring an index already
selected in the source prevents duplicate actions from that queued notification.

GtkPopover events use a different native surface and coordinate origin. The
host must leave these in GTK instead of testing popup-relative pointer positions
against AppKit content holes. Native Return-default handling also excludes
popover focus. Source menu titles/enabled states are synchronized into GTK, and
factories retain the source independently of bridge callback lifetimes.

GTK's overlay-indicator CSS provides thin, transparent-track scrollbar snapshots.
It is selected only when gtk-overlay-scrolling is enabled. In the installed GTK
CSS its resting color does not change for pressed/disabled state flags alone;
hovering/dragging classes belong to live GtkScrolledWindow behavior. Tests now
check thickness against a regular GTK scrollbar, transparent pixels away from
the thumb, geometry/proportion changes, scaling and source input behavior instead
of requiring every native CSS state to have different pixels. AppKit still
reserves the narrow scroller width and owns tracking; fading/hover expansion are
not introduced by this appearance change.

Native tables previously used their enclosing NSScrollView's entire bounds for
both GTK allocation and the X11 hole, so outer scroll views could not clip them.
GTK4NativeClip is now shared by tables and controls. The table clip/hole follows
visibleRect while the GtkScrolledWindow keeps its original full allocation and
scroll adjustment page, offset behind the clip. Cropping the scroller allocation
itself would change the visible row count and cause scrolling/layout jumps.
Tests sample magenta AppKit sentinels outside both viewport edges and verify
clipping, full-size allocation, hiding, resize and detachment at 1x/2x/1.5x.


## Scroll the whole native document instead of chasing AppKit controls

Per-control X11 cutouts cannot make two renderers scroll atomically. AppKit copies
its backing surface when the clip origin changes, while the native peer timer
moves GTK widgets and publishes new holes later. Accelerating the timer still
permits stale AppKit controls to peek through. Supported scroll documents instead
use one GtkScrolledWindow, a complete GTK child tree and a stable viewport cutout.
GTK owns movement and clipping; mirrored AppKit clip bounds serve model/API calls.
The native document uses GtkConstraintLayout directly, without solver proxy views.
Mixed/custom-drawn documents keep the old path until their content is supported.

GNUstep scroll views can report hasHorizontalRuler even when rulers are hidden.
Eligibility must check rulersVisible, rather than rejecting any potential ruler.
A native peer can also survive dictionary removal through autoreleased allValues
arrays; explicitly invalidate and unparent it at removal, rather than waiting for
dealloc, so page replacement never leaves a stale GTK scene visible.

The real-wheel regression disables host synchronization and proves that native
children scroll correctly, the viewport cutout remains fixed, source clip bounds
are mirrored, and AppKit backing pixels stay hidden. Compound layout tests verify
GTK constraint anchors and elastic resizing separately from existing row layout.


## Shared native peers and complete GTK scenes

GSNativeView supplies optional, weak platform peers with no theme/GTK dependency.
An owned subtree must stop AppKit backing drawing and layout, not merely cover
its controls with native widgets. Invalidation queues the GTK node immediately;
custom drawRect: executes once in its own bitmap context and native children are
snapshotted separately. A scoped native drawing rectangle preserves getRectsBeingDrawn:
and needsToDrawRect:. Whole supported window contents and nested scroll trees can
now publish one stable native region. Framework views without adapters remain mixed.

GTK-owned geometry must be reflected to source frames so existing convertPoint:
and responder code keep working. Those reflected frames are not structural changes:
configuration signatures compare original layout frames unless application code
changes the geometry. Springs/struts become parent-size equations in GTK. All
translated row/container layout now uses GtkConstraintLayout, without proxy NSViews.

GtkConstraintLayout baseline variables did not position the actual GtkLabel text in
this environment. Translate first/last baselines to TOP plus GTK-measured font
baseline offsets. Intrinsic priorities use GTK constraint guides. Direct overlapping
soft inequalities triggered solver teardown corruption under repeated resize/detach;
guides pass the same source-priority, pixel-baseline and teardown regression.

GTK gestures propagate through ancestors. A custom parent's gesture must deny a
sequence picked on a native descendant, or its mouseDown steals the child's click.
Native surface transforms also include decoration offsets: real-input tests must
add gtk_native_get_surface_transform when converting widget coordinates to X11.

Application mouseDown may enter an AppKit tracking loop. Deliver responder methods
outside GTK callbacks so the host can pump GDK recursively. Already-captured events
may sit in the run loop's currently executing selector batch; scheduling another
selector alone cannot make them visible to nextEventMatchingMask:. The scoped generic
GSNativeEventSource supplies those queued events to the active tracking loop, and
consumed requests are skipped later. Events arriving during tracking enter the
ordinary AppKit event queue. Tests cover both ordinary callbacks and a blocking
custom tracking handler, without a second hit test or duplicate source action.


Native list rows need a fixed GTK viewport around their constraint container.
Letting GtkListView measure the constraint container directly retained the
measurement solve's expansion in real nib rows, although isolated window layout
passed. The row viewport reports no content-driven minimum and allocates the inner
GTK constraint layout at the exact list-provided size. Real EditGlyphData column
and baseline checks must run alongside standalone layout tests. Nib constraints
may also put a minimum on the child and reverse the parent/child equation order;
include child constraints in intrinsic bounds and normalize parent-target equations.

Do not reflect geometry from hidden/unallocated native widgets, or a pending scene
replacement can write zero size into the source clip view. Do not overwrite source
frames changed by application code while a previous snapshot is in flight. Both
races are covered by resize/replacement and unflipped scroll regressions.

Specialized AppKit field-editor subclasses require dedicated adapters. A generic
custom drawing wrapper must not swallow a validating NSTextField subclass's editor
focus; retain that family's existing path. Custom NSView/NSControl subclasses,
including blocking tracking handlers, use the shared GTK wrapper. Framework
container subclasses are eligible only when their base has an adapter, so inherited
AppKit layout does not silently become a fixed native scene.
