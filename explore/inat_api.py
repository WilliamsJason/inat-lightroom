"""
inat_api.py
~~~~~~~~~~~
A direct-HTTP client for the iNaturalist v1 API.

Why not just use pyinaturalist?
------------------------------
The Lightroom plugin is written in Lua and will hand-roll HTTP requests via
``LrHttp``.  Anything clever that pyinaturalist does for us here would have to
be reimplemented there anyway.  Keeping the exploration code at the same level
of abstraction as the eventual plugin means the request/response shapes we
prove out translate line-for-line into Lua.

Authentication is delegated to :mod:`inat_auth`, which resolves a JWT.  Note
that the v1 API requires a **JWT** (not a bare OAuth access token) for every
write operation -- a plain OAuth token is silently treated as anonymous.
"""

from __future__ import annotations

import mimetypes
import time
from pathlib import Path
from typing import Any, Callable

import requests

from inat_auth import API_V1, USER_AGENT, WWW_BASE, auth_headers, get_token

DEFAULT_TIMEOUT = 60


class InatApiError(RuntimeError):
    """Raised when the API returns an error response."""

    def __init__(self, method: str, url: str, response: requests.Response) -> None:
        self.status_code = response.status_code
        self.body = response.text[:1000]
        super().__init__(
            f"{method} {url} -> {response.status_code}\n{self.body}"
        )


class PhotoNotPersisted(RuntimeError):
    """Raised when a photo upload reports success but never actually attaches."""

    def __init__(self, observation_id: int, attempts: int) -> None:
        self.observation_id = observation_id
        super().__init__(
            f"Photo never attached to observation {observation_id} after "
            f"{attempts} upload attempt(s). iNaturalist accepted each POST but "
            f"the asynchronous image processing did not complete."
        )


