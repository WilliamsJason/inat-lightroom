"""Tests for syncing an observation, driven through the plugin's URL handler.

Sync used to be a menu item (`SyncObservation.lua`), then a clickable row in
the Metadata panel. It is now a button in the publish service's settings
dialog, but the lightroom:// URL still reaches it and is the one entry point a
test can drive without a running Lightroom, so that is the door these tests
come in through.

Each test drains the task queue afterwards, which is what Lightroom does once
the handler returns.

The catalog stub enforces the SDK's write-access rule, so a keyword created
outside a transaction fails here rather than in the host.
"""

from __future__ import annotations

import json
import re
import urllib.parse

import pytest

from lua_harness import LuaPlugin, make_jwt

FUTURE = 4_102_444_800  # 2100-01-01, comfortably unexpired


def taxon(name, taxon_id, ancestors=(), common=None):
    return {
        "id": taxon_id,
        "name": name,
        "preferred_common_name": common,
        "ancestors": [
            {"id": i + 1, "name": a} for i, a in enumerate(ancestors)
        ],
    }


def make_plugin(responses):
    """A runtime whose HTTP stub answers from a {url substring: payload} map."""
    plugin = LuaPlugin()
    # Store the token the way the credentials dialog does, rather than poking
    # at storage keys the auth module owns.
    auth = plugin.require("InatAuth")
    plugin.call(auth["storeApiToken"], make_jwt(FUTURE))
    plugin.set_http_handler(observation_handler(plugin, responses))
    return plugin


def observation_handler(plugin, responses, refuse=None):
    """Answer both the single and the batched observation endpoints.

    Tests declare observations one per id, the way the API used to be asked for
    them. The sync now fetches up to 200 at a time, so the stub has to read the
    `id=` list and answer with whichever of them it has -- including answering
    with fewer than were asked for, which is what a deleted observation looks
    like and is the whole reason the real code keys by id instead of zipping
    two lists together.

    `refuse` makes any URL containing that fragment come back HTTP 429.
    """
    by_id = {}
    for fragment, payload in responses.items():
        match = re.search(r"/observations/(\d+)$", fragment)
        if match:
            results = payload.get("results") if isinstance(payload, dict) else None
            if results:
                by_id[match.group(1)] = results[0]

    def handler(method, url, body=None, headers=None):
        if refuse and refuse in url:
            return "<html>Too many requests</html>", plugin.runtime.table_from(
                {"status": 429})

        # The comma separating ids comes through percent-encoded, which is
        # correct and which the real API decodes.
        batch = re.search(r"/observations\?(?:.*&)?id=([\d,%A-Fa-f]+)", url)
        if batch:
            wanted = urllib.parse.unquote(batch.group(1)).split(",")
            found = [by_id[one] for one in wanted if one in by_id]
            return json.dumps({"results": found}), plugin.runtime.table_from(
                {"status": 200})

        for fragment, payload in responses.items():
            if fragment in url:
                return json.dumps(payload), plugin.runtime.table_from(
                    {"status": 200}
                )
        raise AssertionError(f"unexpected {method} {url}")

    return handler


def run_sync(plugin):
    """Start a sync the way anything outside the settings dialog does."""
    urls = plugin.require("PluginUrls")
    url, _ = plugin.call(urls["urlFor"], "sync")
    handler = plugin.require("URLHandler")

    plugin.call(handler["URLHandler"], url)
    plugin.run_pending_tasks()


DAMSELFLY = taxon(
    "Ischnura cervula",
    12345,
    ancestors=["Animalia", "Arthropoda", "Insecta", "Odonata", "Ischnura"],
    common="Pacific Forktail",
)


def observation(obs_id=999, community=None, taxon_=None, grade="research",
                uuid="0e1d2c3b-4a59-6879-8a9b-0c1d2e3f4a5b", **extra):
    obs = {"id": obs_id, "quality_grade": grade, "uuid": uuid}
    if community:
        obs["community_taxon"] = community
    if taxon_:
        obs["taxon"] = taxon_
    obs.update(extra)
    return {"results": [obs]}


def test_a_synced_photo_gets_the_full_keyword_hierarchy():
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    names = [k["name"] for k in plugin.keywords]
    assert names == [
        "iNaturalist",
        "Animalia",
        "Arthropoda",
        "Insecta",
        "Odonata",
        "Ischnura",
        "Ischnura cervula",
    ]


