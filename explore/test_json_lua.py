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
