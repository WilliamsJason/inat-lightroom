"""ExportPresets: reading the user's own Lightroom export presets off disk.

There is no SDK call for this. The presets are files, so everything here is
about being right about a file format nobody documented -- and about being
right *without executing it*, since a .lrtemplate is Lua source and the plugin
found it on disk rather than shipping it.

The shape of a preset file, from the machine that was measured:

    s = {
      id = "7FF5B530-660A-44EB-A858-8406C40EDD11",
      internalName = "iNaturalist",
      title = "iNaturalist",
      type = "Export",
      value = { exportServiceProvider = "com.adobe.ag.export.file", ... },
      version = 0,
    }
"""

from __future__ import annotations

import pytest

from lua_harness import LuaPlugin

APPDATA_PRESETS = "/appdata/Export Presets"
APPDATA_WATERMARKS = "/appdata/Watermarks"
# The catalog root the stub catalog's getPath implies.
CATALOG_PRESETS = "/catalogs/Test/Lightroom Settings/Export Presets"

INATURALIST = """s = {
	id = "7FF5B530-660A-44EB-A858-8406C40EDD11",
	internalName = "iNaturalist",
	title = "iNaturalist",
	type = "Export",
	value = {
		exportServiceProvider = "com.adobe.ag.export.file",
		export_destinationPathPrefix = "C:\\\\Users\\\\tester\\\\Pictures",
		export_destinationType = "specificFolder",
		export_postProcessing = "revealInFinder",
		collisionHandling = "ask",
		format = "JPEG",
		jpeg_quality = 0.85,
		export_colorSpace = "sRGB",
		size_doConstrain = true,
		size_maxHeight = 2048,
		size_maxWidth = 1000,
		size_resizeType = "longEdge",
		size_units = "pixels",
		size_doNotEnlarge = true,
		size_resolution = 72,
		outputSharpeningOn = true,
		outputSharpeningLevel = 3,
		outputSharpeningMedia = "screen",
		useWatermark = true,
		watermarking_id = "ECB47E01-C27C-4BD8-B27E-29D8F67AE37C",
		embeddedMetadataOption = "all",
		removeLocationMetadata = false,
		metadata_keywordOptions = "lightroomHierarchical",
		includeVideoFiles = true,
		reimportExportedPhoto = true,
	},
	version = 0,
}"""

FOR_EMAIL = """s = {
	id = "6B2C0D8C-A1DE-4C88-9C0B-53E9E8C5F1A1",
	internalName = "ForEMail",
	title = ZSTR "$$$/AgExport/Preset/ForEMail=For Email",
	type = "Export",
	value = {
		exportServiceProvider = "com.adobe.ag.export.email",
		format = "JPEG",
		size_doConstrain = true,
		size_maxHeight = 500,
		size_maxWidth = 500,
		size_resizeType = "longEdge",
	},
	version = 0,
}"""

WATERMARK = """s = {
	id = "ECB47E01-C27C-4BD8-B27E-29D8F67AE37C",
	internalName = "JasonWilliams",
	title = "JasonWilliams",
	type = "WatermarkingPreset",
	value = {
		watermark_type = "text",
		text = "Jason Williams",
		items = {
			{ anchor = "bottomRight", opacity = 60 },
			{ anchor = "topLeft", opacity = 30 },
		},
	},
	version = 0,
}"""


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def presets(plugin):
    return plugin.require("ExportPresets")


@pytest.fixture
def with_inaturalist(plugin):
    plugin.set_file(APPDATA_PRESETS + "/User Presets/iNaturalist.lrtemplate",
                    INATURALIST)
    return plugin


# --- reading the file ------------------------------------------------------


def test_it_reads_the_top_level_fields(presets):
    parsed = presets["parse"](INATURALIST)

    assert parsed["id"] == "7FF5B530-660A-44EB-A858-8406C40EDD11"
    assert parsed["type"] == "Export"
    assert parsed["value"]["exportServiceProvider"] == "com.adobe.ag.export.file"


def test_it_reads_numbers_and_booleans_as_themselves(presets):
    value = presets["parse"](INATURALIST)["value"]

    # Not strings. These go straight into exportSettings, where Lightroom
    # expects a number and a string of one is not the same thing.
    assert value["size_maxHeight"] == 2048
    assert value["jpeg_quality"] == 0.85
    assert value["size_doNotEnlarge"] is True
    assert value["removeLocationMetadata"] is False


