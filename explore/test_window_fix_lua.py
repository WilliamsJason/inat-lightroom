"""The floating panel's z-order fix-up.

Covers WindowFix.lua and the way ObservationPanel starts it.

Lightroom creates SDK floating windows WS_EX_TOPMOST and ownerless, so the panel
would sit above every application on the desktop and would not minimise with
Lightroom. Nothing in the SDK controls that -- `_topmost = false` was passed
through presentFloatingDialog in the host and ignored -- so the plugin shells out
to a PowerShell helper that gives the window an owner and clears topmost.

The shell-out is the fragile part: it is the only place the plugin leaves Lua, it
is Windows-only, and getting the quoting or the platform guard wrong is silent.
Hence these guards.
"""

import pytest

from lua_harness import LuaPlugin, PLUGIN_DIR


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def fix(plugin):
    return plugin.require("WindowFix")


# ---------------------------------------------------------------------------
# The command it builds
# ---------------------------------------------------------------------------


def test_the_helper_script_is_shipped_with_the_plugin(fix):
    name = fix.SCRIPT_NAME
    assert (PLUGIN_DIR / name).is_file(), (
        f"{name} must live in the plugin folder; WindowFix resolves it "
        "relative to _PLUGIN.path, so it ships or it does not run"
    )


def test_the_script_path_is_resolved_against_the_plugin_folder(plugin, fix):
    path = fix.scriptPath("/somewhere/pinned.lrplugin")
    assert path == "/somewhere/pinned.lrplugin/" + fix.SCRIPT_NAME


def test_the_command_quotes_the_script_path(fix):
    command = fix.command("C:/Program Files/pinned.lrplugin/fix.ps1", "iNaturalist")
    assert '-File "C:/Program Files/pinned.lrplugin/fix.ps1"' in command, (
        "an unquoted path breaks on the first space, and plugin folders live "
        "under Program Files and user names with spaces in them"
    )


def test_the_command_quotes_the_title(fix):
    command = fix.command("/p/fix.ps1", "iNaturalist")
    assert '-Title "iNaturalist"' in command


def test_the_command_does_not_start_with_a_quote(fix):
    command = fix.command("/p/fix.ps1", "iNaturalist")
    assert not command.startswith('"'), (
        "cmd.exe strips the outermost pair of quotes when the command begins "
        "with one, which would eat the quotes around the script path"
    )


def test_the_command_bypasses_the_execution_policy(fix):
    command = fix.command("/p/fix.ps1", "iNaturalist")
    assert "-ExecutionPolicy Bypass" in command, (
        "the plugin is installed by pointing the Plug-in Manager at a folder, "
        "so the helper is unsigned and may be marked as downloaded"
    )


def test_the_command_hides_the_console_window(fix):
    command = fix.command("/p/fix.ps1", "iNaturalist")
    assert "-WindowStyle Hidden" in command


def test_the_command_does_not_load_the_users_profile(fix):
    command = fix.command("/p/fix.ps1", "iNaturalist")
    assert "-NoProfile" in command, (
        "a user profile can print, prompt or take seconds to load"
    )


# ---------------------------------------------------------------------------
# When it runs
# ---------------------------------------------------------------------------


def test_it_runs_the_helper_on_windows(plugin, fix):
    plugin.set_platform(windows=True)
    assert plugin.call(fix.apply, "iNaturalist")[0] is True
    assert len(plugin.executed_commands) == 1
    assert fix.SCRIPT_NAME in plugin.executed_commands[0]


def test_it_does_nothing_off_windows(plugin, fix):
    plugin.set_platform(windows=False)
    assert plugin.call(fix.apply, "iNaturalist")[0] is False
    assert plugin.executed_commands == [], (
        "the fix-up is Win32; the macOS behaviour has never been measured"
    )


def test_a_failing_helper_is_reported_not_raised(plugin, fix):
    plugin.set_platform(windows=True)
    plugin.set_execute_exit_code(1)
    assert plugin.call(fix.apply, "iNaturalist")[0] is False
    assert any("helper exited 1" in line for line in plugin.log_lines), (
        "a window-manager nicety failing must leave a trace but must not "
        "interrupt the user"
    )


def test_a_title_containing_a_quote_is_refused(plugin, fix):
    plugin.set_platform(windows=True)
    assert plugin.call(fix.apply, 'iNat"uralist')[0] is False
    assert plugin.executed_commands == [], (
        "a quote in the title would break out of the -Title argument"
    )


# ---------------------------------------------------------------------------
# How the panel uses it
# ---------------------------------------------------------------------------


def test_opening_the_panel_fixes_its_z_order(plugin):
    panel = plugin.require("ObservationPanel")
    plugin.set_platform(windows=True)

    plugin.call(panel.show)
    plugin.run_pending_tasks()

    assert len(plugin.executed_commands) == 1, (
        "opening the panel must fix the window up, or it floats over "
        "everything on the desktop"
    )


