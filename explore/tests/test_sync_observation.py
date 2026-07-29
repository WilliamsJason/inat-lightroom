"""
tests/test_sync_observation.py
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Unit tests for sync_observation.py helpers.
"""

from __future__ import annotations

import os

import pytest

os.environ.setdefault("INAT_APP_ID", "test_app_id")
os.environ.setdefault("INAT_APP_SECRET", "test_app_secret")
os.environ.setdefault("INAT_USERNAME", "test_user")
os.environ.setdefault("INAT_PASSWORD", "test_pass")

from sync_observation import build_keyword_path, build_metadata  # noqa: E402

SAMPLE_TAXON = {
    "id": 48793,
    "name": "Quercus robur",
    "rank": "species",
    "preferred_common_name": "English Oak",
    "ancestors": [
        {"id": 47126, "name": "Plantae", "rank": "kingdom"},
        {"id": 47121, "name": "Quercus", "rank": "genus"},
    ],
}

SAMPLE_OBSERVATION = {
    "id": 12345678,
    "quality_grade": "research",
    "observed_on": "2024-05-10",
    "taxon": SAMPLE_TAXON,
    "community_taxon": SAMPLE_TAXON,
}


class TestBuildKeywordPath:
    def test_starts_with_inat_root(self) -> None:
        path = build_keyword_path(SAMPLE_TAXON)
        assert path[0] == "iNaturalist"

    def test_ends_with_taxon_name(self) -> None:
        path = build_keyword_path(SAMPLE_TAXON)
        assert path[-1] == "Quercus robur"

    def test_includes_ancestors_in_order(self) -> None:
        path = build_keyword_path(SAMPLE_TAXON)
        assert "Plantae" in path
        assert "Quercus" in path
        assert path.index("Plantae") < path.index("Quercus")

    def test_no_ancestors(self) -> None:
        taxon = {"id": 1, "name": "Animalia", "rank": "kingdom", "ancestors": []}
        path = build_keyword_path(taxon)
        assert path == ["iNaturalist", "Animalia"]


class TestBuildMetadata:
    def test_observation_id_field(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        assert meta["inat_observation_id"] == "12345678"

    def test_observation_url(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        assert "12345678" in meta["inat_observation_url"]

    def test_taxon_name_uses_community_taxon(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        assert meta["inat_taxon_name"] == "Quercus robur"

    def test_common_name(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        assert meta["inat_common_name"] == "English Oak"

    def test_quality_grade(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        assert meta["inat_quality_grade"] == "research"

    def test_last_synced_is_iso_string(self) -> None:
        meta = build_metadata(SAMPLE_OBSERVATION)
        # Should look like 2024-05-10T...+00:00 or similar ISO 8601
        assert "T" in meta["inat_last_synced"]

    def test_falls_back_to_taxon_when_no_community_taxon(self) -> None:
        obs = dict(SAMPLE_OBSERVATION)
        obs["community_taxon"] = None
        meta = build_metadata(obs)
        assert meta["inat_taxon_name"] == "Quercus robur"
