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
from test_panel_core_lua import deep


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
    titles = {b["title"] for b in of_type(args["contents"], "push_button")
              if isinstance(b["title"], str)}
    assert "Sync" in titles
    assert "View on iNaturalist" in titles
    assert "Unlink" in titles
    assert "Get Suggestions" in titles
    # The ellipsis is a multi-byte character and Lua hands back raw bytes, so
    # match the part of the label that is plain ASCII.
    assert any(t.startswith("Link to Observation") for t in titles)


def test_there_is_no_save_button(plugin, panel):
    """A guess saved to the catalog and never sent anywhere is what looked like
    it worked and did not. Every route out of the field now ends at iNaturalist,
    so a Save button reappearing is a regression, not a convenience."""
    args = show(plugin, panel)
    titles = {b["title"] for b in of_type(args["contents"], "push_button")
              if isinstance(b["title"], str)}
    assert "Save" not in titles


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


def test_choosing_a_suggestion_fills_the_species_guess(plugin, panel):
    """Selecting a row is the point of the list. The scientific name goes in the
    field because it is unambiguous and it is what gets uploaded."""
    props = plugin.runtime.table_from({})
    props["suggestions"] = plugin.runtime.table_from({
        1: plugin.runtime.table_from(
            {"taxon_id": 47219, "name": "Apis mellifera",
             "common_name": "Western Honey Bee"}),
    })

    plugin.call(panel.chooseSuggestion, props, 1)

    assert props["speciesGuess"] == "Apis mellifera"
    assert props["suggestionTaxonId"] == 47219


def test_choosing_a_suggestion_that_is_not_there_clears_the_taxon(plugin, panel):
    """A stale taxon id is worse than none: the next button press would post an
    identification for a species nobody picked."""
    props = plugin.runtime.table_from({})
    props["suggestionTaxonId"] = 47219
    props["suggestions"] = plugin.runtime.table_from({})

    plugin.call(panel.chooseSuggestion, props, 3)

    assert props["suggestionTaxonId"] is None


def test_a_selection_reported_as_a_list_still_fills_the_species_guess(plugin, panel):
    """What f:simple_list actually hands back. Its `value` is bound to the
    table_view's `selected_indexes` through a transform, so a single click
    arrives as a one-entry list, not a number. Taking that literally as an index
    found no row and the click silently did nothing -- which is how this
    presented in the host: a list that highlighted rows and changed nothing."""
    props = plugin.runtime.table_from({})
    props["suggestions"] = plugin.runtime.table_from({
        1: plugin.runtime.table_from({"taxon_id": 1, "name": "Bombus"}),
        2: plugin.runtime.table_from({"taxon_id": 47219, "name": "Apis mellifera"}),
    })

    plugin.call(panel.chooseSuggestion, props,
                plugin.runtime.table_from({1: 2}))

    assert props["speciesGuess"] == "Apis mellifera"
    assert props["suggestionTaxonId"] == 47219


def test_a_selection_reported_as_a_list_of_items_still_works(plugin, panel):
    """The other shape the transform could plausibly produce: the item tables
    themselves rather than their values. Accepted because the difference is
    invisible until a user clicks a row and nothing happens."""
    props = plugin.runtime.table_from({})
    props["suggestions"] = plugin.runtime.table_from({
        1: plugin.runtime.table_from({"taxon_id": 1, "name": "Bombus"}),
        2: plugin.runtime.table_from({"taxon_id": 47219, "name": "Apis mellifera"}),
    })

    plugin.call(panel.chooseSuggestion, props,
                plugin.runtime.table_from(
                    {1: plugin.runtime.table_from({"title": "Apis mellifera",
                                                   "value": 2})}))

    assert props["suggestionTaxonId"] == 47219


def test_an_empty_selection_list_clears_the_taxon(plugin, panel):
    """Deselecting reports an empty list rather than nil, and an empty list must
    not leave the previous taxon armed."""
    props = plugin.runtime.table_from({})
    props["suggestionTaxonId"] = 47219
    props["suggestions"] = plugin.runtime.table_from({
        1: plugin.runtime.table_from({"taxon_id": 47219, "name": "Apis mellifera"}),
    })

    plugin.call(panel.chooseSuggestion, props, plugin.runtime.table_from({}))

    assert props["suggestionTaxonId"] is None


def test_unlinking_asks_first(plugin, panel):
    """Relinking means finding the observation ID by hand, so it is not a thing
    to do on a stray click next to three harmless buttons."""
    photo = plugin.new_photo(inat_observation_id="123")
    plugin.set_target_photos([photo])
    # The harness answers Cancel unless told otherwise.

    plugin.call(panel.unlink, plugin.runtime.table_from({}))

    assert photo["_props"]["inat_observation_id"] == "123"


