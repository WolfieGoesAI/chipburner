#!/bin/bash
# Builds ChipBurner.app (universal: Intel + Apple silicon, macOS 10.14.4+) on a macOS machine
# with Xcode command-line tools. Used by the GitHub workflow; can also be run by hand.
#
#   scripts/build.sh            -> dist/ChipBurner-<version>.zip
#
# Environment overrides:
#   APP_VERSION     version string (default 0.1.0)
#   MINIPRO_REF     minipro git tag/branch, or "main" for the default (development) branch (default: main)
#   LIBUSB_VERSION  libusb release (default 1.0.27)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
DIST="$ROOT/dist"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MINIPRO_REF="${MINIPRO_REF:-main}"
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
if [ "$MINIPRO_REF" = "main" ]; then
  git clone --depth 50 https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro-git"
elif ! git clone --depth 1 --branch "$MINIPRO_REF" https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro-git"; then
  echo "Tag $MINIPRO_REF not found, using the default branch"
  git clone --depth 50 https://gitlab.com/DavidGriffith/minipro.git "$WORK/src/minipro-git"
fi
git -C "$WORK/src/minipro-git" fetch -q --depth 1 origin 'refs/tags/0.7.4:refs/tags/0.7.4' 2>/dev/null || true
MINIPRO_DESC="$(git -C "$WORK/src/minipro-git" describe --tags --always 2>/dev/null || echo unknown) ($(git -C "$WORK/src/minipro-git" log -1 --format=%cs))"
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
for opt in -q -k -L -d -p -r -w -m -b -E -x -y -s -e -v -c -D -T -i -I -u -P -t -F --infoic --logicic; do
  lines="$(grep -E -A2 "^[[:space:]]*(-[A-Za-z], )?$opt([,[:space:]]|$)" <<<"$MANTXT" | head -3 | tr -s ' ' || true)"
  if [ -z "$lines" ]; then echo "MISSING OPTION: $opt"; missing=1; else OPTDOC+="$lines"$'\n'; fi
done
echo "$OPTDOC"
NOTE="${OPTDOC//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=minipro options used by ChipBurner::$NOTE"
for o in 'vpp=<value>' 'vdd=<value>' 'vcc=<value>' 'pulse=<value>'; do
  grep -q -F -- "-o $o" <<<"$MANTXT" || { echo "MISSING OPTION: -o $o"; missing=1; }
done
[ "$missing" = 0 ] || { echo "ERROR: minipro's options differ from what ChipBurner expects"; false; }

PROGDOC="$(grep -E -i -B1 -A3 'programmer|tl866a' <<<"$MANTXT" | head -40 | tr -s ' ')"
NOTE="${PROGDOC//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=minipro programmer selection::$NOTE"

note() { local t="$1" b="$2"; b="${b//'%'/'%25'}"; b="${b//$'\n'/'%0A'}"; echo "::notice title=$t::$b"; }
note "minipro: all options" "$(grep -E '^[[:space:]]*(-[A-Za-z][, ]|--[a-z])' <<<"$MANTXT" | sed -E 's/^[[:space:]]+//' | tr -s ' ' | head -80)"

log "Smoke test: chip database search for 27C256"
DBARGS=(--infoic "$APP/Contents/Resources/minipro/infoic.xml")
[ -f "$APP/Contents/Resources/minipro/logicic.xml" ] && DBARGS+=(--logicic "$APP/Contents/Resources/minipro/logicic.xml")
SEARCH="$("$APP/Contents/MacOS/minipro" "${DBARGS[@]}" -q TL866A -L 27C256 2>&1 || true)"
echo "$SEARCH" | head -20
NOTE="$(head -15 <<<"$SEARCH")"; NOTE="${NOTE//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=Chip search for 27C256::$NOTE"
grep -q -i '27C256' <<<"$SEARCH" || { echo "ERROR: chip search returned nothing"; false; }

