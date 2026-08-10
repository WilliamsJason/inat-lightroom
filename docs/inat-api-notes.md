# iNaturalist REST API – Notes

Reference: <https://api.inaturalist.org/v1/docs/>

> **Status:** the auth and gotcha sections below were verified empirically on
> 2026-07-28 by running `explore/feasibility_test.py` and
> `explore/suggest_species.py` against the live API. Items marked **[verified]**
> were observed first-hand rather than read in documentation.

---

## Authentication

iNaturalist uses **OAuth 2.0**, but there is a second token type layered on
top, and getting this wrong is the single easiest way to waste an afternoon.

### Two tokens, not one

| Token | Lifetime | What it is for |
|---|---|---|
| **OAuth access token** | Never expires | Almost nothing directly. Its real job is to be exchanged for a JWT. |
| **JWT "API token"** | **24 hours** | The token that actually authenticates API calls. |

**[verified] The v1 and v2 APIs require the JWT for all write operations.**
Presenting a plain OAuth bearer token does not return `401` — the request is
silently processed *as an anonymous user*, so writes fail in confusing ways.
The relevant code path (`iNaturalistAPI:lib/inaturalist_api.js`) tries
`jwt.verify()` on the header and, on failure, simply continues without a user
session.

Exchange an OAuth token for a JWT with:

```
GET https://www.inaturalist.org/users/api_token
Authorization: Bearer <oauth_access_token>

→ {"api_token": "<jwt>"}
```

**[verified]** This endpoint also works with an ordinary logged-in browser
session, which is the fastest way to get a working token for local
exploration — no application registration required. That is what
`explore/inat_auth.py store-token` consumes.

### Creating an OAuth application requires approval

**[verified]** Contrary to older documentation, application creation has not
been self-serve since 2022. From the application form:

> As of 2022 we are requiring manual approval for users wishing to make API
> clients. […] In order to submit an application your account must be at least
> 2 months old and must have made at least 10 improving identifications for
> other users in the last month.

Plan for this lead time. Until approval lands, the pasted-JWT route is the
only way to exercise write endpoints, and it must be repeated every 24 hours.

### Grant types

| Flow | Verdict for this project |
|---|---|
| Resource Owner Password | Fine for local scripts. **Unshippable** in a plugin: the client secret would have to be embedded in readable Lua. Still enabled on iNaturalist as of Aug 2026 (`grant_flows` includes `password`), with no deprecation announced — but the wider OAuth ecosystem has moved against it and it cannot solve the secret problem anyway. |
| Authorization Code + PKCE | **The target for the distributed plugin.** No client secret needed, so the public `client_id` can ship in the plugin. |
| Client Credentials | Read-only public data only. |

Only the *developer* registers an application. Every user of the plugin
authenticates against that single `client_id` and receives their own token, so
end users never touch the registration process. With `confidential = false`
there is no secret to protect and the `client_id` is safe in readable Lua.

**[verified]** iNaturalist runs Doorkeeper 5.6.6, and PKCE is live: the
authorization view passes `code_challenge` and `code_challenge_method` through
(`app/views/doorkeeper/authorizations/new.html.haml`), and Doorkeeper only wires
those up when the migration adding the column has run. `S256` is accepted. The
app registration form has a **Confidential** checkbox — leave it *unchecked* for
this flow, or the token exchange will demand a secret.

### The redirect: use `lightroom://`, not out-of-band

The Lightroom SDK gives a plugin no HTTP server, which appears to rule out the
loopback redirect and push you towards the out-of-band redirect
(`urn:ietf:wg:oauth:2.0:oob`) with the user copy-pasting a code. **There is a
better option.** Register a redirect URI on the plugin's own URL scheme:

```
lightroom://com.github.inat-lightroom/authorization-redirect
```

The browser redirects there, the OS hands it to Lightroom, and Lightroom hands
it to `URLHandler.lua` with the `?code=` attached. No copy-paste, no listener.
This is the same mechanism the Metadata panel action rows use, and that it
reaches the plugin is **confirmed in the host** — see
[lightroom-sdk-notes.md](lightroom-sdk-notes.md).