def test_unlinking_when_confirmed_forgets_the_observation(plugin, panel):
    photo = plugin.new_photo(inat_observation_id="123",
                             inat_observation_url="https://x", inat_taxon_name="Apis")
    plugin.set_target_photos([photo])
    plugin.set_confirm_answer("ok")

    count = plugin.call(panel.unlink, plugin.runtime.table_from({}))[0]

    assert count == 1
    assert photo["_props"]["inat_observation_id"] == ""
    assert photo["_props"]["inat_observation_url"] == ""


def test_unlinking_says_it_leaves_inaturalist_alone(plugin, panel):
    """The word "unlink" does not make clear that nothing is deleted on the
    website. Somebody reading the dialog has to be able to tell."""
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="123")])
    plugin.call(panel.unlink, plugin.runtime.table_from({}))

    message = plugin.dialogs[-1]["message"]
    assert "iNaturalist" in message
    assert "keyword" in message.lower()


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


def test_the_copy_button_is_disabled_without_an_observation(plugin, panel):
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}
    assert buttons["Copy"]["enabled"]["__bind"] == "hasObservation"


def copies(plugin):
    """The clipboard shell-outs, apart from the window fix-up's own."""
    return [c for c in plugin.executed_commands if "Set-Clipboard" in c]


def test_the_copy_button_puts_the_id_on_the_clipboard(plugin, panel):
    """The number is needed in the Link dialog for the other frames of the same
    specimen, and an SDK static_text cannot be selected to copy by hand."""
    plugin.set_platform(windows=True)
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="387778406")])
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}

    plugin.call(buttons["Copy"]["action"])
    plugin.run_pending_tasks()

    assert len(copies(plugin)) == 1
    assert "387778406" in copies(plugin)[0]


def test_copying_nothing_copies_nothing(plugin, panel):
    plugin.set_platform(windows=True)
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")}

    plugin.call(buttons["Copy"]["action"])
    plugin.run_pending_tasks()

    assert copies(plugin) == []


def test_copying_reports_through_the_status_line(plugin, panel):
    """Not a modal: the point of the button is that linking further photos is a
    couple of clicks, and a dialog to dismiss every time would undo that."""
    props = plugin.runtime.table_from({"observationId": "387778406"})
    plugin.set_platform(windows=True)

    assert plugin.in_task(panel.copyObservationId, props) is True
    assert "387778406" in props["suggestionStatus"]
    assert plugin.dialogs == []


# ---------------------------------------------------------------------------
# Location
# ---------------------------------------------------------------------------


def stub_upload_path(plugin):
    """Get uploadOrUpdate past authentication and stop it before the network.

    These tests are about the gate in front of the upload, not about the upload
    or about signing in. Returns a table whose "count" says how many times the
    upload was actually reached.
    """
    return plugin.eval("""
      (function()
        local UploadCore = require "UploadCore"
        local PanelCore  = require "PanelCore"
        local reached = { count = 0, updates = 0, accuracy = nil }

        UploadCore.requireAPI = function()
          return {
            updateObservation = function(_self, _id, params, _ignorePhotos)
              reached.accuracy = params.positional_accuracy
              return { id = 4242 }, nil
            end,
          }, nil
        end
        PanelCore.upload = function()
          reached.count = reached.count + 1
          return 42, nil, {}
        end
        PanelCore.updateSpeciesGuess = function()
          reached.updates = (reached.updates or 0) + 1
          return true, nil
        end

        return reached
      end)()
    """)


def test_the_panel_shows_the_location(plugin, panel):
    photo = plugin.new_photo(raw={"gps": {"latitude": 47.6062, "longitude": -122.3321}})
    values = plugin.call(panel.valuesFor, photo, 1)[0]

    assert values["location"] == "47.60620, -122.33210"
    assert values["hasLocation"] is True


def test_the_panel_shows_a_missing_location_as_missing(plugin, panel):
    values = plugin.call(panel.valuesFor, plugin.new_photo(), 1)[0]

    assert "casual" in values["location"].lower()
    assert values["hasLocation"] is False


def test_the_location_row_is_in_the_window(plugin, panel):
    """A location the user cannot see is one they cannot notice is missing."""
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)

    labels = [v["title"] for v in of_type(args["contents"], "static_text")
              if isinstance(v["title"], str)]

    assert "Location:" in labels


