#!/bin/bash
# Builds libusb and minipro for Android with the NDK and puts them where Gradle packs them:
#   android/app/src/main/jniLibs/<abi>/libminipro.so   (an executable, named .so so Android installs it
#                                                       into the app's native library folder, where
#                                                       running it is allowed)
#   android/app/src/main/assets/minipro/{infoic,logicic}.xml, SOURCE.txt
# Environment: ANDROID_NDK (NDK root), MINIPRO_REF (default main), LIBUSB_VERSION (default 1.0.27),
#              ANDROID_API (default 26).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/android/app/src/main"
WORK="${WORK:-$ROOT/android/build-native}"
NDK="${ANDROID_NDK:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}}"
API="${ANDROID_API:-26}"
LIBUSB_VERSION="${LIBUSB_VERSION:-1.0.27}"
MINIPRO_REF="${MINIPRO_REF:-main}"
DIAG="${DIAG:-$ROOT/android-diag.txt}"

diag() { { echo "### $1"; echo "$2"; echo; } >> "$DIAG"; }
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "ERROR: Android NDK not found (set ANDROID_NDK)"; exit 1; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
diag "NDK" "$NDK ($(grep -m1 Pkg.Revision "$NDK/source.properties" 2>/dev/null || true))"

rm -rf "$WORK" && mkdir -p "$WORK/src"
curl -fsSL "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" -o "$WORK/src/libusb.tar.bz2"
if [ "$MINIPRO_REF" = main ]; then
  git clone -q --depth 50 https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro"
else
  git clone -q --depth 1 --branch "$MINIPRO_REF" https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro" \
    || git clone -q --depth 50 https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro"
fi
git -C "$WORK/src/minipro" fetch -q --depth 1 origin 'refs/tags/0.7.4:refs/tags/0.7.4' 2>/dev/null || true
MINIPRO_DESC="$(git -C "$WORK/src/minipro" describe --tags --always 2>/dev/null || echo unknown) ($(git -C "$WORK/src/minipro" log -1 --format=%cs))"
echo "minipro $MINIPRO_DESC"
PATCH_OUT="$("$ROOT/scripts/patch-minipro.sh" "$WORK/src/minipro")" || { echo "$PATCH_OUT"; exit 1; }
echo "$PATCH_OUT"; diag "minipro patch" "$PATCH_OUT"
diag "minipro source" "$MINIPRO_DESC"
diag "minipro libusb calls" "$(grep -rhoE 'libusb_[a-z_]+\(' "$WORK/src/minipro/src" | sort | uniq -c | sort -rn | head -60)"
diag "minipro Makefile (head)" "$(sed -n '1,80p' "$WORK/src/minipro/Makefile" 2>/dev/null)"

RENAMES="-Dlibusb_init=cb_init -Dlibusb_init_context=cb_init_context -Dlibusb_exit=cb_exit \
-Dlibusb_get_device_list=cb_get_device_list -Dlibusb_free_device_list=cb_free_device_list \
-Dlibusb_open=cb_open -Dlibusb_open_device_with_vid_pid=cb_open_device_with_vid_pid -Dlibusb_close=cb_close"

