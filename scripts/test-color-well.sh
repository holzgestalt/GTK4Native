#!/usr/bin/env bash
set -eo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$root/env.sh"
build="$root/build/gtk4-color-well"
mkdir -p "$build"
bash "$root/scripts/build-themes.sh" GTK4Native > "$build/build.log" 2>&1
read -r -a theme_libs <<< "$(python3 "$root/scripts/theme-config.py" GTK4Native --libs)"
sed -e "s|^GNUSTEP_USER_DEFAULTS_DIR=.*|GNUSTEP_USER_DEFAULTS_DIR=$build/Defaults|" \
  -e 's|^GNUSTEP_USER_CONFIG_FILE=.*|GNUSTEP_USER_CONFIG_FILE=|' \
  "$root/install/etc/GNUstep/GNUstep.conf" > "$build/GNUstep.conf"
chmod 600 "$build/GNUstep.conf"
clang $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) \
  "$root/native/GTK4Native/native-color-well-test.m" -o "$build/native-color-well-test" \
  "${theme_libs[@]}" $(gnustep-config --gui-libs) $(pkg-config --libs gtk4-x11) -ldl > "$build/compile.log" 2>&1
for appearance in light dark scale2 fractional; do
  theme=Adwaita; scale=1; extra=()
  if [[ "$appearance" == dark ]]; then theme=Adwaita:dark; fi
  if [[ "$appearance" == scale2 ]]; then scale=2; fi
  if [[ "$appearance" == fractional ]]; then extra=(-GSScaleFactor 1.5); fi
  log="$build/$appearance.log"
  GNUSTEP_CONFIG_FILE="$build/GNUstep.conf" DCONF_BACKEND=memory GTK_USE_PORTAL=0 GDK_BACKEND=x11 GTK_THEME="$theme" GDK_SCALE="$scale" G_DEBUG=fatal-criticals \
    timeout -k 2s 20s xvfb-run -a -s '-screen 0 2560x2048x24' "$build/native-color-well-test" "${extra[@]}" > "$log" 2>&1 || { cat "$log"; exit 1; }
  cat "$log"
  if grep -Eq 'Gtk-(WARNING|CRITICAL)|Assertion failed' "$log"; then exit 1; fi
done