def test_the_hierarchy_is_nested_rather_than_flat():
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    parents = {k["name"]: k["parent"] for k in plugin.keywords}
    assert parents["iNaturalist"] is None
    assert parents["Animalia"] == "iNaturalist"
    assert parents["Ischnura cervula"] == "Ischnura"


def test_keywords_are_created_inside_a_write_transaction():
    """createKeyword outside withWriteAccessDo is an error in the real SDK."""
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    # The stub raises if write access is missing, and the failure would surface
    # as an error dialog rather than an exception.
    assert plugin.dialogs[-1]["style"] == "info"
    assert plugin.catalog_writes == ["iNat sync"]


def test_the_leaf_keyword_is_applied_to_the_photo():
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    applied = [photo.keywords[i]["name"] for i in range(1, len(photo.keywords) + 1)]
    assert applied == ["Ischnura cervula"]


def test_metadata_is_written_back():
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    props = photo["_props"]
    assert props["inat_taxon_name"] == "Ischnura cervula"
    assert props["inat_common_name"] == "Pacific Forktail"
    assert props["inat_quality_grade"] == "research"
    assert props["inat_observation_url"].endswith("/observations/999")
    assert props["inat_last_synced"]


def test_syncing_records_the_observations_uuid():
    """The UUID is how a photo finds its observation again at publish time, and
    a photo linked by pasting an ID has never had one. Without this, adopting an
    existing observation and then publishing creates a second, duplicate one."""
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert (
        photo["_props"]["inat_observation_uuid"]
        == "0e1d2c3b-4a59-6879-8a9b-0c1d2e3f4a5b"
    )


@pytest.mark.parametrize("uuid", [None, ""])
def test_an_observation_with_no_usable_uuid_leaves_the_field_alone(uuid):
    """Storing an empty UUID would look like a grouping key and quietly join
    every such photo into one observation."""
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY, uuid=uuid)}
    )
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo["_props"]["inat_observation_uuid"] is None


def test_the_community_taxon_wins_over_the_uploader_s_own():
    """The point of syncing is to pick up what other people decided."""
    mine = taxon("Ischnura", 111, ancestors=["Animalia"])
    theirs = taxon("Ischnura cervula", 12345, ancestors=["Animalia"])
    plugin = make_plugin(
        {"/observations/999": observation(community=theirs, taxon_=mine)}
    )
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo["_props"]["inat_taxon_name"] == "Ischnura cervula"


def test_a_photo_without_an_observation_id_is_skipped_not_failed():
    plugin = make_plugin({})
    plugin.set_target_photos([plugin.new_photo()])

    run_sync(plugin)

    summary = plugin.dialogs[-1]
    assert "Skipped (no ID): 1" in summary["message"]
    assert "Errors: 0" in summary["message"]
    assert summary["style"] == "info"


def test_an_unidentified_observation_is_a_normal_outcome_not_an_error():
    """Nobody has identified a brand-new observation, so with sync-on-publish
    turned on this is what almost every first publish looks like. Counting it
    as an error meant a warning dialog after a publish that went perfectly."""
    plugin = make_plugin({"/observations/999": observation()})
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    summary = plugin.dialogs[-1]
    assert "Not identified yet: 1" in summary["message"]
    assert "Errors: 0" in summary["message"]
    assert summary["style"] == "info"


def test_an_unidentified_observation_still_records_its_uuid_and_url():
    """This is the whole reason to sync a photo that was linked by pasting an
    ID: without the UUID its next publish creates a second observation. Bailing
    out before the write, because no taxon had arrived yet, lost exactly the
    field that mattered."""
    plugin = make_plugin({"/observations/999": observation()})
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    props = photo["_props"]
    assert props["inat_observation_uuid"] == "0e1d2c3b-4a59-6879-8a9b-0c1d2e3f4a5b"
    assert props["inat_observation_url"].endswith("/observations/999")
    assert props["inat_last_synced"]


def test_an_unidentified_observation_adds_no_keywords():
    """A taxon-less observation has nothing to file under, and an "iNaturalist"
    root keyword on its own is just clutter."""
    plugin = make_plugin({"/observations/999": observation()})
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert plugin.keywords == []


def test_ancestors_are_fetched_when_the_observation_omits_them():
    thin = {"id": 12345, "name": "Ischnura cervula"}
    plugin = make_plugin(
        {
            "/observations/999": observation(community=thin),
            "/taxa/12345": {"results": [DAMSELFLY]},
        }
    )
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert "Odonata" in [k["name"] for k in plugin.keywords]


