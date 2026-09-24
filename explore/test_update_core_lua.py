"""Deciding when to check, and what to say about the answer.

Covers UpdateCore.lua and the Plug-in Manager section built on it.

The rules being protected here are the two that make an automatic updater
tolerable rather than rude: checking is automatic and installing is not, and a
network failure resolves to "could not check" rather than to a silence that
reads as "nothing new".
"""

import json

import pytest

from lua_harness import PLUGIN_DIR, LuaPlugin

OWNER_REPO = "WilliamsJason/inat-lightroom"
DOWNLOAD = f"https://github.com/{OWNER_REPO}/releases/download"
DIGEST = "a" * 64

DAY = 24 * 60 * 60


def release_json(tag="v9.9.9", *, assets=True):
    payload = {
        "tag_name": tag,
        "body": "notes",
        "html_url": f"https://github.com/{OWNER_REPO}/releases/tag/{tag}",
        "assets": [],
    }
    if assets:
        payload["assets"] = [
            {
                "name": "inat-lightroom-9.9.9.zip",
                "browser_download_url": f"{DOWNLOAD}/{tag}/inat-lightroom-9.9.9.zip",
            },
            {
                "name": "SHA256SUMS",
                "browser_download_url": f"{DOWNLOAD}/{tag}/SHA256SUMS",
            },
        ]
    return payload


class FakeGitHub:
    def __init__(self, release=None, sums=None, reachable=True):
        self.release = release if release is not None else release_json()
        self.sums = sums if sums is not None else f"{DIGEST}  inat-lightroom-9.9.9.zip\n"
        self.reachable = reachable
        self.requests = []

    def __call__(self, method, url, body, headers):
        self.requests.append(url)

        if not self.reachable:
            return None, {"error": {"name": "connection refused"}}

        if url.endswith("SHA256SUMS"):
            return self.sums, {"status": 200}

        return json.dumps(self.release), {"status": 200}


def make(**kwargs):
    fake = FakeGitHub(**kwargs)
    plugin = LuaPlugin(http_handler=fake)
    return plugin, plugin.require("UpdateCore"), fake


@pytest.fixture
def pair():
    plugin, core, fake = make()
    return plugin, core, fake


# ---------------------------------------------------------------------------
# When to check
# ---------------------------------------------------------------------------


def test_a_machine_that_has_never_checked_is_due(pair):
    _plugin, core, _fake = pair
    assert core.isCheckDue(1000, 0, True) is True


def test_a_check_from_today_is_not_due_again(pair):
    _plugin, core, _fake = pair
    assert core.isCheckDue(1000, 1000 - 60, True) is False


def test_a_check_from_yesterday_is_due(pair):
    _plugin, core, _fake = pair
    assert core.isCheckDue(DAY + 10, 5, True) is True


def test_a_last_checked_time_in_the_future_is_due(pair):
    _plugin, core, _fake = pair
    assert core.isCheckDue(1000, 99999, True) is True, (
        "a clock that moved, or a preferences file written by another "
        "machine, must not switch the check off forever"
    )


def test_turning_the_preference_off_stops_the_check(pair):
    _plugin, core, _fake = pair
    assert core.isCheckDue(DAY * 10, 0, False) is False


def test_the_interval_is_a_day(pair):
    _plugin, core, _fake = pair
    assert core.CHECK_INTERVAL_SECONDS == DAY, (
        "releases arrive weeks apart; the cost of being a day late is "
        "nothing next to hitting GitHub on every launch from every machine"
    )


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------


def test_a_check_records_when_it_happened(pair):
    plugin, core, _fake = pair
    plugin.call(core.check)

    assert plugin.prefs["update_last_checked"], (
        "without a timestamp the throttle cannot work"
    )


def test_a_failed_check_still_records_when_it_happened():
    plugin, core, _fake = make(reachable=False)
    plugin.call(core.check)

    assert plugin.prefs["update_last_checked"], (
        "recording only successes turns an offline week into a request on "
        "every single launch, which is what rate limits punish"
    )


def test_a_failed_check_says_so_rather_than_nothing():
    plugin, core, _fake = make(reachable=False)
    result, err = plugin.call(core.check)

    assert result is None
    assert core.statusText(None, err).startswith("Could not check")


# ---------------------------------------------------------------------------
# What it says
# ---------------------------------------------------------------------------


def test_it_names_both_versions_when_an_update_exists(pair):
    plugin, core, _fake = pair
    result, _err = plugin.call(core.check)

    text = core.statusText(result, None)
    assert "9.9.9" in text and "You have" in text


