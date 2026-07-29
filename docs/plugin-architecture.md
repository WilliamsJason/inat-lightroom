# Lightroom Plugin – Architecture

## Overview

The plugin is an **Adobe Lightroom Classic** plugin written in Lua using the [Lightroom SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html). It consists of two main capabilities:

1. **Publish / Upload** – export selected photos directly to iNaturalist as observations.
2. **Sync** – pull the latest community identification from iNaturalist and write the full taxonomic tree into Lightroom keywords.

---

## Plugin files

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, SDK version, menu items
├── PluginInit.lua             # Entry point: called when Lightroom loads the plugin
├── ExportServiceProvider.lua  # Publish service (upload to iNaturalist)
├── SyncObservation.lua        # Sync taxon keywords from iNaturalist → Lightroom
├── InatAPI.lua                # HTTP helpers wrapping iNaturalist REST API (LrHttp)
└── CustomMetadata.lua         # Custom metadata schema definition
```

---

## Custom metadata schema (`CustomMetadata.lua`)

| Field ID | Type | Description |
|---|---|---|
| `inat_observation_id` | `string` | iNaturalist observation ID |
| `inat_observation_url` | `string` | Direct URL to the observation |
| `inat_taxon_id` | `string` | Taxon ID of the community determination |
| `inat_taxon_name` | `string` | Scientific name of the taxon |
| `inat_common_name` | `string` | Vernacular/common name |
| `inat_quality_grade` | `string` | `casual`, `needs_id`, or `research` |
| `inat_last_synced` | `string` | ISO 8601 timestamp of last sync |

These fields appear in Lightroom's **Metadata** panel under the "iNaturalist" panel set.

---

## Upload workflow

```
User selects photos in Lightroom
        │
        ▼
Export dialog opens  ──────────────────────────────────────────────────┐
  • Species search box (autocomplete via /taxa/autocomplete)            │
  • Optional: iNat-specific crop (2nd crop stored in custom metadata)  │
  • Optional: project picker                                           │
  • Optional: override location / timestamp                            │
  • Multi-photo: group selected photos → single observation            │
        │                                                              │
        ▼                                                              │
Lightroom renders JPEG at 2048 px long edge (sRGB, q90)               │
        │                                                              │
        ▼                                                              │
POST /observations  → get observation_id                               │
        │                                                              │
        ▼                                                              │
POST /observation_photos (once per selected photo)                     │
        │                                                              │
        ▼                                                              │
(optional) POST /project_observations                                  │
        │                                                              │
        ▼                                                              │
Write observation_id → CustomMetadata.inat_observation_id             │
        │                                                              │
        └──────────────────────────────────────────────────────────────┘
```

### iNat-specific crop

Lightroom does not expose per-export crop to Lua directly. The approach:

1. In the export dialog, show a **"Set iNat Crop…"** button.
2. This opens a floating window (using `LrDialogs`) that lets the user drag a crop rectangle over a preview.
3. The crop rectangle (as `x, y, w, h` fractions of the original) is stored in `CustomMetadata`.
4. At export time, `ExportServiceProvider.processRenderedPhotos` reads the stored crop, uses `LrPhoto:requestJpegThumbnail` or a secondary export task to produce a cropped JPEG, and uploads that instead of the main export.

> **Alternative (simpler):** Use a Lightroom virtual copy with a different crop and export the virtual copy. The plugin can create the virtual copy automatically.

---

## Sync workflow

```
User selects photos with inat_observation_id set
        │
        ▼
SyncObservation.lua reads inat_observation_id from each photo
        │
        ▼
GET /observations/{id}  →  returns observation + community_taxon + ancestors
        │
        ▼
Build keyword hierarchy:
  Animalia > Arthropoda > Insecta > Lepidoptera > … > Quercus robur
        │
        ▼
LrCatalog:withWriteAccessDo → LrPhoto:addKeyword for each ancestor
        │
        ▼
Update CustomMetadata fields:
  inat_taxon_id, inat_taxon_name, inat_common_name,
  inat_quality_grade, inat_last_synced
```

---

## Authentication

The plugin stores the iNaturalist `access_token` in **Lightroom's encrypted password store** (`LrPasswords`). On first run (or when the token is missing), the plugin opens a dialog asking the user for their OAuth credentials.

For the interactive OAuth flow (required for public App Store distribution), Lightroom can open the system browser via `LrHttp.openUrlInBrowser` and listen for the redirect on a local port using `LrSocket`. For personal/development use, the resource-owner password grant is simpler.

---

## LrHttp notes

The Lightroom SDK provides `LrHttp` for HTTP requests. Key points:

- `LrHttp.get(url, headers)` – simple GET, returns body string
- `LrHttp.post(url, body, headers, method, contentType)` – POST/PUT
- Multipart form data (for photo upload) requires manually building the MIME boundary string.
- SSL is supported but certificate errors will surface as empty responses; ensure the iNaturalist API certificate chain is valid on the user's machine.

A thin `InatAPI.lua` module wraps these calls and handles JSON encode/decode (via a bundled `json.lua`).

---

## Keyword hierarchy approach

Lightroom keywords are hierarchical. The sync step creates/reuses:

```
iNaturalist
└── <kingdom>
    └── <phylum>
        └── <class>
            └── <order>
                └── <family>
                    └── <genus>
                        └── <species binomial>
                            └── <common name>   (synonyms/alias keyword)
```

Using `LrCatalog:createKeyword(name, synonyms, includeOnExport, parent, skipIfAlreadyExists)`.

---

## Export size recommendation

iNaturalist resizes uploaded images to a maximum of **2048 px** on the long edge for display but retains the original. For plugin uploads, exporting at 2048 px is a good default because:

- It matches iNaturalist's display resolution exactly (no server-side downscaling artefacts for the displayed version).
- It keeps upload times reasonable.
- Users can override in the export dialog if they prefer the original resolution.

---

## Future ideas

- **Batch sync** – sync all photos with an `inat_observation_id` in one click.
- **Smart collections** – auto-populate smart collections based on taxonomic keyword hierarchy.
- **Map view integration** – open the observation in the iNaturalist web map.
- **Identification alerts** – notify the user when a new ID is added to their observation.
