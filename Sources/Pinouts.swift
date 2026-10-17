import Foundation

/// Pinouts (DIP, top view) for the chips people burn most: JEDEC EPROMs, parallel EEPROMs, flash and
/// SRAM (picked by package size and capacity, which covers every maker's version), GALs, 8-pin serial
/// memories and the common AVR, PIC and 8051 microcontrollers.
struct ChipPinout: Equatable {
    let title: String
    let pins: [String]          // pins[0] is pin 1
    var notes: [String] = []
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
        let name = parts[0]
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
        guard isDIP else { return nil }

        if has("16V8") { return gal16v8 }
        if has("20V8") { return gal20v8 }
        if has("22V10") { return gal22v10 }
        if has("20RA10") { return gal20ra10 }

        if has("^ATMEGA(8|48|88|168|328)(A|P|PA|PB|V|L)*$") { return mega328 }
        if has("^ATTINY(13|25|45|85)(A|V)*$") { return tiny85 }
        if has("^(ATTINY2313|AT90S2313|ATTINY4313)") { return tiny2313 }
        if has("^AT89C(1051|2051|4051)") { return at89c2051 }
        if has("^PIC16(L)?F(84|627|628|648)") { return pic16f628 }
        if has("^PIC12(L)?F(629|675|683)") { return pic12f675 }
        if (pkgPins == nil || pkgPins == 40),
           has("^(AT89(C|S|LV|LS)5[0-9]|AT89S8252|I?87C5[0-9]|P87C5|SST89|W78E5|SM89|80C51|8751)") { return mcs51 }

        guard let size = size, size > 0 else { return nil }
        let pins = pkgPins ?? (size <= 4096 ? 24 : size <= 0x10000 ? 28 : 32)
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
            return ChipPinout(title: "29F020 / 39SF020 flash (256K × 8)", pins: p, notes: [jedecNote])
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
}
