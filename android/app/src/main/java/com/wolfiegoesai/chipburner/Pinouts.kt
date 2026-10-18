package com.wolfiegoesai.chipburner

/** A chip's pinout, DIP top view (or PLCC32): pins[0] is pin 1. */
data class ChipPinout(
    val title: String,
    val pins: List<String>,
    val notes: List<String> = emptyList(),
    /** Per pin for logic chips: i input, o output, b bidirectional, c clock, g ground, v supply, n unused. */
    val roles: List<Char> = emptyList(),
    val plcc32: Boolean = false,
)

/** Pinouts for JEDEC memories, PLCC32, GALs, serial memories, common microcontrollers and logic chips (ported from the Mac app). */
object Pinouts {
    fun find(chip: String, size: Int?, isSRAM: Boolean = false): ChipPinout? {
        val upper = chip.uppercase()
        val name = upper.substringBefore('@')
        if (name.isEmpty()) return null
        val pkg = upper.substringAfter('@', "")
        val pkgPins = pkg.filter { it.isDigit() }.toIntOrNull()
        val isDIP = pkg.isEmpty() || pkg.startsWith("DIP") || pkg.startsWith("PDIP") || pkg.startsWith("CDIP")
        val isSO8 = pkg.startsWith("SOP8") || pkg.startsWith("SOIC8") || pkg.startsWith("SO8")
        fun has(p: String) = Regex(p).containsMatchIn(name)

        if ((isDIP || isSO8) && (pkgPins == null || pkgPins == 8)) {
            if (has("^[A-Z]*24(C|LC|AA|FC|CS|WC|M)?[0-9]")) return i2cEEPROM
            if (has("^[A-Z]*93(C|LC|AA|S)?[0-9]")) return microwire
            if (has("^[A-Z]*25(Q|LC|AA|X|P|F|VF|PE|DF|C|FL|LQ|SF|CL|LV|L|U|B)?[0-9]")) return spiMemory
        }
        if (pkg.startsWith("PLCC32") && size != null && size >= 8192 && size <= 1048576) {
            val dip = memoryPinout(name, if (size >= 131072) 32 else 28, size, isSRAM) ?: return null
            var p = dip.pins
            if (p.size == 28) {
                val q = MutableList(32) { "NC" }
                for (k in 1..28) {
                    val t = when (k) { in 1..10 -> k + 1; in 11..14 -> k + 2; in 15..22 -> k + 3; else -> k + 4 }
                    q[t - 1] = p[k - 1]
                }
                p = q
            }
            return ChipPinout(dip.title + " – PLCC32", p,
                dip.notes + "PLCC32 seen from above; pin 1 is in the middle of the top edge (the dot / bevelled corner side). Needs a PLCC32-to-DIP32 adapter in the ZIF socket.",
                plcc32 = true)
        }
        if (!isDIP) return null

        if (has("16V8")) return gal16v8
        if (has("20V8")) return gal20v8
        if (has("22V10")) return gal22v10
        if (has("20RA10")) return gal20ra10

        if (has("^ATMEGA(8|48|88|168|328)(A|P|PA|PB|V|L)*$")) return mega328
        if (has("^(ATMEGA(16|32|164|324|644|1284|8535)|AT90S8535|AT90LS8535)(A|P|PA|PB|V|L)*$")) return mega16
        if (has("^ATTINY(11|12|13|15|25|45|85)(A|V|L)*$")) return tiny85
        if (has("^ATTINY(24|44|84)(A|V)*$")) return tiny84
        if (has("^ATTINY(26|261|461|861)(A|V|L)*$")) return tiny861
        if (has("^(ATTINY2313|AT90S2313|ATTINY4313)")) return tiny2313
        if (has("^AT89C(1051|2051|4051)")) return at89c2051
        if (has("^PIC16(L)?F(84|627|628|648)")) return pic16f628
        if (has("^PIC12(L)?F(629|675|683)")) return pic12f675
        val usb = has("^PIC18L?F(2455|2550|4455|4550|2458|2553|4458|4553)")
        if (has("^PIC16L?F(7[236]|73[7]|76[7]|87[036]A?|88[236])$") || (has("^PIC18L?F2[0-9]+[A-Z0-9]*$") && !has("J|^PIC18L?F2[34]31"))) {
            if (pkgPins == null || pkgPins == 28) return pic28(usb)
        }
        if (has("^PIC16L?F(7[47]|74[7]|77[7]|87[147]A?|88[47])$") || (has("^PIC18L?F4[0-9]+[A-Z0-9]*$") && !has("J|^PIC18L?F4[34]31"))) {
            if (pkgPins == null || pkgPins == 40) return pic40(usb)
        }
        if ((pkgPins == null || pkgPins == 40) &&
            has("^(AT89(C|S|LV|LS)5[0-9]|AT89S825[23]|I?87C5[0-9]|I?8751|P87C5|P89C5|P89V5|SST89|W78E|W78C|W77E|SM89|80C51|8751)")) return mcs51

        if (size == null || size <= 0) return null
        val pins = pkgPins ?: if (size <= 4096) 24 else if (size <= 0x10000) 28 else 32
        return memoryPinout(name, pins, size, isSRAM)
    }

