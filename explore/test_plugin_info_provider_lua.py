"""Tests for the Plug-in Manager's Updates section.

Two kinds of test live here.

The first covers `initialise`, `runCheck` and `runInstall` -- the logic behind
the buttons, which is ordinary and testable.

The second covers the *shape* of the view, which normally would not be worth
asserting. It is here because of a specific bug. The section rendered with
"Installed version:" and the status line both blank, while every literal label
and the checkbox looked perfectly correct.

The cause was a missing `bind_to_object`. A binding inside a Plug-in Manager
section does not fall back to the property table the provider is handed; it
falls back to the plugin's preferences. So `LrView.bind("status")` looked up a
preference named "status", found nothing, and rendered empty -- while
`LrView.bind("update_check_automatically")` found a real preference of that
name and appeared to work, reading and writing the wrong table.

That is the worst kind of failure: silent, and partially disguised by a control
that looks right. Nothing in the Lua raises, so only the shape of the view can
catch it.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

import lupa.lua51 as lupa51  # noqa: E402

from lua_harness import LuaPlugin  # noqa: E402


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def provider(plugin):
    return plugin.require("PluginInfoProvider")


def props(plugin, **overrides):
    return plugin.runtime.table_from(dict(overrides))


PLUGIN_PATH = "/plugins/inat.lrplugin"


# ---------------------------------------------------------------------------
# Walking the view
# ---------------------------------------------------------------------------


def is_table(value):
    return lupa51.lua_type(value) == "table"


def walk(node, bound_by=None, found=None):
    """Every binding in the tree, paired with the table it will resolve against.

    `bound_by` carries the nearest enclosing `bind_to_object` downwards, which
    is how Lightroom itself resolves a binding.
    """
    found = [] if found is None else found

    if not is_table(node):
        return found

    if node["bind_to_object"] is not None:
        bound_by = node["bind_to_object"]

    if node["__bind"] is not None:
        found.append((node["__bind"], bound_by))
        return found

    for _, value in node.items():
        walk(value, bound_by, found)

    return found


def section(plugin, provider, property_table):
    sections = provider["sectionsForTopOfDialog"](
        plugin.view_factory(), property_table)
    return sections[1]


def bindings(plugin, provider, property_table):
    return walk(section(plugin, provider, property_table))


def bound_keys(binding):
    """The preference-or-property names a single binding depends on."""
    if isinstance(binding, str):
        return [binding]

    if binding["key"] is not None:
        return [binding["key"]]

    if binding["keys"] is not None:
        return list(binding["keys"].values())

    return []


# ---------------------------------------------------------------------------
# What the section starts out saying
# ---------------------------------------------------------------------------


def test_the_installed_version_is_shown(plugin, provider):
    p = props(plugin)
    provider["initialise"](p, PLUGIN_PATH)

    assert p["installedVersion"] == "0.1.0", (
        "The Plug-in Manager should show the version from Info.lua. Reading it "
        "is the one thing this section must do even with no network."
    )


def test_the_section_says_nothing_has_been_checked_yet(plugin, provider):
    p = props(plugin)
    provider["initialise"](p, PLUGIN_PATH)

    assert p["staged"] is False
    assert "Not checked" in p["status"]


def test_a_staged_update_is_reported_before_any_check(plugin, provider):
    """Someone who already clicked Install needs telling to restart."""
    install = plugin.require("UpdateInstall")
    install["fs"] = plugin.eval("""
      {
        exists   = function(path) return _FILES[path] ~= nil end,
        readFile = function(path) return _FILES[path] end,
      }
    """.replace("_FILES", "({" + ", ".join([
        f'["{PLUGIN_PATH}/.update-staging/READY"] = "v9.9.9"',
        f'["{PLUGIN_PATH}/.update-staging/inat.lrplugin"] = "dir"',
    ]) + "})"))

    p = props(plugin)
    provider["initialise"](p, PLUGIN_PATH)

    assert p["staged"] is True
    assert "v9.9.9" in p["status"]
    assert "restart" in p["status"].lower()


def test_installing_without_checking_first_explains_itself(plugin, provider):
    p = props(plugin)
    provider["initialise"](p, PLUGIN_PATH)

    assert provider["runInstall"](p) is False
    assert "nothing to install" in p["status"].lower()


# ---------------------------------------------------------------------------
# The bug: bindings that resolve against nothing
# ---------------------------------------------------------------------------


def test_the_section_binds_to_the_property_table_it_was_given(plugin, provider):
    """Without this, every bound field silently reads the preferences instead."""
    p = props(plugin)
    found = bindings(plugin, provider, p)

    assert found, "the section has no bindings at all, which cannot be right"

    for binding, bound_by in found:
        assert bound_by is not None, (
            f"{bound_keys(binding)} is bound, but nothing in its enclosing "
            "views sets bind_to_object. Lightroom will resolve it against the "
            "plugin's preferences, so it renders blank -- or worse, silently "
            "reads and writes a preference that happens to share the name."
        )


def test_every_bound_field_resolves_against_the_real_property_table(
        plugin, provider):
    """Binding to *a* table is not enough; it has to be the one being written."""
    p = props(plugin)
    found = bindings(plugin, provider, p)

    # After the view exists, so that initialise() -- which runs while the
    # section is built -- cannot overwrite the sentinel.
    p["installedVersion"] = "1.2.3"

    for binding, bound_by in found:
        assert bound_by["installedVersion"] == "1.2.3", (
            f"{bound_keys(binding)} resolves against some table other than the "
            "one initialise() and runCheck() write to, so the display will "
            "never update."
        )


def test_the_version_and_status_are_both_bound(plugin, provider):
    """The two fields that were blank in Lightroom."""
    keys = set()
    for binding, _ in bindings(plugin, provider, props(plugin)):
        keys.update(bound_keys(binding))

    assert "installedVersion" in keys
    assert "status" in keys


def test_the_automatic_check_box_is_bound_to_the_property_table(
        plugin, provider):
    """It looked correct while bound to the wrong table, purely by coincidence.

    `update_check_automatically` is a real preference name, so a binding that
    fell through to the preferences still showed the right tick. Then endDialog
    would write the stale property back over whatever was clicked.
    """
    p = props(plugin)
    provider["startDialog"](p)

    matches = [
        bound_by for binding, bound_by in bindings(plugin, provider, p)
        if "update_check_automatically" in bound_keys(binding)
    ]

    assert matches, "the checkbox is not bound to anything"

    for bound_by in matches:
        assert bound_by["update_check_automatically"] is not None, (
            "the checkbox resolves against a table that startDialog never "
            "populated, which is the preferences rather than the property table"
        )


# ---------------------------------------------------------------------------
# The preference round trip
# ---------------------------------------------------------------------------


def test_the_automatic_check_preference_is_loaded_into_the_dialog(
        plugin, provider):
    settings = plugin.require("Settings")
    settings["set"]("update_check_automatically", False)

    p = props(plugin)
    provider["startDialog"](p)

    assert p["update_check_automatically"] is False


def test_turning_automatic_checks_off_is_saved_when_the_dialog_closes(
        plugin, provider):
    settings = plugin.require("Settings")

    p = props(plugin, update_check_automatically=False)
    provider["endDialog"](p)

    assert settings["get"]("update_check_automatically") is False, (
        "The Plug-in Manager has no OK button for a plugin's own section, so a "
        "preference not written on close is a preference thrown away."
    )
