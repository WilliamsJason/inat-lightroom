"""Putting text on the system clipboard.

Covers Clipboard.lua. The SDK has no clipboard API, so this shells out, and the
command line it builds is the whole of the behaviour: a wrong quote here means
either nothing on the clipboard or a shell running something it should not.
"""

import pytest

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def clipboard(plugin):
    return plugin.require("Clipboard")


def command(plugin, clipboard, text):
    return plugin.call(clipboard.command, text)[0]


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------


def test_windows_uses_set_clipboard(plugin, clipboard):
    plugin.set_platform(windows=True)
    line = command(plugin, clipboard, "358074828")
    assert "Set-Clipboard" in line
    assert "'358074828'" in line


def test_windows_hides_the_console_window(plugin, clipboard):
    plugin.set_platform(windows=True)
    line = command(plugin, clipboard, "358074828")
    assert "-WindowStyle Hidden" in line
    assert "-NoProfile" in line


def test_a_quote_cannot_escape_the_windows_command(plugin, clipboard):
    plugin.set_platform(windows=True)
    line = command(plugin, clipboard, "it's")
    assert "'it''s'" in line


def test_the_mac_uses_pbcopy(plugin, clipboard):
    plugin.set_platform(windows=False)
    line = command(plugin, clipboard, "358074828")
    assert line == "printf %s '358074828' | pbcopy"


def test_a_quote_cannot_escape_the_mac_command(plugin, clipboard):
    plugin.set_platform(windows=False)
    assert command(plugin, clipboard, "it's") == "printf %s 'it'\\''s' | pbcopy"


@pytest.mark.parametrize("text", ["", None, "one\ntwo", "one\rtwo"])
def test_nothing_copyable_produces_no_command(plugin, clipboard, text):
    plugin.set_platform(windows=True)
    assert command(plugin, clipboard, text) is None


# ---------------------------------------------------------------------------
# Running it
# ---------------------------------------------------------------------------


def test_copying_runs_the_helper_and_reports_success(plugin, clipboard):
    plugin.set_platform(windows=True)
    assert plugin.in_task(clipboard.copy, "358074828") is True
    assert len(plugin.executed_commands) == 1
    assert "Set-Clipboard" in plugin.executed_commands[0]


def test_a_helper_that_fails_is_reported_not_raised(plugin, clipboard):
    plugin.set_platform(windows=True)
    plugin.set_execute_exit_code(1)
    assert plugin.in_task(clipboard.copy, "358074828") is False


def test_nothing_copyable_runs_nothing(plugin, clipboard):
    plugin.set_platform(windows=True)
    assert plugin.in_task(clipboard.copy, "") is False
    assert plugin.executed_commands == []
