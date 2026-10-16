# ChipBurner

A native Mac app for TL866-series chip programmers (TL866A/CS, TL866II+, T48), built on the open-source
[minipro](https://gitlab.com/DavidGriffith/minipro) driver. Everything is inside the app: no Homebrew,
no drivers, nothing else to install.

- Runs on macOS 10.14.4 (Mojave) or newer, Intel and Apple silicon
- Check programmer, search chips, chip info (type, size, ID shown under the chip name)
- **Identify**: reads a chip's electronic ID and lists every matching chip in the database
- Read, blank check, program, verify, erase
- **Logic Test** for 74xx/40xx logic ICs, with pass/fail and the failing vectors in the log
- **Identify Logic…**: pick the pin count and ChipBurner tries every matching 5 V logic chip type, then lists the ones the chip passes
- **Connection**: ZIF socket, or ICSP with the programmer powering the board (`-i`) or the board powering itself (`-I`); chip info says whether a chip is ICSP capable
- **Check pin contact first** (on by default): runs minipro's pin contact check before read, blank check, verify and program; skipped automatically if the programmer doesn't support it
- **Voltages…**: override VPP, write VDD, verify VCC and pulse width when programming EPROMs, GALs and similar chips; the chip's defaults are shown, and overrides are cleared when the chip changes
- Log in its own window, shown with the **Log** button (or Window ▸ Log, ⌘L)
- **Memory** selector for microcontrollers: code, data EEPROM, config/fuses, user row, calibration
- **GAL/PLD** support: read to and program from `.jed` fuse files
- Hex view of the buffer with byte-sum and CRC32; text view for `.jed` and fuse files
- Open and save raw binary, Intel hex, `.jed` and `.conf`

## Getting the app (GitHub builds it)

1. Create a new GitHub repository (private is fine) and upload this folder's contents, including the
   hidden `.github` folder.
2. Open the repository's **Actions** tab. The "Build ChipBurner" run starts by itself (or press
   **Run workflow**). It takes about 5–10 minutes.
3. When it is green, open the run and download **ChipBurner** under *Artifacts*. Unzip it (you may need
   to unzip twice) to get `ChipBurner.app`.
4. Move it to Applications. The first time, **right-click → Open** and confirm, because the app is not
   signed with an Apple developer certificate.

To make a versioned download on the Releases page, push a tag such as `v0.1.0`.

## First use with a TL866A

1. Plug in the programmer and press **Check Programmer**. It shows the model and firmware.
2. minipro expects a particular TL866A/CS firmware. If the log says the firmware is out of date or a
   USB error appears, update or change the firmware once with XGecu's tools and check again.
   (Known case: TL866 firmware 03.2.86 gave `LIBUSB_ERROR_OVERFLOW` on Mojave; 03.2.81 worked.)
3. **Search…** for your chip (e.g. `27C256`) and pick the exact package, such as `@DIP28`.
4. **Read** a known-good chip first and compare the checksum with what you expect.

## Identify

Choose **Identify…**, pick the chip family (28-pin or 32-pin UV EPROM, or "same type as" the chip already
selected), and ChipBurner reads the ID and offers the matching parts. Chips without an electronic ID,
such as NMOS 2716/2732, still have to be picked with **Search…**.

## Identify Logic

Logic chips have no electronic ID, so ChipBurner runs the test vectors of every candidate with the chosen pin
count and keeps the ones the chip passes (the same approach as XGecu's own software). To keep this gentle, it
only tries 5 V chip types with the usual power layout – ground on the last pin of the first row, supply on the
last pin – and stops straight away if minipro reports overcurrent. Chips with other power pins, such as the
7490, can still be checked one at a time with **Logic Test**.

## Options

| Checkbox | minipro flag |
| --- | --- |
| Skip chip ID check | `-x` when reading, `-y` otherwise |
| Allow file size mismatch | `-s` |
| Don't erase before programming | `-e` |
| Don't verify after programming | `-v` |

## Building by hand

On a Mac with Xcode 15 or newer: `brew install autoconf automake libtool pkgconf` then `bash scripts/build.sh`.
The app lands in `dist/`.

## Licences

minipro is GPLv3 and libusb is LGPL 2.1; both are built from their public sources during the build, and
`ChipBurner.app/Contents/Resources/minipro/SOURCE.txt` says where to get them. ChipBurner runs minipro as a
separate program.
