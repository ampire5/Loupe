#!/usr/bin/env python3
"""Generate neutral White/Fine/Soft FP16 grain banks, without external packages."""
from pathlib import Path
import math
import struct

root = Path(__file__).resolve().parents[1] / "Sources/LoupeRender/Resources/GrainTemplates"
root.mkdir(parents=True, exist_ok=True)
side, layers = 128, 4
for style, name in enumerate(("white", "fine", "soft")):
    bank = []
    for layer in range(layers):
        state = 12345 + layer * 9301
        def uniform():
            global state
            state ^= (state << 13) & 0xffffffff
            state ^= state >> 17
            state ^= (state << 5) & 0xffffffff
            return ((state & 0xffffff) + 1) / 16777217
        white = [math.sqrt(-2 * math.log(uniform())) * math.cos(2 * math.pi * uniform()) for _ in range(side * side)]
        field = white[:]
        if style:
            for y in range(side):
                for x in range(side):
                    value = 0
                    for j in range(-1, 2):
                        for i in range(-1, 2):
                            weight = (0.8 if i == j == 0 else 0.025) if style == 1 else ((2 if i == 0 else 1) * (2 if j == 0 else 1)) / 16
                            value += white[((y+j) % side)*side + (x+i) % side] * weight
                    field[y*side+x] = value
        mean = sum(field) / len(field)
        rms = math.sqrt(sum((v-mean)**2 for v in field) / len(field))
        bank.extend(max(-3.5, min(3.5, (v-mean)/rms)) for v in field)
    (root / (name + ".r16f")).write_bytes(struct.pack("<" + "e"*len(bank), *bank))
