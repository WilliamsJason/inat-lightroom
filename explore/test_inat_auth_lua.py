"""Tests for InatAuth.lua, run against a real Lua 5.1 with stubbed SDK modules.

The regression that prompted this: pasting a freshly minted token reported
"Your iNaturalist token has expired". PluginInit validated by calling
getToken(true), and forceRefresh unconditionally bypassed the stored token --
but with no OAuth application configured there is nothing to refresh *from*, so
it fell through to the expiry error. The token was fine the whole time.
"""

from __future__ import annotations

import time

import pytest

pytest.importorskip("lupa.lua51", reason="lupa is not installed")

from lua_harness import LuaPlugin, make_jwt

HOUR = 3600


@pytest.fixture
def plugin():
    return LuaPlugin()


@pytest.fixture
def auth(plugin):
    return plugin.require("InatAuth")


def valid_token(hours_remaining: float = 24) -> str:
    return make_jwt(int(time.time() + hours_remaining * HOUR))


def test_stores_and_returns_a_valid_token(plugin, auth):
    token = valid_token()

    stored, err = plugin.call(auth.storeApiToken, token)
    assert stored, err

    assert plugin.call(auth.getToken) == (token, None)


def test_force_refresh_keeps_a_freshly_pasted_token(plugin, auth):
    """The reported bug: validating a new token must not declare it expired."""
    token = valid_token()
    plugin.call(auth.storeApiToken, token)

    # PluginInit validates with forceRefresh set. With no OAuth application
    # there is nothing to refresh from, so the stored token must come back.
    value, err = plugin.call(auth.getToken, True)

    assert err is None
    assert value == token


def test_accepts_the_full_json_response_body(plugin, auth):
    token = valid_token()

    plugin.call(auth.storeApiToken, '{"api_token":"%s"}' % token)

    assert plugin.call(auth.getToken)[0] == token


def test_tolerates_surrounding_whitespace(plugin, auth):
    token = valid_token()

    plugin.call(auth.storeApiToken, f"  \n {token} \n ")

    assert plugin.call(auth.getToken)[0] == token


def test_reads_expiry_from_the_token_itself(plugin, auth):
    plugin.call(auth.storeApiToken, valid_token(hours_remaining=5))

    remaining = auth.tokenSecondsRemaining()

    # Expiry comes from the JWT's exp claim, not from when it was pasted.
    assert abs(remaining - 5 * HOUR) < 60


def test_rejects_an_already_expired_token(plugin, auth):
    stored, err = plugin.call(auth.storeApiToken, make_jwt(int(time.time()) - HOUR))

    assert not stored
    assert "expired" in err
    assert plugin.call(auth.getToken)[0] is None


@pytest.mark.parametrize(
    "value",
    [
        pytest.param("not-a-token", id="plain-text"),
        pytest.param("https://www.inaturalist.org/users/api_token", id="url"),
        pytest.param("abc.def", id="two-segments"),
        pytest.param("", id="empty"),
    ],
)
def test_rejects_things_that_are_not_tokens(plugin, auth, value):
    stored, err = plugin.call(auth.storeApiToken, value)

    assert not stored
    assert err


def test_treats_a_nearly_expired_token_as_unusable(plugin, auth):
    """Refreshing early stops a token dying part-way through a long export."""
    plugin.call(auth.storeApiToken, valid_token(hours_remaining=0.25))

    value, err = plugin.call(auth.getToken)

    assert value is None
    assert "expired" in err


def test_expired_token_error_explains_how_to_fix_it(plugin, auth):
    plugin.call(auth.storeApiToken, valid_token())

    # Age the stored token past its expiry.
    plugin.prefs["apiTokenExpiresAt"] = int(time.time()) - 60

    value, err = plugin.call(auth.getToken)

    assert value is None
    assert "users/api_token" in err


def test_reports_nothing_configured_before_setup(plugin, auth):
    value, err = plugin.call(auth.getToken)

    assert value is None
    assert "not set up" in err


def test_clear_removes_the_stored_token(plugin, auth):
    plugin.call(auth.storeApiToken, valid_token())

    auth.clear()

    assert plugin.call(auth.getToken)[0] is None
    assert auth.tokenSecondsRemaining() is None


def test_falls_back_to_paste_time_when_expiry_is_unreadable(plugin, auth):
    """A token whose payload will not decode is still usable for a while."""
    # Structurally a JWT, but the payload is not base64-encoded JSON.
    stored, _ = plugin.call(auth.storeApiToken, "aGVhZGVy.bm90LWpzb24.c2ln")
    assert stored

    remaining = auth.tokenSecondsRemaining()

    assert remaining is not None
    assert abs(remaining - 24 * HOUR) < 60


def test_token_is_not_written_to_preferences(plugin, auth):
    """Secrets belong in LrPasswords; prefs are plain-text bookkeeping."""
    token = valid_token()
    plugin.call(auth.storeApiToken, token)

    stored_prefs = plugin.eval(
        "function(p) local out = {} for k, v in pairs(p) do "
        "out[#out + 1] = tostring(v) end return table.concat(out, '|') end"
    )(plugin.prefs)

    assert token not in stored_prefs
    assert plugin.passwords["api_token"] == token