log "Test: ChipBurner's database reader against the bundled database"
xcrun swiftc -O -sdk "$SDK" "$ROOT/Sources/ChipDatabase.swift" "$ROOT/Sources/ChipCapabilities.swift" "$ROOT/Sources/DataFormats.swift" "$ROOT/Sources/BufferOps.swift" "$ROOT/Sources/ChipTests.swift" "$ROOT/tests/dbtest/main.swift" -o "$WORK/dbtest"
DBT="$("$WORK/dbtest" "$APP/Contents/Resources/minipro/infoic.xml" "$APP/Contents/Resources/minipro/logicic.xml" 2>&1)" || {
  echo "$DBT"
  X="$APP/Contents/Resources/minipro/infoic.xml"
  {
    echo "### dbtest failures"; grep -E "FAIL|not found" <<<"$DBT" | head -30
    echo "### minipro source"; echo "$MINIPRO_DESC"
    echo "### files in minipro source"; (cd "$WORK/src/minipro-git" && ls; ls -la *.xml 2>/dev/null)
    echo "### ATMEGA8A in infoic"; grep -n -i -B3 -A22 'ATMEGA8A' "$X" | head -60 | tr -s ' '
    echo "### PIC16F84A in infoic"; grep -n -i -B3 -A5 'PIC16F84A' "$X" | head -30 | tr -s ' '
    echo "### database sections"; grep -n -E '<database|type="INFOIC' "$X" | head
    echo "### dbtest header"; head -8 <<<"$DBT"
    EL="$(grep -o 'at line [0-9]*' <<<"$DBT" | head -1 | grep -o '[0-9]*')"
    if [ -n "$EL" ]; then echo "### infoic.xml around line $EL"; sed -n "$((EL-12)),$((EL+3))p" "$X" | cat -v | cut -c1-300; fi
    L1="$(grep -n 'type="INFOIC"' "$X" | head -1 | cut -d: -f1)"
    echo "### TL866A section: ic count"; sed -n "${L1},\$p" "$X" | grep -c '<ic'
    echo "### TL866A section ATMEGA8 / PIC16F84 / 27C256 names"; sed -n "${L1},\$p" "$X" | grep -E 'name="[^"]*(ATMEGA8|PIC16F84|27C256)' | head -12 | tr -s ' '
    echo "### TL866A section first entries"; sed -n "${L1},$((L1+60))p" "$X" | grep -E 'name=|type=' | head -12 | tr -s ' '
    for q in TL866A TL866II; do echo "### minipro -q $q -L ATMEGA8"; "$APP/Contents/MacOS/minipro" --infoic "$X" --logicic "$APP/Contents/Resources/minipro/logicic.xml" -q $q -L ATMEGA8 2>&1 | grep -v overridden | head -8; done
    echo "### minipro -q TL866A -L 27C256"; "$APP/Contents/MacOS/minipro" --infoic "$X" --logicic "$APP/Contents/Resources/minipro/logicic.xml" -q TL866A -L 27C256 2>&1 | grep -v overridden | head -8
    echo "### avr_15 definition"; grep -n -B4 -A30 'name="avr_15"' "$X" | head -50 | tr -s ' '
    echo "### pic_23 definition"; grep -n -B2 -A30 'name="pic_23"' "$X" | head -40 | tr -s ' '
    echo "### configurations tags"; grep -n -E '<configurations|</configurations|<database|</database' "$X" | head -20
    echo "### other xml in source"; (cd "$WORK/src/minipro-git" && find . -name '*.xml' | head)
    echo "### minipro -d ATMEGA8A@DIP28"; "$APP/Contents/MacOS/minipro" --infoic "$X" --logicic "$APP/Contents/Resources/minipro/logicic.xml" -q TL866A -d ATMEGA8A@DIP28 2>&1 | head -20
    echo "### minipro -L ATMEGA8"; "$APP/Contents/MacOS/minipro" --infoic "$X" -q TL866A -L ATMEGA8 2>&1 | head -10
  } > "$ROOT/diag.txt"
  false
}
echo "$DBT"
NOTE="${DBT//'%'/'%25'}"; NOTE="${NOTE//$'\n'/'%0A'}"
echo "::notice title=Database reader test::$NOTE"

log "Test: JED decoder against Galette's assembled test cases"
xcrun swiftc -O -sdk "$SDK" "$ROOT/Sources/GalDecoder.swift" "$ROOT/Sources/GalAssembler.swift" "$ROOT/Sources/LogicVectors.swift" "$ROOT/Sources/PalReadout.swift" "$ROOT/Sources/Minipro.swift" "$ROOT/tests/galtest/main.swift" -o "$WORK/galtest"
GT="$("$WORK/galtest" "$ROOT/tests/gal/cases" 2>&1)" || { echo "$GT"; printf '### galtest\n%s\n' "$(grep -v '^ok ' <<<"$GT" | grep -v '^;' | head -150)" > "$ROOT/diag.txt"; false; }
echo "$GT"
note "JED decoder test" "$(grep -v '^;' <<<"$GT" | tail -40)"

# Extra diagnostics: add diag "title" "text" lines here; the workflow prints them as notices.
DIAG=""
diag() { DIAG+="### $1"$'\n'"$2"$'\n\n'; }
diag "minipro source" "$MINIPRO_DESC"$'\n'"$("$APP/Contents/MacOS/minipro" --version 2>&1 | head -5)"
diag "Test-related chip types" "$(grep -E '^(SRAM|DRAMLOGIC|LOGICNAMES|TL866A entries)' <<<"$DBT")"
diag "get_fuse_value" "$(grep -rn -A40 '^int get_fuse_value\|^static int get_fuse_value' "$WORK/src/minipro-git/src/" | cut -c1-200 | sed 's|.*/src/||' | head -60)"
diag "firmware update" "$("$APP/Contents/MacOS/minipro" --help 2>&1 | grep -i -A1 'update\|-F' | head -8; grep -rn -i 'update.dat\|updateII\|bootloader\|firmware' "$WORK/src/minipro-git/src/main.c" | head -25 | cut -c1-200 | sed 's|.*/src/||')"
diag "Fuses & Locks families" "$(grep -E '^(FL|FUSES)' <<<"$DBT")"
printf '%s' "$DIAG" > "$ROOT/diag.txt"

log "Smoke test: launch the app and check that the window comes up"
mkdir -p "$DIST"
CHIPBURNER_SMOKETEST=1 CHIPBURNER_SCREENSHOT="$DIST/screenshot.png" "$APP/Contents/MacOS/ChipBurner" > "$WORK/smoke.log" 2>&1 &
SMOKE_PID=$!
for _ in $(seq 1 60); do kill -0 "$SMOKE_PID" 2>/dev/null || break; sleep 1; done
kill "$SMOKE_PID" 2>/dev/null || true
SMOKE="$(cat "$WORK/smoke.log")"
echo "$SMOKE"
diag "App launch smoke test" "$(grep -v -i 'overridden database' <<<"$SMOKE" | grep -v '^SMOKE  \|^SMOKE row' | tail -40)"
grep -q "SMOKE OK" <<<"$SMOKE" || { echo "ERROR: the app window did not come up"; printf '%s' "$DIAG" > "$ROOT/diag.txt"; false; }
printf '%s' "$DIAG" > "$ROOT/diag.txt"

# ---------- sign and package ----------
log "Ad-hoc signing"
codesign --force --sign - "$APP/Contents/MacOS/minipro"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

ZIP="$DIST/ChipBurner-$APP_VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
log "Done: $ZIP"