def test_the_map_button_switches_to_the_map_module(plugin, panel):
    """The only way this plugin can offer a location: Lightroom's own Map
    module, which has the map, the search and the pin we cannot draw."""
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)
    buttons = {b["title"]: b for b in of_type(args["contents"], "push_button")
               if isinstance(b["title"], str)}

    plugin.call(buttons["Set on Map"]["action"])
    plugin.run_pending_tasks()

    assert plugin.module_switches == ["map"]


def test_uploading_without_a_location_asks_first(plugin, panel):
    """Almost nothing without coordinates ever leaves casual grade, and once it
    is uploaded the panel has no way to say so."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([plugin.new_photo()])
    # The harness answers Cancel unless told otherwise.

    plugin.call(panel.uploadOrUpdate, plugin.runtime.table_from({}))
    plugin.run_pending_tasks()

    assert reached["count"] == 0
    assert "casual" in plugin.dialogs[-1]["message"].lower()


def test_uploading_without_a_location_proceeds_when_confirmed(plugin, panel):
    """It is a warning, not a veto. Plenty of observations are worth having
    without a location, and refusing would just send people elsewhere."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([plugin.new_photo()])
    plugin.set_confirm_answer("ok")

    plugin.call(panel.uploadOrUpdate, plugin.runtime.table_from({}))
    plugin.run_pending_tasks()

    assert reached["count"] == 1


def test_uploading_a_located_photo_asks_nothing(plugin, panel):
    reached = stub_upload_path(plugin)
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})
    plugin.set_target_photos([photo])
    # Left on Cancel: if it asked, the upload would not happen.

    plugin.call(panel.uploadOrUpdate, plugin.runtime.table_from({}))
    plugin.run_pending_tasks()

    assert reached["count"] == 1