def test_a_zstr_title_keeps_only_what_a_person_should_read(presets):
    parsed = presets["parse"](FOR_EMAIL)

    # ZSTR is a function call in the file, not syntax. Nothing is called here.
    assert parsed["title"] == "$$$/AgExport/Preset/ForEMail=For Email"
    assert presets["displayTitle"](parsed["title"]) == "For Email"


def test_a_plain_title_is_left_alone(presets):
    assert presets["displayTitle"]("iNaturalist") == "iNaturalist"


def test_a_nested_list_of_tables_survives(presets):
    # A watermark preset's items are a list of tables. A flat key = value
    # matcher reads the inner keys as if they were outer ones, which is why
    # the reader is recursive.
    value = presets["parse"](WATERMARK)["value"]

    assert value["items"][1]["anchor"] == "bottomRight"
    assert value["items"][2]["opacity"] == 30


def test_an_escaped_backslash_in_a_windows_path_is_one_backslash(presets):
    value = presets["parse"](INATURALIST)["value"]

    assert value["export_destinationPathPrefix"] == "C:\\Users\\tester\\Pictures"


def test_a_truncated_file_is_refused_rather_than_half_read(presets):
    parsed, reason = presets["parse"](INATURALIST[:200])

    assert parsed is None
    assert "unterminated" in reason


def test_a_file_with_no_table_in_it_is_refused(presets):
    parsed, reason = presets["parse"]("this is not a preset")

    assert parsed is None
    assert reason == "no preset table found"


def test_an_empty_file_is_refused(presets):
    parsed, reason = presets["parse"]("")

    assert parsed is None
    assert reason == "the file is empty"


def test_an_unknown_constructor_costs_its_key_not_the_preset(presets):
    # AgRect(...) and friends appear in Lightroom's own files. One value this
    # reader does not understand is not worth losing the preset over.
    parsed = presets["parse"](
        's = { id = "x", value = { box = AgRect(0, 0, 1, 1), format = "JPEG" } }'
    )

    assert parsed["value"]["format"] == "JPEG"
    assert parsed["id"] == "x"


def test_parsing_agrees_with_executing_the_same_file(plugin, presets):
    """The pattern reader is shipped; the Lua route is kept honest here.

    Both were measured working in the plugin sandbox. The pattern reader was
    chosen because it never hands a file from disk to the interpreter -- but
    "safer" is only worth having if it also reads the same thing, so the two
    are compared on every file this suite uses.
    """
    compare = plugin.runtime.eval("""function(source, parsed)
      -- The host's own route, minus setfenv, which the probe measured as nil
      -- inside a plugin: define ZSTR as a global, run the chunk, read back the
      -- global it assigned.
      local savedS, savedZstr = _G.s, _G.ZSTR
      _G.ZSTR = function(text) return text end
      local chunk = loadstring(source)
      chunk()
      local executed = _G.s
      _G.s, _G.ZSTR = savedS, savedZstr

      local function same(a, b, path)
        if type(a) ~= type(b) then return false, path .. " type" end
        if type(a) ~= "table" then
          if a ~= b then return false, path .. " value" end
          return true
        end
        for key, value in pairs(a) do
          local ok, where = same(value, b[key], path .. "." .. tostring(key))
          if not ok then return false, where end
        end
        for key in pairs(b) do
          if a[key] == nil then return false, path .. "." .. tostring(key) end
        end
        return true
      end

      local ok, where = same(executed, parsed, "s")
      return { ok = ok, where = where or "" }
    end""")
    for source in (INATURALIST, FOR_EMAIL, WATERMARK):
        result = compare(source, presets["parse"](source))
        assert result["ok"], result["where"]


# --- finding the files -----------------------------------------------------


def test_both_preset_roots_are_looked_at(presets):
    # LrPrefs is per-plugin and cannot read AgTemplateBrowser_storePresets-
    # WithCatalog, so the plugin cannot tell which root is in use and reads
    # both rather than guessing.
    roots = list(presets["roots"]("Export Presets").values())

    assert APPDATA_PRESETS in roots
    assert CATALOG_PRESETS in roots


def test_a_preset_beside_the_catalog_is_found_too(plugin, presets):
    plugin.set_file(CATALOG_PRESETS + "/iNaturalist.lrtemplate", INATURALIST)

    found = list(presets["list"]().values())

    assert [preset["title"] for preset in found] == ["iNaturalist"]


def test_a_preset_in_a_user_subfolder_is_found(with_inaturalist, presets):
    # Lightroom puts the user's own presets under "User Presets", and lets
    # them make more folders underneath.
    found = list(presets["list"]().values())

    assert [preset["title"] for preset in found] == ["iNaturalist"]
    assert found[0]["id"] == "7FF5B530-660A-44EB-A858-8406C40EDD11"