def test_it_says_so_when_there_is_nothing_new():
    installed = LuaPlugin().require("Updater").currentVersion()
    tag = "v%d.%d.%d" % (installed.major, installed.minor, installed.revision)

    plugin, core, _fake = make(release=release_json(tag=tag))
    result, _err = plugin.call(core.check)

    assert "latest release" in core.statusText(result, None)


def test_a_release_with_no_archive_points_at_the_releases_page():
    plugin, core, _fake = make(release=release_json(assets=False))
    result, _err = plugin.call(core.check)

    text = core.statusText(result, None)
    assert "releases page" in text, (
        "a release published by hand has nothing to download, and the honest "
        "answer is to send the user somewhere that does"
    )


def test_the_staged_message_says_when_it_takes_effect(pair):
    plugin, core, _fake = pair
    result, _err = plugin.call(core.check)

    text = core.stagedText(result)
    assert "quit" in text.lower() and "9.9.9" in text


# ---------------------------------------------------------------------------
# Installing
# ---------------------------------------------------------------------------


def test_nothing_to_install_is_refused_politely(pair):
    plugin, core, _fake = pair
    ok, err = plugin.call(core.install, None)

    assert ok is None
    assert "nothing to install" in err


def test_it_will_not_install_what_it_could_not_verify():
    # A release whose checksum file cannot be read is exactly the case the
    # checksum exists for.
    plugin, core, _fake = make(sums="")
    result, _err = plugin.call(core.check)
    ok, err = plugin.call(core.install, result)

    assert ok is None
    assert "checksum" in err


# ---------------------------------------------------------------------------
# The unattended check
# ---------------------------------------------------------------------------


def test_it_tells_you_once_about_a_version(pair):
    plugin, core, _fake = pair
    result, _err = plugin.call(core.check)

    assert core.shouldNotify(result, "") is True
    assert core.shouldNotify(result, "v9.9.9") is False, (
        "being told about the same release every morning is how people learn "
        "to click through a notification without reading it"
    )


def test_it_does_not_interrupt_you_about_a_version_you_have():
    installed = LuaPlugin().require("Updater").currentVersion()
    tag = "v%d.%d.%d" % (installed.major, installed.minor, installed.revision)

    plugin, core, _fake = make(release=release_json(tag=tag))
    result, _err = plugin.call(core.check)

    assert core.shouldNotify(result, "") is False


def test_it_does_not_interrupt_you_about_something_it_cannot_install():
    plugin, core, _fake = make(release=release_json(assets=False))
    result, _err = plugin.call(core.check)

    assert core.shouldNotify(result, "") is False, (
        "the dialog offers one button and that button installs; there is "
        "nothing for it to do with a release published by hand"
    )


def test_the_startup_check_does_not_run_inline(pair):
    plugin, core, fake = pair
    plugin.call(core.checkOnStartup)

    assert fake.requests == [], (
        "LrInitPlugin must return promptly; Lightroom is loading plugins"
    )

    plugin.run_pending_tasks()
    assert fake.requests, "the check has to actually happen once it is a task"


def test_the_startup_check_respects_the_preference(pair):
    plugin, core, fake = pair
    plugin.prefs["update_check_automatically"] = False

    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert fake.requests == []


def test_the_startup_check_remembers_what_it_told_you(pair):
    plugin, core, _fake = pair
    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert plugin.prefs["update_notified_tag"] == "v9.9.9"


def _stub_install(plugin, core, *, succeeds):
    """Replace the install step with one that records and answers to order.

    The real one writes into the installed plugin folder, which the harness
    does not have; what these tests are about is what the dialog does with the
    answer, not the staging that UpdateInstall's own tests cover.
    """
    calls = plugin.eval("function() return {} end")()
    core.install = plugin.eval(
        """
        function(calls, succeeds)
          return function(result)
            calls[#calls + 1] = result
            if succeeds then return true end
            return nil, "the download did not match its checksum"
          end
        end
        """
    )(calls, succeeds)
    return calls


def test_the_startup_check_never_installs_unasked(pair):
    plugin, core, _fake = pair
    calls = _stub_install(plugin, core, succeeds=True)

    # The harness answers "cancel" unless a test says otherwise, so this is
    # someone pressing Later.
    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert len(calls) == 0, (
        "checking is automatic and installing is not: a plugin that replaces "
        "itself unasked changes what your catalog does while you are away"
    )


def test_the_startup_dialog_offers_the_update_itself(pair):
    plugin, core, _fake = pair
    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    offer = plugin.dialogs[0]
    assert offer["style"] == "confirm"
    assert "9.9.9" in offer["message"]
    assert plugin.opened_urls == [], (
        "a browser is a detour: the plugin can do the update here, and the "
        "releases page is a button in the Plug-in Manager for anyone who "
        "wants to read the notes first"
    )


