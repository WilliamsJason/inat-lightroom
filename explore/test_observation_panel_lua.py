"""The floating observation panel.

Covers ObservationPanel.lua: what it says about a photo, what it puts on the
property table, that the window is wired to follow the filmstrip selection, and
that its buttons do what they claim.

The panel is the plugin's only surface that can hold both data and controls --
the Metadata panel is docked but text-only, the publish service has controls but
no per-photo detail -- so the wiring that makes it follow the selection is the
whole point of it and is guarded here.
"""

import pytest

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def panel(plugin):
    return plugin.require("ObservationPanel")


def show(plugin, panel):
    """Open the panel and return the args presentFloatingDialog was given."""
    plugin.call(panel.show)
    plugin.run_pending_tasks()
    dialogs = plugin.floating_dialogs
    assert len(dialogs) == 1, "expected exactly one floating window"
    return dialogs[0]


def views(node, found=None):
    """Every table in a view tree, flattened."""
    found = [] if found is None else found
    if not hasattr(node, "keys"):
        return found
    found.append(node)
    for key in list(node.keys()):
        child = node[key]
        if hasattr(child, "keys"):
            views(child, found)
    return found


def of_type(contents, view_type):
    return [v for v in views(contents) if v["_viewType"] == view_type]


# ---------------------------------------------------------------------------
# What it says about a photo
# ---------------------------------------------------------------------------


def test_a_photo_that_has_never_been_uploaded_says_so(plugin, panel):
    photo = plugin.new_photo()
    assert plugin.call(panel.statusFor, photo)[0] == "Not uploaded yet"


def test_no_selection_says_so(plugin, panel):
    assert plugin.call(panel.statusFor, None)[0] == "No photo selected"


def test_an_identified_photo_shows_its_common_and_scientific_name(plugin, panel):
    photo = plugin.new_photo(
        inat_observation_id="123",
        inat_taxon_name="Apis mellifera",
        inat_common_name="Western Honey Bee",
    )
    status = plugin.call(panel.statusFor, photo)[0]
    assert status == "Western Honey Bee (Apis mellifera)"


def test_a_taxon_with_no_common_name_shows_the_scientific_one_alone(plugin, panel):
    photo = plugin.new_photo(inat_observation_id="123", inat_taxon_name="Apis")
    assert plugin.call(panel.statusFor, photo)[0] == "Apis"


def test_an_unidentified_observation_is_not_reported_as_a_problem(plugin, panel):
    """The normal state of anything just published, so it must not read as an
    error -- nobody has identified it yet, which is nothing to fix."""
    photo = plugin.new_photo(inat_observation_id="387778406")
    status = plugin.call(panel.statusFor, photo)[0]
    assert status == "Observation 387778406 - not identified yet"
    assert "error" not in status.lower()
    assert "fail" not in status.lower()


def test_empty_strings_count_as_absent(plugin, panel):
    """Lightroom hands back "" for a field that was written and then cleared,
    and "Observation  - not identified yet" would be the result of trusting it.
    """
    photo = plugin.new_photo(inat_observation_id="", inat_taxon_name="")
    assert plugin.call(panel.statusFor, photo)[0] == "Not uploaded yet"


# ---------------------------------------------------------------------------
# The values it publishes to the view
# ---------------------------------------------------------------------------


def test_values_carry_the_stored_fields(plugin, panel):
    photo = plugin.new_photo(
        inat_observation_id="123",
        inat_quality_grade="research",
        inat_last_synced="2026-08-06T12:00:00Z",
        inat_species_guess="Apis mellifera",
    )
    values = plugin.call(panel.valuesFor, photo, 1)[0]

    assert values["observationId"] == "123"
    assert values["quality"] == "research"
    assert values["lastSynced"] == "2026-08-06T12:00:00Z"
    assert values["speciesGuess"] == "Apis mellifera"
    assert values["hasPhoto"] is True
    assert values["hasObservation"] is True


def test_a_photo_with_no_observation_disables_the_view_button(plugin, panel):
    values = plugin.call(panel.valuesFor, plugin.new_photo(), 1)[0]
    assert values["hasPhoto"] is True
    assert values["hasObservation"] is False


def test_nothing_selected_disables_everything(plugin, panel):
    values = plugin.call(panel.valuesFor, None, 0)[0]
    assert values["hasPhoto"] is False
    assert values["hasObservation"] is False
    assert values["selection"] == "Select a photo in the filmstrip"