def test_the_same_preset_in_both_roots_is_listed_once(plugin, presets):
    plugin.set_file(APPDATA_PRESETS + "/iNaturalist.lrtemplate", INATURALIST)
    plugin.set_file(CATALOG_PRESETS + "/iNaturalist.lrtemplate", INATURALIST)

    assert len(list(presets["list"]().values())) == 1


def test_a_file_that_is_not_a_preset_is_ignored(plugin, presets):
    plugin.set_file(APPDATA_PRESETS + "/notes.txt", INATURALIST)

    assert list(presets["list"]().values()) == []


def test_a_watermark_preset_is_not_an_export_preset(plugin, presets):
    # Both live under the same appData root, one folder apart, and both are
    # .lrtemplate files. The type field is the only thing separating them.
    plugin.set_file(APPDATA_PRESETS + "/JasonWilliams.lrtemplate", WATERMARK)

    assert list(presets["list"]().values()) == []


def test_missing_preset_folders_are_not_an_error(presets):
    # A fresh install, or a machine where the user has never saved a preset.
    assert list(presets["list"]().values()) == []


# --- which presets can actually be used ------------------------------------


def test_a_hard_drive_preset_is_usable(with_inaturalist, presets):
    assert list(presets["list"]().values())[0]["usable"] is True


def test_an_email_preset_is_listed_but_marked_unusable(plugin, presets):
    # Not dropped. A user who cannot find the preset they just made has no way
    # to discover that it is the wrong kind of export, and "it is not listed"
    # is the least informative answer available.
    plugin.set_file(APPDATA_PRESETS + "/ForEmail.lrtemplate", FOR_EMAIL)

    found = list(presets["list"]().values())[0]

    assert found["usable"] is False
    assert "Email" in found["reason"]
    assert "Hard Drive" in found["reason"]


def test_presets_come_back_in_a_predictable_order(plugin, presets):
    plugin.set_file(APPDATA_PRESETS + "/ForEmail.lrtemplate", FOR_EMAIL)
    plugin.set_file(APPDATA_PRESETS + "/iNaturalist.lrtemplate", INATURALIST)

    titles = [p["title"] for p in presets["list"]().values()]

    assert titles == ["For Email", "iNaturalist"]


def test_a_preset_is_found_by_its_id(with_inaturalist, presets):
    found = presets["find"]("7FF5B530-660A-44EB-A858-8406C40EDD11")

    assert found["title"] == "iNaturalist"


def test_an_id_that_matches_nothing_finds_nothing(with_inaturalist, presets):
    assert presets["find"]("no-such-guid") is None


def test_the_no_preset_value_finds_nothing(with_inaturalist, presets):
    # "" is what the popup's first row writes, and it means plugin defaults.
    assert presets["find"](presets["NONE"]) is None


# --- what a preset will actually do ----------------------------------------


def test_long_edge_reads_the_height(presets):
    # Measured: Export.lrmodule's synopsis formats "Resize Long Edge to ^2"
    # against the value list (size_maxWidth, size_maxHeight), so ^2 is the
    # height. The user's own preset holds longEdge/2048 with a stale width of
    # 1000, and the Export dialog shows one box reading 2048.
    size = presets["effectiveSize"](presets["parse"](INATURALIST)["value"])

    assert size["pixels"] == 2048
    assert size["text"] == "2048 px long edge"


def test_a_width_long_edge_mode_ignores_is_called_out(presets):
    size = presets["effectiveSize"](presets["parse"](INATURALIST)["value"])

    # Silently passing the pair through is right for the render, and wrong for
    # the settings dialog: 1000 is exactly the number a user would panic about
    # if the plugin never explained it.
    assert "1000" in size["ignored"]
    assert "ignores" in size["ignored"]


def test_a_matching_pair_says_nothing_about_it(presets):
    size = presets["effectiveSize"](presets["parse"](FOR_EMAIL)["value"])

    assert size["text"] == "500 px long edge"
    assert size["ignored"] is None


def test_an_unconstrained_preset_is_full_size(plugin, presets):
    size = presets["effectiveSize"](plugin.runtime.table_from(
        {"size_doConstrain": False}))

    assert size["text"] == "full size"


def test_width_and_height_mode_reports_both(plugin, presets):
    size = presets["effectiveSize"](plugin.runtime.table_from({
        "size_doConstrain": True,
        "size_resizeType": "wh",
        "size_maxWidth": 1600,
        "size_maxHeight": 1200,
        "size_units": "pixels",
    }))

    assert size["text"] == "1600 x 1200 px"


