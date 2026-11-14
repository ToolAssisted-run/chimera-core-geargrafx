#!/usr/bin/env python3
"""Builds the PC Engine test programs this repository's tests run: small
HuC6280 programs of our own, written for these tests and under this
repository's licence (GPL-3.0). The HuCard program started from the one the
Chimera Mesen core's tests use (chimera-core-mesen, tests/pce-test/), which
is this project's own work too.

Usage: make-pce-test.py <out dir>

Writes:
  pce-test.pce   an 8 KiB HuCard. At power on it maps the I/O page and its
                 RAM, sets the video chip's display timing with the background
                 on, writes a word to video memory through the SECOND video
                 chip's ports ($0010-$0013: on a SuperGrafx the second chip,
                 on a PC Engine the first chip again, so the two machines end
                 with different video memory), and sets the sound chip's
                 channel 0 to a square wave. Each frame it waits for the
                 vertical blank flag, then reads the controller port the way
                 a game reads the TurboTap: the port is reset, and for each
                 of five pads the directions (SEL high) and the buttons (SEL
                 low) are read. RAM $10-$14 hold the five pads, 1 for held:
                 Up Right Down Left on bits 4-7, I II Select Run on bits 0-3.
                 RAM $00 counts frames; RAM $30-$34 keep what the memory map
                 registers 3 to 6 and the Y register held at power on, which
                 the program never sets. The backdrop colour is pad 1's byte,
                 and channel 0 plays at a frequency that byte gives.
  sgx-test.sgx   the same program, for the SuperGrafx.
  pce-pad6.pce   the same, reading the port twice a frame, for the six-button
                 Avenue Pad 6: each reset of the port switches such a pad
                 between its usual half and its other half (no direction held,
                 and III IV V VI on the button bits). The first read goes to
                 RAM $10-$14, the second to $18-$1C.
  cd-card.pce    a 256 KiB stand-in for the System Card, so the CD machine
                 can be tested with no NEC firmware. It is NOT a System Card:
                 it runs no disc's own program. At power on it does what the
                 HuCard does, then asks the CD drive for sector 0 of the disc
                 (a SCSI READ through the CD interface at $1800-$1808) and
                 copies the first 256 bytes into RAM $0200-$02FF; RAM $02
                 counts the sectors read, RAM $03 holds the last status byte.
                 It repeats the read every 8 frames, of sector 16 times
                 (pad 1's byte & 63), so input moves what the drive reads and
                 the reads cross the disc.
  cd-test.cue,   a disc of one data track of 1024 sectors of 2048 bytes; each
  cd-test.iso    sector starts "GGT" and the low byte of its number, and is
                 filled with a pattern made of its number.
  cd-test.chd    the same disc as a CHD, made by MAME's chdman when it is
                 installed (mame-tools); not written without it.

RAM is the work RAM's first page ($2000 in the CPU's view).
"""
import os
import shutil
import subprocess
import sys


class Asm:
    def __init__(self, origin):
        self.origin = origin
        self.out = bytearray()
        self.labels = {}
        self.fix = []

    def pc(self):
        return self.origin + len(self.out)

    def label(self, name):
        self.labels[name] = self.pc()

    def b(self, *data):
        self.out += bytes(data)

    def br(self, op, name):
        self.b(op, 0)
        self.fix.append(("rel", len(self.out) - 1, name))

    def jmp(self, name):
        self.b(0x4C, 0, 0)
        self.fix.append(("abs", len(self.out) - 2, name))

    def jsr(self, name):
        self.b(0x20, 0, 0)
        self.fix.append(("abs", len(self.out) - 2, name))

    def resolve(self):
        for kind, at, name in self.fix:
            if kind == "rel":
                rel = self.labels[name] - (self.origin + at + 1)
                assert -128 <= rel < 128, name
                self.out[at] = rel & 0xFF
            else:
                self.out[at:at + 2] = self.labels[name].to_bytes(2, "little")
        return self.out


