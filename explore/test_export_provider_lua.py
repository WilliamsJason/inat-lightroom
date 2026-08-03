"""Tests for ExportServiceProvider.lua, under Lightroom's Lua 5.1.

This file started as a regression test for one crash:

    attempt to index local 'firstRendition' (a number value)

renditions() is a Lua iterator, and calling it directly returns the values it
yields, which begin with the loop index -- so the code took a number and tried
to read .photo off it. It only surfaced at upload time, after the user had
already filled in the whole export panel.

That function is gone: it existed to find "the photo" for an export batch, and
a publish service has no batch. What replaced it is per-photo, and the tests
here cover the two things that are easy to get wrong in that model -- reading
observation data off the right photo, and deciding whether several photos share
one observation or get one each.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def provider(plugin):
    return plugin.require("ExportServiceProvider")


@pytest.fixture
def internal(provider):
    return provider["_internal"]


def settings(plugin, **overrides):
    """A publish connection's settings table."""
    values = {
        "inat_geoprivacy": "open",
        "inat_default_taxon_id": "",
        "inat_upload_location": True,
    }
    values.update(overrides)
    return plugin.runtime.table_from(values)


def fake_api(plugin, *, created=None, found=None, upload=None, upload_error=None):
    """An InatAPI stand-in that records every call made against it.

    Returns (api, calls); ``calls`` is a Lua list of {method, arg} tables.
    """
    builder = plugin.eval(
        """
        function(created, found, upload, uploadError)
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

          function api:uploadPhotoVerified(observationId, _path, _options)
            record("upload", observationId)
            if uploadError then return nil, uploadError end
            return upload, nil
          end

          function api:deleteObservationPhoto(id)
            record("deletePhoto", id)
            return {}, nil
          end

          function api:deleteObservation(id)
            record("deleteObservation", id)
            return {}, nil
          end

          function api:countAttachedPhotos(id)
            record("count", id)
            return 1, nil
          end

          return api, calls
        end
        """
    )
    return builder(created, found, upload, upload_error)


def methods(calls) -> list[str]:
    return [calls[i]["method"] for i in range(1, len(calls) + 1)]


def lua_values(table) -> list:
    return [table[i] for i in range(1, len(table) + 1)]


# ---------------------------------------------------------------------------
# The observation date
# ---------------------------------------------------------------------------


def test_capture_date_is_read_through_lrdate(plugin, internal):
    """Lightroom counts seconds from 2001, so os.date would be 31 years out."""
    photo = plugin.new_photo(raw={"dateTimeOriginal": 801234567})

    # The stubbed LrDate formats any timestamp to this; os.date would not.
    assert internal["observedOnFor"](photo) == "2026-07-29"


def test_no_date_when_the_photo_has_no_capture_time(plugin, internal):
    """Better a missing date than an exception midway through a publish."""
    assert internal["observedOnFor"](plugin.new_photo()) is None


# ---------------------------------------------------------------------------
# Building the observation
# ---------------------------------------------------------------------------


def test_species_guess_comes_from_the_photo(plugin, internal):
    """The whole point of the publish conversion: per-photo, not per-batch."""
    photo = plugin.new_photo(inat_species_guess="Quercus robur")

    params = internal["observationParamsFor"](settings(plugin), photo)

    assert params["species_guess"] == "Quercus robur"


def test_an_empty_species_guess_is_not_sent(plugin, internal):
    """An empty string is what an untouched field holds, not a species."""
    photo = plugin.new_photo(inat_species_guess="")

    params = internal["observationParamsFor"](settings(plugin), photo)

    assert params["species_guess"] is None


def test_the_connections_default_taxon_is_used(plugin, internal):
    photo = plugin.new_photo()

    params = internal["observationParamsFor"](
        settings(plugin, inat_default_taxon_id="12345"), photo
    )

    assert params["taxon_id"] == 12345


def test_the_caption_becomes_the_description(plugin, internal):
    photo = plugin.new_photo(formatted={"caption": "On a fence post"})

    params = internal["observationParamsFor"](settings(plugin), photo)

    assert params["description"] == "On a fence post"


def test_gps_is_uploaded_when_the_setting_is_on(plugin, internal):
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    params = internal["observationParamsFor"](settings(plugin), photo)

    assert params["latitude"] == 51.5
    assert params["longitude"] == -0.1


def test_gps_is_withheld_when_the_setting_is_off(plugin, internal):
    """Publishing someone's location against their setting is not recoverable."""
    photo = plugin.new_photo(raw={"gps": {"latitude": 51.5, "longitude": -0.1}})

    params = internal["observationParamsFor"](
        settings(plugin, inat_upload_location=False), photo
    )

    assert params["latitude"] is None
    assert params["longitude"] is None


# ---------------------------------------------------------------------------
# Which observation a photo belongs to
# ---------------------------------------------------------------------------


