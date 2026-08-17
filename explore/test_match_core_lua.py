"""Tests for MatchCore.lua -- deciding which photo an observation came from.

Reverse Sync links photos to observations without the user checking each one,
which makes this the module whose mistakes are least visible. A wrong keyword
shows up in the Library; a photo linked to the wrong observation looks exactly
like a photo linked to the right one, and stays wrong through every later sync.

So the cases here are mostly the ways a match can be confidently wrong: times
that parse into the wrong instant, obscured coordinates that look like a
location conflict, bursts where several photos fit equally well.

MatchCore imports nothing from the SDK, so it runs under plain Lua rather than
through the plugin harness's stubs.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def match(plugin):
    return plugin.require("MatchCore")


def observation(plugin, **fields):
    return plugin.runtime.table_from(fields)


# ---------------------------------------------------------------- timestamps


@pytest.mark.parametrize(
    "text,expected",
    [
        ("2017-04-29T10:22:27-07:00", (2017, 4, 29, 10, 22, 27, -420)),
        ("2017-04-29T10:22:27+05:30", (2017, 4, 29, 10, 22, 27, 330)),
        ("2017-04-29T10:22:27Z", (2017, 4, 29, 10, 22, 27, 0)),
        ("2017-04-29T10:22:27+0530", (2017, 4, 29, 10, 22, 27, 330)),
        ("2017-04-29 10:22:27", (2017, 4, 29, 10, 22, 27, None)),
        ("2017-04-29T10:22:27.500-07:00", (2017, 4, 29, 10, 22, 27, -420)),
    ],
)
def test_parses_the_shapes_the_api_emits(match, text, expected):
    parts = match.parseTimestamp(text)
    assert parts is not None, text
    year, month, day, hour, minute, second, offset = expected
    assert (parts.year, parts.month, parts.day) == (year, month, day)
    assert (parts.hour, parts.min, parts.sec) == (hour, minute, second)
    assert parts.offset == offset


@pytest.mark.parametrize(
    "text",
    [
        "2017-04-29",           # a date is not a time
        "29/04/2017 10:22:27",  # not ISO at all
        "2017-13-01T10:22:27",  # month 13
        "2017-02-30T10:22:27",  # February never has 30 days
        "2017-04-29T25:00:00",  # hour 25
        "",
        None,
    ],
)
def test_refuses_to_guess_at_what_it_cannot_read(match, text):
    """A misparsed time is worse than no time: it matches the wrong photo
    confidently rather than skipping the observation visibly."""
    assert match.parseTimestamp(text) is None


def test_leap_day_is_a_real_date(match):
    assert match.parseTimestamp("2016-02-29T12:00:00Z") is not None
    assert match.parseTimestamp("2017-02-29T12:00:00Z") is None


def test_the_offset_is_parsed_but_not_applied(match):
    """The wall clock is the common ground between EXIF and iNaturalist.

    Applying the offset would move the observation off the photo it came from,
    since the camera's clock never knew about zones.
    """
    east = match.parseTimestamp("2017-04-29T10:22:27+05:30")
    west = match.parseTimestamp("2017-04-29T10:22:27-07:00")
    assert match.toSeconds(east) == match.toSeconds(west)
    assert east.offset != west.offset


# ------------------------------------------------------------ civil calendar


@pytest.mark.parametrize(
    "text,seconds",
    [
        ("1970-01-01T00:00:00Z", 0),
        ("2000-01-01T00:00:00Z", 946684800),
        ("2017-04-29T10:22:27Z", 1493461347),
        ("1969-12-31T23:59:59Z", -1),
    ],
)
def test_seconds_agree_with_the_unix_epoch(match, text, seconds):
    assert match.toSeconds(match.parseTimestamp(text)) == seconds


@pytest.mark.parametrize(
    "text",
    [
        "1904-02-29T06:00:00Z",
        "1970-01-01T00:00:00Z",
        "1999-12-31T23:59:59Z",
        "2000-02-29T12:00:00Z",
        "2017-04-29T10:22:27Z",
        "2100-03-01T00:00:00Z",
    ],
)
def test_seconds_round_trip(match, text):
    """fromSeconds is the inverse of toSeconds, including across the century
    rules that make 1900 an ordinary year and 2000 a leap one."""
    original = match.parseTimestamp(text)
    seconds = match.toSeconds(original)
    back = match.fromSeconds(seconds)
    assert match.formatSearchValue(back) == text.replace("Z", "")


# ---------------------------------------------------------------- the window


def test_window_brackets_the_observation(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27-07:00")
    start, end = match.windowFor(obs, 2)
    assert start == "2017-04-29T10:22:25"
    assert end == "2017-04-29T10:22:29"


def test_window_is_formatted_the_only_way_findphotos_accepts(plugin, match):
    """LrDate.timeToW3CDate output matches nothing at all -- silently, with an
    empty result rather than an error -- so the format is pinned here."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    start, _ = match.windowFor(obs, 2)
    assert "." not in start
    assert "+" not in start
    assert not start.endswith("Z")
    assert len(start) == len("2017-04-29T10:22:25")


