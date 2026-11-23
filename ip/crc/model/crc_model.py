#!/usr/bin/env python3
"""Reference model of the crc IP (Rocksoft model) and check of its design choices.

Two independent implementations of the same CRC:
  - bitwise: shift register, one message bit at a time (the algorithm the RTL unrolls);
  - division: polynomial long division of the message followed by W zero bits, with INIT
    xored into the first W bits (a different algorithm).
Both must give the catalogue check value for the message "123456789". The script then
checks the word-width convention used by the RTL: a message sent as DATA_WIDTH-bit words
gives the same CRC as the same message sent as bytes (see SPEC section 5).

Usage (from the repository root):
    python ip/crc/model/crc_model.py
Needs Python 3 only. Writes ip/crc/results/model_summary.txt.
"""
import random
import sys
from pathlib import Path

# name: (width, poly, init, refin, refout, xorout, check of "123456789")
CATALOGUE = {
    "CRC-3/GSM":          (3,  0x3,                0x0,                False, False, 0x7,                0x4),
    "CRC-5/USB":          (5,  0x05,               0x1F,               True,  True,  0x1F,               0x19),
    "CRC-8/SMBUS":        (8,  0x07,               0x00,               False, False, 0x00,               0xF4),
    "CRC-8/MAXIM-DOW":    (8,  0x31,               0x00,               True,  True,  0x00,               0xA1),
    "CRC-16/IBM-3740":    (16, 0x1021,             0xFFFF,             False, False, 0x0000,             0x29B1),
    "CRC-16/XMODEM":      (16, 0x1021,             0x0000,             False, False, 0x0000,             0x31C3),
    "CRC-16/ARC":         (16, 0x8005,             0x0000,             True,  True,  0x0000,             0xBB3D),
    "CRC-16/MODBUS":      (16, 0x8005,             0xFFFF,             True,  True,  0x0000,             0x4B37),
    "CRC-16/KERMIT":      (16, 0x1021,             0x0000,             True,  True,  0x0000,             0x2189),
    "CRC-24/OPENPGP":     (24, 0x864CFB,           0xB704CE,           False, False, 0x000000,           0x21CF02),
    "CRC-32/ISO-HDLC":    (32, 0x04C11DB7,         0xFFFFFFFF,         True,  True,  0xFFFFFFFF,         0xCBF43926),
    "CRC-32/ISCSI":       (32, 0x1EDC6F41,         0xFFFFFFFF,         True,  True,  0xFFFFFFFF,         0xE3069283),
    "CRC-32/MPEG-2":      (32, 0x04C11DB7,         0xFFFFFFFF,         False, False, 0x00000000,         0x0376E6E7),
    "CRC-32/BZIP2":       (32, 0x04C11DB7,         0xFFFFFFFF,         False, False, 0xFFFFFFFF,         0xFC891918),
    "CRC-64/ECMA-182":    (64, 0x42F0E1EBA9EA3693, 0x0,                False, False, 0x0,                0x6C40DF5F0B497347),
    "CRC-64/XZ":          (64, 0x42F0E1EBA9EA3693, 0xFFFFFFFFFFFFFFFF, True,  True,  0xFFFFFFFFFFFFFFFF, 0x995DC9BBDF1939FA),
}


def reflect(v, w):
    return int(format(v, f"0{w}b")[::-1], 2)


def msg_bits(data, refin):
    """Bits in transmission order: MSB first, or LSB first if refin (per byte)."""
    bits = []
    for byte in data:
        b = [(byte >> i) & 1 for i in range(8)]
        bits += b if refin else b[::-1]
    return bits


def bitwise(params, data):
    w, poly, init, refin, refout, xorout, _ = params
    crc = init
    top = 1 << (w - 1)
    mask = (1 << w) - 1
    for b in msg_bits(data, refin):
        fb = ((crc & top) != 0) ^ b
        crc = (crc << 1) & mask
        if fb:
            crc ^= poly
    if refout:
        crc = reflect(crc, w)
    return crc ^ xorout


def division(params, data):
    w, poly, init, refin, refout, xorout, _ = params
    bits = msg_bits(data, refin) + [0] * w
    for i in range(w):                       # init xored into the first W bits
        bits[i] ^= (init >> (w - 1 - i)) & 1
    full = (1 << w) | poly
    L = len(bits) - w
    for i in range(L):
        if bits[i]:
            for j in range(w + 1):
                bits[i + j] ^= (full >> (w - j)) & 1
    crc = int("".join(map(str, bits[L:])), 2) if w else 0
    if refout:
        crc = reflect(crc, w)
    return crc ^ xorout


def words_to_bytes(words, dw, refin):
    out = []
    for wv in words:
        for j in range(dw // 8):
            out.append((wv >> (8 * j)) & 0xFF if refin else (wv >> (dw - 8 - 8 * j)) & 0xFF)
    return out


def main():
    lines = []

    def say(t=""):
        print(t)
        lines.append(t)

    ok = True
    say("=== 1. Catalogue check values, message '123456789' (two independent algorithms)")
    for name, p in CATALOGUE.items():
        a, b = bitwise(p, b"123456789"), division(p, b"123456789")
        good = a == p[6] and b == p[6]
        ok &= good
        say(f"{name:18s} check={p[6]:0{(p[0]+3)//4}X} bitwise={a:0{(p[0]+3)//4}X} division={b:0{(p[0]+3)//4}X} {'OK' if good else 'MISMATCH'}")

    say("\n=== 2. Word convention: message sent as DATA_WIDTH-bit words = same message as bytes")
    rng = random.Random(1)
    bad = 0
    n = 0
    for name, p in CATALOGUE.items():
        for dw in (16, 32, 64):
            for _ in range(20):
                words = [rng.getrandbits(dw) for _ in range(rng.randint(1, 6))]
                by = words_to_bytes(words, dw, p[3])
                bits = []
                for wv in words:
                    wb = [(wv >> i) & 1 for i in range(dw)]
                    bits += wb if p[3] else wb[::-1]
                if bits != msg_bits(by, p[3]):
                    bad += 1
                n += 1
    ok &= bad == 0
    say(f"{n} word messages, {bad} differ from the byte stream -> {'OK' if bad == 0 else 'MISMATCH'}")

    say("\n=== 3. Empty message")
    for name in ("CRC-16/IBM-3740", "CRC-32/ISO-HDLC", "CRC-16/ARC"):
        p = CATALOGUE[name]
        a, b = bitwise(p, b""), division(p, b"")
        ok &= a == b
        say(f"{name:18s} CRC of the empty message = {a:0{(p[0]+3)//4}X} (both algorithms agree: {a == b})")

    say("\n" + ("ALL OK" if ok else "FAILED"))
    out = Path(__file__).resolve().parent.parent / "results" / "model_summary.txt"
    out.parent.mkdir(exist_ok=True)
    out.write_text("crc model: python ip/crc/model/crc_model.py\n\n" + "\n".join(lines) + "\n",
                   encoding="utf-8", newline="\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())