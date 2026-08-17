"""Tests for ReverseSync.lua -- matching observations back onto catalog photos.

The module's whole reason for existing is a performance shape: catalogs run to
millions of photos, observation counts to a few thousand, so it must ask the
catalog a narrow question per observation and never walk the catalog. Most of
what follows checks the correctness that shape makes easy to get wrong --
photos claimed twice, photos that were already linked, an epoch conversion
between two modules that count from different years.

The catalog stubs these lean on were written against a real SDK probe, so
`findPhotos` here honours seconds and matches nothing when handed a date it
cannot read, exactly as Lightroom does.
"""

from __future__ import annotations

import calendar
import json

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin

LR_EPOCH_IN_UNIX = 978307200


def lr_time(text: str) -> int:
    """A Lightroom capture time from a wall-clock string."""
    stamp = calendar.timegm(tuple(
        int(part) for part in
        (text[0:4], text[5:7], text[8:10], text[11:13], text[14:16], text[17:19])
    ) + (0, 0, 0))
    return stamp - LR_EPOCH_IN_UNIX


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def sync(plugin):
    return plugin.require("ReverseSync")


def observation(plugin, obs_id, when, **fields):
    fields.setdefault("id", obs_id)
    fields.setdefault("uuid", "uuid-%s" % obs_id)
    fields["time_observed_at"] = when
    return plugin.runtime.table_from(fields)


def observations(plugin, *items):
    return plugin.runtime.table_from(list(items))


def photo_at(plugin, when, gps=None, path=None, **properties):
    raw = {"dateTimeOriginal": lr_time(when), "path": path or ("/" + when + ".jpg")}
    if gps:
        raw["gps"] = gps
    return plugin.new_photo(raw=raw, **properties)


# ------------------------------------------------------------------- linked

def test_photos_already_linked_are_listed(plugin, sync):
    linked = photo_at(plugin, "2024-05-01T10:00:00", inat_observation_id="123")
    loose = photo_at(plugin, "2024-05-01T11:00:00")
    plugin.set_all_photos([linked, loose])

    found = sync["linkedPhotos"](plugin.catalog)

    assert found[linked] == "123"
    assert found[loose] is None


def test_an_unlinked_photo_is_not_treated_as_linked(plugin, sync):
    """Unlinking empties the field rather than removing it, so the photo still
    comes back from findPhotosWithProperty. Trusting that call without checking
    the value would make every photo ever unlinked permanently unmatchable."""
    photo = photo_at(plugin, "2024-05-01T10:00:00", inat_observation_id="")
    plugin.set_all_photos([photo])

    assert sync["linkedPhotos"](plugin.catalog)[photo] is None


# --------------------------------------------------------------- candidates

def test_a_photo_at_the_observed_second_is_a_candidate(plugin, sync):
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2,
        plugin.runtime.table_from({}))

    assert len(found) == 1
    assert found[1].path == "/2024-05-01T10:00:00.jpg"


def test_the_window_is_seconds_wide_not_a_whole_day(plugin, sync):
    """The search value has to be the format the probe found works. Handed
    LrDate.timeToW3CDate output the real call matches nothing at all, and
    handed a bare date it matches everything taken that day."""
    inside = photo_at(plugin, "2024-05-01T10:00:01")
    outside = photo_at(plugin, "2024-05-01T10:05:00")
    plugin.set_all_photos([inside, outside])

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2,
        plugin.runtime.table_from({}))

    assert [found[i].path for i in range(1, len(found) + 1)] == \
        ["/2024-05-01T10:00:01.jpg"]


def test_an_already_linked_photo_is_not_a_candidate(plugin, sync):
    """Reverse Sync fills gaps. Relinking a photo the user has already placed
    is worse than finding nothing, because nothing is visible and this is not."""
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])
    linked = plugin.runtime.table_from({})
    linked[photo] = "999"

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2, linked)

    assert len(found) == 0


