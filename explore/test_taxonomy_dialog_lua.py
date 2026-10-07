"""The taxonomy window -- one rank per row, each with its own Copy button.

Covers TaxonomyDialog.lua. This is a window of its own rather than a part of
the floating panel for a reason the SDK forces: the panel's view tree is fixed
once presented and a bound ``visible`` does not hide a row, so a collapsible
taxonomy inside the panel would stand at full height whether collapsed or not.

It is *floating* rather than modal because modals stack: a second one leaves
the first on screen, unreadable and unmovable, until the top is dismissed, and
there is no way to close a modal from code. Floating windows are independent,
which turns opening two into the feature it looked like -- two lineages side by
side.
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
    return plugin.require("TaxonomyDialog")


def deep(plugin, value):
    if isinstance(value, dict):
        return plugin.runtime.table_from(
            {k: deep(plugin, v) for k, v in value.items()})
    if isinstance(value, list):
        return plugin.runtime.table_from(
            {i + 1: deep(plugin, v) for i, v in enumerate(value)})
    return value


def views(node, found=None):
    found = [] if found is None else found
    if not hasattr(node, "keys"):
        return found
    found.append(node)
    for key in list(node.keys()):
        child = node[key]
        if hasattr(child, "keys"):
            views(child, found)
    return found


def of_type(contents, view_type):
    return [v for v in views(contents) if v["_viewType"] == view_type]


def lineage(plugin):
    """What PanelCore.taxonomyRows hands over."""
    core = plugin.require("PanelCore")
    taxon = deep(plugin, {
        "id": 103486, "name": "Ischnura erratica", "rank": "species",
        "ancestors": [
            {"id": 1, "name": "Animalia", "rank": "kingdom"},
            {"id": 47158, "name": "Insecta", "rank": "class"},
            {"id": 52054, "name": "Ischnura", "rank": "genus",
             "preferred_common_name": "Forktails"},
        ],
    })
    return core["taxonomyRows"](taxon)


def shown(plugin, dialog, rows=None, heading="Ischnura erratica"):
    rows = lineage(plugin) if rows is None else rows
    result = plugin.in_task(dialog.show, None, rows, heading)
    return result, plugin.floating_dialogs[-1] if plugin.floating_dialogs else None


def press(plugin, opened, title):
    """Press a button in the window by its label, and let its task run."""
    button = [b for b in of_type(opened["contents"], "push_button")
              if b["title"] == title]
    assert len(button) == 1, f"expected one {title} button"
    button[0]["action"]()
    plugin.run_pending_tasks()


# ---------------------------------------------------------------------------
# What it draws
# ---------------------------------------------------------------------------


def test_every_rank_gets_a_row(plugin, dialog):
    _, opened = shown(plugin, dialog)

    labels = [v["title"] for v in of_type(opened["contents"], "static_text")
              if isinstance(v["title"], str) and v["title"].endswith(":")]

    assert labels == ["Kingdom:", "Class:", "Genus:", "Species:"]


def test_every_row_can_be_copied_on_its_own(plugin, dialog):
    """The request was for fields that are copy/pastable. A selectable
    static_text is not that -- it is a field you can select if you aim
    carefully, and it would take the row's mouse_down with it."""
    _, opened = shown(plugin, dialog)

    copies = [b for b in of_type(opened["contents"], "push_button")
              if b["title"] == "Copy"]

    assert len(copies) == 4


def test_a_rank_shows_its_common_name_too(plugin, dialog):
    _, opened = shown(plugin, dialog)

    texts = [v["title"] for v in of_type(opened["contents"], "static_text")
             if isinstance(v["title"], str)]

    assert "Forktails (Ischnura)" in texts


def test_the_name_column_truncates_rather_than_dropping_a_word(plugin, dialog):
    """Without `truncation` the documented behaviour is to drop the last word
    silently, which reads as a shorter name rather than a cut-off one."""
    _, opened = shown(plugin, dialog)

    names = [v for v in of_type(opened["contents"], "static_text")
             if v["title"] == "Forktails (Ischnura)"]

    assert len(names) == 1
    assert names[0]["truncation"] == "tail"
    assert names[0]["width"] > 0


