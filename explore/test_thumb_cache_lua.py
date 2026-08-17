"""Tests for ThumbCache.lua -- the iNaturalist side of a review row.

The review list's whole claim is that you can confirm a match by looking at the
two photos. That rests on getting the right image, at a size worth looking at,
without paying for it twice -- and on the failures being invisible rather than
fatal, because a thumbnail that will not download is not a reason to abandon a
review of four hundred matches.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


SQUARE = "https://inaturalist-open-data.s3.amazonaws.com/photos/718149957/square.jpg"
MEDIUM = "https://inaturalist-open-data.s3.amazonaws.com/photos/718149957/medium.jpg"


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def cache_module(plugin):
    return plugin.require("ThumbCache")


def new_cache(plugin, cache_module, folder="/tmp/thumbs", write=None):
    written = {}

    def record(path, bytes_):
        written[path] = bytes_
        return True

    cache = cache_module["new"](plugin.runtime.table_from({
        "folder": folder,
        "placeholder": "/plugins/pinned.lrplugin/no-photo.png",
        "write": write or record,
    }))
    return cache, written


# --------------------------------------------------------------------- sizes

def test_the_square_thumbnail_is_swapped_for_a_bigger_one(plugin, cache_module):
    """75px is too small to tell two frames of the same bird apart, which is
    the only thing the image is there for."""
    assert cache_module["sizedUrl"](SQUARE) == MEDIUM


def test_the_size_is_a_rename_rather_than_another_request(plugin, cache_module):
    """iNaturalist serves every size from the same path, so the bigger file
    needs no lookup to find."""
    assert cache_module["sizedUrl"](SQUARE, "small").endswith("/small.jpg")
    assert cache_module["sizedUrl"](SQUARE, "large").endswith("/large.jpg")


def test_a_png_keeps_its_extension(plugin, cache_module):
    url = "https://static.inaturalist.org/photos/1/square.png"

    assert cache_module["sizedUrl"](url).endswith("/medium.png")


def test_an_unrecognised_url_is_left_alone(plugin, cache_module):
    """Guessing at a URL shape we do not know would turn an API change into a
    wrong image rather than a missing one."""
    assert cache_module["sizedUrl"]("https://example.com/photo") is None
    assert cache_module["sizedUrl"](None) is None
    assert cache_module["sizedUrl"]("") is None


# -------------------------------------------------------------- observations

def test_the_first_photo_is_the_one_shown(plugin, cache_module):
    observation = plugin.runtime.eval("""
      { photos = { { id = 718149957, url = "%s" },
                   { id = 2, url = "https://x/photos/2/square.jpg" } } }
    """ % SQUARE)

    assert cache_module["observationUrl"](observation) == MEDIUM


def test_an_observation_with_no_photos_asks_for_nothing(plugin, cache_module):
    """Sound recordings are observations too, and so is a photo that has since
    been deleted."""
    assert cache_module["observationUrl"](
        plugin.runtime.eval("{ photos = {} }")) is None
    assert cache_module["observationUrl"](plugin.runtime.eval("{}")) is None
    assert cache_module["observationUrl"](None) is None


# ------------------------------------------------------------------ fetching

def test_a_thumbnail_is_downloaded_once(plugin, cache_module):
    """Paging back to re-check a match is the normal way this dialog is used.
    Paying for the download again every time would make it feel broken well
    before it made it slow."""
    calls = []

    def handler(method, url, body, headers):
        calls.append(url)
        return ("bytes", {"status": 200})

    plugin.set_http_handler(handler)
    cache, written = new_cache(plugin, cache_module)

    first = cache["fetch"](cache, MEDIUM)
    second = cache["fetch"](cache, MEDIUM)

    assert calls == [MEDIUM]
    assert first == second
    assert first.endswith("718149957-medium.jpg")


def test_a_failed_download_shows_the_placeholder(plugin, cache_module):
    """A row still needs a file: f:picture is bound before the download and
    stays bound after it fails."""
    plugin.set_http_handler(lambda *a: (None, {"status": 404}))
    cache, written = new_cache(plugin, cache_module)

    assert cache["fetch"](cache, MEDIUM).endswith("no-photo.png")


def test_a_failed_download_is_not_retried(plugin, cache_module):
    """One dead photo would otherwise be re-requested on every page turn."""
    calls = []
    plugin.set_http_handler(
        lambda m, u, b, h: (calls.append(u), (None, {"status": 500}))[1])
    cache, written = new_cache(plugin, cache_module)

    cache["fetch"](cache, MEDIUM)
    cache["fetch"](cache, MEDIUM)

    assert len(calls) == 1


def test_an_observation_with_no_photo_shows_the_placeholder(
        plugin, cache_module):
    cache, written = new_cache(plugin, cache_module)

    assert cache["fetch"](cache, None).endswith("no-photo.png")


def test_the_page_fills_in_as_images_arrive(plugin, cache_module):
    """Twenty-five images appearing together after 2.6 seconds of nothing looks
    like a stall. One at a time looks like loading."""
    plugin.set_http_handler(lambda *a: ("bytes", {"status": 200}))
    cache, written = new_cache(plugin, cache_module)

    ready = []
    cache["fetchAll"](cache,
        plugin.runtime.table_from([SQUARE, MEDIUM]),
        lambda row, path: ready.append(row),
        None)

    assert ready == [1, 2]


def test_leaving_the_page_abandons_the_rest_of_its_downloads(
        plugin, cache_module):
    """Otherwise turning the page twice queues fifty downloads for fifty rows,
    of which twenty-five are already off screen."""
    calls = []
    plugin.set_http_handler(
        lambda m, u, b, h: (calls.append(u), ("bytes", {"status": 200}))[1])
    cache, written = new_cache(plugin, cache_module)

    finished = cache["fetchAll"](cache,
        plugin.runtime.table_from([SQUARE, MEDIUM]),
        None,
        lambda: len(calls) >= 1)

    assert finished is False
    assert len(calls) == 1


def test_a_thumbnail_that_cannot_be_written_shows_the_placeholder(
        plugin, cache_module):
    """A read-only or full temp folder is a whole-run problem, but not one
    worth failing a review of four hundred matches over."""
    plugin.set_http_handler(lambda *a: ("bytes", {"status": 200}))
    cache, _written = new_cache(plugin, cache_module,
                                write=lambda path, data: (False, "denied"))

    assert cache["fetch"](cache, MEDIUM).endswith("no-photo.png")


def test_the_folder_is_made_before_anything_is_written(plugin, cache_module):
    plugin.set_http_handler(lambda *a: ("bytes", {"status": 200}))
    cache, written = new_cache(plugin, cache_module, folder="/tmp/made-here")

    cache["fetchAll"](cache, plugin.runtime.table_from([MEDIUM]), None, None)

    assert "/tmp/made-here" in plugin.created_directories