def vdc(a, reg, value):
    a.b(0x03, reg)                             # ST0: the register
    a.b(0x13, value & 0xFF, 0x23, value >> 8)  # ST1, ST2: its value


def vdc2(a, reg, value):
    # the second video chip's ports: $0010 register, $0012/$0013 data
    a.b(0xA9, reg, 0x8D, 0x10, 0x00)
    a.b(0xA9, value & 0xFF, 0x8D, 0x12, 0x00)
    a.b(0xA9, value >> 8, 0x8D, 0x13, 0x00)


def setup(a):
    a.label("reset")
    a.b(0x78, 0xD4, 0xD8)                 # SEI; CSH; CLD
    a.b(0xA9, 0xFF, 0x53, 0x01)           # LDA #$FF; TAM #1: I/O at $0000
    a.b(0xA9, 0xF8, 0x53, 0x02)           # LDA #$F8; TAM #2: RAM at $2000
    a.b(0xA2, 0xFF, 0x9A)                 # LDX #$FF; TXS
    a.b(0xA2, 0x00)
    a.label("clear")
    a.b(0x74, 0x00, 0xE8)                 # STZ $00,X; INX
    a.br(0xD0, "clear")
    # what the console was at power on: the memory map registers 3 to 6
    # (which this program never sets) to RAM $30-$33, and Y to $34
    for n, mpr in enumerate((0x08, 0x10, 0x20, 0x40)):
        a.b(0x43, mpr, 0x85, 0x30 + n)    # TMA #mpr; STA $30+n
    a.b(0x84, 0x34)                       # STY $34
    a.b(0xA9, 0x07, 0x8D, 0x02, 0x14)     # $1402 = 7: no IRQ reaches the CPU
    vdc(a, 0x0A, 0x0202)                  # HSR
    vdc(a, 0x0B, 0x041F)                  # HDR
    vdc(a, 0x0C, 0x0F02)                  # VPR
    vdc(a, 0x0D, 0x00EF)                  # VDW
    vdc(a, 0x0E, 0x0003)                  # VCR
    vdc(a, 0x09, 0x0000)                  # MWR: 32x32 tiles
    vdc(a, 0x05, 0x0088)                  # CR: background on, vertical blank flag on
    # a word into video memory at $1000 through the second chip's ports
    vdc2(a, 0x00, 0x1000)                 # MAWR
    vdc2(a, 0x02, 0xA55A)                 # VWR
    a.b(0x9C, 0x00, 0x04)                 # STZ $0400: VCE dot clock
    # the sound chip's channel 0: a square wave at full volume
    a.b(0x9C, 0x00, 0x08)                 # select channel 0
    a.b(0xA9, 0xFF, 0x8D, 0x01, 0x08)     # main volume
    a.b(0x9C, 0x04, 0x08)                 # channel off: the waveform's index back to 0
    a.b(0xA2, 0x00)
    a.label("wave")
    a.b(0x8A, 0x29, 0x10, 0xF0, 0x02, 0xA9, 0x1F)  # TXA; AND #$10; BEQ +2; LDA #$1F
    a.b(0x8D, 0x06, 0x08, 0xE8, 0xE0, 0x20)        # STA $0806; INX; CPX #32
    a.br(0xD0, "wave")
    a.b(0xA9, 0xFF, 0x8D, 0x05, 0x08)     # balance
    a.b(0xA9, 0x9F, 0x8D, 0x04, 0x08)     # on, volume 31


