# iNaturalist REST API – Notes

Reference: <https://api.inaturalist.org/v1/docs/>

---

## Authentication

iNaturalist uses **OAuth 2.0**.

| Flow | When to use |
|---|---|
| Authorization Code | Interactive apps where a user logs in via browser |
| Resource Owner Password | CLI / server scripts (username + password → token) |
| Client Credentials | Read-only public data (no user context) |

### Token endpoint
```
POST https://www.inaturalist.org/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=password&client_id=...&client_secret=...&username=...&******
```
Returns `access_token` (never expires until revoked).

The token is passed as a ******
```
Authorization: ******
```

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

iNaturalist stores up to ~2048 px on the long edge; uploading larger images is fine – they are resized server-side. For best quality, export from Lightroom at **2048 px long edge, sRGB, quality 90 JPEG**.

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

## pyinaturalist (Python)

The [`pyinaturalist`](https://pyinaturalist.readthedocs.io/) package provides a typed, well-documented wrapper around the API. Use it for exploration; the Lua plugin will call the API directly.

```python
from pyinaturalist import create_observation, upload_photos, get_observation

# Create observation
response = create_observation(
    taxon_id=48793,
    observed_on="2024-05-10",
    latitude=51.5074,
    longitude=-0.1278,
    access_token=token,
)
observation_id = response["id"]

# Attach photo
upload_photos(observation_id, photo="/path/to/photo.jpg", access_token=token)

# Retrieve
obs = get_observation(observation_id)
print(obs["taxon"]["name"])
```
