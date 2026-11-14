#!/usr/bin/env python3
"""Clock-level model of uart_rx. It validated the design choices before the RTL was written
(SPEC section 9, item 6). It is a model, not the RTL: the RTL is checked by the testbench.

Receiver model: 2-flop synchronizer, falling edge on the synchronized line restarts a
counter, bit k sampled at m0 + k*N + N//2 (+/- S for the 3-sample vote, S = max(1, N//16)).

Usage (from the repository root):
    python ip/uart/model/uart_rx_model.py
Needs Python 3 and numpy. Writes ip/uart/results/model_summary.txt. Takes a few seconds.
"""
import sys
from pathlib import Path
import numpy as np

rng = np.random.default_rng(12345)
LOG = []


def say(text=""):
    print(text)
    LOG.append(text)


def frame_bits(data, D, parity, stops):
    bits = [0] + [(data >> i) & 1 for i in range(D)]
    if parity:
        p = bin(data).count("1") & 1          # 1 if odd number of ones
        bits.append(p if parity == 1 else p ^ 1)   # parity 1 even, 2 odd
    bits += [1] * stops
    return bits


def make_line(datas, D, parity, stops, N, eps, phase, gap_bits, lead_bits=3):
    T = N * (1.0 + eps)
    bits = [1] * lead_bits
    for d in datas:
        bits += frame_bits(d, D, parity, stops)
        bits += [1] * gap_bits
    bits += [1] * 3
    bits = np.array(bits, dtype=np.int8)
    M = int(len(bits) * T) + 8
    t = np.arange(M) + phase
    idx = np.floor(t / T).astype(int)
    idx = np.clip(idx, 0, len(bits) - 1)
    return bits[idx]


