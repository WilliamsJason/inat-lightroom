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
        options = {"folder": "/tmp/inat-test"}
        if prefs:
            options["settings"] = plugin.runtime.table_from(prefs)
        return render["settingsFor"](plugin.runtime.table_from(options))

    return build


# --- where the files go ---------------------------------------------------
#
# The first attempt used export_destinationType = "tempFolder" and the host
# refused it: "export settings are missing the LR_export_destinationPathPrefix".
# Lightroom resolves anything that is not specificFolder or chooseLater through
# getStandardFilePath, which returns nil for "tempFolder". The real tempFolder
# support lives behind an export service provider declaring
# exportToTemporaryLocation -- and this plugin deliberately has no provider.


def test_it_exports_through_the_plain_file_provider(settings):
    assert settings()["LR_exportServiceProvider"] == "com.adobe.ag.export.file"


def test_it_names_a_specific_folder(settings):
    # Not "tempFolder": that needs a provider this plugin does not have, and
    # Lightroom rejects the export outright.
    assert settings()["LR_export_destinationType"] == "specificFolder"


def test_the_folder_is_the_one_it_was_given(settings):
    # Lightroom asserts this is a string. A nil here is the exact failure the
    # first version of this file shipped with.
    assert settings()["LR_export_destinationPathPrefix"] == "/tmp/inat-test"


def test_it_does_not_invent_a_subfolder(settings):
    # The caller deletes the folder it was given. A subfolder underneath it
    # would still be deleted, but the returned paths would not be where the
    # caller expects to find them.
    assert settings()["LR_export_useSubfolder"] is False


def test_the_temp_folder_is_created_before_anything_renders(plugin, render):
    folder = render["makeTempFolder"]()

    assert folder in plugin.created_directories


def test_each_render_gets_its_own_folder(plugin, render):
    # Two panels, or a sync and an upload, can render at once. Sharing one
    # folder means cleanup after the first deletes the second's files.
    first = render["makeTempFolder"]()
    second = render["makeTempFolder"]()

    assert first != second


def test_the_temp_folder_is_under_the_system_temp_directory(plugin, render):
    # Anywhere else and the plugin is leaving files in a place the operating
    # system will never clean up if the plugin's own cleanup is missed.
    assert render["makeTempFolder"]().startswith("/tmp/")


def test_rendering_reports_the_folder_so_the_caller_can_clean_up(plugin, render):
    _, _, folder = render["render"](photos(plugin, 1))

    assert folder
    assert folder in plugin.created_directories


def test_a_caller_can_supply_its_own_folder(plugin, render):
    _, _, folder = render["render"](
        photos(plugin, 1), plugin.runtime.table_from({"folder": "/tmp/mine"}))

    assert folder == "/tmp/mine"
    assert plugin.export_sessions[0]["settings"][
        "LR_export_destinationPathPrefix"] == "/tmp/mine"


# --- cleaning up ----------------------------------------------------------


def test_cleaning_up_deletes_the_folder(plugin, render):
    render["cleanUp"]("/tmp/inat-test")

    assert plugin.deleted_paths == ["/tmp/inat-test"]


def test_cleaning_up_nothing_deletes_nothing(plugin, render):
    # render() returns a nil folder when there was nothing to render, and that
    # nil goes straight back into cleanUp. Without a guard the delete still
    # happens, fails, and is reported as a problem -- so the absence of a
    # complaint is the thing worth asserting.
    render["cleanUp"](None)

    assert plugin.deleted_paths == []
    assert not [line for line in plugin.log_lines if "Could not remove" in line]


def test_a_failed_cleanup_does_not_raise(plugin, render):
    # A locked file must not turn a successful upload into an error. By the
    # time this runs the observation already exists on iNaturalist.
    plugin.set_delete_fails()

    assert render["cleanUp"]("/tmp/inat-test") is False


def test_a_failed_cleanup_is_logged(plugin, render):
    plugin.set_delete_fails()

    render["cleanUp"]("/tmp/inat-test")

    assert any("/tmp/inat-test" in line for line in plugin.log_lines)


