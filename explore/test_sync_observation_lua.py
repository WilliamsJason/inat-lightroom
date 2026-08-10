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

    def handler(method, url, body=None, headers=None):
        for fragment, payload in responses.items():
            if fragment in url:
                return json.dumps(payload), plugin.runtime.table_from(
                    {"status": 200}
                )
        raise AssertionError(f"unexpected {method} {url}")

    plugin.set_http_handler(handler)
    return plugin


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
