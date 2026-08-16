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
import re

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


@pytest.fixture
def api_pair_with():
    """Same, but driven by a handler the test supplies."""

    def build(handler):
        plugin = LuaPlugin(http_handler=handler)
        InatAPI = plugin.require("InatAPI")
        return plugin, InatAPI.new(TOKEN), handler

    return build


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
# LrHttp call convention
# ---------------------------------------------------------------------------


def test_post_does_not_pass_a_content_type_positionally(api_pair):
    """LrHttp.post's fifth parameter is a timeout, not a content type.

    Passing "application/json" there meant no request was made at all, and the
    only symptom was "no response from the server".
    """
    plugin, api, fake = api_pair
    fake.add("/observations", {"id": 1})
    fake.add("/identifications", {"id": 2})
    fake.add("/observation_photos", {"id": 3})

    plugin.call(api.createObservation, api, plugin.eval("{}"))
    plugin.call(api.updateObservation, api, 1, plugin.eval("{}"))
    plugin.call(api.addIdentification, api, 1, 2)
    plugin.call(api.deleteObservation, api, 1)

    writes = [call for call in plugin.http_calls if call["method"] != "GET"]
    assert writes, "expected some write requests"

    for call in writes:
        assert call["extra_args"] == 0, (
            f"{call['method']} {call['url']} passed extra positional arguments "
            "to LrHttp.post"
        )


def test_writes_declare_their_content_type_in_headers(api_pair):
    """Content type has to travel in the headers, not as a positional arg."""
    plugin, api, fake = api_pair
    fake.add("/observations", {"id": 1})

    plugin.call(api.createObservation, api, plugin.eval("{}"))

    call = plugin.http_calls[-1]
    assert call["headers"]["Content-Type"] == "application/json"


def test_multipart_declares_its_boundary_in_headers(api_pair, tmp_path):
    plugin, api, fake = api_pair
    photo = tmp_path / "photo.jpg"
    photo.write_bytes(b"data")
    fake.add("/observation_photos", {"id": 3})

    plugin.call(api.uploadPhoto, api, 9, str(photo))

    call = plugin.http_calls[-1]
    assert call["extra_args"] == 0
    assert "multipart/form-data; boundary=" in call["headers"]["Content-Type"]

    boundary = call["headers"]["Content-Type"].split("boundary=", 1)[1]
    assert boundary in call["body"], "body must use the boundary it declares"


def test_transport_failures_report_the_underlying_reason(api_pair):
    """LrHttp puts the reason in the headers table when there is no body."""
    plugin, api, fake = api_pair
    plugin.set_http_handler(
        lambda *_args: (
            None,
            plugin.eval('{error = {name = "Network is unreachable", errorCode = 6}}'),
        )
    )

    observation, err = plugin.call(api.getObservation, api, 1)

    assert observation is None
    assert "Network is unreachable" in err
    assert "6" in err


# ---------------------------------------------------------------------------
# Who we are
# ---------------------------------------------------------------------------


def test_the_account_is_looked_up_before_searching(api_pair_with):
    """user_id=me reads like it should work and does not: the search endpoint
    answers HTTP 422 Unknown user_id me, because user_id is an index filter and
    the index holds numbers. This is what shipped broken."""
    plugin, api, pages = api_pair_with(Pages(3))

    plugin.call(api.listObservations, api, plugin.eval("{}"))

    assert "/users/me" in pages.requests[0]["url"]
    assert "user_id=4242" in pages.searches[0]["url"]
    assert not any("user_id=me" in r["url"] for r in pages.requests)


def test_the_account_is_only_looked_up_once(api_pair_with):
    """It cannot change while a token is in use, and asking again would put a
    round trip in front of every search."""
    plugin, api, pages = api_pair_with(Pages(500))

    plugin.call(api.listObservations, api, plugin.eval("{ perPage = 200 }"))

    identity = [r for r in pages.requests if "/users/me" in r["url"]]
    assert len(identity) == 1
    assert len(pages.searches) == 3


def test_currentUser_returns_the_account(api_pair_with):
    plugin, api, _ = api_pair_with(Pages(0))

    user, err = plugin.call(api.currentUser, api)

    assert err is None
    assert user.id == 4242
    assert user.login == "naturalist"


