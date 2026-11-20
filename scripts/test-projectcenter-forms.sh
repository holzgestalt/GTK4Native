#!/usr/bin/env bash
set -eo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$root/env.sh"
build="$root/build/projectcenter-forms"
mkdir -p "$build/FormsTest.app"
bash "$root/scripts/build-projectcenter.sh" > "$build/build.log" 2>&1
appbuild="$root/build/ProjectCenter/Debug"
ln -sfn "$appbuild/ProjectCenter/ProjectCenter.app/Resources" "$build/FormsTest.app/Resources"
sed -e "s|^GNUSTEP_USER_DEFAULTS_DIR=.*|GNUSTEP_USER_DEFAULTS_DIR=$build/Defaults|" \
  -e 's|^GNUSTEP_USER_CONFIG_FILE=.*|GNUSTEP_USER_CONFIG_FILE=|' \
  "$root/install/etc/GNUstep/GNUstep.conf" > "$build/GNUstep.conf"
chmod 600 "$build/GNUstep.conf"
read -r -a theme_libs <<< "$(python3 "$root/scripts/theme-config.py" GTK4Native --libs)"
framework="$appbuild/ProjectCenter.framework/ProjectCenter.framework"
clang -I"$root/src/apps-projectcenter/Headers" -I"$root/src/apps-projectcenter" -I"$root/native/GTK4Native" \
  $(gnustep-config --objc-flags) $(pkg-config --cflags gtk4-x11) \
  "$root/native/GTK4Native/projectcenter-forms-test.m" \
  "$appbuild"/ProjectCenter/obj/ProjectCenter.obj/Sources/PC*.o \
  "$framework/libProjectCenter.so" "${theme_libs[@]}" $(gnustep-config --gui-libs) -ldl \
  -o "$build/FormsTest.app/FormsTest" > "$build/compile.log" 2>&1
for appearance in light dark scale2 fractional; do
  theme=Adwaita; scale=1; extra=(); do_build=()
  if [[ "$appearance" == dark ]]; then theme=Adwaita:dark; fi
  if [[ "$appearance" == scale2 ]]; then scale=2; fi
  if [[ "$appearance" == fractional ]]; then extra=(-GSScaleFactor 1.5); fi
  if [[ "$appearance" == light && "${PC_FORMS_SKIP_BUILD:-0}" != 1 ]]; then do_build=(PC_FORMS_BUILD=1); fi
  env "${do_build[@]}" LD_LIBRARY_PATH="$framework/Versions/Current:$LD_LIBRARY_PATH" \
    GNUSTEP_CONFIG_FILE="$build/GNUstep.conf" DCONF_BACKEND=memory GDK_BACKEND=x11 \
    GTK_THEME="$theme" GDK_SCALE="$scale" G_DEBUG=fatal-criticals \
    PC_FORMS_SCREENSHOT="$build/$appearance.png" \
    timeout -k 2s 160s xvfb-run -a -s '-screen 0 2560x2048x24' \
    "$build/FormsTest.app/FormsTest" "$root/Apps/EditGlyphData/EditGlyphData.xcodeproj" "${extra[@]}" \
    > "$build/$appearance.log" 2>&1 || { tail -n 35 "$build/$appearance.log"; exit 1; }
  tail -n 8 "$build/$appearance.log"
  if grep -Eq 'Gtk-(WARNING|CRITICAL)|Assertion failed|negative width|negative height' "$build/$appearance.log"; then exit 1; fi
done
nm "$root/build/EditGlyphData/EditGlyphData.app/EditGlyphData" > "$build/editglyph-symbols.log"
grep -q '__objc_class_name_GTK4NativeTheme\|._OBJC_CLASS_GTK4NativeTheme' "$build/editglyph-symbols.log"
! grep -q '._OBJC_CLASS_GSDefaultTheme' "$build/editglyph-symbols.log"
printf 'PASS EditGlyphData links the selected GTK4Native provider\n'
