"""Browser sign-in: PKCE, the redirect, and the token that stops expiring.

Covers Sha256.lua, InatOAuth.lua, the query parsing in PluginUrls.lua, and the
refresh branch InatAuth.lua grew for it.

The properties worth protecting here are the ones whose failure is either
silent or catastrophic:

  * the challenge is really S256 of the verifier, checked against an
    independent SHA-256 rather than against the plugin's own;
  * no client_secret is ever sent, because that is the whole reason a public
    client is allowed to do this;
  * a verifier is single-use and time-limited, which is what stops a redirect
    that arrives from somewhere else being redeemed;
  * an authorization code never reaches the log;
  * a signed-in plugin mints a new JWT by itself, and a pasted one still
    cannot.
"""

import base64
import hashlib
import json
import time

import pytest

from lua_harness import LuaPlugin, make_jwt

CLIENT_ID = "y3sOmdF1q07gmGEDDH9vttdZsaWrWf9cGGvjw1Oa3KA"
REDIRECT = "lightroom://com.github.inat-lightroom/authorization-redirect"

TOKEN_URL = "https://www.inaturalist.org/oauth/token"
API_TOKEN_URL = "https://www.inaturalist.org/users/api_token"
ME_URL = "https://api.inaturalist.org/v1/users/me"


