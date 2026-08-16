"""Tests for json.lua -- specifically the nulls iNaturalist is full of.

The bug this exists for: parse_object worked out whether it still needed a
comma by asking whether the table it was filling was empty. Since null decodes
to nil, a pair whose value was null left it empty, the comma before the next
key went unconsumed, and the parser blamed the key for not being a string:

    could not parse the response (json.lua:128: expected string key at line 1
    col 5829)

Which is a message about a key, thousands of characters from the null that
actually caused it.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def json_lua(plugin):
    return plugin.require("json")


def decode(json_lua, text):
    return json_lua.decode(text)


# -------------------------------------------------------------------- nulls

def test_a_null_first_field_does_not_break_the_object(plugin, json_lua):
    """This is the exact shape that failed. Everything after the null was lost
    -- and with it, in the real response, the whole page of observations."""
    result = decode(json_lua, '{"a":null,"b":1}')

    assert result["a"] is None
    assert result["b"] == 1


def test_a_null_in_the_middle_does_not_break_the_object(plugin, json_lua):
    result = decode(json_lua, '{"a":1,"b":null,"c":2}')

    assert result["a"] == 1
    assert result["c"] == 2


def test_an_object_of_nothing_but_nulls_is_still_an_object(plugin, json_lua):
    """Every pair leaves the table empty, so every iteration after the first
    took the wrong branch."""
    result = decode(json_lua, '{"a":null,"b":null,"c":null}')

    assert dict(result) == {}


def test_a_null_only_object_still_finds_its_closing_brace(plugin, json_lua):
    """The parser has to end up past the }, or the caller resumes mid-string."""
    result = decode(json_lua, '{"outer":{"a":null,"b":null},"after":7}')

    assert result["after"] == 7


def test_nested_nulls_do_not_break_the_parent(plugin, json_lua):
    result = decode(json_lua, '{"taxon":{"id":null,"name":"Rana"},"id":42}')

    assert result["taxon"]["name"] == "Rana"
    assert result["id"] == 42


def test_an_observation_shaped_response_decodes(plugin, json_lua):
    """A page of results the way iNaturalist actually sends one: nulls in the
    leading positions, which is what made a real fetch fail."""
    payload = ('{"total_results":2,"page":1,"results":['
               '{"id":1,"community_taxon":null,"taxon":{"id":9,"name":"Rana"},'
               '"time_observed_at":"2024-05-01T10:00:00+00:00"},'
               '{"id":2,"community_taxon":null,"taxon":null,'
               '"description":null,"quality_grade":"casual"}]}')

    result = decode(json_lua, payload)

    assert result["total_results"] == 2
    assert result["results"][1]["taxon"]["name"] == "Rana"
    assert result["results"][2]["quality_grade"] == "casual"


# ------------------------------------------------------- still strict enough

def test_a_genuinely_missing_comma_is_still_an_error(plugin, json_lua):
    """The fix must not turn the comma check off."""
    with pytest.raises(Exception):
        decode(json_lua, '{"a":1 "b":2}')


def test_a_missing_comma_after_a_null_is_still_an_error(plugin, json_lua):
    """The case most easily lost by fixing this the lazy way -- skipping the
    comma requirement whenever the table happens to be empty."""
    with pytest.raises(Exception):
        decode(json_lua, '{"a":null "b":2}')


def test_an_unquoted_key_is_still_an_error(plugin, json_lua):
    with pytest.raises(Exception):
        decode(json_lua, '{a:1}')


# ---------------------------------------------------------------- unchanged

def test_ordinary_objects_still_decode(plugin, json_lua):
    result = decode(json_lua, '{"a":1,"b":"two","c":true,"d":[1,2,3]}')

    assert result["a"] == 1
    assert result["b"] == "two"
    assert result["c"] is True
    assert result["d"][3] == 3


def test_an_empty_object_still_decodes(plugin, json_lua):
    assert dict(decode(json_lua, "{}")) == {}


# ------------------------------------------------------------------- escapes
#
# parse_string now scans in runs between interesting characters rather than one
# character at a time, so the escape handling is worth re-checking at the seams:
# an escape at the very start of a string, at the very end, and back to back.


def test_escapes_survive_the_chunked_scan(plugin, json_lua):
    assert decode(json_lua, r'"\"lead"') == '"lead'
    assert decode(json_lua, r'"trail\""') == 'trail"'
    assert decode(json_lua, r'"a\n\t\\b"') == "a\n\t\\b"
    # json.lua returns UTF-8 bytes, which arrive here as one Python character
    # per byte, so the expectation is written the same way.
    assert decode(json_lua, r'"\u00e9t\u00e9"') == "\xc3\xa9t\xc3\xa9"


def test_an_unterminated_string_is_still_an_error(plugin, json_lua):
    with pytest.raises(Exception):
        decode(json_lua, '{"a":"no end')


def test_a_raw_control_character_is_still_an_error(plugin, json_lua):
    with pytest.raises(Exception):
        decode(json_lua, '"tab\there"')


def test_an_empty_string_still_decodes(plugin, json_lua):
    assert decode(json_lua, '{"a":""}')["a"] == ""


# --------------------------------------------------------------------- size
#
# The reverse sync fetches observations 200 at a time, and one such page really
# is megabytes. Decoding it took so long that Lightroom appeared to have
# crashed: parse_number did str:sub(i) -- copying the entire remaining document
# -- once per number, and parse_string walked a character at a time.
#
# Timed rather than counted because the failure was quadratic, and no assertion
# about behaviour catches that. The margin is large enough that an ordinary slow
# machine passes; the bug this guards was six minutes and still going.


def _big_document(observations=2000):
    import json as pyjson

    rows = [
        {
            "id": 15845541 + i,
            "uuid": "5cf6f775-b0a2-4ff8-b5e4-41633f8117%02d" % (i % 100),
            "observed_on": "2018-08-21",
            "time_observed_at": "2018-08-21T22:00:22-07:00",
            "location": "47.665249362,-122.124891804",
            "positional_accuracy": None,
            "public_positional_accuracy": 26807,
            "obscured": True,
            "taxon": {"id": 60053, "name": "Agulla", "rank": "genus"},
        }
        for i in range(observations)
    ]
    return pyjson.dumps({"total_results": observations, "results": rows})


def test_a_page_sized_document_decodes_promptly(plugin, json_lua):
    import time

    text = _big_document()
    assert len(text) > 500_000, "not big enough to be a fair test"

    start = time.time()
    decoded = decode(json_lua, text)
    elapsed = time.time() - start

    assert plugin.eval("function(t) return #t.results end")(decoded) == 2000
    assert elapsed < 10, "decode took %.1fs; parsing is quadratic again" % elapsed


def test_numbers_late_in_a_large_document_are_still_read_correctly(
    plugin, json_lua
):
    """parse_number matches from an offset now instead of copying the tail, and
    an off-by-one there would corrupt values rather than fail loudly."""
    text = '{"pad":"' + ("x" * 200_000) + '","n":-12.5e3,"m":42}'

    decoded = decode(json_lua, text)

    assert decoded["n"] == -12500
    assert decoded["m"] == 42