def test_the_window_is_named_after_the_taxon(plugin, dialog):
    _, opened = shown(plugin, dialog)

    assert "Ischnura erratica" in opened["title"]


def test_no_heading_still_names_the_window(plugin, dialog):
    _, opened = shown(plugin, dialog, heading=None)

    assert "Taxonomy" in opened["title"]


def test_an_empty_lineage_opens_nothing(plugin, dialog):
    """There is nothing to show and nothing to copy, so a window would only be
    a thing to close."""
    result = plugin.in_task(dialog.show, None, deep(plugin, []), "")

    assert result is False
    assert plugin.floating_dialogs == []


# ---------------------------------------------------------------------------
# Opening more than one
# ---------------------------------------------------------------------------


def test_the_window_floats_rather_than_blocking_the_panel(plugin, dialog):
    """The bug this fixes: two modal windows stack, and only the top one can be
    selected, so the first is stranded on screen."""
    _, opened = shown(plugin, dialog)

    assert plugin.modal_dialogs == []
    assert opened["blockTask"] is True, \
        "without blockTask the context dies and every binding is dead"


def test_two_taxa_get_two_windows(plugin, dialog):
    """The reason for making them floating at all: comparing two lineages is
    how anyone decides between two suggestions."""
    core = plugin.require("PanelCore")
    other = core["taxonomyRows"](deep(plugin, {
        "id": 47219, "name": "Apis mellifera", "rank": "species",
        "ancestors": [{"id": 1, "name": "Animalia", "rank": "kingdom"}],
    }))

    shown(plugin, dialog)
    shown(plugin, dialog, rows=other, heading="Apis mellifera")

    ids = [d["id"] for d in plugin.floating_dialogs]

    assert len(plugin.floating_dialogs) == 2
    assert ids[0] != ids[1]


def test_the_same_taxon_keeps_the_same_window_id(plugin, dialog):
    """Keyed on the taxon, so asking twice about one species raises the window
    already open rather than laying an identical one on top of it."""
    shown(plugin, dialog)
    shown(plugin, dialog)

    ids = [d["id"] for d in plugin.floating_dialogs]

    assert ids[0] == ids[1]
    assert "103486" in ids[0]


def test_the_window_does_not_remember_a_frame(plugin, dialog):
    """Every one of these would share one remembered rectangle, so a second
    would open exactly on top of the first -- the stacking this replaced, at
    the position the user had chosen."""
    _, opened = shown(plugin, dialog)

    assert opened["save_frame"] is None


def test_the_window_can_be_closed(plugin, dialog):
    """The close box is always there. The Close button below is the same
    WM_CLOSE by another route -- it cannot be
    closeFloatingDialogsForPlugin, which is plugin-wide and would take the
    observation panel with it."""
    _, opened = shown(plugin, dialog)

    assert opened["closable"] is True


def test_the_window_is_fixed_up_the_way_the_panel_is(plugin, dialog):
    """Lightroom makes every window it creates this way topmost and ownerless,
    so without this it floats over every other application."""
    plugin.set_platform(windows=True)

    _, opened = shown(plugin, dialog)
    plugin.run_pending_tasks()

    assert any(opened["title"] in command
               for command in plugin.executed_commands), \
        "the z-order helper was never asked about this window"


# ---------------------------------------------------------------------------
# Copying
# ---------------------------------------------------------------------------


def props_of(plugin):
    table = plugin.runtime.table_from({})
    table["status"] = ""
    return table


def test_copying_one_rank_puts_that_rank_on_the_clipboard(plugin, dialog):
    plugin.set_platform(windows=True)
    props = props_of(plugin)

    assert plugin.in_task(dialog.copy, props, "Animalia", "kingdom") is True
    assert "'Animalia'" in plugin.executed_commands[-1]
    assert props["status"] == "Copied kingdom."


