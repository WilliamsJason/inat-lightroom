"""Tests for ExportServiceProvider.lua helpers, under Lightroom's Lua 5.1.

Written after an export failed with:

    attempt to index local 'firstRendition' (a number value)

renditions() is a Lua iterator. Calling it directly returns the first values
the iterator yields, which begin with the loop index -- so the code took a
number and tried to read .photo off it. It only surfaced at upload time,
after the user had already filled in the whole export panel.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def internals():
    plugin = LuaPlugin()
    provider = plugin.require("ExportServiceProvider")
    return plugin, provider["_internal"]


def make_session(plugin: LuaPlugin, photo_names: list[str], *, style: str):
    """Build a fake LrExportSession whose iterators behave like Lightroom's.

    Lightroom yields (index, value) pairs, which is exactly what tripped the
    original bug, so the stub must do the same.
    """
    builder = plugin.eval(
        """
        function(names, style)
          local photos = {}
          for i = 1, #names do
            photos[i] = {
              name = names[i],
              getRawMetadata = function(_self, key)
                if key == "dateTimeOriginal" then return 801234567 end
                return nil
              end,
            }
          end

          local function iterate(wrap)
            return function()
              local i = 0
              return function()
                i = i + 1
                if photos[i] == nil then return nil end
                return i, wrap(photos[i])
              end
            end
          end

          local session = {}
          if style == "photos" or style == "both" then
            session.photosToExport = iterate(function(p) return p end)
          end
          if style == "renditions" or style == "both" then
            session.renditions = iterate(function(p) return { photo = p } end)
          end
          return session
        end
        """
    )
    names = plugin.eval(
        "{" + ",".join(f"'{name}'" for name in photo_names) + "}"
    )
    return builder(names, style)


@pytest.mark.parametrize("style", ["photos", "renditions", "both"])
def test_returns_the_first_photo_not_the_loop_index(internals, style):
    """The reported crash: the iterator's index was mistaken for a rendition."""
    plugin, internal = internals
    session = make_session(plugin, ["one", "two"], style=style)

    photo = internal["firstExportPhoto"](session)

    assert photo is not None, "got nil instead of a photo"
    assert photo["name"] == "one"


def test_returns_nil_for_an_empty_export(internals):
    plugin, internal = internals
    session = make_session(plugin, [], style="both")

    assert internal["firstExportPhoto"](session) is None


def test_survives_a_session_with_neither_iterator(internals):
    """Better a missing date than an exception midway through an export."""
    plugin, internal = internals

    assert internal["firstExportPhoto"](plugin.eval("{}")) is None


def test_panel_date_overrides_the_photo(internals):
    plugin, internal = internals
    session = make_session(plugin, ["one"], style="both")

    assert internal["observedOnFor"](session, "2020-01-01") == "2020-01-01"


def test_falls_back_to_the_first_photos_capture_date(internals):
    plugin, internal = internals
    session = make_session(plugin, ["one"], style="both")

    # The stubbed LrDate formats any timestamp to this.
    assert internal["observedOnFor"](session, "") == "2026-07-29"


def test_no_date_when_there_is_nothing_to_read(internals):
    plugin, internal = internals
    session = make_session(plugin, [], style="both")

    assert internal["observedOnFor"](session, "") is None
