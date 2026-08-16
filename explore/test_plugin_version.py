"""The tag and Info.lua have to agree.

Covers plugin_version.py, which is what the release workflow runs before it
builds anything.

This check exists because the updater compares the tag published on GitHub
against the version compiled into the installed plugin. If those disagree, the
failure is silent and permanent in one of two directions: a plugin that never
sees an update, or one that offers the same update every single day.
"""

import pytest

from plugin_version import (
    VersionError,
    check_tag,
    number_string,
    read_version,
    tag_for,
)


@pytest.fixture
def version():
    return read_version()


def test_it_reads_the_shipped_version(version):
    assert version["major"] is not None
    assert number_string(version).count(".") == 2


def test_the_shipped_version_agrees_with_its_own_tag(version):
    assert check_tag(tag_for(version), version) == []


def test_a_tag_that_does_not_match_is_rejected(version):
    problems = check_tag("v99.0.0", version)
    assert problems, "a mismatched tag must stop the release, not warn about it"
    assert "Info.lua" in problems[0]


def test_the_shipped_version_is_not_a_pre_release(version):
    assert "pre-release" not in str(version["display"]), (
        "a release built from a plugin that calls itself pre-release ships "
        "that label to everyone who installs it"
    )


def test_a_pre_release_display_string_is_rejected():
    fake = {"major": 0, "minor": 1, "revision": 0, "display": "0.1.0 (pre-release)"}
    assert any("pre-release" in problem for problem in check_tag("v0.1.0", fake))


def test_a_display_string_that_disagrees_with_the_numbers_is_rejected():
    fake = {"major": 0, "minor": 2, "revision": 0, "display": "0.1.0"}
    problems = check_tag("v0.2.0", fake)
    assert any("display" in problem for problem in problems), (
        "the Plug-in Manager shows the display string, so it must not "
        "disagree with the release it came from"
    )


def test_a_missing_info_lua_is_an_error_not_a_default(tmp_path):
    missing = tmp_path / "Info.lua"
    missing.write_text("return { }", encoding="utf-8")

    with pytest.raises(VersionError):
        read_version(missing)


def test_it_survives_an_info_lua_full_of_brackets(tmp_path):
    # Info.lua is read by running it, and it is wrapped in a Lua long string to
    # get there. A file containing ]] would end that string early and the
    # remainder would be compiled as if it were code.
    info = tmp_path / "Info.lua"
    info.write_text(
        '-- a closing long bracket ]] and a longer one ]=] in a comment\n'
        'local marker = "]] ]=] ]==]"\n'
        "return { VERSION = { major = 1, minor = 2, revision = 3, "
        "display = '1.2.3', note = marker } }",
        encoding="utf-8",
    )

    assert number_string(read_version(info)) == "1.2.3"
