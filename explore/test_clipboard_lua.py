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


@pytest.mark.parametrize("text", ["", None, "\n", "\r\n"])
def test_nothing_copyable_produces_no_command(plugin, clipboard, text):
    plugin.set_platform(windows=True)
    assert command(plugin, clipboard, text) is None


# ---------------------------------------------------------------------------
# More than one line
#
# A taxonomy is eight ranks and is worth having as eight lines. The rule that
# still holds is that a newline never reaches the command line itself: the
# lines become arguments, and the helper on each platform is what joins them.
# ---------------------------------------------------------------------------


def test_windows_passes_several_lines_as_an_array(plugin, clipboard):
    plugin.set_platform(windows=True)
    line = command(plugin, clipboard, "Kingdom\tAnimalia\nPhylum\tArthropoda")
    assert "Set-Clipboard -Value @('Kingdom\tAnimalia','Phylum\tArthropoda')" in line


def test_the_mac_repeats_the_printf_format_per_line(plugin, clipboard):
    plugin.set_platform(windows=False)
    line = command(plugin, clipboard, "one\ntwo")
    assert line == "printf '%s\\n' 'one' 'two' | pbcopy"


@pytest.mark.parametrize("windows", [True, False])
def test_no_newline_survives_into_the_command_line(plugin, clipboard, windows):
    plugin.set_platform(windows=windows)
    line = command(plugin, clipboard, "one\ntwo\nthree")
    assert "\n" not in line
    assert "\r" not in line


@pytest.mark.parametrize("text", ["one\r\ntwo", "one\rtwo", "one\ntwo"])
def test_every_line_ending_is_understood(plugin, clipboard, text):
    plugin.set_platform(windows=True)
    assert "@('one','two')" in command(plugin, clipboard, text)


def test_a_quote_cannot_escape_a_multi_line_command(plugin, clipboard):
    plugin.set_platform(windows=True)
    assert "@('it''s','fine')" in command(plugin, clipboard, "it's\nfine")

    plugin.set_platform(windows=False)
    line = command(plugin, clipboard, "it's\nfine")
    assert line == "printf '%s\\n' 'it'\\''s' 'fine' | pbcopy"


def test_one_trailing_newline_does_not_become_a_blank_line(plugin, clipboard):
    plugin.set_platform(windows=True)
    # Identical to the single-line form: a block built by appending "\n" to
    # every line must not copy with an empty last one.
    assert command(plugin, clipboard, "one\n") == command(plugin, clipboard, "one")


def test_a_blank_line_in_the_middle_is_kept(plugin, clipboard):
    plugin.set_platform(windows=True)
    assert "@('one','','two')" in command(plugin, clipboard, "one\n\ntwo")


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