def test_a_copy_is_reported_in_the_dialog_not_in_another_dialog(plugin, dialog):
    """A dialog on top of a dialog to acknowledge a copy is worse than the copy
    was good."""
    plugin.set_platform(windows=True)
    props = props_of(plugin)

    plugin.in_task(dialog.copy, props, "Animalia", "kingdom")

    assert plugin.modal_dialogs == []


def test_a_failed_copy_is_reported_not_raised(plugin, dialog):
    plugin.set_platform(windows=True)
    plugin.set_execute_exit_code(1)
    props = props_of(plugin)

    assert plugin.in_task(dialog.copy, props, "Animalia", "kingdom") is False
    assert "Could not copy kingdom" in props["status"]


def test_copying_nothing_runs_nothing(plugin, dialog):
    props = props_of(plugin)

    assert plugin.in_task(dialog.copy, props, "", "kingdom") is False
    assert plugin.executed_commands == []


def test_copy_all_takes_the_whole_lineage(plugin, dialog):
    """One button for the common case, so the whole tree can go into a note
    without four clicks and four pastes."""
    plugin.set_platform(windows=True)

    result, opened = shown(plugin, dialog)

    assert result is True

    press(plugin, opened, "Copy All")

    command = plugin.executed_commands[-1]
    assert "'Kingdom\tAnimalia'" in command
    assert "'Species\tIschnura erratica'" in command
    assert "\n" not in command, "a newline in a command line is a second command"


def test_copy_all_is_reported_in_the_window(plugin, dialog):
    plugin.set_platform(windows=True)

    _, opened = shown(plugin, dialog)
    press(plugin, opened, "Copy All")

    assert plugin.modal_dialogs == [], \
        "a dialog to acknowledge a copy is worse than the copy was good"


# ---------------------------------------------------------------------------
# The shape of it
# ---------------------------------------------------------------------------


def rank_rows(contents):
    """The lineage rows, in order, as [spacer, label, name, Copy]."""
    rows = []
    for row in of_type(contents, "row"):
        label = row[2]
        if label is None or label["_viewType"] != "static_text":
            continue
        if not isinstance(label["title"], str) or not label["title"].endswith(":"):
            continue
        rows.append(row)
    return rows


def test_the_rank_labels_are_left_aligned(plugin, dialog):
    """They were right-aligned, which made a staircase out of the different
    lengths of "Kingdom" and "Subclass" -- raggedness that carried no meaning
    and read as centring."""
    _, opened = shown(plugin, dialog)

    alignments = [row[2]["alignment"] for row in rank_rows(opened["contents"])]

    assert alignments == ["left"] * 4


def test_each_rank_steps_one_further_right_than_the_one_above(plugin, dialog):
    """A lineage is a descent. A flush-left list of eight ranks reads as eight
    unrelated facts."""
    _, opened = shown(plugin, dialog)

    indents = [row[1]["width"] for row in rank_rows(opened["contents"])]
    step = indents[1]

    assert step > 0, "no indent at all is the flush-left list this replaced"
    assert indents == [0, step, step * 2, step * 3]


def test_the_indent_is_a_spacer_rather_than_spaces(plugin, dialog):
    """Two reasons, and the second is the one the user asked for: the label
    column is a fixed width, so padding "Subspecies" would simply truncate it;
    and nothing indented this way can reach the clipboard."""
    _, opened = shown(plugin, dialog)

    for row in rank_rows(opened["contents"]):
        assert row[1]["_viewType"] == "spacer"
        assert not row[2]["title"].startswith(" ")
        assert not row[3]["title"].startswith(" ")


def test_the_copy_buttons_stay_in_one_straight_column(plugin, dialog):
    """The name column gives back exactly what the indent takes. Otherwise the
    buttons would run away to the right in their own staircase -- the same
    accident the right-aligned labels were."""
    _, opened = shown(plugin, dialog)

    reach = [row[1]["width"] + row[3]["width"]
             for row in rank_rows(opened["contents"])]

    assert len(set(reach)) == 1, f"the Copy buttons drift: {reach}"


