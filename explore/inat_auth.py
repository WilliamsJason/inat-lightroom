"""
inat_auth.py
~~~~~~~~~~~~
Credential storage and token resolution for iNaturalist.

Design goals
------------
* Keep secrets **out of the repo**. Nothing here ever writes a credential to a
  file inside the working tree.
* Store secrets in the OS credential vault (Windows Credential Manager /
  macOS Keychain / Secret Service) via ``keyring``.  This mirrors what the
  Lightroom plugin will do with the ``LrPasswords`` SDK namespace, which is
  backed by the same OS vaults -- so the *shape* of the credential model
  transfers directly even though the two runtimes cannot share a vault entry
  namespace.
* Support more than one auth mode, because iNaturalist offers several and the
  right one for the shipping plugin is still an open question.

Auth modes
----------
``api_token``
    A JSON Web Token copied from https://www.inaturalist.org/users/api_token
    while signed in to the website.  No OAuth application registration
    required.  Short-lived (~24 h), so it is only suitable for exploration --
    but it unblocks testing today.

``oauth_password``
    OAuth 2.0 Resource Owner Password Credentials grant.  Needs a registered
    application (client id + secret) plus the account username and password.
    Yields a long-lived OAuth token, which is then exchanged for a JWT.

Both modes converge on the same thing: a bearer token accepted by
``https://api.inaturalist.org/v1``.

CLI
---
    python inat_auth.py status
    python inat_auth.py store-token            # prompts for a pasted JWT
    python inat_auth.py store-oauth-app        # prompts for app id/secret/user/pass
    python inat_auth.py clear
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

WWW_BASE = "https://www.inaturalist.org"
API_V1 = "https://api.inaturalist.org/v1"

#: Vault "service" name.  Chosen to match the Lightroom plugin's intended
#: LrPasswords key prefix so the two stay conceptually aligned.
KEYRING_SERVICE = "inat-lightroom"

#: Individual entries stored under KEYRING_SERVICE.
_KEY_API_TOKEN = "api_token"
_KEY_API_TOKEN_AT = "api_token_obtained_at"
_KEY_APP_ID = "app_id"
_KEY_APP_SECRET = "app_secret"
_KEY_USERNAME = "username"
_KEY_PASSWORD = "user_password"

#: iNaturalist JWTs are documented as valid for 24 hours.  Refresh a little
#: early so a long-running script does not expire mid-flight.
JWT_LIFETIME_SECONDS = 24 * 60 * 60
JWT_REFRESH_MARGIN_SECONDS = 60 * 60

USER_AGENT = "inat-lightroom-explore/0.1 (+https://github.com/WilliamsJason/inat-lightroom)"


class AuthError(RuntimeError):
    """Raised when a usable token cannot be produced."""


# --------------------------------------------------------------------------
# Vault access
# --------------------------------------------------------------------------


def _keyring():
    """Import keyring lazily so the module is importable without a vault."""
    try:
        import keyring

        return keyring
    except Exception as exc:  # pragma: no cover - environment dependent
        raise AuthError(f"keyring is unavailable: {exc}") from exc


def vault_get(key: str) -> str | None:
    try:
        return _keyring().get_password(KEYRING_SERVICE, key)
    except Exception:
        return None


def vault_set(key: str, value: str) -> None:
    _keyring().set_password(KEYRING_SERVICE, key, value)


def vault_delete(key: str) -> None:
    kr = _keyring()
    try:
        kr.delete_password(KEYRING_SERVICE, key)
    except Exception:
        pass


def _setting(env_name: str, vault_key: str) -> str | None:
    """Environment variable wins over the vault, so CI/one-offs can override."""
    return os.environ.get(env_name) or vault_get(vault_key)


# --------------------------------------------------------------------------
# Credential model
# --------------------------------------------------------------------------


@dataclass
class OAuthAppCredentials:
    app_id: str
    app_secret: str
    username: str
    password: str


def load_oauth_app_credentials() -> OAuthAppCredentials | None:
    app_id = _setting("INAT_APP_ID", _KEY_APP_ID)
    app_secret = _setting("INAT_APP_SECRET", _KEY_APP_SECRET)
    username = _setting("INAT_USERNAME", _KEY_USERNAME)
    password = _setting("INAT_PASSWORD", _KEY_PASSWORD)
    if all([app_id, app_secret, username, password]):
        return OAuthAppCredentials(app_id, app_secret, username, password)  # type: ignore[arg-type]
    return None


def store_api_token(token: str) -> None:
    vault_set(_KEY_API_TOKEN, token.strip())
    vault_set(_KEY_API_TOKEN_AT, str(int(time.time())))


def store_oauth_app_credentials(creds: OAuthAppCredentials) -> None:
    vault_set(_KEY_APP_ID, creds.app_id)
    vault_set(_KEY_APP_SECRET, creds.app_secret)
    vault_set(_KEY_USERNAME, creds.username)
    vault_set(_KEY_PASSWORD, creds.password)


def clear_all() -> None:
    for key in (
        _KEY_API_TOKEN,
        _KEY_API_TOKEN_AT,
        _KEY_APP_ID,
        _KEY_APP_SECRET,
        _KEY_USERNAME,
        _KEY_PASSWORD,
    ):
        vault_delete(key)


# --------------------------------------------------------------------------
# Token acquisition
# --------------------------------------------------------------------------


def _cached_api_token() -> str | None:
    token = _setting("INAT_API_TOKEN", _KEY_API_TOKEN)
    if not token:
        return None
    # An env-supplied token has no recorded age; assume the caller knows.
    if os.environ.get("INAT_API_TOKEN"):
        return token
    obtained_at = vault_get(_KEY_API_TOKEN_AT)
    if obtained_at:
        age = time.time() - int(obtained_at)
        if age > JWT_LIFETIME_SECONDS - JWT_REFRESH_MARGIN_SECONDS:
            return None
    return token


def _oauth_password_grant(creds: OAuthAppCredentials) -> str:
    """Exchange username/password for a long-lived OAuth access token."""
    payload = {
        "grant_type": "password",
        "client_id": creds.app_id,
        "client_secret": creds.app_secret,
        "username": creds.username,
        "password": creds.password,
    }
    resp = requests.post(
        f"{WWW_BASE}/oauth/token",
        json=payload,
        headers={"User-Agent": USER_AGENT},
        timeout=30,
    )
    if resp.status_code >= 400:
        raise AuthError(
            f"OAuth token request failed ({resp.status_code}): {resp.text[:400]}"
        )
    token = resp.json().get("access_token")
    if not token:
        raise AuthError(f"No access_token in OAuth response: {resp.text[:400]}")
    return token


def _exchange_for_jwt(oauth_token: str) -> str:
    """Trade an OAuth bearer token for the JWT used by the modern API."""
    resp = requests.get(
        f"{WWW_BASE}/users/api_token",
        headers={"Authorization": f"Bearer {oauth_token}", "User-Agent": USER_AGENT},
        timeout=30,
    )
    if resp.status_code >= 400:
        raise AuthError(
            f"JWT exchange failed ({resp.status_code}): {resp.text[:400]}"
        )
    token = resp.json().get("api_token")
    if not token:
        raise AuthError(f"No api_token in response: {resp.text[:400]}")
    return token


def get_token(*, refresh: bool = False) -> str:
    """
    Return a bearer token usable against the iNaturalist v1 API.

    Resolution order:
      1. ``INAT_API_TOKEN`` environment variable
      2. A non-expired JWT in the OS credential vault
      3. OAuth password grant using stored/env application credentials,
         exchanged for a fresh JWT (which is then cached)
    """
    if not refresh:
        cached = _cached_api_token()
        if cached:
            return cached

    creds = load_oauth_app_credentials()
    if creds is None:
        had_expired_token = bool(_setting("INAT_API_TOKEN", _KEY_API_TOKEN))
        if had_expired_token:
            raise AuthError(
                "The stored iNaturalist JWT has expired (they last 24 hours).\n"
                "Get a fresh one while signed in at\n"
                "  https://www.inaturalist.org/users/api_token\n"
                "then run `python inat_auth.py store-token` again.\n\n"
                "To stop doing this by hand you need an approved OAuth "
                "application; see explore/README.md."
            )
        raise AuthError(
            "No usable iNaturalist credentials found.\n"
            "Either:\n"
            "  * run `python inat_auth.py store-token` and paste the JWT from\n"
            "    https://www.inaturalist.org/users/api_token, or\n"
            "  * run `python inat_auth.py store-oauth-app` to save an approved\n"
            "    OAuth application id/secret plus your username and password."
        )

    jwt = _exchange_for_jwt(_oauth_password_grant(creds))
    store_api_token(jwt)
    return jwt


def auth_headers(token: str | None = None) -> dict[str, str]:
    """Standard headers for an authenticated API call."""
    return {
        "Authorization": f"Bearer {token or get_token()}",
        "User-Agent": USER_AGENT,
    }


def whoami(token: str | None = None) -> dict[str, Any]:
    """Verify a token by fetching the authenticated user."""
    resp = requests.get(
        f"{API_V1}/users/me", headers=auth_headers(token), timeout=30
    )
    if resp.status_code >= 400:
        raise AuthError(f"Token check failed ({resp.status_code}): {resp.text[:400]}")
    results = resp.json().get("results") or []
    if not results:
        raise AuthError("users/me returned no results")
    return results[0]


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _cmd_status(_args: argparse.Namespace) -> int:
    have_token = bool(_cached_api_token())
    have_app = load_oauth_app_credentials() is not None
    print(f"Cached JWT present : {have_token}")
    print(f"OAuth app creds    : {have_app}")
    if not (have_token or have_app):
        print("\nNo credentials stored. Run `store-token` or `store-oauth-app`.")
        return 1
    try:
        user = whoami()
    except AuthError as exc:
        print(f"\nToken check FAILED: {exc}")
        return 1
    print(f"\nAuthenticated as   : {user.get('login')} (id={user.get('id')})")
    print(f"Observations       : {user.get('observations_count')}")
    return 0


def _cmd_store_token(_args: argparse.Namespace) -> int:
    print("Sign in at https://www.inaturalist.org then open:")
    print("  https://www.inaturalist.org/users/api_token")
    print("Paste either the raw token or the whole JSON blob.\n")
    raw = getpass.getpass("api_token: ").strip()
    if not raw:
        print("Nothing entered.", file=sys.stderr)
        return 1
    # Accept a pasted {"api_token": "..."} payload as well as a bare token.
    if raw.startswith("{"):
        try:
            raw = json.loads(raw)["api_token"]
        except Exception as exc:
            print(f"Could not parse JSON: {exc}", file=sys.stderr)
            return 1
    store_api_token(raw)
    try:
        user = whoami(raw)
    except AuthError as exc:
        print(f"Stored, but the token did not validate: {exc}", file=sys.stderr)
        return 1
    print(f"Stored. Authenticated as {user.get('login')} (id={user.get('id')}).")
    return 0


def _cmd_store_oauth_app(args: argparse.Namespace) -> int:
    if getattr(args, "from_env", False):
        creds = load_oauth_app_credentials()
        if creds is None:
            print(
                "Could not find all four values in the environment or .env file.\n"
                "Expected INAT_APP_ID, INAT_APP_SECRET, INAT_USERNAME, INAT_PASSWORD.",
                file=sys.stderr,
            )
            return 1
        print("Migrating credentials from the environment into the OS vault.")
    else:
        print(
            "Create an application at https://www.inaturalist.org/oauth/applications/new"
        )
        print("if you have not already.\n")
        app_id = input("Application client ID: ").strip()
        app_secret = getpass.getpass("Application client secret: ").strip()
        username = input("iNaturalist username: ").strip()
        password = getpass.getpass("iNaturalist password: ").strip()
        if not all([app_id, app_secret, username, password]):
            print("All four values are required.", file=sys.stderr)
            return 1
        creds = OAuthAppCredentials(app_id, app_secret, username, password)

    store_oauth_app_credentials(creds)
    try:
        token = get_token(refresh=True)
        user = whoami(token)
    except AuthError as exc:
        print(f"Stored, but authentication failed: {exc}", file=sys.stderr)
        return 1
    print(f"Stored. Authenticated as {user.get('login')} (id={user.get('id')}).")
    if getattr(args, "from_env", False):
        env_file = Path(__file__).parent / ".env"
        if env_file.exists():
            print(
                f"\nCredentials now live in the OS vault. You can safely delete\n"
                f"  {env_file}"
            )
    return 0


def _cmd_clear(_args: argparse.Namespace) -> int:
    clear_all()
    print("Cleared all stored iNaturalist credentials.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Manage iNaturalist credentials.")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Show what is stored and validate it.").set_defaults(
        func=_cmd_status
    )
    sub.add_parser("store-token", help="Store a pasted JWT API token.").set_defaults(
        func=_cmd_store_token
    )
    store_app = sub.add_parser(
        "store-oauth-app", help="Store OAuth application + account credentials."
    )
    store_app.add_argument(
        "--from-env",
        action="store_true",
        help="Read the four values from the environment / .env instead of prompting, "
        "then move them into the OS vault.",
    )
    store_app.set_defaults(func=_cmd_store_oauth_app)
    sub.add_parser("clear", help="Remove all stored credentials.").set_defaults(
        func=_cmd_clear
    )

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