def test_window_crosses_midnight(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T23:59:59Z")
    start, end = match.windowFor(obs, 2)
    assert start == "2017-04-29T23:59:57"
    assert end == "2017-04-30T00:00:01"


def test_window_crosses_a_leap_day(plugin, match):
    obs = observation(plugin, time_observed_at="2016-02-28T23:59:59Z")
    _, end = match.windowFor(obs, 2)
    assert end == "2016-02-29T00:00:01"


def test_date_only_observations_have_no_window(plugin, match):
    """observed_on without a time would match a whole day, which is a
    coincidence rather than a match. Skipped, not widened."""
    obs = observation(plugin, observed_on="2017-04-29")
    start, end = match.windowFor(obs, 2)
    assert start is None and end is None


def test_falls_back_to_observed_on_string(plugin, match):
    obs = observation(plugin, observed_on_string="2017-04-29 10:22:27")
    start, _ = match.windowFor(obs, 2)
    assert start == "2017-04-29T10:22:25"


# ------------------------------------------------------------------ location


def test_obscured_observations_offer_no_location(plugin, match):
    """An obscured observation reports a deliberately wrong public location, in
    the same field and format as an honest one. Believing it would demote every
    obscured observation to a location conflict."""
    obs = observation(
        plugin,
        obscured=True,
        location="45.100000,-122.100000",  # wrong on purpose, ~30 km out
    )
    latitude, longitude = match.coordinatesFrom(obs)
    assert latitude is None and longitude is None


def test_private_location_is_believed_even_when_obscured(plugin, match):
    obs = observation(
        plugin,
        obscured=True,
        location="45.100000,-122.100000",
        private_location="45.512300,-122.658000",
    )
    latitude, longitude = match.coordinatesFrom(obs)
    assert latitude == pytest.approx(45.5123)
    assert longitude == pytest.approx(-122.658)


def test_distance_is_great_circle(match):
    # Portland to Seattle, about 233 km.
    metres = match.distanceMetres(45.5152, -122.6784, 47.6062, -122.3321)
    assert 230_000 < metres < 236_000


def test_distance_needs_both_ends(match):
    assert match.distanceMetres(45.5, -122.6, None, None) is None


# -------------------------------------------------------------------- rating


def photo_info(plugin, match, when, latitude=None, longitude=None, name="p"):
    seconds = match.toSeconds(match.parseTimestamp(when))
    return plugin.runtime.table_from(
        {"photo": name, "seconds": seconds,
         "latitude": latitude, "longitude": longitude}
    )


def test_nearby_location_confirms(plugin, match):
    obs = observation(
        plugin,
        time_observed_at="2017-04-29T10:22:27Z",
        location="45.512300,-122.658000",
    )
    info = photo_info(plugin, match, "2017-04-29T10:22:27Z", 45.5123, -122.658)
    tier, distance, apart = match.rate(obs, info)
    assert tier == match.CONFIRMED
    assert distance < 10
    assert apart == 0


def test_distant_location_conflicts_but_does_not_reject(plugin, match):
    """A conflict is reported rather than dropped: 'iNat thinks this was 200 km
    away' is something the user can adjudicate and this module cannot."""
    obs = observation(
        plugin,
        time_observed_at="2017-04-29T10:22:27Z",
        location="47.606200,-122.332100",
    )
    info = photo_info(plugin, match, "2017-04-29T10:22:27Z", 45.5123, -122.658)
    tier, _, _ = match.rate(obs, info)
    assert tier == match.CONFLICT


def test_middle_distances_are_neither_evidence_nor_objection(plugin, match):
    """A phone observation logged from the car park at the end of a walk is a
    normal way to be a kilometre from the photo it describes."""
    obs = observation(
        plugin,
        time_observed_at="2017-04-29T10:22:27Z",
        location="45.521300,-122.658000",  # ~1 km north
    )
    info = photo_info(plugin, match, "2017-04-29T10:22:27Z", 45.5123, -122.658)
    tier, distance, _ = match.rate(obs, info)
    assert tier == match.LIKELY
    assert 500 < distance < 2000


def test_no_location_anywhere_is_likely_not_confirmed(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    info = photo_info(plugin, match, "2017-04-29T10:22:27Z")
    tier, distance, _ = match.rate(obs, info)
    assert tier == match.LIKELY
    assert distance is None


# ------------------------------------------------------------------ choosing


def test_closest_in_time_wins(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from(
        [
            photo_info(plugin, match, "2017-04-29T10:22:25Z"),
            photo_info(plugin, match, "2017-04-29T10:22:27Z"),
        ]
    )
    best = match.chooseMatch(obs, candidates)
    assert best.secondsApart == 0


def test_a_burst_is_reported_as_ambiguous(plugin, match):
    """Frames a second apart are one observation and several equally good
    photos. Picking the first quietly would link an arbitrary one."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from(
        [
            photo_info(plugin, match, "2017-04-29T10:22:26Z", name="a"),
            photo_info(plugin, match, "2017-04-29T10:22:27Z", name="b"),
            photo_info(plugin, match, "2017-04-29T10:22:28Z", name="c"),
        ]
    )
    best = match.chooseMatch(obs, candidates)
    assert best.ambiguous is True
    assert best.alternatives == 2


def test_candidates_are_counted_by_position_not_identity(plugin, match):
    """Regression: alternatives were counted by comparing photo values, so
    candidates that happened to compare equal -- virtual copies, or any caller
    reusing one table -- collapsed into a single row and a burst reported
    itself as unambiguous."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from(
        [
            photo_info(plugin, match, "2017-04-29T10:22:27Z", name="same"),
            photo_info(plugin, match, "2017-04-29T10:22:27Z", name="same"),
        ]
    )
    best = match.chooseMatch(obs, candidates)
    assert best.ambiguous is True
    assert best.alternatives == 1


def test_a_single_candidate_is_not_ambiguous(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from(
        [photo_info(plugin, match, "2017-04-29T10:22:27Z")]
    )
    best = match.chooseMatch(obs, candidates)
    assert best.ambiguous is False
    assert best.alternatives == 0


def test_location_breaks_a_tie_time_cannot(plugin, match):
    """Two frames equally distant in time, one of them standing where the
    observation says it happened."""
    obs = observation(
        plugin,
        time_observed_at="2017-04-29T10:22:27Z",
        location="45.512300,-122.658000",
    )
    near = photo_info(plugin, match, "2017-04-29T10:22:28Z", 45.5123, -122.658)
    far = photo_info(plugin, match, "2017-04-29T10:22:28Z", 47.6062, -122.3321)
    candidates = plugin.runtime.table_from([far, near])

    best = match.chooseMatch(obs, candidates)
    assert best.tier == match.CONFIRMED


def test_no_candidates_is_no_match(plugin, match):
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    assert match.chooseMatch(obs, plugin.runtime.table_from([])) is None


# ------------------------------------------------------------ ranking them all

def test_ranking_returns_every_candidate_closest_first(plugin, match):
    """One observation may legitimately have several photos, so the caller wants
    the whole field ranked rather than a winner and a count of the rest."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from([
        photo_info(plugin, match, "2017-04-29T10:22:29Z", name="c"),
        photo_info(plugin, match, "2017-04-29T10:22:27Z", name="a"),
        photo_info(plugin, match, "2017-04-29T10:22:28Z", name="b"),
    ])

    ranked = match.rankMatches(obs, candidates)

    assert len(ranked) == 3
    assert [ranked[row].secondsApart for row in (1, 2, 3)] == [0, 1, 2]


def test_ranking_keeps_equal_candidates_in_catalog_order(plugin, match):
    """table.sort is not stable. Two frames on the same second would otherwise
    swap places between runs, and the review list would reorder itself for no
    reason the user could see."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from([
        photo_info(plugin, match, "2017-04-29T10:22:27Z", name="first"),
        photo_info(plugin, match, "2017-04-29T10:22:27Z", name="second"),
        photo_info(plugin, match, "2017-04-29T10:22:27Z", name="third"),
    ])

    ranked = match.rankMatches(obs, candidates)

    assert [ranked[row].photo for row in (1, 2, 3)] \
        == ["first", "second", "third"]


def test_ranking_prefers_the_confirmed_frame_on_a_tie(plugin, match):
    """Same judgement chooseMatch makes: location breaks a tie time cannot."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z",
                      location="45.512300,-122.658000")
    far = photo_info(plugin, match, "2017-04-29T10:22:28Z", 47.6062, -122.3321)
    near = photo_info(plugin, match, "2017-04-29T10:22:28Z", 45.5123, -122.658)
    candidates = plugin.runtime.table_from([far, near])

    ranked = match.rankMatches(obs, candidates)

    assert ranked[1].tier == match.CONFIRMED


def test_ranking_nothing_is_an_empty_list_not_nil(plugin, match):
    """The caller loops over the result; nil would be an error rather than an
    empty afternoon."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")

    assert len(match.rankMatches(obs, plugin.runtime.table_from([]))) == 0