def test_a_multi_photo_selection_says_it_is_showing_only_the_first(plugin, panel):
    """Everything below the heading describes one photo. Without this the
    species guess field looks like it applies to all of them."""
    photo = plugin.new_photo(inat_observation_id="123")
    values = plugin.call(panel.valuesFor, photo, 4)[0]
    assert values["selection"] == "4 photos selected - showing the first"


def test_a_single_selection_is_named_by_its_file(plugin, panel):
    photo = plugin.new_photo(formatted={"fileName": "DSC_1234.NEF"})
    values = plugin.call(panel.valuesFor, photo, 1)[0]
    assert values["selection"] == "DSC_1234.NEF"


# ---------------------------------------------------------------------------
# The window itself
# ---------------------------------------------------------------------------


def test_the_window_follows_the_filmstrip_selection(plugin, panel):
    """The reason this is a floating window and not a menu item. Without an
    observer it shows whatever was selected when it opened, forever."""
    args = show(plugin, panel)
    assert args["selectionChangeObserver"] is not None


def test_the_window_follows_a_change_of_folder_or_collection(plugin, panel):
    args = show(plugin, panel)
    assert args["sourceChangeObserver"] is not None


def test_the_window_remembers_where_it_was_put(plugin, panel):
    """A floating window that reopens centred every time is a window people
    close and never open again."""
    args = show(plugin, panel)
    assert args["save_frame"], "save_frame is what persists position and size"
    assert args["id"], "save_frame needs an id to key the stored frame on"


def test_the_window_holds_its_task_open(plugin, panel):
    """The property table belongs to this task's function context. Without
    blockTask the task ends, the context dies, and every binding in the window
    is pointing at a dead object."""
    args = show(plugin, panel)
    assert args["blockTask"] is True


def test_the_observer_picks_up_the_new_selection(plugin, panel):
    """The whole contract, end to end: change the selection, fire the observer
    the way Lightroom does, and the bound values must have changed."""
    first = plugin.new_photo(
        inat_observation_id="1", inat_taxon_name="Apis mellifera",
        formatted={"fileName": "one.jpg"},
    )
    second = plugin.new_photo(formatted={"fileName": "two.jpg"})

    plugin.set_target_photos([first])
    args = show(plugin, panel)

    contents = args["contents"]
    props = contents["bind_to_object"]
    assert props["status"] == "Apis mellifera"
    assert props["selection"] == "one.jpg"

    plugin.set_target_photos([second])
    plugin.call(args["selectionChangeObserver"])
    plugin.run_pending_tasks()

    assert props["status"] == "Not uploaded yet"
    assert props["selection"] == "two.jpg"


def test_the_observer_reads_the_catalog_on_a_task(plugin, panel):
    """Lightroom calls the window's observers outside any task, and reading
    plugin metadata yields. Doing it inline raises "We can only wait from
    within a task", which Lightroom then swallows -- so the panel silently
    stops following the filmstrip. Observed in the host exactly that way."""
    first = plugin.new_photo(formatted={"fileName": "one.jpg"})
    second = plugin.new_photo(formatted={"fileName": "two.jpg"})

    plugin.set_target_photos([first])
    args = show(plugin, panel)
    props = args["contents"]["bind_to_object"]

    plugin.set_target_photos([second])
    plugin.call(args["selectionChangeObserver"])

    assert props["selection"] == "one.jpg", (
        "the observer must hand the catalog reads to a task rather than doing "
        "them inline"
    )
    assert plugin.pending_task_count() > 0, "and it must actually queue one"


def test_the_source_observer_also_reads_on_a_task(plugin, panel):
    """Same trap, same fix: a folder or collection change fires this one."""
    first = plugin.new_photo(formatted={"fileName": "one.jpg"})
    second = plugin.new_photo(formatted={"fileName": "two.jpg"})

    plugin.set_target_photos([first])
    args = show(plugin, panel)
    props = args["contents"]["bind_to_object"]

    plugin.set_target_photos([second])
    plugin.call(args["sourceChangeObserver"])

    assert props["selection"] == "one.jpg"
    assert plugin.pending_task_count() > 0