def test_pressing_update_stages_the_release(pair):
    plugin, core, _fake = pair
    calls = _stub_install(plugin, core, succeeds=True)
    plugin.set_confirm_answer("ok")

    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert len(calls) == 1, (
        "the whole point of the button is that it does the update"
    )
    assert any(d["style"] == "bezel" for d in plugin.dialogs), (
        "the dialog is gone by then, and a second of nothing reads as a "
        "button that did not work"
    )
    assert "quit" in plugin.dialogs[-1]["message"].lower(), (
        "having pressed Update, you are owed the one fact that matters: it "
        "takes effect when you quit"
    )


def test_a_failed_install_from_the_dialog_says_so(pair):
    plugin, core, _fake = pair
    _stub_install(plugin, core, succeeds=False)
    plugin.set_confirm_answer("ok")

    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert "Could not install" in plugin.dialogs[-1]["message"], (
        "silence after pressing a button reads as success, and this one "
        "leaves the old version running"
    )
    assert "checksum" in plugin.dialogs[-1]["message"]


def test_a_release_with_no_archive_does_not_interrupt():
    plugin, core, _fake = make(release=release_json(assets=False))
    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert plugin.dialogs == [], (
        "the dialog's offer is a button that installs; a release published by "
        "hand has nothing to install, so it waits in the Plug-in Manager"
    )
    assert not plugin.prefs["update_notified_tag"], (
        "nothing was said, so the offer must still arrive if the archive is "
        "attached later"
    )


def test_an_offline_startup_check_says_nothing_at_all():
    plugin, core, _fake = make(reachable=False)
    plugin.call(core.checkOnStartup)
    plugin.run_pending_tasks()

    assert plugin.dialogs == [], (
        "a dialog about a failed background check is noise about something "
        "the user did not ask for"
    )


# ---------------------------------------------------------------------------
# Telling someone their session is half-updated
# ---------------------------------------------------------------------------


def test_the_restart_notice_names_the_version_and_the_cure(pair):
    """Two facts and nothing else to do. Naming the version is what makes it
    an update notice rather than an error, and the restart is the only action
    -- the folder on disk is already correct."""
    _plugin, core, _fake = pair

    text = core.restartNeededText("v0.3.2")

    assert "v0.3.2" in text
    assert "quit Lightroom and start it again" in text
    assert "Nothing is damaged" in text


def test_the_restart_notice_does_not_interrupt_lightroom_starting(pair):
    """Same reasoning as the startup check: a modal raised from LrInitPlugin
    lands before Lightroom has drawn a window, and LrInitPlugin has to return
    promptly either way."""
    plugin, core, _fake = pair

    plugin.call(core.announceRestartNeeded, "v0.3.2")

    assert plugin.dialogs == [], "nothing may be shown during LrInitPlugin"

    plugin.run_pending_tasks()

    assert len(plugin.dialogs) == 1, "but it does have to be shown"
    assert plugin.sleeps, "and only once Lightroom is up"


def test_the_restart_notice_is_not_an_error(pair):
    """The update worked. Every file copied, nothing is missing, and the only
    consequence is that this session is running the old file list -- so a
    critical alert would be claiming damage that is not there and inviting a
    repair that would do nothing."""
    plugin, core, _fake = pair

    plugin.call(core.announceRestartNeeded, "v0.3.2")
    plugin.run_pending_tasks()

    assert plugin.dialogs[0]["style"] == "info"


def test_plugin_init_says_so_at_the_moment_it_becomes_true():
    """This is the whole fix. Two releases in a row, a user's session was left
    unable to load a module and was told nothing until they clicked a menu
    item and got "An internal error has occurred" naming a Lua file. The
    notice has to be raised where the situation is created."""
    init = (PLUGIN_DIR / "PluginInit.lua").read_text(encoding="utf-8")
    body = init.split("--]]", 1)[1]

    assert "announceRestartNeeded(applied)" in body, (
        "an update applied here leaves the session half-loaded, and saying so "
        "is the only thing that can be done about it"
    )


# ---------------------------------------------------------------------------
# The Plug-in Manager section
# ---------------------------------------------------------------------------


@pytest.fixture
def props(pair):
    plugin, _core, _fake = pair
    return _property_table(plugin)


def _property_table(plugin):
    return plugin.eval("function() return {} end")()


def test_the_section_shows_the_installed_version(pair):
    plugin, _core, _fake = pair
    provider = plugin.require("PluginInfoProvider")

    state = provider.initialise(_property_table(plugin), "/plugins/pinned.lrplugin")
    assert state.installedVersion


