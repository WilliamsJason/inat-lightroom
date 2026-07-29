"""
tests/test_inat_client.py
~~~~~~~~~~~~~~~~~~~~~~~~~
Unit tests for inat_client.py.

All HTTP calls are mocked with the `responses` library so no real API
credentials are needed.
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Patch environment before importing the module under test so that dotenv
# does not try to read a .env file that doesn't exist in CI.
# ---------------------------------------------------------------------------
os.environ.setdefault("INAT_APP_ID", "test_app_id")
os.environ.setdefault("INAT_APP_SECRET", "test_app_secret")
os.environ.setdefault("INAT_USERNAME", "test_user")
os.environ.setdefault("INAT_PASSWORD", "test_pass")

from inat_client import InatClient  # noqa: E402  (import after env setup)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SAMPLE_TAXON = {
    "id": 48793,
    "name": "Quercus robur",
    "rank": "species",
    "preferred_common_name": "English Oak",
    "ancestors": [
        {"id": 47126, "name": "Plantae", "rank": "kingdom"},
        {"id": 47125, "name": "Tracheophyta", "rank": "phylum"},
        {"id": 47124, "name": "Magnoliopsida", "rank": "class"},
        {"id": 47123, "name": "Fagales", "rank": "order"},
        {"id": 47122, "name": "Fagaceae", "rank": "family"},
        {"id": 47121, "name": "Quercus", "rank": "genus"},
    ],
}

SAMPLE_OBSERVATION = {
    "id": 12345678,
    "quality_grade": "research",
    "observed_on": "2024-05-10",
    "taxon": SAMPLE_TAXON,
    "community_taxon": SAMPLE_TAXON,
    "latitude": "51.5074",
    "longitude": "-0.1278",
}


@pytest.fixture
def client() -> InatClient:
    """Return an InatClient with a pre-set fake access token."""
    # Positional order: app_id, app_secret, username, password
    c = InatClient("test_app_id", "test_app_secret", "test_user", "test_pass")
    c._token = "fake_token"
    return c


# ---------------------------------------------------------------------------
# build_keyword_path
# ---------------------------------------------------------------------------

class TestBuildKeywordPath:
    def test_root_is_inaturalist(self, client: InatClient) -> None:
        path = client.build_keyword_path(SAMPLE_TAXON)
        assert path[0] == "iNaturalist"

    def test_ends_with_species_name(self, client: InatClient) -> None:
        path = client.build_keyword_path(SAMPLE_TAXON)
        assert path[-1] == "Quercus robur"

    def test_ancestor_order(self, client: InatClient) -> None:
        path = client.build_keyword_path(SAMPLE_TAXON)
        # Kingdom should come right after the iNaturalist root
        assert path[1] == "Plantae"
        assert path[-2] == "Quercus"

    def test_no_ancestors(self, client: InatClient) -> None:
        """A taxon with no ancestors still produces a two-element path."""
        taxon = {"id": 1, "name": "Animalia", "rank": "kingdom", "ancestors": []}
        path = client.build_keyword_path(taxon)
        assert path == ["iNaturalist", "Animalia"]


# ---------------------------------------------------------------------------
# autocomplete_taxon (mocked via pyinaturalist)
# ---------------------------------------------------------------------------

class TestAutocompleteTaxon:
    def test_returns_results(self, client: InatClient) -> None:
        mock_response = {"results": [SAMPLE_TAXON], "total_results": 1}
        with patch("pyinaturalist.get_taxa_autocomplete", return_value=mock_response):
            results = client.autocomplete_taxon("Quercus robur")
        assert len(results) == 1
        assert results[0]["name"] == "Quercus robur"

    def test_empty_query_returns_empty_list(self, client: InatClient) -> None:
        mock_response = {"results": [], "total_results": 0}
        with patch("pyinaturalist.get_taxa_autocomplete", return_value=mock_response):
            results = client.autocomplete_taxon("zzznomatch")
        assert results == []


# ---------------------------------------------------------------------------
# create_observation (mocked via pyinaturalist)
# ---------------------------------------------------------------------------

class TestCreateObservation:
    def test_returns_observation_dict(self, client: InatClient) -> None:
        mock_obs = {"id": 99, "taxon_id": 48793}
        with patch("pyinaturalist.create_observation", return_value=mock_obs):
            result = client.create_observation(
                taxon_id=48793,
                observed_on="2024-05-10",
                latitude=51.5,
                longitude=-0.1,
            )
        assert result["id"] == 99

    def test_passes_access_token(self, client: InatClient) -> None:
        mock_obs = {"id": 42}
        with patch("pyinaturalist.create_observation", return_value=mock_obs) as mock_fn:
            client.create_observation(taxon_id=1, observed_on="2024-01-01")
        call_kwargs = mock_fn.call_args.kwargs
        assert call_kwargs.get("access_token") == "fake_token"


# ---------------------------------------------------------------------------
# get_observation (mocked via pyinaturalist)
# ---------------------------------------------------------------------------

class TestGetObservation:
    def test_returns_observation(self, client: InatClient) -> None:
        with patch("pyinaturalist.get_observation", return_value=SAMPLE_OBSERVATION):
            obs = client.get_observation(12345678)
        assert obs["id"] == 12345678
        assert obs["quality_grade"] == "research"