**[verified]** This is not speculative: `rcloran/lr-inaturalist-publish`, a
publicly distributed Lightroom Classic plugin, does exactly this today —
PKCE/S256, `redirect_uri = lightroom://net.rcloran.lr-inaturalist-publish/…`,
a hardcoded plaintext `client_id`, and **no `client_secret` anywhere in the
source**. Worth reading before implementing.

**[verified]** `force_ssl_in_redirect_uri false` in iNaturalist's Doorkeeper
initializer, so non-HTTPS redirect URIs are accepted at all.

The resulting OAuth token never expires, so the user authorizes **once** and
the plugin silently refreshes the 24-hour JWT from it thereafter.

---

## Base URL

```
https://api.inaturalist.org/v1/
```

All paths below are relative to this base URL.

---

## Key endpoints

### Observations

| Method | Path | Description |
|---|---|---|
| `POST` | `/observations` | Create a new observation |
| `GET` | `/observations/{id}` | Get a single observation |
| `PUT` | `/observations/{id}` | Update an observation |
| `DELETE` | `/observations/{id}` | Delete an observation |
| `GET` | `/observations` | Search / list observations |

#### Create observation – minimal body
```json
{
  "observation": {
    "species_guess": "Quercus robur",
    "taxon_id": 48793,
    "observed_on_string": "2024-05-10",
    "time_observed_at": "2024-05-10T14:30:00+01:00",
    "latitude": 51.5074,
    "longitude": -0.1278,
    "positional_accuracy": 10,
    "description": "Found near the pond",
    "captive_cultivated": false,
    "geoprivacy": "open"
  }
}
```

Response includes the new observation's `id` – **this is the ID we store in Lightroom**.

It also includes a `uuid`, which is the more useful handle: `GET
/observations?uuid=…` looks one up, and the field is client-supplyable — the
same UUID can be sent on a later create to reunite a photo with an observation.
(That is how `rcloran/lr-inaturalist-publish` works; this plugin's
recreate-under-the-same-UUID path has not yet been exercised in the host.)
Nothing needs to generate one to create an observation: omit it and read the
server's back.

**`taxon_id` overrides `species_guess` in what people see.** Both are stored,
but a taxon makes the observation's identification and that is what the site
displays; the free text is then invisible. **Not verified against the live API**
— reasoned from the data model, and worth checking. The plugin behaves as if it
is true: a connection-wide default taxon is sent only when the photo has no
species guess of its own, so the general fallback can never mask the specific
thing the user typed.

---

### Observation photos

| Method | Path | Description |
|---|---|---|
| `POST` | `/observation_photos` | Attach a photo to an observation |

#### Attach a photo
```
POST /observation_photos
Content-Type: multipart/form-data

observation_photo[observation_id]=<obs_id>
file=<binary>
```

#### **[verified] A `200` response does *not* mean the photo is attached**

The upload is processed asynchronously:

1. The POST returns `200` with a fully-populated `observation_photo` record,
   including a real `id` and correct `width`/`height` — iNaturalist has
   decoded the image by this point.
2. All `*_url` fields in that response point at
   `https://www.inaturalist.org/attachment_defaults/local_photos/*.png`,
   i.e. placeholder graphics, because the file has not been stored yet.

So the response body cannot confirm success. Verify afterwards — see
`InatApi.upload_observation_photo_verified` in `explore/inat_api.py`.

#### **[verified] Verify against Rails, not the v1 index**

`GET /v1/observations/{id}` is served from Elasticsearch and lags photo
processing by *minutes*. It reported `photos: []`, `identifications_count: 0`
and `quality_grade: casual` for a healthy observation for well over half an
hour.

Poll the Rails endpoint instead, which reflects the database immediately:

```
GET https://www.inaturalist.org/observations/{id}.json
→ .observation_photos[]
```

#### **[verified] Upload size limit**

