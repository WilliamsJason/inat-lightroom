"""Staging an update and swapping it in.

Covers UpdateInstall.lua, which is the only code in this plugin that can leave
someone without a working plugin. Everything else fails by not doing something;
this fails by half-doing it.

The filesystem is faked rather than real. That is not to make the tests quick --
it is so that a test can watch the exact order of copies and deletions, make a
copy fail in the middle, and check what was left behind, none of which is
observable from a directory listing after the fact.
"""

import pytest

from lua_harness import LuaPlugin

PLUGIN = "/plugins/inat.lrplugin"
STAGED = PLUGIN + "/.update-staging/inat.lrplugin"

DIGEST = "a" * 64


# ---------------------------------------------------------------------------
# A filesystem that only exists in a table
# ---------------------------------------------------------------------------

FAKE_FS = """
function(initial)
  local fs = {
    files = {}, copies = {}, deletes = {}, writes = {}, ops = {},
    failCopy = nil,
  }

  for path, contents in pairs(initial or {}) do
    fs.files[path] = contents
  end

  local api = {}

  function api.exists(path)
    if fs.files[path] ~= nil then return true end
    -- A directory exists when anything lives under it.
    for existing in pairs(fs.files) do
      if existing:sub(1, #path + 1) == path .. "/" then return true end
    end
    return false
  end

  function api.isDirectory(path)
    return api.exists(path) and fs.files[path] == nil
  end

  function api.makeDirectories(_path) return true end

  function api.copy(from, to)
    fs.copies[#fs.copies + 1] = from .. " -> " .. to
    fs.ops[#fs.ops + 1] = "copy"
    if fs.failCopy and from:find(fs.failCopy, 1, true) then
      return false, "copy refused by the test"
    end
    fs.files[to] = fs.files[from]
    return true
  end

  function api.delete(path)
    fs.deletes[#fs.deletes + 1] = path
    fs.ops[#fs.ops + 1] = "delete"
    for existing in pairs(fs.files) do
      if existing == path or existing:sub(1, #path + 1) == path .. "/" then
        fs.files[existing] = nil
      end
    end
    return true
  end

  function api.readFile(path) return fs.files[path] end

  function api.writeFile(path, contents)
    fs.writes[#fs.writes + 1] = path
    if fs.readOnly then return nil, "read-only" end
    fs.files[path] = contents
    return true
  end

  function api.files(root)
    local found = {}
    for path in pairs(fs.files) do
      if path:sub(1, #root + 1) == root .. "/" then
        found[#found + 1] = path:sub(#root + 2)
      end
    end
    table.sort(found)
    return found
  end

  return api, fs
end
"""


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def install(plugin):
    return plugin.require("UpdateInstall")


@pytest.fixture
def make_fs(plugin):
    factory = plugin.eval(FAKE_FS)
    new_table = plugin.eval("function() return {} end")

    def build(files=None):
        initial = new_table()
        for path, contents in (files or {}).items():
            initial[path] = contents
        return factory(initial)

    return build


def staged_plugin(files):
    """Files as they arrive from the archive, under the staging folder."""
    return {f"{STAGED}/{name}": body for name, body in files.items()}


def installed_plugin(files):
    return {f"{PLUGIN}/{name}": body for name, body in files.items()}


# ---------------------------------------------------------------------------
# Where things live
# ---------------------------------------------------------------------------


def test_staging_lives_inside_the_plugin_folder(install):
    assert install.stagingPath(PLUGIN) == PLUGIN + "/.update-staging", (
        "beside the plugin needs a different write permission from the swap "
        "itself, and temp is cleared between sessions -- which is exactly "
        "when a staged update is waiting"
    )


def test_the_archive_unpacks_to_a_plugin_folder_inside_staging(install):
    assert install.stagedPluginPath(PLUGIN) == STAGED


def test_the_ready_marker_lives_beside_the_unpacked_plugin(install):
    assert install.readyMarkerPath(PLUGIN).endswith("/.update-staging/READY")


# ---------------------------------------------------------------------------
# The helper command
# ---------------------------------------------------------------------------


def test_the_windows_command_passes_every_path_quoted(plugin, install):
    plugin.set_platform(windows=True)
    command = install.command(
        "C:/Program Files/inat.lrplugin/install_update.ps1",
        "C:/Users/A B/Temp/update.zip",
        DIGEST,
        "C:/Program Files/inat.lrplugin/.update-staging",
    )

    assert '-File "C:/Program Files/inat.lrplugin/install_update.ps1"' in command
    assert '-Archive "C:/Users/A B/Temp/update.zip"' in command
    assert f'-ExpectedHash "{DIGEST}"' in command
    assert '-Destination "C:/Program Files/inat.lrplugin/.update-staging"' in command


