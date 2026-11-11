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
for theme in Adwaita Adwaita:dark; do
  GTK_THEME="$theme" xvfb-run -a "$test_build_dir/renderer-test"
  GTK_THEME="$theme" xvfb-run -a "$test_build_dir/integration-test"
done
