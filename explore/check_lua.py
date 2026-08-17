#!/usr/bin/env python3
"""Syntax-check the plugin's Lua against the interpreter Lightroom actually uses.

Lightroom Classic embeds **Lua 5.1**. Checking with anything newer is worse than
not checking at all, because 5.2+ parsers happily accept syntax that makes the
plugin fail to load with an error as unhelpful as:

    An internal error has occurred: error loading toolkit script `json'
    ([string "json.lua"]:134: ')' expected near '|')

The bitwise operators (``|``, ``&``, ``~``, ``<<``, ``>>``), integer division
(``//``) and ``goto`` all parse fine under 5.3 and are syntax errors under 5.1.

This only checks that files *parse*. It cannot catch calls to Lightroom SDK
functions that do not exist, because the SDK is not available outside Lightroom.

Usage:
    python explore/check_lua.py
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from lupa import lua51
except ImportError:
    sys.exit(
        "lupa is not installed. Run:  pip install lupa\n"
        "It bundles a real Lua 5.1, which is what Lightroom runs."
    )

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugin" / "pinned.lrplugin"


def check(path: Path, runtime) -> str | None:
    """Return an error message, or None when the file parses cleanly."""
    source = path.read_text(encoding="utf-8")

    # Normalise inside Lua rather than Python: loadstring returns either one
    # value or two depending on success, which does not map cleanly across the
    # bridge.
    #
    # loadstring compiles without executing, which is what we want: the plugin
    # calls into the Lightroom SDK at load time and none of that exists here.
    compile_chunk = runtime.eval(
        "function(src, name)"
        "  local chunk, err = loadstring(src, name)"
        "  if chunk then return nil end"
        "  return err or 'unknown error'"
        "end"
    )
    return compile_chunk(source, path.name)


def main() -> int:
    if not PLUGIN_DIR.is_dir():
        sys.exit(f"Plugin directory not found: {PLUGIN_DIR}")

    runtime = lua51.LuaRuntime()
    files = sorted(PLUGIN_DIR.glob("*.lua"))

    if not files:
        sys.exit(f"No Lua files found in {PLUGIN_DIR}")

    failures = 0
    for path in files:
        err = check(path, runtime)
        if err:
            failures += 1
            print(f"FAIL  {path.name}\n        {err}")
        else:
            print(f"ok    {path.name}")

    print()
    if failures:
        print(f"{failures} of {len(files)} file(s) will not load in Lightroom.")
        return 1

    print(f"All {len(files)} file(s) parse under Lua 5.1.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