def test_the_windows_command_does_not_start_with_a_quote(plugin, install):
    plugin.set_platform(windows=True)
    command = install.command("/p/s.ps1", "/t/u.zip", DIGEST, "/p/.update-staging")

    assert not command.startswith('"'), (
        "cmd.exe strips the outermost pair of quotes when the command begins "
        "with one, which would eat the quotes around every path"
    )


def test_the_mac_command_runs_the_shell_script(plugin, install):
    plugin.set_platform(windows=False)
    command = install.command(
        "/p/install_update.sh", "/t/u.zip", DIGEST, "/p/.update-staging"
    )

    assert command.startswith("sh ")
    assert '"/p/install_update.sh"' in command


def test_each_platform_ships_the_script_it_runs(plugin, install):
    from lua_harness import PLUGIN_DIR

    for windows in (True, False):
        plugin.set_platform(windows=windows)
        assert (PLUGIN_DIR / install.scriptName()).is_file(), (
            "the helper is resolved relative to _PLUGIN.path, so it ships or "
            "the update cannot be verified or unpacked at all"
        )


def test_every_helper_exit_code_has_something_to_say(install):
    for code in (1, 2, 3, 4):
        assert install.EXIT_MESSAGES[code], (
            f"exit {code} reaches the user as text; a bare number is not an "
            "explanation"
        )


def test_the_checksum_failure_says_nothing_was_installed(install):
    assert "not installed" in install.EXIT_MESSAGES[2], (
        "a failed checksum is the one failure where the user most needs to "
        "know their working plugin was left alone"
    )


# ---------------------------------------------------------------------------
# The swap plan
# ---------------------------------------------------------------------------


def _from_lua(sequence):
    return [sequence[i] for i in range(1, len(sequence) + 1)]


def test_every_staged_file_is_copied(plugin, install):
    result = install.swapPlan(
        plugin.eval("function() return {'Info.lua'} end")(),
        plugin.eval("function() return {'Info.lua', 'Updater.lua'} end")(),
    )
    assert sorted(_from_lua(result.copy)) == ["Info.lua", "Updater.lua"]


def test_a_file_dropped_from_the_release_is_deleted(plugin, install):
    result = install.swapPlan(
        plugin.eval("function() return {'Info.lua', 'Gone.lua'} end")(),
        plugin.eval("function() return {'Info.lua'} end")(),
    )
    assert _from_lua(result.delete) == ["Gone.lua"], (
        "a module dropped in a release stays behind otherwise, and a stale "
        "Lua file is harmless right up until something requires it again"
    )


def test_the_staging_folder_is_never_deleted_mid_swap(plugin, install):
    result = install.swapPlan(
        plugin.eval(
            "function() return {'Info.lua', "
            "'.update-staging/READY', "
            "'.update-staging/inat.lrplugin/Info.lua'} end"
        )(),
        plugin.eval("function() return {'Info.lua'} end")(),
    )
    assert _from_lua(result.delete) == [], (
        "staging lives inside the plugin folder, so it turns up in the walk; "
        "deleting it mid-swap would delete the source of the copy still "
        "happening"
    )


def test_files_the_user_added_are_left_alone_only_if_the_release_has_them(
    plugin, install
):
    # Anything in the folder that the release does not ship is removed. This is
    # the documented cost of updating in place, and the test exists so that it
    # stays a decision rather than a surprise.
    result = install.swapPlan(
        plugin.eval("function() return {'Info.lua', 'my-notes.txt'} end")(),
        plugin.eval("function() return {'Info.lua'} end")(),
    )
    assert _from_lua(result.delete) == ["my-notes.txt"]


# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------


@pytest.fixture
def staged_ready(make_fs):
    """A plugin folder with a complete, marked staging folder inside it."""
    files = {}
    files.update(installed_plugin({"Info.lua": "old", "Gone.lua": "old"}))
    files.update(staged_plugin({"Info.lua": "new", "Updater.lua": "new"}))
    files[PLUGIN + "/.update-staging/READY"] = "v0.2.0"
    return make_fs(files)


def test_it_applies_a_staged_update(plugin, install, staged_ready):
    fs, state = staged_ready

    tag = install.apply(PLUGIN, fs)

    assert tag == "v0.2.0"
    assert state.files[PLUGIN + "/Info.lua"] == "new"
    assert state.files[PLUGIN + "/Updater.lua"] == "new"


def test_it_removes_files_the_new_release_does_not_have(install, staged_ready):
    fs, state = staged_ready
    install.apply(PLUGIN, fs)

    assert state.files[PLUGIN + "/Gone.lua"] is None