def s256_challenge(verifier: str) -> str:
    """The code challenge, computed independently of the plugin."""
    digest = hashlib.sha256(verifier.encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


class FakeInat:
    """Enough of iNaturalist to finish a sign-in."""

    def __init__(self, *, access_token="oauth-access-token", jwt=None,
                 token_status=200, token_body=None, login="ada"):
        self.access_token = access_token
        self.jwt = jwt if jwt is not None else make_jwt(int(time.time()) + 86400)
        self.token_status = token_status
        self.token_body = token_body
        self.login = login
        self.requests = []

    def __call__(self, method, url, body, headers):
        self.requests.append({
            "method": method,
            "url": url,
            "body": body,
            "headers": {h["field"]: h["value"] for h in (headers or {}).values()}
            if hasattr(headers, "values") else {},
        })

        if url == TOKEN_URL:
            if self.token_body is not None:
                return self.token_body, {"status": self.token_status}
            if self.token_status >= 400:
                return (
                    json.dumps({"error": "invalid_grant",
                                "error_description": "code has expired"}),
                    {"status": self.token_status},
                )
            return json.dumps({"access_token": self.access_token}), {"status": 200}

        if url == API_TOKEN_URL:
            return json.dumps({"api_token": self.jwt}), {"status": 200}

        if url.startswith(ME_URL):
            return (
                json.dumps({"results": [{"login": self.login, "id": 7}]}),
                {"status": 200},
            )

        raise AssertionError(f"unexpected request: {url}")


def make(**kwargs):
    fake = FakeInat(**kwargs)
    plugin = LuaPlugin(http_handler=fake)
    return plugin, fake


@pytest.fixture
def env():
    plugin, fake = make()
    return plugin, plugin.require("InatOAuth"), fake


# ---------------------------------------------------------------------------
# SHA-256 and base64url
# ---------------------------------------------------------------------------


def test_sha256_matches_the_reference_implementation():
    plugin = LuaPlugin()
    sha = plugin.require("Sha256")

    for text in ["", "abc", "the quick brown fox", "x" * 1000]:
        digest, err = plugin.call(sha.hex, text)
        assert err is None
        assert digest == hashlib.sha256(text.encode()).hexdigest()


def test_base64url_is_unpadded_and_url_safe():
    plugin = LuaPlugin()
    sha = plugin.require("Sha256")

    for text in ["abc", "sign-in", "\xff\xfe\x00 padding"]:
        hex_digest = hashlib.sha256(text.encode("latin-1")).hexdigest()
        assert sha.base64urlFromHex(hex_digest) == s256_challenge_from_hex(hex_digest)


def s256_challenge_from_hex(hex_digest: str) -> str:
    raw = bytes.fromhex(hex_digest)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def test_base64url_handles_lengths_that_need_padding():
    """A 1- and 2-byte tail take the two branches a 32-byte digest never does."""
    plugin = LuaPlugin()
    sha = plugin.require("Sha256")

    for raw in [b"\x01", b"\x01\x02", b"\x01\x02\x03", b"\x01\x02\x03\x04"]:
        expected = base64.urlsafe_b64encode(raw).decode().rstrip("=")
        assert sha.base64urlFromHex(raw.hex()) == expected


def test_a_lightroom_without_lrdigest_says_so_rather_than_failing_later():
    plugin = LuaPlugin()
    plugin.set_digest_missing(True)
    sha = plugin.require("Sha256")

    available, reason = plugin.call(sha.available)
    assert available is False
    assert "LrDigest" in reason


# ---------------------------------------------------------------------------
# The challenge
# ---------------------------------------------------------------------------


def test_the_challenge_is_s256_of_the_verifier(env):
    plugin, oauth, _fake = env

    verifier, err = plugin.call(oauth.generateVerifier)
    assert err is None

    challenge, err = plugin.call(oauth.challengeFor, verifier)
    assert err is None
    assert challenge == s256_challenge(verifier)


def test_the_verifier_is_a_legal_pkce_verifier(env):
    plugin, oauth, _fake = env

    verifier, _ = plugin.call(oauth.generateVerifier)

    # RFC 7636: 43-128 characters from the unreserved set.
    assert 43 <= len(verifier) <= 128
    assert all(c in "abcdefghijklmnopqrstuvwxyz0123456789" for c in verifier)


def test_two_sign_ins_do_not_share_a_verifier(env):
    plugin, oauth, _fake = env

    first, _ = plugin.call(oauth.generateVerifier)
    second, _ = plugin.call(oauth.generateVerifier)
    assert first != second


# ---------------------------------------------------------------------------
# Starting the flow
# ---------------------------------------------------------------------------


def test_starting_a_sign_in_opens_an_authorize_url_with_the_challenge(env):
    plugin, oauth, _fake = env

    ok, err = plugin.call(oauth.startSignIn)
    assert ok is True, err

    assert len(plugin.opened_urls) == 1
    url = plugin.opened_urls[0]

    assert url.startswith("https://www.inaturalist.org/oauth/authorize?")
    assert f"client_id={CLIENT_ID}" in url
    assert "code_challenge_method=S256" in url
    assert "response_type=code" in url

    verifier = plugin.call(oauth.pendingVerifier)[0]
    assert f"code_challenge={s256_challenge(verifier)}" in url


def test_the_redirect_uri_is_built_from_the_toolkit_identifier(env):
    plugin, oauth, _fake = env

    assert plugin.call(oauth.redirectUri)[0] == REDIRECT

    plugin.call(oauth.startSignIn)
    url = plugin.opened_urls[0]

    # Percent-encoded, because it is a URL inside a query string.
    assert "redirect_uri=lightroom%3A%2F%2Fcom.github.inat-lightroom%2F" \
        "authorization-redirect" in url


def test_the_authorize_url_carries_no_secret(env):
    plugin, oauth, _fake = env
    plugin.call(oauth.startSignIn)
    assert "client_secret" not in plugin.opened_urls[0]


def test_sign_in_refuses_when_sha256_is_unavailable():
    plugin, _fake = make()
    plugin.set_digest_missing(True)
    oauth = plugin.require("InatOAuth")

    ok, err = plugin.call(oauth.startSignIn)
    assert ok is False
    assert "LrDigest" in err
    assert plugin.opened_urls == []


# ---------------------------------------------------------------------------
# Parsing the redirect
# ---------------------------------------------------------------------------


def test_the_action_survives_a_query_string():
    plugin = LuaPlugin()
    urls = plugin.require("PluginUrls")

    assert urls.parse(REDIRECT + "?code=abc") == "authorization-redirect"


def test_query_parameters_are_decoded():
    plugin = LuaPlugin()
    urls = plugin.require("PluginUrls")

    params = urls.parseParams(
        REDIRECT + "?error=access_denied&error_description=The+user+said+no%21")

    assert params["error"] == "access_denied"
    assert params["error_description"] == "The user said no!"


def test_a_code_containing_padding_is_not_truncated():
    """An authorization code can contain '=' and '-'; splitting naively eats it."""
    plugin = LuaPlugin()
    urls = plugin.require("PluginUrls")

    params = urls.parseParams(REDIRECT + "?code=ab-cd_ef==&state=x")
    assert params["code"] == "ab-cd_ef=="


def test_a_url_with_no_query_gives_an_empty_table():
    plugin = LuaPlugin()
    urls = plugin.require("PluginUrls")

    assert dict(urls.parseParams(REDIRECT)) == {}


# ---------------------------------------------------------------------------
# Finishing the flow
# ---------------------------------------------------------------------------


def complete_sign_in(plugin, oauth, fake, code="the-code"):
    plugin.call(oauth.startSignIn)
    verifier = plugin.call(oauth.pendingVerifier)[0]

    urls = plugin.require("PluginUrls")
    params = urls.parseParams(f"{REDIRECT}?code={code}")

    oauth.handleRedirect(params)
    plugin.run_pending_tasks()
    return verifier


def token_request(fake):
    return next(r for r in fake.requests if r["url"] == TOKEN_URL)


def in_task_call(plugin, fn, *args):
    """Call a value-or-error function inside a task, normalising its returns.

    ``LuaPlugin.call`` does this outside a task and ``in_task`` runs inside one,
    but nothing does both -- and getToken needs both, because it yields on the
    network and follows the value-or-error convention.
    """
    wrapper = plugin.runtime.eval(
        "function(fn, ...)\n"
        "  local args = { ... }\n"
        "  return function()\n"
        "    local value, err = fn(unpack(args))\n"
        "    return { value = value, err = err }\n"
        "  end\n"
        "end"
    )
    result = plugin.in_task(wrapper(fn, *args))
    return result["value"], result["err"]


def stored(plugin, key):
    """A secret out of the stubbed vault, absent and empty both reading None."""
    value = plugin.passwords[key]
    return value if value else None


def test_a_successful_redirect_stores_an_oauth_token(env):
    plugin, oauth, fake = env
    complete_sign_in(plugin, oauth, fake)

    assert plugin.passwords["oauth_access_token"] == "oauth-access-token"
    assert plugin.prefs["authMode"] == "oauth"

    assert any("Signed in as ada" in d["message"] for d in plugin.dialogs)


def test_the_exchange_sends_the_verifier_and_no_secret(env):
    plugin, oauth, fake = env
    verifier = complete_sign_in(plugin, oauth, fake)

    body = token_request(fake)["body"]

    assert f"code_verifier={verifier}" in body
    assert "grant_type=authorization_code" in body
    assert f"client_id={CLIENT_ID}" in body
    assert "client_secret" not in body


def test_the_exchange_sends_a_form_content_type(env):
    plugin, oauth, fake = env
    complete_sign_in(plugin, oauth, fake)

    headers = token_request(fake)["headers"]
    assert headers["Content-Type"] == "application/x-www-form-urlencoded"


def test_the_verifier_is_spent_once_used(env):
    plugin, oauth, fake = env
    complete_sign_in(plugin, oauth, fake)

    assert plugin.call(oauth.pendingVerifier)[0] is None


def test_the_verifier_is_spent_even_when_the_exchange_fails():
    plugin, fake = make(token_status=400)
    oauth = plugin.require("InatOAuth")

    complete_sign_in(plugin, oauth, fake)

    assert plugin.call(oauth.pendingVerifier)[0] is None
    assert stored(plugin, "oauth_access_token") is None
    assert any("code has expired" in d["message"] for d in plugin.dialogs)


def test_a_redirect_with_no_sign_in_in_progress_is_refused(env):
    plugin, oauth, fake = env

    urls = plugin.require("PluginUrls")
    oauth.handleRedirect(urls.parseParams(f"{REDIRECT}?code=unexpected"))
    plugin.run_pending_tasks()

    # Nothing was exchanged: an unsolicited code is exactly what PKCE refuses.
    assert fake.requests == []
    assert any("No sign-in is in progress" in d["message"] for d in plugin.dialogs)


def test_a_stale_sign_in_is_refused(env):
    plugin, oauth, fake = env

    plugin.call(oauth.startSignIn)
    plugin.prefs["pkceStartedAt"] = time.time() - (31 * 60)

    assert plugin.call(oauth.pendingVerifier)[0] is None

    urls = plugin.require("PluginUrls")
    oauth.handleRedirect(urls.parseParams(f"{REDIRECT}?code=too-late"))
    plugin.run_pending_tasks()

    assert fake.requests == []


def test_a_rejected_authorization_is_reported_without_alarm(env):
    plugin, oauth, fake = env

    plugin.call(oauth.startSignIn)
    urls = plugin.require("PluginUrls")
    oauth.handleRedirect(urls.parseParams(
        f"{REDIRECT}?error=access_denied&error_description=Denied"))
    plugin.run_pending_tasks()

    assert fake.requests == []
    assert plugin.call(oauth.pendingVerifier)[0] is None

    declined = [d for d in plugin.dialogs if "not completed" in d["message"]]
    assert declined and declined[0]["style"] == "info"


def test_the_authorization_code_never_reaches_the_log(env):
    plugin, oauth, fake = env
    complete_sign_in(plugin, oauth, fake, code="secret-code-value")

    assert not any("secret-code-value" in line for line in plugin.log_lines)


def test_an_unknown_url_is_logged_without_its_query_string():
    plugin = LuaPlugin()
    handler = plugin.require("URLHandler")

    handler.URLHandler("lightroom://someone.else/thing?code=secret-code-value")

    assert not any("secret-code-value" in line for line in plugin.log_lines)


# ---------------------------------------------------------------------------
# Living with the token
# ---------------------------------------------------------------------------


def test_a_signed_in_plugin_mints_a_new_jwt_when_the_old_one_expires():
    plugin, fake = make()
    oauth = plugin.require("InatOAuth")
    auth = plugin.require("InatAuth")

    complete_sign_in(plugin, oauth, fake)

    # Expire what is cached, as a day passing would.
    plugin.prefs["apiTokenExpiresAt"] = time.time() - 1
    fresh = make_jwt(int(time.time()) + 86400, payload={"round": 2})
    fake.jwt = fresh

    token, err = in_task_call(plugin, auth.getToken)
    assert err is None
    assert token == fresh


def test_a_pasted_token_still_cannot_refresh_itself():
    plugin, _fake = make()
    auth = plugin.require("InatAuth")

    ok, err = plugin.call(auth.storeApiToken, make_jwt(int(time.time()) + 86400))
    assert ok is True, err

    plugin.prefs["apiTokenExpiresAt"] = time.time() - 1

    token, err = in_task_call(plugin, auth.getToken)
    assert token is None
    assert "expired" in err


def test_signing_out_forgets_both_tokens_and_any_pending_sign_in():
    plugin, fake = make()
    oauth = plugin.require("InatOAuth")
    auth = plugin.require("InatAuth")

    complete_sign_in(plugin, oauth, fake)
    plugin.call(oauth.startSignIn)

    auth.clear()

    assert stored(plugin, "oauth_access_token") is None
    assert stored(plugin, "api_token") is None
    assert stored(plugin, "pkce_verifier") is None
    assert plugin.call(auth.isSignedIn)[0] is False


def test_a_revoked_application_says_what_to_do_about_it():
    plugin, fake = make()
    oauth = plugin.require("InatOAuth")
    auth = plugin.require("InatAuth")

    complete_sign_in(plugin, oauth, fake)
    plugin.prefs["apiTokenExpiresAt"] = time.time() - 1

    def revoked(method, url, body, headers):
        if url == API_TOKEN_URL:
            return "", {"status": 401}
        return fake(method, url, body, headers)

    plugin.set_http_handler(revoked)

    token, err = in_task_call(plugin, auth.getToken)
    assert token is None
    assert "revoked" in err
