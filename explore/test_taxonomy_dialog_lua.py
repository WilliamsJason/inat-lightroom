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

    assert "Ischnura (Forktails)" in texts


def test_the_name_column_truncates_rather_than_dropping_a_word(plugin, dialog):
    """Without `truncation` the documented behaviour is to drop the last word
    silently, which reads as a shorter name rather than a cut-off one."""
    _, opened = shown(plugin, dialog)

    names = [v for v in of_type(opened["contents"], "static_text")
             if v["title"] == "Ischnura (Forktails)"]

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
    """Its own close box is the only way out: closeFloatingDialogsForPlugin is
    plugin-wide and would take the observation panel with it."""
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