def test_it_clears_the_staging_folder_afterwards(install, staged_ready):
    fs, state = staged_ready
    install.apply(PLUGIN, fs)

    assert state.files[PLUGIN + "/.update-staging/READY"] is None, (
        "a staging folder left behind would be applied again at every "
        "shutdown and every launch, forever"
    )


def test_an_unmarked_staging_folder_is_not_applied(install, make_fs):
    # What an interrupted unpack looks like: files present, marker absent.
    files = {}
    files.update(installed_plugin({"Info.lua": "old"}))
    files.update(staged_plugin({"Info.lua": "half-written"}))
    fs, state = make_fs(files)

    assert install.apply(PLUGIN, fs) is None
    assert state.files[PLUGIN + "/Info.lua"] == "old", (
        "unpacking is not atomic, so a partial staging folder must never be "
        "mistaken for a finished one"
    )


def test_a_marker_with_no_files_is_not_applied(install, make_fs):
    files = installed_plugin({"Info.lua": "old"})
    files[PLUGIN + "/.update-staging/READY"] = "v0.2.0"
    fs, _state = make_fs(files)

    assert install.apply(PLUGIN, fs) is None


def test_nothing_staged_means_nothing_happens(install, make_fs):
    fs, state = make_fs(installed_plugin({"Info.lua": "old"}))

    assert install.apply(PLUGIN, fs) is None
    assert _from_lua(state.copies) == []


def test_a_failed_copy_leaves_the_staging_folder_for_the_next_attempt(
    install, staged_ready
):
    fs, state = staged_ready
    state.failCopy = "Updater.lua"

    assert install.apply(PLUGIN, fs) is None
    assert state.files[PLUGIN + "/.update-staging/READY"] == "v0.2.0", (
        "a half-applied update is the one state worth retrying "
        "automatically, and the next launch will"
    )


def test_a_failed_copy_is_logged_rather_than_raised(plugin, install, staged_ready):
    fs, state = staged_ready
    state.failCopy = "Updater.lua"

    install.apply(PLUGIN, fs)

    assert any("could not apply" in line for line in plugin.log_lines), (
        "this runs during shutdown, where there is no user to show a dialog "
        "to, so the log is the only place it can say anything"
    )


def test_copies_happen_before_deletions(install, staged_ready):
    fs, state = staged_ready
    install.apply(PLUGIN, fs)

    ops = _from_lua(state.ops)
    # The staging folder is removed at the end, so there are deletions after
    # the copies either way; what matters is that none comes before them.
    assert ops.index("delete") > max(
        index for index, op in enumerate(ops) if op == "copy"
    ), (
        "deleting first would spend time with the plugin missing files it "
        "has not yet been given"
    )


# ---------------------------------------------------------------------------
# Pending and discarding
# ---------------------------------------------------------------------------


def test_pending_reports_the_staged_tag(install, staged_ready):
    fs, _state = staged_ready
    assert install.pending(PLUGIN, fs) == "v0.2.0"


def test_pending_is_nil_with_nothing_staged(install, make_fs):
    fs, _state = make_fs(installed_plugin({"Info.lua": "old"}))
    assert install.pending(PLUGIN, fs) is None


def test_discard_removes_everything_staged(install, staged_ready):
    fs, state = staged_ready
    install.discard(PLUGIN, fs)

    assert state.files[PLUGIN + "/.update-staging/READY"] is None
    assert state.files[STAGED + "/Info.lua"] is None
    assert state.files[PLUGIN + "/Info.lua"] == "old", (
        "discarding an update must not touch the installed plugin"
    )


# ---------------------------------------------------------------------------
# Refusing to start
# ---------------------------------------------------------------------------


def test_a_read_only_plugin_folder_is_refused_before_downloading(
    plugin, install, make_fs
):
    fs, state = make_fs(installed_plugin({"Info.lua": "old"}))
    state.readOnly = True

    release = plugin.eval(
        "function() return { assetUrl = 'https://example.invalid/x.zip', "
        "tag = 'v0.2.0' } end"
    )()

    ok, err = plugin.call(install.stage, release, DIGEST, PLUGIN, fs)

    assert ok is None
    assert "read-only" in err or "by hand" in err
    assert plugin.http_calls == [], (
        "discovering an unwritable folder after a download leaves a stray "
        "file in temp and wastes the user's bandwidth"
    )


def test_a_release_with_no_usable_checksum_is_refused(plugin, install, make_fs):
    fs, _state = make_fs(installed_plugin({"Info.lua": "old"}))
    release = plugin.eval(
        "function() return { assetUrl = 'https://example.invalid/x.zip' } end"
    )()

    ok, err = plugin.call(install.stage, release, "not-a-hash", PLUGIN, fs)

    assert ok is None
    assert "checksum" in err
    assert plugin.http_calls == []