def test_a_failed_lookup_stops_the_listing(api_pair):
    """Better a plain "who are you" failure than a search filtered by nothing,
    which would return every observation on iNaturalist."""
    plugin, api, _ = api_pair
    plugin.set_http_handler(
        lambda *_args: ('{"error":"Unauthorized"}', plugin.eval("{status = 401}")))

    observations, err = plugin.call(api.listObservations, api, plugin.eval("{}"))

    assert observations is None
    assert err is not None


def test_a_response_without_an_id_is_refused(api_pair):
    """An empty results array would otherwise become user_id=nil, which the
    query builder drops, leaving a search across everybody's observations."""
    plugin, api, _ = api_pair
    plugin.set_http_handler(
        lambda *_args: ('{"total_results":0,"results":[]}', plugin.eval("{status = 200}")))

    user, err = plugin.call(api.currentUser, api)

    assert user is None
    assert "account" in err


# ---------------------------------------------------------------------------
# Listing every observation
# ---------------------------------------------------------------------------


class Pages:
    """A user's observations, served the way the API serves them.

    Ignores everything except id_above and per_page, which is the whole point:
    a paginator that works against a stub keyed on page numbers proves nothing
    about one that has to carry a cursor.
    """

    def __init__(self, count: int, per_page_cap: int = 200) -> None:
        self.observations = [
            {"id": index, "time_observed_at": "2017-04-29T10:22:27Z"}
            for index in range(1, count + 1)
        ]
        self.per_page_cap = per_page_cap
        self.requests: list[dict] = []

    def __call__(self, method, url, body, _headers):
        self.requests.append({"method": method, "url": url})

        # The search endpoints have no notion of "me", so the client has to ask
        # who it is before it can ask what it owns.
        if "/users/me" in url:
            return json.dumps({
                "total_results": 1,
                "results": [{"id": 4242, "login": "naturalist"}],
            }), {"status": 200}

        id_above = int(re.search(r"id_above=(\d+)", url).group(1))
        per_page = int(re.search(r"per_page=(\d+)", url).group(1))
        per_page = min(per_page, self.per_page_cap)

        remaining = [o for o in self.observations if o["id"] > id_above]
        return json.dumps({
            "total_results": len(self.observations),
            "results": remaining[:per_page],
        }), {"status": 200}

    @property
    def searches(self) -> list[dict]:
        """The observation requests, without the identity lookup in front."""
        return [r for r in self.requests if "/users/me" not in r["url"]]


def test_lists_every_observation_across_pages(api_pair_with):
    plugin, api, pages = api_pair_with(Pages(450))

    observations, _ = plugin.call(api.listObservations, api,
                                  plugin.eval("{ perPage = 200 }"))

    assert len(observations) == 450
    assert observations[1].id == 1
    assert observations[450].id == 450


def test_pages_by_cursor_rather_than_page_number(api_pair_with):
    """page x per_page is capped at 10,000 by the API, so a user with more
    observations than that cannot reach the end by counting pages -- the
    request fails rather than paging on. id_above has no such ceiling."""
    plugin, api, pages = api_pair_with(Pages(450))

    plugin.call(api.listObservations, api, plugin.eval("{ perPage = 200 }"))

    assert all("id_above=" in request["url"] for request in pages.searches)
    assert not any("&page=" in request["url"] for request in pages.searches)

    cursors = [int(re.search(r"id_above=(\d+)", r["url"]).group(1))
               for r in pages.searches]
    assert cursors == [0, 200, 400]


def test_asks_for_ascending_id_order(api_pair_with):
    """The cursor is the last id of the previous page, so any other ordering
    silently repeats or skips observations."""
    plugin, api, pages = api_pair_with(Pages(10))

    plugin.call(api.listObservations, api, plugin.eval("{ perPage = 200 }"))

    assert "order_by=id" in pages.searches[0]["url"]
    assert "order=asc" in pages.searches[0]["url"]


def test_a_short_page_ends_it(api_pair_with):
    """Asking again would spend a request against a 100/minute limit to be
    told the same thing."""
    plugin, api, pages = api_pair_with(Pages(150))

    plugin.call(api.listObservations, api, plugin.eval("{ perPage = 200 }"))

    assert len(pages.searches) == 1


