"""Tests for where the plugin lives in Lightroom: tagsets, URLs, the manifest.

Lightroom Classic has no SDK hook for adding a panel to the Library right panel
stack -- the shipped binaries recognise no such Info.lua key -- so this plugin
appears there in two places: the Metadata panel via a preset, which can hold
data and nothing else, and the Publish Services list, which is where the
actions are.

That arrangement has failure modes the host will not report: a tagset naming a
field that does not exist, a field defined but shown nowhere, or a lightroom://
URL whose plugin ID has drifted from LrToolkitIdentifier. All of them leave the
plugin quietly wrong rather than raising, so they are asserted here.
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


def metadata_fields(plugin) -> dict:
    return {
        field["id"]: field
        for field in lua_list(
            plugin.require("CustomMetadata")["metadataFieldsForPhotos"]
        )
    }


# ---------------------------------------------------------------------------
# Plugin URLs
# ---------------------------------------------------------------------------


def test_plugin_urls_use_the_toolkit_identifier(plugin):
    """Lightroom routes lightroom:// by plugin ID; a drifted ID goes nowhere.

    This matters more than it used to. The same mechanism will carry the OAuth
    authorization code back from iNaturalist, and a redirect that lands
    nowhere is a sign-in that hangs with no way to tell why.
    """
    urls = plugin.require("PluginUrls")
    info = plugin.require("Info")

    assert urls["PLUGIN_ID"] == info["LrToolkitIdentifier"]
    assert urls["urlFor"]("sync") == f"lightroom://{TOOLKIT_ID}/sync"


@pytest.mark.parametrize("action", ["sync", "link", "authorization-redirect"])
def test_a_plugin_url_parses_back_to_its_action(plugin, action):
    urls = plugin.require("PluginUrls")

    assert urls["parse"](urls["urlFor"](action)) == action


def test_a_query_string_does_not_become_part_of_the_action(plugin):
    """The OAuth redirect arrives as .../authorization-redirect?code=..., so
    without this the action name would never match a handler."""
    urls = plugin.require("PluginUrls")

    assert urls["parse"](urls["urlFor"]("sync") + "?photo=42") == "sync"


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
    urls = plugin.require("PluginUrls")

    assert urls["parse"](url) is None


def test_parse_survives_a_non_string(plugin):
    urls = plugin.require("PluginUrls")

    assert urls["parse"](None) is None


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
    urls = plugin.require("PluginUrls")

    assert urls["parseObservationId"](pasted) == "12345"


@pytest.mark.parametrize("pasted", ["", "   ", "not a number", "obs 12 and 34", None])
def test_unusable_input_is_rejected_rather_than_guessed(plugin, pasted):
    """Storing a wrong ID fails later, during a sync, a long way from here."""
    urls = plugin.require("PluginUrls")

    assert urls["parseObservationId"](pasted) is None


# ---------------------------------------------------------------------------
# Tagsets
# ---------------------------------------------------------------------------

TAGSETS = ["TagsetInat"]


def declared_field_ids(plugin) -> set[str]:
    return set(metadata_fields(plugin))


def field_items(plugin, module) -> list[str]:
    """The tagset's field references, without its heading rows.

    An item is either a field ID string or a table -- com.adobe.separator and
    com.adobe.label rows are structure, not data, and the checks below are all
    about whether a named field is real.
    """
    return [item for item in lua_list(plugin.require(module)["items"])
            if isinstance(item, str)]


@pytest.mark.parametrize("module", TAGSETS)
def test_every_plugin_field_in_a_tagset_actually_exists(plugin, module):
    """A tagset naming a missing field breaks the panel without an error."""
    declared = declared_field_ids(plugin)
    prefix = TOOLKIT_ID + "."

    for item in field_items(plugin, module):
        if item.startswith(prefix):
            assert item[len(prefix):] in declared, f"{module} references {item}"


@pytest.mark.parametrize("module", TAGSETS)
def test_tagset_items_are_namespaced(plugin, module):
    """A bare field ID silently resolves to nothing; it needs the plugin ID."""
    for item in field_items(plugin, module):
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
    for item in field_items(plugin, module):
        if item.startswith("com.adobe."):
            assert item in BUILT_IN_TAGSET_ITEMS, f"{module} uses {item}"


def test_the_tagsets_have_distinct_ids(plugin):
    ids = [plugin.require(module)["id"] for module in TAGSETS]

    assert len(set(ids)) == len(ids)


@pytest.mark.parametrize("module", TAGSETS)
def test_the_only_url_field_shown_is_one_we_always_fill_in(plugin, module):
    """Lightroom draws a "Go to URL" arrow on every url field and fires it even
    when the field is empty -- on Windows that opens Explorer. So a url row is
    only safe for a field that either holds a real URL or is not shown at all.

    This is the guard against reintroducing the action rows that used to live
    here: they were url fields holding lightroom:// links, and on a photo that
    had never been published they were live buttons that did the wrong thing.
    """
    fields = metadata_fields(plugin)
    prefix = TOOLKIT_ID + "."

    for item in field_items(plugin, module):
        if not item.startswith(prefix):
            continue
        field = fields[item[len(prefix):]]
        if field["dataType"] == "url":
            assert field["id"] == "inat_observation_url", (
                f"{field['id']} is a url row; its arrow will fire even when empty"
            )


@pytest.mark.parametrize("module", TAGSETS)
def test_every_metadata_field_is_reachable_from_a_tagset(plugin, module):
    """A field defined but in no preset is invisible: the plugin's own presets
    are the only place its fields appear, so anything missing here is data the
    user has no way to see."""
    items = set(field_items(plugin, module))

    for field_id in declared_field_ids(plugin):
        assert TOOLKIT_ID + "." + field_id in items, f"{field_id} is not shown"


# ---------------------------------------------------------------------------
# Metadata schema
# ---------------------------------------------------------------------------


def test_synced_fields_are_read_only(plugin):
    """They mirror iNaturalist state; an edit would be silently overwritten by
    the next sync, which is worse than not being editable."""
    fields = metadata_fields(plugin)

    for field_id in ("inat_taxon_name", "inat_common_name", "inat_taxon_id",
                     "inat_quality_grade", "inat_last_synced",
                     "inat_observation_url", "inat_observation_uuid"):
        assert fields[field_id]["readOnly"] is True, field_id


def test_every_field_is_read_only(plugin):
    """The floating panel is the only way to change anything, so a field you can
    type into here is a promise the plugin cannot keep.

    Two of these used to be editable and both were traps. Editing
    inat_species_guess wrote a string to the catalog and nothing else --
    iNaturalist ignores species_guess once an observation has a taxon, so it was
    saved, uploaded and silently discarded. Editing inat_observation_id let a
    pasted ID land on a whole selection at once with nothing to confirm it.
    """
    fields = metadata_fields(plugin)

    for field_id, field in fields.items():
        assert field["readOnly"] is True, f"{field_id} is editable"


def test_the_species_guess_stays_separate_from_the_synced_taxon(plugin):
    """One field says what was sent, the other says what the community decided.
    Merging them would mean a sync silently rewrote the record of what this
    plugin claimed."""
    fields = metadata_fields(plugin)

    assert "inat_species_guess" in fields
    assert "inat_taxon_name" in fields


def test_the_panel_tells_you_where_the_controls_are(plugin):
    """A panel of greyed-out fields with no explanation reads as broken rather
    than deliberate."""
    items = lua_list(plugin.require("TagsetInat")["items"])
    labels = [i["label"] for i in items
              if not isinstance(i, str) and i["formatter"] == "com.adobe.label"]

    assert labels, "no heading row"
    assert any("Plug-in Extras" in label for label in labels)


def test_a_bumped_schema_version_brings_a_migration_hook(plugin):
    """Lightroom calls this when a catalog carries an older schema; missing it
    turns a version bump into a load-time failure."""
    metadata = plugin.require("CustomMetadata")

    assert metadata["schemaVersion"] >= 3
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
    urls = plugin.require("PluginUrls")

    handler["URLHandler"](urls["urlFor"]("nonsense"))

    assert "Unknown action" in plugin.dialogs[-1]["message"]


@pytest.mark.parametrize("action", ["sync", "link"])
def test_a_known_action_dispatches_work(plugin, action):
    """Asserting only "no unknown-action dialog" would pass for a handler that
    silently did nothing, so this also checks the click reached a task. The
    task is left queued deliberately: running it would need more of Lightroom
    than the stubs provide.
    """
    handler = plugin.require("URLHandler")
    urls = plugin.require("PluginUrls")

    handler["URLHandler"](urls["urlFor"](action))

    assert plugin.dialogs == [], "the action fell through to the unknown branch"
    assert plugin.pending_tasks == 1, "the action dispatched no work"


# ---------------------------------------------------------------------------
# Info.lua wiring
# ---------------------------------------------------------------------------


def test_info_registers_the_tagset_and_url_handler(plugin):
    info = plugin.require("Info")

    assert set(lua_list(info["LrMetadataTagsetFactory"])) == {"TagsetInat.lua"}
    assert info["URLHandler"] == "URLHandler.lua"


def test_the_menu_items_hang_off_the_file_menu(plugin):
    """`Library.lrmodule` hangs one shared "Plug-in Extras" submenu off three
    parents, selected by which Info.lua key you declare: LrExportMenuItems is
    File, LrLibraryMenuItems is Library, LrHelpMenuItems is Help. The key name
    is a lie -- LrExportMenuItems has nothing to do with exporting, and this
    plugin has no export target at all. File is the right parent because the
    Library menu only exists in the Library module, while both items open
    floating windows that work from any module."""
    info = plugin.require("Info")

    assert info["LrExportMenuItems"] is not None
    assert info["LrLibraryMenuItems"] is None
    assert info["LrHelpMenuItems"] is None


def test_no_user_facing_string_points_at_the_wrong_menu(plugin):
    """Directions to a menu are a fact about Info.lua duplicated in prose, and
    prose does not get updated when a key changes. Three of these strings were
    already stale before this test existed -- two still named a "Set Up
    Credentials" item that had been gone for two redesigns."""
    from pathlib import Path

    plugin_dir = Path(__file__).resolve().parent.parent / "plugin" / "pinned.lrplugin"
    for path in sorted(plugin_dir.glob("*.lua")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "Plug-in Extras" not in line:
                continue
            assert "Library >" not in line, f"{path.name}:{number} {line.strip()}"
            assert "Set Up Credentials" not in line, f"{path.name}:{number} {line.strip()}"


def test_the_menu_only_opens_things(plugin):
    """The menu is not where features live -- the floating panel is, because it
    is in front of the user while they work. A menu item earns its place only by
    being the way to reach something that is not currently on screen: settings,
    which you need before anything works, and the panel, which can be closed."""
    info = plugin.require("Info")
    items = lua_list(info["LrExportMenuItems"])

    permanent = [item for item in items if not str(item["id"]).endswith("_probe")]
    assert len(permanent) == 2
    files = {item["file"] for item in permanent}
    assert files == {"ObservationPanelMenu.lua", "SettingsMenu.lua"}


def test_every_probe_menu_item_says_it_is_temporary(plugin):
    """Host probes exist because some things can only be established in the
    running application, and they are supposed to leave once they have. The
    thing that actually gets forgotten is not the file, it is the menu item --
    so the title has to admit what it is while it is still there."""
    info = plugin.require("Info")
    items = lua_list(info["LrExportMenuItems"])

    for item in items:
        if str(item["id"]).endswith("_probe"):
            assert "temporary" in str(item["title"]).lower(), item["title"]


def test_the_panel_menu_item_comes_first(plugin):
    """It is the one people will reach for repeatedly; settings is a
    once-per-install errand."""
    info = plugin.require("Info")
    items = lua_list(info["LrExportMenuItems"])
    assert items[0]["file"] == "ObservationPanelMenu.lua"


def test_the_plugin_offers_no_export_or_publish_target(plugin):
    """LrExportServiceProvider is one key doing two jobs: it is what puts
    iNaturalist in the Publish Services list AND what puts it in the Export
    dialog's target popup. The panel is the only way in now, so the key has to
    be absent -- leaving it would quietly restore both.

    Not to be confused with LrExportMenuItems, which the plugin does declare;
    despite the name that one only means "the File menu"."""
    info = plugin.require("Info")

    assert info["LrExportServiceProvider"] is None


def test_menu_scripts_are_never_required_by_other_modules():
    """Lightroom runs a menu-item script on load, so requiring one from a
    module performs its action as a side effect. This is how a sync used to be
    unreachable from anywhere but the menu."""
    from pathlib import Path

    plugin_dir = Path(__file__).resolve().parent.parent / "plugin" / "pinned.lrplugin"
    declared = {
        item["file"]
        for item in lua_list(LuaPlugin().require("Info")["LrExportMenuItems"])
    }
    menu_scripts = {Path(name).stem for name in declared}

    for path in plugin_dir.glob("*.lua"):
        if path.stem in menu_scripts:
            continue
        source = path.read_text(encoding="utf-8")
        for script in menu_scripts:
            assert f'require "{script}"' not in source, f"{path.name} requires {script}"