def test_megapixels_mode_reports_megapixels(plugin, presets):
    size = presets["effectiveSize"](plugin.runtime.table_from({
        "size_doConstrain": True,
        "size_resizeType": "megapixels",
        "size_megapixels": 4,
    }))

    assert "4" in size["text"]
    assert "megapixel" in size["text"]


# --- the watermark that quietly is not there -------------------------------


def test_watermarks_are_read_by_id(plugin, presets):
    plugin.set_file(APPDATA_WATERMARKS + "/JasonWilliams.lrtemplate", WATERMARK)

    found = dict(presets["watermarks"]())

    assert found["ECB47E01-C27C-4BD8-B27E-29D8F67AE37C"] == "JasonWilliams"


def test_a_preset_whose_watermark_exists_has_no_problem(plugin, presets):
    plugin.set_file(APPDATA_WATERMARKS + "/JasonWilliams.lrtemplate", WATERMARK)
    value = presets["parse"](INATURALIST)["value"]

    assert presets["watermarkProblem"](value, presets["watermarks"]()) is None


def test_a_watermark_that_no_longer_exists_is_reported(presets):
    # Measured: a GUID matching no preset renders 557475 bytes, byte-identical
    # to no watermark at all, with no error raised. Someone who chose their
    # preset *for* the watermark would never be told.
    value = presets["parse"](INATURALIST)["value"]

    problem = presets["watermarkProblem"](value, presets["watermarks"]())

    assert "no longer in Lightroom" in problem


def test_a_preset_with_no_watermark_has_no_problem(presets):
    value = presets["parse"](FOR_EMAIL)["value"]

    assert presets["watermarkProblem"](value, presets["watermarks"]()) is None


def test_the_built_in_copyright_watermark_is_called_a_no_op(plugin, presets):
    # Measured: 557475 bytes with and without it on a photo with no copyright,
    # 559988 once a copyright was written. It works; it just draws nothing for
    # anyone who does not set one.
    value = plugin.runtime.table_from({
        "useWatermark": True,
        "watermarking_id": presets["BUILT_IN_WATERMARK"],
    })

    problem = presets["watermarkProblem"](value, presets["watermarks"]())

    assert "copyright" in problem


def test_watermarking_on_with_nothing_named_is_reported(plugin, presets):
    value = plugin.runtime.table_from({"useWatermark": True})

    assert presets["watermarkProblem"](value, None) is not None


# --- turning a preset into export settings ---------------------------------


def test_keys_come_back_with_the_lr_prefix(presets):
    settings = presets["settingsFrom"](presets["parse"](INATURALIST)["value"])

    # The file stores them unprefixed; exportSettings wants LR_.
    assert settings["LR_size_maxHeight"] == 2048
    assert settings["LR_jpeg_quality"] == 0.85
    assert settings["LR_useWatermark"] is True
    assert settings["LR_watermarking_id"] == "ECB47E01-C27C-4BD8-B27E-29D8F67AE37C"


def test_the_resize_mode_travels_with_the_size(presets):
    # Never one without the other: the mode is what decides which of the two
    # size values Lightroom reads.
    settings = presets["settingsFrom"](presets["parse"](INATURALIST)["value"])

    assert settings["LR_size_resizeType"] == "longEdge"
    assert settings["LR_size_maxWidth"] == 1000
    assert settings["LR_size_maxHeight"] == 2048


@pytest.mark.parametrize("key", [
    "LR_exportServiceProvider",
    "LR_export_destinationType",
    "LR_export_destinationPathPrefix",
    "LR_export_postProcessing",
    "LR_collisionHandling",
    "LR_format",
    "LR_includeVideoFiles",
    "LR_reimportExportedPhoto",
    "LR_metadata_keywordOptions",
])
def test_the_keys_that_make_the_render_work_never_come_from_a_preset(presets, key):
    # Every one of these is in the sample preset with a value that would break
    # the upload: revealInFinder in the middle of a render, "ask" halting on a
    # dialog, re-import duplicating every photo into the catalog.
    settings = presets["settingsFrom"](presets["parse"](INATURALIST)["value"])

    assert key not in dict(settings)


def test_the_metadata_options_do_come_from_a_preset(presets):
    # Deliberately not overridden: the point of choosing a preset is to decide
    # the file in one place.
    settings = presets["settingsFrom"](presets["parse"](INATURALIST)["value"])

    assert settings["LR_embeddedMetadataOption"] == "all"
    assert settings["LR_removeLocationMetadata"] is False
