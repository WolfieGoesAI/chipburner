#!/bin/bash
# Builds ChipBurner.app (universal: Intel + Apple silicon, macOS 10.14.4+) on a macOS machine
# with Xcode command-line tools. Used by the GitHub workflow; can also be run by hand.
#
#   scripts/build.sh            -> dist/ChipBurner-<version>.zip
#
# Environment overrides:
#   APP_VERSION     version string (default 0.1.0)
#   MINIPRO_REF     minipro git tag/branch (default 0.7.4, falls back to master)
#   LIBUSB_VERSION  libusb release (default 1.0.27)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
DIST="$ROOT/dist"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MINIPRO_REF="${MINIPRO_REF:-0.7.4}"
LIBUSB_VERSION="${LIBUSB_VERSION:-1.0.27}"
ARCHS=(x86_64 arm64)

log() { printf '\n==> %s\n' "$*"; STEP="$*"; }
STEP="start"

# Keep a copy of all output so a failure can be reported as a GitHub annotation
# (annotations are readable through the API even where the raw log is not).
BUILD_LOG="$(mktemp -t chipburner-build)"
exec > >(tee "$BUILD_LOG") 2>&1
report_failure() {
  local code=$? line=$1
  sleep 1
  local extra=""
  local cfg; cfg="$(ls -t "$ROOT"/build/*/config.log 2>/dev/null | head -1 || true)"
  [ -n "$cfg" ] && extra="$(printf '\n--- tail of %s ---\n' "${cfg#$ROOT/}"; tail -n 25 "$cfg")"
  # Only the output of the failing step, newest last, short lines (annotations are size-limited).
  local stepout; stepout="$(awk '/^==> /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$BUILD_LOG" | grep -v '^clang ' | tail -n 40 | cut -c1-160)"
  local body; body="$(printf 'Step: %s (line %s, exit %s)\n' "$STEP" "$line" "$code"; printf '%s' "$stepout"; printf '%s' "$extra")"
  body="${body//'%'/'%25'}"; body="${body//$'\r'/}"; body="${body//$'\n'/'%0A'}"
  echo "::error title=Build failed during: ${STEP//[:,]/ }::$body"
  exit "$code"
}
trap 'report_failure $LINENO' ERR

min_for() { [ "$1" = x86_64 ] && echo 10.14 || echo 11.0; }
swift_min_for() { [ "$1" = x86_64 ] && echo 10.14.4 || echo 11.0; }
host_for() { [ "$1" = x86_64 ] && echo x86_64-apple-darwin || echo aarch64-apple-darwin; }

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK/src" "$DIST"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# A pkg-config wrapper that always asks for static link flags, so minipro links libusb statically
# (libusb's private flags pull in the IOKit/CoreFoundation/Security frameworks it needs).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/pkg-config" <<'EOF'
#!/bin/bash
exec "$REAL_PKG_CONFIG" --static "$@"
EOF
chmod +x "$WORK/bin/pkg-config"
export REAL_PKG_CONFIG="$(command -v pkg-config || command -v pkgconf)"
[ -n "$REAL_PKG_CONFIG" ] || { echo "pkg-config is required"; false; }

# ---------- sources ----------
log "Fetching libusb $LIBUSB_VERSION"
curl -fsSL "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" \
  -o "$WORK/src/libusb.tar.bz2"

log "Fetching minipro ($MINIPRO_REF)"
if ! git clone --depth 1 --branch "$MINIPRO_REF" https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro-git"; then
  echo "Tag $MINIPRO_REF not found, using master"
  git clone --depth 1 https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro-git"
fi
MINIPRO_DESC="$(git -C "$WORK/src/minipro-git" describe --tags --always 2>/dev/null || echo unknown)"
echo "minipro source: $MINIPRO_DESC"

