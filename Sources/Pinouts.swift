import Foundation

/// Pinouts (DIP, top view) for the chips people burn most: JEDEC EPROMs, parallel EEPROMs, flash and
/// SRAM (picked by package size and capacity, which covers every maker's version), GALs, 8-pin serial
/// memories and the common AVR, PIC and 8051 microcontrollers.
struct ChipPinout: Equatable {
    let title: String
    let pins: [String]          // pins[0] is pin 1
    var notes: [String] = []
    /// Per pin, for logic chips: i input, o output, b bidirectional, c clock, g ground, v supply, n unused.
    var roles: [Character] = []
    var package: Package = .dip

    enum Package: Equatable { case dip, plcc32 }
}

enum Pinouts {

    // MARK: Lookup

    /// - Parameters:
    ///   - chip: the minipro name, e.g. "AM27C256@DIP28" or "ATMEGA328P@DIP28"
    ///   - size: the chip's code size in bytes (from the database), if known
    ///   - isSRAM: the database says it's a static RAM
    static func find(chip: String, size: Int?, isSRAM: Bool = false) -> ChipPinout? {
        let upper = chip.uppercased()
        let parts = upper.split(separator: "@", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let pkg = parts.count > 1 ? parts[1] : ""
        let pkgPins = Int(pkg.filter { $0.isNumber })
        let isDIP = pkg.isEmpty || pkg.hasPrefix("DIP") || pkg.hasPrefix("PDIP") || pkg.hasPrefix("CDIP")
        let isSO8 = pkg.hasPrefix("SOP8") || pkg.hasPrefix("SOIC8") || pkg.hasPrefix("SO8")

        func has(_ pattern: String) -> Bool { name.range(of: pattern, options: .regularExpression) != nil }

        // 8-pin serial memories (DIP8 and SO8 number the pins the same way).
        if isDIP || isSO8, pkgPins == nil || pkgPins == 8 {
            if has("^[A-Z]*24(C|LC|AA|FC|CS|WC|M)?[0-9]") { return i2cEEPROM }
            if has("^[A-Z]*93(C|LC|AA|S)?[0-9]") { return microwire }
            if has("^[A-Z]*25(Q|LC|AA|X|P|F|VF|PE|DF|C|FL|LQ|SF|CL|LV|L|U|B)?[0-9]") { return spiMemory }
        }
        // PLCC32 memories: JEDEC numbers the pins like the 32-pin DIP; 28-pin chips leave 1, 12, 17 and 26 free.
        if pkg.hasPrefix("PLCC32"), let size = size, size >= 8192, size <= 1048576 {
            guard let dip = memoryPinout(name: name, pins: size >= 131072 ? 32 : 28, size: size, isSRAM: isSRAM) else { return nil }
            var p = dip.pins
            if p.count == 28 {
                // DIP28 pin k → PLCC32: 1–10 → 2–11, 11–13 → 13–15, 14 → 16, 15–19 → 18–22, 20–22 → 23–25, 23–28 → 27–32
                var q = [String](repeating: "NC", count: 32)
                for k in 1...28 {
                    let t: Int
                    switch k {
                    case 1...10: t = k + 1
                    case 11...14: t = k + 2
                    case 15...22: t = k + 3
                    default: t = k + 4
                    }
                    q[t - 1] = p[k - 1]
                }
                p = q
            }
            return ChipPinout(title: dip.title + " – PLCC32", pins: p,
                              notes: dip.notes + ["PLCC32 seen from above; pin 1 is in the middle of the top edge (the dot / bevelled corner side). Needs a PLCC32-to-DIP32 adapter in the ZIF socket."],
                              package: .plcc32)
        }
        guard isDIP else { return nil }

        if has("16V8") { return gal16v8 }
        if has("20V8") { return gal20v8 }
        if has("22V10") { return gal22v10 }
        if has("20RA10") { return gal20ra10 }

        if has("^ATMEGA(8|48|88|168|328)(A|P|PA|PB|V|L)*$") { return mega328 }
        if has("^(ATMEGA(16|32|164|324|644|1284|8535)|AT90S8535|AT90LS8535)(A|P|PA|PB|V|L)*$") { return mega16 }
        if has("^ATTINY(11|12|13|15|25|45|85)(A|V|L)*$") { return tiny85 }
        if has("^ATTINY(24|44|84)(A|V)*$") { return tiny84 }
        if has("^ATTINY(26|261|461|861)(A|V|L)*$") { return tiny861 }
        if has("^(ATTINY2313|AT90S2313|ATTINY4313)") { return tiny2313 }
        if has("^AT89C(1051|2051|4051)") { return at89c2051 }
        if has("^PIC16(L)?F(84|627|628|648)") { return pic16f628 }
        if has("^PIC12(L)?F(629|675|683)") { return pic12f675 }
        // Standard 28- and 40-pin PIC16/PIC18 layouts (not the 3.3 V J-series or the motor-control parts).
        let usb = has("^PIC18L?F(2455|2550|4455|4550|2458|2553|4458|4553)")
        if has("^PIC16L?F(7[236]|73[7]|76[7]|87[036]A?|88[236])$") || (has("^PIC18L?F2[0-9]+[A-Z0-9]*$") && !has("J|^PIC18L?F2[34]31")) {
            if pkgPins == nil || pkgPins == 28 { return pic28(usb: usb) }
        }
        if has("^PIC16L?F(7[47]|74[7]|77[7]|87[147]A?|88[47])$") || (has("^PIC18L?F4[0-9]+[A-Z0-9]*$") && !has("J|^PIC18L?F4[34]31")) {
            if pkgPins == nil || pkgPins == 40 { return pic40(usb: usb) }
        }
        if (pkgPins == nil || pkgPins == 40),
           has("^(AT89(C|S|LV|LS)5[0-9]|AT89S825[23]|I?87C5[0-9]|I?8751|P87C5|P89C5|P89V5|SST89|W78E|W78C|W77E|SM89|80C51|8751)") { return mcs51 }

        guard let size = size, size > 0 else { return nil }
        let pins = pkgPins ?? (size <= 4096 ? 24 : size <= 0x10000 ? 28 : 32)
        return memoryPinout(name: name, pins: pins, size: size, isSRAM: isSRAM)
    }

    /// DIP pinout of a parallel memory chip from its family, pin count and size.
    static func memoryPinout(name: String, pins: Int, size: Int, isSRAM: Bool) -> ChipPinout? {
        func has(_ pattern: String) -> Bool { name.range(of: pattern, options: .regularExpression) != nil }
        // Intel-style 28F flash and SST 28SF have different control pins, so they're left out.
        let eeprom = has("28(C|HC|LV)[0-9]") && !has("27")
        let flash = has("(29(F|C|EE|LV|SF)|39(SF|VF|LF)|49F)[0-9]")
        let eprom = has("27(C|SF|E|HC|LV|W|V)?[0-9]")
        let sram = (isSRAM && !has("^PIC")) || has("(^|[A-Z])(6116|6264|62256|61256|628128|628512|61512|W24|W2465|DS12)")

        if sram { return sramPinout(pins: pins, size: size) }
        if flash { return flashPinout(pins: pins, size: size) }
        if eeprom { return eepromPinout(pins: pins, size: size) }
        if eprom { return epromPinout(pins: pins, size: size) }
        return nil
    }

    // MARK: JEDEC memories

    private static let jedecNote = "Standard JEDEC pinout – compare with your chip's data sheet."

    /// Common 28-pin layout (27256 / 28C256 / 62256 core).
    private static func base28() -> [String] {
        ["VPP", "A12", "A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
         "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "A11", "A9", "A8", "A13", "A14", "VCC"]
    }

    /// Common 32-pin layout (27C010 / 29F010 / 628128 core).
    private static func base32() -> [String] {
        ["VPP", "A16", "A15", "A12", "A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
         "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "A11", "A9", "A8", "A13", "A14", "NC", "/PGM", "VCC"]
    }

    /// Common 24-pin layout (2716 / 6116 core).
    private static func base24() -> [String] {
        ["A7", "A6", "A5", "A4", "A3", "A2", "A1", "A0", "D0", "D1", "D2", "GND",
         "D3", "D4", "D5", "D6", "D7", "/CE", "A10", "/OE", "VPP", "A9", "A8", "VCC"]
    }

    private static func set(_ p: inout [String], _ changes: [Int: String]) {
        for (pin, label) in changes { p[pin - 1] = label }
    }

    static func epromPinout(pins: Int, size: Int) -> ChipPinout? {
        switch (pins, size) {
        case (24, 2048):
            return ChipPinout(title: "2716 EPROM (2K × 8)", pins: base24(), notes: [jedecNote])
        case (24, 4096):
            var p = base24(); set(&p, [20: "/OE/VPP", 21: "A11"])
            return ChipPinout(title: "2732 EPROM (4K × 8)", pins: p, notes: [jedecNote])
        case (28, 8192):
            var p = base28(); set(&p, [26: "NC", 27: "/PGM"])
            return ChipPinout(title: "2764 EPROM (8K × 8)", pins: p, notes: [jedecNote])
        case (28, 16384):
            var p = base28(); set(&p, [27: "/PGM"])
            return ChipPinout(title: "27128 EPROM (16K × 8)", pins: p, notes: [jedecNote])
        case (28, 32768):
            return ChipPinout(title: "27256 EPROM (32K × 8)", pins: base28(), notes: [jedecNote])
        case (28, 65536):
            var p = base28(); set(&p, [1: "A15", 22: "/OE/VPP"])
            return ChipPinout(title: "27512 EPROM (64K × 8)", pins: p, notes: [jedecNote])
        case (32, 131072):
            return ChipPinout(title: "27C010 EPROM (128K × 8)", pins: base32(), notes: [jedecNote])
        case (32, 262144):
            var p = base32(); set(&p, [30: "A17"])
            return ChipPinout(title: "27C020 EPROM (256K × 8)", pins: p, notes: [jedecNote])
        case (32, 524288):
            var p = base32(); set(&p, [30: "A17", 31: "A18"])
            return ChipPinout(title: "27C040 EPROM (512K × 8)", pins: p, notes: [jedecNote])
        case (32, 1048576):
            var p = base32(); set(&p, [1: "A19", 24: "/OE/VPP", 30: "A17", 31: "A18"])
            return ChipPinout(title: "27C080 / 27C801 EPROM (1M × 8)", pins: p, notes: [jedecNote])
        default:
            return nil
        }
    }

    static func eepromPinout(pins: Int, size: Int) -> ChipPinout? {
        switch (pins, size) {
        case (24, 2048):
            var p = base24(); set(&p, [21: "/WE"])
            return ChipPinout(title: "28C16 EEPROM (2K × 8)", pins: p, notes: [jedecNote])
        case (28, 8192):
            var p = base28(); set(&p, [1: "RDY/BSY", 26: "NC", 27: "/WE"])
            return ChipPinout(title: "28C64 EEPROM (8K × 8)", pins: p, notes: [jedecNote, "Pin 1 is NC on some makes."])
        case (28, 32768):
            var p = base28(); set(&p, [1: "A14", 26: "A13", 27: "/WE"])
            return ChipPinout(title: "28C256 EEPROM (32K × 8)", pins: p, notes: [jedecNote])
        case (32, 131072):
            var p = base32(); set(&p, [1: "NC", 30: "NC", 31: "/WE"])
            return ChipPinout(title: "28C010 EEPROM (128K × 8)", pins: p, notes: [jedecNote])
        default:
            return nil
        }
    }

    static func flashPinout(pins: Int, size: Int) -> ChipPinout? {
        switch (pins, size) {
        case (28, 32768):
            var p = base28(); set(&p, [1: "A14", 26: "A13", 27: "/WE"])
            return ChipPinout(title: "29C256 flash (32K × 8)", pins: p, notes: [jedecNote])
        case (32, 131072):
            var p = base32(); set(&p, [1: "NC", 30: "NC", 31: "/WE"])
            return ChipPinout(title: "29F010 / 39SF010 flash (128K × 8)", pins: p, notes: [jedecNote])
        case (32, 262144):
            var p = base32(); set(&p, [1: "NC", 30: "A17", 31: "/WE"])
            return ChipPinout(title: "29F020 / 39SF020 flash (256K × 8)", pins: p, notes: [jedecNote, "On 29F002-type chips pin 1 is /RESET."])
        case (32, 524288):
            var p = base32(); set(&p, [1: "A18", 30: "A17", 31: "/WE"])
            return ChipPinout(title: "29F040 / 39SF040 flash (512K × 8)", pins: p, notes: [jedecNote])
        default:
            return nil
        }
    }

    static func sramPinout(pins: Int, size: Int) -> ChipPinout? {
        switch (pins, size) {
        case (24, 2048):
            var p = base24(); set(&p, [18: "/CS", 21: "/WE"])
            return ChipPinout(title: "6116 SRAM (2K × 8)", pins: p, notes: [jedecNote])
        case (28, 8192):
            var p = base28(); set(&p, [1: "NC", 20: "/CS1", 26: "CS2", 27: "/WE"])
            return ChipPinout(title: "6264 SRAM (8K × 8)", pins: p, notes: [jedecNote])
        case (28, 32768):
            var p = base28(); set(&p, [1: "A14", 20: "/CS", 26: "A13", 27: "/WE"])
            return ChipPinout(title: "62256 SRAM (32K × 8)", pins: p, notes: [jedecNote])
        case (32, 131072):
            var p = base32(); set(&p, [1: "NC", 3: "A14", 22: "/CS1", 29: "/WE", 30: "CS2", 31: "A15"])
            return ChipPinout(title: "628128 SRAM (128K × 8)", pins: p, notes: [jedecNote])
        case (32, 524288):
            var p = base32(); set(&p, [1: "A18", 3: "A14", 22: "/CS", 29: "/WE", 30: "A17", 31: "A15"])
            return ChipPinout(title: "628512 SRAM (512K × 8)", pins: p, notes: [jedecNote])
        default:
            return nil
        }
    }

    // MARK: Serial memories

    static let i2cEEPROM = ChipPinout(title: "24Cxx I²C EEPROM", pins: ["A0", "A1", "A2", "GND", "SDA", "SCL", "WP", "VCC"],
                                      notes: ["A0–A2 are not connected inside some sizes."])
    static let microwire = ChipPinout(title: "93Cxx Microwire EEPROM", pins: ["CS", "SK", "DI", "DO", "GND", "ORG", "NC", "VCC"],
                                      notes: ["ORG selects 8-bit (GND) or 16-bit (VCC) words."])
    static let spiMemory = ChipPinout(title: "25xx SPI flash / EEPROM", pins: ["/CS", "DO", "/WP", "GND", "DI", "CLK", "/HOLD", "VCC"],
                                      notes: ["Most 25-series parts are 3.3 V – check before programming."])

    // MARK: GALs

    static let gal16v8 = ChipPinout(title: "GAL16V8", pins: ["CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "GND",
                                                            "/OE/I11", "IO12", "IO13", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "VCC"])
    static let gal20v8 = ChipPinout(title: "GAL20V8", pins: ["CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                            "/OE/I13", "I14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "I23", "VCC"])
    static let gal22v10 = ChipPinout(title: "GAL22V10", pins: ["CLK/I1", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                              "I13", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "IO23", "VCC"])
    static let gal20ra10 = ChipPinout(title: "GAL20RA10", pins: ["/PL", "I2", "I3", "I4", "I5", "I6", "I7", "I8", "I9", "I10", "I11", "GND",
                                                                "/OE", "IO14", "IO15", "IO16", "IO17", "IO18", "IO19", "IO20", "IO21", "IO22", "IO23", "VCC"])

    // MARK: Microcontrollers

    static let mega328 = ChipPinout(title: "ATmega8 / 48 / 88 / 168 / 328 (DIP28)", pins: [
        "PC6/RESET", "PD0/RXD", "PD1/TXD", "PD2/INT0", "PD3/INT1", "PD4", "VCC", "GND", "PB6/XTAL1", "PB7/XTAL2",
        "PD5", "PD6", "PD7", "PB0", "PB1", "PB2/SS", "PB3/MOSI", "PB4/MISO", "PB5/SCK", "AVCC",
        "AREF", "GND", "PC0/ADC0", "PC1/ADC1", "PC2/ADC2", "PC3/ADC3", "PC4/SDA", "PC5/SCL"])
    static let tiny85 = ChipPinout(title: "ATtiny13 / 25 / 45 / 85 (DIP8)", pins: ["PB5/RESET", "PB3", "PB4", "GND", "PB0/MOSI", "PB1/MISO", "PB2/SCK", "VCC"])
    static let tiny2313 = ChipPinout(title: "ATtiny2313 / AT90S2313 (DIP20)", pins: [
        "PA2/RESET", "PD0/RXD", "PD1/TXD", "PA1/XTAL2", "PA0/XTAL1", "PD2/INT0", "PD3/INT1", "PD4/T0", "PD5/T1", "GND",
        "PD6/ICP", "PB0/AIN0", "PB1/AIN1", "PB2", "PB3/OC1A", "PB4/OC1B", "PB5/MOSI", "PB6/MISO", "PB7/SCK", "VCC"])
    static let at89c2051 = ChipPinout(title: "AT89C1051 / 2051 / 4051 (DIP20)", pins: [
        "RST", "P3.0/RXD", "P3.1/TXD", "XTAL2", "XTAL1", "P3.2/INT0", "P3.3/INT1", "P3.4/T0", "P3.5/T1", "GND",
        "P3.7", "P1.0/AIN0", "P1.1/AIN1", "P1.2", "P1.3", "P1.4", "P1.5", "P1.6", "P1.7", "VCC"])
    static let mcs51 = ChipPinout(title: "8051 family (DIP40)", pins: [
        "P1.0", "P1.1", "P1.2", "P1.3", "P1.4", "P1.5", "P1.6", "P1.7", "RST", "P3.0/RXD",
        "P3.1/TXD", "P3.2/INT0", "P3.3/INT1", "P3.4/T0", "P3.5/T1", "P3.6/WR", "P3.7/RD", "XTAL2", "XTAL1", "GND",
        "P2.0/A8", "P2.1/A9", "P2.2/A10", "P2.3/A11", "P2.4/A12", "P2.5/A13", "P2.6/A14", "P2.7/A15", "/PSEN", "ALE/PROG",
        "/EA/VPP", "P0.7/AD7", "P0.6/AD6", "P0.5/AD5", "P0.4/AD4", "P0.3/AD3", "P0.2/AD2", "P0.1/AD1", "P0.0/AD0", "VCC"])
    static let pic16f628 = ChipPinout(title: "PIC16F84 / 627 / 628 / 648 (DIP18)", pins: [
        "RA2", "RA3", "RA4/T0CKI", "RA5/MCLR/VPP", "VSS", "RB0/INT", "RB1/RX", "RB2/TX", "RB3/CCP1",
        "RB4/PGM", "RB5", "RB6/PGC", "RB7/PGD", "VDD", "RA6/OSC2", "RA7/OSC1", "RA0", "RA1"],
                                      notes: ["On the PIC16F84 pins 15/16 are OSC2/OSC1 only, and RX/TX/CCP1 don't exist."])
    static let pic12f675 = ChipPinout(title: "PIC12F629 / 675 / 683 (DIP8)", pins: ["VDD", "GP5/OSC1", "GP4/OSC2", "GP3/MCLR/VPP", "GP2", "GP1/ICSPCLK", "GP0/ICSPDAT", "VSS"])

    // MARK: Logic chips

    /// Signal names for common logic chips, written from the makers' data sheets ("role:name" per pin,
    /// pin 1 first). The build checks every role against the database's test vectors.
    static let logicNames: [String: (title: String, pins: String)] = [
        "7400": ("quad 2-input NAND", "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7402": ("quad 2-input NOR", "o:1Y i:1A i:1B o:2Y i:2A i:2B g:GND i:3A i:3B o:3Y i:4A i:4B o:4Y v:VCC"),
        "7404": ("hex inverter", "i:1A o:1Y i:2A o:2Y i:3A o:3Y g:GND o:4Y i:4A o:5Y i:5A o:6Y i:6A v:VCC"),
        "7408": ("quad 2-input AND", "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7410": ("triple 3-input NAND", "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7411": ("triple 3-input AND", "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7420": ("dual 4-input NAND", "i:1A i:1B n:NC i:1C i:1D o:1Y g:GND o:2Y i:2A i:2B n:NC i:2C i:2D v:VCC"),
        "7421": ("dual 4-input AND", "i:1A i:1B n:NC i:1C i:1D o:1Y g:GND o:2Y i:2A i:2B n:NC i:2C i:2D v:VCC"),
        "7427": ("triple 3-input NOR", "i:1A i:1B i:2A i:2B i:2C o:2Y g:GND o:3Y i:3A i:3B i:3C o:1Y i:1C v:VCC"),
        "7430": ("8-input NAND", "i:A i:B i:C i:D i:E i:F g:GND o:Y n:NC n:NC i:G i:H n:NC v:VCC"),
        "7432": ("quad 2-input OR", "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "7474": ("dual D flip-flop", "i:1/CLR i:1D i:1CLK i:1/PRE o:1Q o:1/Q g:GND o:2/Q o:2Q i:2/PRE i:2CLK i:2D i:2/CLR v:VCC"),
        "7486": ("quad 2-input XOR", "i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3A i:3B o:4Y i:4A i:4B v:VCC"),
        "74125": ("quad 3-state buffer", "i:1/OE i:1A o:1Y i:2/OE i:2A o:2Y g:GND o:3Y i:3A i:3/OE o:4Y i:4A i:4/OE v:VCC"),
        "74126": ("quad 3-state buffer", "i:1OE i:1A o:1Y i:2OE i:2A o:2Y g:GND o:3Y i:3A i:3OE o:4Y i:4A i:4OE v:VCC"),
        "74138": ("3-to-8 decoder", "i:A i:B i:C i:/G2A i:/G2B i:G1 o:/Y7 g:GND o:/Y6 o:/Y5 o:/Y4 o:/Y3 o:/Y2 o:/Y1 o:/Y0 v:VCC"),
        "74139": ("dual 2-to-4 decoder", "i:1/G i:1A i:1B o:1/Y0 o:1/Y1 o:1/Y2 o:1/Y3 g:GND o:2/Y3 o:2/Y2 o:2/Y1 o:2/Y0 i:2B i:2A i:2/G v:VCC"),
        "74151": ("8-to-1 multiplexer", "i:D3 i:D2 i:D1 i:D0 o:Y o:/W i:/G g:GND i:C i:B i:A i:D7 i:D6 i:D5 i:D4 v:VCC"),
        "74153": ("dual 4-to-1 multiplexer", "i:1/G i:B i:1C3 i:1C2 i:1C1 i:1C0 o:1Y g:GND o:2Y i:2C0 i:2C1 i:2C2 i:2C3 i:A i:2/G v:VCC"),
        "74157": ("quad 2-to-1 multiplexer", "i:S i:1A i:1B o:1Y i:2A i:2B o:2Y g:GND o:3Y i:3B i:3A o:4Y i:4B i:4A i:/G v:VCC"),
        "74161": ("4-bit counter", "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74160": ("decade counter", "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74162": ("decade counter", "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74163": ("4-bit counter", "i:/CLR i:CLK i:A i:B i:C i:D i:ENP g:GND i:/LOAD i:ENT o:QD o:QC o:QB o:QA o:RCO v:VCC"),
        "74164": ("8-bit shift register", "i:A i:B o:QA o:QB o:QC o:QD g:GND i:CLK i:/CLR o:QE o:QF o:QG o:QH v:VCC"),
        "74165": ("8-bit shift register", "i:SH/LD i:CLK i:E i:F i:G i:H o:/QH g:GND o:QH i:SER i:A i:B i:C i:D i:CLKINH v:VCC"),
        "74174": ("hex D flip-flop", "i:/CLR o:1Q i:1D i:2D o:2Q i:3D o:3Q g:GND i:CLK o:4Q i:4D o:5Q i:5D i:6D o:6Q v:VCC"),
        "74175": ("quad D flip-flop", "i:/CLR o:1Q o:1/Q i:1D i:2D o:2/Q o:2Q g:GND i:CLK o:3Q o:3/Q i:3D i:4D o:4/Q o:4Q v:VCC"),
        "74193": ("4-bit up/down counter", "i:B o:QB o:QA i:DOWN i:UP o:QC o:QD g:GND i:D i:C i:/LOAD o:/CO o:/BO i:CLR i:A v:VCC"),
        "74240": ("octal inverting buffer", "i:1/G i:1A1 o:2Y4 i:1A2 o:2Y3 i:1A3 o:2Y2 i:1A4 o:2Y1 g:GND i:2A1 o:1Y4 i:2A2 o:1Y3 i:2A3 o:1Y2 i:2A4 o:1Y1 i:2/G v:VCC"),
        "74244": ("octal buffer", "i:1/G i:1A1 o:2Y4 i:1A2 o:2Y3 i:1A3 o:2Y2 i:1A4 o:2Y1 g:GND i:2A1 o:1Y4 i:2A2 o:1Y3 i:2A3 o:1Y2 i:2A4 o:1Y1 i:2/G v:VCC"),
        "74245": ("octal bus transceiver", "i:DIR b:A1 b:A2 b:A3 b:A4 b:A5 b:A6 b:A7 b:A8 g:GND b:B8 b:B7 b:B6 b:B5 b:B4 b:B3 b:B2 b:B1 i:/OE v:VCC"),
        "74273": ("octal D flip-flop", "i:/CLR o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:CLK o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74373": ("octal latch", "i:/OE o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:LE o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74374": ("octal D flip-flop", "i:/OE o:1Q i:1D i:2D o:2Q o:3Q i:3D i:4D o:4Q g:GND i:CLK o:5Q i:5D i:6D o:6Q o:7Q i:7D i:8D o:8Q v:VCC"),
        "74393": ("dual 4-bit counter", "i:1A i:1CLR o:1QA o:1QB o:1QC o:1QD g:GND o:2QD o:2QC o:2QB o:2QA i:2CLR i:2A v:VCC"),
        "74541": ("octal buffer", "i:/G1 i:A1 i:A2 i:A3 i:A4 i:A5 i:A6 i:A7 i:A8 g:GND o:Y8 o:Y7 o:Y6 o:Y5 o:Y4 o:Y3 o:Y2 o:Y1 i:/G2 v:VCC"),
        "74573": ("octal latch", "i:/OE i:D1 i:D2 i:D3 i:D4 i:D5 i:D6 i:D7 i:D8 g:GND i:LE o:Q8 o:Q7 o:Q6 o:Q5 o:Q4 o:Q3 o:Q2 o:Q1 v:VCC"),
        "74574": ("octal D flip-flop", "i:/OE i:D1 i:D2 i:D3 i:D4 i:D5 i:D6 i:D7 i:D8 g:GND i:CLK o:Q8 o:Q7 o:Q6 o:Q5 o:Q4 o:Q3 o:Q2 o:Q1 v:VCC"),
        "74595": ("shift register with latch", "o:QB o:QC o:QD o:QE o:QF o:QG o:QH g:GND o:QH' i:/SRCLR i:SRCLK i:RCLK i:/OE i:SER o:QA v:VCC"),
        "7447": ("BCD to 7-segment decoder", "i:B i:C i:/LT b:/BI/RBO i:/RBI i:D i:A g:GND o:/e o:/d o:/c o:/b o:/a o:/g o:/f v:VCC"),
        "7483": ("4-bit full adder", "i:A4 o:S3 i:A3 i:B3 v:VCC o:S2 i:B2 i:A2 o:S1 i:A1 i:B1 g:GND i:C0 o:C4 o:S4 i:B4"),
        "7485": ("4-bit comparator", "i:B3 i:A<Bin i:A=Bin i:A>Bin o:A>Bout o:A=Bout o:A<Bout g:GND i:B0 i:A0 i:B1 i:A1 i:A2 i:B2 i:A3 v:VCC"),
        "7490": ("decade counter", "i:CKB i:R0(1) i:R0(2) n:NC v:VCC i:R9(1) i:R9(2) o:QC o:QB g:GND o:QD o:QA n:NC i:CKA"),
        "7493": ("4-bit counter", "i:CKB i:R0(1) i:R0(2) n:NC v:VCC n:NC n:NC o:QC o:QB g:GND o:QD o:QA n:NC i:CKA"),
        "4001": ("quad 2-input NOR", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4011": ("quad 2-input NAND", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4071": ("quad 2-input OR", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4081": ("quad 2-input AND", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4070": ("quad 2-input XOR", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4093": ("quad Schmitt NAND", "i:1A i:1B o:1Y o:2Y i:2A i:2B g:VSS i:3A i:3B o:3Y o:4Y i:4A i:4B v:VDD"),
        "4013": ("dual D flip-flop", "o:1Q o:1/Q i:1CLK i:1R i:1D i:1S g:VSS i:2S i:2D i:2R i:2CLK o:2/Q o:2Q v:VDD"),
        "4017": ("decade counter / divider", "o:Q5 o:Q1 o:Q0 o:Q2 o:Q6 o:Q7 o:Q3 g:VSS o:Q8 o:Q4 o:Q9 o:CO i:/CE i:CLK i:RST v:VDD"),
        "4040": ("12-bit ripple counter", "o:Q12 o:Q6 o:Q5 o:Q7 o:Q4 o:Q3 o:Q2 g:VSS o:Q1 i:CLK i:RST o:Q9 o:Q8 o:Q10 o:Q11 v:VDD"),
        "4049": ("hex inverting buffer", "v:VDD o:1Y i:1A o:2Y i:2A o:3Y i:3A g:VSS i:4A o:4Y i:5A o:5Y n:NC i:6A o:6Y n:NC"),
        "4050": ("hex buffer", "v:VDD o:1Y i:1A o:2Y i:2A o:3Y i:3A g:VSS i:4A o:4Y i:5A o:5Y n:NC i:6A o:6Y n:NC"),
        "4051": ("8-channel analog mux", "b:X4 b:X6 b:X b:X7 b:X5 i:/INH g:VEE g:VSS i:C i:B i:A b:X3 b:X0 b:X1 b:X2 v:VDD"),
        "4060": ("14-bit counter + oscillator", "o:Q12 o:Q13 o:Q14 o:Q6 o:Q5 o:Q7 o:Q4 g:VSS o:/φO o:φO i:φI i:RST o:Q9 o:Q8 o:Q10 v:VDD"),
        "4066": ("quad bilateral switch", "b:1Y b:1Z b:2Z b:2Y i:2C i:3C g:VSS b:3Y b:3Z b:4Z b:4Y i:4C i:1C v:VDD"),
        "4511": ("BCD to 7-segment latch/decoder", "i:B i:C i:/LT i:/BL i:LE i:D i:A g:VSS o:e o:d o:c o:b o:a o:g o:f v:VDD"),
    ]

    /// Known mistakes in minipro's logic test vectors (chip: pins), where the data sheet wins.
    static let logicVectorQuirks: [String: Set<Int>] = ["74174": [7]]

    /// The base part number: "74LS00" / "SN74HCT00N" / "CD4011BE" → "7400" / "4011".
    static func logicBase(_ name: String) -> String {
        let n = name.uppercased().split(separator: "@").first.map(String.init) ?? name.uppercased()
        if let r = n.range(of: "74[A-Z]*([0-9]{2,6})", options: .regularExpression) {
            let s = String(n[r])
            let digits = s.dropFirst(2).drop { $0.isLetter }
            return "74" + digits
        }
        if let r = n.range(of: "4[0-9]{3,4}", options: .regularExpression) { return String(n[r]) }
        return n
    }

    /// Role of each pin from the test vectors: G/V power, 0/1 driven (input), C clock, L/H/Z sensed (output).
    static func logicRoles(_ vectors: [[Character]], pins: Int) -> [Character] {
        (0..<pins).map { p in
            let s = Set(vectors.compactMap { p < $0.count ? $0[p] : nil })
            if s.isEmpty || s == ["X"] { return "n" }
            if s == ["G"] { return "g" }
            if s == ["V"] { return "v" }
            let driven = !s.isDisjoint(with: ["0", "1"]), sensed = !s.isDisjoint(with: ["L", "H", "Z"])
            if s.contains("C") && !sensed { return "c" }
            if driven && sensed { return "b" }
            return sensed ? "o" : "i"
        }
    }

    /// The test vectors of one chip from logicic.xml text.
    static func logicVectors(xml: String, name: String) -> (pins: Int, group: String, vectors: [[Character]])? {
        let target = name.uppercased()
        var from = xml.startIndex
        while let start = xml.range(of: "<ic ", range: from..<xml.endIndex),
              let tagEnd = xml.range(of: ">", range: start.upperBound..<xml.endIndex),
              let end = xml.range(of: "</ic>", range: tagEnd.upperBound..<xml.endIndex) {
            let tag = xml[start.lowerBound..<tagEnd.upperBound]
            func attr(_ a: String) -> String? {
                guard let r = tag.range(of: a + "=\""), let e = tag.range(of: "\"", range: r.upperBound..<tag.endIndex) else { return nil }
                return String(tag[r.upperBound..<e.lowerBound])
            }
            let group = attr("name") ?? ""
            if group.uppercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == target }) {
                let body = xml[tagEnd.upperBound..<end.lowerBound]
                var vectors: [[Character]] = []
                var f = body.startIndex
                while let vs = body.range(of: "<vector", range: f..<body.endIndex),
                      let gt = body.range(of: ">", range: vs.upperBound..<body.endIndex),
                      let ve = body.range(of: "</vector>", range: gt.upperBound..<body.endIndex) {
                    vectors.append(Array(body[gt.upperBound..<ve.lowerBound].filter { !$0.isWhitespace }))
                    f = ve.upperBound
                }
                return (Int(attr("pins") ?? "") ?? vectors.first?.count ?? 0, group, vectors)
            }
            from = end.upperBound
        }
        return nil
    }

    /// Pinout of a logic chip: named pins for the common ones, otherwise the pin roles from the test vectors.
    static func logic(name: String, pins: Int, group: String, vectors: [[Character]]) -> ChipPinout? {
        guard pins >= 4, pins % 2 == 0 else { return nil }
        let roles = logicRoles(vectors, pins: pins)
        let members = [name] + group.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let display = name.split(separator: "@").first.map(String.init) ?? name
        for m in members {
            let base = logicBase(m)
            guard let entry = logicNames[base] ?? logicNames[m] else { continue }
            let items = entry.pins.split(separator: " ")
            guard items.count == pins else { continue }
            let names = items.map { String($0.split(separator: ":", maxSplits: 1).last ?? "") }
            let r = items.map { $0.first ?? "i" }
            let title = base == logicBase(display) ? "\(display) – \(entry.title)" : "\(display) – same pinout as \(base) (\(entry.title))"
            return ChipPinout(title: title, pins: names, notes: ["Pin names from the data sheet; outputs in green."], roles: r)
        }
        let labels = roles.map { r -> String in
            switch r {
            case "g": return "GND"
            case "v": return "VCC"
            case "o": return "out"
            case "c": return "clock"
            case "b": return "in/out"
            case "n": return "–"
            default: return "in"
            }
        }
        return ChipPinout(title: "\(display) – pin functions", pins: labels,
                          notes: ["Worked out from minipro's test vectors (in, out, clock, power); \"–\" = not used by the test. Check the data sheet for the signal names."],
                          roles: roles)
    }

    // MARK: More microcontrollers

    static let mega16 = ChipPinout(title: "ATmega16 / 32 / 164 / 324 / 644 / 1284 / 8535 (DIP40)", pins: [
        "PB0/T0", "PB1/T1", "PB2/INT2/AIN0", "PB3/OC0/AIN1", "PB4/SS", "PB5/MOSI", "PB6/MISO", "PB7/SCK", "RESET", "VCC",
        "GND", "XTAL2", "XTAL1", "PD0/RXD", "PD1/TXD", "PD2/INT0", "PD3/INT1", "PD4/OC1B", "PD5/OC1A", "PD6/ICP1",
        "PD7/OC2", "PC0/SCL", "PC1/SDA", "PC2/TCK", "PC3/TMS", "PC4/TDO", "PC5/TDI", "PC6/TOSC1", "PC7/TOSC2", "AVCC",
        "GND", "AREF", "PA7/ADC7", "PA6/ADC6", "PA5/ADC5", "PA4/ADC4", "PA3/ADC3", "PA2/ADC2", "PA1/ADC1", "PA0/ADC0"],
        notes: ["Alternate functions shown for the ATmega16/32; the others differ slightly (check the data sheet for timer pins)."])
    static let tiny84 = ChipPinout(title: "ATtiny24 / 44 / 84 (DIP14)", pins: [
        "VCC", "PB0/XTAL1", "PB1/XTAL2", "PB3/RESET", "PB2", "PA7", "PA6/MOSI", "PA5/MISO", "PA4/SCK", "PA3", "PA2", "PA1", "PA0", "GND"])
    static let tiny861 = ChipPinout(title: "ATtiny26 / 261 / 461 / 861 (DIP20)", pins: [
        "PB0/MOSI", "PB1/MISO", "PB2/SCK", "PB3", "VCC", "GND", "PB4/XTAL1", "PB5/XTAL2", "PB6", "PB7/RESET",
        "PA7", "PA6", "PA5", "PA4", "AVCC", "AGND", "PA3/AREF", "PA2", "PA1", "PA0"])

    static func pic28(usb: Bool) -> ChipPinout {
        var p = ["MCLR/VPP", "RA0/AN0", "RA1/AN1", "RA2/AN2", "RA3/AN3", "RA4/T0CKI", "RA5/AN4", "VSS", "OSC1/RA7", "OSC2/RA6",
                 "RC0", "RC1", "RC2/CCP1", "RC3/SCK/SCL", "RC4/SDI/SDA", "RC5/SDO", "RC6/TX", "RC7/RX", "VSS", "VDD",
                 "RB0/INT", "RB1", "RB2", "RB3/PGM", "RB4", "RB5", "RB6/PGC", "RB7/PGD"]
        if usb { p[13] = "VUSB"; p[14] = "RC4/D-"; p[15] = "RC5/D+" }
        return ChipPinout(title: "PIC16F / PIC18F, 28 pins", pins: p,
                          notes: ["Standard 28-pin PIC layout; some parts have RE3 on pin 1 or other alternate functions – check the data sheet."])
    }

    static func pic40(usb: Bool) -> ChipPinout {
        var p = ["MCLR/VPP", "RA0/AN0", "RA1/AN1", "RA2/AN2", "RA3/AN3", "RA4/T0CKI", "RA5/AN4", "RE0/RD", "RE1/WR", "RE2/CS",
                 "VDD", "VSS", "OSC1", "OSC2", "RC0", "RC1", "RC2/CCP1", "RC3/SCK/SCL", "RD0", "RD1",
                 "RD2", "RD3", "RC4/SDI/SDA", "RC5/SDO", "RC6/TX", "RC7/RX", "RD4", "RD5", "RD6", "RD7",
                 "VSS", "VDD", "RB0/INT", "RB1", "RB2", "RB3/PGM", "RB4", "RB5", "RB6/PGC", "RB7/PGD"]
        if usb { p[17] = "VUSB"; p[22] = "RC4/D-"; p[23] = "RC5/D+" }
        return ChipPinout(title: "PIC16F / PIC18F, 40 pins", pins: p,
                          notes: ["Standard 40-pin PIC layout; some parts have RE3 on pin 1 or other alternate functions – check the data sheet."])
    }
}