def test_an_observation_without_a_time_has_no_window(plugin, sync):
    """A date-only observation would match every photo taken that day, which is
    a coincidence rather than a match. nil distinguishes it from no candidates."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])

    found = sync["candidatesFor"](plugin.catalog,
        plugin.runtime.table_from({"id": 1, "observed_on": "2024-05-01"}), 2,
        plugin.runtime.table_from({}))

    assert found is None


def test_the_capture_time_survives_the_epoch_conversion(plugin, sync):
    """Lightroom counts from 2001 and MatchCore from 1970. If the conversion
    were dropped the candidate would still be found -- the search is Lightroom's
    -- and then rated against a time thirty-one years out."""
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2,
        plugin.runtime.table_from({}))

    assert found[1].seconds == calendar.timegm((2024, 5, 1, 10, 0, 0, 0, 0, 0))


def test_gps_is_flattened_onto_the_candidate(plugin, sync):
    photo = photo_at(plugin, "2024-05-01T10:00:00",
        gps={"latitude": 47.6, "longitude": -122.3})
    plugin.set_all_photos([photo])

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2,
        plugin.runtime.table_from({}))

    assert found[1].latitude == 47.6
    assert found[1].longitude == -122.3


def test_a_photo_with_no_capture_time_is_dropped(plugin, sync):
    """It cannot be rated, and a candidate whose time is nil would be compared
    against the observation as if it were the epoch."""
    plugin.set_all_photos([plugin.new_photo(raw={"path": "/x.jpg"})])

    found = sync["candidatesFor"](plugin.catalog,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"), 2,
        plugin.runtime.table_from({}))

    assert len(found) == 0


# --------------------------------------------------------------------- scan

def test_scanning_matches_each_observation_to_its_photo(plugin, sync):
    first = photo_at(plugin, "2024-05-01T10:00:00")
    second = photo_at(plugin, "2024-05-02T11:30:00")
    plugin.set_all_photos([first, second])

    matches, summary = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"),
        observation(plugin, 2, "2024-05-02T11:30:00+00:00")))

    assert summary.matched == 2
    assert {matches[1].path, matches[2].path} == \
        {"/2024-05-01T10:00:00.jpg", "/2024-05-02T11:30:00.jpg"}


def test_every_match_starts_selected(plugin, sync):
    """The dialog offers un-ticking, not ticking: the common case is accepting
    the lot, and making the user tick a thousand boxes to get there is not an
    offer anyone takes."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])

    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00")))

    assert matches[1].selected is True


def test_two_observations_wanting_one_photo_both_get_a_row(plugin, sync):
    """Observations made seconds apart both fall inside the same window. Hiding
    the frame from the second one made it report as unmatched, which is a lie --
    which of the two it belongs to is precisely the user's call, so both are
    offered and only the first is ticked."""
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])

    matches, summary = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"),
        observation(plugin, 2, "2024-05-01T10:00:01+00:00")))

    assert summary.matched == 2
    assert summary.unmatched == 0
    assert summary.claimed == 1
    assert [matches[1].selected, matches[2].selected] == [True, False]
    assert matches[2].claimedBy == 1


def test_a_burst_becomes_one_row_per_frame(plugin, sync):
    """An observation is allowed several photos, so four frames of a settled
    insect are four links to make, not three to throw away."""
    plugin.set_all_photos([
        photo_at(plugin, "2024-05-01T10:00:00"),
        photo_at(plugin, "2024-05-01T10:00:01"),
        photo_at(plugin, "2024-05-01T10:00:02"),
    ])

    matches, summary = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00")))

    assert summary.matched == 1
    assert summary.photos == 3
    assert len(matches) == 3
    assert all(matches[row].selected for row in (1, 2, 3))


def test_the_closest_frame_leads_the_group(plugin, sync):
    """Rows are reviewed in order, so the one the matcher believes in most has
    to be the one read first."""
    plugin.set_all_photos([
        photo_at(plugin, "2024-05-01T10:00:02"),
        photo_at(plugin, "2024-05-01T10:00:00"),
    ])

    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00")))

    assert matches[1].secondsApart == 0
    assert matches[1].primary is True
    assert matches[2].primary is False


def test_an_observation_with_no_photo_is_counted_not_dropped(plugin, sync):
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])

    _, summary = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2019-01-01T09:00:00+00:00")))

    assert summary.unmatched == 1
    assert summary.matched == 0


