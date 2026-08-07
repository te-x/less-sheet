#!/usr/bin/env python3
"""Deterministic CSV fixtures at a byte target and a chosen column count.

Why this exists alongside tools/csvgen: csvgen is an adversarial CATALOG — its
cases pin their own shape (`size_scaling` is 3 columns, `wide_100k_cols` is
100,000), which is exactly right for a conformance corpus and useless for a
benchmark that varies width on purpose. This does the one thing csvgen
deliberately does not: same data, N columns wide, M bytes long.

Published numbers have to be reproducible by someone who was not here, so this
lives in the repo rather than in a scratch directory, and it is deterministic:
same (--cols, --size, --seed) gives a byte-identical file on any machine.

Streams in fixed-size chunks, so a 10 GB fixture costs the same memory as a
10 KB one — which is also the property the app under test claims, and it would
be embarrassing to measure that with a generator that does not have it.
"""
import argparse
import random
import sys

CHUNK = 4 << 20

UNITS = {"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30}


def parse_size(text):
    t = text.strip().upper()
    for suffix in ("GB", "MB", "KB", "B"):
        if t.endswith(suffix):
            return int(float(t[: -len(suffix)]) * UNITS[suffix])
    return int(t)


def build_row(rng, cols, index):
    """One record: a couple of typed columns then filler, so a viewer has real
    work to do (type inference, varying widths) rather than one repeated byte."""
    fields = [str(index), "%.4f" % (rng.random() * 1000.0)]
    for c in range(cols - 2):
        if c % 7 == 0:
            fields.append("%d" % rng.randint(0, 999999))
        elif c % 5 == 0:
            fields.append("2026-%02d-%02d" % (rng.randint(1, 12), rng.randint(1, 28)))
        else:
            fields.append("".join(rng.choice("abcdefghijklmnopqrstuvwxyz")
                                  for _ in range(rng.randint(3, 11))))
    return ",".join(fields)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--size", required=True, help="byte target, e.g. 10KB / 10MB / 10GB")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=1337)
    args = ap.parse_args()

    if args.cols < 2:
        sys.exit("--cols must be at least 2")
    target = parse_size(args.size)
    rng = random.Random(args.seed)

    header = ",".join(["id", "value"] + ["col%d" % i for i in range(args.cols - 2)]) + "\n"
    if len(header) >= target:
        sys.exit("--cols %d needs %d bytes for the header alone, which is already "
                 "past the %d-byte target: this fixture cannot have a single data "
                 "row. Pick a bigger --size or fewer --cols."
                 % (args.cols, len(header), target))

    # Build ONE block of distinct rows, then repeat it to reach the target.
    # Generating every row individually is correct and unusably slow in Python
    # at 10 GB (~130 million rows, several rng calls each — hours). The block is
    # megabytes of varied rows; beyond it the content repeats, which is
    # immaterial to everything being measured here: opening reads only the head,
    # and indexing counts record terminators. It would NOT be acceptable for a
    # compression benchmark, where repetition is the whole subject — those
    # numbers come from gzipping these files, so the ratio is reported from the
    # actual artifact rather than assumed.
    block, blocklen, index = [], 0, 0
    while blocklen < CHUNK:
        index += 1
        line = build_row(rng, args.cols, index) + "\n"
        block.append(line)
        blocklen += len(line)
    block_text = "".join(block)

    written = 0
    rows = 0
    with open(args.out, "w", encoding="utf-8", newline="") as fh:
        fh.write(header)
        written += len(header)
        while written + blocklen <= target:
            fh.write(block_text)
            written += blocklen
            rows += len(block)
        # Top up with whole rows only — a fixture must never end mid-record, or
        # the last row is a truncation artifact rather than data.
        for line in block:
            if written + len(line) > target:
                break
            fh.write(line)
            written += len(line)
            rows += 1

    # Counted, not estimated. A fixture that silently came out a different width
    # or length than requested would quietly invalidate an axis of the whole
    # benchmark, so report what was actually produced — and never print a
    # derived guess in a field that reads like a measurement.
    print("%s: %d bytes, %d columns, %d data rows" % (args.out, written, args.cols, rows))


if __name__ == "__main__":
    main()