Photos above roughly **20 MB** are rejected. A 33.8 MB camera-original JPEG
(7008 × 4672) exceeds this. Rendering to 2048 px long edge at quality 90
produced a 0.66 MB file with EXIF intact — a 51× reduction. Since the plugin
is an Export Service Provider, Lightroom's export pipeline handles this
naturally; never upload the catalog original.

---

### ⚠️ Updating an observation destroys its photos

**[verified] This is the single most dangerous behaviour in the API.**

`PUT /v1/observations/{id}` treats the request as a *full replacement* of the
observation's nested associations. If the payload does not carry the photos
forward, **every photo is detached from the observation** — and the request
still returns `200`.

The photo files themselves survive in iNaturalist's storage and remain
retrievable by photo ID; it is the `observation_photos` join records that are
deleted. The observation is left with no evidence and silently drops to
`casual` quality grade.

The guard is a top-level `ignore_photos` flag, *outside* the `observation`
object:

```json
PUT /v1/observations/386157650
{
  "observation": { "description": "Updated description" },
  "ignore_photos": true
}
```

Controlled test on a live observation:

| Request | Photos before | Photos after |
|---|---|---|
| `PUT` with `ignore_photos: true` | 1 | **1** |
| `PUT` without the flag | 1 | **0** |

Both returned `200`.

`InatApi.update_observation()` therefore defaults `ignore_photos=True`. Any
Lua implementation must do the same. Note the flag's name is misleading: it
does not mean "ignore photos in the payload", it means "leave the existing
photos alone".

This is easy to misdiagnose, because the v1 index lag means the damage does
not surface for minutes, long after the update appears to have succeeded.

---

### Computer vision suggestions

| Method | Path | Description |
|---|---|---|
| `POST` | `/computervision/score_image` | Identify an image before it is uploaded |
| `GET` | `/computervision/score_observation/{id}` | Score an observation's existing photos |

`score_image` is the one the plugin wants: it lets us offer suggestions from a
locally rendered JPEG without creating anything on iNaturalist first.

```
POST /computervision/score_image
Content-Type: multipart/form-data

image=<binary>
lat=47.80693
lng=-122.21465
observed_on=2026-05-20
```

#### **[verified] `lat`/`lng`/`observed_on` must be form fields, not query params**

Passing them in the query string returns `200` and silently ignores them.
The only symptom is that every `frequency_score` comes back `0` — easy to
miss if you are not looking for it. Sent correctly as multipart fields, the
geographic prior applies and the difference is dramatic:

| | Candidates returned | Top combined score |
|---|---|---|
| Without geo | 4 (incl. a Colombian and two arctic species) | 96.72 |
| With geo | **1** | **99.80** |

#### Response shape

```json
{
  "common_ancestor": { "taxon": { "id": 52054, "name": "Ischnura", "rank": "genus" } },
  "results": [
    {
      "combined_score": 99.80,
      "vision_score": 96.72,
      "frequency_score": 1.00,
      "taxon": { "id": 103486, "name": "Ischnura erratica", "rank": "species" }
    }
  ]
}
```

`common_ancestor` is the most specific taxon the model is confident about
across all candidates. It is the natural default for a picker when the user
would rather come in at a coarser rank than species — and the `ancestors`
array from `/taxa/{id}` gives the full ladder of ranks they can choose from.

---

### Species / Taxon

| Method | Path | Description |
|---|---|---|
| `GET` | `/taxa/autocomplete` | Search taxa by name (for species picker) |
| `GET` | `/taxa/{id}` | Full taxon details incl. ancestors |
| `GET` | `/observations/species_counts` | Species counts for a set of observations |

#### Autocomplete example
```
GET /taxa/autocomplete?q=Quercus+rob&rank=species&locale=en
```

#### Full taxonomic tree from a taxon ID
`GET /taxa/{id}` returns an `ancestors` array ordered from kingdom → species. Each ancestor has:
- `id` – taxon ID
- `name` – scientific name
- `rank` – `kingdom`, `phylum`, `class`, `order`, `family`, `genus`, `species`, …
- `preferred_common_name` – vernacular name (locale-dependent)

---

### Identifications