# ---------- per-architecture builds ----------
for ARCH in "${ARCHS[@]}"; do
  MIN="$(min_for "$ARCH")"
  export MACOSX_DEPLOYMENT_TARGET="$MIN"
  CC_ARCH="clang -arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN"
  PREFIX="$WORK/$ARCH"

  log "libusb for $ARCH (min macOS $MIN)"
  rm -rf "$WORK/libusb-$ARCH" && mkdir -p "$WORK/libusb-$ARCH"
  tar -xjf "$WORK/src/libusb.tar.bz2" -C "$WORK/libusb-$ARCH" --strip-components=1
  ( cd "$WORK/libusb-$ARCH"
    CC="$CC_ARCH" ./configure --host="$(host_for "$ARCH")" --prefix="$PREFIX" \
      --disable-shared --enable-static --disable-dependency-tracking >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
    make install >/dev/null )

  log "minipro for $ARCH"
  rm -rf "$WORK/minipro-$ARCH" && cp -R "$WORK/src/minipro-git" "$WORK/minipro-$ARCH"
  ( cd "$WORK/minipro-$ARCH"
    PATH="$WORK/bin:$PATH" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
      make -j"$(sysctl -n hw.ncpu)" CC="$CC_ARCH" )
  cp "$WORK/minipro-$ARCH/minipro" "$WORK/minipro.$ARCH"

  log "ChipBurner for $ARCH"
  xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos$(swift_min_for "$ARCH")" \
    "$ROOT"/Sources/*.swift -o "$WORK/ChipBurner.$ARCH"
done

log "Making universal binaries"
lipo -create "$WORK"/minipro.* -output "$WORK/minipro"
lipo -create "$WORK"/ChipBurner.* -output "$WORK/ChipBurner"
lipo -info "$WORK/minipro" "$WORK/ChipBurner"

log "Checking that nothing links to Homebrew or other non-system libraries"
for BIN in "$WORK/minipro" "$WORK/ChipBurner"; do
  otool -L "$BIN"
  if otool -L "$BIN" | grep -E '^[[:space:]]' | grep -v -E '^[[:space:]]+(/usr/lib/|/System/Library/|@rpath/libswift)' ; then
    echo "ERROR: $BIN links to a library that is not on every Mac"; false
  fi
done

# ---------- chip database ----------
log "Locating the minipro chip database"
INFOIC="$(find "$WORK/src/minipro-git" -name infoic.xml -print -quit)"
LOGICIC="$(find "$WORK/src/minipro-git" -name logicic.xml -print -quit)"
if [ -z "$INFOIC" ]; then
  echo "ERROR: infoic.xml is not in the minipro source tree."
  echo "See minipro's README for how the chip database is obtained, then place it in Resources/minipro/."
  [ -f "$ROOT/Resources/minipro/infoic.xml" ] || false
  INFOIC="$ROOT/Resources/minipro/infoic.xml"
  LOGICIC="$ROOT/Resources/minipro/logicic.xml"
fi
echo "infoic:  $INFOIC"
echo "logicic: ${LOGICIC:-<none>}"

# ---------- assemble the app ----------
APP="$WORK/ChipBurner.app"
log "Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/minipro"
cp "$WORK/ChipBurner" "$WORK/minipro" "$APP/Contents/MacOS/"
cp "$INFOIC" "$APP/Contents/Resources/minipro/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[ -n "${LOGICIC:-}" ] && cp "$LOGICIC" "$APP/Contents/Resources/minipro/"
cp "$WORK/src/minipro-git/LICENSE"* "$APP/Contents/Resources/minipro/" 2>/dev/null || true
cat > "$APP/Contents/Resources/minipro/SOURCE.txt" <<EOF
This app runs minipro ($MINIPRO_DESC), licensed under the GNU GPL v3.
Source code: https://gitlab.com/DavidGriffith/minipro
libusb $LIBUSB_VERSION (LGPL 2.1): https://github.com/libusb/libusb
EOF
sed -e "s/__VERSION__/$APP_VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# ---------- smoke tests (no programmer needed) ----------
log "Smoke test: minipro options this app uses (from minipro's manual page)"
"$APP/Contents/MacOS/minipro" --version 2>&1 | head -3 || true
MANFILE="$(find "$WORK/src/minipro-git" -name 'minipro.1' -print -quit)"
[ -n "$MANFILE" ] || { echo "ERROR: minipro.1 manual page not found in the source tree"; false; }
MANTXT="$( (mandoc -T ascii "$MANFILE" 2>/dev/null || groff -man -Tascii "$MANFILE" 2>/dev/null || cat "$MANFILE") | col -b | sed 's/\\-/-/g')"
missing=0
OPTDOC=""
for opt in -q -k -L -d -p -r -w -m -b -E -x -y -s -e -v -c -D -T --infoic --logicic; do
  lines="$(grep -E -A2 "^[[:space:]]*(-[A-Za-z], )?$opt([,[:space:]]|$)" <<<"$MANTXT" | head -3 | tr -s ' ' || true)"
  if [ -z "$lines" ]; then echo "MISSING OPTION: $opt"; missing=1; else OPTDOC+="$lines"$'\n'; fi
