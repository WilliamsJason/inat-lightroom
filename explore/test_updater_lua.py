"""Finding out whether a newer release exists.

Covers Updater.lua: version comparison, reading a GitHub release, and picking
the archive out of its assets.

The comparison is the part worth being fussy about. It runs unattended on
everyone's machine and both ways of getting it wrong are silent -- too eager
offers an update that does not exist, too lax strands people on an old version
with no sign that anything is wrong.
"""

import json

import pytest

from lua_harness import LuaPlugin

OWNER_REPO = "WilliamsJason/inat-lightroom"
DOWNLOAD = f"https://github.com/{OWNER_REPO}/releases/download"


def release_json(tag="v0.2.0", *, assets=None, body="notes"):
    """A release payload shaped the way GitHub's API returns one."""
    if assets is None:
        assets = [
            {
                "name": "inat-lightroom-0.2.0.zip",
                "browser_download_url": f"{DOWNLOAD}/{tag}/inat-lightroom-0.2.0.zip",
            },
            {
                "name": "SHA256SUMS",
                "browser_download_url": f"{DOWNLOAD}/{tag}/SHA256SUMS",
            },
        ]
    return {
        "tag_name": tag,
        "body": body,
        "html_url": f"https://github.com/{OWNER_REPO}/releases/tag/{tag}",
        "assets": assets,
    }


class FakeGitHub:
    """Answers the release endpoint and the checksum asset, recording requests."""

    def __init__(self, release=None, sums=None, status=200):
        self.release = release if release is not None else release_json()
        self.sums = sums
        self.status = status
        self.requests = []

    def __call__(self, method, url, body, headers):
        self.requests.append({"method": method, "url": url, "headers": headers})

        if url.endswith("SHA256SUMS"):
            if self.sums is None:
                return None, {"error": {"name": "not found"}}
            return self.sums, {"status": 200}

        if self.status != 200:
            return json.dumps({"message": "Not Found"}), {"status": self.status}

        return json.dumps(self.release), {"status": 200}


@pytest.fixture
def plugin():
    return LuaPlugin(http_handler=FakeGitHub())


@pytest.fixture
def updater(plugin):
    return plugin.require("Updater")


def make(release=None, sums=None, status=200):
    fake = FakeGitHub(release, sums, status)
    plugin = LuaPlugin(http_handler=fake)
    return plugin, plugin.require("Updater"), fake


# ---------------------------------------------------------------------------
# Reading a version
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "text,expected",
    [
        ("v0.2.0", (0, 2, 0)),
        ("0.2.0", (0, 2, 0)),
        ("V1.20.3", (1, 20, 3)),
        ("  v2.0.1  ", (2, 0, 1)),
        ("0.2", (0, 2, 0)),
    ],
)
def test_it_reads_a_version_however_it_is_written(updater, text, expected):
    version = updater.parseVersion(text)
    assert (version.major, version.minor, version.revision) == expected


@pytest.mark.parametrize("text", ["", "latest", "release-2", "v", None, "vx.y.z"])
def test_it_refuses_anything_that_is_not_a_version(updater, text):
    assert updater.parseVersion(text) is None, (
        "a tag that is not a version must not parse as one: it would be "
        "compared against the installed version and offered as an update"
    )


def test_the_installed_version_comes_from_info_lua(updater):
    version = updater.currentVersion()
    assert version is not None, (
        "Info.lua is the only place the version exists; _PLUGIN carries id, "
        "path and enabled but no version"
    )
    assert isinstance(version.major, (int, float))


# ---------------------------------------------------------------------------
# Comparing versions
# ---------------------------------------------------------------------------


def version(updater, text):
    return updater.parseVersion(text)


