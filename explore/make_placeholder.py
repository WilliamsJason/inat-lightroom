"""Draw the tile a review row shows when there is no photo to show.

f:picture takes a file path, and a row's path has to be *something* from the
moment the dialog is built -- the view tree is fixed once presented, so the
widget exists before its thumbnail has been downloaded, and it still exists
when a download fails. Rather than find out what f:picture does with nil, every
row starts pointed at this file and is repointed when an image arrives.

Written by hand rather than with Pillow so that regenerating it needs nothing
but the standard library, and checked in so the plugin has no build step.
"""

import struct
import zlib
from pathlib import Path

SIZE = 128
BACKGROUND = (58, 58, 58)
BORDER = (92, 92, 92)
MARK = (120, 120, 120)


def pixel(x: int, y: int) -> tuple:
    edge = x < 2 or y < 2 or x >= SIZE - 2 or y >= SIZE - 2
    if edge:
        return BORDER
    # A slash, drawn thick enough to read at thumbnail size, to say "nothing
    # here" without any text -- text would need a font and would be wrong in
    # every language but one.
    if abs((x + y) - SIZE) < 4 and 24 < x < SIZE - 24:
        return MARK
    return BACKGROUND


def chunk(kind: bytes, payload: bytes) -> bytes:
    body = kind + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(
        ">I", zlib.crc32(body) & 0xFFFFFFFF)


def main() -> None:
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter: none
        for x in range(SIZE):
            raw.extend(pixel(x, y))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    out = (Path(__file__).resolve().parent.parent
           / "plugin" / "inat.lrplugin" / "no-photo.png")
    out.write_bytes(png)
    print(f"wrote {out} ({len(png)} bytes)")


if __name__ == "__main__":
    main()