def test_one_failing_photo_does_not_stop_the_rest():
    """A deleted or private observation should cost that photo and no other."""
    plugin = make_plugin(
        {
            "/observations/999": observation(community=DAMSELFLY),
            "/observations/888": {"results": []},
        }
    )
    plugin.set_target_photos(
        [
            plugin.new_photo(inat_observation_id="888"),
            plugin.new_photo(inat_observation_id="999"),
        ]
    )

    run_sync(plugin)

    summary = plugin.dialogs[-1]["message"]
    assert "Synced: 1" in summary
    assert "Errors: 1" in summary


def test_nothing_selected_is_a_message_not_a_crash():
    plugin = make_plugin({})
    plugin.set_target_photos([])

    run_sync(plugin)

    assert plugin.dialogs[-1]["message"] == "No photos selected."


def test_sync_reads_but_never_writes_to_inaturalist():
    """PUT /observations wipes photos without ignore_photos; sync has no
    reason to write at all, so assert it stays read-only."""
    plugin = make_plugin(
        {"/observations/999": observation(community=DAMSELFLY)}
    )
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert {call["method"] for call in plugin.http_calls} == {"GET"}


# ---------------------------------------------------------------------------
# Bringing the location home
# ---------------------------------------------------------------------------


def coords(plugin, **fields):
    """Run SyncCore.coordinatesFrom over an observation-shaped table."""
    sync = plugin.require("SyncCore")
    return sync["coordinatesFrom"](plugin.runtime.table_from(fields))


def test_a_plain_observation_gives_up_its_coordinates():
    plugin = LuaPlugin()
    lat, lng, acc = coords(plugin, location="48.5817,-123.3715",
                           positional_accuracy=36)

    assert (round(lat, 4), round(lng, 4)) == (48.5817, -123.3715)
    assert acc == 36


def test_an_obscured_observation_is_refused():
    """The single most dangerous response this plugin can receive. iNaturalist
    randomises the public position of anything obscured -- a live example was
    ~30 km out -- and still returns a location string that looks exactly like a
    real one. Only the `obscured` flag says otherwise, so believing the
    coordinates would write a plausible, wrong location into someone's catalog
    without a word."""
    plugin = LuaPlugin()
    lat, lng, acc = coords(plugin, location="22.5854,114.0637", obscured=True,
                           positional_accuracy=61,
                           public_positional_accuracy=30278)

    assert lat is None and lng is None and acc is None


def test_the_owners_private_location_is_used_even_when_obscured():
    """Authenticated as the observation's owner, iNaturalist tells the truth in
    private_location. That is the one case where an obscured observation still
    has a usable position."""
    plugin = LuaPlugin()
    lat, lng, _ = coords(plugin, location="22.5000,114.0000",
                         private_location="22.5854,114.0637", obscured=True)

    assert (round(lat, 4), round(lng, 4)) == (22.5854, 114.0637)


def test_an_observation_with_no_location_gives_nothing():
    plugin = LuaPlugin()
    assert coords(plugin, positional_accuracy=10)[0] is None


def test_a_malformed_location_is_not_half_believed():
    """A partial parse would put the photo on the equator."""
    plugin = LuaPlugin()
    assert coords(plugin, location="48.5817")[0] is None


def test_syncing_gives_an_unlocated_photo_its_location():
    """The case this exists for: uploaded from a camera with no GPS, placed on
    the map afterwards on the website. Without this the catalog never finds
    out."""
    plugin = make_plugin({
        "/observations/999": observation(community=DAMSELFLY,
                                         location="48.5817,-123.3715",
                                         positional_accuracy=36),
    })
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    gps = photo["_raw"]["gps"]
    assert round(gps["latitude"], 4) == 48.5817
    assert round(gps["longitude"], 4) == -123.3715
    assert photo["_props"]["inat_positional_accuracy"] == "36"


def test_syncing_never_overwrites_a_location_the_photo_already_has():
    """iNaturalist's copy came from the photo in the first place. Where they
    have genuinely diverged, silently moving a photo the user has already
    placed is a correction nobody asked for and cannot see happen."""
    plugin = make_plugin({
        "/observations/999": observation(community=DAMSELFLY,
                                         location="0.0,0.0"),
    })
    photo = plugin.new_photo(inat_observation_id="999",
                             raw={"gps": {"latitude": 51.5, "longitude": -0.1}})
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo["_raw"]["gps"]["latitude"] == 51.5
    assert photo["_raw"]["gps"]["longitude"] == -0.1


