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


def test_leftover_application_fields_do_not_stop_a_token_being_stored(plugin, dialog):
    """The OAuth password-grant fields are gone, but a property table is just a
    table and callers can put anything in one. Reading only what it needs means
    a stray key cannot divert the token away from being stored."""
    stored, err = dialog["saveCredentials"](
        props(
            plugin,
            api_token=_jwt(),
            app_id="id",
            app_secret="secret",
            user_pass="pw",
        )
    )

    assert err is None
    assert stored == "token"


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


# ---------------------------------------------------------------------------
# The keyword root
#
# Configurable because rcloran's lr-inaturalist-publish -- the other plugin
# with this workflow -- syncs taxonomy keywords under a root the user picks and
# prunes anything under it that it considers non-equivalent. Two plugins
# pointed at one keyword means whichever syncs last strips the other's
# keywords off the photo, silently.
# ---------------------------------------------------------------------------


def test_the_root_still_defaults_to_inaturalist(settings):
    """The root is provenance, not branding: keywords leave Lightroom as XMP
    subject tags, where "iNaturalist > Animalia > …" says where the
    identification came from."""
    assert settings["DEFAULTS"]["sync_keyword_root"] == "iNaturalist"


def test_saving_stores_the_keyword_root(plugin, dialog, settings):
    dialog["savePreferences"](props(plugin, sync_keyword_root="Nature > iNat"))

    assert settings["get"]("sync_keyword_root") == "Nature > iNat"


def test_saving_tidies_a_typed_root(plugin, dialog, settings):
    """A trailing separator would otherwise become an empty keyword level,
    which the sync refuses -- so the whole lineage would go unwritten."""
    dialog["savePreferences"](props(plugin, sync_keyword_root="  Nature >  "))

    assert settings["get"]("sync_keyword_root") == "Nature"


def test_an_emptied_root_is_stored_as_empty(plugin, dialog, settings):
    """Empty means the top level of the catalog, which is a choice and not an
    absence -- it must not fall back to the default."""
    dialog["savePreferences"](props(plugin, sync_keyword_root=""))

    assert settings["get"]("sync_keyword_root") == ""


def test_the_picker_offers_every_keyword_in_the_catalog(plugin, dialog):
    plugin.add_keyword("Nature")
    plugin.add_keyword("Places")
    plugin.add_keyword("Wildlife", "Nature")

    items = plugin.in_task(dialog["keywordRootItems"], plugin.catalog)
    values = [items[i]["value"] for i in range(1, len(items) + 1)]

    assert values == ["", "Nature", "Nature > Wildlife", "Places"]


def test_the_pickers_first_item_chooses_nothing(plugin, dialog):
    """Selecting it must not empty the field -- it is the popup's resting
    state, not a keyword."""
    items = plugin.in_task(dialog["keywordRootItems"], plugin.catalog)

    assert items[1]["title"] == dialog["KEYWORD_ROOT_PICK_PROMPT"]
    assert items[1]["value"] == ""


def test_a_child_is_offered_as_a_full_path(plugin, dialog):
    """Bare names would be ambiguous: two different parents can each have a
    child called Insects, and the setting has to say which."""
    plugin.add_keyword("Nature")
    plugin.add_keyword("Insects", "Nature")

    items = plugin.in_task(dialog["keywordRootItems"], plugin.catalog)
    titles = [items[i]["title"] for i in range(1, len(items) + 1)]

    assert "Nature > Insects" in titles


def test_the_picker_stops_before_it_lists_a_whole_catalog(plugin, dialog):
    """This plugin creates a keyword per taxon, so a heavy user's catalog can
    hold tens of thousands. The edit field still takes any path."""
    limit = int(dialog["KEYWORD_ROOT_PICK_LIMIT"])
    for i in range(limit + 50):
        plugin.add_keyword(f"kw{i:05d}")

    items = plugin.in_task(dialog["keywordRootItems"], plugin.catalog)

    assert len(items) <= limit + 1


def test_opening_the_dialog_reads_the_catalog_from_inside_a_task(plugin, dialog):
    """The picker walks catalog:getKeywords, which refuses outside a task, and
    reads each keyword's name, which refuses outside a read block.

    A menu item's script is neither, and neither is callWithContext, so
    building the dialog there raised before it could appear. The two failures
    read very differently to a user: the first arrived as "An internal error
    has occurred: We can only wait from within a task", and the second, raised
    inside the task that replaced it, as nothing whatsoever -- the menu item
    simply did nothing. Every other test here calls the pieces directly, so
    only opening it the way the menu does can catch either.
    """
    plugin.add_keyword("Nature")
    plugin.add_keyword("Wildlife", "Nature")

    dialog["show"]()
    plugin.run_pending_tasks()


def test_the_dialog_opens_even_when_the_keywords_cannot_be_read(plugin, dialog):
    """The picker is a convenience; the dialog is not.

    A failed catalog read must cost the popup and nothing else -- the field
    beside it still takes any path typed in, and the other two tabs hold the
    credentials. Losing the whole window over it is how one broken read made
    every setting in the plugin unreachable.
    """
    plugin.set_keywords_fail(True)

    dialog["show"]()
    plugin.run_pending_tasks()

    assert any("could not list keywords" in line for line in plugin.log_lines), (
        "A read that fails behind a closed dialog is invisible unless it is "
        "logged: nothing raised inside this task reaches the user."
    )


