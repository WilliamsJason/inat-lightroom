"""Tests for the Library-panel surface: tagsets, action links, URL handling.

Lightroom Classic has no SDK hook for adding a panel to the Library right panel
stack -- the shipped binaries recognise no such Info.lua key -- so this plugin's
presence there is the Metadata panel plus two presets, and its only "buttons"
are custom metadata fields of dataType "url" holding lightroom:// links that
route back through URLHandler.lua.

That arrangement has one failure mode the host will not report: a tagset naming
a field that does not exist, or an action URL whose plugin ID has drifted from
LrToolkitIdentifier. Both leave the panel quietly wrong rather than raising, so
they are asserted here.

What these tests cannot answer is whether Lightroom routes a click on a
metadata URL into the plugin's URLHandler at all. That needs the host.
"""

from __future__ import annotations

import pytest

from lua_harness import LuaPlugin

TOOLKIT_ID = "com.github.inat-lightroom"


def lua_list(table) -> list:
    """A Lua array as a Python list."""
    return [table[i] for i in range(1, len(table) + 1)]


@pytest.fixture
def plugin():
    return LuaPlugin()


# ---------------------------------------------------------------------------
# Action URLs
# ---------------------------------------------------------------------------


def test_action_urls_use_the_toolkit_identifier(plugin):
    """Lightroom routes lightroom:// by plugin ID; a drifted ID goes nowhere."""
    actions = plugin.require("PanelActions")
    info = plugin.require("Info")

    assert actions["PLUGIN_ID"] == info["LrToolkitIdentifier"]
    assert actions["urlFor"]("sync") == f"lightroom://{TOOLKIT_ID}/sync"


def test_an_action_url_parses_back_to_its_action(plugin):
    actions = plugin.require("PanelActions")

    for entry in lua_list(actions["FIELDS"]):
        url = actions["urlFor"](entry["action"])
        assert actions["parse"](url) == entry["action"]


def test_a_query_string_does_not_become_part_of_the_action(plugin):
    actions = plugin.require("PanelActions")
    url = actions["urlFor"]("sync") + "?photo=42"

    assert actions["parse"](url) == "sync"


@pytest.mark.parametrize(
    "url",
    [
        "https://www.inaturalist.org/observations/999",
        "lightroom://com.adobe.lightroom.export.flickr/sync",
        "lightroom://com.github.inat-lightroom",
        "",
    ],
)
def test_urls_that_are_not_ours_are_rejected(plugin, url):
    """The handler is offered every lightroom:// URL, not only ours."""
    actions = plugin.require("PanelActions")

    assert actions["parse"](url) is None


def test_parse_survives_a_non_string(plugin):
    actions = plugin.require("PanelActions")

    assert actions["parse"](None) is None


# ---------------------------------------------------------------------------
# Reading a pasted observation ID
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "pasted",
    [
        "12345",
        "  12345  ",
        "https://www.inaturalist.org/observations/12345",
        "https://www.inaturalist.org/observations/12345/",
        "https://www.inaturalist.org/observations/12345?foo=1",
        "inaturalist.org/observations/12345",
    ],
)
def test_an_observation_id_is_read_from_whatever_was_pasted(plugin, pasted):
    """People copy the URL out of the browser far more often than the number."""
    actions = plugin.require("PanelActions")

    assert actions["parseObservationId"](pasted) == "12345"


@pytest.mark.parametrize("pasted", ["", "   ", "not a number", "obs 12 and 34", None])
def test_unusable_input_is_rejected_rather_than_guessed(plugin, pasted):
    """Storing a wrong ID fails later, during a sync, a long way from here."""
    actions = plugin.require("PanelActions")

    assert actions["parseObservationId"](pasted) is None


# ---------------------------------------------------------------------------
# Arming photos
# ---------------------------------------------------------------------------


def test_arming_a_photo_fills_every_action_field(plugin):
    """A metadata field has no default, so a blank field renders no link."""
    actions = plugin.require("PanelActions")
    photo = plugin.new_photo()

    actions["armPhotos"](plugin.catalog, plugin.runtime.table_from([photo]))

    props = photo["_props"]
    for entry in lua_list(actions["FIELDS"]):
        assert props[entry["field"]] == actions["urlFor"](entry["action"])


def test_arming_opens_a_write_transaction(plugin):
    """setPropertyForPlugin outside withWriteAccessDo is an error in the SDK."""
    actions = plugin.require("PanelActions")

    actions["armPhotos"](plugin.catalog, plugin.runtime.table_from([plugin.new_photo()]))

    assert plugin.catalog_writes == ["iNat panel actions"]


def test_arming_nothing_is_not_an_empty_transaction(plugin):
    actions = plugin.require("PanelActions")

    assert actions["armPhotos"](plugin.catalog, plugin.runtime.table_from([])) == 0
    assert plugin.catalog_writes == []


