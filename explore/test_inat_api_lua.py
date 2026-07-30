"""Tests for InatAPI.lua against stubbed HTTP, under Lightroom's Lua 5.1.

These cover the parts of the client that encode assumptions about how the
iNaturalist API behaves -- assumptions established by running against the live
API in explore/inat_api.py, and easy to undo by accident later.

The most important test here is the ignore_photos one. A PUT without that flag
silently deletes every photo on an observation and still returns 200, so a
regression would destroy user data with no visible symptom until someone looks
at their observation and finds the evidence gone.
"""

from __future__ import annotations

import json

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin

TOKEN = "header.payload.signature"


class FakeAPI:
    """Canned HTTP responses keyed loosely by URL, recording what was sent."""

    def __init__(self) -> None:
        self.routes: list[tuple[str, object, int]] = []
        self.requests: list[dict] = []

    def add(self, url_contains: str, payload, status: int = 200) -> None:
        self.routes.append((url_contains, payload, status))

    def __call__(self, method, url, body, _headers):
        self.requests.append({"method": method, "url": url, "body": body})

        for fragment, payload, status in self.routes:
            if fragment in url:
                text = payload if isinstance(payload, str) else json.dumps(payload)
                return text, {"status": status}

        return json.dumps({"error": "no route"}), {"status": 404}

    def last_body(self) -> dict:
        return json.loads(self.requests[-1]["body"])


@pytest.fixture
def api_pair():
    fake = FakeAPI()
    plugin = LuaPlugin(http_handler=fake)
    InatAPI = plugin.require("InatAPI")
    return plugin, InatAPI.new(TOKEN), fake


# ---------------------------------------------------------------------------
# The destructive one
# ---------------------------------------------------------------------------


def test_update_sends_ignore_photos_by_default(api_pair):
    """Without this flag the API deletes every photo and still returns 200."""
    plugin, api, fake = api_pair
    fake.add("/observations/1", {"id": 1})

    plugin.call(api.updateObservation, api, 1, plugin.eval('{description = "x"}'))

    body = fake.last_body()
    assert body["ignore_photos"] is True, "PUT without ignore_photos destroys photos"
    # The flag has to sit at the top level, not inside the observation.
    assert "ignore_photos" not in body["observation"]


def test_update_can_still_opt_out_explicitly(api_pair):
    plugin, api, fake = api_pair
    fake.add("/observations/1", {"id": 1})

    plugin.call(
        api.updateObservation, api, 1, plugin.eval('{description = "x"}'), False
    )

    assert "ignore_photos" not in fake.last_body()


def test_update_uses_the_put_verb(api_pair):
    plugin, api, fake = api_pair
    fake.add("/observations/1", {"id": 1})

    plugin.call(api.updateObservation, api, 1, plugin.eval("{}"))

    assert fake.requests[-1]["method"] == "PUT"


# ---------------------------------------------------------------------------
# Response shapes
# ---------------------------------------------------------------------------


def test_unwraps_the_results_envelope(api_pair):
    """v1 wraps single objects in {total_results, results:[...]}."""
    plugin, api, fake = api_pair
    fake.add("/observations/42", {"total_results": 1, "results": [{"id": 42}]})

    observation, err = plugin.call(api.getObservation, api, 42)

    assert err is None
    assert observation["id"] == 42


def test_handles_a_bare_object_response(api_pair):
    plugin, api, fake = api_pair
    fake.add("/observations/42", {"id": 42})

    observation, _ = plugin.call(api.getObservation, api, 42)

    assert observation["id"] == 42


def test_reports_an_empty_results_list_as_not_found(api_pair):
    plugin, api, fake = api_pair
    fake.add("/observations/42", {"total_results": 0, "results": []})

    observation, err = plugin.call(api.getObservation, api, 42)

    assert observation is None
    assert "not found" in err


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


def test_surfaces_http_errors_with_the_response_body(api_pair):
    """Validation details live in the body; discarding them hides the cause."""
    plugin, api, fake = api_pair
    fake.add("/observations", {"error": "Observed on is invalid"}, status=422)

    observation, err = plugin.call(api.createObservation, api, plugin.eval("{}"))

    assert observation is None
    assert "422" in err
    assert "Observed on is invalid" in err


def test_reports_a_missing_response(api_pair):
    plugin, api, fake = api_pair
    plugin.set_http_handler(lambda *_args: (None, None))

    observation, err = plugin.call(api.getObservation, api, 1)

    assert observation is None
    assert "no response" in err.lower()


