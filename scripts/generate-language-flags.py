"""Build the original, small flag atlas used by the language menu (32-bit TGA)."""
import math
from pathlib import Path
import struct

W, H = 512, 32
WHITE, RED, BLUE = (255, 255, 255), (206, 34, 48), (28, 65, 145)
GOLD, GREEN, BLACK = (255, 207, 42), (0, 144, 86), (25, 25, 29)
pixels = bytearray(W * H * 4)


def polygon(x, y, points):
    inside = False
    previous = points[-1]
    for current in points:
        ax, ay = previous
        bx, by = current
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
        previous = current
    return inside


def star(x, y, cx, cy, radius):
    return polygon(x, y, [
        (cx + math.sin(i * math.pi / 5) * radius * (1 if i % 2 == 0 else .4),
         cy - math.cos(i * math.pi / 5) * radius * (1 if i % 2 == 0 else .4))
        for i in range(10)
    ])


def color(index, x, y):
    if index == 0:  # United States
        return BLUE if x < .43 and y < .55 else (RED if int(y * 13) % 2 == 0 else WHITE)
    if index == 1:
        return (BLACK, RED, GOLD)[min(2, int(y * 3))]
    if index == 2:
        return RED if y < .25 or y > .75 else GOLD
    if index in (3, 4, 5):
        colors = (GREEN, WHITE, RED) if index != 4 else (BLUE, WHITE, RED)
        base = colors[min(2, int(x * 3))]
        if index == 3 and (x - .5) ** 2 + (y - .55) ** 2 < .015:
            return (125, 97, 37)
        return base
    if index == 6:  # Brazil
        if abs(x - .5) / .44 + abs(y - .5) / .42 < 1:
            return BLUE if (x - .5) ** 2 + (y - .5) ** 2 < .055 else GOLD
        return GREEN
    if index == 7:  # South Korea
        dx, dy = x - .5, (y - .5) * .69
        if dx * dx + dy * dy < .032:
            return RED if dy < .04 * math.sin(dx * 20) else BLUE
        if .15 < abs(dx) < .31 and .17 < abs(dy) < .26:
            return BLACK if int((x + y) * 32) % 3 != 0 else WHITE
        return WHITE
    if index == 8:
        return (WHITE, BLUE, RED)[min(2, int(y * 3))]
    if index == 9:  # China
        if star(x, y, .19, .28, .13) or any(
            star(x, y, cx, cy, .045) for cx, cy in ((.34, .12), (.4, .25), (.4, .4), (.33, .51))
        ):
            return GOLD
        return RED
    if x < .5 and y < .55:  # Taiwan
        dx, dy = x - .25, (y - .275) * .69
        if dx * dx + dy * dy < .005 or star(x, y * .69, .25, .275 * .69, .12):
            return WHITE
        return BLUE
    return RED


for index in range(11):
    for row in range(18):
        for column in range(26):
            # Supersampling keeps diagonals and small emblems smooth at menu size.
            samples = [color(index, (column + (sx + .5) / 4) / 26,
                             (row + (sy + .5) / 4) / 18)
                       for sx in range(4) for sy in range(4)]
            rgb = [round(sum(sample[c] for sample in samples) / 16) for c in range(3)]
            offset = ((row + 7) * W + index * 32 + column + 3) * 4
            pixels[offset:offset + 4] = bytes((*reversed(rgb), 255))

header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, W, H, 32, 0x28)
Path(__file__).resolve().parents[1].joinpath("textures/language-flags.tga").write_bytes(header + pixels)