# ---------------------------------------------------------------------------
# Tagsets
# ---------------------------------------------------------------------------

TAGSETS = ["TagsetInat", "TagsetInatCombined"]


def declared_field_ids(plugin) -> set[str]:
    fields = plugin.require("CustomMetadata")["metadataFieldsForPhotos"]
    return {field["id"] for field in lua_list(fields)}


@pytest.mark.parametrize("module", TAGSETS)
def test_every_plugin_field_in_a_tagset_actually_exists(plugin, module):
    """A tagset naming a missing field breaks the panel without an error."""
    declared = declared_field_ids(plugin)
    prefix = TOOLKIT_ID + "."

    for item in lua_list(plugin.require(module)["items"]):
        if item.startswith(prefix):
            assert item[len(prefix):] in declared, f"{module} references {item}"


@pytest.mark.parametrize("module", TAGSETS)
def test_tagset_items_are_namespaced(plugin, module):
    """A bare field ID silently resolves to nothing; it needs the plugin ID."""
    for item in lua_list(plugin.require(module)["items"]):
        assert item.startswith("com.adobe.") or item.startswith(TOOLKIT_ID + ".")


# Every ID Lightroom's own built-in tagsets use, read out of the compiled
# AgMetadataTagsets.lua inside LibraryToolkit.dll (see docs/lightroom-sdk-notes.md).
#
# This list exists because a tagset naming an ID Lightroom does not accept
# misbehaves without raising, and the plausible-looking names are the dangerous
# ones: "com.adobe.label" is a section-heading formatter rather than the colour
# label, and "com.adobe.keywords" is not a tagset item at all.
BUILT_IN_TAGSET_ITEMS = {
    "com.adobe.artist",
    "com.adobe.audioAnnotation",
    "com.adobe.brightnessValue",
    "com.adobe.captureDate",
    "com.adobe.captureTime",
    "com.adobe.caption",
    "com.adobe.colorLabels",
    "com.adobe.combinedCameraName",
    "com.adobe.commonPhotoSettings",
    "com.adobe.copyname",
    "com.adobe.copyright",
    "com.adobe.copyrightState",
    "com.adobe.creator",
    "com.adobe.dateTime",
    "com.adobe.dateTimeDigitized",
    "com.adobe.dateTimeOriginal",
    "com.adobe.duration.combined.optional",
    "com.adobe.exposure",
    "com.adobe.exposureBiasValue",
    "com.adobe.exposureProgram",
    "com.adobe.filename",
    "com.adobe.filepath",
    "com.adobe.flash",
    "com.adobe.focalLength",
    "com.adobe.focalLength35mm",
    "com.adobe.folder",
    "com.adobe.GPS",
    "com.adobe.GPSAltitude",
    "com.adobe.GPSImgDirection",
    "com.adobe.imageCroppedDimensions",
    "com.adobe.imageFileDimensions",
    "com.adobe.ISOSpeedRating",
    "com.adobe.lens",
    "com.adobe.location",
    "com.adobe.make",
    "com.adobe.metadataStatus",
    "com.adobe.meteringMode",
    "com.adobe.model",
    "com.adobe.preservedFilename",
    "com.adobe.rating",
    "com.adobe.separator",
    "com.adobe.serialNumber",
    "com.adobe.sidecars",
    "com.adobe.software",
    "com.adobe.title",
    "com.adobe.userComment",
}


@pytest.mark.parametrize("module", TAGSETS)
def test_built_in_fields_are_ones_lightroom_itself_uses(plugin, module):
    """Presence of a com.adobe.* string in the binaries does not make it a valid
    tagset item. Lightroom's own tagsets are the authority."""
    for item in lua_list(plugin.require(module)["items"]):
        if item.startswith("com.adobe."):
            assert item in BUILT_IN_TAGSET_ITEMS, f"{module} uses {item}"


def test_the_tagsets_have_distinct_ids(plugin):
    ids = [plugin.require(module)["id"] for module in TAGSETS]

    assert len(set(ids)) == len(ids)


def test_both_tagsets_offer_the_actions(plugin):
    """The actions are the reason to look at the panel at all."""
    actions = lua_list(plugin.require("PanelActions")["FIELDS"])
    wanted = {TOOLKIT_ID + "." + entry["field"] for entry in actions}

    for module in TAGSETS:
        items = set(lua_list(plugin.require(module)["items"]))
        assert wanted <= items, f"{module} is missing action rows"


def test_the_combined_tagset_keeps_the_everyday_lightroom_fields(plugin):
    """The iNat-only preset costs the user their normal metadata view, so the
    combined one has to be usable as a permanent replacement for Default."""
    items = set(lua_list(plugin.require("TagsetInatCombined")["items"]))

    for field in ("com.adobe.filename", "com.adobe.rating",
                  "com.adobe.caption", "com.adobe.colorLabels",
                  "com.adobe.dateTimeOriginal"):
        assert field in items


