"""Tests for UploadCore.lua -- creating observations and linking photos to them.

Most of this is inherited from test_export_provider_lua.py, which covered the
same logic while it lived in the publish service. The publish service is gone;
the logic is not, and neither is the reason each of these tests exists. Every
one of them is here because the behaviour it pins down was got wrong at least
once and the symptom was invisible from Lightroom.

Dropped rather than ported:

  * the connection's default taxon. It was a per-connection fallback for photos
    that said nothing about themselves, and there is no connection any more.
    The trap it guarded -- that iNaturalist prefers taxon_id and silently
    discards species_guess when both are sent -- has not gone away; it moves to
    the identification logic, and is tested there.
  * everything about renditions and published photo IDs, which only a publish
    service has.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def upload(plugin):
    return plugin.require("UploadCore")


def settings(plugin, **overrides):
    values = {
        "inat_geoprivacy": "open",
        "inat_upload_location": True,
    }
    values.update(overrides)
    return plugin.runtime.table_from(values)


def fake_api(plugin, *, created=None, found=None, update_error=None):
    """An InatAPI stand-in that records every call made against it.

    Returns (api, calls); ``calls`` is a Lua list of {method, arg} tables.
    """
    builder = plugin.eval(
        """
        function(created, found, updateError)
          local calls = {}
          local function record(method, arg)
            calls[#calls + 1] = { method = method, arg = arg }
          end

          local api = {}

          function api:findObservationByUuid(uuid)
            record("find", uuid)
            return found, nil
          end

          function api:createObservation(params)
            record("create", params)
            if created == nil then
              return nil, "the server said no"
            end
            return created, nil
          end

          function api:updateObservation(id, params, ignorePhotos)
            record("update", { id = id, params = params, ignorePhotos = ignorePhotos })
            if updateError then return nil, updateError end
            return { id = id }, nil
          end

          return api, calls
        end
        """
    )
    return builder(created, found, update_error)


def methods(calls) -> list[str]:
    return [calls[i]["method"] for i in range(1, len(calls) + 1)]


# ---------------------------------------------------------------------------
# The observation date
# ---------------------------------------------------------------------------


def test_capture_date_is_read_through_lrdate(plugin, upload):
    """Lightroom counts seconds from 2001, so os.date would be 31 years out."""
    photo = plugin.new_photo(raw={"dateTimeOriginal": 801234567})

    assert upload["observedOnFor"](photo) == "2026-07-29"


def test_no_date_when_the_photo_has_no_capture_time(plugin, upload):
    """Better a missing date than an exception midway through an upload."""
    assert upload["observedOnFor"](plugin.new_photo()) is None


# ---------------------------------------------------------------------------
# Building the observation
# ---------------------------------------------------------------------------


def test_species_guess_comes_from_the_photo(plugin, upload):
    photo = plugin.new_photo(inat_species_guess="Quercus robur")

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["species_guess"] == "Quercus robur"


def test_an_empty_species_guess_is_not_sent(plugin, upload):
    """An empty string is what an untouched field holds, not a species."""
    photo = plugin.new_photo(inat_species_guess="")

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["species_guess"] is None


def test_the_caption_becomes_the_description(plugin, upload):
    photo = plugin.new_photo(formatted={"caption": "On a fence post"})

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["description"] == "On a fence post"


def test_gps_is_uploaded_when_the_setting_is_on(plugin, upload):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["latitude"] == 51.5
    assert params["longitude"] == -0.1


def test_gps_is_withheld_when_the_setting_is_off(plugin, upload):
    """Uploading someone's location against their setting is not recoverable."""
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    params = upload["observationParamsFor"](
        settings(plugin, inat_upload_location=False), photo
    )

    assert params["latitude"] is None
    assert params["longitude"] is None


def test_locationof_reads_the_coordinates(plugin, upload):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    latitude, longitude = upload["locationOf"](photo)

    assert latitude == 51.5
    assert longitude == -0.1


def test_locationof_reports_nothing_when_there_is_no_gps(plugin, upload):
    latitude, longitude = upload["locationOf"](plugin.new_photo())

    assert latitude is None
    assert longitude is None


def test_locationof_treats_a_half_written_location_as_absent(plugin, upload):
    """Lightroom hands back a gps table for a photo carrying only one of the
    pair. Sending a latitude with no longitude puts the observation somewhere it
    has never been, which is worse than sending no location at all."""
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5}})

    latitude, longitude = upload["locationOf"](photo)

    assert latitude is None
    assert longitude is None