def test_a_photo_with_no_uuid_gets_a_new_observation(plugin, internal):
    api, calls = fake_api(
        plugin, created=plugin.runtime.table_from({"id": 42, "uuid": "abc"})
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = internal["resolveObservation"](
        api, settings(plugin), plugin.new_photo(), seen
    )

    assert (obs_id, uuid, err) == (42, "abc", None)
    assert methods(calls) == ["create"]
    assert seen["abc"] == 42


def test_photos_sharing_a_uuid_publish_into_one_observation(plugin, internal):
    """The behaviour the export batch used to provide, now carried on photos.

    Without this a three-frame observation becomes three observations of one
    photo each, which is the thing iNaturalist reviewers ask people not to do
    and which cannot be undone from Lightroom.
    """
    api, calls = fake_api(
        plugin, created=plugin.runtime.table_from({"id": 7, "uuid": "shared"})
    )
    seen = plugin.eval("{}")
    config = settings(plugin)

    first_id, _, _ = internal["resolveObservation"](
        api, config, plugin.new_photo(inat_observation_uuid="shared"), seen
    )
    second_id, _, _ = internal["resolveObservation"](
        api, config, plugin.new_photo(inat_observation_uuid="shared"), seen
    )

    assert first_id == second_id == 7
    # One create for the pair, and no second trip to the server to look it up.
    assert methods(calls) == ["find", "create"]


def test_a_previously_published_photo_reuses_its_observation(plugin, internal):
    """A re-publish must not create a second observation for the same photo."""
    api, calls = fake_api(
        plugin, found=plugin.runtime.table_from({"id": 99, "uuid": "known"})
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = internal["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="known"), seen
    )

    assert (obs_id, uuid, err) == (99, "known", None)
    assert methods(calls) == ["find"]


def test_an_observation_deleted_on_the_website_is_recreated(plugin, internal):
    """Not an error state. Someone tidying up on inaturalist.org is normal, and
    the photo should publish again rather than fail forever."""
    api, calls = fake_api(
        plugin,
        found=None,
        created=plugin.runtime.table_from({"id": 5, "uuid": "orphan"}),
    )
    seen = plugin.eval("{}")

    obs_id, uuid, err = internal["resolveObservation"](
        api, settings(plugin), plugin.new_photo(inat_observation_uuid="orphan"), seen
    )

    assert (obs_id, uuid, err) == (5, "orphan", None)
    assert methods(calls) == ["find", "create"]

    # Recreated under the same UUID, so photos grouped with it stay grouped.
    assert calls[2]["arg"]["uuid"] == "orphan"


def test_a_failed_create_reports_the_reason(plugin, internal):
    api, _ = fake_api(plugin, created=None)
    seen = plugin.eval("{}")

    obs_id, _, err = internal["resolveObservation"](
        api, settings(plugin), plugin.new_photo(), seen
    )

    assert obs_id is None
    assert "the server said no" in err


# ---------------------------------------------------------------------------
# Publishing one photo
# ---------------------------------------------------------------------------


def rendition(plugin, photo, *, published_photo_id=None):
    """A stub LrExportRendition that records what was published against it."""
    builder = plugin.eval(
        """
        function(photo, previousId)
          local r = { photo = photo, publishedPhotoId = previousId, recorded = {} }
          function r:recordPublishedPhotoId(id) self.recorded.id = id end
          function r:recordPublishedPhotoUrl(url) self.recorded.url = url end
          function r:uploadFailed(message) self.recorded.failed = message end
          return r
        end
        """
    )
    return builder(photo, published_photo_id)


def test_publishing_records_the_photo_and_its_observation(plugin, internal):
    api, _ = fake_api(
        plugin,
        created=plugin.runtime.table_from({"id": 42, "uuid": "abc"}),
        upload=plugin.runtime.table_from({"id": 555}),
    )
    rend = rendition(plugin, plugin.new_photo())

    ok, err = internal["publishRendition"](
        api, settings(plugin), plugin.catalog, rend, "C:\\tmp\\a.jpg",
        plugin.eval("{}"), 1,
    )

    assert (ok, err) == (True, None)
    assert rend["recorded"]["id"] == "555"
    assert rend["recorded"]["url"] == "https://www.inaturalist.org/observations/42"


def test_publishing_stores_the_uuid_on_the_photo(plugin, internal):
    """Without this the photo has no way back to its observation, and the next
    publish creates a duplicate."""
    api, _ = fake_api(
        plugin,
        created=plugin.runtime.table_from({"id": 42, "uuid": "abc"}),
        upload=plugin.runtime.table_from({"id": 555}),
    )
    photo = plugin.new_photo()

    internal["publishRendition"](
        api, settings(plugin), plugin.catalog, rendition(plugin, photo),
        "C:\\tmp\\a.jpg", plugin.eval("{}"), 1,
    )

    assert photo["_props"]["inat_observation_uuid"] == "abc"
    assert photo["_props"]["inat_observation_id"] == "42"


def test_publishing_writes_through_the_private_catalog_transaction(plugin, internal):
    """Inside an export task the ordinary catalog write can block on a
    transaction the export itself holds; withPrivateWriteAccessDo is the one
    that does not."""
    api, _ = fake_api(
        plugin,
        created=plugin.runtime.table_from({"id": 42, "uuid": "abc"}),
        upload=plugin.runtime.table_from({"id": 555}),
    )

    internal["publishRendition"](
        api, settings(plugin), plugin.catalog,
        rendition(plugin, plugin.new_photo()), "C:\\tmp\\a.jpg",
        plugin.eval("{}"), 1,
    )

    assert plugin.catalog_writes == ["<private>"]


def test_republishing_removes_the_copy_it_replaced(plugin, internal):
    """A re-publish uploads a fresh render; leaving the old one attached puts
    two versions of the same frame on the observation."""
    api, calls = fake_api(
        plugin,
        found=plugin.runtime.table_from({"id": 42, "uuid": "abc"}),
        upload=plugin.runtime.table_from({"id": 777}),
    )
    photo = plugin.new_photo(inat_observation_uuid="abc")
    rend = rendition(plugin, photo, published_photo_id="555")

    internal["publishRendition"](
        api, settings(plugin), plugin.catalog, rend, "C:\\tmp\\a.jpg",
        plugin.eval("{}"), 1,
    )

    # The old copy goes only after the new one is verified, never before.
    assert methods(calls) == ["find", "upload", "deletePhoto"]
    assert calls[3]["arg"] == "555"


def test_a_failed_upload_is_not_recorded_as_published(plugin, internal):
    """Recording it would mark the photo Published in Lightroom even though
    nothing reached iNaturalist, and no later publish would retry it."""
    api, _ = fake_api(
        plugin,
        created=plugin.runtime.table_from({"id": 42, "uuid": "abc"}),
        upload_error="iNaturalist accepted the upload but the photo never attached",
    )
    rend = rendition(plugin, plugin.new_photo())

    ok, err = internal["publishRendition"](
        api, settings(plugin), plugin.catalog, rend, "C:\\tmp\\a.jpg",
        plugin.eval("{}"), 1,
    )

    assert ok is False
    assert "never attached" in err
    assert rend["recorded"]["id"] is None


# ---------------------------------------------------------------------------
# Removing photos again
# ---------------------------------------------------------------------------


def test_published_photos_are_mapped_back_to_their_observations(plugin, internal):
    """Lightroom hands over remote photo IDs and nothing else, but whether an
    observation should be deleted depends on how many of its photos are going."""
    plugin.set_published_collection(
        7,
        [
            {"remoteId": "111", "photo": plugin.new_photo(inat_observation_id="42")},
            {"remoteId": "222", "photo": plugin.new_photo(inat_observation_id="42")},
            {"remoteId": "333", "photo": plugin.new_photo(inat_observation_id="99")},
        ],
    )

    mapped = internal["observationsForPublishedPhotoIds"](
        plugin.catalog, 7, plugin.eval("{'111', '222'}")
    )

    assert sorted(lua_values(mapped["42"])) == ["111", "222"]
    # The third photo was not being deleted, so its observation is not at risk.
    assert mapped["99"] is None


def test_an_unknown_collection_maps_to_nothing(plugin, internal):
    """Better to detach the photos and leave the observations alone than to
    throw halfway through a delete."""
    mapped = internal["observationsForPublishedPhotoIds"](
        plugin.catalog, 404, plugin.eval("{'111'}")
    )

    assert len(mapped) == 0


# ---------------------------------------------------------------------------
# The publish service contract
# ---------------------------------------------------------------------------


def test_the_service_is_publish_only(provider):
    """An export that forgot the observation link would create duplicates on
    every run, so there is no useful plain-export mode to offer."""
    assert provider["supportsIncrementalPublish"] == "only"


def test_there_is_exactly_one_collection_and_it_cannot_be_removed(provider):
    """iNaturalist has no album concept to mirror, so extra collections would
    exist only in Lightroom while claiming to be published somewhere."""
    info = provider["getCollectionBehaviorInfo"](None)

    assert info["defaultCollectionName"] == "Observations"
    assert info["canAddCollection"] is False
    assert info["defaultCollectionCanBeDeleted"] is False


def test_republish_is_triggered_by_specific_fields_only(provider):
    """Without default = false every catalog field triggers a republish and the
    whole collection sits permanently in Modified."""
    triggers = provider["metadataThatTriggersRepublish"](None)

    assert triggers["default"] is False
    assert triggers["caption"] is True
    assert triggers["com.github.inat-lightroom.inat_species_guess"] is True


def test_publishing_cannot_send_a_file_larger_than_inaturalist_accepts(provider):
    """iNaturalist displays at most 2048px on the long edge; anything bigger is
    bandwidth spent on both sides for an image nobody will ever see."""
    export_settings = {}
    provider["updateExportSettings"](export_settings)

    assert export_settings["LR_format"] == "JPEG"
    assert export_settings["LR_size_maxWidth"] == 2048
    assert export_settings["LR_size_resizeType"] == "longEdge"