def test_ranking_leaves_no_bookkeeping_on_the_rows(plugin, match):
    """The rows go straight into the review list and out to the linker, so a
    stray sort key would travel with them."""
    obs = observation(plugin, time_observed_at="2017-04-29T10:22:27Z")
    candidates = plugin.runtime.table_from(
        [photo_info(plugin, match, "2017-04-29T10:22:27Z")])

    ranked = match.rankMatches(obs, candidates)

    assert ranked[1]._score is None
    assert ranked[1]._index is None


# ------------------------------------------------------- minute precision
#
# iNaturalist's web uploader formats EXIF through moment.js as
# "YYYY/MM/DD h:mm A" -- no seconds token -- and Chronic parses that back
# with the seconds zeroed. Confirmed against a real photo: DSC00045.ARW was
# shot at 20:03:41 and the observation reads 20:03:00. Two thirds of a real
# account arrived this way, and every one of them was invisible to a two
# second window.


def truncated(plugin, **extra):
    """An observation as the web uploader leaves it: no seconds anywhere."""
    fields = {"time_observed_at": "2025-05-30T20:03:00-06:00",
              "observed_on_string": "2025/05/30 8:03 PM"}
    fields.update(extra)
    return observation(plugin, **fields)


def exact(plugin, **extra):
    """An observation as the mobile app leaves it: seconds all the way down."""
    fields = {"time_observed_at": "2025-05-30T20:03:41-06:00",
              "observed_on_string": "2025-05-30T20:03:41"}
    fields.update(extra)
    return observation(plugin, **fields)