def test_a_suggestion_render_cleans_up_after_itself(plugin, render):
    # Unlike an upload, nothing needs the file after the question is answered.
    _, _, folder = render["renderForSuggestions"](plugin.new_photo())

    render["cleanUp"](folder)
    assert plugin.deleted_paths


def test_a_failed_suggestion_render_still_cleans_up(plugin, render):
    # The folder was created before the render was attempted, so an early
    # return leaks it.
    plugin.set_render_failure("Disk full")

    render["renderForSuggestions"](plugin.new_photo())

    assert plugin.deleted_paths


# --- what actually leaves the machine -------------------------------------


def test_nothing_is_reimported_into_the_catalog(settings):
    # reimportExportedPhoto would add a duplicate of every uploaded photo back
    # into the user's catalog, as a JPEG beside their raw file.
    assert settings()["LR_reimportExportedPhoto"] is False


def test_nothing_is_opened_or_revealed_afterwards(settings):
    # Lightroom's own presets ship with revealInFinder. A file browser opening
    # on a temp folder in the middle of an upload is not what was asked for.
    assert settings()["LR_export_postProcessing"] == "doNothing"


def test_a_name_collision_renames_rather_than_asking(settings):
    # "ask" is Lightroom's default and stops the render dead with a dialog.
    # Two selected photos can collide -- DSC0001.ARW and DSC0001.JPG both
    # become DSC0001.jpg -- and overwriting would silently drop one of the
    # observation's photos.
    assert settings()["LR_collisionHandling"] == "rename"


def test_videos_are_left_out(settings):
    # Nothing here renders a video, and one passed through as if it were an
    # image fails later at upload, where the message makes no sense.
    assert settings()["LR_includeVideoFiles"] is False


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
    rendered, failures, _ = render["render"](plugin.runtime.table_from([]))

    assert len(list(rendered.values())) == 0
    assert len(list(failures.values())) == 0
    assert plugin.export_sessions == []


def test_it_returns_a_path_for_each_photo(plugin, render):
    rendered, failures, _ = render["render"](photos(plugin, 2))

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

    rendered, _, _ = render["render"](plugin.runtime.table_from(originals))

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

    rendered, failures, _ = render["render"](photos(plugin, 1))

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
    path, err, _ = render["renderForSuggestions"](plugin.new_photo())

    assert err is None
    assert path.endswith(".jpg")


def test_a_failed_suggestion_render_reports_why(plugin, render):
    plugin.set_render_failure("Disk full")

    path, err, _ = render["renderForSuggestions"](plugin.new_photo())

    assert path is None
    assert err == "Disk full"


def test_a_failed_suggestion_render_always_gives_some_reason(plugin, render):
    # Lightroom does not promise a message. tostring(nil) is the string "nil",
    # which is what the panel would then show the user.
    plugin.set_render_failure()

    path, err, _ = render["renderForSuggestions"](plugin.new_photo())

    assert path is None
    assert err == render["FAILED_MESSAGE"]


def test_a_reasonless_failure_is_reported_as_a_sentence_not_as_nil(plugin, render):
    plugin.set_render_failure()

    _, failures, _ = render["render"](photos(plugin, 1))

    assert list(failures.values()) == [render["FAILED_MESSAGE"]]


def test_a_reasonless_failure_is_logged_as_a_sentence(plugin, render):
    plugin.set_render_failure()

    render["render"](photos(plugin, 1))

    assert not any("nil" in line for line in plugin.log_lines)
    assert any(render["FAILED_MESSAGE"] in line for line in plugin.log_lines)


def test_a_render_that_yields_nothing_at_all_still_reports_a_reason(plugin, render):
    # No renditions means nothing failed, so there is no message to pass on --
    # but the caller still cannot proceed and has to be told why.
    path, err, _ = render["renderForSuggestions"](None)

    assert path is None
    assert err == render["FAILED_MESSAGE"]
