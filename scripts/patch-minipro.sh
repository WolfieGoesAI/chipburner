#!/bin/bash
# Fixes applied to the minipro source before ChipBurner builds it (Mac and Android).
# Usage: patch-minipro.sh <minipro source dir>  (src/tl866a.c, src/prom.c and infoic.xml are changed)
#
# 1. TL866A/CS: wrong VPP/VCC byte in the begin-transaction message.
#    The TL866A database keeps the programming voltages as one byte, VPP code in the high nibble and
#    VCC code in the low nibble (0x02 = VCC 3.3 V, 0x20 = VPP 21 V, 0x30 = VPP 13.5 V – the same codes as
#    minipro's own tl866a_vcc/vpp tables). The firmware wants that byte as it is in msg[5]; minipro
#    shifts it left by 4, so a 3.3 V chip (0x02) is sent 0x20 – VCC 5 V and the 21 V VPP code – and a
#    21 V EPROM such as the 2716 (0x20) is sent 0x00 (12.5 V). Older minipro (opts1) sent it unshifted.
#    Seen as: AM29LV040B reads and erases (at 5 V!) but every write hangs the programmer (USB timeout),
#    while the vendor's software programs it fine on the same programmer.
set -euo pipefail
SRC="$1/src/tl866a.c"
[ -f "$SRC" ] || { echo "patch-minipro: $SRC not found"; exit 1; }
if grep -q 'msg\[5\] = handle->device->voltages.vpp << 4;' "$SRC"; then
  sed -i.orig 's/msg\[5\] = handle->device->voltages.vpp << 4;/msg[5] = (uint8_t)handle->device->voltages.vpp; \/* ChipBurner fix: VPP|VCC codes, unshifted *\//' "$SRC"
  grep -q 'ChipBurner fix: VPP|VCC codes' "$SRC" || { echo "patch-minipro: TL866A voltage fix did not apply"; exit 1; }
  rm -f "$SRC.orig"
  echo "patch-minipro: TL866A voltage byte fixed"
else
  echo "patch-minipro: TL866A voltage line not found (fixed upstream?) – left as it is"
fi

# 2. 23128 mask ROM (16K × 8, DIP28): read with minipro's bit-banged mask-ROM reader (prom.c), like its 2316
#    and HN43128P entries. Pinout: A0-A7 10..3, A8 25, A9 24, A10 21, A11 23, A12 2, A13 26, D0-D7 11-13 15-19,
#    /CS1 22, /CS2 20, CS3 27, NC 1. The chip-select levels are set by the mask, so all three are "cs_pins":
#    the reader tries all eight level combinations and keeps the first that gives data other than all FF.
#    No ID read, no programming voltage – only 5 V, GND and logic levels.
PROM="$1/src/prom.c"
if grep -q '23128, ChipBurner' "$PROM"; then
  echo "patch-minipro: 23128 already present"
else
  grep -q 'Type 0x81; 2048x8; DIP24 w/ programmable CE (2316)' "$PROM" || { echo "patch-minipro: prom.c mask ROM table not found"; exit 1; }
  perl -0pi -e 's/(\.cs_pins = \(uint8_t\[\]\)\{ 20, 18, 21, 0 \},\s*\.compare_mask = 0xff \})/$1,\n\t\/* Type 0x82; 16384x8; DIP28 w\/ mask-programmed \/CS1 (22), \/CS2 (20), CS3 (27) (23128, ChipBurner) *\/\n\t{ .gnd_pins = (uint8_t[]){ 14, 0 },\n\t  .vcc_pins = (uint8_t[]){ 28, 0 },\n\t  .data_bus_pins = (uint8_t[]){ 11, 12, 13, 15, 16, 17, 18, 19, 0 },\n\t  .addr_bus_pins =\n\t\t  (uint8_t[]){ 10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 0 },\n\t  .ce_pins = (uint8_t[]){ 0 },\n\t  .cs_pins = (uint8_t[]){ 22, 20, 27, 0 },\n\t  .compare_mask = 0xff }/' "$PROM"
  grep -q '23128, ChipBurner' "$PROM" || { echo "patch-minipro: 23128 prom.c entry did not apply"; exit 1; }
  echo "patch-minipro: 23128 mask ROM reader added"
fi
DB="$1/infoic.xml"
if [ -f "$DB" ] && ! grep -q 'name="23128@DIP28"' "$DB"; then
  perl -0pi -e 's/(name="2316\@DIP24".*?<\/custom\s*>)/$1\n    <custom\n        name="Mask ROM"\n      >\n          <ic\n          name="23128\@DIP28"\n          type="1"\n          protocol_id="0x80000001"\n          variant="0x82"\n          read_buffer_size="0x10"\n          write_buffer_size="0x00"\n          code_memory_size="0x4000"\n          data_memory_size="0x00"\n          data_memory2_size="0x00"\n          page_size="0x0000"\n          pages_per_block="0x0000"\n          chip_id="0x00000000"\n          voltages="0x0900"\n          pulse_delay="0x0000"\n          flags="0x00000000"\n          chip_info="0x0000"\n          pin_map="0x00000c16"\n          blank_value="0x00"\n          package_details="0x1c000000"\n          config="NULL"\n      \/>\n    <\/custom\n    >/gs' "$DB"
  n=$(grep -c 'name="23128@DIP28"' "$DB")
  [ "$n" -ge 1 ] || { echo "patch-minipro: 23128 database entry did not apply"; exit 1; }
  echo "patch-minipro: 23128 added to $n database sections"
fi