def test_a_truncated_time_is_recognised_as_minute_precision(match, plugin):
    assert match.isMinutePrecision(truncated(plugin)) is True


def test_seconds_written_down_are_believed_even_when_zero(match, plugin):
    """The mobile app sends ISO-8601; :00 from it is a real :00."""
    obs = observation(plugin, time_observed_at="2025-05-30T20:03:00-06:00",
                      observed_on_string="2025-05-30T20:03:00")
    assert match.isMinutePrecision(obs) is False


def test_a_time_with_seconds_is_not_minute_precision(match, plugin):
    assert match.isMinutePrecision(exact(plugin)) is False


def test_the_window_covers_the_whole_minute_after_a_truncated_time(match, plugin):
    """DSC00045.ARW sits at :41 and has to fall inside."""
    start, finish = match.windowFor(truncated(plugin), 2)
    assert start == "2025-05-30T20:02:58"
    assert finish == "2025-05-30T20:04:01"


def test_the_window_does_not_widen_backwards(match, plugin):
    """Truncation only ever loses time forwards, so :00 is the earliest."""
    start, _ = match.windowFor(truncated(plugin), 0)
    assert start == "2025-05-30T20:03:00"


def test_an_exact_time_keeps_its_tight_window(match, plugin):
    start, finish = match.windowFor(exact(plugin), 2)
    assert start == "2025-05-30T20:03:39"
    assert finish == "2025-05-30T20:03:43"


def test_a_photo_inside_the_minute_is_not_reported_as_seconds_out(match, plugin):
    """Every frame in the minute fits what iNaturalist actually recorded."""
    seconds = match.toSeconds(match.parseTimestamp("2025-05-30T20:03:41-06:00"))
    _, _, apart = match.rate(truncated(plugin),
                             plugin.runtime.table_from({"seconds": seconds}))
    assert apart == 0


def test_a_photo_outside_the_minute_is_measured_from_the_minute(match, plugin):
    seconds = match.toSeconds(match.parseTimestamp("2025-05-30T20:04:04-06:00"))
    _, _, apart = match.rate(truncated(plugin),
                             plugin.runtime.table_from({"seconds": seconds}))
    assert apart == 5


def test_frames_across_a_truncated_minute_rank_by_position_not_by_second(
        match, plugin):
    """None of them is closer to the truth than another, so order is stable."""
    def at(text):
        return {"seconds": match.toSeconds(match.parseTimestamp(text)),
                "path": text}

    candidates = plugin.runtime.table_from([
        plugin.runtime.table_from(at("2025-05-30T20:03:52-06:00")),
        plugin.runtime.table_from(at("2025-05-30T20:03:03-06:00")),
    ])
    ranked = match.rankMatches(truncated(plugin), candidates)

    assert [ranked[1].secondsApart, ranked[2].secondsApart] == [0, 0]
    assert ranked[1].path == "2025-05-30T20:03:52-06:00"
