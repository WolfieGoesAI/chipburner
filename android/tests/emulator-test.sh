#!/bin/bash
# Smoke test in an Android emulator: minipro runs on Android, the app starts, and a few screens work.
# Writes android-emulator.txt and screenshots to shots/.
set -u
OUT="${OUT:-android-emulator.txt}"
mkdir -p shots
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }
APK="$(ls dist/*.apk | head -1)"

say "### device"; adb shell getprop ro.build.version.release | tee -a "$OUT"
say "### minipro on Android"
adb push android/app/src/main/jniLibs/x86_64/libminipro.so /data/local/tmp/minipro >/dev/null
adb push android/app/src/main/assets/minipro/infoic.xml /data/local/tmp/infoic.xml >/dev/null
adb shell chmod 755 /data/local/tmp/minipro
adb shell /data/local/tmp/minipro --version 2>&1 | head -5 | tee -a "$OUT"
say "--- -L 27C256"
adb shell "/data/local/tmp/minipro --infoic /data/local/tmp/infoic.xml -q TL866A -L 27C256" 2>&1 | head -8 | tee -a "$OUT"
say "--- -k (no programmer attached)"
adb shell "/data/local/tmp/minipro --infoic /data/local/tmp/infoic.xml -k" 2>&1 | head -5 | tee -a "$OUT"

say "### install and start"
adb install -r "$APK" 2>&1 | tail -1 | tee -a "$OUT"
adb logcat -c
adb shell am start -W -n com.wolfiegoesai.chipburner/.MainActivity 2>&1 | tail -3 | tee -a "$OUT"
sleep 30
shot() { adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png "shots/$1.png" >/dev/null; }
tap_text() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  adb pull /sdcard/ui.xml ui.xml >/dev/null 2>&1
  python3 - "$@" <<'PY'
import re, sys, subprocess
want = sys.argv[1]
last = len(sys.argv) > 2
x = open("ui.xml", encoding="utf-8", errors="replace").read()
nodes = list(re.finditer(r'<node [^>]*>', x))
if last: nodes.reverse()
for m in nodes:
    n = m.group(0)
    t = re.search(r' text="([^"]*)"', n); d = re.search(r'content-desc="([^"]*)"', n)
    if (t and t.group(1) == want) or (d and d.group(1) == want):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        cx = (int(b.group(1)) + int(b.group(3))) // 2; cy = (int(b.group(2)) + int(b.group(4))) // 2
        subprocess.run(["adb", "shell", "input", "tap", str(cx), str(cy)])
        print("tapped", want, cx, cy); break
else:
    print("not found:", want)
PY
}
shot 1-chip
tap_text "Search" | tee -a "$OUT"; sleep 2
adb shell input text 27C256; sleep 3
shot 2-search
adb shell input keyevent 111; sleep 2
tap_text "AM27C256" | tee -a "$OUT"; sleep 2
shot 3-chosen
tap_text "Info" | tee -a "$OUT"; sleep 8
shot 4-info
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "Pinout" | tee -a "$OUT"; sleep 2
shot 4b-pinout
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "Test" | tee -a "$OUT"; sleep 2
shot 4f-chiptest
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "Search" | tee -a "$OUT"; sleep 2
for i in $(seq 12); do adb shell input keyevent 67; done
adb shell input text 74161; sleep 3
adb shell input keyevent 111; sleep 2
tap_text "74161" last | tee -a "$OUT"; sleep 2
tap_text "Pinout" | tee -a "$OUT"; sleep 2
shot 4c-logic-pinout
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "Identify" | tee -a "$OUT"; sleep 2
shot 4d-ident
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "More" | tee -a "$OUT"; sleep 2
shot 4e-menu
adb shell input keyevent KEYCODE_BACK; sleep 1
tap_text "Buffer" | tee -a "$OUT"; sleep 2
tap_text "New" | tee -a "$OUT"; sleep 2
tap_text "OK" | tee -a "$OUT"; sleep 2
tap_text "A" | tee -a "$OUT"; tap_text "5" | tee -a "$OUT"; sleep 1
shot 5-buffer
tap_text "Test" | tee -a "$OUT"; sleep 2
shot 6-test
tap_text "Log" | tee -a "$OUT"; sleep 2
shot 7-log
say "### crashes"
adb logcat -d | grep -E "FATAL|AndroidRuntime|chipburner" | tail -40 | tee -a "$OUT"
ls -la shots | tee -a "$OUT"
