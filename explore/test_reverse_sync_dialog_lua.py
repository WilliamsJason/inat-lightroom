"""Tests for ReverseSyncDialog.lua -- the review list.

The list is the only thing standing between a matching heuristic and someone's
catalog, so what it says about a match matters as much as the match. These
cover the row text, the pre-selection, and the translation back from a
selection to a decision -- the last being the one that can silently link photos
the user just unticked.

The dialog itself is not opened; presentModalDialog needs a real UI. Everything
here is the logic that decides what would be shown.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def dialog(plugin):
    return plugin.require("ReverseSyncDialog")


def match(plugin, **fields):
    fields.setdefault("path", "/photos/2024 Spring/DSC_0042.NEF")
    observation = fields.pop("observation", {"species_guess": "Common Frog"})
    table = plugin.runtime.table_from(fields)
    table.observation = plugin.runtime.table_from(observation)
    return table


def matches(plugin, *items):
    return plugin.runtime.table_from(list(items))


# ---------------------------------------------------------------- file names

def test_the_row_names_the_folder_as_well_as_the_file(plugin, dialog):
    """DSC_0042 on its own stops identifying anything the moment a camera's
    counter wraps, which over a career it does to everyone."""
    assert dialog["shortPath"]("/photos/2024 Spring/DSC_0042.NEF") \
        == "2024 Spring/DSC_0042.NEF"


def test_windows_paths_are_split_the_same_way(plugin, dialog):
    assert dialog["shortPath"](r"C:\Photos\2024 Spring\DSC_0042.NEF") \
        == "2024 Spring/DSC_0042.NEF"


def test_a_missing_path_still_produces_a_row(plugin, dialog):
    """batchGetRawMetadata can return a row without a path. A nil here would
    take out the whole list rather than the one entry."""
    assert dialog["shortPath"](None) == "(unknown file)"
    assert dialog["shortPath"]("") == "(unknown file)"


# ----------------------------------------------------------------- row text

def test_the_row_names_the_species(plugin, dialog):
    row = dialog["describe"](match(plugin))

    assert "DSC_0042.NEF" in row
    assert "Common Frog" in row


def test_a_taxon_is_used_when_there_is_no_guess(plugin, dialog):
    row = dialog["describe"](match(plugin, observation={
        "taxon": {"preferred_common_name": "Grey Heron", "name": "Ardea cinerea"}}))

    assert "Grey Heron" in row


def test_an_unidentified_observation_still_gets_a_row(plugin, dialog):
    row = dialog["describe"](match(plugin, observation={}))

    assert "Unknown species" in row


def test_a_location_conflict_is_spelled_out(plugin, dialog):
    """The user can adjudicate "iNat thinks this was 40 km away"; the matcher
    cannot, which is why it flags rather than discards."""
    row = dialog["describe"](match(plugin, tier="conflict", distance=40000))

    assert "40 km away" in row


def test_an_ambiguous_match_says_how_many_others_fit(plugin, dialog):
    row = dialog["describe"](match(plugin, ambiguous=True, alternatives=3))

    assert "3 other photo(s) fit equally well" in row


def test_a_confident_match_carries_no_note(plugin, dialog):
    """If every row were annotated the flags would stop meaning anything."""
    row = dialog["describe"](match(plugin, tier="confirmed", distance=12))

    assert "[" not in row


# ---------------------------------------------------------------- selection

def test_every_row_starts_selected(plugin, dialog):
    """Ticking a thousand boxes to accept matches that are already right is an
    offer people abandon halfway through."""
    items, selection = dialog["build"](matches(plugin,
        match(plugin), match(plugin), match(plugin)))

    assert len(items) == 3
    assert [selection[i] for i in range(1, 4)] == [1, 2, 3]


def test_an_empty_run_builds_an_empty_list(plugin, dialog):
    items, selection = dialog["build"](matches(plugin))

    assert len(items) == 0
    assert len(selection) == 0


def test_the_selection_decides_what_gets_linked(plugin, dialog):
    every = matches(plugin, match(plugin), match(plugin), match(plugin))

    count = dialog["applySelection"](every, plugin.runtime.table_from([1, 3]))

    assert count == 2
    assert [every[i].selected for i in range(1, 4)] == [True, False, True]


def test_unticking_everything_links_nothing(plugin, dialog):
    """An empty selection has to mean none rather than all. Read the other way
    -- as "no filter" -- it would link every match the user just rejected."""
    every = matches(plugin, match(plugin), match(plugin))

    count = dialog["applySelection"](every, plugin.runtime.table_from([]))

    assert count == 0
    assert [every[i].selected for i in range(1, 3)] == [False, False]


def test_a_missing_selection_links_nothing(plugin, dialog):
    every = matches(plugin, match(plugin))

    assert dialog["applySelection"](every, None) == 0


# ------------------------------------------------------------------ summary

def test_the_summary_leads_with_what_matched(plugin, dialog):
    line = dialog["summarise"](plugin.runtime.table_from(
        {"matched": 12, "observations": 20}))

    assert line.startswith("12 of 20 observations matched a photo")


def test_observations_with_no_time_are_reported_separately(plugin, dialog):
    """Distinct from unmatched: the catalog is fine, the observation just does
    not say enough, and telling the user that is how they know to fix it."""
    line = dialog["summarise"](plugin.runtime.table_from(
        {"matched": 1, "observations": 3, "undatable": 2}))

    assert "2 had no time of day" in line


def test_a_clean_run_says_nothing_else(plugin, dialog):
    line = dialog["summarise"](plugin.runtime.table_from(
        {"matched": 5, "observations": 5}))

    assert line == "5 of 5 observations matched a photo."
