"""
inat_client.py
~~~~~~~~~~~~~~
Thin authenticated wrapper around pyinaturalist.

Usage
-----
    from inat_client import InatClient

    client = InatClient()           # reads credentials from .env
    token = client.access_token
    obs = client.get_observation(12345678)
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import pyinaturalist
from dotenv import load_dotenv

# ---------------------------------------------------------------------------
# Load credentials from .env (if present)
# ---------------------------------------------------------------------------
_ENV_FILE = Path(__file__).parent / ".env"
load_dotenv(_ENV_FILE)


class InatClient:
    """Lightweight wrapper that caches an OAuth token and exposes helpers."""

    BASE_URL = "https://api.inaturalist.org/v1"

    def __init__(
        self,
        app_id: str | None = None,
        app_secret: str | None = None,
        username: str | None = None,
        password: str | None = None,
    ) -> None:
        self._app_id = app_id or os.environ["INAT_APP_ID"]
        self._app_secret = app_secret or os.environ["INAT_APP_SECRET"]
        self._username = username or os.environ["INAT_USERNAME"]
        self._password = password or os.environ["INAT_PASSWORD"]
        self._token: str | None = None

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    @property
    def access_token(self) -> str:
        """Return a cached OAuth access token, obtaining one if needed."""
        if self._token is None:
            # Positional args: username, password, app_id, app_secret
            self._token = pyinaturalist.get_access_token(
                self._username,
                self._password,
                self._app_id,
                self._app_secret,
            )
        return self._token

    # ------------------------------------------------------------------
    # Taxa
    # ------------------------------------------------------------------

    def autocomplete_taxon(self, query: str, rank: str = "species") -> list[dict[str, Any]]:
        """Return taxa matching *query* (used for the species picker UI)."""
        results = pyinaturalist.get_taxa_autocomplete(q=query, rank=rank)
        return results.get("results", [])

    def get_taxon(self, taxon_id: int) -> dict[str, Any]:
        """Return full taxon details including the ancestor list."""
        results = pyinaturalist.get_taxa(taxon_id)
        return results["results"][0]

    def build_keyword_path(self, taxon: dict[str, Any]) -> list[str]:
        """
        Build the hierarchical keyword path for Lightroom from a taxon dict.

        Returns a list ordered from kingdom to species, e.g.:
            ["Animalia", "Arthropoda", "Insecta", ..., "Quercus robur"]

        The top-level "iNaturalist" keyword is prepended so the hierarchy is
        nested under a single root.
        """
        ancestors: list[dict[str, Any]] = taxon.get("ancestors", [])
        path = ["iNaturalist"] + [a["name"] for a in ancestors] + [taxon["name"]]
        return path

    # ------------------------------------------------------------------
    # Observations
    # ------------------------------------------------------------------

    def create_observation(
        self,
        *,
        taxon_id: int,
        observed_on: str,
        latitude: float | None = None,
        longitude: float | None = None,
        description: str = "",
        geoprivacy: str = "open",
    ) -> dict[str, Any]:
        """Create a new observation and return the full response dict."""
        params: dict[str, Any] = {
            "taxon_id": taxon_id,
            "observed_on_string": observed_on,
            "description": description,
            "geoprivacy": geoprivacy,
            "access_token": self.access_token,
        }
        if latitude is not None:
            params["latitude"] = latitude
        if longitude is not None:
            params["longitude"] = longitude

        response = pyinaturalist.create_observation(**params)
        return response

    def upload_photo(self, observation_id: int, photo_path: str) -> dict[str, Any]:
        """Attach a photo file to an existing observation."""
        response = pyinaturalist.upload_photos(
            observation_id,
            photo=photo_path,
            access_token=self.access_token,
        )
        return response

    def get_observation(self, observation_id: int) -> dict[str, Any]:
        """Fetch a single observation including taxon and identification data."""
        results = pyinaturalist.get_observation(observation_id)
        return results

    def add_to_project(self, observation_id: int, project_id: int) -> dict[str, Any]:
        """Add an observation to an iNaturalist project."""
        import requests

        url = f"{self.BASE_URL}/project_observations"
        auth_scheme = "Bearer"
        headers = {"Authorization": f"{auth_scheme} {self.access_token}"}
        payload = {
            "project_observation": {
                "observation_id": observation_id,
                "project_id": project_id,
            }
        }
        resp = requests.post(url, json=payload, headers=headers, timeout=30)
        resp.raise_for_status()
        return resp.json()

    # ------------------------------------------------------------------
    # Projects
    # ------------------------------------------------------------------

    def search_projects(self, query: str) -> list[dict[str, Any]]:
        """Search iNaturalist projects by name."""
        import requests

        url = f"{self.BASE_URL}/projects"
        params = {"q": query, "per_page": 20}
        resp = requests.get(url, params=params, timeout=30)
        resp.raise_for_status()
        return resp.json().get("results", [])
