#!/usr/bin/env python3
"""Parse and compare Kubernetes resource quantities (stdlib only).

Kubernetes reports memory as quantity strings with binary (Ki, Mi, Gi, ...) or decimal (k, M, G,
...) suffixes, or as a plain/scientific number of bytes. The regression tests need to compare a
kubelet's reserved headroom against Capacity - Allocatable, which are quantities in different
units, so this normalizes both to an integer number of bytes before comparing.

Usage:
  k8s-quantity.py sub A B        # prints int(A - B) in bytes
  k8s-quantity.py ge A B         # exit 0 if A >= B, else 1
  k8s-quantity.py gt|le|lt|eq A B
"""
import sys
from decimal import Decimal

# Suffix -> multiplier. Binary (power-of-two) and decimal (SI) suffixes per the Kubernetes
# quantity grammar; "m" is milli (1/1000), used for CPU but handled for completeness.
_SUFFIXES = {
    "": Decimal(1),
    "m": Decimal(1) / Decimal(1000),
    "k": Decimal(1000),
    "M": Decimal(1000) ** 2,
    "G": Decimal(1000) ** 3,
    "T": Decimal(1000) ** 4,
    "P": Decimal(1000) ** 5,
    "E": Decimal(1000) ** 6,
    "Ki": Decimal(1024),
    "Mi": Decimal(1024) ** 2,
    "Gi": Decimal(1024) ** 3,
    "Ti": Decimal(1024) ** 4,
    "Pi": Decimal(1024) ** 5,
    "Ei": Decimal(1024) ** 6,
}


def parse(value):
    """Return a Decimal number of bytes for a Kubernetes quantity string."""
    text = value.strip()
    if not text:
        raise ValueError("empty quantity")
    # Longest matching suffix first so "Mi" is not read as "M".
    for suffix in sorted(_SUFFIXES, key=len, reverse=True):
        if suffix and text.endswith(suffix):
            return Decimal(text[: -len(suffix)]) * _SUFFIXES[suffix]
    # No suffix: a plain or scientific-notation number of bytes (e.g. "1234", "1.5e9").
    return Decimal(text)


_COMPARATORS = {
    "ge": lambda a, b: a >= b,
    "gt": lambda a, b: a > b,
    "le": lambda a, b: a <= b,
    "lt": lambda a, b: a < b,
    "eq": lambda a, b: a == b,
}


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    op, a_raw, b_raw = argv[1], argv[2], argv[3]
    a, b = parse(a_raw), parse(b_raw)
    if op == "sub":
        # Emit an integer number of bytes so the result re-parses as a plain quantity.
        print(int(a - b))
        return 0
    comparator = _COMPARATORS.get(op)
    if comparator is None:
        sys.stderr.write("unknown operation: %s\n" % op)
        return 2
    return 0 if comparator(a, b) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