def test_an_exact_multiple_takes_one_extra_page(api_pair_with):
    """400 observations at 200 a page cannot be distinguished from 400-plus
    until a page comes back empty."""
    plugin, api, pages = api_pair_with(Pages(400))

    observations, _ = plugin.call(api.listObservations, api,
                                  plugin.eval("{ perPage = 200 }"))

    assert len(observations) == 400
    assert len(pages.searches) == 3


def test_no_observations_is_not_an_error(api_pair_with):
    plugin, api, pages = api_pair_with(Pages(0))

    observations, err = plugin.call(api.listObservations, api,
                                    plugin.eval("{ perPage = 200 }"))

    assert err is None
    assert len(observations) == 0


def test_reports_progress_per_page(api_pair_with):
    plugin, api, pages = api_pair_with(Pages(450))

    seen = plugin.eval("{}")
    options = plugin.eval(
        """
        function(seen)
          return { perPage = 200, onPage = function(fetched, total)
            seen[#seen + 1] = { fetched = fetched, total = total }
          end }
        end
        """
    )(seen)

    plugin.call(api.listObservations, api, options)

    assert [row.fetched for row in seen.values()] == [200, 400, 450]
    assert all(row.total == 450 for row in seen.values())


def test_can_be_stopped_between_pages(api_pair_with):
    """A user who cancels should not wait out every remaining page."""
    plugin, api, pages = api_pair_with(Pages(1000))

    options = plugin.eval(
        """
        { perPage = 200, shouldStop = function() return true end }
        """
    )
    observations, _ = plugin.call(api.listObservations, api, options)

    assert len(observations) == 200
    assert len(pages.searches) == 1


def test_a_failed_page_fails_the_whole_call(api_pair):
    """Half a user's observations looks exactly like a user with half as many,
    and would quietly report nothing to match against."""
    plugin, api, fake = api_pair
    fake.add("/observations", {"error": "boom"}, status=500)

    observations, err = plugin.call(api.listObservations, api,
                                    plugin.eval("{ perPage = 200 }"))

    assert observations is None
    assert err is not None


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


# ---------------------------------------------------------------------------
# The fallback taxon the vision endpoint volunteers
# ---------------------------------------------------------------------------


@pytest.fixture
def inat_api():
    plugin = LuaPlugin()
    return plugin, plugin.require("InatAPI")


def test_the_common_ancestor_is_carried_out_of_the_payload(inat_api):
    """It is what makes an honest coarser suggestion possible. Dropping it --
    which is what the code did before -- leaves the picker with nothing to fall
    back to but the top result's own lineage, which is the guess in doubt."""
    plugin, api = inat_api
    payload = plugin.runtime.eval("""
      {
        common_ancestor = { taxon = { id = 52054, name = "Ischnura", rank = "genus" } },
        results = {
          { combined_score = 40.5,
            taxon = { id = 103486, name = "Ischnura erratica", rank = "species" } },
        },
      }
    """)

    rows, ancestor = api["summariseSuggestions"](payload)

    assert rows[1]["name"] == "Ischnura erratica"
    assert ancestor["name"] == "Ischnura"
    assert ancestor["rank"] == "genus"


def test_the_ancestor_is_unwrapped_from_its_envelope(inat_api):
    """common_ancestor is {taxon = {...}}, not the taxon itself. Returning the
    wrapper gives a table with no name or rank, and the fallback row renders as
    "Unnamed taxon"."""
    plugin, api = inat_api
    payload = plugin.runtime.eval("""
      { common_ancestor = { taxon = { id = 1, name = "Animalia", rank = "kingdom" } },
        results = {} }
    """)

    _, ancestor = api["summariseSuggestions"](payload)

    assert ancestor["name"] == "Animalia"


def test_a_payload_with_no_common_ancestor_is_fine(inat_api):
    """The candidates shared nothing, and score_observation may not send one at
    all. Nil here has to mean "no fallback", not an error."""
    plugin, api = inat_api
    payload = plugin.runtime.eval("""
      { results = { { combined_score = 98,
          taxon = { id = 1, name = "X", rank = "species" } } } }
    """)

    rows, ancestor = api["summariseSuggestions"](payload)

    assert len(rows) == 1
    assert ancestor is None


def test_an_empty_payload_yields_no_rows_and_no_ancestor(inat_api):
    _, api = inat_api

    rows, ancestor = api["summariseSuggestions"](None)

    assert len(rows) == 0
    assert ancestor is None