@pytest.mark.parametrize(
    "candidate,installed",
    [
        ("0.2.0", "0.1.0"),
        ("1.0.0", "0.9.9"),
        ("0.1.1", "0.1.0"),
        ("0.10.0", "0.9.0"),
        ("0.1.10", "0.1.9"),
    ],
)
def test_it_sees_a_newer_release(updater, candidate, installed):
    assert updater.isNewer(version(updater, candidate), version(updater, installed))


def test_ten_is_newer_than_nine(updater):
    # The classic way to strand everyone on the release where a number reached
    # double figures: comparing "0.10.0" against "0.9.0" as strings.
    assert updater.isNewer(version(updater, "0.10.0"), version(updater, "0.9.0"))
    assert not updater.isNewer(version(updater, "0.9.0"), version(updater, "0.10.0"))


@pytest.mark.parametrize(
    "candidate,installed",
    [("0.1.0", "0.1.0"), ("0.1.0", "0.2.0"), ("0.9.9", "1.0.0")],
)
def test_the_same_or_older_is_not_an_update(updater, candidate, installed):
    assert not updater.isNewer(
        version(updater, candidate), version(updater, installed)
    ), (
        "the latest-release endpoint returns the newest by date, not by "
        "number, so retagging an old commit must not offer a downgrade"
    )


def test_an_unreadable_installed_version_does_not_block_updates(updater):
    assert updater.isNewer(version(updater, "0.1.0"), None) is True, (
        "if Info.lua could not be read the safe answer is to offer the "
        "update, not to hide it"
    )


# ---------------------------------------------------------------------------
# Picking the assets
# ---------------------------------------------------------------------------


def test_it_finds_the_archive_and_the_checksums(plugin, updater):
    release = plugin.require("json").decode(json.dumps(release_json()))
    asset, sums, name = updater.pickAssets(release)

    assert name == "inat-lightroom-0.2.0.zip"
    assert asset.endswith("inat-lightroom-0.2.0.zip")
    assert sums.endswith("SHA256SUMS")


def test_it_ignores_an_asset_hosted_somewhere_else(plugin, updater):
    payload = release_json(
        assets=[
            {
                "name": "inat-lightroom-0.2.0.zip",
                "browser_download_url": "https://example.com/inat-lightroom-0.2.0.zip",
            }
        ]
    )
    release = plugin.require("json").decode(json.dumps(payload))
    asset, _sums, _name = updater.pickAssets(release)

    assert asset is None, (
        "the downloader must only ever be pointed at this repository's own "
        "release downloads, whatever the JSON says"
    )


def test_it_ignores_an_asset_that_is_not_the_plugin(plugin, updater):
    payload = release_json(
        assets=[
            {
                "name": "screenshots.zip",
                "browser_download_url": f"{DOWNLOAD}/v0.2.0/screenshots.zip",
            }
        ]
    )
    release = plugin.require("json").decode(json.dumps(payload))
    asset, _sums, name = updater.pickAssets(release)

    assert asset is None and name is None


# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------


DIGEST = "a" * 64
OTHER = "b" * 64


def test_it_reads_the_digest_for_the_named_file(updater):
    sums = f"{DIGEST}  inat-lightroom-0.2.0.zip\n{OTHER}  other.zip\n"
    assert updater.hashFor(sums, "inat-lightroom-0.2.0.zip") == DIGEST


def test_it_reads_the_binary_marker_form(updater):
    # sha256sum writes '*name' for a file read in binary mode.
    sums = f"{DIGEST} *inat-lightroom-0.2.0.zip\n"
    assert updater.hashFor(sums, "inat-lightroom-0.2.0.zip") == DIGEST


def test_it_will_not_verify_a_file_against_another_files_digest(updater):
    sums = f"{OTHER}  something-else.zip\n"
    assert updater.hashFor(sums, "inat-lightroom-0.2.0.zip") is None, (
        "a release carrying several archives must never have one checked "
        "against another's hash"
    )


def test_a_truncated_digest_is_not_a_digest(updater):
    sums = "abc123  inat-lightroom-0.2.0.zip\n"
    assert updater.hashFor(sums, "inat-lightroom-0.2.0.zip") is None


