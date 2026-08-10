"""Tests for SettingsDialog.lua and Settings.lua.

The dialog itself is modal and cannot be driven from here, so what is tested is
everything it delegates to: what a preference reads as when nobody has set it,
what Save actually stores, and which photos Sync All decides to sync. Those are
the parts that can be wrong without the dialog looking wrong.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def settings(plugin):
    return plugin.require("Settings")


@pytest.fixture
def dialog(plugin):
    return plugin.require("SettingsDialog")


# ---------------------------------------------------------------------------
# Preferences and their defaults
# ---------------------------------------------------------------------------


def test_an_unset_preference_reads_as_its_default(settings):
    """Lightroom returns nil for a preference nobody has set. A nil geoprivacy
    reaching the API is a 422 whose message does not say which field."""
    assert settings["get"]("inat_geoprivacy") == "open"


def test_a_stored_preference_wins_over_the_default(plugin, settings):
    settings["set"]("inat_geoprivacy", "obscured")

    assert settings["get"]("inat_geoprivacy") == "obscured"


def test_false_is_a_value_not_an_absence(settings):
    """`prefs[key] or default` would turn every checkbox the user unticked
    back on, which is the kind of bug nobody reports because they assume they
    forgot to save."""
    settings["set"]("inat_upload_location", False)

    assert settings["get"]("inat_upload_location") is False


def test_location_is_sent_by_default(settings):
    """An observation with no location is close to worthless as a biodiversity
    record. Obscuring it is what geoprivacy is for, and it does it properly."""
    assert settings["DEFAULTS"]["inat_upload_location"] is True
    assert settings["DEFAULTS"]["render_remove_location"] is False


def test_all_returns_every_known_preference(settings):
    values = settings["all"]()

    for key in list(settings["DEFAULTS"].keys()):
        assert values[key] is not None, key


# ---------------------------------------------------------------------------
# Saving the dialog
# ---------------------------------------------------------------------------


def props(plugin, **overrides):
    values = {
        "api_token": "",
        "app_id": "",
        "app_secret": "",
        "username": "",
        "user_pass": "",
    }
    values.update(overrides)
    return plugin.runtime.table_from(values)


def test_saving_stores_the_edited_preferences(plugin, dialog, settings):
    dialog["savePreferences"](props(plugin, inat_geoprivacy="private"))

    assert settings["get"]("inat_geoprivacy") == "private"


def test_saving_stores_a_preference_that_was_turned_off(plugin, dialog, settings):
    """The reason savePreferences checks for nil rather than falsiness."""
    dialog["savePreferences"](props(plugin, inat_upload_location=False))

    assert settings["get"]("inat_upload_location") is False


def test_saving_ignores_keys_that_are_not_preferences(plugin, dialog):
    """The property table also carries the credential fields and the status
    line. Copying the whole thing into prefs would write the user's pasted
    token to disk in clear text, which is the one thing this plugin promises
    not to do."""
    dialog["savePreferences"](props(plugin, api_token="secret-token"))

    assert plugin.prefs["api_token"] is None


def test_nothing_in_the_credential_fields_is_not_an_error(plugin, dialog):
    """Someone opening this to change geoprivacy has no reason to retype a
    token, and making them would be a good way to end up with neither saved."""
    stored, err = dialog["saveCredentials"](props(plugin))

    assert (stored, err) == (None, None)


def test_a_pasted_token_is_stored(plugin, dialog):
    stored, err = dialog["saveCredentials"](props(plugin, api_token=_jwt()))

    assert err is None
    assert stored == "token"


def test_full_application_details_beat_a_pasted_token(plugin, dialog):
    """Both filled in means the user has just set up an application; the token
    is whatever was left in the field from last time. The application refreshes
    itself and the token expires in 24 hours, so the application has to win."""
    stored, _ = dialog["saveCredentials"](
        props(
            plugin,
            api_token=_jwt(),
            app_id="id",
            app_secret="secret",
            username="me",
            user_pass="pw",
        )
    )

    assert stored == "oauth"


# ---------------------------------------------------------------------------
# Sync All
# ---------------------------------------------------------------------------


def test_sync_all_finds_every_linked_photo(plugin, dialog):
    linked = [
        plugin.new_photo(inat_observation_id="1"),
        plugin.new_photo(inat_observation_id="2"),
    ]
    plugin.set_all_photos(linked + [plugin.new_photo()])

    found = dialog["linkedPhotos"](plugin.catalog)

    assert len(found) == 2


def test_sync_all_skips_photos_whose_link_was_cleared(plugin, dialog):
    """Unlinking empties the field rather than removing it, so the catalog's
    index still returns those photos. Syncing them would fetch observation ""
    for every photo the user has ever unlinked."""
    plugin.set_all_photos([
        plugin.new_photo(inat_observation_id=""),
        plugin.new_photo(inat_observation_id="7"),
    ])

    found = dialog["linkedPhotos"](plugin.catalog)

    assert len(found) == 1
    assert found[1]["_props"]["inat_observation_id"] == "7"


def test_sync_all_is_not_the_filmstrip_selection(plugin, dialog):
    """The whole point of the button: it is in a modal dialog, nowhere near the
    Library, and 'everything linked' is what it says."""
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="selected")])
    plugin.set_all_photos([plugin.new_photo(inat_observation_id="elsewhere")])

    found = dialog["linkedPhotos"](plugin.catalog)

    assert len(found) == 1
    assert found[1]["_props"]["inat_observation_id"] == "elsewhere"


def test_sync_all_says_so_when_nothing_is_linked(plugin, dialog):
    """Otherwise the button appears to do nothing at all."""
    plugin.set_all_photos([plugin.new_photo()])

    synced = dialog["syncAll"](plugin.eval("{ alive = true }"))

    assert synced == 0
    assert plugin.dialogs, "no message shown"
    assert "No photos" in plugin.dialogs[0]["message"]


def _jwt() -> str:
    from lua_harness import make_jwt

    return make_jwt(4_102_444_800)


# ---------------------------------------------------------------------------
# The tab views
#
# ui.dll validates tab_view_item at build time and raises. Both messages are in
# the binary verbatim: "Multiple tab_view_item views with the same identifier"
# and "tab_view_item needs to have a string or number identifier". Either one
# means the settings window does not open at all, and nothing else in the
# plugin reports it.
# ---------------------------------------------------------------------------


def tabs(plugin, dialog):
    factory = plugin.view_factory()
    return list(
        dialog["tabs"](factory, props(plugin), plugin.eval("{}")).values()
    )


def test_there_is_a_tab_for_each_thing_a_person_comes_here_to_do(plugin, dialog):
    assert len(tabs(plugin, dialog)) == 3


def test_every_tab_has_a_string_identifier(plugin, dialog):
    for tab in tabs(plugin, dialog):
        assert isinstance(tab["identifier"], str), tab["title"]
        assert tab["identifier"]


def test_no_two_tabs_share_an_identifier(plugin, dialog):
    identifiers = [tab["identifier"] for tab in tabs(plugin, dialog)]

    assert len(set(identifiers)) == len(identifiers), identifiers


def test_every_tab_is_labelled(plugin, dialog):
    """An unlabelled tab is unreachable -- there is nothing to click."""
    for tab in tabs(plugin, dialog):
        assert tab["title"]


def test_the_account_tab_comes_first(plugin, dialog):
    """Nothing else in the dialog does anything until credentials exist."""
    assert tabs(plugin, dialog)[0]["identifier"] == "account"