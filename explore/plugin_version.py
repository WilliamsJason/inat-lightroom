#!/usr/bin/env python3
"""Read the plugin's version out of Info.lua, and check it against a git tag.

The tag is the source of truth for what a release is called, and Info.lua is the
source of truth for what the plugin believes it is. They have to agree: the
updater compares the tag on GitHub against the version compiled into the
installed plugin, so a mismatch either hides an available update forever or
offers the same update on every check.

Info.lua is read by running it, not by matching a regex against it. It is Lua,
the version lives in a nested table, and a regex over `major = 0` would have to
guess at formatting that Lua does not care about. Running it needs LOC, which is
a Lightroom global rather than a module -- see lua_harness for the same problem.

Usage:
    python explore/plugin_version.py                 # print 0.1.0
    python explore/plugin_version.py --display       # print the display string
    python explore/plugin_version.py --expect v0.1.0 # exit 1 on mismatch
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lupa import lua51

INFO_LUA = (
    Path(__file__).resolve().parent.parent / "plugin" / "pinned.lrplugin" / "Info.lua"
)

# Info.lua calls LOC at load time for the plugin and menu names. The real one
# returns the text after the '=' when no translation is loaded, which is what
# Lightroom itself falls back to.
_LOC = """
function LOC(key, ...)
  local text = tostring(key):match("^%$%$%$/[^=]*=(.*)$") or tostring(key)
  return text
end
"""


class VersionError(RuntimeError):
    """Info.lua does not carry a version this tooling can use."""


def read_version(info_path: Path = INFO_LUA) -> dict:
    """The VERSION table from Info.lua, as a plain dict."""
    runtime = lua51.LuaRuntime()
    runtime.execute(_LOC)

    info = runtime.execute(
        f"return assert(loadstring({_lua_quote(info_path.read_text('utf-8'))}, "
        f"'Info.lua'))()"
    )
    if info is None:
        raise VersionError(f"{info_path} did not return a table")

    version = info["VERSION"]
    if version is None:
        raise VersionError(f"{info_path} has no VERSION table")

    parsed = {}
    for part in ("major", "minor", "revision"):
        value = version[part]
        if value is None:
            raise VersionError(f"{info_path} VERSION has no '{part}'")
        parsed[part] = int(value)

    parsed["display"] = version["display"] or number_string(parsed)
    return parsed


def _lua_quote(source: str) -> str:
    """Wrap Lua source in a long-bracket string that cannot terminate early."""
    level = 0
    while f"]{'=' * level}]" in source:
        level += 1
    equals = "=" * level
    # A long string starting with a newline drops it, so line numbers in any
    # syntax error still point at the right line of Info.lua.
    return f"[{equals}[\n{source}]{equals}]"


def number_string(version: dict) -> str:
    """The dotted number alone: 0.1.0."""
    return f"{version['major']}.{version['minor']}.{version['revision']}"


def tag_for(version: dict) -> str:
    """The git tag this version should be released under."""
    return "v" + number_string(version)


def check_tag(tag: str, version: dict | None = None) -> list[str]:
    """Return the reasons `tag` and Info.lua disagree. Empty means they agree."""
    version = version or read_version()
    number = number_string(version)
    problems = []

    expected = tag_for(version)
    if tag != expected:
        problems.append(
            f"tag is {tag} but Info.lua says {number}, so the tag should be "
            f"{expected}. Bump VERSION in Info.lua, or retag."
        )

    display = str(version["display"])
    if not display.startswith(number):
        problems.append(
            f"VERSION.display is {display!r}, which does not start with "
            f"{number}. The Plug-in Manager shows the display string, so it "
            f"must not disagree with the release it came from."
        )

    # "0.1.0 (pre-release)" was the state before the first tagged release. A
    # release built from it would ship a plugin that calls itself pre-release
    # in the Plug-in Manager forever.
    if "pre-release" in display:
        problems.append(
            f"VERSION.display is {display!r}. A tagged release is not a "
            f"pre-release; drop the suffix."
        )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect", metavar="TAG", help="fail unless the tag matches")
    parser.add_argument(
        "--display", action="store_true", help="print the display string instead"
    )
    args = parser.parse_args()

    try:
        version = read_version()
    except VersionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.expect:
        problems = check_tag(args.expect, version)
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"{args.expect} matches Info.lua")
        return 0

    print(version["display"] if args.display else number_string(version))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