# ---------------------------------------------------------------------------
# Asking GitHub
# ---------------------------------------------------------------------------


def test_it_asks_the_latest_release_endpoint():
    plugin, updater, fake = make()
    plugin.call(updater.latestRelease)

    assert fake.requests[0]["url"] == (
        f"https://api.github.com/repos/{OWNER_REPO}/releases/latest"
    )


def test_it_identifies_itself_when_it_asks():
    plugin, updater, fake = make()
    plugin.call(updater.latestRelease)

    fields = {h["field"]: h["value"] for h in _headers(fake.requests[0]["headers"])}
    assert "User-Agent" in fields, (
        "GitHub's API rejects requests with no user agent"
    )


def _headers(raw):
    return [raw[i] for i in range(1, len(raw) + 1)]


def test_it_reads_the_release_it_is_given():
    plugin, updater, _fake = make()
    release, err = plugin.call(updater.latestRelease)

    assert err is None
    assert release.tag == "v0.2.0"
    assert release.version.minor == 2
    assert release.assetName == "inat-lightroom-0.2.0.zip"


def test_a_repository_with_no_releases_is_not_an_error_worth_hiding():
    plugin, updater, _fake = make(status=404)
    release, err = plugin.call(updater.latestRelease)

    assert release is None
    assert "404" in err, "the reason has to survive as far as the user"


def test_a_release_that_is_not_named_like_a_version_is_refused():
    plugin, updater, _fake = make(release_json(tag="nightly"))
    release, err = plugin.call(updater.latestRelease)

    assert release is None
    assert "version" in err


def test_nonsense_instead_of_json_is_reported_not_raised():
    class Garbage:
        def __call__(self, method, url, body, headers):
            return "<html>rate limited</html>", {"status": 200}

    plugin = LuaPlugin(http_handler=Garbage())
    updater = plugin.require("Updater")
    release, err = plugin.call(updater.latestRelease)

    assert release is None
    assert "JSON" in err


# ---------------------------------------------------------------------------
# The whole check
# ---------------------------------------------------------------------------


def test_a_newer_release_with_both_assets_can_be_installed():
    plugin, updater, _fake = make(release_json(tag="v9.9.9"))
    result, err = plugin.call(updater.check)

    assert err is None
    assert result.isNewer is True
    assert result.canInstall is True


def test_a_newer_release_with_no_archive_cannot_be_installed():
    payload = release_json(tag="v9.9.9", assets=[])
    plugin, updater, _fake = make(payload)
    result, _err = plugin.call(updater.check)

    assert result.isNewer is True
    assert result.canInstall is False, (
        "a release published by hand has no archive attached, and an Install "
        "button that cannot work is worse than saying so"
    )


def test_the_current_release_is_not_an_update():
    installed = LuaPlugin().require("Updater").currentVersion()
    tag = "v%d.%d.%d" % (installed.major, installed.minor, installed.revision)

    plugin, updater, _fake = make(release_json(tag=tag))
    result, _err = plugin.call(updater.check)

    assert result.isNewer is False
    assert result.canInstall is False


def test_the_expected_hash_comes_from_the_checksum_asset():
    sums = f"{DIGEST}  inat-lightroom-0.2.0.zip\n"
    plugin, updater, _fake = make(sums=sums)

    release, _err = plugin.call(updater.latestRelease)
    digest, err = plugin.call(updater.expectedHash, release)

    assert err is None
    assert digest == DIGEST


def test_a_missing_checksum_file_is_an_error_not_a_pass():
    plugin, updater, _fake = make(sums=None)

    release, _err = plugin.call(updater.latestRelease)
    digest, err = plugin.call(updater.expectedHash, release)

    assert digest is None
    assert err, (
        "no checksum must never be treated as a checksum that matched"
    )