| Method | Path | Description |
|---|---|---|
| `GET` | `/identifications` | List identifications (filter by `observation_id`) |
| `POST` | `/identifications` | Add an identification |

The **community taxon** is available directly on the observation object at `.community_taxon_id` and `.community_taxon`.

**[verified]** `identifications_count` on the observation is also
Elasticsearch-backed and lags. A freshly created observation reported
`identifications_count: 0` while `GET /identifications?observation_id=…`
correctly returned the observer's own identification with `current: true`.
When the plugin syncs determinations, treat `/identifications` as
authoritative and the counts on the observation as advisory.

**[verified]** Creating an observation with a `taxon_id` implicitly creates an
identification by the observer, so a brand-new observation already has one.
Its `category` is `null` until iNaturalist scores it against other
identifications.

**[verified] To change what an observation is identified as, POST a new
identification** — do not set `taxon_id` via `PUT /observations/{id}`. Posting
an identification makes iNaturalist withdraw the author's previous one
automatically and recompute `category`. Updating the observation's `taxon_id`
directly leaves the old identification standing, so the two disagree.

```json
POST /v1/identifications
{ "identification": { "observation_id": 386157650, "taxon_id": 103486 } }
```

---

### Projects

| Method | Path | Description |
|---|---|---|
| `GET` | `/projects` | Search / list projects |
| `GET` | `/projects/{id}` | Get a project |
| `POST` | `/project_observations` | Add an observation to a project |

---

## Rate limits

- Authenticated: **100 requests / minute** per user
- Unauthenticated: **60 requests / minute** per IP

---

## Useful fields on the Observation response

```json
{
  "id": 12345678,
  "uuid": "...",
  "created_at": "2024-05-10T14:30:00Z",
  "observed_on": "2024-05-10",
  "taxon": {
    "id": 48793,
    "name": "Quercus robur",
    "rank": "species",
    "preferred_common_name": "English Oak",
    "ancestors": [...]
  },
  "community_taxon_id": 48793,
  "community_taxon": { ... },
  "quality_grade": "research",
  "identifications_count": 3,
  "photos": [
    {
      "id": 987654,
      "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/987654/original.jpg"
    }
  ],
  "latitude": "51.5074",
  "longitude": "-0.1278"
}
```

---

## An observation with no coordinates is almost always casual grade

**[verified, measured against the live API 2026-08-09]**

Of **8,691,735** observations with open geoprivacy and no coordinates,
**8,689,562 — 99.975% — are casual grade.** Only 1,793 ever reached research
grade and 380 sit at needs_id. Casual grade keeps an observation out of most
research use and out of the GBIF export, so uploading without a location
produces a record that will almost certainly not count. That is why the plugin
warns before creating one.

Coordinates also feed the vision endpoint's geographic prior, so a located photo
gets materially better suggestions.

### The query that appears to disprove this

The obvious check says the opposite and is wrong:

```
/v1/observations?geo=false&quality_grade=research&per_page=0
-> total_results: 492818
```

Half a million research-grade observations with no location would settle it.
But `geo=false` means **"coordinates are not visible to you"**, not "there are
no coordinates". Adding `geoprivacy=private` accounts for 490,423 of those
492,818: the coordinates exist, they are obscured. The honest query pins
geoprivacy open:

```
/v1/observations?geo=false&geoprivacy=open&per_page=0
-> total_results: 8691735
/v1/observations?geo=false&geoprivacy=open&quality_grade=casual&per_page=0
-> total_results: 8689562
```

Worth remembering generally: on this API, "not visible" and "not present" share
a parameter.

---

## iNaturalist image resolution tiers

| Tier | Approx. size |
|---|---|
| `square` | 75 × 75 px |
| `small` | 240 px |
| `medium` | 500 px |
| `large` | 1024 px |
| `original` | Full size as uploaded |

To get a specific tier, replace the tier name in the `url` field above.

---

## Testing practice

**[verified] There is no public sandbox.** `staging.inaturalist.org` exists but
returns `401` — it is an internal environment. Every test write lands on the
production site and on your real account.

Recommended hygiene for throwaway tests:

