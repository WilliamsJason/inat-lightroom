# Exploration scripts

Python scripts for experimenting with the iNaturalist REST API before
implementing equivalent functionality in the Lightroom plugin (Lua).

These call the API directly with `requests` rather than using a client
library, deliberately: the plugin will hand-roll HTTP through `LrHttp`, so
keeping the prototype at the same level of abstraction means what we prove
here transfers straight into Lua. See `docs/inat-api-notes.md` for the
findings, several of which are non-obvious.

---

## Setup

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

---

## Credentials

Secrets live in the **OS credential vault** (Windows Credential Manager,
macOS Keychain, or Secret Service) under the service name `inat-lightroom` —
never in a file in the repo. This mirrors the plugin, which will use
Lightroom's `LrPasswords` namespace, backed by the same vaults.

### Fastest route: paste a JWT

No application registration needed.

1. Sign in at <https://www.inaturalist.org>
2. Open <https://www.inaturalist.org/users/api_token>
3. Copy the token (or the whole `{"api_token": "..."}` blob)

```powershell
.\.venv\Scripts\python.exe inat_auth.py store-token
```

**The JWT expires after 24 hours**, so this must be repeated each session.

### Durable route: an OAuth application

Requires approval from iNaturalist — your account must be at least 2 months
old and have made at least 10 improving identifications for other users in the
last month. Apply at <https://www.inaturalist.org/oauth/applications/new>.

Once approved, the never-expiring OAuth token mints fresh JWTs automatically:

```powershell
.\.venv\Scripts\python.exe inat_auth.py store-oauth-app
```

### Managing credentials

```powershell
.\.venv\Scripts\python.exe inat_auth.py status   # show and validate
.\.venv\Scripts\python.exe inat_auth.py clear    # remove everything
```

Environment variables (`INAT_API_TOKEN`, `INAT_APP_ID`, `INAT_APP_SECRET`,
`INAT_USERNAME`, `INAT_PASSWORD`) override the vault if set, which is handy
for one-offs. `store-oauth-app --from-env` migrates them into the vault so the
`.env` file can be deleted.

---

## Scripts

### `inat_auth.py`

Credential storage and token resolution. Everything else imports it.

### `inat_api.py`

Direct-HTTP client for the endpoints the plugin needs: taxa, observations,
photos, identifications, and computer vision. Import it rather than running
it.

Of note, `upload_observation_photo_verified()` uploads *and confirms the photo
actually attached*, retrying if not — because iNaturalist returns `200` for
uploads that it later silently discards.

### `feasibility_test.py`

The full round trip: authenticate → read EXIF → resolve taxon → create
observation → attach photo → read back → update metadata → verify → read
determination.

```powershell
.\.venv\Scripts\python.exe feasibility_test.py `
  --photo "C:\path\to\photo.jpg" `
  --species "Damselfly" `
  --lat 47.80693 --lng -122.21465
```

Useful flags:

| Flag | Effect |
|---|---|
| `--dry-run` | Everything except the writes. Works without credentials. |
| `--captive` | Mark the observation captive, keeping it out of the data set. |
| `--delete` | Delete the observation at the end, leaving no trace. |
| `--max-dimension N` | Long edge for the rendered upload (default 2048; `0` sends the original). |
| `--taxon-id N` | Skip the name search. |

> **There is no iNaturalist sandbox.** Every run writes to the production site
> under your real account. Use `--dry-run` while iterating, and `--captive`
> plus `--delete` for throwaway records.

### `suggest_species.py`

Computer-vision suggestions for a photo, prototyping the plugin's species
picker.

```powershell
.\.venv\Scripts\python.exe suggest_species.py `
  --photo "C:\path\to\photo.jpg" `
  --lat 47.80693 --lng -122.21465
```

Prints ranked candidates, iNaturalist's own `common_ancestor` as a safe
fallback, and the full ladder of ranks the user could choose to come in at.
Pass `--no-geo` to see how much the geographic prior is contributing, and
`--observation-id N` to score an existing observation instead.

### `sync_observation.py`

Earlier prototype of the sync workflow, built on `pyinaturalist`. Superseded
in practice by `feasibility_test.py`, which uses the direct client.

---

## Running tests

```powershell
.\.venv\Scripts\python.exe -m pytest
```

Tests in `tests/` use `responses` for HTTP mocking, so no real API calls are
made and no credentials are required.