def test_a_superseded_refresh_does_not_overwrite_a_newer_one(plugin, panel):
    """Arrow-keying fires the observer faster than the reads finish, and a
    folder change reports the whole folder selected before settling on one
    photo. Whichever refresh was asked for last has to win, whatever order the
    reads happen to complete in."""
    stale = plugin.new_photo(formatted={"fileName": "stale.jpg"})
    fresh = plugin.new_photo(formatted={"fileName": "fresh.jpg"})

    plugin.set_target_photos([stale])
    args = show(plugin, panel)
    props = args["contents"]["bind_to_object"]

    # Two refreshes queued back to back, each reading a different selection.
    plugin.set_target_photos([stale])
    plugin.call(args["selectionChangeObserver"])
    plugin.set_target_photos([fresh])
    plugin.call(args["selectionChangeObserver"])

    # Drained back to front: the older refresh finishes last, which is the
    # ordering that would let it win.
    plugin.run_pending_tasks(reverse=True)

    assert props["selection"] == "fresh.jpg", (
        "the newest refresh must win; an older one completing later must not "
        "put the panel back on the previous photo"
    )


def test_the_window_offers_the_actions_the_metadata_panel_cannot(plugin, panel):
    """The Metadata panel is validated down to string/enum/url fields, so it can
    never hold a button. These are the actions that had nowhere else to live."""
    args = show(plugin, panel)
    titles = {b["title"] for b in of_type(args["contents"], "push_button")}
    assert "Sync" in titles
    assert "View on iNaturalist" in titles
    # The ellipsis is a multi-byte character and Lua hands back raw bytes, so
    # match the part of the label that is plain ASCII.
    assert any(t.startswith("Link to Observation") for t in titles)


def test_the_species_guess_is_editable_here(plugin, panel):
    """The one field a user is meant to type into, next to the buttons that act
    on it rather than only in the Metadata panel."""
    args = show(plugin, panel)
    fields = of_type(args["contents"], "edit_field")
    assert len(fields) == 1
    assert fields[0]["value"]["__bind"] == "speciesGuess"


def test_the_view_button_is_disabled_without_an_observation(plugin, panel):
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}
    assert buttons["View on iNaturalist"]["enabled"]["__bind"] == "hasObservation"


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------


def test_saving_the_species_guess_writes_every_selected_photo(plugin, panel):
    """Deliberately the whole selection, unlike the display: one name across the
    six frames of the same animal is the common case."""
    photos = [plugin.new_photo(), plugin.new_photo(), plugin.new_photo()]
    plugin.set_target_photos(photos)

    props = plugin.runtime.table_from({"speciesGuess": "Apis mellifera"})
    count = plugin.call(panel.saveSpeciesGuess, props)[0]

    assert count == 3
    for photo in photos:
        assert photo["_props"]["inat_species_guess"] == "Apis mellifera"


def test_saving_the_species_guess_opens_a_write_transaction(plugin, panel):
    """setPropertyForPlugin outside one throws in the real catalog."""
    plugin.set_target_photos([plugin.new_photo()])
    props = plugin.runtime.table_from({"speciesGuess": "Apis"})
    plugin.call(panel.saveSpeciesGuess, props)
    assert plugin.catalog_writes == ["iNat species guess"]


def test_saving_with_nothing_selected_does_nothing(plugin, panel):
    plugin.set_target_photos([])
    props = plugin.runtime.table_from({"speciesGuess": "Apis"})
    assert plugin.call(panel.saveSpeciesGuess, props)[0] == 0
    assert plugin.catalog_writes == []


def test_clearing_the_species_guess_is_allowed(plugin, panel):
    """Emptying the field has to reach the photo. Treating "" as "no change"
    would make a wrong guess impossible to take back."""
    photo = plugin.new_photo(inat_species_guess="Wrong")
    plugin.set_target_photos([photo])

    props = plugin.runtime.table_from({"speciesGuess": ""})
    plugin.call(panel.saveSpeciesGuess, props)

    assert photo["_props"]["inat_species_guess"] == ""


def test_the_view_button_opens_the_observation(plugin, panel):
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="387778406")])
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}

    plugin.call(buttons["View on iNaturalist"]["action"])
    plugin.run_pending_tasks()

    assert plugin.opened_urls == [
        "https://www.inaturalist.org/observations/387778406"
    ]


def test_the_view_button_opens_nothing_without_an_observation(plugin, panel):
    """enabled is a binding, and a binding is not a guarantee -- the action has
    to refuse too, or a stale click opens /observations/ and a 404."""
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}

    plugin.call(buttons["View on iNaturalist"]["action"])
    plugin.run_pending_tasks()

    assert plugin.opened_urls == []
