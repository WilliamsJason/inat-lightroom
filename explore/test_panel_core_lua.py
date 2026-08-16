"""Tests for PanelCore.lua -- what the floating panel's buttons actually do.

Three behaviours here are the reason this module exists at all, and each was
wrong at some point in a way Lightroom could not show:

  * a species guess is not a determination. iNaturalist ignores species_guess
    once an observation has a taxon, so a guess that was faithfully saved,
    faithfully uploaded and silently discarded looked exactly like success.
  * suggestions for a photo that is already on iNaturalist need no render, no
    temporary file and no upload -- and asking the wrong way costs a full
    export of a raw file every time somebody presses the button.
  * every path that changes an observation has to sync it back, or the taxonomy
    keywords -- the whole point of the plugin -- quietly stop matching the
    website.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def core(plugin):
    return plugin.require("PanelCore")


def deep(plugin, value):
    """Convert nested Python containers into Lua tables.

    table_from only converts the outermost level, so a nested dict arrives in
    Lua as userdata and fails at the first ipairs. Every fixture here is nested.
    """
    if isinstance(value, dict):
        return plugin.runtime.table_from(
            {k: deep(plugin, v) for k, v in value.items()})
    if isinstance(value, list):
        return plugin.runtime.table_from(
            {i + 1: deep(plugin, v) for i, v in enumerate(value)})
    return value


def settings(plugin, **overrides):
    values = {
        "inat_geoprivacy": "open",
        "inat_upload_location": True,
        "inat_project_id": "",
        "inat_sync_after_upload": True,
    }
    values.update(overrides)
    return plugin.runtime.table_from(values)


def rows(plugin, *entries):
    table = {}
    for i, entry in enumerate(entries, start=1):
        table[i] = plugin.runtime.table_from(entry)
    return plugin.runtime.table_from(table)


def fake_api(plugin, **options):
    """An InatAPI stand-in recording every call, with per-call outcomes.

    Returns (api, calls). ``calls`` is a Lua list of {method, arg} tables.
    """
    builder = plugin.eval(
        """
        function(opts)
          local calls = {}
          local function record(method, arg)
            calls[#calls + 1] = { method = method, arg = arg }
          end

          local api = {}

          function api:findObservationByUuid(uuid)
            record("find", uuid)
            return opts.found, nil
          end

          function api:createObservation(params)
            record("create", params)
            if opts.createError then return nil, opts.createError end
            return opts.created or { id = 4242, uuid = "made-up-uuid" }, nil
          end

          function api:updateObservation(id, params, ignorePhotos)
            record("update", { id = id, params = params, ignorePhotos = ignorePhotos })
            if opts.updateError then return nil, opts.updateError end
            return { id = id }, nil
          end

          local uploads = 0
          function api:uploadPhotoVerified(id, path, options)
            uploads = uploads + 1
            record("upload", { id = id, path = path })
            if opts.uploadError then return nil, opts.uploadError end
            if opts.uploadFailAfter and uploads > opts.uploadFailAfter then
              return nil, "photo " .. uploads .. " would not attach"
            end
            return { id = 7 }, nil
          end

          function api:addIdentification(id, taxonId)
            record("identify", { id = id, taxon_id = taxonId })
            if opts.identifyError then return nil, opts.identifyError end
            return { id = 9 }, nil
          end

          function api:addToProject(id, projectId)
            record("project", { id = id, project_id = projectId })
            if opts.projectError then return nil, opts.projectError end
            return {}, nil
          end

          function api:scoreObservation(id)
            record("scoreObservation", id)
            if opts.scoreError then return nil, opts.scoreError end
            return opts.score or { results = {} }, nil
          end

          function api:scoreImage(path, lat, lng, observedOn)
            record("scoreImage",
              { path = path, lat = lat, lng = lng, observed_on = observedOn })
            if opts.scoreError then return nil, opts.scoreError end
            return opts.score or { results = {} }, nil
          end

          -- SyncCore reaches for these after every change.
          function api:getObservation(id)
            record("getObservation", id)
            if opts.observation == nil then
              return nil, "no such observation"
            end
            return opts.observation, nil
          end

          function api:getTaxon(id)
            record("getTaxon", id)
            return opts.taxon, nil
          end

          return api, calls
        end
        """
    )
    return builder(plugin.runtime.table_from(options))


def methods(calls) -> list[str]:
    return [calls[i]["method"] for i in range(1, len(calls) + 1)]


def call_named(calls, name):
    return [calls[i]["arg"] for i in range(1, len(calls) + 1)
            if calls[i]["method"] == name]


def strings(lua_list) -> list[str]:
    return [lua_list[i] for i in range(1, len(lua_list) + 1)]


# ---------------------------------------------------------------------------
# Describing a suggestion
# ---------------------------------------------------------------------------


def test_a_suggestion_shows_both_names_and_a_score(plugin, core):
    """The common name is what people choose between; the scientific name is
    what gets uploaded. Hiding either makes the list impossible to check."""
    row = plugin.runtime.table_from({
        "name": "Apis mellifera",
        "common_name": "Western Honey Bee",
        "combined_score": 87.4,
    })

    assert core["describeSuggestion"](row) == \
        "Western Honey Bee (Apis mellifera) - 87%"


def test_a_suggestion_with_no_common_name_still_reads_properly(plugin, core):
    """Most taxa above species have no common name. Showing "() " around an
    empty string would be the visible symptom."""
    row = plugin.runtime.table_from({"name": "Apoidea", "combined_score": 12})

    assert core["describeSuggestion"](row) == "Apoidea - 12%"


def test_a_suggestion_with_no_score_omits_the_percentage(plugin, core):
    """score_observation does not always carry combined_score, and "- nil%" or
    "- 0%" would both be lies."""
    row = plugin.runtime.table_from({"name": "Apoidea"})

    assert core["describeSuggestion"](row) == "Apoidea"


def test_a_nameless_suggestion_does_not_produce_a_blank_row(plugin, core):
    """A blank row in a list is selectable and says nothing about what it does."""
    row = plugin.runtime.table_from({"combined_score": 3})

    assert core["describeSuggestion"](row).startswith("Unnamed taxon")


# ---------------------------------------------------------------------------
# Turning suggestions into list items
# ---------------------------------------------------------------------------


def test_items_carry_the_row_position_as_their_value(plugin, core):
    """Not the taxon id: a malformed result comes back with a taxon that has no
    id, and a list with nil or colliding values selects the wrong row rather
    than failing."""
    items = core["suggestionItems"](rows(plugin,
        {"name": "Apis mellifera"},
        {"name": "Bombus terrestris"},
    ))

    assert items[1]["value"] == 1
    assert items[2]["value"] == 2


def test_items_are_capped(plugin, core):
    """iNaturalist returns a long tail of noise, and a list that needs scrolling
    is harder to use than a short one."""
    many = rows(plugin, *[{"name": f"Taxon {i}"} for i in range(20)])

    items = core["suggestionItems"](many)

    assert len(list(items.values())) == core["SUGGESTION_LIMIT"]


def test_no_suggestions_makes_no_items(plugin, core):
    assert len(list(core["suggestionItems"](None).values())) == 0


# ---------------------------------------------------------------------------
# Asking for suggestions
# ---------------------------------------------------------------------------


def test_an_uploaded_photo_is_scored_without_rendering(plugin, core):
    """score_observation is a plain GET against something iNaturalist already
    holds. Rendering a raw file to ask it would be a full export per click."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin)

    core["getSuggestions"](api, photo)

    assert methods(calls) == ["scoreObservation"]
    assert len(plugin.export_sessions) == 0


def test_an_unlinked_photo_is_rendered_and_scored(plugin, core):
    photo = plugin.new_photo()
    api, calls = fake_api(plugin)

    core["getSuggestions"](api, photo)

    assert methods(calls) == ["scoreImage"]
    assert len(plugin.export_sessions) == 1


def test_scoring_an_image_sends_location_and_date(plugin, core):
    """Sent properly these collapse the candidate list, because a species from
    the wrong hemisphere stops being plausible. iNaturalist returns 200 and
    ignores them if they go in the query string instead."""
    photo = plugin.new_photo(
        raw={"gps": {"latitude": 47.6, "longitude": -122.3},
             "dateTimeOriginal": 801234567})
    api, calls = fake_api(plugin)

    core["getSuggestions"](api, photo)

    arg = call_named(calls, "scoreImage")[0]
    assert arg["lat"] == 47.6
    assert arg["lng"] == -122.3
    assert arg["observed_on"] == "2026-05-23"


def test_scoring_cleans_up_the_rendered_file(plugin, core):
    """The render goes into a directory this plugin made. Nobody else will ever
    delete it."""
    api, _ = fake_api(plugin)

    core["getSuggestions"](api, plugin.new_photo())

    assert len(plugin.deleted_paths) == 1


def test_a_failed_render_reports_rather_than_scoring_nothing(plugin, core):
    plugin.set_render_failure("the disk is full")
    api, calls = fake_api(plugin)

    result, err = core["getSuggestions"](api, plugin.new_photo())

    assert result is None
    assert "disk is full" in err
    assert methods(calls) == []


def test_suggestions_are_flattened_into_rows(plugin, core):
    api, _ = fake_api(plugin, score=plugin.runtime.table_from({
        "results": plugin.runtime.table_from({
            1: plugin.runtime.table_from({
                "combined_score": 91,
                "taxon": plugin.runtime.table_from(
                    {"id": 47219, "name": "Apis mellifera"}),
            }),
        }),
    }))

    result, _ = core["getSuggestions"](api, plugin.new_photo())

    assert result[1]["taxon_id"] == 47219
    assert result[1]["combined_score"] == 91


def test_asking_with_no_photo_says_so(plugin, core):
    api, _ = fake_api(plugin)

    result, err = core["getSuggestions"](api, None)

    assert result is None
    assert err


# ---------------------------------------------------------------------------
# Uploading
# ---------------------------------------------------------------------------


def upload(plugin, core, photos, api, **overrides):
    return core["upload"](plugin.catalog, api, settings(plugin, **overrides),
                          plugin.runtime.table_from(
                              {i + 1: p for i, p in enumerate(photos)}))


def test_the_whole_selection_becomes_one_observation(plugin, core):
    """The thing the publish service could not do. Six frames of one animal are
    one sighting, and iNaturalist wants them on one observation."""
    photos = [plugin.new_photo(), plugin.new_photo(), plugin.new_photo()]
    api, calls = fake_api(plugin)

    obs_id, url, errors = upload(plugin, core, photos, api)

    assert obs_id == 4242
    assert methods(calls).count("create") == 1
    assert methods(calls).count("upload") == 3


def test_every_photo_in_the_group_records_the_link(plugin, core):
    """So the panel shows the right thing whichever of them is selected next,
    and so a second upload finds the observation instead of duplicating it."""
    photos = [plugin.new_photo(), plugin.new_photo()]
    api, _ = fake_api(plugin)

    upload(plugin, core, photos, api)

    for photo in photos:
        assert photo["_props"]["inat_observation_id"] == "4242"
        assert photo["_props"]["inat_observation_uuid"] == "made-up-uuid"


def test_the_observation_details_come_from_the_first_photo(plugin, core):
    """One sighting however many frames were taken of it."""
    first = plugin.new_photo(inat_species_guess="Apis mellifera")
    api, calls = fake_api(plugin)

    upload(plugin, core, [first, plugin.new_photo()], api)

    assert call_named(calls, "create")[0]["species_guess"] == "Apis mellifera"


def test_the_rendered_files_are_cleaned_up(plugin, core):
    api, _ = fake_api(plugin)

    upload(plugin, core, [plugin.new_photo()], api)

    assert len(plugin.deleted_paths) == 1


def test_a_failed_upload_does_not_record_an_empty_observation(plugin, core):
    """The observation exists but has no photo in it. Recording the link would
    make the panel report success and stop offering to upload."""
    photo = plugin.new_photo()
    api, _ = fake_api(plugin, uploadError="the connection dropped")

    obs_id, _, errors = upload(plugin, core, [photo], api)

    assert obs_id is None
    assert photo["_props"]["inat_observation_id"] is None
    assert any("no photo" in e for e in strings(errors))


def test_one_failed_photo_out_of_several_still_records_the_link(plugin, core):
    """Losing the link because the third frame failed would orphan the two that
    worked, and the next upload would make a duplicate observation rather than
    finding the one already sitting there."""
    photos = [plugin.new_photo(), plugin.new_photo(), plugin.new_photo()]
    api, _ = fake_api(plugin, uploadFailAfter=2)

    obs_id, _, errors = upload(plugin, core, photos, api)

    assert obs_id == 4242
    for photo in photos:
        assert photo["_props"]["inat_observation_id"] == "4242"
    assert any("would not attach" in e for e in strings(errors)), (
        "the photo that failed has to be reported, or the user never finds out "
        "the observation is short an image"
    )


def test_nothing_selected_is_refused(plugin, core):
    """And refused by name. Falling through to the renderer produces "the render
    failed", which sends somebody looking for a problem with their photo."""
    api, calls = fake_api(plugin)

    obs_id, _, errors = upload(plugin, core, [], api)

    assert obs_id is None
    assert methods(calls) == []
    assert len(plugin.export_sessions) == 0
    assert "Select" in strings(errors)[0]


def test_a_render_that_produces_nothing_never_creates_an_observation(plugin, core):
    """An observation with no photo is rubbish on a public dataset, and it is
    the user who has to go and delete it."""
    plugin.set_render_failure("no renditions")
    api, calls = fake_api(plugin)

    obs_id, _, _ = upload(plugin, core, [plugin.new_photo()], api)

    assert obs_id is None
    assert "create" not in methods(calls)


def test_the_project_is_only_used_when_one_is_configured(plugin, core):
    api, calls = fake_api(plugin)

    upload(plugin, core, [plugin.new_photo()], api)

    assert "project" not in methods(calls)


def test_a_configured_project_gets_the_observation(plugin, core):
    api, calls = fake_api(plugin)

    upload(plugin, core, [plugin.new_photo()], api, inat_project_id="12345")

    assert call_named(calls, "project")[0]["project_id"] == "12345"


def test_a_project_failure_does_not_fail_the_upload(plugin, core):
    """The photo is on iNaturalist. Reporting the whole thing as a failure would
    invite a second upload of something that already worked."""
    api, _ = fake_api(plugin, projectError="not a member of that project")

    obs_id, _, errors = upload(plugin, core, [plugin.new_photo()], api,
                               inat_project_id="12345")

    assert obs_id == 4242
    assert any("project" in e for e in strings(errors))


# ---------------------------------------------------------------------------
# Syncing back -- the reason the plugin exists
# ---------------------------------------------------------------------------


OBSERVATION = {
    "id": 4242,
    "uuid": "made-up-uuid",
    "quality_grade": "research",
    "community_taxon": {
        "id": 47219,
        "name": "Apis mellifera",
        "preferred_common_name": "Western Honey Bee",
        "ancestors": {},
    },
}


def test_uploading_writes_the_taxonomy_keywords(plugin, core):
    """The keywords are the whole point. An upload that left the catalog knowing
    only an observation ID meant they appeared whenever somebody happened to
    press Sync, which is to say sometimes."""
    photo = plugin.new_photo()
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    upload(plugin, core, [photo], api)

    assert "getObservation" in methods(calls)
    assert photo["_props"]["inat_taxon_name"] == "Apis mellifera"
    assert any(k["name"] == "Apis mellifera" for k in plugin.keywords)


def test_the_sync_after_upload_can_be_turned_off(plugin, core):
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    upload(plugin, core, [plugin.new_photo()], api,
           inat_sync_after_upload=False)

    assert "getObservation" not in methods(calls)


def test_a_sync_that_fails_does_not_undo_the_upload(plugin, core):
    """By the time it runs the photo is on iNaturalist. Reporting failure would
    invite a second upload of something that already worked."""
    photo = plugin.new_photo()
    api, _ = fake_api(plugin)  # getObservation returns nil

    obs_id, _, errors = upload(plugin, core, [photo], api)

    assert obs_id == 4242
    assert photo["_props"]["inat_observation_id"] == "4242"
    assert len(strings(errors)) > 0


# ---------------------------------------------------------------------------
# Changing the determination
# ---------------------------------------------------------------------------


def update(plugin, core, photos, api, guess, taxon_id=None):
    return core["updateSpeciesGuess"](
        plugin.catalog, api,
        plugin.runtime.table_from({i + 1: p for i, p in enumerate(photos)}),
        guess, taxon_id)


def test_a_known_taxon_is_posted_as_an_identification(plugin, core):
    """species_guess is free text iNaturalist shows only while an observation
    has no taxon. Sending a chosen suggestion that way is why an edited guess
    appeared to vanish."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    ok, _ = update(plugin, core, [photo], api, "Apis mellifera", 47219)

    assert ok
    assert call_named(calls, "identify")[0]["taxon_id"] == 47219
    assert "update" not in methods(calls)


def test_free_text_is_only_used_when_there_is_no_taxon(plugin, core):
    """Somebody typed something we could not resolve. It is worth sending, but
    it is not an identification and must not pretend to be one."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    update(plugin, core, [photo], api, "some kind of bee")

    assert "identify" not in methods(calls)
    assert call_named(calls, "update")[0]["params"]["species_guess"] == \
        "some kind of bee"


def test_updating_never_touches_the_photos_on_the_observation(plugin, core):
    """A PUT to /observations replaces the observation wholesale. Without
    ignore_photos it detaches every image on it."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    update(plugin, core, [photo], api, "some kind of bee")

    assert call_named(calls, "update")[0]["ignorePhotos"] is True


def test_the_guess_is_written_to_every_selected_photo(plugin, core):
    """The panel shows the first photo but the buttons act on the selection: one
    name across the six frames of the same animal is the common case."""
    photos = [plugin.new_photo(inat_observation_id="4242"), plugin.new_photo()]
    api, _ = fake_api(plugin,
                      observation=deep(plugin, OBSERVATION))

    update(plugin, core, photos, api, "Apis mellifera", 47219)

    for photo in photos:
        assert photo["_props"]["inat_species_guess"] == "Apis mellifera"


def test_a_guess_is_never_written_into_the_synced_taxon_field(plugin, core):
    """inat_taxon_id means "what iNaturalist currently says this is". Putting a
    guess in it would make the Metadata panel claim a determination nobody --
    including us -- has actually made."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, _ = fake_api(plugin)

    update(plugin, core, [photo], api, "Apis mellifera", 47219)

    assert photo["_props"]["inat_taxon_id"] is None


def test_an_unlinked_photo_cannot_have_its_identification_changed(plugin, core):
    """There is nothing to identify yet. Saying so is better than a 404."""
    api, calls = fake_api(plugin)

    ok, err = update(plugin, core, [plugin.new_photo()], api, "Apis", 47219)

    assert ok is False
    assert "uploaded" in err
    assert methods(calls) == []


def test_a_rejected_identification_reports_the_reason(plugin, core):
    photo = plugin.new_photo(inat_observation_id="4242")
    api, _ = fake_api(plugin, identifyError="that taxon is inactive")

    ok, err = update(plugin, core, [photo], api, "Apis", 47219)

    assert ok is False
    assert "inactive" in err


def test_changing_the_identification_syncs_the_keywords_back(plugin, core):
    """The community taxon may now be something other than what was posted, and
    the keywords have to follow the website rather than the guess."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin,
                          observation=deep(plugin, OBSERVATION))

    update(plugin, core, [photo], api, "Apis mellifera", 47219)

    assert "getObservation" in methods(calls)
    assert photo["_props"]["inat_taxon_name"] == "Apis mellifera"


def test_updating_with_nothing_selected_is_refused(plugin, core):
    api, calls = fake_api(plugin)

    ok, _ = update(plugin, core, [], api, "Apis", 47219)

    assert ok is False
    assert methods(calls) == []


# ---------------------------------------------------------------------------
# Unlinking
# ---------------------------------------------------------------------------


def test_unlinking_clears_the_link_but_keeps_the_keywords(plugin, core):
    """By the time somebody unlinks, the keywords are part of their catalog --
    used in smart collections and exports. Taking them away is a bigger and less
    reversible act than the button appears to offer."""
    photo = plugin.new_photo(inat_observation_id="4242",
                             inat_taxon_name="Apis mellifera")
    api, _ = fake_api(plugin, observation=deep(plugin, OBSERVATION))

    # Give it a keyword the honest way first, so there is something to lose.
    core["syncBack"](plugin.catalog, api, plugin.runtime.table_from({1: photo}),
                     plugin.runtime.table_from({}))
    before = len(list(photo["keywords"].values()))
    assert before == 1, "the sync should have applied a keyword to lose"

    count = core["unlink"](plugin.catalog,
                           plugin.runtime.table_from({1: photo}))

    assert count == 1
    assert photo["_props"]["inat_observation_id"] == ""
    assert photo["_props"]["inat_taxon_name"] == ""
    assert len(list(photo["keywords"].values())) == before


# ---------------------------------------------------------------------------
# Location
# ---------------------------------------------------------------------------


def test_a_located_photo_shows_its_coordinates(plugin, core):
    photo = plugin.new_photo(raw={"gps": {"latitude": 47.6062, "longitude": -122.3321}})

    assert core["describeLocation"](photo) == "47.60620, -122.33210"


def test_a_photo_with_no_location_says_what_that_costs(plugin, core):
    """"None" on its own reads like an empty field. It is not: it is the
    difference between an observation that counts and one that does not, and the
    panel is the only place the user will ever be told."""
    described = core["describeLocation"](plugin.new_photo())

    assert described == core["NO_LOCATION"]
    assert "casual" in described.lower()


def test_no_photo_shows_no_location_claim(plugin, core):
    """With nothing selected there is no photo to be missing a location, so
    saying one is missing would be a warning about nothing."""
    assert core["describeLocation"](None) == ""


def test_uploading_a_photo_with_no_location_is_questioned(plugin, core):
    warning = core["locationWarning"](settings(plugin),
                                      plugin.runtime.table_from({1: plugin.new_photo()}))

    assert warning is not None
    assert "casual" in warning.lower()
    assert "map" in warning.lower(), "it must say where to go and fix it"


def test_uploading_a_located_photo_is_not_questioned(plugin, core):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    assert core["locationWarning"](settings(plugin),
                                   plugin.runtime.table_from({1: photo})) is None


def test_nothing_is_said_when_the_user_has_turned_location_off(plugin, core):
    """They switched it off on purpose. A warning that fires when it should not
    is one people learn to click through, and we would lose the times it is
    right."""
    warning = core["locationWarning"](
        settings(plugin, inat_upload_location=False),
        plugin.runtime.table_from({1: plugin.new_photo()}))

    assert warning is None


def test_nothing_is_said_when_nothing_is_selected(plugin, core):
    assert core["locationWarning"](settings(plugin),
                                   plugin.runtime.table_from({})) is None


def test_the_warning_judges_the_photo_the_observation_comes_from(plugin, core):
    """A multi-photo selection becomes one observation, and its details come off
    the first photo. Deciding on any other photo would warn about a location
    that is not the one being uploaded."""
    located = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})
    bare = plugin.new_photo()

    first_located = core["locationWarning"](
        settings(plugin), plugin.runtime.table_from({1: located, 2: bare}))
    first_bare = core["locationWarning"](
        settings(plugin), plugin.runtime.table_from({1: bare, 2: located}))

    assert first_located is None
    assert first_bare is not None


# ---------------------------------------------------------------------------
# How precise the location claims to be
# ---------------------------------------------------------------------------


def items(core, stored=None):
    got = core["accuracyItems"](stored)
    return [(got[i]["value"], got[i]["title"]) for i in range(1, len(got) + 1)]


def test_an_unset_accuracy_is_the_empty_string(core):
    assert core["accuracyValue"](None) == ""
    assert core["accuracyValue"]("") == ""


def test_a_number_becomes_whole_metres(core):
    """iNaturalist rejects a fractional positional_accuracy, and a float would
    never match a preset's string in the popup either."""
    assert core["accuracyValue"](36) == "36"
    assert core["accuracyValue"]("36.4") == "36"
    assert core["accuracyValue"](36.6) == "37"


def test_nonsense_accuracy_is_treated_as_unset(core):
    """Better an unstated accuracy than a claimed one that means nothing."""
    assert core["accuracyValue"]("about a mile") == ""
    assert core["accuracyValue"](0) == ""
    assert core["accuracyValue"](-5) == ""


def test_the_presets_offer_a_way_to_say_nothing(core):
    """Leaving it unsaid is a real answer. Without a listed choice for it the
    popup would open on a value the user never picked."""
    assert items(core)[0][0] == ""


def test_no_preset_claims_a_perfect_coordinate(core):
    """A coordinate is never exact. Offering to claim zero uncertainty would be
    offering to lie on the user's behalf."""
    values = [v for v, _ in items(core) if v != ""]
    assert values and all(int(v) > 0 for v in values)


def test_a_stored_preset_is_not_duplicated(core):
    values = [v for v, _ in items(core, "100")]
    assert values.count("100") == 1


def test_a_synced_accuracy_gets_an_item_of_its_own(core):
    """A popup whose value matches no item renders blank, which would read as
    "not specified" for an observation that has an accuracy -- and touching the
    popup would then overwrite it. iNaturalist's real numbers are almost never
    one of our four."""
    entries = items(core, "36")
    assert "36" in [v for v, _ in entries]
    assert any("36" in title for v, title in entries if v == "36")


def test_the_odd_item_is_last_so_the_presets_keep_their_order(core):
    assert items(core, "36")[-1][0] == "36"


def test_recording_an_accuracy_writes_it_to_every_photo(plugin, core):
    photos = [plugin.new_photo(), plugin.new_photo()]
    core["recordAccuracy"](plugin.catalog,
                           plugin.runtime.table_from({1: photos[0], 2: photos[1]}),
                           "100")

    assert [p["_props"]["inat_positional_accuracy"] for p in photos] == ["100", "100"]


def test_recording_happens_inside_a_write_transaction(plugin, core):
    photo = plugin.new_photo()
    core["recordAccuracy"](plugin.catalog,
                           plugin.runtime.table_from({1: photo}), "10")

    assert plugin.catalog_writes


def test_updating_accuracy_pushes_it_to_an_existing_observation(plugin, core):
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin)

    ok, err = core["updateAccuracy"](plugin.catalog, api,
                                     plugin.runtime.table_from({1: photo}), "100")

    assert ok and err is None
    sent = call_named(calls, "update")[0]
    assert sent["params"]["positional_accuracy"] == 100


