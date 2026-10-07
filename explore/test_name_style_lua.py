"""Which way round a taxon's two names go -- the account's answer, not ours.

Covers NameStyle.lua. iNaturalist settles this per account in Settings >
Content & Display, and exposes the answer on GET /v1/users/me as
``prefers_common_names`` and ``prefers_scientific_name_first``. The public user
record carries no preferences at all, so that one route is the only source.

The important subtlety is that a preference row only exists once it differs
from the default, so a *missing* field means "default", not "false". Getting
that backwards would silently strip every common name from the panel for every
account that never touched the setting -- which is most of them.
"""

from __future__ import annotations

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def style(plugin):
    return plugin.require("NameStyle")


def styled(plugin, common, scientific_first):
    return plugin.runtime.table_from({
        "commonNames": common,
        "scientificFirst": scientific_first,
    })


def api(plugin, user=None, error=None):
    """An API client with just the one method NameStyle asks for.

    Built in Lua rather than from Python callables, because NameStyle guards
    with ``type(api.currentUser) == "function"`` and a Python function crossing
    the bridge is not one.

    Returns (client, calls), where ``calls`` is a Lua list it appends to.
    """
    builder = plugin.eval(
        """
        function(user, err)
          local calls = {}
          local api = { calls = calls }

          function api:currentUser()
            calls[#calls + 1] = true
            if user == nil then return nil, err end
            return user, nil
          end

          return api
        end
        """)

    client = builder(
        plugin.runtime.table_from(user) if user is not None else None,
        error or "no")

    return client, client["calls"]


# -----------------------------------------------------------------------------
# format -- the four combinations
# -----------------------------------------------------------------------------

def test_common_names_first_is_the_iNaturalist_default(plugin, style):
    assert style["format"]("Ischnura erratica", "Swift Forktail",
                           styled(plugin, True, False)) == \
        "Swift Forktail (Ischnura erratica)"


def test_scientific_first_puts_the_binomial_in_front(plugin, style):
    assert style["format"]("Ischnura erratica", "Swift Forktail",
                           styled(plugin, True, True)) == \
        "Ischnura erratica (Swift Forktail)"


def test_common_names_off_drops_the_common_name_entirely(plugin, style):
    """Not "moves it to the back" -- iNaturalist itself shows the binomial
    alone, and parenthesising the thing somebody switched off would be an odd
    way of honouring the setting."""
    assert style["format"]("Ischnura erratica", "Swift Forktail",
                           styled(plugin, False, False)) == "Ischnura erratica"


def test_common_names_off_ignores_the_ordering_preference(plugin, style):
    assert style["format"]("Ischnura erratica", "Swift Forktail",
                           styled(plugin, False, True)) == "Ischnura erratica"


# -----------------------------------------------------------------------------
# format -- the awkward inputs
# -----------------------------------------------------------------------------

def test_a_taxon_with_no_common_name_is_just_its_binomial(plugin, style):
    assert style["format"]("Dolomedes", None,
                           styled(plugin, True, False)) == "Dolomedes"


def test_an_empty_common_name_counts_as_absent(plugin, style):
    assert style["format"]("Dolomedes", "",
                           styled(plugin, True, False)) == "Dolomedes"


def test_the_same_word_twice_is_not_shown_twice(plugin, style):
    """Plenty of taxa report the scientific name in the common name's place,
    and "Dolomedes (Dolomedes)" reads as a bug rather than as thoroughness."""
    assert style["format"]("Dolomedes", "Dolomedes",
                           styled(plugin, True, False)) == "Dolomedes"


def test_a_common_name_alone_survives_common_names_being_off(plugin, style):
    """The setting is a preference between two names. With only one there is no
    preference to express, and dropping it would leave an empty row."""
    assert style["format"](None, "Forktails",
                           styled(plugin, False, False)) == "Forktails"


def test_no_names_at_all_is_empty_rather_than_a_crash(plugin, style):
    assert style["format"](None, None, styled(plugin, True, False)) == ""


def test_format_without_a_style_uses_whatever_is_in_force(plugin, style):
    assert style["format"]("Ischnura erratica", "Swift Forktail") == \
        "Swift Forktail (Ischnura erratica)"


# -----------------------------------------------------------------------------
# of -- reading a user record
# -----------------------------------------------------------------------------

def test_an_absent_field_means_the_default_not_false(plugin, style):
    """The preference row only exists once it differs from the default, so an
    account that never changed the setting sends nothing at all."""
    got = style["of"](plugin.runtime.table_from({"id": 1, "login": "someone"}))

    assert got["commonNames"] is True
    assert got["scientificFirst"] is False


def test_an_explicit_false_is_honoured(plugin, style):
    got = style["of"](plugin.runtime.table_from({
        "prefers_common_names": False,
        "prefers_scientific_name_first": True,
    }))

    assert got["commonNames"] is False
    assert got["scientificFirst"] is True


def test_no_user_at_all_is_the_default_style(plugin, style):
    got = style["of"](None)

    assert got["commonNames"] is True
    assert got["scientificFirst"] is False


# -----------------------------------------------------------------------------
# load, current, forget
# -----------------------------------------------------------------------------

def test_the_style_is_the_default_until_the_account_is_read(plugin, style):
    got = style["current"]()

    assert got["commonNames"] is True
    assert got["scientificFirst"] is False


def test_loading_adopts_the_accounts_answer(plugin, style):
    client, _ = api(plugin, {"prefers_scientific_name_first": True})

    style["load"](client)

    assert style["current"]()["scientificFirst"] is True


def test_loading_twice_only_asks_once(plugin, style):
    client, calls = api(plugin, {"prefers_scientific_name_first": True})

    style["load"](client)
    style["load"](client)

    assert len(list(calls.values())) == 1


def test_a_failed_lookup_leaves_the_default_standing(plugin, style):
    """A name in the wrong order is a cosmetic disappointment. Refusing to show
    a suggestion list because preferences could not be read would not be."""
    client, _ = api(plugin, None, "401 Unauthorized")

    style["load"](client)

    assert style["current"]()["commonNames"] is True


def test_a_failed_lookup_is_retried_next_time(plugin, style):
    client, calls = api(plugin, None, "offline")

    style["load"](client)
    style["load"](client)

    assert len(list(calls.values())) == 2


def test_no_api_client_at_all_is_survivable(plugin, style):
    """Signing in is not required to open the panel, and requireAPI answers nil
    for anyone who has not."""
    assert style["load"](None)["commonNames"] is True


def test_an_api_without_currentUser_is_survivable(plugin, style):
    older = plugin.runtime.table_from({})

    assert style["load"](older)["commonNames"] is True


def test_forgetting_sends_the_next_load_back_to_the_account(plugin, style):
    client, calls = api(plugin, {"prefers_scientific_name_first": True})

    style["load"](client)
    style["forget"]()

    assert style["current"]()["scientificFirst"] is False

    style["load"](client)

    assert len(list(calls.values())) == 2
