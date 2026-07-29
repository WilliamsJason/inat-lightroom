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
| Resource Owner Password | Fine for local scripts. **Unshippable** in a plugin: the client secret would have to be embedded in readable Lua. |
| Authorization Code + PKCE | **The target for the distributed plugin.** No client secret needed, so the public `client_id` can ship in the plugin. |
| Client Credentials | Read-only public data only. |

Only the *developer* registers an application. Every user of the plugin
authenticates against that single `client_id` and receives their own token, so
end users never touch the registration process.

Because the Lightroom SDK provides no HTTP server, the loopback redirect
(`http://127.0.0.1:port`) is not usable from a plugin. Use the out-of-band
redirect `urn:ietf:wg:oauth:2.0:oob` and have the user copy the authorization
code from the browser into a plugin dialog — the same pattern Adobe's bundled
Flickr plugin uses.

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

This is the most dangerous behaviour we found. The upload is processed
asynchronously:

1. The POST returns `200` with a fully-populated `observation_photo` record,
   including a real `id` and correct `width`/`height` — iNaturalist has
   decoded the image by this point.
2. All `*_url` fields in that response point at
   `https://www.inaturalist.org/attachment_defaults/local_photos/*.png`,
   i.e. placeholder graphics, because the file has not been stored yet.
3. If the asynchronous processing then fails, **the record is silently
   deleted.** The observation ends up with no photo and drops to `casual`
   quality grade, while the client saw nothing but success.

We hit exactly this: `observation_photo` 652907815 returned `200`, then
vanished. An immediate retry (652911996) succeeded.

**Therefore the plugin must verify after uploading, and retry on failure.**
See `InatApi.upload_observation_photo_verified` in `explore/inat_api.py`.

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