def frame(a, passes):
    a.label("wait")
    a.b(0xAD, 0x00, 0x00, 0x29, 0x20)     # LDA $0000 (VDC status); AND #$20
    a.br(0xF0, "wait")
    for n in range(passes):
        # the multitap's reset: CLR high, then low
        a.b(0xA9, 0x01, 0x8D, 0x00, 0x10, 0xA9, 0x03, 0x8D, 0x00, 0x10, 0xA9, 0x01, 0x8D, 0x00, 0x10)
        a.b(0xA2, 0x00)
        a.label("pads%d" % n)
        a.b(0xA9, 0x01, 0x8D, 0x00, 0x10, 0xEA, 0xEA)   # SEL high
        a.b(0xAD, 0x00, 0x10, 0x29, 0x0F, 0x0A, 0x0A, 0x0A, 0x0A, 0x85, 0x20)  # the directions, << 4, to $20
        a.b(0x9C, 0x00, 0x10, 0xEA, 0xEA)               # SEL low
        a.b(0xAD, 0x00, 0x10, 0x29, 0x0F, 0x05, 0x20, 0x49, 0xFF, 0x95, 0x10 + 8 * n)  # | buttons, inverted, to $10,X
        a.b(0xE8, 0xE0, 0x05)                           # INX; CPX #5
        a.br(0xD0, "pads%d" % n)
    a.b(0xE6, 0x00)                                 # INC $00
    a.b(0x9C, 0x02, 0x04, 0x9C, 0x03, 0x04)         # VCE colour 0
    a.b(0xA5, 0x10, 0x8D, 0x04, 0x04, 0x9C, 0x05, 0x04)   # = pad 1's byte
    a.b(0xA5, 0x10, 0x8D, 0x02, 0x08, 0xA9, 0x01, 0x8D, 0x03, 0x08)  # channel 0's frequency


def cd_read(a):
    """A subroutine: READ(6) of one sector, the number in RAM $04, through
    the CD interface. The first 256 bytes go to RAM $0200-$02FF ($2200)."""
    a.label("cdread")
    # select the drive: its id on the data bus, then SEL
    a.b(0xA9, 0x81, 0x8D, 0x01, 0x18)     # LDA #$81; STA $1801
    a.b(0x8D, 0x00, 0x18)                 # STA $1800: SEL
    a.label("busy")
    a.b(0xAD, 0x00, 0x18, 0x29, 0x80)     # LDA $1800; AND #$80 (BSY)
    a.br(0xF0, "busy")
    # the command: 08 00 00 <sector> 01 00, a byte each time the drive asks
    a.b(0xA0, 0x00)                       # LDY #0
    a.label("cmd")
    a.jsr("req")
    a.b(0xB9, 0, 0)                       # LDA cmdbytes,Y
    a.fix.append(("abs", len(a.out) - 2, "cmdbytes"))
    a.b(0xC0, 0x02, 0xD0, 0x02, 0xA5, 0x05)  # CPY #2; BNE +2; LDA $05 (the sector's high byte)
    a.b(0xC0, 0x03, 0xD0, 0x02, 0xA5, 0x04)  # CPY #3; BNE +2; LDA $04 (its low byte)
    a.b(0x8D, 0x01, 0x18)                 # STA $1801
    a.jsr("ack")
    a.b(0xC8, 0xC0, 0x06)                 # INY; CPY #6
    a.br(0xD0, "cmd")
    # data: 2048 bytes; the first 256 kept
    a.b(0xA2, 0x00)                       # LDX #0 (the low count)
    a.b(0xA0, 0x08)                       # LDY #8 (256-byte pages)
    a.label("data")
    a.jsr("req")
    a.b(0xAD, 0x00, 0x18, 0x29, 0x18, 0xC9, 0x08)  # LDA $1800; AND #$18 (CD, IO); CMP #$08 (data in)
    a.br(0xD0, "status")
    a.b(0xAD, 0x01, 0x18)                 # LDA $1801
    a.b(0xC0, 0x08, 0xD0, 0x03)           # CPY #8; BNE +3
    a.b(0x9D, 0x00, 0x22)                 # STA $2200,X
    a.jsr("ack")
    a.b(0xE8)                             # INX
    a.br(0xD0, "data")
    a.b(0x88)                             # DEY
    a.br(0xD0, "data")
    # status, then the message
    a.label("status")
    a.jsr("req")
    a.b(0xAD, 0x01, 0x18, 0x85, 0x03)     # LDA $1801; STA $03
    a.jsr("ack")
    a.jsr("req")
    a.b(0xAD, 0x01, 0x18)                 # LDA $1801 (the message)
    a.jsr("ack")
    a.b(0xE6, 0x02)                       # INC $02
    a.b(0x60)                             # RTS
    # wait until the drive asks (REQ)
    a.label("req")
    a.b(0xAD, 0x00, 0x18, 0x29, 0x40)     # LDA $1800; AND #$40
    a.br(0xF0, "req")
    a.b(0x60)
    # acknowledge: ACK up, then down
    a.label("ack")
    a.b(0xA9, 0x80, 0x8D, 0x02, 0x18)     # LDA #$80; STA $1802
    a.label("ackwait")
    a.b(0xAD, 0x00, 0x18, 0x29, 0x40)     # LDA $1800; AND #$40: REQ drops
    a.br(0xD0, "ackwait")
    a.b(0x9C, 0x02, 0x18)                 # STZ $1802
    a.b(0x60)
    a.label("cmdbytes")
    a.b(0x08, 0x00, 0x00, 0x00, 0x01, 0x00)


