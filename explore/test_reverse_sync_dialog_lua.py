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
    note = dialog["caveats"](match(plugin, tier="conflict", distance=40000))

    assert "40 km away" in note


def test_an_ambiguous_match_says_how_many_others_fit(plugin, dialog):
    note = dialog["caveats"](match(plugin, ambiguous=True, alternatives=3))

    assert "3 other photo(s) fit equally well" in note


def test_a_confident_match_carries_no_note(plugin, dialog):
    """If every row were annotated the flags would stop meaning anything."""
    assert dialog["caveats"](match(plugin, tier="confirmed", distance=12)) == ""


def test_the_caveat_line_is_empty_rather_than_absent(plugin, dialog):
    """Rows are reused as the page turns, so a nil here would leave the
    previous page's warning attached to a match that does not have one."""
    assert dialog["caveats"](match(plugin)) == ""


# -------------------------------------------------------------------- paging

def test_a_short_run_is_one_page(plugin, dialog):
    assert dialog["pageCount"](25, 25) == 1
    assert dialog["pageCount"](1, 25) == 1


def test_an_empty_run_still_has_a_page(plugin, dialog):
    """Zero pages would make "Page 1 of 0" and leave both buttons dead."""
    assert dialog["pageCount"](0, 25) == 1


def test_a_partial_last_page_is_still_a_page(plugin, dialog):
    assert dialog["pageCount"](26, 25) == 2
    assert dialog["pageCount"](51, 25) == 3


def test_a_page_covers_its_own_slice(plugin, dialog):
    assert tuple(dialog["pageRange"](1, 60, 25)) == (1, 25)
    assert tuple(dialog["pageRange"](2, 60, 25)) == (26, 50)


def test_the_last_page_stops_at_the_last_match(plugin, dialog):
    """Running to 75 would index past the end and put nil in ten rows."""
    assert tuple(dialog["pageRange"](3, 60, 25)) == (51, 60)


# ---------------------------------------------------------------- selection

def pager(plugin, dialog, count, page_size=3):
    """A Pager over `count` throwaway matches, with its own property table."""
    every = matches(plugin, *[match(plugin) for _ in range(count)])
    props = plugin.eval(
        'function() return import("LrBinding").makePropertyTable(nil) end')()
    made = dialog["Pager"]["new"](every, props,
                                  plugin.runtime.table_from(
                                      {"pageSize": page_size}))
    made["render"](made)
    return made, every, props


def test_every_row_starts_selected(plugin, dialog):
    """Ticking a thousand boxes to accept matches that are already right is an
    offer people abandon halfway through."""
    made, _every, props = pager(plugin, dialog, 3)

    assert [props["selected" + str(row)] for row in (1, 2, 3)] \
        == [True, True, True]


def test_the_page_shows_only_its_own_matches(plugin, dialog):
    made, _every, props = pager(plugin, dialog, 7)

    assert props["visible1"] is True
    assert props["status"].startswith("Page 1 of 3")


def test_a_short_last_page_hides_its_spare_rows(plugin, dialog):
    """The rows cannot be removed, so leaving them showing would repeat the
    previous page's photos under checkboxes that link nothing."""
    made, _every, props = pager(plugin, dialog, 7)

    made["turn"](made, 1)
    made["turn"](made, 1)

    assert props["visible1"] is True
    assert props["visible2"] is False
    assert props["title2"] == ""
    assert props["photo2"] is None


def test_unticking_survives_turning_the_page_and_back(plugin, dialog):
    """The checkboxes are reused, so an answer left in a widget is an answer
    overwritten by the next page. This is the bug the selection array exists
    to prevent."""
    made, every, props = pager(plugin, dialog, 6)

    props["selected2"] = False
    made["turn"](made, 1)
    made["turn"](made, -1)

    assert props["selected2"] is False
    assert made["commit"](made) == 5
    assert [every[i].selected for i in range(1, 7)] \
        == [True, False, True, True, True, True]


def test_the_answer_from_a_page_left_behind_is_still_kept(plugin, dialog):
    """Untick on page 1, accept from page 2: the dialog never returns to the
    page holding the decision, so it has to have been harvested on the way
    out."""
    made, every, props = pager(plugin, dialog, 6)

    props["selected1"] = False
    made["turn"](made, 1)

    assert made["commit"](made) == 5
    assert every[1].selected is False


def test_paging_stops_at_both_ends(plugin, dialog):
    made, _every, props = pager(plugin, dialog, 6)

    assert made["turn"](made, -1) is False
    assert made["turn"](made, 1) is True
    assert made["turn"](made, 1) is False
    assert props["canGoForward"] is False
    assert props["canGoBack"] is True


def test_select_none_reaches_pages_the_user_has_not_seen(plugin, dialog):
    """The button sits beside a count of the whole run. Clearing only the
    visible page would leave that number contradicting the button next to
    it."""
    made, every, props = pager(plugin, dialog, 6)

    made["setAll"](made, False)

    assert props["status"].endswith("0 of 6 selected")
    assert made["commit"](made) == 0
    assert [every[i].selected for i in range(1, 7)] == [False] * 6


def test_select_all_puts_back_what_was_unticked(plugin, dialog):
    made, _every, props = pager(plugin, dialog, 6)

    props["selected1"] = False
    made["setAll"](made, True)

    assert props["selected1"] is True
    assert made["commit"](made) == 6


def test_select_all_does_not_discard_the_page_s_thumbnails(plugin, dialog):
    """Re-rendering would bump the epoch and abandon downloads that are already
    correct -- only the ticks changed."""
    made, _every, _props = pager(plugin, dialog, 6)
    before = made["epoch"]

    made["setAll"](made, False)

    assert made["epoch"] == before


def test_unticking_everything_links_nothing(plugin, dialog):
    """An empty selection has to mean none rather than all. Read the other way
    -- as "no filter" -- it would link every match the user just rejected."""
    made, every, props = pager(plugin, dialog, 2, page_size=25)

    props["selected1"] = False
    props["selected2"] = False

    assert made["commit"](made) == 0
    assert [every[i].selected for i in range(1, 3)] == [False, False]


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