def test_the_button_row_does_not_sit_on_the_frame(plugin, dialog):
    """The window hugs its contents. Every other row has one below it to
    breathe against; this one has the bottom of the window."""
    _, opened = shown(plugin, dialog)

    column = opened["contents"]
    positions = [k for k in column.keys() if isinstance(k, int)]
    last = column[max(positions)]

    assert last["_viewType"] == "spacer"
    assert last["height"] > 0


# ---------------------------------------------------------------------------
# Closing
# ---------------------------------------------------------------------------


def test_there_is_a_close_button_on_windows(plugin, dialog):
    """A window of this shape reads as a dialog, and a dialog is expected to
    have one. The close box still works and does the same thing."""
    plugin.set_platform(windows=True)

    _, opened = shown(plugin, dialog)

    assert [b for b in of_type(opened["contents"], "push_button")
            if b["title"] == "Close"]


def test_there_is_no_close_button_where_it_could_not_work(plugin, dialog):
    """The helper behind it is Win32. A button that silently does nothing is
    worse than no button, and the close box is still there."""
    plugin.set_platform(windows=False)

    _, opened = shown(plugin, dialog)

    assert not [b for b in of_type(opened["contents"], "push_button")
                if b["title"] == "Close"]


def test_close_asks_the_window_manager_about_this_window_only(plugin, dialog):
    """closeFloatingDialogsForPlugin is the only programmatic close the SDK
    has and it is plugin-wide -- it would take the observation panel with it.
    That is not a Close button, it is a trapdoor."""
    plugin.set_platform(windows=True)

    _, opened = shown(plugin, dialog)
    press(plugin, opened, "Close")

    assert f'-Title "{opened["title"]}"' in plugin.executed_commands[-1]
    assert "close_window.ps1" in plugin.executed_commands[-1]
    assert not any("closeFloatingDialogs" in command
                   for command in plugin.executed_commands)


def test_a_close_that_does_not_land_says_so(plugin, dialog):
    """Rather than a dialog on top of the window the user was trying to be rid
    of, the status line beside the button says to use the close box."""
    plugin.set_platform(windows=True)

    _, opened = shown(plugin, dialog)
    plugin.set_execute_exit_code(1)
    press(plugin, opened, "Close")

    assert plugin.modal_dialogs == []


# ---------------------------------------------------------------------------
# The window that stays open
# ---------------------------------------------------------------------------


def settings(plugin):
    return plugin.require("Settings")


def allow_multiple(plugin, value):
    settings(plugin)["set"]("taxonomy_multiple_windows", value)


def presented(plugin, dialog, rows=None, heading="Ischnura erratica"):
    """Press Taxonomy… -- whichever window the preference asks for."""
    rows = lineage(plugin) if rows is None else rows
    result = plugin.in_task(dialog.present, None, rows, heading)
    return result, plugin.floating_dialogs[-1] if plugin.floating_dialogs else None


def ladder(contents):
    """The slot rows of the single window, in order."""
    rows = []
    for row in of_type(contents, "row"):
        if row[2] is None or row[2]["_viewType"] != "static_text":
            continue
        title = row[2]["title"]
        if not hasattr(title, "keys"):
            continue
        if not str(title["__bind"]).startswith("rowLabel"):
            continue
        rows.append(row)
    return rows


def slots(props, prefix, count):
    return [props[f"{prefix}{slot}"] for slot in range(1, count + 1)]


def long_lineage(plugin, depth):
    core = plugin.require("PanelCore")
    ancestors = [{"id": step, "name": f"Rung{step}", "rank": "genus"}
                 for step in range(1, depth)]
    return core["taxonomyRows"](deep(plugin, {
        "id": depth, "name": "Leaf", "rank": "species", "ancestors": ancestors,
    }))


def another_lineage(plugin):
    return plugin.require("PanelCore")["taxonomyRows"](deep(plugin, {
        "id": 47219, "name": "Apis mellifera", "rank": "species",
        "ancestors": [{"id": 1, "name": "Animalia", "rank": "kingdom"}],
    }))


