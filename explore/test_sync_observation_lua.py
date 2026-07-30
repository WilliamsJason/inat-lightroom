"""Tests for SyncObservation.lua, the "Sync Selected Photos" menu item.

This file runs at load time rather than exposing functions, so each test loads
it into a fresh runtime and drains the task queue, which is what Lightroom does
once the menu handler returns.

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
    plugin.require("SyncObservation")
    plugin.run_pending_tasks()


DAMSELFLY = taxon(
    "Ischnura cervula",
    12345,
    ancestors=["Animalia", "Arthropoda", "Insecta", "Odonata", "Ischnura"],
    common="Pacific Forktail",
)


def observation(obs_id=999, community=None, taxon_=None, grade="research"):
    obs = {"id": obs_id, "quality_grade": grade}
    if community:
        obs["community_taxon"] = community
    if taxon_:
        obs["taxon"] = taxon_
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


def test_an_observation_with_no_taxon_yet_is_reported_as_an_error():
    """Freshly created observations lag the search index by minutes."""
    plugin = make_plugin({"/observations/999": observation()})
    plugin.set_target_photos([plugin.new_photo(inat_observation_id="999")])

    run_sync(plugin)

    summary = plugin.dialogs[-1]
    assert "has no taxon data yet" in summary["message"]
    assert summary["style"] == "warning"


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
    plugin = make_plugin(
        {
            "/observations/999": observation(community=DAMSELFLY),
            "/observations/888": observation(obs_id=888),
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
