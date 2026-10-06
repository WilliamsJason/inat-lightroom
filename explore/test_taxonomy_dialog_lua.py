"""The taxonomy dialog -- one rank per row, each with its own Copy button.

Covers TaxonomyDialog.lua. This is a dialog rather than a part of the floating
panel for a reason the SDK forces: the panel's view tree is fixed once
presented and a bound ``visible`` does not hide a row, so a collapsible
taxonomy inside the panel would stand at full height whether collapsed or not.
A dialog is built fresh each time and is exactly as tall as the lineage it was
handed.
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
    return result, plugin.modal_dialogs[-1] if plugin.modal_dialogs else None


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
    assert plugin.modal_dialogs == []


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
    """The action button is Copy All rather than OK, because there is nothing
    here to accept."""
    plugin.set_platform(windows=True)
    plugin.set_modal_answer("ok")

    result, opened = shown(plugin, dialog)

    assert opened["actionVerb"] == "Copy All"
    assert result is True

    command = plugin.executed_commands[-1]
    assert "'Kingdom\tAnimalia'" in command
    assert "'Species\tIschnura erratica'" in command
    assert "\n" not in command, "a newline in a command line is a second command"


def test_closing_copies_nothing(plugin, dialog):
    plugin.set_platform(windows=True)
    plugin.set_modal_answer("cancel")

    result, _ = shown(plugin, dialog)

    assert result is False
    assert plugin.executed_commands == []