    fun memoryPinout(name: String, pins: Int, size: Int, isSRAM: Boolean): ChipPinout? {
        fun has(p: String) = Regex(p).containsMatchIn(name)
        val eeprom = has("28(C|HC|LV)[0-9]") && !has("27")
        val flash = has("(29(F|C|EE|LV|SF)|39(SF|VF|LF)|49F)[0-9]")
        val eprom = has("27(C|SF|E|HC|LV|W|V)?[0-9]")
        val sram = (isSRAM && !has("^PIC")) || has("(^|[A-Z])(6116|6264|62256|61256|628128|628512|61512|W24|W2465|DS12)")
        if (sram) return sramPinout(pins, size)
        if (flash) return flashPinout(pins, size)
        if (eeprom) return eepromPinout(pins, size)
        if (eprom) return epromPinout(pins, size)
        if (has("2364") && pins == 24 && size == 8192) {
            return ChipPinout("2364 mask ROM (8K × 8)", base24(18 to "A12", 20 to "CS", 21 to "A11"), listOf(
                "Mask ROM: read-only, it can't be erased or programmed.",
                "The chip-select level on pin 20 was set when the ROM was made (active low on most). If a read gives all FF or one value, the ROM may need CS high.",
                "Not pin-compatible with a 2764 (28 pins); to replace it with an EPROM use a 2364 adapter."))
        }
        return null
    }

    private const val JEDEC = "Standard JEDEC pinout – compare with your chip's data sheet."

    private fun apply(base: List<String>, changes: Array<out Pair<Int, String>>): List<String> {
        val p = base.toMutableList()
        for ((pin, label) in changes) p[pin - 1] = label
        return p
    }