def test_one_window_is_the_default(plugin, dialog):
    """Clicking down a list of suggestions is the way the panel is used, and a
    window per click means a press of the button and a window to close for
    every row."""
    _, opened = presented(plugin, dialog)

    assert opened["id"] == dialog["SINGLE_ID"]
    assert opened["title"] == dialog["SINGLE_TITLE"]


def test_the_preference_brings_the_per_taxon_windows_back(plugin, dialog):
    """Two lineages side by side is how anyone decides between two
    suggestions, and that needs two windows."""
    allow_multiple(plugin, True)

    _, opened = presented(plugin, dialog)

    assert opened["id"] != dialog["SINGLE_ID"]
    assert "Ischnura erratica" in opened["title"]


def test_the_one_window_remembers_where_it_was_put(plugin, dialog):
    """The objection to save_frame is that every per-taxon window would share
    one rectangle and open on top of the last. There is only ever one of
    these."""
    _, opened = presented(plugin, dialog)

    assert opened["save_frame"] == dialog["SINGLE_FRAME"]


def test_the_taxon_is_named_inside_the_window(plugin, dialog):
    """The title bar cannot carry it: it is fixed when the window is built, it
    outlives any one taxon, and it is what the Win32 helpers find the window
    by."""
    _, opened = presented(plugin, dialog)

    headings = [v for v in of_type(opened["contents"], "static_text")
                if hasattr(v["title"], "keys")
                and v["title"]["__bind"] == "heading"]

    assert len(headings) == 1
    assert opened["contents"]["bind_to_object"]["heading"] == "Ischnura erratica"


def test_the_window_is_built_as_a_fixed_ladder(plugin, dialog):
    """A presented view tree cannot grow a row, so a window that outlives the
    lineage it was opened for has to be built for the deepest one it will ever
    be asked to show."""
    _, opened = presented(plugin, dialog)

    assert len(ladder(opened["contents"])) == dialog["SLOTS"]


def test_the_rungs_past_the_lineage_are_left_empty(plugin, dialog):
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")
    props = state["props"]
    count = dialog["SLOTS"]

    assert slots(props, "rowLabel", count)[:4] == \
        ["Kingdom:", "Class:", "Genus:", "Species:"]
    assert slots(props, "rowLabel", count)[4:] == [""] * (count - 4)
    assert slots(props, "rowUsed", count)[4:] == [False] * (count - 4)
    assert slots(props, "rowCopy", count)[4:] == [""] * (count - 4)


def test_a_shorter_lineage_clears_the_rungs_the_last_one_reached(plugin, dialog):
    """Otherwise the tail of the previous taxon stays on screen below the new
    one and reads as part of it."""
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")
    shorter = plugin.require("PanelCore")["taxonomyRows"](deep(plugin, {
        "id": 1, "name": "Animalia", "rank": "kingdom",
    }))

    dialog.refresh(shorter, "Animalia")

    count = dialog["SLOTS"]
    assert slots(state["props"], "rowLabel", count)[:2] == ["Kingdom:", ""]
    assert state["props"]["heading"] == "Animalia"


def test_a_lineage_deeper_than_the_ladder_keeps_its_finest_ranks(plugin, dialog):
    """Trimming the other end would drop the species and leave the window
    describing something nobody chose."""
    count = dialog["SLOTS"]
    kept = dialog.visibleRows(long_lineage(plugin, count + 4))

    assert len(kept) == count
    assert kept[count]["name"] == "Leaf"


def test_the_open_window_follows_the_panel(plugin, dialog):
    """The whole point of one window: it keeps up with the species guess
    without the button being pressed again."""
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    assert dialog.refresh(another_lineage(plugin)) is True
    assert state["props"]["heading"] == "Apis mellifera"
    assert state["props"]["rowLabel2"] == "Species:"


def test_a_refresh_does_not_bring_the_window_forward(plugin, dialog):
    """A refresh is something the user did not ask for. Stealing focus from
    the panel they are clicking in would be."""
    plugin.set_platform(windows=True)
    dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    dialog.refresh(another_lineage(plugin))
    plugin.run_pending_tasks()

    assert not any("raise_window.ps1" in command
                   for command in plugin.executed_commands)


