#!/bin/bash
# Fixes applied to the minipro source before ChipBurner builds it (Mac and Android).
# Usage: patch-minipro.sh <minipro source dir>
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
