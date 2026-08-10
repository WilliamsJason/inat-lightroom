"""RenderPhoto: turning catalog photos into JPEGs without an export provider.

Every assertion here is about a string Lightroom will silently ignore if it is
wrong. A misspelled settings key does not raise -- it produces a file that
uploads perfectly and is not what the user asked for, and the only place that
becomes visible is iNaturalist, after the fact.
"""

from __future__ import annotations

import pytest

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def render(plugin):
    module = plugin.require("RenderPhoto")
    return module


@pytest.fixture
def settings(plugin, render):
    """Ask for the export settings, optionally with preferences applied."""

    def build(**prefs):
        options = {}
        if prefs:
            options["settings"] = plugin.runtime.table_from(prefs)
        return render["settingsFor"](plugin.runtime.table_from(options))

    return build


# --- the settings that decide what actually leaves the machine ------------


def test_it_exports_through_the_plain_file_provider(settings):
    # com.adobe.ag.export.file is the only provider that declares
    # canExportToTemporaryLocation, which is what tempFolder needs.
    assert settings()["LR_exportServiceProvider"] == "com.adobe.ag.export.file"


def test_it_renders_into_lightrooms_temp_folder(settings):
    # Anything else writes files into the user's pictures folder as a side
    # effect of asking iNaturalist a question.
    assert settings()["LR_export_destinationType"] == "tempFolder"


def test_it_renders_jpeg(settings):
    assert settings()["LR_format"] == "JPEG"


def test_jpeg_quality_is_a_fraction_not_a_percentage(settings):
    # Lightroom takes 0..1 here. Passing 90 does not error; it clamps, and the
    # user gets a maximum-quality file several times larger than intended.
    quality = settings()["LR_jpeg_quality"]
    assert 0 < quality <= 1
    assert quality == pytest.approx(0.9)


def test_it_constrains_the_long_edge_to_what_inaturalist_displays(settings):
    result = settings()
    assert result["LR_size_doConstrain"] is True
    assert result["LR_size_maxWidth"] == 2048
    assert result["LR_size_maxHeight"] == 2048
    assert result["LR_size_resizeType"] == "longEdge"


def test_it_never_enlarges_a_small_photo(settings):
    # Upscaling to hit 2048 invents detail, and the computer vision is being
    # asked to identify what is in the photo.
    assert settings()["LR_size_doNotEnlarge"] is True


def test_keywords_go_up_flat(settings):
    # This plugin writes the community's taxonomy back into Lightroom as a
    # keyword hierarchy. Exporting that hierarchy would send iNaturalist its
    # own identification back as though the user had made it.
    assert settings()["LR_metadata_keywordOptions"] == "flat"


def test_a_smaller_render_can_be_asked_for(plugin, render):
    result = render["settingsFor"](plugin.runtime.table_from({"maxPixels": 1024}))
    assert result["LR_size_maxWidth"] == 1024
    assert result["LR_size_maxHeight"] == 1024


# --- the preferences the settings dialog owns ----------------------------


def test_location_is_kept_in_the_file_by_default(settings):
    # An observation without a location is close to worthless to iNaturalist.
    # Hiding a location is geoprivacy's job, not the renderer's.
    assert settings()["LR_removeLocationMetadata"] is False


def test_location_can_be_stripped_when_the_user_asks(settings):
    assert settings(render_remove_location=True)["LR_removeLocationMetadata"] is True


def test_the_watermark_is_off_and_carries_no_id(settings):
    result = settings()
    assert result["LR_useWatermark"] is False
    assert result["LR_watermarking_id"] is None


def test_turning_the_watermark_on_names_the_built_in_one(settings):
    # No plugin can enumerate the user's own watermark presets: watermarkPresets
    # appears in no binary in the product. Turning the setting on without
    # naming one would render nothing at all.
    result = settings(render_use_watermark=True)
    assert result["LR_useWatermark"] is True
    assert result["LR_watermarking_id"] == "<simpleCopyrightWatermark>"


def test_the_metadata_option_is_passed_through(settings):
    result = settings(render_metadata_option="copyrightOnly")
    assert result["LR_embeddedMetadataOption"] == "copyrightOnly"


def test_all_metadata_is_sent_when_the_user_has_not_chosen(settings):
    assert settings()["LR_embeddedMetadataOption"] == "all"


def test_every_settings_key_is_prefixed_for_the_sdk(settings):
    # Lightroom's remapSdkSettingsTableToInternal strips LR_ on the way in. A
    # key without it is not recognised and is dropped without complaint.
    for key in settings().keys():
        assert str(key).startswith("LR_"), key