done
echo "$OPTDOC"
NOTE="${OPTDOC//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=minipro options used by ChipBurner::$NOTE"
[ "$missing" = 0 ] || { echo "ERROR: minipro's options differ from what ChipBurner expects"; false; }

PROGDOC="$(grep -E -i -B1 -A3 'programmer|tl866a' <<<"$MANTXT" | head -40 | tr -s ' ')"
NOTE="${PROGDOC//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=minipro programmer selection::$NOTE"

note() { local t="$1" b="$2"; b="${b//'%'/'%25'}"; b="${b//$'\n'/'%0A'}"; echo "::notice title=$t::$b"; }
note "minipro: all options" "$(grep -E '^[[:space:]]*(-[A-Za-z][, ]|--[a-z])' <<<"$MANTXT" | sed -E 's/^[[:space:]]+//' | tr -s ' ' | head -80)"

note "minipro: pin check" "$(grep -E -i -B1 -A8 '(-z, --pin_check|pin.?check|pin.?detect|bad contact)' <<<"$MANTXT" | head -50 | tr -s ' ')"

log "Smoke test: chip database search for 27C256"
DBARGS=(--infoic "$APP/Contents/Resources/minipro/infoic.xml")
[ -f "$APP/Contents/Resources/minipro/logicic.xml" ] && DBARGS+=(--logicic "$APP/Contents/Resources/minipro/logicic.xml")
note "minipro: voltage options" "$(grep -E -A45 '^[[:space:]]*-o vpp=' <<<"$MANTXT" | head -45 | tr -s ' ')"
for c in 'ATMEGA328P@DIP28' 'AM27C256@DIP28' 'GAL16V8' 'PIC16F84A' 'W27C512@DIP28'; do
  note "minipro -d $c" "$("$APP/Contents/MacOS/minipro" "${DBARGS[@]}" -q TL866A -d "$c" 2>&1 | grep -v 'overridden database' | head -30)"
done

SEARCH="$("$APP/Contents/MacOS/minipro" "${DBARGS[@]}" -q TL866A -L 27C256 2>&1 || true)"
echo "$SEARCH" | head -20
NOTE="$(head -15 <<<"$SEARCH")"; NOTE="${NOTE//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=Chip search for 27C256::$NOTE"
grep -q -i '27C256' <<<"$SEARCH" || { echo "ERROR: chip search returned nothing"; false; }

log "Test: ChipBurner's database reader against the bundled database"
xcrun swiftc -O -sdk "$SDK" "$ROOT/Sources/ChipDatabase.swift" "$ROOT/tests/dbtest/main.swift" -o "$WORK/dbtest"
DBT="$("$WORK/dbtest" "$APP/Contents/Resources/minipro/infoic.xml" "$APP/Contents/Resources/minipro/logicic.xml" 2>&1)" || { echo "$DBT"; false; }
echo "$DBT"
NOTE="${DBT//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=Database reader test::$NOTE"

# ---------- sign and package ----------
log "Ad-hoc signing"
codesign --force --sign - "$APP/Contents/MacOS/minipro"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

ZIP="$DIST/ChipBurner-$APP_VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
log "Done: $ZIP"