# ---------------------------------------------------------------------------
# Metadata schema
# ---------------------------------------------------------------------------


def test_action_fields_are_urls(plugin):
    """dataType 'url' is what makes the Metadata panel render a clickable row.
    Anything else and the action is unreachable text."""
    fields = {
        field["id"]: field
        for field in lua_list(
            plugin.require("CustomMetadata")["metadataFieldsForPhotos"]
        )
    }

    for entry in lua_list(plugin.require("PanelActions")["FIELDS"]):
        assert fields[entry["field"]]["dataType"] == "url"


def test_synced_fields_are_read_only(plugin):
    """They mirror iNaturalist state; an edit would be silently overwritten by
    the next sync, which is worse than not being editable."""
    fields = {
        field["id"]: field
        for field in lua_list(
            plugin.require("CustomMetadata")["metadataFieldsForPhotos"]
        )
    }

    for field_id in ("inat_taxon_name", "inat_common_name", "inat_taxon_id",
                     "inat_quality_grade", "inat_last_synced",
                     "inat_observation_url"):
        assert fields[field_id]["readOnly"] is True, field_id


def test_the_observation_id_stays_editable(plugin):
    """Pasting an ID is how a photo adopts an observation made elsewhere."""
    fields = {
        field["id"]: field
        for field in lua_list(
            plugin.require("CustomMetadata")["metadataFieldsForPhotos"]
        )
    }

    assert fields["inat_observation_id"]["readOnly"] is False


def test_a_bumped_schema_version_brings_a_migration_hook(plugin):
    """Lightroom calls this when a catalog carries an older schema; missing it
    turns a version bump into a load-time failure."""
    metadata = plugin.require("CustomMetadata")

    assert metadata["schemaVersion"] >= 2
    assert metadata["updateFromEarlierSchemaVersion"] is not None


# ---------------------------------------------------------------------------
# URL handler wiring
# ---------------------------------------------------------------------------


def test_the_url_handler_matches_the_sdk_contract(plugin):
    """Adobe's own Flickr plugin returns { URLHandler = function(url) }; a bare
    function or a differently named key is never called."""
    handler = plugin.require("URLHandler")

    assert handler["URLHandler"] is not None


def test_a_foreign_url_is_ignored_rather_than_acted_on(plugin):
    handler = plugin.require("URLHandler")

    handler["URLHandler"]("https://example.com/whatever")

    assert plugin.dialogs == []


def test_an_unknown_action_reports_instead_of_failing_silently(plugin):
    handler = plugin.require("URLHandler")
    actions = plugin.require("PanelActions")

    handler["URLHandler"](actions["urlFor"]("nonsense"))

    assert "Unknown action" in plugin.dialogs[-1]["message"]


def test_every_action_field_has_a_handler(plugin):
    """A link with no handler behind it is a dead row in the panel.

    Asserting only "no unknown-action dialog" would pass for a handler that
    silently did nothing, so this also checks each click actually dispatched
    work. The tasks are left queued deliberately: running them would need more
    of Lightroom than the stubs provide.
    """
    handler = plugin.require("URLHandler")
    actions = plugin.require("PanelActions")
    entries = lua_list(actions["FIELDS"])

    for entry in entries:
        handler["URLHandler"](actions["urlFor"](entry["action"]))

    assert plugin.dialogs == [], "an action fell through to the unknown branch"
    assert plugin.pending_tasks == len(entries), "an action dispatched no work"


# ---------------------------------------------------------------------------
# Info.lua wiring
# ---------------------------------------------------------------------------


def test_info_registers_the_tagsets_and_url_handler(plugin):
    info = plugin.require("Info")

    assert set(lua_list(info["LrMetadataTagsetFactory"])) == {
        "TagsetInat.lua",
        "TagsetInatCombined.lua",
    }
    assert info["URLHandler"] == "URLHandler.lua"


def test_the_menu_is_a_single_entry(plugin):
    """Everything else moved into the Metadata panel; what remains is the one
    thing the panel cannot bootstrap for itself."""
    info = plugin.require("Info")

    assert len(lua_list(info["LrLibraryMenuItems"])) == 1


def test_menu_scripts_are_never_required_by_other_modules():
    """Lightroom runs a menu-item script on load, so requiring one from a
    module performs its action as a side effect. This is how a sync used to be
    unreachable from anywhere but the menu."""
    from pathlib import Path

    plugin_dir = Path(__file__).resolve().parent.parent / "plugin" / "inat.lrplugin"
    menu_scripts = {"SyncObservation", "PluginInit", "InatMenu"}

    for path in plugin_dir.glob("*.lua"):
        if path.stem in menu_scripts:
            continue
        source = path.read_text(encoding="utf-8")
        for script in menu_scripts:
            assert f'require "{script}"' not in source, f"{path.name} requires {script}"