def bindable(plugin):
    """A property table of the kind the dialog builds, which notifies."""
    return plugin.env["stubs"]["LrBinding"]["makePropertyTable"]()


def test_picking_a_keyword_fills_in_the_field(plugin, dialog):
    props = bindable(plugin)
    props["sync_keyword_root"] = "iNaturalist"
    dialog["watchKeywordRootPicker"](props)

    props["sync_keyword_root_pick"] = "Nature > Wildlife"

    assert props["sync_keyword_root"] == "Nature > Wildlife"


def test_the_picker_returns_to_its_prompt(plugin, dialog):
    """Otherwise choosing the same keyword a second time is a write of the
    value already there, which Lightroom does not notify for."""
    props = bindable(plugin)
    dialog["watchKeywordRootPicker"](props)

    props["sync_keyword_root_pick"] = "Nature"

    assert props["sync_keyword_root_pick"] == ""


def test_the_prompt_row_does_not_empty_the_field(plugin, dialog):
    """The reset above fires the observer again. Treating the prompt as a
    value would wipe the root the user just chose."""
    props = bindable(plugin)
    props["sync_keyword_root"] = "iNaturalist"
    dialog["watchKeywordRootPicker"](props)

    props["sync_keyword_root_pick"] = ""

    assert props["sync_keyword_root"] == "iNaturalist"


def test_the_observations_tab_lets_the_root_be_edited(plugin, dialog):
    """A setting nothing binds to cannot be changed without editing prefs by
    hand, which is the state this replaced."""
    from test_plugin_info_provider_lua import bound_keys, walk

    observations = tabs(plugin, dialog)[1]
    bound = [key for binding, _ in walk(observations)
             for key in bound_keys(binding)]

    assert "sync_keyword_root" in bound


def _jwt() -> str:
    from lua_harness import make_jwt

    return make_jwt(4_102_444_800)


# ---------------------------------------------------------------------------
# One operation at a time
#
# Both buttons start something that walks the whole catalog and writes to it.
# Overlapping runs fight over write transactions, and a reverse sync working out
# which photos are unlinked while a sync is busy linking them is reading a
# catalog that is changing underneath it.
# ---------------------------------------------------------------------------


def test_reverse_sync_will_not_start_while_something_else_is_running(
    plugin, dialog
):
    jobs = plugin.require("Jobs")
    started = []

    def busy():
        started.append(dialog["reverseSync"](plugin.eval("{ alive = true }")))

    jobs["run"]("Syncing all linked photos", busy)

    assert started == [False]
    assert "Syncing all linked photos" in plugin.dialogs[-1]["message"]


def test_a_sync_will_not_start_while_something_else_is_running(plugin):
    """Guarded at SyncCore.syncPhotos rather than at the button, because the
    menu, the panel and a link all reach the same work by other routes."""
    jobs = plugin.require("Jobs")
    sync = plugin.require("SyncCore")
    plugin.set_all_photos([plugin.new_photo(inat_observation_id="42")])
    started = []

    def busy():
        photos = plugin.eval("{}")
        started.append(sync["syncPhotos"](plugin.eval("{ alive = true }"),
                                          photos))

    jobs["run"]("Finding unlinked observations", busy)

    assert started == [False]
    assert "Finding unlinked observations" in plugin.dialogs[-1]["message"]


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


# ---------------------------------------------------------------------------
# The account tab asks for a token and nothing else
#
# iNaturalist recommends against the OAuth password grant, and specifically
# against it in distributed applications, because it means the user types their
# iNaturalist password into third-party software. The plugin used to offer
# exactly that -- app id, app secret, username, password -- and it worked,
# which is what makes this worth a guard rather than a note: the code to bring
# it back is in the history, and nothing else here would notice if it returned.
# ---------------------------------------------------------------------------


def account_tab_bindings(plugin, dialog):
    """Every property name the Account tab binds to."""
    from test_plugin_info_provider_lua import bound_keys, walk

    account = tabs(plugin, dialog)[0]
    return [key for binding, _ in walk(account) for key in bound_keys(binding)]


def test_the_account_tab_never_asks_for_an_inaturalist_password(plugin, dialog):
    """The whole reason the password grant was removed. A field bound to any of
    these means the plugin is collecting an account password again."""
    bound = account_tab_bindings(plugin, dialog)

    for key in ("app_id", "app_secret", "user_pass", "username"):
        assert key not in bound, (
            f"the Account tab binds to {key!r}. That was the OAuth "
            "password-grant form, which iNaturalist recommends against for "
            "distributed applications. Use the authorization code flow."
        )


def test_the_account_tab_still_takes_a_pasted_token(plugin, dialog):
    """The other half of the test above: proving those fields are gone is only
    reassuring if the one remaining way in still exists."""
    assert "api_token" in account_tab_bindings(plugin, dialog)