# --- rendering -----------------------------------------------------------


def photos(plugin, count):
    return plugin.runtime.table_from(
        [plugin.new_photo() for _ in range(count)]
    )


def test_rendering_nothing_is_not_an_error(plugin, render):
    rendered, failures = render["render"](plugin.runtime.table_from([]))

    assert len(list(rendered.values())) == 0
    assert len(list(failures.values())) == 0
    assert plugin.export_sessions == []


def test_it_returns_a_path_for_each_photo(plugin, render):
    rendered, failures = render["render"](photos(plugin, 2))

    assert len(list(failures.values())) == 0
    paths = [entry["path"] for entry in rendered.values()]
    assert len(paths) == 2
    assert all(path.endswith(".jpg") for path in paths)


def test_each_result_carries_the_photo_it_came_from(plugin, render):
    # The upload has to know which catalog photo a file belongs to, or it
    # writes the observation link onto the wrong one.
    originals = [
        plugin.new_photo(inat_observation_id="first"),
        plugin.new_photo(inat_observation_id="second"),
    ]

    rendered, _ = render["render"](plugin.runtime.table_from(originals))

    # Compared by a value on the photo rather than by identity: the bridge
    # hands out a fresh proxy object each time, so two references to one Lua
    # table are never the same Python object.
    came_from = [
        entry["photo"]["getPropertyForPlugin"](
            entry["photo"], None, "inat_observation_id")
        for entry in rendered.values()
    ]
    assert came_from == ["first", "second"]


def test_asking_for_renditions_is_what_starts_the_export(plugin, render):
    # renditions() runs startRendering itself. If this stopped being true the
    # renderer would hang waiting for work nobody had asked for.
    render["render"](photos(plugin, 1))

    assert plugin.export_sessions[0]["started"] is True


def test_a_failed_render_is_reported_not_returned_as_a_path(plugin, render):
    # waitForRender puts the failure message in the same slot as the path, so
    # ignoring the success flag yields a "path" that is an error string.
    plugin.set_render_failure("Disk full")

    rendered, failures = render["render"](photos(plugin, 1))

    assert len(list(rendered.values())) == 0
    assert list(failures.values()) == ["Disk full"]


def test_a_failed_render_is_logged(plugin, render):
    plugin.set_render_failure("Disk full")

    render["render"](photos(plugin, 1))

    assert any("Disk full" in line for line in plugin.log_lines)


# --- the suggestions render ----------------------------------------------


def test_a_suggestion_render_is_smaller_than_an_upload(plugin, render):
    # It is uploaded, asked a question and thrown away. Sending 2048 px costs
    # the user's bandwidth for an answer that does not change.
    render["renderForSuggestions"](plugin.new_photo())

    settings_used = plugin.export_sessions[0]["settings"]
    assert settings_used["LR_size_maxWidth"] == 1024


def test_a_suggestion_render_returns_one_path(plugin, render):
    path, err = render["renderForSuggestions"](plugin.new_photo())

    assert err is None
    assert path.endswith(".jpg")


def test_a_failed_suggestion_render_reports_why(plugin, render):
    plugin.set_render_failure("Disk full")

    path, err = render["renderForSuggestions"](plugin.new_photo())

    assert path is None
    assert err == "Disk full"


def test_a_failed_suggestion_render_always_gives_some_reason(plugin, render):
    # Lightroom does not promise a message. tostring(nil) is the string "nil",
    # which is what the panel would then show the user.
    plugin.set_render_failure()

    path, err = render["renderForSuggestions"](plugin.new_photo())

    assert path is None
    assert err == render["FAILED_MESSAGE"]


def test_a_reasonless_failure_is_reported_as_a_sentence_not_as_nil(plugin, render):
    plugin.set_render_failure()

    _, failures = render["render"](photos(plugin, 1))

    assert list(failures.values()) == [render["FAILED_MESSAGE"]]


def test_a_reasonless_failure_is_logged_as_a_sentence(plugin, render):
    plugin.set_render_failure()

    render["render"](photos(plugin, 1))

    assert not any("nil" in line for line in plugin.log_lines)
    assert any(render["FAILED_MESSAGE"] in line for line in plugin.log_lines)


def test_a_render_that_yields_nothing_at_all_still_reports_a_reason(plugin, render):
    # No renditions means nothing failed, so there is no message to pass on --
    # but the caller still cannot proceed and has to be told why.
    path, err = render["renderForSuggestions"](None)

    assert path is None
    assert err == render["FAILED_MESSAGE"]
