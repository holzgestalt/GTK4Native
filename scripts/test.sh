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
# Keep tests on the temporary X display inside Wayland desktop sessions too.
export GDK_BACKEND=x11
test_build_dir=${GTK4_TEST_BUILD_DIR:-"$plugin_root/build/tests"}
mkdir -p "$test_build_dir"
test_build_dir=$(cd -- "$test_build_dir" && pwd)
cd "$plugin_root"
clang GTK4Renderer.c renderer-test.c -o "$test_build_dir/renderer-test" \
  $(pkg-config --cflags --libs gtk4)
clang $(gnustep-config --objc-flags) integration-test.m \
  -o "$test_build_dir/integration-test" $(gnustep-config --gui-libs)
clang $(gnustep-config --objc-flags) fallback-test.m \
  -o "$test_build_dir/fallback-test" $(gnustep-config --gui-libs)
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) native-menu-test.m \
  -o "$test_build_dir/native-menu-test" $(gnustep-config --gui-libs) \
  $(pkg-config --libs gtk4-x11) -ldl
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4) native-file-panel-test.m \
  -o "$test_build_dir/native-file-panel-test" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4)
for theme in Adwaita Adwaita:dark; do
  DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/gtk4native-no-session-bus DCONF_BACKEND=memory \
    GTK_THEME="$theme" xvfb-run -a timeout -k 2s 15s "$test_build_dir/native-file-panel-test"
  GTK_THEME="$theme" xvfb-run -a "$test_build_dir/renderer-test"
  GTK_THEME="$theme" xvfb-run -a "$test_build_dir/integration-test"
  GTK_THEME="$theme" xvfb-run -a timeout 15s "$test_build_dir/native-menu-test"
done
GDK_BACKEND=wayland WAYLAND_DISPLAY=gnustep-test-unavailable \
  xvfb-run -a timeout 15s "$test_build_dir/fallback-test"
# With no explicit GTK selection, the theme must match the AppKit X11 backend.
env -u GDK_BACKEND xvfb-run -a timeout 15s "$test_build_dir/native-menu-test"