def test_date_only_observations_are_reported_separately(plugin, sync):
    """Distinct from unmatched: nothing is wrong with the catalog, the
    observation simply does not say enough to be matched safely."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])

    _, summary = sync["scan"](plugin.catalog, observations(plugin,
        plugin.runtime.table_from({"id": 1, "observed_on": "2024-05-01"})))

    assert summary.undatable == 1
    assert summary.unmatched == 0


def test_progress_is_reported_per_observation(plugin, sync):
    """Ten thousand observations is long enough that a dialog saying nothing
    looks like a dialog that has hung."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])
    seen = []

    sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"),
        observation(plugin, 2, "2024-05-03T10:00:00+00:00")),
        plugin.runtime.table_from({
            "onProgress": lambda done, total, found: seen.append((done, total)),
        }))

    assert seen == [(1, 2), (2, 2)]


def test_cancelling_stops_the_scan(plugin, sync):
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])

    _, summary = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00"),
        observation(plugin, 2, "2024-05-03T10:00:00+00:00")),
        plugin.runtime.table_from({"shouldStop": lambda: True}))

    assert summary.stopped is True
    assert summary.observations == 2


def test_the_catalog_is_never_walked(plugin, sync):
    """The load-bearing performance property. Reading every photo costs about
    0.7 ms each, so on a million-photo catalog one getAllPhotos call is twelve
    minutes before the first match appears."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])
    plugin.catalog.getAllPhotos = lambda *a: pytest.fail(
        "Reverse Sync walked the catalog")

    sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 1, "2024-05-01T10:00:00+00:00")))


# -------------------------------------------------------------------- apply

def test_applying_links_the_selected_matches(plugin, sync):
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])
    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 7, "2024-05-01T10:00:00+00:00")))

    done, failures = sync["apply"](plugin.catalog, matches)

    assert done == 1
    assert len(failures) == 0
    assert photo._props["inat_observation_id"] == "7"
    assert photo._props["inat_observation_uuid"] == "uuid-7"


def test_unticked_matches_are_left_alone(plugin, sync):
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])
    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observation(plugin, 7, "2024-05-01T10:00:00+00:00")))
    matches[1].selected = False

    done, _ = sync["apply"](plugin.catalog, matches)

    assert done == 0
    assert photo._props["inat_observation_id"] is None


def test_linking_is_batched_rather_than_one_transaction_each(plugin, sync):
    """One block around everything holds the catalog against the user for the
    whole run and loses the lot if it fails at the end; one block per photo
    pays the transaction cost once per photo."""
    photos = [photo_at(plugin, "2024-05-01T10:00:%02d" % second)
              for second in range(0, 10)]
    plugin.set_all_photos(photos)
    matches, _ = sync["scan"](plugin.catalog, observations(plugin, *[
        observation(plugin, index, "2024-05-01T10:00:%02d+00:00" % index)
        for index in range(0, 10)]))
    plugin.catalog_writes.clear()

    sync["apply"](plugin.catalog, matches,
        plugin.runtime.table_from({"batchSize": 4}))

    assert len(plugin.catalog_writes) == 3


# ----------------------------------------------------------- applying taxa

def taxon_api(plugin, fetched=None):
    """An API that answers getTaxon, recording which ids it was asked for."""
    asked = []

    def get_taxon(_self, taxon_id):
        asked.append(taxon_id)
        return plugin.runtime.table_from({
            "id": taxon_id, "name": "Rana temporaria",
            "ancestors": plugin.runtime.table_from([
                plugin.runtime.table_from({"name": "Animalia", "rank": "kingdom"}),
            ]),
        })

    return plugin.runtime.table_from({"getTaxon": get_taxon}), asked


def observed_with_taxon(plugin, obs_id, when, taxon_id=42):
    return observation(plugin, obs_id, when,
        quality_grade="research",
        taxon=plugin.runtime.table_from({"id": taxon_id, "name": "Rana temporaria"}))


def test_linking_also_syncs_the_observation(plugin, sync):
    """A photo left linked but not synced knows an observation id and nothing
    else -- no keywords, no grade -- which looks like the feature half worked."""
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])
    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observed_with_taxon(plugin, 7, "2024-05-01T10:00:00+00:00")))
    api, _ = taxon_api(plugin)

    sync["apply"](plugin.catalog, matches,
        plugin.runtime.table_from({"api": api}))

    assert photo._props["inat_observation_id"] == "7"
    assert photo._props["inat_quality_grade"] == "research"
    assert photo._props["inat_taxon_name"] == "Rana temporaria"


def test_the_observation_is_not_fetched_again(plugin, sync):
    """The whole point of doing this here: the observation came down with the
    list, and asking for it again is one round trip per photo against a limit
    of a hundred requests a minute."""
    plugin.set_all_photos([photo_at(plugin, "2024-05-01T10:00:00")])
    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observed_with_taxon(plugin, 7, "2024-05-01T10:00:00+00:00")))
    api, _ = taxon_api(plugin)
    api.getObservation = lambda *a: pytest.fail(
        "Reverse Sync re-fetched an observation it already had")

    sync["apply"](plugin.catalog, matches, plugin.runtime.table_from({"api": api}))


def test_a_repeated_species_is_only_looked_up_once(plugin, sync):
    """A few thousand observations are usually a few hundred species.

    Driven through a real InatAPI client rather than a stub with a getTaxon
    method, because that is where the caching lives now, and a stub would
    happily pass while the shipping path made a request per photo -- which is
    exactly how a real run got itself rate limited.

    One request covers all four rows: the species are prefetched together, and
    the repeats are answered from the cache that prefetch fills."""
    requested = []

    def handler(_method, url, _body=None, _headers=None):
        requested.append(url)
        return json.dumps({"results": [{"id": 42, "name": "Rana temporaria",
                                        "ancestors": [{"name": "Animalia"}]}]}), \
            plugin.runtime.table_from({"status": 200})

    plugin.set_http_handler(handler)
    api = plugin.require("InatAPI")["new"]("header.payload.signature")

    photos = [photo_at(plugin, "2024-05-01T10:00:%02d" % second)
              for second in range(0, 4)]
    plugin.set_all_photos(photos)
    matches, _ = sync["scan"](plugin.catalog, observations(plugin, *[
        observed_with_taxon(plugin, index, "2024-05-01T10:00:%02d+00:00" % index)
        for index in range(0, 4)]))

    sync["apply"](plugin.catalog, matches, plugin.runtime.table_from({"api": api}))

    assert len([url for url in requested if "/taxa" in url]) == 1


def test_linking_without_an_api_still_links(plugin, sync):
    """The link is the part that must not depend on the network."""
    photo = photo_at(plugin, "2024-05-01T10:00:00")
    plugin.set_all_photos([photo])
    matches, _ = sync["scan"](plugin.catalog, observations(plugin,
        observed_with_taxon(plugin, 7, "2024-05-01T10:00:00+00:00")))

    done, _ = sync["apply"](plugin.catalog, matches)

    assert done == 1
    assert photo._props["inat_observation_id"] == "7"
    assert photo._props["inat_quality_grade"] is None


def test_one_bad_observation_does_not_abandon_the_batch(plugin, sync):
    """Ninety-nine good links should not be lost to the hundredth."""
    photos = [photo_at(plugin, "2024-05-01T10:00:%02d" % second)
              for second in range(0, 3)]
    plugin.set_all_photos(photos)
    matches, _ = sync["scan"](plugin.catalog, observations(plugin, *[
        observed_with_taxon(plugin, index, "2024-05-01T10:00:%02d+00:00" % index)
        for index in range(0, 3)]))
    matches[2].observation = None

    done, failures = sync["apply"](plugin.catalog, matches)

    assert done == 2
    assert len(failures) == 1


def test_a_failure_is_logged_not_only_counted(plugin, sync):
    """Told "1 could not be linked" with nothing in the log, neither the user
    nor anyone helping them has anywhere to go next."""
    photo = plugin.new_photo(path="C:/photos/one.jpg")
    match = plugin.eval("""
      function(photo)
        return {
          selected = true,
          photo    = photo,
          observation = { id = 4242, uuid = "u-4242" },
        }
      end
    """)(photo)

    upload = plugin.require("UploadCore")
    upload.writeObservationFields = plugin.eval(
        'function() error("catalog said no", 0) end')

    linked, failures = sync.apply(
        plugin.catalog, plugin.eval("function(m) return { m } end")(match))

    assert linked == 0
    assert len(list(failures.values())) == 1
    logged = " ".join(plugin.log_lines)
    assert "4242" in logged
    assert "catalog said no" in logged


def test_linking_creates_keywords_without_yielding_inside_a_plain_pcall(
    plugin, sync
):
    """The bug this exists for: apply wrapped each row in Lua's pcall, and
    creating the taxon's keyword path yields. Lua 5.1 cannot yield across a C
    call and pcall is one, so every single link failed with

        Yielding is not allowed within a C or metamethod call

    which names neither pcall nor the call that yielded. The failures were
    caught and counted, so the run reported "0 linked" and read as a matching
    problem rather than a Lua one.
    """
    plugin.set_http_handler(lambda method, url, body, headers: (
        '{"results":[{"id":60053,"name":"Agulla","rank":"genus",'
        '"ancestors":[{"id":1,"name":"Animalia","rank":"kingdom"}]}]}',
        {"status": 200},
    ))

    photo = plugin.new_photo(path="C:/photos/one.jpg")
    match = plugin.eval("""
      function(photo)
        return {
          selected = true,
          photo    = photo,
          observation = {
            id = 15845541, uuid = "u-1",
            quality_grade = "needs_id",
            taxon = { id = 60053, name = "Agulla", rank = "genus" },
          },
        }
      end
    """)(photo)

    api = plugin.require("InatAPI").new("token")
    linked, failures = sync.apply(
        plugin.catalog,
        plugin.eval("function(m) return { m } end")(match),
        plugin.eval("function(api) return { api = api } end")(api))

    assert list(failures.values()) == []
    assert linked == 1
    assert photo._props["inat_observation_id"] == "15845541"
    assert photo._props["inat_taxon_name"] == "Agulla"


# ------------------------------------------- the web uploader drops seconds
#
# The regression that started this: observation 288642140 reads 20:03:00
# because iNaturalist's uploader formatted the EXIF through a moment.js
# pattern with no seconds token. The photo it was made from, DSC00045.ARW,
# was shot at 20:03:41, so a two second window never saw it.


def truncated_observation(plugin, obs_id, when_minute):
    """As the web uploader leaves it: :00 seconds and a string without any."""
    return observation(plugin, obs_id, when_minute + ":00+00:00",
                       observed_on_string="2025/05/30 8:03 PM")


def test_a_photo_later_in_a_truncated_minute_is_still_found(plugin, sync):
    photo = photo_at(plugin, "2025-05-30T20:03:41", path="/DSC00045.ARW")
    plugin.set_all_photos([photo])

    found = sync["candidatesFor"](plugin.catalog,
        truncated_observation(plugin, 1, "2025-05-30T20:03"), 2,
        plugin.runtime.table_from({}))

    assert len(found) == 1
    assert found[1].path == "/DSC00045.ARW"


def test_the_next_minute_is_still_out_of_reach(plugin, sync):
    """Widening to the minute must not quietly become a two minute window."""
    photo = photo_at(plugin, "2025-05-30T20:04:30")
    plugin.set_all_photos([photo])

    found = sync["candidatesFor"](plugin.catalog,
        truncated_observation(plugin, 1, "2025-05-30T20:03"), 2,
        plugin.runtime.table_from({}))

    assert len(found) == 0


def test_every_frame_in_a_truncated_minute_is_offered(plugin, sync):
    """One observation, several plausible frames -- the user picks by eye."""
    early = photo_at(plugin, "2025-05-30T20:03:05", path="/early.ARW")
    late = photo_at(plugin, "2025-05-30T20:03:55", path="/late.ARW")
    plugin.set_all_photos([early, late])

    found = sync["candidatesFor"](plugin.catalog,
        truncated_observation(plugin, 1, "2025-05-30T20:03"), 2,
        plugin.runtime.table_from({}))

    assert sorted(found[i].path for i in range(1, len(found) + 1)) == [
        "/early.ARW", "/late.ARW"]
