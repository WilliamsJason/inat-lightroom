"""Attaching photos to an observation that already exists.

Covers LinkObservation.lua. Publishing can only create new observations, so this
is the only way a photo reaches one made in the field -- and the only way the
second, third and fourth frame of a specimen reach the observation the first one
was uploaded to.
"""

import pytest

from lua_harness import LuaPlugin
from test_panel_core_lua import deep


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def link(plugin):
    return plugin.require("LinkObservation")


def views(node, found=None):
    """Every table in a view tree, flattened."""
    found = [] if found is None else found
    if not hasattr(node, "keys"):
        return found
    found.append(node)
    for key in list(node.keys()):
        child = node[key]
        if hasattr(child, "keys"):
            views(child, found)
    return found


def prompt_text(dialog):
    texts = [
        v["title"]
        for v in views(dialog["contents"])
        if v["_viewType"] == "static_text" and isinstance(v["title"], str)
    ]
    return "\n".join(texts)


def run(plugin, link):
    """Run the link flow the way the panel button does."""
    plugin.call(link.start)
    plugin.run_pending_tasks()


# ---------------------------------------------------------------------------
# Finding an ID already in the selection
# ---------------------------------------------------------------------------


def test_the_first_linked_photo_supplies_the_id(plugin, link):
    photos = [
        plugin.new_photo(),
        plugin.new_photo(inat_observation_id="358074828"),
        plugin.new_photo(inat_observation_id="999"),
    ]
    assert plugin.in_task(link.existingObservationId, deep(plugin, photos)) == "358074828"


def test_a_selection_with_no_links_supplies_nothing(plugin, link):
    photos = [plugin.new_photo(), plugin.new_photo()]
    assert plugin.in_task(link.existingObservationId, deep(plugin, photos)) is None


def test_an_empty_field_does_not_count_as_a_link(plugin, link):
    photos = [
        plugin.new_photo(inat_observation_id=""),
        plugin.new_photo(inat_observation_id="358074828"),
    ]
    assert plugin.in_task(link.existingObservationId, deep(plugin, photos)) == "358074828"


def test_no_photos_at_all_supplies_nothing(plugin, link):
    assert plugin.in_task(link.existingObservationId, None) is None


# ---------------------------------------------------------------------------
# The dialog
# ---------------------------------------------------------------------------


def test_the_dialog_says_which_id_it_filled_in(plugin, link):
    plugin.set_target_photos(
        [plugin.new_photo(), plugin.new_photo(inat_observation_id="358074828")]
    )
    run(plugin, link)

    assert "358074828" in prompt_text(plugin.modal_dialogs[0])


def test_an_unlinked_selection_is_asked_to_paste(plugin, link):
    plugin.set_target_photos([plugin.new_photo(), plugin.new_photo()])
    run(plugin, link)

    assert "Paste the observation ID" in prompt_text(plugin.modal_dialogs[0])


def test_nothing_selected_opens_no_dialog(plugin, link):
    plugin.set_target_photos([])
    run(plugin, link)

    assert plugin.modal_dialogs == []
    assert plugin.dialogs[0]["message"] == "No photos selected."


# ---------------------------------------------------------------------------
# What accepting it does
# ---------------------------------------------------------------------------


def test_accepting_the_prefilled_id_links_the_whole_selection(plugin, link):
    unlinked = plugin.new_photo()
    linked = plugin.new_photo(inat_observation_id="358074828")
    plugin.set_target_photos([unlinked, linked])
    plugin.set_modal_answer("ok")

    run(plugin, link)

    assert unlinked.getPropertyForPlugin(unlinked, None, "inat_observation_id") \
        == "358074828"
    assert linked.getPropertyForPlugin(linked, None, "inat_observation_id") \
        == "358074828"


def test_cancelling_links_nothing(plugin, link):
    unlinked = plugin.new_photo()
    plugin.set_target_photos(
        [unlinked, plugin.new_photo(inat_observation_id="358074828")]
    )
    plugin.set_modal_answer("cancel")

    run(plugin, link)

    assert unlinked.getPropertyForPlugin(unlinked, None, "inat_observation_id") is None