def test_the_section_starts_with_nothing_checked(pair):
    plugin, _core, _fake = pair
    provider = plugin.require("PluginInfoProvider")

    state = provider.initialise(_property_table(plugin), "/plugins/pinned.lrplugin")
    assert state.status == "Not checked yet."
    assert state.result is None, (
        "the Install button is bound to this, and it must not be live before "
        "a check has found something installable"
    )


def test_checking_from_the_section_fills_in_the_status(pair):
    plugin, _core, _fake = pair
    provider = plugin.require("PluginInfoProvider")
    state = provider.initialise(_property_table(plugin), "/plugins/pinned.lrplugin")

    plugin.call(provider.runCheck, state)

    assert "9.9.9" in state.status
    assert state.result is not None
    assert state.busy is False


def test_installing_without_checking_is_refused(pair):
    plugin, _core, _fake = pair
    provider = plugin.require("PluginInfoProvider")
    state = provider.initialise(_property_table(plugin), "/plugins/pinned.lrplugin")

    assert plugin.call(provider.runInstall, state)[0] is False
    assert "Check for updates first" in state.status


# ---------------------------------------------------------------------------
# Repairing
# ---------------------------------------------------------------------------


def installed_tag() -> str:
    """The tag of the release this working copy claims to be."""
    version = LuaPlugin().require("Updater").currentVersion()
    return "v%d.%d.%d" % (version.major, version.minor, version.revision)


def stub_staging(plugin, *, succeeds=True):
    """Replace UpdateInstall.stage, recording what it was asked to install.

    Field assignment on the required module, which is the same table UpdateCore
    holds: require caches. The real one downloads and shells out, neither of
    which belongs in a test about which release a repair chooses.
    """
    calls = plugin.eval("function() return {} end")()
    plugin.require("UpdateInstall").stage = plugin.eval(
        """
        function(calls, succeeds)
          return function(release, hash)
            calls[#calls + 1] = { tag = release.tag, hash = hash }
            if succeeds then return true end
            return nil, "the folder is read-only"
          end
        end
        """
    )(calls, succeeds)
    return calls


def test_repairing_reinstalls_a_release_that_is_not_newer():
    """The whole reason repair exists. Every guard on the update path asks "is
    it newer?", and for a damaged copy of the current release the answer is no
    -- so an update could never put the missing files back."""
    tag = installed_tag()
    plugin, core, _fake = make(release=release_json(tag=tag))
    calls = stub_staging(plugin)

    result, err = plugin.call(core.repair)

    assert err is None
    assert result is not None
    assert [call["tag"] for call in calls.values()] == [tag]


def test_repairing_verifies_the_checksum_like_any_other_install():
    tag = installed_tag()
    plugin, core, _fake = make(release=release_json(tag=tag))
    calls = stub_staging(plugin)

    plugin.call(core.repair)

    assert [call["hash"] for call in calls.values()] == [DIGEST], (
        "a repair writes to the plugin folder exactly as an update does, so "
        "it cannot be the one path that skips the checksum"
    )


def test_a_release_with_no_archive_cannot_be_repaired_from():
    plugin, core, _fake = make(release=release_json(assets=False))
    stub_staging(plugin)

    ok, err = plugin.call(core.repair)

    assert ok is None
    assert "by hand" in err, "there is nothing here that can put the files back"


def test_a_repair_cannot_start_when_github_is_unreachable():
    plugin, core, _fake = make(reachable=False)
    stub_staging(plugin)

    ok, err = plugin.call(core.repair)

    assert ok is None
    assert err


def test_a_failed_staging_is_reported_rather_than_claimed():
    tag = installed_tag()
    plugin, core, _fake = make(release=release_json(tag=tag))
    stub_staging(plugin, succeeds=False)

    ok, err = plugin.call(core.repair)

    assert ok is None
    assert "read-only" in err


def test_a_repair_is_described_as_a_reinstall(pair):
    """"Version 0.3.0 is ready" reads as though nothing happened when 0.3.0 is
    the version you are already on and the one that is broken."""
    plugin, core, _fake = pair
    result, _err = plugin.call(core.check)

    text = core.repairedText(result)
    assert "reinstalled" in text
    assert "quit Lightroom" in text


def test_the_automatic_check_preference_round_trips(pair):
    plugin, _core, _fake = pair
    provider = plugin.require("PluginInfoProvider")
    state = _property_table(plugin)

    provider.startDialog(state)
    assert state.update_check_automatically is True, (
        "on by default: the check is one request a day, and a plugin talking "
        "to a live API is worth keeping current"
    )

    state.update_check_automatically = False
    provider.endDialog(state)

    assert plugin.prefs["update_check_automatically"] is False