def test_geoprivacy_defaults_to_open_when_nothing_is_configured(plugin, upload):
    """A nil geoprivacy reaching the API is a 422 whose message says nothing."""
    params = upload["observationParamsFor"](plugin.eval("{}"), plugin.new_photo())

    assert params["geoprivacy"] == "open"


# ---------------------------------------------------------------------------
# Which observation a photo belongs to
# ---------------------------------------------------------------------------


def test_a_photo_with_no_uuid_gets_a_new_observation(plugin, upload):
    api, calls = fake_api(
        plugin, created=plugin.runtime.table_from({"id": 42, "uuid": "abc"})
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(), seen
    )

    assert (obs_id, uuid, err) == (42, "abc", None)
    assert methods(calls) == ["create"]
    assert seen["abc"] == 42


def test_photos_sharing_a_uuid_go_into_one_observation(plugin, upload):
    """Without this a three-frame observation becomes three observations of one
    photo each, which is the thing iNaturalist reviewers ask people not to do
    and which cannot be undone from Lightroom."""
    api, calls = fake_api(
        plugin, created=plugin.runtime.table_from({"id": 7, "uuid": "shared"})
    )
    seen = plugin.eval("{}")
    config = settings(plugin)

    first_id, _, _ = upload["resolveObservation"](
        api, config, plugin.new_photo(inat_observation_uuid="shared"), seen
    )
    second_id, _, _ = upload["resolveObservation"](
        api, config, plugin.new_photo(inat_observation_uuid="shared"), seen
    )

    assert first_id == second_id == 7
    # One create for the pair, and no second trip to the server to look it up.
    assert methods(calls) == ["find", "create"]


def test_a_previously_uploaded_photo_reuses_its_observation(plugin, upload):
    """A second upload must not create a second observation for the same photo."""
    api, calls = fake_api(
        plugin, found=plugin.runtime.table_from({"id": 99, "uuid": "known"})
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="known"), seen
    )

    assert (obs_id, uuid, err) == (99, "known", None)
    assert methods(calls) == ["find", "update"]


def test_re_uploading_pushes_the_photos_current_details(plugin, upload):
    """Reusing the observation and sending nothing threw away the only change
    the user made -- and iNaturalist showed no species."""
    api, calls = fake_api(
        plugin, found=plugin.runtime.table_from({"id": 99, "uuid": "known"})
    )

    upload["resolveObservation"](
        api,
        settings(plugin),
        plugin.new_photo(
            inat_observation_uuid="known", inat_species_guess="Apis mellifera"
        ),
        plugin.eval("{}"),
    )

    update = calls[2]["arg"]
    assert update["id"] == 99
    assert update["params"]["species_guess"] == "Apis mellifera"


def test_an_update_never_turns_off_ignore_photos(plugin, upload):
    """A PUT without ignore_photos detaches EVERY photo from the observation
    and still returns 200, leaving it at casual grade with no evidence. The
    API defaults the flag on; passing false explicitly is the way to lose it."""
    api, calls = fake_api(
        plugin, found=plugin.runtime.table_from({"id": 99, "uuid": "known"})
    )

    upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="known"),
        plugin.eval("{}")
    )

    assert calls[2]["arg"]["ignorePhotos"] is not False


def test_a_failed_update_warns_but_still_returns_the_observation(plugin, upload):
    """The image reaching iNaturalist matters more than the caption following
    it, but silently dropping what the user typed has to be said out loud."""
    api, _ = fake_api(
        plugin,
        found=plugin.runtime.table_from({"id": 99, "uuid": "known"}),
        update_error="422 Unprocessable Entity",
    )
    warnings = plugin.eval("{}")

    obs_id, _, err = upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="known"),
        plugin.eval("{}"), warnings
    )

    assert (obs_id, err) == (99, None)
    assert "422" in warnings[1]


def test_an_observation_deleted_on_the_website_is_recreated(plugin, upload):
    """Not an error state. Someone tidying up on inaturalist.org is normal, and
    the photo should upload again rather than fail forever."""
    api, calls = fake_api(
        plugin,
        found=None,
        created=plugin.runtime.table_from({"id": 5, "uuid": "orphan"}),
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="orphan"), seen
    )

    assert (obs_id, uuid, err) == (5, "orphan", None)
    assert methods(calls) == ["find", "create"]

    # Recreated under the same UUID, so photos grouped with it stay grouped.
    assert calls[2]["arg"]["uuid"] == "orphan"


