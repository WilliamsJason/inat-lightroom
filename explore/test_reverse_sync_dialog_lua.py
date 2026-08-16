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


def deep(plugin, value):
    """Convert nested dicts too.

    A Python dict reaching Lua as itself raises KeyError on a missing key
    rather than reading as nil, so `taxon.preferred_common_name` on a taxon
    that has none takes out the test instead of exercising the fallback.
    """
    if isinstance(value, dict):
        return plugin.runtime.table_from(
            {key: deep(plugin, item) for key, item in value.items()})
    return value


def match(plugin, **fields):
    fields.setdefault("path", "/photos/2024 Spring/DSC_0042.NEF")
    observation = fields.pop("observation", {"species_guess": "Common Frog"})
    table = plugin.runtime.table_from(fields)
    table.observation = deep(plugin, observation)
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


def test_the_row_carries_both_names(plugin, dialog):
    """A common name is what makes the row scannable; a scientific name is what
    makes it unambiguous. Confirming a match wants both."""
    row = dialog["describe"](match(plugin, observation={
        "taxon": {"preferred_common_name": "Dark Fishing Spider",
                  "name": "Dolomedes tenebrosus"}}))

    assert "Dark Fishing Spider (Dolomedes tenebrosus)" in row


def test_the_communitys_name_beats_the_observers_guess(plugin, dialog):
    """species_guess is whatever was typed at the time; the taxon is what has
    been agreed since."""
    row = dialog["describe"](match(plugin, observation={
        "species_guess": "some kind of heron",
        "taxon": {"preferred_common_name": "Grey Heron",
                  "name": "Ardea cinerea"}}))

    assert "Grey Heron (Ardea cinerea)" in row
    assert "some kind of heron" not in row


def test_a_taxon_with_no_common_name_is_not_repeated(plugin, dialog):
    """Many taxa report the scientific name in the common-name slot, and
    "Dolomedes (Dolomedes)" reads as a bug rather than as thoroughness."""
    row = dialog["describe"](match(plugin, observation={
        "taxon": {"preferred_common_name": "Dolomedes", "name": "Dolomedes"}}))

    assert "Dolomedes (" not in row
    assert "Dolomedes" in row


def test_a_scientific_name_alone_is_enough(plugin, dialog):
    row = dialog["describe"](match(plugin, observation={
        "taxon": {"name": "Dolomedes tenebrosus"}}))

    assert "Dolomedes tenebrosus" in row


def test_a_guess_is_used_when_there_is_no_taxon(plugin, dialog):
    """An observation nobody has identified yet still has to say something."""
    row = dialog["describe"](match(plugin, observation={
        "species_guess": "small brown beetle"}))

    assert "small brown beetle" in row


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


# -------------------------------------------------------------- diagnostics

def test_an_ordinary_path_is_not_reported(plugin, dialog):
    """Reporting every row would bury the one that matters."""
    assert dialog["oddBytes"]("AlienMuffin/20180824_200649.jpg") is None


def test_a_non_ascii_byte_is_spelled_out(plugin, dialog):
    """The whole point: the path prints fine and draws wrong, so the log has to
    show the bytes rather than the string."""
    escaped = dialog["oddBytes"]("Bj\xc3\xb6rn/DSC_0042.NEF")

    assert escaped == "Bj\\xC3\\xB6rn/DSC_0042.NEF"


def test_a_control_character_is_spelled_out(plugin, dialog):
    """A stray newline or NUL would end the drawn text with nothing to see."""
    assert dialog["oddBytes"]("a\nb") == "a\\x0Ab"
    assert dialog["oddBytes"]("a\0b") == "a\\x00b"


def test_a_non_string_is_not_reported(plugin, dialog):
    assert dialog["oddBytes"](None) is None


def test_the_em_dash_in_our_own_separator_is_not_reported(plugin, dialog):
    """The separator between species and filename is an em dash, so every title
    holds non-ASCII bytes. Escaping titles rather than paths would flag all 166
    rows and say nothing about the one that is wrong."""
    every = matches(plugin, match(plugin))

    assert dialog["logRows"](every, 25) == 0


def test_every_unusual_row_is_logged_however_far_down_it_is(plugin, dialog):
    """The row that prompted this was second, but nothing says the next one
    will be on the first page."""
    every = matches(plugin,
        *[match(plugin) for _ in range(30)],
        match(plugin, path="Bj\xc3\xb6rn/DSC_0042.NEF"))

    assert dialog["logRows"](every, 5) == 1
    assert any("may not draw" in line and "row 31" in line
               for line in plugin.log_lines)


def test_the_first_page_is_logged_even_when_it_is_ordinary(plugin, dialog):
    """If the odd row turns out to be plain ASCII, the truncation is somewhere
    other than the bytes -- and knowing that needs the rows that worked."""
    every = matches(plugin, *[match(plugin) for _ in range(8)])

    assert dialog["logRows"](every, 3) == 0
    assert sum(1 for line in plugin.log_lines if "review row" in line) == 3


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


def test_the_last_page_is_padded_backwards_rather_than_left_short(
        plugin, dialog):
    """Hiding surplus rows does not work -- visible binds and does nothing, and
    page 7 of 7 drew nine empty checkboxes beside placeholder tiles, which reads
    as nine matches the feature failed to describe. So the last page ends on the
    last match and begins a full page before it."""
    assert tuple(dialog["pageRange"](3, 60, 25)) == (36, 60)


def test_a_run_shorter_than_a_page_does_not_pad(plugin, dialog):
    """There is nothing to pad with, and the rows are built to fit."""
    assert tuple(dialog["pageRange"](1, 16, 25)) == (1, 16)


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

    assert props["status"].startswith("Page 1 of 3")


def test_no_row_is_ever_left_empty(plugin, dialog):
    """Seven matches over pages of three: the last page shows 5, 6, 7 rather
    than 7 and two blanks. The blanks were the bug -- a checkbox beside a
    placeholder tile with no text looks like a match that failed."""
    made, _every, props = pager(plugin, dialog, 7)

    made["turn"](made, 1)
    made["turn"](made, 1)

    assert props["title1"] != ""
    assert props["title2"] != ""
    assert props["title3"] != ""


def test_the_padded_page_repeats_rather_than_invents(plugin, dialog):
    """The overlap has to be real matches. Selection is keyed by match index,
    so a match seen twice is one checkbox state, not two."""
    made, every, props = pager(plugin, dialog, 7)

    made["turn"](made, 1)
    made["turn"](made, 1)
    props["selected1"] = False          # match 5, also shown on page 2

    made["turn"](made, -1)              # page 2 is matches 4, 5, 6

    assert props["selected2"] is False


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
