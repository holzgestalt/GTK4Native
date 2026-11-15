#!/usr/bin/env bash
set -eo pipefail
plugin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for command in clang gnustep-config pkg-config xvfb-run; do
  command -v "$command" >/dev/null || {
    echo "Missing $command. Install dependencies and activate your GNUstep environment." >&2
    exit 1
  }
done
pkg-config --exists gtk4
workspace_root=$(cd "$plugin_root/../.." && pwd)
bash "$workspace_root/scripts/build-themes.sh" GTK4Native
read -r -a theme_libs <<< "$(python3 "$workspace_root/scripts/theme-config.py" GTK4Native --libs)"
# Keep tests on the temporary X display inside Wayland desktop sessions too.
export GDK_BACKEND=x11
test_build_dir=${GTK4_TEST_BUILD_DIR:-"$plugin_root/build/tests"}
mkdir -p "$test_build_dir"
test_build_dir=$(cd -- "$test_build_dir" && pwd)
cd "$plugin_root"
clang GTK4Renderer.c renderer-test.c -o "$test_build_dir/renderer-test" \
  $(pkg-config --cflags --libs gtk4)
clang $(gnustep-config --objc-flags) integration-test.m \
  -o "$test_build_dir/integration-test" "${theme_libs[@]}" $(gnustep-config --gui-libs)
clang $(gnustep-config --objc-flags) fallback-test.m \
  -o "$test_build_dir/fallback-test" "${theme_libs[@]}" $(gnustep-config --gui-libs)
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) native-menu-test.m \
  -o "$test_build_dir/native-menu-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) \
  $(pkg-config --libs gtk4-x11) -ldl
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) native-file-panel-test.m \
  -o "$test_build_dir/native-file-panel-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) native-scroller-test.m \
  -o "$test_build_dir/native-scroller-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) native-view-test.m \
  -o "$test_build_dir/native-view-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) theme-startup-test.m \
  -o "$test_build_dir/theme-startup-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4-x11)
for scale in 1 2; do
  env -u GDK_BACKEND GDK_SCALE="$scale" EXPECTED_UI_SCALE="$scale" \
    WAYLAND_DISPLAY=gnustep-test-unavailable G_DEBUG=fatal-criticals \
    xvfb-run -a timeout 15s "$test_build_dir/theme-startup-test"
done
env -u GDK_BACKEND GDK_SCALE=2 EXPECTED_UI_SCALE=1 \
  WAYLAND_DISPLAY=gnustep-test-unavailable G_DEBUG=fatal-criticals \
  xvfb-run -a timeout 15s "$test_build_dir/theme-startup-test" -GSScaleFactor 1
for theme in Adwaita Adwaita:dark; do
  G_DEBUG=fatal-criticals GTK_THEME="$theme" xvfb-run -a timeout 15s "$test_build_dir/native-view-test"
  LC_ALL=C DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/gtk4native-no-session-bus DCONF_BACKEND=memory \
    GTK_THEME="$theme" xvfb-run -a timeout -k 2s 15s "$test_build_dir/native-file-panel-test"
  GTK_THEME="$theme" xvfb-run -a "$test_build_dir/renderer-test"
  GTK_THEME="$theme" xvfb-run -a timeout 15s "$test_build_dir/native-scroller-test"
  # This checks AppKit's field-editor backing/focus rendering explicitly.
  # Native entry widgets are covered by native-view and native-window tests.
  GTK4_NATIVE_WINDOWS=0 GTK_THEME="$theme" xvfb-run -a "$test_build_dir/integration-test"
  GTK_THEME="$theme" xvfb-run -a timeout 15s "$test_build_dir/native-menu-test"
done
GDK_BACKEND=wayland WAYLAND_DISPLAY=gnustep-test-unavailable \
  xvfb-run -a timeout 15s "$test_build_dir/fallback-test"
# With no explicit GTK selection, the theme must match the AppKit X11 backend.
env -u GDK_BACKEND xvfb-run -a timeout 15s "$test_build_dir/native-menu-test"

# Check the installed GTK catalog rather than an application translation bundle.
LC_ALL=de_DE.UTF-8 LANGUAGE=de FILE_PANEL_TEST_LANGUAGE=de \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/gtk4native-no-session-bus DCONF_BACKEND=memory \
  xvfb-run -a timeout -k 2s 15s "$test_build_dir/native-file-panel-test"

clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) scaling-test.m \
  -o "$test_build_dir/scaling-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
for scale in 1 2; do
  GDK_SCALE="$scale" EXPECTED_UI_SCALE="$scale" xvfb-run -a -s '-screen 0 2560x2048x24' "$test_build_dir/scaling-test"
done
GDK_SCALE=2 EXPECTED_UI_SCALE=1 xvfb-run -a "$test_build_dir/scaling-test" -GSScaleFactor 1

clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) live-scaling-test.m \
  -o "$test_build_dir/live-scaling-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4-x11)
GDK_SCALE=1 xvfb-run -a -s '-screen 0 2560x2048x24' \
  "$test_build_dir/live-scaling-test" > "$test_build_dir/live-scaling-test.log" 2>&1
cat "$test_build_dir/live-scaling-test.log"
if grep -Eq 'negative width|negative height' "$test_build_dir/live-scaling-test.log"; then exit 1; fi

GDK_SCALE=2 GTK_THEME=Adwaita xvfb-run -a -s '-screen 0 2560x2048x24' \
  timeout 15s "$test_build_dir/native-scroller-test"

if pkg-config --atleast-version=4.10 gtk4; then
  clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) native-alert-test.m \
    -o "$test_build_dir/native-alert-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
  for theme in Adwaita Adwaita:dark; do
    LC_ALL=C LANGUAGE=en GTK_THEME="$theme" \
      DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/gtk4native-no-session-bus DCONF_BACKEND=memory \
      xvfb-run -a timeout -k 2s 15s "$test_build_dir/native-alert-test"
  done
fi

# Native GTK top-level ownership, real AppKit input and backend lifecycle.
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) native-window-test.m \
  -o "$test_build_dir/native-window-test" "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4-x11) -ldl
for theme in Adwaita Adwaita:dark; do
  LC_ALL=C GTK_THEME="$theme" xvfb-run -a timeout -k 2s 15s "$test_build_dir/native-window-test"
done
GDK_SCALE=2 LC_ALL=C xvfb-run -a -s '-screen 0 2560x2048x24' \
  timeout -k 2s 15s "$test_build_dir/native-window-test"
GTK4_NATIVE_WINDOWS=0 xvfb-run -a timeout 15s "$test_build_dir/integration-test"

# Standalone controls use live GTK peers, including real XTest input.
bash "$plugin_root/scripts/test-buttons.sh"

# Nested native surfaces and thin scroller appearance.
bash "$plugin_root/scripts/test-scroll-layout.sh"

# Complete scenes and custom AppKit responder/drawing wrappers.
bash "$plugin_root/scripts/test-custom-views.sh"

# GTK-owned window composition and live AppKit split tracking.
bash "$plugin_root/scripts/test-live-resize.sh"