def test_reports_unparseable_json(api_pair):
    plugin, api, fake = api_pair
    fake.add("/observations/1", "<html>502 Bad Gateway</html>")

    observation, err = plugin.call(api.getObservation, api, 1)

    assert observation is None
    assert "parse" in err.lower()


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------


def test_encodes_query_parameters(api_pair):
    """Species names contain spaces; an unencoded URL would break the search."""
    plugin, api, fake = api_pair
    fake.add("/taxa/autocomplete", {"results": []})

    plugin.call(api.autocompleteTaxon, api, "Ischnura erratica")

    url = fake.requests[-1]["url"]
    assert "Ischnura%20erratica" in url or "Ischnura+erratica" in url
    assert " " not in url


def test_autocomplete_returns_the_results_list(api_pair):
    plugin, api, fake = api_pair
    fake.add(
        "/taxa/autocomplete",
        {"results": [{"id": 103486, "name": "Ischnura erratica", "rank": "species"}]},
    )

    taxa, err = plugin.call(api.autocompleteTaxon, api, "Ischnura")

    assert err is None
    assert taxa[1]["id"] == 103486


def test_counts_photos_via_the_rails_endpoint(api_pair):
    """The v1 index lags photo processing by minutes and reports zero."""
    plugin, api, fake = api_pair
    fake.add(
        "www.inaturalist.org/observations/7.json",
        {"observation_photos": [{"id": 1}, {"id": 2}]},
    )

    count, err = plugin.call(api.countAttachedPhotos, api, 7)

    assert err is None
    assert count == 2
    assert "www.inaturalist.org" in fake.requests[-1]["url"]


def test_identifications_are_posted_not_put(api_pair):
    """PUTting taxon_id leaves the previous identification standing."""
    plugin, api, fake = api_pair
    fake.add("/identifications", {"id": 99})

    plugin.call(api.addIdentification, api, 7, 103486)

    request = fake.requests[-1]
    assert request["method"] == "POST"
    assert "/identifications" in request["url"]

    body = json.loads(request["body"])
    assert body["identification"]["observation_id"] == 7
    assert body["identification"]["taxon_id"] == 103486


# ---------------------------------------------------------------------------
# Verified upload
# ---------------------------------------------------------------------------


def test_upload_is_verified_against_the_photo_count(api_pair, tmp_path):
    """A 200 from the upload endpoint does not mean the photo attached."""
    plugin, api, fake = api_pair
    photo = tmp_path / "photo.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xe0 pretend JPEG bytes")

    counts = iter([0, 1])

    def handler(method, url, body, _headers):
        fake.requests.append({"method": method, "url": url, "body": body})
        if "observations/9.json" in url:
            n = next(counts, 1)
            return json.dumps({"observation_photos": [{}] * n}), {"status": 200}
        return json.dumps({"id": 500}), {"status": 200}

    plugin.set_http_handler(handler)

    result, err = plugin.call(
        api.uploadPhotoVerified, api, 9, str(photo), plugin.eval("{}")
    )

    assert err is None
    assert result is not None


def test_upload_sends_the_file_bytes_intact(api_pair, tmp_path):
    """Binary must survive the multipart body untouched."""
    plugin, api, fake = api_pair
    photo = tmp_path / "photo.jpg"
    content = b"\xff\xd8\xff\xe0\x00\x10JFIF binary \x00\x01\x02payload"
    photo.write_bytes(content)

    fake.add("/observation_photos", {"id": 500})

    plugin.call(api.uploadPhoto, api, 9, str(photo))

    body = fake.requests[-1]["body"].encode("latin-1")
    assert content in body
    assert b'name="observation_photo[observation_id]"' in body
    assert b'filename="photo.jpg"' in body


def test_upload_fails_when_the_photo_never_attaches(api_pair, tmp_path):
    plugin, api, fake = api_pair
    photo = tmp_path / "photo.jpg"
    photo.write_bytes(b"data")

    def handler(method, url, body, _headers):
        if "observations/9.json" in url:
            return json.dumps({"observation_photos": []}), {"status": 200}
        return json.dumps({"id": 500}), {"status": 200}

    plugin.set_http_handler(handler)

    result, err = plugin.call(
        api.uploadPhotoVerified, api, 9, str(photo), plugin.eval("{}")
    )

    assert result is None
    assert "never attached" in err


def test_upload_reports_a_missing_file_clearly(api_pair):
    plugin, api, fake = api_pair

    result, err = plugin.call(api.uploadPhoto, api, 9, "does/not/exist.jpg")

    assert result is None
    assert "Cannot open file" in err
