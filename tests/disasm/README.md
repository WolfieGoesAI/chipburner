`vectors.txt` holds the output of MAME's own disassemblers (z80dasm, upd7810_dasm, 6x09dasm,
mcs51dasm, m6502d – BSD-3-Clause) for every opcode, every prefix page and random code at several
base addresses. The build disassembles the same bytes with `Sources/Disassembler.swift` and
requires identical text.

Format: `@ cpu base hexbytes`, then one `ADDR LEN TEXT|` line per instruction (`|` keeps trailing spaces).