def test_an_unresolved_guess_leaves_the_last_lineage_up(plugin, dialog):
    """The panel clears its taxonomy between one suggestion and the next, and
    while a typed name is unresolved. Blanking the window at each of those
    moments would make it flicker through empty."""
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    assert dialog.refresh(deep(plugin, [])) is False
    assert state["props"]["heading"] == "Ischnura erratica"
    assert state["props"]["rowLabel1"] == "Kingdom:"


def test_a_refresh_with_no_window_opens_nothing(plugin, dialog):
    """Choosing a suggestion must not pop up a window nobody asked for."""
    assert dialog.refresh(lineage(plugin)) is False
    assert plugin.floating_dialogs == []


def test_pressing_the_button_again_raises_the_window_it_already_opened(
        plugin, dialog):
    plugin.set_platform(windows=True)
    dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    assert plugin.in_task(dialog.showSingle, None, lineage(plugin),
                          "Ischnura erratica") is True
    plugin.run_pending_tasks()

    assert plugin.floating_dialogs == [], "a second window was opened"
    assert any("raise_window.ps1" in command
               for command in plugin.executed_commands)


def test_pressing_the_button_again_also_refills_it(plugin, dialog):
    """Pressing Taxonomy… on a different guess has to show that guess, even
    though the window it raises is the one already up."""
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    plugin.in_task(dialog.showSingle, None, another_lineage(plugin),
                   "Apis mellifera")

    assert state["props"]["heading"] == "Apis mellifera"


def test_the_copy_buttons_follow_the_refresh(plugin, dialog):
    """They are built once and the window outlives the lineage, so they act on
    what it is showing now rather than on what it was opened with."""
    plugin.set_platform(windows=True)
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    dialog.refresh(another_lineage(plugin))
    state["actions"]["copyRow"](2)
    plugin.run_pending_tasks()

    assert "'Apis mellifera'" in plugin.executed_commands[-1]


def test_copying_an_empty_rung_runs_nothing(plugin, dialog):
    plugin.set_platform(windows=True)
    state = dialog.singleWindow(None, lineage(plugin), "Ischnura erratica")

    state["actions"]["copyRow"](dialog["SLOTS"])
    plugin.run_pending_tasks()

    assert plugin.executed_commands == []


def test_an_empty_lineage_opens_no_single_window(plugin, dialog):
    assert plugin.in_task(dialog.showSingle, None, deep(plugin, []), "") is False
    assert plugin.floating_dialogs == []


def test_the_one_window_is_fixed_up_the_way_the_panel_is(plugin, dialog):
    plugin.set_platform(windows=True)

    presented(plugin, dialog)
    plugin.run_pending_tasks()

    assert any("fix_window_z_order.ps1" in command
               and dialog["SINGLE_TITLE"] in command
               for command in plugin.executed_commands)


def test_every_copy_button_is_built_the_same_width(plugin, dialog):
    """A push_button measures itself against the title it holds when the
    window is built, and these are bound. A slot that was empty then is a box
    built for "" -- so the first deeper lineage to reach it shows a clipped
    button, on the species row, which is the one row nobody wants clipped."""
    _, opened = presented(plugin, dialog)

    widths = {row[4]["width"] for row in ladder(opened["contents"])}

    assert len(widths) == 1
    assert widths.pop() > 0


def test_the_one_window_does_not_sit_against_its_frame(plugin, dialog):
    """It is built once and never resized, so a row that reaches the edge
    stays there."""
    _, opened = presented(plugin, dialog)

    assert opened["contents"]["margin_horizontal"] > 0


def test_closing_the_one_window_lets_the_next_press_build_another(
        plugin, dialog):
    """Otherwise a refresh writes into a property table nothing is drawing,
    and the next press raises a window that is not there."""
    _, opened = presented(plugin, dialog)
    opened["windowWillClose"]()

    assert dialog["single"] is None
    assert dialog.refresh(lineage(plugin)) is False
