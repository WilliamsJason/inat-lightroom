"""The plugin's Lua must parse under Lua 5.1, which is what Lightroom embeds.

This exists because a bundled json.lua used Lua 5.3 bitwise operators. It parsed
fine under every checker that was tried, and then took the entire plugin down at
load time with an error that pointed at the symptom rather than the cause. The
only reliable check is a real 5.1 parser.
"""

from __future__ import annotations

from pathlib import Path

import pytest

lua51 = pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from check_lua import PLUGIN_DIR, check


def lua_files() -> list[Path]:
    return sorted(PLUGIN_DIR.glob("*.lua"))


@pytest.mark.parametrize("path", lua_files(), ids=lambda p: p.name)
def test_parses_under_lua_51(path: Path) -> None:
    err = check(path, lua51.LuaRuntime())
    assert err is None, f"{path.name} will not load in Lightroom: {err}"


def test_plugin_has_lua_files() -> None:
    # Guard against the parametrised test silently passing with nothing to test.
    assert lua_files(), f"No Lua files found in {PLUGIN_DIR}"


@pytest.mark.parametrize(
    "source",
    [
        pytest.param("return 0xC0 | 1\n", id="bitwise-or"),
        pytest.param("return 8 >> 2\n", id="right-shift"),
        pytest.param("return 7 // 2\n", id="integer-division"),
    ],
)
def test_rejects_lua_53_syntax(source: str, tmp_path: Path) -> None:
    """The checker is worthless if it accepts the syntax that caused the bug."""
    probe = tmp_path / "probe.lua"
    probe.write_text(source, encoding="utf-8")

    assert check(probe, lua51.LuaRuntime()) is not None