class InatApi:
    """Minimal authenticated client for the endpoints the plugin needs."""

    def __init__(self, token: str | None = None) -> None:
        self._token = token or get_token()
        self._session = requests.Session()
        self._session.headers.update({"User-Agent": USER_AGENT})

    # ------------------------------------------------------------------
    # Plumbing
    # ------------------------------------------------------------------

    def _request(
        self,
        method: str,
        path: str,
        *,
        authenticated: bool = True,
        **kwargs: Any,
    ) -> Any:
        url = f"{API_V1}{path}"
        headers = dict(kwargs.pop("headers", {}))
        if authenticated:
            headers.update(auth_headers(self._token))
        resp = self._session.request(
            method, url, headers=headers, timeout=DEFAULT_TIMEOUT, **kwargs
        )
        if resp.status_code >= 400:
            raise InatApiError(method, url, resp)
        if not resp.content:
            return None
        return resp.json()

    @staticmethod
    def _first_result(payload: Any) -> dict[str, Any]:
        """Unwrap the several response shapes the v1 API uses."""
        if isinstance(payload, list):
            return payload[0] if payload else {}
        if isinstance(payload, dict):
            if "results" in payload:
                results = payload["results"]
                return results[0] if results else {}
            return payload
        return {}

    # ------------------------------------------------------------------
    # Taxa
    # ------------------------------------------------------------------

    def autocomplete_taxon(
        self, query: str, *, rank: str | None = None, per_page: int = 10
    ) -> list[dict[str, Any]]:
        params: dict[str, Any] = {"q": query, "per_page": per_page, "locale": "en"}
        if rank:
            params["rank"] = rank
        payload = self._request(
            "GET", "/taxa/autocomplete", authenticated=False, params=params
        )
        return payload.get("results", [])

    def get_taxon(self, taxon_id: int) -> dict[str, Any]:
        payload = self._request("GET", f"/taxa/{taxon_id}", authenticated=False)
        return self._first_result(payload)

    # ------------------------------------------------------------------
    # Observations
    # ------------------------------------------------------------------

    def create_observation(self, observation: dict[str, Any]) -> dict[str, Any]:
        """
        Create an observation.

        *observation* is the inner object -- it gets wrapped in the
        ``{"observation": {...}}`` envelope the API expects.  Useful keys:
        ``species_guess``, ``taxon_id``, ``observed_on_string``,
        ``latitude``, ``longitude``, ``positional_accuracy``, ``description``,
        ``captive_flag``, ``geoprivacy``.
        """
        payload = self._request(
            "POST", "/observations", json={"observation": observation}
        )
        return self._first_result(payload)

    def get_observation(self, observation_id: int) -> dict[str, Any]:
        payload = self._request(
            "GET", f"/observations/{observation_id}", authenticated=False
        )
        return self._first_result(payload)

    def update_observation(
        self,
        observation_id: int,
        observation: dict[str, Any],
        *,
        ignore_photos: bool = True,
    ) -> dict[str, Any]:
        """
        Partially update an observation; only the supplied keys change.

        .. warning::
           ``ignore_photos`` defaults to ``True`` here, and you almost
           certainly want to leave it that way.

           The underlying API treats a ``PUT`` as a *full replacement* of the
           observation's nested associations. Omitting the flag detaches every
           photo on the observation -- the request still returns ``200``, and
           the photo files remain in iNaturalist's storage, but the links to
           the observation are gone. The observation silently drops to
           ``casual`` grade with no evidence attached.

           This was verified directly: a PUT without the flag took an
           observation from 1 photo to 0; the identical PUT with the flag left
           it untouched.
        """
        payload: dict[str, Any] = {"observation": observation}
        if ignore_photos:
            payload["ignore_photos"] = True
        result = self._request(
            "PUT", f"/observations/{observation_id}", json=payload
        )
        return self._first_result(result)

    def delete_observation(self, observation_id: int) -> None:
        self._request("DELETE", f"/observations/{observation_id}")

    # ------------------------------------------------------------------
    # Photos
    # ------------------------------------------------------------------

    def upload_observation_photo(
        self, observation_id: int, photo_path: str | Path
    ) -> dict[str, Any]:
        """Attach a local image file to an existing observation."""
        path = Path(photo_path)
        if not path.is_file():
            raise FileNotFoundError(path)
        content_type = mimetypes.guess_type(path.name)[0] or "image/jpeg"

        with path.open("rb") as handle:
            payload = self._request(
                "POST",
                "/observation_photos",
                data={"observation_photo[observation_id]": str(observation_id)},
                files={"file": (path.name, handle, content_type)},
            )
        return self._first_result(payload)

    def count_attached_photos(self, observation_id: int) -> int:
        """
        Count photos actually persisted against an observation.

        This deliberately queries the Rails endpoint rather than
        ``/v1/observations/{id}``.  The v1 API is served from an
        Elasticsearch index that lags photo processing by minutes, so it
        reports zero photos long after the upload has in fact succeeded --
        and would make a verification poll give up far too early.
        """
        resp = self._session.get(
            f"{WWW_BASE}/observations/{observation_id}.json",
            headers=auth_headers(self._token),
            timeout=DEFAULT_TIMEOUT,
        )
        if resp.status_code >= 400:
            raise InatApiError("GET", resp.url, resp)
        return len(resp.json().get("observation_photos") or [])

    def upload_observation_photo_verified(
        self,
        observation_id: int,
        photo_path: str | Path,
        *,
        attempts: int = 3,
        poll_seconds: float = 10.0,
        poll_tries: int = 6,
        on_event: Callable[[str], None] | None = None,
    ) -> dict[str, Any]:
        """
        Upload a photo and confirm it actually stuck, retrying if it did not.

        iNaturalist accepts the multipart POST and returns ``200`` with a
        populated ``observation_photo`` record *before* the image has been
        processed and stored. The URLs in that response point at placeholder
        graphics until processing completes, so the response body cannot tell
        you whether the upload really succeeded.

        Verifying here is cheap insurance. Note that by far the most common
        cause of a photo going missing is not a failed upload at all, but a
        subsequent ``PUT`` without ``ignore_photos`` -- see
        :meth:`update_observation`. Always order operations so that photo
        uploads come *after* any metadata update, or pass the flag.

        Returns the upload response for the attempt that verified.
        """

        def emit(message: str) -> None:
            if on_event:
                on_event(message)

        baseline = self.count_attached_photos(observation_id)
        last_response: dict[str, Any] = {}

        for attempt in range(1, attempts + 1):
            last_response = self.upload_observation_photo(observation_id, photo_path)
            emit(
                f"attempt {attempt}/{attempts}: POST accepted "
                f"(observation_photo id={last_response.get('id')})"
            )

            for poll in range(poll_tries):
                time.sleep(poll_seconds)
                current = self.count_attached_photos(observation_id)
                if current > baseline:
                    emit(
                        f"verified after {(poll + 1) * poll_seconds:.0f}s "
                        f"({baseline} -> {current} photos)"
                    )
                    return last_response
            emit(
                f"attempt {attempt} did not persist within "
                f"{poll_seconds * poll_tries:.0f}s"
            )

        raise PhotoNotPersisted(observation_id, attempts)

    # ------------------------------------------------------------------
    # Computer vision suggestions
    # ------------------------------------------------------------------

    def suggest_species_for_image(
        self,
        photo_path: str | Path,
        *,
        latitude: float | None = None,
        longitude: float | None = None,
        observed_on: str | None = None,
    ) -> dict[str, Any]:
        """
        Ask iNaturalist's vision model to identify an image *before* it is
        uploaded anywhere.

        This is the call the plugin wants: the user picks a photo in
        Lightroom, we render a small JPEG, and we can offer suggestions
        without creating anything on iNaturalist first.

        Supplying coordinates and a date materially improves the ranking,
        because the model combines visual similarity with what is actually
        recorded nearby at that time of year.

        Note that ``lat``/``lng``/``observed_on`` must be sent as **multipart
        form fields**, not query-string parameters.  Passing them in the query
        string returns HTTP 200 and silently ignores them, leaving every
        ``frequency_score`` at zero -- an easy mistake to miss.

        Returns the raw response, which contains:
          ``results``          ranked candidate taxa
          ``common_ancestor``  the most specific taxon the model is confident
                               about across all candidates -- a natural
                               default when the user wants to "come in" at a
                               coarser level than species
        """
        path = Path(photo_path)
        if not path.is_file():
            raise FileNotFoundError(path)
        content_type = mimetypes.guess_type(path.name)[0] or "image/jpeg"

        form: dict[str, str] = {}
        if latitude is not None and longitude is not None:
            form["lat"] = str(latitude)
            form["lng"] = str(longitude)
        if observed_on:
            form["observed_on"] = observed_on

        with path.open("rb") as handle:
            payload = self._request(
                "POST",
                "/computervision/score_image",
                data=form,
                files={"image": (path.name, handle, content_type)},
            )
        return payload

    def suggest_species_for_observation(self, observation_id: int) -> dict[str, Any]:
        """Score an observation that already has photos attached."""
        return self._request(
            "GET", f"/computervision/score_observation/{observation_id}"
        )

    @staticmethod
    def summarise_suggestions(payload: dict[str, Any]) -> list[dict[str, Any]]:
        """Flatten a vision response into rows suitable for a picker UI."""
        rows: list[dict[str, Any]] = []
        for result in payload.get("results") or []:
            taxon = result.get("taxon") or {}
            rows.append(
                {
                    "taxon_id": taxon.get("id"),
                    "name": taxon.get("name"),
                    "rank": taxon.get("rank"),
                    "common_name": taxon.get("preferred_common_name"),
                    "combined_score": result.get("combined_score"),
                    "vision_score": result.get("vision_score"),
                    "frequency_score": result.get("frequency_score"),
                }
            )
        return rows

    # ------------------------------------------------------------------
    # Identifications
    # ------------------------------------------------------------------

    def get_identifications(self, observation_id: int) -> list[dict[str, Any]]:
        payload = self._request(
            "GET",
            "/identifications",
            authenticated=False,
            params={"observation_id": observation_id, "per_page": 100},
        )
        return payload.get("results", [])

    def add_identification(
        self, observation_id: int, taxon_id: int, body: str = ""
    ) -> dict[str, Any]:
        """
        Add an identification to an observation.

        This is the correct way to change what an observation is identified
        as. Setting ``taxon_id`` via ``PUT /observations/{id}`` moves the
        observation's own taxon but leaves the existing identification
        standing, so the two disagree. Posting a new identification instead
        makes iNaturalist withdraw the author's previous one automatically.
        """
        payload: dict[str, Any] = {
            "identification": {
                "observation_id": observation_id,
                "taxon_id": taxon_id,
            }
        }
        if body:
            payload["identification"]["body"] = body
        return self._first_result(
            self._request("POST", "/identifications", json=payload)
        )

    # ------------------------------------------------------------------
    # Derived helpers (these mirror what the plugin needs to produce)
    # ------------------------------------------------------------------

    def build_keyword_path(self, taxon: dict[str, Any], root: str = "iNaturalist") -> list[str]:
        """
        Build the Lightroom hierarchical keyword path for a taxon.

        ``/taxa/{id}`` returns ``ancestors`` ordered kingdom -> parent, so the
        path is simply the ancestor names followed by the taxon itself.
        """
        ancestors = taxon.get("ancestors") or []
        return [root] + [a["name"] for a in ancestors] + [taxon["name"]]

    def determination(self, observation: dict[str, Any]) -> dict[str, Any]:
        """
        Summarise the current determination for an observation.

        iNaturalist exposes two related things:
          * ``taxon`` -- what the site currently displays for the observation
          * ``community_taxon`` -- the community consensus, which may lag or
            differ from the observer's own ID

        The plugin should prefer the community taxon when present.
        """
        taxon = observation.get("taxon") or {}
        community = observation.get("community_taxon") or {}
        chosen = community or taxon
        return {
            "taxon_id": chosen.get("id"),
            "name": chosen.get("name"),
            "rank": chosen.get("rank"),
            "common_name": chosen.get("preferred_common_name"),
            "is_community": bool(community),
            "quality_grade": observation.get("quality_grade"),
            "identifications_count": observation.get("identifications_count"),
            "num_identification_agreements": observation.get(
                "num_identification_agreements"
            ),
            "num_identification_disagreements": observation.get(
                "num_identification_disagreements"
            ),
        }