def test_updating_accuracy_keeps_the_photos_attached(plugin, core):
    """A PUT without ignore_photos detaches every photo on the observation and
    still returns 200."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin)

    core["updateAccuracy"](plugin.catalog, api,
                           plugin.runtime.table_from({1: photo}), "100")

    assert call_named(calls, "update")[0]["ignorePhotos"] is True


def test_an_unset_accuracy_sends_no_update(plugin, core):
    """Sending nothing is not the same as sending "no accuracy". Turning an
    unanswered question into a PUT would overwrite whatever iNaturalist knows."""
    photo = plugin.new_photo(inat_observation_id="4242")
    api, calls = fake_api(plugin)

    ok, _ = core["updateAccuracy"](plugin.catalog, api,
                                   plugin.runtime.table_from({1: photo}), "")

    assert ok
    assert methods(calls) == []


def test_an_unlinked_photo_needs_no_accuracy_update(plugin, core):
    """It has no observation yet; the upload will carry the accuracy itself."""
    api, calls = fake_api(plugin)

    ok, _ = core["updateAccuracy"](plugin.catalog, api,
                                   plugin.runtime.table_from({1: plugin.new_photo()}),
                                   "100")

    assert ok
    assert methods(calls) == []


# ---------------------------------------------------------------------------
# Coming in at a rank you can defend
# ---------------------------------------------------------------------------


def ancestor(plugin, rank="genus", name="Ischnura", ancestors=None):
    """A common ancestor with its lineage, as /taxa/{id} returns it."""
    return deep(plugin, {
        "id": 52054,
        "name": name,
        "rank": rank,
        "preferred_common_name": "Forktails",
        "ancestors": ancestors if ancestors is not None else [
            {"id": 1, "name": "Animalia", "rank": "kingdom"},
            {"id": 47158, "name": "Insecta", "rank": "class"},
            {"id": 47792, "name": "Odonata", "rank": "order"},
            {"id": 47208, "name": "Zygoptera", "rank": "suborder"},
            {"id": 47209, "name": "Coenagrionidae", "rank": "family"},
        ],
    })


def ranks_of(rows):
    return [rows[i]["rank"] for i in range(1, len(rows) + 1)]


def test_a_confident_list_is_offered_no_fallback(plugin, core):
    """Offering an escape hatch beside a 98% answer would make every
    identification look like a guess."""
    assert len(core["fallbackRows"](ancestor(plugin), 98)) == 0


def test_an_unconfident_list_gets_coarser_options(plugin, core):
    assert ranks_of(core["fallbackRows"](ancestor(plugin), 40)) == [
        "genus", "family", "order"]


def test_the_most_specific_safe_option_comes_first(plugin, core):
    """It is the one most people want: the finest rank still defensible. Put
    the order first and the useful answer is the one nobody reads."""
    assert ranks_of(core["fallbackRows"](ancestor(plugin), 40))[0] == "genus"


def test_the_ladder_never_goes_below_the_common_ancestor(plugin, core):
    """The whole justification for these rows is that every candidate agrees at
    or above the common ancestor. A genus taken from the top result's lineage
    would assume that result is right -- exactly what a 40% score doubts."""
    family = ancestor(plugin, rank="family", name="Coenagrionidae", ancestors=[
        {"id": 1, "name": "Animalia", "rank": "kingdom"},
        {"id": 47158, "name": "Insecta", "rank": "class"},
        {"id": 47792, "name": "Odonata", "rank": "order"},
    ])

    rows = core["fallbackRows"](family, 40)

    assert "genus" not in ranks_of(rows)
    assert ranks_of(rows) == ["family", "order"]


def test_intermediate_ranks_are_left_out(plugin, core):
    """Suborder and superfamily are real ranks and useless as choices. A list
    with all of them is a taxonomy lesson, not a decision."""
    assert "suborder" not in ranks_of(core["fallbackRows"](ancestor(plugin), 40))


def test_a_fallback_row_says_why_it_is_there(plugin, core):
    rows = core["fallbackRows"](ancestor(plugin), 40)

    assert rows[1]["note"] and "agreed" in rows[1]["note"]


def test_a_fallback_row_carries_no_invented_score(plugin, core):
    """These are not candidates the model ranked. A percentage beside one would
    be a number nobody computed."""
    rows = core["fallbackRows"](ancestor(plugin), 40)

    assert rows[1]["combined_score"] is None
    assert "%" not in core["describeSuggestion"](rows[1])


def test_no_common_ancestor_means_no_fallback(plugin, core):
    """The model had no confident shared ancestor, so there is nothing honest
    to offer."""
    assert len(core["fallbackRows"](None, 40)) == 0


def test_an_empty_list_still_gets_the_fallback(plugin, core):
    """No score at all is the least confident case there is, not the most."""
    assert len(core["fallbackRows"](ancestor(plugin), None)) == 3


def test_the_fallbacks_go_above_the_species(plugin, core):
    api, _ = fake_api(plugin, taxon=ancestor(plugin))
    rows = deep(plugin, [{"taxon_id": 1, "name": "Ischnura erratica",
                          "rank": "species", "combined_score": 40}])

    combined = core["withFallbacks"](api, rows, ancestor(plugin))

    assert ranks_of(combined) == ["genus", "family", "order", "species"]


def test_a_confident_list_is_passed_straight_through(plugin, core):
    api, calls = fake_api(plugin, taxon=ancestor(plugin))
    rows = deep(plugin, [{"taxon_id": 1, "name": "Ischnura erratica",
                          "rank": "species", "combined_score": 98}])

    combined = core["withFallbacks"](api, rows, ancestor(plugin))

    assert ranks_of(combined) == ["species"]
    assert "getTaxon" not in methods(calls), "no lineage is worth fetching here"


# ---------------------------------------------------------------------------
# Arguing before a weak species claim
# ---------------------------------------------------------------------------


def test_a_weak_species_claim_is_argued_with(core):
    warning = core["confidenceWarning"](
        {"rank": "species", "combined_score": 40, "name": "Ischnura erratica"})

    assert warning and "40%" in warning
    assert "Ischnura erratica" in warning


def test_a_confident_species_claim_is_not(core):
    assert core["confidenceWarning"](
        {"rank": "species", "combined_score": 98, "name": "X"}) is None


def test_a_weak_genus_claim_is_not_argued_with(core):
    """Coming in at genus when the photo will not support more is what an
    expert does. Warning about it would punish the careful answer."""
    assert core["confidenceWarning"](
        {"rank": "genus", "combined_score": 40, "name": "Ischnura"}) is None


def test_a_subspecies_counts_as_a_species_claim(core):
    assert core["confidenceWarning"](
        {"rank": "subspecies", "combined_score": 40, "name": "X"}) is not None


def test_a_row_with_no_score_is_not_argued_with(plugin, core):
    """A fallback rank or a hand-typed name. There is no evidence to call weak,
    and a warning here would fire on every manual identification."""
    row = deep(plugin, {"rank": "species", "name": "X"})

    assert core["confidenceWarning"](row) is None


def test_the_warning_says_what_to_do_instead(core):
    """A warning that only says "are you sure?" gets clicked through. This one
    has to name the alternative, because the alternative is the whole point."""
    warning = core["confidenceWarning"](
        {"rank": "species", "combined_score": 40, "name": "X"})

    assert "genus" in warning


# ---------------------------------------------------------------------------
# Filing a name without publishing it
# ---------------------------------------------------------------------------


def species_taxon(plugin):
    return deep(plugin, {
        "id": 103486,
        "name": "Ischnura erratica",
        "rank": "species",
        "preferred_common_name": "Swift Forktail",
        "ancestors": [
            {"id": 1, "name": "Animalia", "rank": "kingdom"},
            {"id": 47158, "name": "Insecta", "rank": "class"},
            {"id": 52054, "name": "Ischnura", "rank": "genus"},
        ],
    })


def test_a_taxon_url_is_built_from_the_id(core):
    assert core["taxonUrl"](103486) == "https://www.inaturalist.org/taxa/103486"
    assert core["taxonUrl"]("103486") == "https://www.inaturalist.org/taxa/103486"


def test_a_taxon_url_is_not_invented_without_an_id(core):
    """A URL built from nil opens the taxa index, which looks like the button
    worked and answers a question nobody asked."""
    assert core["taxonUrl"](None) is None
    assert core["taxonUrl"]("") is None
    assert core["taxonUrl"]("not-a-number") is None


def test_a_taxon_id_is_not_written_in_scientific_notation(core):
    """tostring on a Lua number gives 1.03486e+08 past a certain size, which is
    a URL that 404s."""
    assert "e+" not in core["taxonUrl"](103486)


def test_applying_locally_writes_the_keyword_hierarchy(plugin, core):
    photo = plugin.new_photo()
    api, _ = fake_api(plugin, taxon=species_taxon(plugin))

    ok, err = core["applyGuessLocally"](plugin.catalog, api,
                                        plugin.runtime.table_from({1: photo}),
                                        103486)

    assert ok and err is None
    names = [k["name"] for k in plugin.keywords]
    assert names == ["iNaturalist", "Animalia", "Insecta", "Ischnura",
                     "Ischnura erratica"]


def test_applying_locally_fills_in_the_taxon_fields(plugin, core):
    photo = plugin.new_photo()
    api, _ = fake_api(plugin, taxon=species_taxon(plugin))

    core["applyGuessLocally"](plugin.catalog, api,
                              plugin.runtime.table_from({1: photo}), 103486)

    assert photo["_props"]["inat_taxon_name"] == "Ischnura erratica"
    assert photo["_props"]["inat_common_name"] == "Swift Forktail"
    assert photo["_props"]["inat_species_guess"] == "Ischnura erratica"


def test_applying_locally_creates_no_observation_link(plugin, core):
    """The photo is not on iNaturalist. An observation id here would make the
    panel offer Sync and View for something that does not exist."""
    photo = plugin.new_photo()
    api, calls = fake_api(plugin, taxon=species_taxon(plugin))

    core["applyGuessLocally"](plugin.catalog, api,
                              plugin.runtime.table_from({1: photo}), 103486)

    assert photo["_props"]["inat_observation_id"] is None
    assert methods(calls) == ["getTaxon"], "nothing else may be called"


def test_applying_locally_covers_the_whole_selection(plugin, core):
    photos = [plugin.new_photo(), plugin.new_photo()]
    api, _ = fake_api(plugin, taxon=species_taxon(plugin))

    core["applyGuessLocally"](plugin.catalog, api,
                              plugin.runtime.table_from({1: photos[0], 2: photos[1]}),
                              103486)

    assert all(p["_props"]["inat_taxon_name"] == "Ischnura erratica"
               for p in photos)


def test_applying_locally_needs_a_chosen_suggestion(plugin, core):
    """Without one there is no taxon to apply, and the alternative is writing
    the free-text guess as though it were a taxon."""
    api, calls = fake_api(plugin, taxon=species_taxon(plugin))

    ok, err = core["applyGuessLocally"](plugin.catalog, api,
                                        plugin.runtime.table_from({1: plugin.new_photo()}),
                                        None)

    assert not ok and "suggestion" in err
    assert methods(calls) == []


def test_applying_locally_needs_a_photo(plugin, core):
    api, _ = fake_api(plugin, taxon=species_taxon(plugin))

    ok, err = core["applyGuessLocally"](plugin.catalog, api,
                                        plugin.runtime.table_from({}), 103486)

    assert not ok and err


def test_a_failed_taxon_fetch_writes_nothing(plugin, core):
    """Half-applying a taxonomy is worse than not applying it: the keywords
    would disagree with the fields."""
    photo = plugin.new_photo()
    api, _ = fake_api(plugin, taxon=None)

    ok, err = core["applyGuessLocally"](plugin.catalog, api,
                                        plugin.runtime.table_from({1: photo}),
                                        103486)

    assert not ok and err
    assert photo["_props"]["inat_taxon_name"] is None
    assert list(plugin.keywords) == []
