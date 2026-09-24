"""What a complete installation contains, and what happens when it is not.

Covers PluginFiles.lua and the repair path built on it.

The bug behind all of this: a user on 0.3.0 hit "An internal error has
occurred. Could not load toolkit script: ExportPresets". That is what
Lightroom's ``require`` raises when a .lua file is not on disk -- a syntax
error is worded differently and names a line -- so the plugin was running with
a file missing from its own folder, and had nothing to say about it and no way
to put it back.

Two classes of test here, and they guard different halves of that:

    the manifest   PluginFiles.FILES is what a repair checks against, so a
                   manifest that has drifted from what ships would either miss
                   a missing file or call a healthy install damaged. Both are
                   worse than no check, so the list is pinned to the folder in
                   both directions.

    the behaviour  a missing file must produce a sentence naming the repair,
                   and anything that is *not* a missing file must still raise,
                   because dressing a real bug up as "reinstall the plugin"
                   loses the only diagnostic a user could have sent.
"""

from __future__ import annotations

import re

import pytest

from lua_harness import PLUGIN_DIR, PLUGIN_PATH, LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def files(plugin):
    return plugin.require("PluginFiles")


def lua_list(table) -> list:
    return [table[i] for i in range(1, len(table) + 1)]


def shipped_files() -> set[str]:
    return {path.name for path in PLUGIN_DIR.iterdir() if path.is_file()}


# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------


def test_the_manifest_lists_every_file_that_ships(files):
    """A file added to the folder and not to the manifest is a file the
    repair check cannot notice the absence of -- which is exactly the failure
    ExportPresets.lua produced."""
    assert shipped_files() - set(lua_list(files.FILES)) == set()


def test_the_manifest_lists_nothing_that_does_not_ship(files):
    """The more dangerous direction. A stale name here reports every healthy
    installation as damaged, which sends everyone round a download they do not
    need and teaches them to ignore the warning."""
    assert set(lua_list(files.FILES)) - shipped_files() == set()


def test_every_required_module_is_a_file_that_ships():
    """The check that would have caught this before the release.

    Nothing asserted that a ``require "X"`` had an X.lua to find. The Lua
    parses whether or not the module exists -- the failure is at load time, in
    Lightroom, in front of a user.
    """
    modules = {path.stem for path in PLUGIN_DIR.glob("*.lua")}
    pattern = re.compile(r'require\s*\(?\s*"([^"]+)"')

    for path in PLUGIN_DIR.glob("*.lua"):
        for name in pattern.findall(path.read_text(encoding="utf-8")):
            assert name in modules, f"{path.name} requires {name}, which does not exist"


# ---------------------------------------------------------------------------
# Finding what is missing
# ---------------------------------------------------------------------------


def test_a_complete_installation_has_nothing_missing(files):
    assert lua_list(files.missing(PLUGIN_PATH)) == []


def test_a_removed_module_is_found(plugin, files):
    plugin.remove_plugin_file("ExportPresets.lua")

    assert lua_list(files.missing(PLUGIN_PATH)) == ["ExportPresets.lua"]


def test_a_removed_helper_script_is_found_too(plugin, files):
    """install_update.sh going missing raises nothing on any code path: it is
    only ever handed to a shell. The plugin simply stops being able to update
    itself, silently, which is the worst possible file to lose."""
    plugin.remove_plugin_file("install_update.sh")

    assert lua_list(files.missing(PLUGIN_PATH)) == ["install_update.sh"]


# ---------------------------------------------------------------------------
# What it says
# ---------------------------------------------------------------------------


def test_a_complete_installation_is_described_as_nothing_at_all(files):
    """nil, not an empty string. The caller's other reason for asking is a
    real bug in a module that loaded fine, and that one has to be re-raised."""
    assert files.brokenInstallText(PLUGIN_PATH) is None


def test_the_message_names_the_file_and_the_repair(plugin, files):
    plugin.remove_plugin_file("ExportPresets.lua")

    text = files.brokenInstallText(PLUGIN_PATH)

    assert "ExportPresets.lua" in text
    assert "Plug-in Manager" in text
    assert "Repair Installation" in text


def test_one_missing_file_is_not_described_in_the_plural(plugin, files):
    plugin.remove_plugin_file("ExportPresets.lua")

    assert "1 file is missing" in files.brokenInstallText(PLUGIN_PATH)


def test_several_missing_files_are(plugin, files):
    plugin.remove_plugin_file("ExportPresets.lua")
    plugin.remove_plugin_file("RenderPhoto.lua")

    assert "2 files are missing" in files.brokenInstallText(PLUGIN_PATH)