    private fun base28(vararg c: Pair<Int, String>) = apply(listOf("VPP", "A12", "A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
        "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "A11", "A9", "A8", "A13", "A14", "VCC"), c)
    private fun base32(vararg c: Pair<Int, String>) = apply(listOf("VPP", "A16", "A15", "A12", "A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
        "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "A11", "A9", "A8", "A13", "A14", "NC", "/PGM", "VCC"), c)
    private fun base24(vararg c: Pair<Int, String>) = apply(listOf("A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
        "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "VPP", "A9", "A8", "VCC"), c)

    fun epromPinout(pins: Int, size: Int): ChipPinout? = when (pins to size) {
        24 to 2048 -> ChipPinout("2716 EPROM (2K × 8)", base24(), listOf(JEDEC))
        24 to 4096 -> ChipPinout("2732 EPROM (4K × 8)", base24(20 to "/OE/VPP", 21 to "A11"), listOf(JEDEC))
        28 to 8192 -> ChipPinout("2764 EPROM (8K × 8)", base28(26 to "NC", 27 to "/PGM"), listOf(JEDEC))
        28 to 16384 -> ChipPinout("27128 EPROM (16K × 8)", base28(27 to "/PGM"), listOf(JEDEC))
        28 to 32768 -> ChipPinout("27256 EPROM (32K × 8)", base28(), listOf(JEDEC))
        28 to 65536 -> ChipPinout("27512 EPROM (64K × 8)", base28(1 to "A15", 22 to "/OE/VPP"), listOf(JEDEC))
        32 to 131072 -> ChipPinout("27C010 EPROM (128K × 8)", base32(), listOf(JEDEC))
        32 to 262144 -> ChipPinout("27C020 EPROM (256K × 8)", base32(30 to "A17"), listOf(JEDEC))
        32 to 524288 -> ChipPinout("27C040 EPROM (512K × 8)", base32(30 to "A17", 31 to "A18"), listOf(JEDEC))
        32 to 1048576 -> ChipPinout("27C080 / 27C801 EPROM (1M × 8)", base32(1 to "A19", 24 to "/OE/VPP", 30 to "A17", 31 to "A18"), listOf(JEDEC))
        else -> null
    }

    fun eepromPinout(pins: Int, size: Int): ChipPinout? = when (pins to size) {
        24 to 2048 -> ChipPinout("28C16 EEPROM (2K × 8)", base24(21 to "/WE"), listOf(JEDEC))
        28 to 8192 -> ChipPinout("28C64 EEPROM (8K × 8)", base28(1 to "RDY/BSY", 26 to "NC", 27 to "/WE"), listOf(JEDEC, "Pin 1 is NC on some makes."))
        28 to 32768 -> ChipPinout("28C256 EEPROM (32K × 8)", base28(1 to "A14", 26 to "A13", 27 to "/WE"), listOf(JEDEC))
        32 to 131072 -> ChipPinout("28C010 EEPROM (128K × 8)", base32(1 to "NC", 30 to "NC", 31 to "/WE"), listOf(JEDEC))
        else -> null
    }

    fun flashPinout(pins: Int, size: Int): ChipPinout? = when (pins to size) {
        28 to 32768 -> ChipPinout("29C256 flash (32K × 8)", base28(1 to "A14", 26 to "A13", 27 to "/WE"), listOf(JEDEC))
        32 to 131072 -> ChipPinout("29F010 / 39SF010 flash (128K × 8)", base32(1 to "NC", 30 to "NC", 31 to "/WE"), listOf(JEDEC))
        32 to 262144 -> ChipPinout("29F020 / 39SF020 flash (256K × 8)", base32(1 to "NC", 30 to "A17", 31 to "/WE"), listOf(JEDEC, "On 29F002-type chips pin 1 is /RESET."))
        32 to 524288 -> ChipPinout("29F040 / 39SF040 flash (512K × 8)", base32(1 to "A18", 30 to "A17", 31 to "/WE"), listOf(JEDEC))
        else -> null
    }

    fun sramPinout(pins: Int, size: Int): ChipPinout? = when (pins to size) {
        24 to 2048 -> ChipPinout("6116 SRAM (2K × 8)", base24(18 to "/CS", 21 to "/WE"), listOf(JEDEC))
        28 to 8192 -> ChipPinout("6264 SRAM (8K × 8)", base28(1 to "NC", 20 to "/CS1", 26 to "CS2", 27 to "/WE"), listOf(JEDEC))
        28 to 32768 -> ChipPinout("62256 SRAM (32K × 8)", base28(1 to "A14", 20 to "/CS", 26 to "A13", 27 to "/WE"), listOf(JEDEC))
        32 to 131072 -> ChipPinout("628128 SRAM (128K × 8)", base32(1 to "NC", 3 to "A14", 22 to "/CS1", 29 to "/WE", 30 to "CS2", 31 to "A15"), listOf(JEDEC))
        32 to 524288 -> ChipPinout("628512 SRAM (512K × 8)", base32(1 to "A18", 3 to "A14", 22 to "/CS", 29 to "/WE", 30 to "A17", 31 to "A15"), listOf(JEDEC))
        else -> null
    }

    fun pic28(usb: Boolean): ChipPinout {
        val p = mutableListOf("MCLR/VPP", "RA0/AN0", "RA1/AN1", "RA2/AN2", "RA3/AN3", "RA4/T0CKI", "RA5/AN4", "VSS", "OSC1/RA7", "OSC2/RA6",
            "RC0", "RC1", "RC2/CCP1", "RC3/SCK/SCL", "RC4/SDI/SDA", "RC5/SDO", "RC6/TX", "RC7/RX", "VSS", "VDD",
            "RB0/INT", "RB1", "RB2", "RB3/PGM", "RB4", "RB5", "RB6/PGC", "RB7/PGD")
        if (usb) { p[13] = "VUSB"; p[14] = "RC4/D-"; p[15] = "RC5/D+" }
        return ChipPinout("PIC16F / PIC18F, 28 pins", p, listOf("Standard 28-pin PIC layout; some parts have RE3 on pin 1 or other alternate functions – check the data sheet."))
    }

    fun pic40(usb: Boolean): ChipPinout {
        val p = mutableListOf("MCLR/VPP", "RA0/AN0", "RA1/AN1", "RA2/AN2", "RA3/AN3", "RA4/T0CKI", "RA5/AN4", "RE0/RD", "RE1/WR", "RE2/CS",
            "VDD", "VSS", "OSC1", "OSC2", "RC0", "RC1", "RC2/CCP1", "RC3/SCK/SCL", "RD0", "RD1",
            "RD2", "RD3", "RC4/SDI/SDA", "RC5/SDO", "RC6/TX", "RC7/RX", "RD4", "RD5", "RD6", "RD7",
            "VSS", "VDD", "RB0/INT", "RB1", "RB2", "RB3/PGM", "RB4", "RB5", "RB6/PGC", "RB7/PGD")
        if (usb) { p[17] = "VUSB"; p[22] = "RC4/D-"; p[23] = "RC5/D+" }
        return ChipPinout("PIC16F / PIC18F, 40 pins", p, listOf("Standard 40-pin PIC layout; some parts have RE3 on pin 1 or other alternate functions – check the data sheet."))
    }

    // MARK: Logic chips

    /** "74LS00" / "SN74HCT00N" / "CD4011BE" → "7400" / "4011". */
    fun logicBase(name: String): String {
        val n = name.uppercase().substringBefore('@')
        Regex("74[A-Z]*([0-9]{2,6})").find(n)?.let { return "74" + it.groupValues[1] }
        Regex("4[0-9]{3,4}").find(n)?.let { return it.value }
        return n
    }

    /** Pin roles from the test vectors: G/V power, 0/1 driven (input), C clock, L/H/Z sensed (output). */
    fun logicRoles(vectors: List<String>, pins: Int): List<Char> = (0 until pins).map { p ->
        val s = vectors.mapNotNull { it.getOrNull(p) }.toSet()
        when {
            s.isEmpty() || s == setOf('X') -> 'n'
            s == setOf('G') -> 'g'
            s == setOf('V') -> 'v'
            else -> {
                val driven = s.any { it == '0' || it == '1' }
                val sensed = s.any { it == 'L' || it == 'H' || it == 'Z' }
                when {
                    'C' in s && !sensed -> 'c'
                    driven && sensed -> 'b'
                    sensed -> 'o'
                    else -> 'i'
                }
            }
        }
    }

    fun logic(name: String, pins: Int, group: String, vectors: List<String>): ChipPinout? {
        if (pins < 4 || pins % 2 != 0) return null
        val roles = logicRoles(vectors, pins)
        val display = name.substringBefore('@')
        val members = listOf(name) + group.split(',').map { it.trim() }
        for (m in members) {
            val base = logicBase(m)
            val entry = logicNames[base] ?: logicNames[m] ?: continue
            val items = entry.second.split(' ')
            if (items.size != pins) continue
            val names = items.map { it.substringAfter(':') }
            val r = items.mapIndexed { i, it -> if (it.first() == 'i' && roles.getOrNull(i) == 'c') 'c' else it.first() }
            val title = if (base == logicBase(display)) "$display – ${entry.first}" else "$display – same pinout as $base (${entry.first})"
            return ChipPinout(title, names, listOf("Pin names from the data sheet; outputs in green."), r)
        }
        val labels = roles.map {
            when (it) { 'g' -> "GND"; 'v' -> "VCC"; 'o' -> "out"; 'c' -> "clock"; 'b' -> "in/out"; 'n' -> "–"; else -> "in" }
        }
        return ChipPinout("$display – pin functions", labels,
            listOf("Worked out from minipro's test vectors (in, out, clock, power); \"–\" = not used by the test. Check the data sheet for the signal names."), roles)
    }

    val i2cEEPROM = ChipPinout(title = "24Cxx I²C EEPROM", pins = listOf("A0", "A1", "A2", "GND", "SDA", "SCL", "WP", "VCC"),
                                      notes = listOf("A0–A2 are not connected inside some sizes."))
    val microwire = ChipPinout(title = "93Cxx Microwire EEPROM", pins = listOf("CS", "SK", "DI", "DO", "GND", "ORG", "NC", "VCC"),
                                      notes = listOf("ORG selects 8-bit (GND) or 16-bit (VCC) words."))
    val spiMemory = ChipPinout(title = "25xx SPI flash / EEPROM", pins = listOf("/CS", "DO", "/WP", "GND", "DI", "CLK", "/HOLD", "VCC"),
                                      notes = listOf("Most 25-series parts are 3.3 V – check before programming."))
    val gal16v8 = ChipPinout(title = "GAL16V8", pins = listOf("CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "GND",
                                                            "/OE/I11", "IO12", "IO13", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "VCC"))
    val gal20v8 = ChipPinout(title = "GAL20V8", pins = listOf("CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                            "/OE/I13", "I14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "I23", "VCC"))
    val gal22v10 = ChipPinout(title = "GAL22V10", pins = listOf("CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                              "I13", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "IO23", "VCC"))
    val gal20ra10 = ChipPinout(title = "GAL20RA10", pins = listOf("/PL", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                                "/OE", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "IO23", "VCC"))
    val mega328 = ChipPinout(title = "ATmega8 / 48 / 88 / 168 / 328 (DIP28)", pins = listOf(
        "PC6/RESET", "PD0/RXD", "PD1/TXD", "PD2/INT0", "PD3/INT1", "PD4", "VCC", "GND", "PB6/XTAL1", "PB7/XTAL2",
        "PD5", "PD6", "PD7", "PB0", "PB1", "PB2/SS", "PB3/MOSI", "PB4/MISO", "PB5/SCK", "AVCC",
        "AREF", "GND", "PC0/ADC0", "PC1/ADC1", "PC2/ADC2", "PC3/ADC3", "PC4/SDA", "PC5/SCL"))
    val tiny85 = ChipPinout(title = "ATtiny13 / 25 / 45 / 85 (DIP8)", pins = listOf("PB5/RESET", "PB3", "PB4", "GND", "PB0/MOSI", "PB1/MISO", "PB2/SCK", "VCC"))
    val tiny2313 = ChipPinout(title = "ATtiny2313 / AT90S2313 (DIP20)", pins = listOf(
        "PA2/RESET", "PD0/RXD", "PD1/TXD", "PA1/XTAL2", "PA0/XTAL1", "PD2/INT0", "PD3/INT1", "PD4/T0", "PD5/T1", "GND",
        "PD6/ICP", "PB0/AIN0", "PB1/AIN1", "PB2", "PB3/OC1A", "PB4/OC1B", "PB5/MOSI", "PB6/MISO", "PB7/SCK", "VCC"))
    val at89c2051 = ChipPinout(title = "AT89C1051 / 2051 / 4051 (DIP20)", pins = listOf(
        "RST", "P3.0/RXD", "P3.1/TXD", "XTAL2", "XTAL1", "P3.2/INT0", "P3.3/INT1", "P3.4/T0", "P3.5/T1", "GND",
        "P3.7", "P1.0/AIN0", "P1.1/AIN1", "P1.2", "P1.3", "P1.4", "P1.5", "P1.6", "P1.7", "VCC"))
    val mcs51 = ChipPinout(title = "8051 family (DIP40)", pins = listOf(
        "P1.0", "P1.1", "P1.2", "P1.3", "P1.4", "P1.5", "P1.6", "P1.7", "RST", "P3.0/RXD",
        "P3.1/TXD", "P3.2/INT0", "P3.3/INT1", "P3.4/T0", "P3.5/T1", "P3.6/WR", "P3.7/RD", "XTAL2", "XTAL1", "GND",
        "P2.0/A8", "P2.1/A9", "P2.2/A10", "P2.3/A11", "P2.4/A12", "P2.5/A13", "P2.6/A14", "P2.7/A15", "/PSEN", "ALE/PROG",
        "/EA/VPP", "P0.7/AD7", "P0.6/AD6", "P0.5/AD5", "P0.4/AD4", "P0.3/AD3", "P0.2/AD2", "P0.1/AD1", "P0.0/AD0", "VCC"))
    val pic16f628 = ChipPinout(title = "PIC16F84 / 627 / 628 / 648 (DIP18)", pins = listOf(
        "RA2", "RA3", "RA4/T0CKI", "RA5/MCLR/VPP", "VSS", "RB0/INT", "RB1/RX", "RB2/TX", "RB3/CCP1",
        "RB4/PGM", "RB5", "RB6/PGC", "RB7/PGD", "VDD", "RA6/OSC2", "RA7/OSC1", "RA0", "RA1"),
                                      notes = listOf("On the PIC16F84 pins 15/16 are OSC2/OSC1 only, and RX/TX/CCP1 don't exist."))
    val pic12f675 = ChipPinout(title = "PIC12F629 / 675 / 683 (DIP8)", pins = listOf("VDD", "GP5/OSC1", "GP4/OSC2", "GP3/MCLR/VPP", "GP2", "GP1/ICSPCLK", "GP0/ICSPDAT", "VSS"))
    val mega16 = ChipPinout(title = "ATmega16 / 32 / 164 / 324 / 644 / 1284 / 8535 (DIP40)", pins = listOf(
        "PB0/T0", "PB1/T1", "PB2/INT2/AIN0", "PB3/OC0/AIN1", "PB4/SS", "PB5/MOSI", "PB6/MISO", "PB7/SCK", "RESET", "VCC",
        "GND", "XTAL2", "XTAL1", "PD0/RXD", "PD1/TXD", "PD2/INT0", "PD3/INT1", "PD4/OC1B", "PD5/OC1A", "PD6/ICP1",
        "PD7/OC2", "PC0/SCL", "PC1/SDA", "PC2/TCK", "PC3/TMS", "PC4/TDO", "PC5/TDI", "PC6/TOSC1", "PC7/TOSC2", "AVCC",
        "GND", "AREF", "PA7/ADC7", "PA6/ADC6", "PA5/ADC5", "PA4/ADC4", "PA3/ADC3", "PA2/ADC2", "PA1/ADC1", "PA0/ADC0"),
        notes = listOf("Alternate functions shown for the ATmega16/32; the others differ slightly (check the data sheet for timer pins)."))
    val tiny84 = ChipPinout(title = "ATtiny24 / 44 / 84 (DIP14)", pins = listOf(
        "VCC", "PB0/XTAL1", "PB1/XTAL2", "PB3/RESET", "PB2", "PA7", "PA6/MOSI", "PA5/MISO", "PA4/SCK", "PA3", "PA2", "PA1", "PA0", "GND"))
    val tiny861 = ChipPinout(title = "ATtiny26 / 261 / 461 / 861 (DIP20)", pins = listOf(
        "PB0/MOSI", "PB1/MISO", "PB2/SCK", "PB3", "VCC", "GND", "PB4/XTAL1", "PB5/XTAL2", "PB6", "PB7/RESET",
        "PA7", "PA6", "PA5", "PA4", "AVCC", "AGND", "PA3/AREF", "PA2", "PA1", "PA0"))

    val logicNames: Map<String, Pair<String, String>> = mapOf(
        "7400" to ("quad 2-input NAND" to "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7402" to ("quad 2-input NOR" to "o:1Y i:1A i:1B o:2Y i:2A i:2B g:GND i:3A i:3B o:3Y i:4A i:4B o:4Y v:VCC"),
        "7404" to ("hex inverter" to "i:1A o:1Y i:2A o:2Y i:3A o:3Y g:GND o:4Y i:4A o:5Y i:5A o:6Y i:6A v:VCC"),
        "7408" to ("quad 2-input AND" to "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7410" to ("triple 3-input NAND" to "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7411" to ("triple 3-input AND" to "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7420" to ("dual 4-input NAND" to "i:1A i:1B n:NC i:1C i:1D o:1Y g:GND o:2Y i:2A i:2B n:NC i:2C i:2D v:VCC"),
        "7421" to ("dual 4-input AND" to "i:1A i:1B n:NC i:1C i:1D o:1Y g:GND o:2Y i:2A i:2B n:NC i:2C i:2D v:VCC"),
        "7427" to ("triple 3-input NOR" to "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7430" to ("8-input NAND" to "i:A i:B i:C i:D i:E i:F g:GND o:Y n:NC n:NC i:G i:H n:NC v:VCC"),
        "7432" to ("quad 2-input OR" to "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7474" to ("dual D flip-flop" to "i:1/CLR i:1D i:1CLK i:1/PRE o:1Q o:1/Q g:GND o:2/Q o:2Q i:2/PRE i:2CLK i:2D i:2/CLR v:VCC"),
        "7486" to ("quad 2-input XOR" to "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "74125" to ("quad 3-state buffer" to "i:1/OE i:1A o:1Y i:2/OE i:2A o:2Y g:GND o:3Y i:3A i:3/OE o:4Y i:4A i:4/OE v:VCC"),
        "74126" to ("quad 3-state buffer" to "i:1OE i:1A o:1Y i:2OE i:2A o:2Y g:GND o:3Y i:3A i:3OE o:4Y i:4A i:4OE v:VCC"),
        "74138" to ("3-to-8 decoder" to "i:A i:B i:C i:/G2A i:/G2B i:G1 o:/Y7 g:GND o:/Y6 o:/Y5 o:/Y4 o:/Y3 o:/Y2 o:/Y1 o:/Y0 v:VCC"),
        "74139" to ("dual 2-to-4 decoder" to "i:1/G i:1A i:1B o:1/Y0 o:1/Y1 o:1/Y2 o:1/Y3 g:GND o:2/Y3 o:2/Y2 o:2/Y1 o:2/Y0 i:2B i:2A i:2/G v:VCC"),
        "74151" to ("8-to-1 multiplexer" to "i:D3 i:D2 i:D1 i:D0 o:Y o:/W i:/G g:GND i:C i:B i:A i:D7 i:D6 i:D5 i:D4 v:VCC"),
        "74153" to ("dual 4-to-1 multiplexer" to "i:1/G i:B i:1C3 i:1C2 i:1C1 i:1C0 o:1Y g:GND o:2Y i:2C0 i:2C1 i:2C2 i:2C3 i:A i:2/G v:VCC"),
        "74157" to ("quad 2-to-1 multiplexer" to "i:S i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3B i:3A o:4Y i:4B i:4A i:/G v:VCC"),
        "74161" to ("4-bit counter" to "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74160" to ("decade counter" to "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74162" to ("decade counter" to "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74163" to ("4-bit counter" to "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74164" to ("8-bit shift register" to "i:A i:B o:QA o:QB o:QC o:QD g:GND i:CLK i:/CLR o:QE o:QF o:QG o:QH v:VCC"),
        "74165" to ("8-bit shift register" to "i:SH/LD i:CLK i:E i:F i:G i:H o:/QH g:GND o:QH i:SER i:A i:B i:C i:D i:CLKINH v:VCC"),
        "74174" to ("hex D flip-flop" to "i:/CLR o:1Q i:1D i:2D o:2Q i:3D o:3Q g:GND i:CLK o:4Q i:4D o:5Q i:5D i:6D o:6Q v:VCC"),
        "74175" to ("quad D flip-flop" to "i:/CLR o:1Q o:1/Q i:1D i:2D o:2/Q o:2Q g:GND i:CLK o:3Q o:3/Q i:3D i:4D o:4/Q o:4Q v:VCC"),
        "74193" to ("4-bit up/down counter" to "i:B o:QB o:QA i:DOWN i:UP o:QC o:QD g:GND i:D i:C i:/LOAD o:/CO o:/BO i:CLR i:A v:VCC"),
        "74240" to ("octal inverting buffer" to "i:1/G i:1A1 o:2Y4 i:1A2 o:2Y3 i:1A3 o:2Y2 i:1A4 o:2Y1 g:GND i:2A1 o:1Y4 i:2A2 o:1Y3 i:2A3 o:1Y2 i:2A4 o:1Y1 i:2/G v:VCC"),
        "74244" to ("octal buffer" to "i:1/G i:1A1 o:2Y4 i:1A2 o:2Y3 i:1A3 o:2Y2 i:1A4 o:2Y1 g:GND i:2A1 o:1Y4 i:2A2 o:1Y3 i:2A3 o:1Y2 i:2A4 o:1Y1 i:2/G v:VCC"),
        "74245" to ("octal bus transceiver" to "i:DIR b:A1 b:A2 b:A3 b:A4 b:A5 b:A6 b:A7 b:A8 g:GND b:B8 b:B7 b:B6 b:B5 b:B4 b:B3 b:B2 b:B1 i:/OE v:VCC"),
        "74273" to ("octal D flip-flop" to "i:/CLR o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:CLK o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74373" to ("octal latch" to "i:/OE o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:LE o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74374" to ("octal D flip-flop" to "i:/OE o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:CLK o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74393" to ("dual 4-bit counter" to "i:1A i:1CLR o:1QA o:1QB o:1QC o:1QD g:GND o:2QD o:2QC o:2QB o:2QA i:2CLR i:2A v:VCC"),
        "74541" to ("octal buffer" to "i:/G1 i:A1 i:A2 i:A3 i:A4 i:A5 i:A6 i:A7 i:A8 g:GND o:Y8 o:Y7 o:Y6 o:Y5 o:Y4 o:Y3 o:Y2 o:Y1 i:/G2 v:VCC"),
        "74573" to ("octal latch" to "i:/OE i:D1 i:D2 i:D3 i:D4 i:D5 i:D6 i:D7 i:D8 g:GND i:LE o:Q8 o:Q7 o:Q6 o:Q5 o:Q4 o:Q3 o:Q2 o:Q1 v:VCC"),
        "74574" to ("octal D flip-flop" to "i:/OE i:D1 i:D2 i:D3 i:D4 i:D5 i:D6 i:D7 i:D8 g:GND i:CLK o:Q8 o:Q7 o:Q6 o:Q5 o:Q4 o:Q3 o:Q2 o:Q1 v:VCC"),
        "74595" to ("shift register with latch" to "o:QB o:QC o:QD o:QE o:QF o:QG o:QH g:GND o:QH' i:/SRCLR i:SRCLK i:RCLK i:/OE i:SER o:QA v:VCC"),
        "7447" to ("BCD to 7-segment decoder" to "i:B i:C i:/LT b:/BI/RBO i:/RBI i:D i:A g:GND o:/e o:/d o:/c o:/b o:/a o:/g o:/f v:VCC"),
        "7483" to ("4-bit full adder" to "i:A4 o:S3 i:A3 i:B3 v:VCC o:S2 i:B2 i:A2 o:S1 i:A1 i:B1 g:GND i:C0 o:C4 o:S4 i:B4"),
        "7485" to ("4-bit comparator" to "i:B3 i:A<Bin i:A=Bin i:A>Bin o:A>Bout o:A=Bout o:A<Bout g:GND i:B0 i:A0 i:B1 i:A1 i:A2 i:B2 i:A3 v:VCC"),
        "7490" to ("decade counter" to "i:CKB i:R0(1) i:R0(2) n:NC v:VCC i:R9(1) i:R9(2) o:QC o:QB g:GND o:QD o:QA n:NC i:CKA"),
        "7493" to ("4-bit counter" to "i:CKB i:R0(1) i:R0(2) n:NC v:VCC n:NC n:NC o:QC o:QB g:GND o:QD o:QA n:NC i:CKA"),
        "4001" to ("quad 2-input NOR" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4011" to ("quad 2-input NAND" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4071" to ("quad 2-input OR" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4081" to ("quad 2-input AND" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4070" to ("quad 2-input XOR" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4093" to ("quad Schmitt NAND" to "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4013" to ("dual D flip-flop" to "o:1Q o:1/Q i:1CLK i:1R i:1D i:1S g:VSS i:2S i:2D i:2R i:2CLK o:2/Q o:2Q v:VDD"),
        "4017" to ("decade counter / divider" to "o:Q5 o:Q1 o:Q0 o:Q2 o:Q6 o:Q7 o:Q3 g:VSS o:Q8 o:Q4 o:Q9 o:CO i:/CE i:CLK i:RST v:VDD"),
        "4040" to ("12-bit ripple counter" to "o:Q12 o:Q6 o:Q5 o:Q7 o:Q4 o:Q3 o:Q2 g:VSS o:Q1 i:CLK i:RST o:Q9 o:Q8 o:Q10 o:Q11 v:VDD"),
        "4049" to ("hex inverting buffer" to "v:VDD o:1Y i:1A o:2Y i:2A o:3Y i:3A g:VSS i:4A o:4Y i:5A o:5Y n:NC i:6A o:6Y n:NC"),
        "4050" to ("hex buffer" to "v:VDD o:1Y i:1A o:2Y i:2A o:3Y i:3A g:VSS i:4A o:4Y i:5A o:5Y n:NC i:6A o:6Y n:NC"),
        "4051" to ("8-channel analog mux" to "b:X4 b:X6 b:X b:X7 b:X5 i:/INH g:VEE g:VSS i:C i:B i:A b:X3 b:X0 b:X1 b:X2 v:VDD"),
        "4060" to ("14-bit counter + oscillator" to "o:Q12 o:Q13 o:Q14 o:Q6 o:Q5 o:Q7 o:Q4 g:VSS o:/φO o:φO i:φI i:RST o:Q9 o:Q8 o:Q10 v:VDD"),
        "4066" to ("quad bilateral switch" to "b:1Y b:1Z b:2Z b:2Y i:2C i:3C g:VSS b:3Y b:3Z b:4Z b:4Y i:4C i:1C v:VDD"),
        "4511" to ("BCD to 7-segment latch/decoder" to "i:B i:C i:/LT i:/BL i:LE i:D i:A g:VSS o:e o:d o:c o:b o:a o:g o:f v:VDD"),
    )
}