def test_the_fix_up_targets_the_window_the_panel_actually_opens(plugin):
    panel = plugin.require("ObservationPanel")
    plugin.set_platform(windows=True)

    plugin.call(panel.show)
    plugin.run_pending_tasks()

    title = plugin.floating_dialogs[0]["title"]
    assert f'-Title "{title}"' in plugin.executed_commands[0], (
        "the helper finds the window by its caption, so the title the panel "
        "opens with and the title it looks for cannot drift apart"
    )


def test_the_fix_up_does_not_delay_the_window(plugin):
    panel = plugin.require("ObservationPanel")
    plugin.set_platform(windows=True)

    plugin.call(panel.show)
    plugin.run_pending_tasks()

    assert plugin.timeline == ["floatingDialog", "execute"], (
        "the fix-up must be handed to its own task, not run inline: "
        "LrTasks.execute blocks, so running it first would hold the window "
        "shut for as long as the helper takes to find it"
    )


# ---------------------------------------------------------------------------
# Closing one window by name
# ---------------------------------------------------------------------------


def test_the_close_helper_is_shipped_with_the_plugin(fix):
    name = fix.CLOSE_SCRIPT_NAME
    assert (PLUGIN_DIR / name).is_file()


def test_closing_runs_the_close_helper_not_the_z_order_one(plugin, fix):
    plugin.set_platform(windows=True)
    assert plugin.call(fix.close, "Pinned - Taxonomy")[0] is True
    assert fix.CLOSE_SCRIPT_NAME in plugin.executed_commands[-1]
    assert fix.SCRIPT_NAME not in plugin.executed_commands[-1]


def test_closing_names_the_window_it_means(plugin, fix):
    """The helper finds the window by its caption. There is one observation
    panel and any number of taxonomy windows, and the SDK's own close is
    plugin-wide -- getting the title wrong closes the wrong thing or, worse,
    nothing while reporting success."""
    plugin.set_platform(windows=True)
    plugin.call(fix.close, "Pinned - Taxonomy: Ischnura")
    assert '-Title "Pinned - Taxonomy: Ischnura"' in plugin.executed_commands[-1]


def test_closing_does_nothing_off_windows(plugin, fix):
    plugin.set_platform(windows=False)
    assert plugin.call(fix.close, "Pinned - Taxonomy")[0] is False
    assert plugin.executed_commands == []


def test_a_window_that_was_not_found_is_reported_not_raised(plugin, fix):
    """The user has probably already closed it with the close box."""
    plugin.set_platform(windows=True)
    plugin.set_execute_exit_code(1)
    assert plugin.call(fix.close, "Pinned - Taxonomy")[0] is False
    assert any("close helper exited 1" in line for line in plugin.log_lines)


def test_a_title_containing_a_quote_is_refused_by_close_too(plugin, fix):
    plugin.set_platform(windows=True)
    assert plugin.call(fix.close, 'Pinned - "Taxonomy"')[0] is False
    assert plugin.executed_commands == []


# ---------------------------------------------------------------------------
# Bringing one window forward by name
# ---------------------------------------------------------------------------


def test_the_raise_helper_is_shipped_with_the_plugin(fix):
    name = fix.RAISE_SCRIPT_NAME
    assert (PLUGIN_DIR / name).is_file()


def test_raising_runs_the_raise_helper(plugin, fix):
    """The SDK can raise a window it recognises, by presenting it again -- but
    that call holds the calling task until the window closes, so a button
    pressed five times would park five of them."""
    plugin.set_platform(windows=True)
    assert plugin.call(fix["raise"], "Pinned - Taxonomy")[0] is True
    assert fix.RAISE_SCRIPT_NAME in plugin.executed_commands[-1]
    assert '-Title "Pinned - Taxonomy"' in plugin.executed_commands[-1]


def test_raising_does_nothing_off_windows(plugin, fix):
    plugin.set_platform(windows=False)
    assert plugin.call(fix["raise"], "Pinned - Taxonomy")[0] is False
    assert plugin.executed_commands == []


def test_a_window_that_cannot_be_raised_is_only_logged(plugin, fix):
    """Nothing the user asked for fails here: they pressed a button that also
    redrew the window. A dialog saying it could not be brought forward would
    be worse than the window staying where it is."""
    plugin.set_platform(windows=True)
    plugin.set_execute_exit_code(1)
    assert plugin.call(fix["raise"], "Pinned - Taxonomy")[0] is False
    assert any("raise helper exited 1" in line for line in plugin.log_lines)


def test_a_title_containing_a_quote_is_refused_by_raise_too(plugin, fix):
    plugin.set_platform(windows=True)
    assert plugin.call(fix["raise"], 'Pinned - "Taxonomy"')[0] is False
    assert plugin.executed_commands == []