def program(passes=1, cd=False):
    a = Asm(0xE000)
    setup(a)
    if cd:
        a.jsr("cdread")                   # sector 0 ($04/$05 are cleared)
    a.label("main")
    frame(a, passes)
    if cd:
        # every 8 frames, read sector 16 * (pad 1's byte & 63): sectors 0
        # to 1008 of the 1024, so the disc's caches fill and give pieces back
        a.b(0xA5, 0x00, 0x29, 0x07)       # LDA $00; AND #$07
        a.br(0xD0, "nocd")
        a.b(0xA5, 0x10, 0x29, 0x3F, 0x0A, 0x0A, 0x0A, 0x0A, 0x85, 0x04)  # << 4: the low byte
        a.b(0xA5, 0x10, 0x29, 0x3F, 0x4A, 0x4A, 0x4A, 0x4A, 0x85, 0x05)  # >> 4: the high byte
        a.jsr("cdread")
        a.label("nocd")
    a.jmp("main")
    if cd:
        cd_read(a)
    a.label("rti")
    a.b(0x40)
    return a.resolve(), a.labels


def cart(passes=1, cd=False, size=0x2000):
    code, labels = program(passes, cd)
    assert len(code) < 0x1FF0
    rom = bytearray(size)
    # the program in the card's first 8 KiB, which is what bank 0 maps at
    # power on (MPR7 = 0: $E000-$FFFF)
    rom[0:len(code)] = code
    for vec in (0x1FF6, 0x1FF8, 0x1FFA, 0x1FFC):
        rom[vec:vec + 2] = labels["rti"].to_bytes(2, "little")
    rom[0x1FFE:0x2000] = labels["reset"].to_bytes(2, "little")
    return bytes(rom)


def disc(out):
    sectors = bytearray()
    for n in range(1024):
        sector = bytearray(2048)
        for i in range(2048):
            sector[i] = (n * 37 + i * 7 + (i >> 8)) & 0xFF
        sector[0:4] = b"GGT" + bytes([n & 0xFF])
        sectors += sector
    with open(os.path.join(out, "cd-test.iso"), "wb") as f:
        f.write(sectors)
    with open(os.path.join(out, "cd-test.cue"), "w", newline="\n") as f:
        f.write('FILE "cd-test.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = sys.argv[1]
    data = cart()
    for name in ("pce-test.pce", "sgx-test.sgx"):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
    with open(os.path.join(out, "pce-pad6.pce"), "wb") as f:
        f.write(cart(2))
    with open(os.path.join(out, "cd-card.pce"), "wb") as f:
        f.write(cart(1, cd=True, size=0x40000))
    disc(out)
    # the same disc as a CHD, when MAME's chdman is installed (mame-tools)
    chdman = shutil.which("chdman")
    if chdman:
        subprocess.run([chdman, "createcd", "-f", "-i", os.path.join(out, "cd-test.cue"),
                        "-o", os.path.join(out, "cd-test.chd")], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