def test_syncing_an_obscured_observation_leaves_the_photo_unlocated():
    plugin = make_plugin({
        "/observations/999": observation(community=DAMSELFLY,
                                         location="22.5854,114.0637",
                                         obscured=True,
                                         positional_accuracy=61),
    })
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo["_raw"]["gps"] is None
    assert not photo["_props"]["inat_positional_accuracy"]


def test_an_observation_with_no_coordinates_writes_no_gps():
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo["_raw"]["gps"] is None


# ---------------------------------------------------------------------------
# When the lineage cannot be fetched
#
# A taxon on an observation carries a name but no ancestors, so the plugin
# fetches the full one. When iNaturalist refuses -- and under rate limiting it
# refused 346 times in one real run -- the fallback taxon still looks like a
# taxon, and the keyword code used to file it directly under "iNaturalist".
# Writing nothing is a re-run; writing a species beside the kingdoms is a
# cleanup in someone else's catalog.
# ---------------------------------------------------------------------------


def bare_taxon(name="Bombus", taxon_id=52775):
    """As an observation reports it: named, ranked, no lineage."""
    return {"id": taxon_id, "name": name, "rank": "genus",
            "preferred_common_name": "Bumble Bees"}


def make_refusing_plugin(responses, refuse):
    """Like make_plugin, but any URL containing `refuse` comes back 429."""
    plugin = LuaPlugin()
    auth = plugin.require("InatAuth")
    plugin.call(auth["storeApiToken"], make_jwt(FUTURE))
    plugin.set_http_handler(observation_handler(plugin, responses, refuse=refuse))
    return plugin


def test_a_throttled_taxon_writes_no_keyword_at_all():
    plugin = make_refusing_plugin(
        {"/observations/999": observation(community=bare_taxon())},
        refuse="/taxa/")
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    # Not even the root: a lone "iNaturalist" keyword is harmless, but the
    # species that used to land under it is not.
    assert [k["name"] for k in plugin.keywords] == []


def test_a_throttled_taxon_still_writes_the_fields():
    """They are right whatever happened to the lineage, and they are what a
    later run reads to put the keyword where it belongs."""
    plugin = make_refusing_plugin(
        {"/observations/999": observation(community=bare_taxon())},
        refuse="/taxa/")
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo._props["inat_taxon_name"] == "Bombus"
    assert photo._props["inat_taxon_id"] == "52775"


def test_a_throttled_taxon_says_so_in_the_log():
    """Silence here is what let a third of a keyword tree go wrong unnoticed."""
    plugin = make_refusing_plugin(
        {"/observations/999": observation(community=bare_taxon())},
        refuse="/taxa/")
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert any("No lineage for taxon Bombus" in line
               for line in plugin.log_lines)


def test_a_kingdom_is_not_mistaken_for_a_missing_lineage():
    """An empty ancestors list is the top of the tree, not a failed fetch. Read
    as failure it would refuse to file anything at kingdom rank."""
    plugin = make_plugin({"/observations/999": observation(
        community=taxon("Animalia", 1, ancestors=[]))})
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert [k["name"] for k in plugin.keywords] == ["iNaturalist", "Animalia"]


# ---------------------------------------------------------------------------
# Fetching observations in batches
#
# One request per photo was fine until requests had to be paced a second apart
# to stay inside the rate limit. At that point a sync of the author's 654
# linked photos spent eleven minutes doing nothing but waiting.
# ---------------------------------------------------------------------------


def names_on(photo):
    """The keywords actually applied to one photo, in order."""
    return [photo.keywords[i]["name"] for i in range(1, len(photo.keywords) + 1)]


def counting_plugin(responses):
    """A plugin that also records every URL its HTTP stub is asked for."""
    plugin = make_plugin(responses)
    inner = observation_handler(plugin, responses)
    seen = []

    def handler(method, url, body=None, headers=None):
        seen.append(url)
        return inner(method, url, body, headers)

    plugin.set_http_handler(handler)
    return plugin, seen


