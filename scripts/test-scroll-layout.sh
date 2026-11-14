#!/usr/bin/env bash
set -eo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$root/env.sh"
build="$root/build/gtk4-scroll-layout"
mkdir -p "$build"
bash "$root/scripts/build-themes.sh" GTK4Native > "$build/build.log" 2>&1
read -r -a theme_libs <<< "$(python3 "$root/scripts/theme-config.py" GTK4Native --libs)"
sed -e "s|^GNUSTEP_USER_DEFAULTS_DIR=.*|GNUSTEP_USER_DEFAULTS_DIR=$build/Defaults|" \
  -e 's|^GNUSTEP_USER_CONFIG_FILE=.*|GNUSTEP_USER_CONFIG_FILE=|' \
  "$root/install/etc/GNUstep/GNUstep.conf" > "$build/GNUstep.conf"
chmod 600 "$build/GNUstep.conf"
export GNUSTEP_CONFIG_FILE="$build/GNUstep.conf" GDK_BACKEND=x11
clang "$root/native/GTK4Native/GTK4Renderer.c" "$root/native/GTK4Native/renderer-test.c" \
  -o "$build/renderer-test" $(pkg-config --cflags --libs gtk4)
for name in native-scroll-layout native-scroller; do
  clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11 cairo-xlib) \
    "$root/native/GTK4Native/$name-test.m" -o "$build/$name-test" \
    "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4-x11 cairo-xlib)
done
for appearance in light dark scale2 fractional; do
  theme=Adwaita; scale=1; extra=()
  if [[ "$appearance" != light ]]; then theme=Adwaita:dark; fi
  if [[ "$appearance" == scale2 ]]; then scale=2; fi
  if [[ "$appearance" == fractional ]]; then extra=(-GSScaleFactor 1.5); fi
  for name in renderer native-scroller native-scroll-layout; do
    log="$build/$name-$appearance.log"
    GTK_THEME="$theme" GDK_SCALE="$scale" G_DEBUG=fatal-criticals \
      NATIVE_SCROLL_LAYOUT_PREVIEW="$build/$appearance.png" \
      xvfb-run -a -s '-screen 0 2560x2048x24' timeout -k 2s 25s \
      "$build/$name-test" "${extra[@]}" > "$log" 2>&1 || { cat "$log"; exit 1; }
    cat "$log"
    if grep -Eq 'Gtk-(WARNING|CRITICAL)|incorrect signature|negative width|negative height' "$log"; then exit 1; fi
  done
done