def test_a_failed_create_reports_the_reason(plugin, upload):
    api, _ = fake_api(plugin, created=None)

    obs_id, _, err = upload["resolveObservation"](
        api, settings(plugin), plugin.new_photo(), plugin.eval("{}")
    )

    assert obs_id is None
    assert "the server said no" in err


# ---------------------------------------------------------------------------
# Recording the link
# ---------------------------------------------------------------------------


def test_every_photo_in_the_group_gets_the_same_observation(plugin, upload):
    """The panel shows whichever photo is selected. If only the first frame
    carried the link, selecting the second would offer to upload it again."""
    photos = [plugin.new_photo(), plugin.new_photo(), plugin.new_photo()]

    upload["recordObservation"](
        plugin.catalog, plugin.runtime.table_from(photos), 1234, "a-uuid"
    )

    for photo in photos:
        assert photo["_props"]["inat_observation_id"] == "1234"
        assert photo["_props"]["inat_observation_uuid"] == "a-uuid"
        assert (
            photo["_props"]["inat_observation_url"]
            == "https://www.inaturalist.org/observations/1234"
        )


def test_recording_the_link_takes_the_catalog_write_lock(plugin, upload):
    """setPropertyForPlugin outside a write transaction raises, and the error
    surfaces nowhere the user will see it."""
    upload["recordObservation"](
        plugin.catalog, plugin.runtime.table_from([plugin.new_photo()]), 1, "u"
    )

    assert plugin.catalog_writes == ["iNat upload"]


# ---------------------------------------------------------------------------
# Unlinking
# ---------------------------------------------------------------------------


def test_unlinking_clears_every_field_that_points_at_inaturalist(plugin, upload):
    photo = plugin.new_photo(
        inat_observation_id="42",
        inat_observation_uuid="u",
        inat_observation_url="http://example.com",
        inat_quality_grade="research",
        inat_last_synced="2026-01-01",
        inat_taxon_id="7",
        inat_taxon_name="Apis mellifera",
        inat_common_name="Western Honey Bee",
    )

    upload["unlink"](plugin.catalog, plugin.runtime.table_from([photo]))

    for field in [
        "inat_observation_id",
        "inat_observation_uuid",
        "inat_observation_url",
        "inat_quality_grade",
        "inat_last_synced",
        "inat_taxon_id",
        "inat_taxon_name",
        "inat_common_name",
    ]:
        assert photo["_props"][field] == "", field


def test_unlinking_leaves_the_species_guess_alone(plugin, upload):
    """The guess is the user's own typing, not something synced down. Unlinking
    a photo to upload it somewhere else should not empty the field describing
    what it is."""
    photo = plugin.new_photo(
        inat_observation_id="42", inat_species_guess="Apis mellifera"
    )

    upload["unlink"](plugin.catalog, plugin.runtime.table_from([photo]))

    assert photo["_props"]["inat_species_guess"] == "Apis mellifera"


def test_unlinking_nothing_does_not_open_a_transaction(plugin, upload):
    """An empty write transaction still lands in the user's undo stack as
    'iNat unlink', which is a confusing thing to find after doing nothing."""
    assert upload["unlink"](plugin.catalog, plugin.eval("{}")) == 0
    assert plugin.catalog_writes == []


def test_the_accuracy_is_sent_with_the_coordinates(plugin, upload):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}},
                             inat_positional_accuracy="100")

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["positional_accuracy"] == 100


def test_an_accuracy_without_coordinates_is_not_sent(plugin, upload):
    """It would describe the precision of a location that was never sent, which
    a reader of the observation could only guess at."""
    photo = plugin.new_photo(inat_positional_accuracy="100")

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["positional_accuracy"] is None


def test_the_accuracy_is_withheld_with_the_location(plugin, upload):
    """Location off means location off. An accuracy on its own still says
    something about where the photo was taken."""
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}},
                             inat_positional_accuracy="100")

    params = upload["observationParamsFor"](
        settings(plugin, inat_upload_location=False), photo)

    assert params["positional_accuracy"] is None


def test_an_unset_accuracy_sends_no_field(plugin, upload):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["positional_accuracy"] is None


def test_a_nonsense_stored_accuracy_is_not_sent(plugin, upload):
    """iNaturalist answers a non-numeric positional_accuracy with a 422 whose
    message does not name the field."""
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}},
                             inat_positional_accuracy="about a mile")

    params = upload["observationParamsFor"](settings(plugin), photo)

    assert params["positional_accuracy"] is None