build_abi() {
  local ABI="$1" TRIPLE="$2" CCPREFIX="$3"
  local CC="$TC/bin/${CCPREFIX}${API}-clang"
  local PREFIX="$WORK/$ABI"
  echo "== $ABI"
  mkdir -p "$PREFIX/lib/pkgconfig"

  rm -rf "$WORK/libusb-$ABI" && mkdir -p "$WORK/libusb-$ABI"
  tar -xjf "$WORK/src/libusb.tar.bz2" -C "$WORK/libusb-$ABI" --strip-components=1
  ( cd "$WORK/libusb-$ABI"
    CC="$CC" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" ./configure --host="$TRIPLE" --prefix="$PREFIX" \
      --disable-shared --enable-static --disable-udev --disable-dependency-tracking > "$WORK/libusb-$ABI.log" 2>&1 \
      || { tail -40 "$WORK/libusb-$ABI.log"; exit 1; }
    make -j"$(nproc)" >> "$WORK/libusb-$ABI.log" 2>&1 || { tail -60 "$WORK/libusb-$ABI.log"; exit 1; }
    make install >> "$WORK/libusb-$ABI.log" 2>&1 )

  # The shim, compiled against the real libusb names.
  "$CC" -O2 -fPIC -I"$PREFIX/include/libusb-1.0" -c "$ROOT/android/native/usbshim.c" -o "$PREFIX/usbshim.o"
  "$TC/bin/llvm-ar" rcs "$PREFIX/lib/libcbshim.a" "$PREFIX/usbshim.o"

  # minipro gets libusb through pkg-config: the renamed calls plus the shim, linked statically.
  cat > "$PREFIX/lib/pkgconfig/libusb-1.0.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libusb-1.0
Description: libusb with the ChipBurner Android shim
Version: $LIBUSB_VERSION
Libs: -L\${libdir} -lcbshim -lusb-1.0 -llog
Cflags: -I\${includedir}/libusb-1.0 $RENAMES
EOF
  cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from the NDK
Version: 1.2.13
Libs: -lz
Cflags:
EOF

  rm -rf "$WORK/minipro-$ABI" && cp -R "$WORK/src/minipro" "$WORK/minipro-$ABI"
  ( cd "$WORK/minipro-$ABI"
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
      make -j"$(nproc)" CC="$CC" > "$WORK/minipro-$ABI.log" 2>&1 \
      || { tail -60 "$WORK/minipro-$ABI.log"; diag "minipro build $ABI" "$(tail -80 "$WORK/minipro-$ABI.log")"; exit 1; } )
  [ -f "$WORK/minipro-$ABI/minipro" ] || { echo "minipro binary missing for $ABI"; exit 1; }
  "$TC/bin/llvm-strip" "$WORK/minipro-$ABI/minipro"
  mkdir -p "$APP/jniLibs/$ABI"
  cp "$WORK/minipro-$ABI/minipro" "$APP/jniLibs/$ABI/libminipro.so"
  diag "binary $ABI" "$(file "$APP/jniLibs/$ABI/libminipro.so") | undefined cb_: $("$TC/bin/llvm-nm" -D "$APP/jniLibs/$ABI/libminipro.so" 2>/dev/null | grep -c ' cb_' || true) | NEEDED: $("$TC/bin/llvm-readelf" -d "$APP/jniLibs/$ABI/libminipro.so" | grep NEEDED | tr -s ' ' | cut -d' ' -f6 | tr '\n' ' ')"
}

build_abi arm64-v8a aarch64-linux-android aarch64-linux-android
build_abi armeabi-v7a arm-linux-androideabi armv7a-linux-androideabi
build_abi x86_64 x86_64-linux-android x86_64-linux-android

# Chip database
INFOIC="$(find "$WORK/src/minipro" -name infoic.xml -print -quit)"
LOGICIC="$(find "$WORK/src/minipro" -name logicic.xml -print -quit)"
[ -n "$INFOIC" ] || { echo "ERROR: infoic.xml not in the minipro source"; exit 1; }
mkdir -p "$APP/assets/minipro"
cp "$INFOIC" "$APP/assets/minipro/infoic.xml"
[ -n "$LOGICIC" ] && cp "$LOGICIC" "$APP/assets/minipro/logicic.xml"
cat > "$APP/assets/minipro/SOURCE.txt" <<EOF
This app runs minipro ($MINIPRO_DESC), licensed under the GNU GPL v3.
Source code: https://gitlab.com/DavidGriffith/minipro
ChipBurner applies small changes before building it (TL866A voltage byte fix, TL866A VPP check): scripts/patch-minipro.sh and scripts/minipro-vppcheck.c
in https://github.com/WolfieGoesAI/chipburner
libusb $LIBUSB_VERSION (LGPL 2.1): https://github.com/libusb/libusb
EOF
echo "$MINIPRO_DESC" > "$APP/assets/minipro/VERSION.txt"
echo "native build done"