- Put an obvious marker in the `description`.
- Set `captive_flag=true` so the record stays out of the biodiversity data set
  (skip this when the observation is genuine and you intend to keep it).
- Delete afterwards: `DELETE /v1/observations/{id}`.
- Consider a dedicated test account rather than your main one.

`explore/feasibility_test.py` supports `--captive`, `--delete` and `--dry-run`
for exactly this.

---

## Client libraries

### pyinaturalist

The [`pyinaturalist`](https://pyinaturalist.readthedocs.io/) package is a
typed wrapper around the API, useful as a reference implementation.

Note that its `get_access_token()` uses the **password grant** and therefore
needs an approved OAuth application; it is not a way around the approval
requirement. It does default to `jwt=True`, correctly exchanging the OAuth
token for a JWT.

### Why the exploration scripts do not use it

`explore/inat_api.py` calls the API directly with `requests` instead. The
Lightroom plugin is Lua and will hand-roll HTTP through `LrHttp`, so anything
pyinaturalist abstracts away would have to be rediscovered in Lua later.
Keeping the Python prototype at the same level of abstraction as the eventual
plugin means the request and response shapes we prove out transfer directly —
and it is how the multipart and index-lag gotchas above were found.

## Obscured coordinates look exactly like real ones

The most dangerous response this plugin can receive. iNaturalist randomises the
public position of an observation that is obscured — either because the observer
set `geoprivacy = obscured`, or because the *taxon* is threatened and the site
obscures it automatically — and **still returns a normal-looking `location`
string and a normal-looking `geojson` point**. Nothing about the shape of the
response says the numbers are fiction. Only the `obscured` flag does.

A live example: `positional_accuracy` 61, `public_positional_accuracy` 30278.
Roughly 30 km of deliberate error, presented in the same field as a GPS fix.

The owner is told the truth through `private_location`, which is **absent
entirely from unauthenticated responses** — confirmed by dumping the full field
list of an unauthenticated fetch, not by its being empty. So:

```lua
-- SyncCore.coordinatesFrom
private_location, if present        -- the owner's own true position
else the public location, but only if not obscured
else nothing at all
```

Declining is the right third branch. Writing a randomised position into a user's
catalog would be worse than writing nothing, because it is indistinguishable
from a real one after the fact.

### `positional_accuracy` writes; `public_positional_accuracy` is derived

`positional_accuracy` is the field a client sets, in **metres**. Fractional
values are rejected. `public_positional_accuracy` is computed by the site: equal
to the former when nothing is obscured, and inflated to cover the obscuring
rectangle when something is. It is read-only, and it belongs to a position this
plugin never stores, so it is never read.

## `common_ancestor` is the honest way to offer a coarser rank

Already recorded in the response shape above, and worth calling out separately
because the plugin now depends on it: `common_ancestor` is the most specific
taxon the vision model is confident about **across every candidate**. When the
top five results disagree about the species but all sit in one genus, that genus
is what comes back.

This is a different and much better-founded claim than the top result's own
lineage. Walking up from result #1 assumes result #1 is in the right family —
which, at a 40% score, is exactly what is in doubt. Walking up from
`common_ancestor` assumes only what every candidate already agrees on.

So the rank ladder the plugin offers is built from `common_ancestor` and its
`ancestors`, never from a single result, and it never descends below it.

`/v1/taxa/{id}` supplies the ladder: the response carries an `ancestors` array
from `kingdom` downwards, including intermediate ranks (`subphylum`, `suborder`,
`superfamily`) that are real but useless as choices — the plugin keeps only
`order`, `family` and `genus`.

Two things this does **not** establish:

- Whether `score_observation` includes `common_ancestor` at all. Only
  `score_image` has been seen to. Every caller must handle its absence.
- What score, if any, iNaturalist attaches to it. None is returned, which is why
  the plugin shows no percentage against a fallback row rather than inventing
  one.

Both vision endpoints require authentication — an unauthenticated call returns
`{"error":"Unauthorized","status":401}` — so neither can be probed without a
token, and neither appears in `/v1/swagger.json`.