# ---------------------------------------------------------------------------
# A session that applied its own update
# ---------------------------------------------------------------------------


def test_nothing_was_applied_at_startup_by_default(files):
    assert files.appliedAtStartup() is None


def test_the_applied_tag_round_trips(plugin, files):
    files.setAppliedAtStartup("v0.3.2")

    assert files.appliedAtStartup() == "v0.3.2"


def test_clearing_the_flag_clears_it(files):
    files.setAppliedAtStartup("v0.3.2")
    files.setAppliedAtStartup(None)

    assert files.appliedAtStartup() is None


def test_plugin_init_and_plugin_files_agree_on_the_preference_name():
    """Written by one file and read by another, as a bare string on both sides.

    Deliberately not shared through a module: the flag exists for a session
    where a module might not load, so making the two files agree via a third
    would reintroduce the thing it is reporting. That leaves the names able to
    drift, so they are pinned here instead.
    """
    init = (PLUGIN_DIR / "PluginInit.lua").read_text(encoding="utf-8")
    files_lua = (PLUGIN_DIR / "PluginFiles.lua").read_text(encoding="utf-8")

    key = re.search(r'APPLIED_AT_STARTUP_PREF\s*=\s*"([^"]+)"', files_lua).group(1)

    assert f".{key} = nil" in init, "PluginInit must clear the flag each launch"
    assert f".{key} = applied" in init, "PluginInit must set it when it applies"


def test_a_stale_session_is_described_without_being_asked_to_repair(files):
    files.setAppliedAtStartup("v0.3.2")

    text = files.staleSessionText()

    assert "v0.3.2" in text
    assert "Quit Lightroom" in text
    assert "Repair" not in text, (
        "the folder is correct and a repair would download it again to no "
        "effect; the only cure is a restart"
    )


def test_no_stale_message_without_a_startup_apply(files):
    assert files.staleSessionText() is None


def test_a_module_lightroom_will_not_load_is_explained_as_a_restart(
        plugin, files):
    """The actual 0.3.2 failure. Every file is present -- the update copied
    perfectly -- but Lightroom fixed the plugin's script list before the update
    was applied, so the file it added cannot be required this session."""
    files.setAppliedAtStartup("v0.3.2")

    ran = files.protect(plugin.eval(
        'function() return function() error("Could not load toolkit script: '
        'PluginFiles", 0) end end')())

    assert ran is False
    assert len(plugin.dialogs) == 1
    assert "start it again" in plugin.dialogs[0]["message"]


def test_a_missing_file_still_wins_over_a_restart(plugin, files):
    """Both can be true at once: an update applied at startup that also failed
    to copy something. A file that is genuinely absent will not come back on
    its own, so that is the one to act on."""
    plugin.remove_plugin_file("ExportPresets.lua")
    files.setAppliedAtStartup("v0.3.2")

    files.protect(plugin.eval(
        'function() return function() error("boom", 0) end end')())

    assert "ExportPresets.lua" in plugin.dialogs[0]["message"]


def test_a_real_bug_in_a_stale_session_is_not_swallowed(plugin, files):
    """A restart is not the answer to every error just because one happened to
    be applied at startup -- but it is the answer to this class of them, and
    telling them apart from the outside is not possible. Reported, not raised,
    and deliberately: the alternative leaves the one case this exists for
    showing an internal error."""
    files.setAppliedAtStartup("v0.3.2")

    files.protect(plugin.eval(
        'function() return function() error("nil value in PanelCore", 0) end end')())

    assert len(plugin.dialogs) == 1


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def test_a_missing_file_becomes_a_dialog_rather_than_an_internal_error(plugin, files):
    plugin.remove_plugin_file("ExportPresets.lua")

    ran = files.protect(
        plugin.eval('function() return function() error("Could not load '
                    'toolkit script: ExportPresets", 0) end end')()
    )

    assert ran is False
    assert len(plugin.dialogs) == 1
    assert "ExportPresets.lua" in plugin.dialogs[0]["message"]


def test_a_real_bug_is_re_raised_untouched(plugin, files):
    """The installation is intact, so whatever went wrong is a bug in a module
    that loaded. Turning it into "reinstall the plugin" would send the user
    away and throw away the stack Lightroom would otherwise print."""
    raise_it = plugin.eval(
        'function() return function() error("nil value in PanelCore", 0) end end'
    )()

    with pytest.raises(Exception) as caught:
        files.protect(raise_it)

    assert "PanelCore" in str(caught.value)
    assert plugin.dialogs == []


def test_a_successful_action_says_so_and_shows_nothing(plugin, files):
    assert files.protect(plugin.eval("function() return function() end end")()) is True
    assert plugin.dialogs == []