def decode(line, D, parity, stops, N, nvote, S=None, tol_sync=2):
    S = max(1, N // 16) if S is None else S
    s = np.concatenate([np.ones(tol_sync, dtype=np.int8), line])[: len(line)]  # 2-flop delay
    fall = np.where((s[:-1] == 1) & (s[1:] == 0))[0] + 1
    nbits = 1 + D + (1 if parity else 0) + stops
    out = []
    pos = 0
    n = len(s)

    def vote(c):
        if nvote == 1:
            return int(s[c]) if c < n else 1
        v = [int(s[c + o]) if c + o < n else 1 for o in (-S, 0, S)]
        return 1 if sum(v) >= 2 else 0

    while True:
        j = np.searchsorted(fall, pos)
        if j >= len(fall):
            break
        m0 = int(fall[j])
        if vote(m0 + N // 2) != 0:                      # false start
            pos = m0 + N // 2 + S + 1
            continue
        b = [vote(m0 + k * N + N // 2) for k in range(1, nbits)]
        data = sum(b[i] << i for i in range(D))
        perr = 0
        if parity:
            ones = bin(data).count("1") + b[D]
            perr = int((ones & 1) != (0 if parity == 1 else 1))
        ferr = int(any(x == 0 for x in b[-stops:]))
        out.append((data, perr, ferr))
        pos = m0 + (nbits - 1) * N + N // 2 + S + 1
    return out


def run_trial(D, parity, stops, N, eps, nvote, gap, frames=10):
    datas = [int(x) for x in rng.integers(0, 1 << D, frames)]
    phase = float(rng.uniform(0, 1))
    line = make_line(datas, D, parity, stops, N, eps, phase + rng.integers(0, N), gap)
    got = decode(line, D, parity, stops, N, nvote)
    exp = [(d, 0, 0) for d in datas]
    return got == exp


def tolerance(D, parity, stops, N, nvote, gap, trials=25, step=0.0025, limit=0.15):
    res = {}
    for sign in (+1, -1):
        last = 0.0
        e = 0.0
        while e <= limit:
            ok = all(run_trial(D, parity, stops, N, sign * e, nvote, gap) for _ in range(trials))
            if not ok:
                break
            last = e
            e += step
        res[sign] = last
    return res


def glitch_trial(D, parity, stops, N, nvote, w, where="frame"):
    d = int(rng.integers(0, 1 << D))
    line = make_line([d], D, parity, stops, N, 0.0, int(rng.integers(0, N)), 0, lead_bits=3).copy()
    nb = 1 + D + (1 if parity else 0) + stops
    start = 3 * N + 0
    p = int(rng.integers(start + 1, start + nb * N - w - 1))   # inside the frame
    line[p:p + w] ^= 1
    got = decode(line, D, parity, stops, N, nvote)
    return got == [(d, 0, 0)]


def main():
    fmts = {"8N1": (8, 0, 1), "8E2": (8, 1, 2), "5N1": (5, 0, 1)}
    say("=== 1. Baud tolerance (max |eps| with 100% correct frames, 25 random phases, back-to-back)")
    say("N, format, vote: eps_fast_tx (+), eps_slow_tx (-)   [eps = tx bit time / rx bit time - 1]")
    for N in (16, 32, 100, 868):
        for name, (D, P, S_) in fmts.items():
            for nv in (1, 3):
                if N == 868 and name != "8N1":
                    continue
                r = tolerance(D, P, S_, N, nv, gap=0, trials=12 if N == 868 else 25,
                              step=0.005 if N == 868 else 0.0025)
                say(f"N={N:4d} {name} vote={nv}: tx slower +{r[1]*100:.2f}%  tx faster -{r[-1]*100:.2f}%")
        sys.stdout.flush()

    say("\n=== 2. Glitch immunity inside a frame (1 glitch of w clocks, 8N1, eps=0): frame error rate")
    for N in (16, 32, 100):
        S = max(1, N // 16)
        for w in sorted({1, S, S + 1, 2 * S, max(1, N // 8), max(1, N // 4)}):
            row = []
            for nv in (1, 3):
                bad = sum(not glitch_trial(8, 0, 1, N, nv, w) for _ in range(600))
                row.append(bad / 600)
            say(f"N={N:4d} S={S:2d} w={w:3d}: single={row[0]*100:5.1f}%  vote3={row[1]*100:5.1f}%")

    say("\n=== 3. False start: low glitch of w clocks in idle, accepted as a start bit?")
    for N in (16, 32, 100):
        S = max(1, N // 16)
        res = {}
        for nv in (1, 3):
            thr = None
            for w in range(1, N):
                line = np.ones(6 * N, dtype=np.int8)
                line[2 * N:2 * N + w] = 0
                out = decode(line, 8, 0, 1, N, nv)
                if out:
                    thr = w
                    break
            res[nv] = thr
        say(f"N={N:4d}: shortest accepted glitch single={res[1]} clk, vote3={res[3]} clk (N/2={N//2}, S={S})")

    say("\n=== 4. 1-clock glitch in idle d clocks before a real frame: frame still correct?")
    for N in (16, 32, 100):
        S = max(1, N // 16)
        bad = []
        for d in range(2, N):
            ok = True
            for ph in range(3):
                dat = 0xA5
                line = make_line([dat], 8, 0, 1, N, 0.0, 0, 0, lead_bits=4)
                st = 4 * N
                line = line.copy()
                gpos = st - d
                line[gpos:gpos + 1] ^= 1
                out = decode(line, 8, 0, 1, N, 3)
                ok &= (out == [(dat, 0, 0)])
            if not ok:
                bad.append(d)
        say(f"N={N:4d} S={S}: failing d (clocks before start edge) = {bad[:1]}..{bad[-1:]} count={len(bad)}")


if __name__ == "__main__":
    main()
    out = Path(__file__).resolve().parent.parent / "results" / "model_summary.txt"
    out.parent.mkdir(exist_ok=True)
    out.write_text("uart_rx model: python ip/uart/model/uart_rx_model.py\n\n" + "\n".join(LOG) + "\n",
                   encoding="utf-8", newline="\n")