def test_updating_an_existing_observation_asks_nothing(plugin, panel):
    """The update sends an identification, not coordinates, so warning about a
    location it could not set either way is a dialog with no answer behind it."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="123")])

    plugin.call(panel.uploadOrUpdate, plugin.runtime.table_from({}))
    plugin.run_pending_tasks()

    assert reached["count"] == 0, "an update must not go through upload"
    assert reached["updates"] == 1, "it should have updated the identification"
    assert not any("casual" in d["message"].lower() for d in plugin.dialogs)


# ---------------------------------------------------------------------------
# Location accuracy
# ---------------------------------------------------------------------------


def test_the_panel_offers_an_accuracy_control(plugin, panel):
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)

    labels = [v["title"] for v in of_type(args["contents"], "static_text")
              if isinstance(v["title"], str)]

    assert "Accuracy:" in labels
    assert of_type(args["contents"], "popup_menu"), "expected a popup for it"


def test_the_panel_carries_the_stored_accuracy(plugin, panel):
    photo = plugin.new_photo(inat_positional_accuracy="36")
    values = plugin.call(panel.valuesFor, photo, 1)[0]

    assert values["accuracy"] == "36"
    offered = values["accuracyItems"]
    assert "36" in [offered[i]["value"] for i in range(1, len(offered) + 1)]


def test_uploading_records_the_chosen_accuracy_on_the_photo(plugin, panel):
    """The upload builds its observation from what the photo says, not from
    what the panel is showing, so a choice never written down is never sent."""
    stub_upload_path(plugin)
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})
    plugin.set_target_photos([photo])

    props = plugin.runtime.table_from({"accuracy": "100"})
    plugin.call(panel.uploadOrUpdate, props)
    plugin.run_pending_tasks()

    assert photo["_props"]["inat_positional_accuracy"] == "100"


def test_updating_pushes_a_changed_accuracy_to_inaturalist(plugin, panel):
    """Upload reads the accuracy off the photo; the update path posts an
    identification, which says nothing about location. Without its own step the
    panel would accept a change iNaturalist never hears about."""
    photo = plugin.new_photo(inat_observation_id="4242")
    plugin.set_target_photos([photo])

    props = plugin.runtime.table_from({"accuracy": "100"})
    reached = stub_upload_path(plugin)
    plugin.call(panel.uploadOrUpdate, props)
    plugin.run_pending_tasks()

    assert reached["accuracy"] == 100


# ---------------------------------------------------------------------------
# Filing a name, and looking one up
# ---------------------------------------------------------------------------


def button_titles(args):
    return [b["title"] for b in of_type(args["contents"], "push_button")
            if isinstance(b["title"], str)]


def test_the_panel_offers_both_new_buttons(plugin, panel):
    plugin.set_target_photos([plugin.new_photo()])

    titles = button_titles(show(plugin, panel))

    assert "Sync guess to Metadata tags" in titles
    assert "View guess on iNaturalist" in titles


def test_both_new_buttons_wait_for_a_chosen_suggestion(plugin, panel):
    """Neither means anything without a taxon: one would have nothing to apply
    and the other nowhere to go. Enabled buttons that do nothing are how users
    learn to distrust a panel."""
    plugin.set_target_photos([plugin.new_photo()])
    args = show(plugin, panel)

    for title in ("Sync guess to Metadata tags", "View guess on iNaturalist"):
        button = [b for b in of_type(args["contents"], "push_button")
                  if b["title"] == title][0]
        assert button["enabled"]["__bind"] == "hasSuggestion", title


def test_choosing_a_suggestion_enables_them(plugin, panel):
    props = plugin.runtime.table_from({})
    props["suggestions"] = deep(plugin, [
        {"taxon_id": 103486, "name": "Ischnura erratica", "rank": "species",
         "combined_score": 91},
    ])

    plugin.call(panel.chooseSuggestion, props, 1)

    assert props["hasSuggestion"] is True
    assert props["suggestionTaxonId"] == 103486


def test_choosing_nothing_disables_them_again(plugin, panel):
    """A stale enabled button would apply the taxon the user just deselected."""
    props = plugin.runtime.table_from({})
    props["suggestions"] = deep(plugin, [])
    props["hasSuggestion"] = True

    plugin.call(panel.chooseSuggestion, props, 99)

    assert props["hasSuggestion"] is False


def test_the_chosen_rank_and_score_are_remembered(plugin, panel):
    """Read at the moment of choosing, because Get Suggestions replaces the
    list wholesale and the index would then point at a different taxon."""
    props = plugin.runtime.table_from({})
    props["suggestions"] = deep(plugin, [
        {"taxon_id": 1, "name": "X", "rank": "species", "combined_score": 40},
    ])

    plugin.call(panel.chooseSuggestion, props, 1)

    assert props["suggestionRank"] == "species"
    assert props["suggestionScore"] == 40


# ---------------------------------------------------------------------------
# Arguing before a weak species claim
# ---------------------------------------------------------------------------


def choose_weak_species(plugin):
    props = plugin.runtime.table_from({})
    props["speciesGuess"] = "Ischnura erratica"
    props["suggestionTaxonId"] = 103486
    props["suggestionRank"] = "species"
    props["suggestionScore"] = 40
    return props


def test_a_weak_species_upload_asks_first(plugin, panel):
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([
        plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})])
    plugin.set_confirm_answer("cancel")

    plugin.call(panel.uploadOrUpdate, choose_weak_species(plugin))
    plugin.run_pending_tasks()

    assert reached["count"] == 0, "cancelling must not upload"


def test_a_weak_species_update_asks_too(plugin, panel):
    """An existing observation is not a safer place to put a wrong species --
    it is a published one. The location warning is upload-only for a real
    reason; this one is not."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="4242")])
    plugin.set_confirm_answer("cancel")

    plugin.call(panel.uploadOrUpdate, choose_weak_species(plugin))
    plugin.run_pending_tasks()

    assert reached["updates"] == 0


def test_confirming_a_weak_species_goes_ahead(plugin, panel):
    """It is a warning, not a veto. Plenty of weak identifications are worth
    making and the community will correct them."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([
        plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})])
    plugin.set_confirm_answer("ok")

    plugin.call(panel.uploadOrUpdate, choose_weak_species(plugin))
    plugin.run_pending_tasks()

    assert reached["count"] == 1


def test_a_confident_species_upload_asks_nothing(plugin, panel):
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([
        plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})])
    plugin.set_confirm_answer("cancel")

    props = choose_weak_species(plugin)
    props["suggestionScore"] = 98

    plugin.call(panel.uploadOrUpdate, props)
    plugin.run_pending_tasks()

    assert reached["count"] == 1, "a confident guess must not be interrogated"


def test_a_coarser_rank_upload_asks_nothing(plugin, panel):
    """Choosing the genus is the careful answer. Warning about it would punish
    the behaviour the fallback list exists to encourage."""
    reached = stub_upload_path(plugin)
    plugin.set_target_photos([
        plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})])
    plugin.set_confirm_answer("cancel")

    props = choose_weak_species(plugin)
    props["suggestionRank"] = "genus"

    plugin.call(panel.uploadOrUpdate, props)
    plugin.run_pending_tasks()

    assert reached["count"] == 1
