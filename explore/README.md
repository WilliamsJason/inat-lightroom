# Exploration scripts

Python scripts for experimenting with the iNaturalist REST API before implementing equivalent functionality in the Lightroom plugin (Lua).

---

## Setup

```bash
# Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate     # Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt
```

---

## Configuration

Copy the example environment file and fill in your credentials:

```bash
cp .env.example .env
```

`.env` fields:

| Variable | Description |
|---|---|
| `INAT_APP_ID` | OAuth application client ID |
| `INAT_APP_SECRET` | OAuth application client secret |
| `INAT_USERNAME` | Your iNaturalist username |
| `INAT_PASSWORD` | Your iNaturalist password |

> **Important:** Never commit your `.env` file.  It is already in `.gitignore`.

You can create an OAuth application at <https://www.inaturalist.org/oauth/applications/new>.

---

## Scripts

### `inat_client.py`

A thin wrapper around [`pyinaturalist`](https://pyinaturalist.readthedocs.io/) that handles authentication and provides helpers used by the other scripts. Import it rather than calling it directly.

### `upload_observation.py`

Prototype for the upload workflow:

```bash
python upload_observation.py \
  --photo /path/to/photo.jpg \
  --species "Quercus robur" \
  --lat 51.5074 \
  --lng -0.1278 \
  --date 2024-05-10 \
  [--project-id 12345] \
  [--description "Found near the pond"]
```

This demonstrates:
- Authenticating with iNaturalist
- Searching for a taxon by name
- Creating an observation
- Attaching a photo
- (Optionally) adding the observation to a project

### `sync_observation.py`

Prototype for the sync workflow:

```bash
python sync_observation.py --observation-id 12345678
```

Output: the full taxonomic hierarchy for the community determination, formatted as the keyword path that would be created in Lightroom.

---

## Running tests

```bash
pytest
```

Tests in `tests/` use `pytest` with `responses` for HTTP mocking so no real API calls are made.