def test_many_photos_cost_a_handful_of_requests_not_one_each():
    routes = {f"/observations/{i}": observation(obs_id=i, community=DAMSELFLY)
              for i in range(1000, 1450)}
    plugin, seen = counting_plugin(routes)
    plugin.set_target_photos(
        [plugin.new_photo(inat_observation_id=str(i))
         for i in range(1000, 1450)])

    run_sync(plugin)

    fetches = [url for url in seen if "/observations?" in url]
    # 450 ids at 200 to a request.
    assert len(fetches) == 3


def test_photos_sharing_an_observation_are_fetched_once():
    plugin, seen = counting_plugin(
        {"/observations/999": observation(community=DAMSELFLY)})
    plugin.set_target_photos(
        [plugin.new_photo(inat_observation_id="999") for _ in range(5)])

    run_sync(plugin)

    assert len([url for url in seen if "/observations?" in url]) == 1
    assert "Synced: 5" in plugin.dialogs[-1]["message"]


def test_an_observation_that_no_longer_exists_is_reported_not_skipped():
    """A deleted id simply does not come back. That is this photo's error."""
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.set_target_photos([
        plugin.new_photo(inat_observation_id="888"),
        plugin.new_photo(inat_observation_id="999"),
    ])

    run_sync(plugin)

    summary = plugin.dialogs[-1]["message"]
    assert "Synced: 1" in summary
    assert "Errors: 1" in summary


def test_each_photo_gets_its_own_observation_not_the_next_one_along():
    """The API may answer in any order, so assignment must be by id."""
    other = taxon("Bombus vosnesenskii", 555,
                  ancestors=["Animalia", "Arthropoda", "Insecta",
                             "Hymenoptera", "Bombus"],
                  common="Yellow-faced Bumble Bee")
    plugin = make_plugin({
        "/observations/777": observation(obs_id=777, community=other),
        "/observations/999": observation(obs_id=999, community=DAMSELFLY),
    })
    bee = plugin.new_photo(inat_observation_id="777")
    fly = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([bee, fly])

    run_sync(plugin)

    assert names_on(bee) == ["Bombus vosnesenskii"]
    assert names_on(fly) == ["Ischnura cervula"]


def test_a_photo_with_no_observation_id_costs_no_request():
    plugin, seen = counting_plugin({})
    plugin.set_target_photos([plugin.new_photo(), plugin.new_photo()])

    run_sync(plugin)

    assert [url for url in seen if "/observations" in url] == []
    assert "Skipped (no ID): 2" in plugin.dialogs[-1]["message"]


# ---------------------------------------------------------------------------
# A refused keyword must not strand the rest of the lineage at the top level
#
# Lightroom hands back nil from createKeyword under conditions the SDK does not
# document. The loop used to assign that nil to parentKw, and a nil parent
# means "top of the catalog" -- so a lineage that broke at Insecta went on to
# create Odonata, Ischnura and the species as new top-level keywords, outside
# the iNaturalist tree. Deleting iNaturalist does not remove them, because they
# were never in it, and the SDK cannot delete a keyword at all.
# ---------------------------------------------------------------------------


def test_a_refused_keyword_leaves_nothing_at_the_top_level():
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.refuse_keyword("Insecta")
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    stranded = [k["name"] for k in plugin.keywords
                if k["parent"] is None and k["name"] != "iNaturalist"]
    assert stranded == []


def test_a_refused_keyword_stops_the_path_rather_than_finishing_it():
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.refuse_keyword("Insecta")
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    made = [k["name"] for k in plugin.keywords]
    assert "Arthropoda" in made          # everything above the break is fine
    assert "Odonata" not in made         # everything below it is not written
    assert "Ischnura cervula" not in made


def test_a_refused_keyword_applies_no_keyword_to_the_photo():
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.refuse_keyword("Insecta")
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert names_on(photo) == []


def test_a_refused_keyword_still_writes_the_taxon_fields():
    """The fields are right either way, and a later run reads them to repair."""
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.refuse_keyword("Insecta")
    photo = plugin.new_photo(inat_observation_id="999")
    plugin.set_target_photos([photo])

    run_sync(plugin)

    assert photo._props["inat_taxon_name"] == "Ischnura cervula"


def test_a_refused_keyword_says_which_one_in_the_log():
    plugin = make_plugin({"/observations/999": observation(community=DAMSELFLY)})
    plugin.refuse_keyword("Insecta")
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    assert any("Insecta" in line and "would not create" in line
               for line in plugin.log_lines)
