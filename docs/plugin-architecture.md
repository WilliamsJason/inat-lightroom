# Lightroom Plugin – Architecture

## Overview

The plugin is an **Adobe Lightroom Classic** plugin written in Lua using the [Lightroom SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html). It consists of two main capabilities:

1. **Publish / Upload** – export selected photos directly to iNaturalist as observations.
2. **Sync** – pull the latest community identification from iNaturalist and write the full taxonomic tree into Lightroom keywords.

---

## Plugin files

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, SDK version, menu, tagsets, URL handler
├── PluginInit.lua             # Menu script: opens the credentials dialog
├── InatMenu.lua               # Menu script: the single Plug-in Extras entry
├── SyncObservation.lua        # Menu script: launches a sync
├── CredentialsDialog.lua      # The credentials dialog itself
├── SyncCore.lua               # Sync logic, callable from any entry point
├── ExportServiceProvider.lua  # Publish service (upload to iNaturalist)
├── PanelActions.lua           # lightroom:// action links for the Metadata panel
├── URLHandler.lua             # Receives those links and dispatches
├── TagsetInat.lua             # Metadata panel preset: iNaturalist fields only
├── TagsetInatCombined.lua     # Metadata panel preset: everyday fields + iNaturalist
├── InatAPI.lua                # HTTP helpers wrapping iNaturalist REST API (LrHttp)
└── CustomMetadata.lua         # Custom metadata schema definition
```

The three menu scripts are deliberately thin. Lightroom executes a menu-item
file top to bottom when the item is clicked, so a file registered as a menu item
cannot be required from anywhere else without performing its action as a side
effect. Logic lives in `SyncCore.lua` and `CredentialsDialog.lua`; the scripts
only launch it.

---

## Where the plugin lives in the UI

Lightroom Classic has **no SDK hook for adding a panel to the Library right
panel stack**. This was checked against the shipped binaries, not assumed — see
[lightroom-sdk-notes.md](lightroom-sdk-notes.md). Third-party products that
appear to have one are companion applications drawing their own window over the
panel column.

So the plugin's home is the **Metadata panel**, via two presets in its dropdown:

| Preset | Contents |
|---|---|
| `iNaturalist` | Only this plugin's fields |
| `iNaturalist + Default` | The everyday Lightroom fields, then iNaturalist |

The combined preset is the one meant for daily use. A preset *replaces* the
panel's contents rather than adding to it, so a plugin-only preset is something
users switch away from and never switch back.

### Actions in the panel

The Metadata panel renders no buttons, but it renders a field of
`dataType = "url"` as a clickable row. `PanelActions.lua` writes plugin URLs
into two such fields:

```
inat_action_sync  →  lightroom://com.github.inat-lightroom/sync
inat_action_link  →  lightroom://com.github.inat-lightroom/link
```

`URLHandler.lua`, registered through the `URLHandler` key in `Info.lua`,
receives the click and dispatches. `link` asks for an observation ID and
attaches it to the selection — the workflow for adopting an observation created
outside Lightroom, which nothing else offered.

A custom metadata field has no default, so these rows only appear once
something has written to them. Sync does it on the way past; for photos with no
iNaturalist data yet, `Library > Plug-in Extras > iNaturalist…` has an option
to arm the selection. That is the only reason a menu item still exists.

> **Unverified in the host.** Whether Lightroom routes a click on a *metadata*
> URL back into the plugin's `URLHandler` has not yet been confirmed by running
> it. If it does not, the fields are inert text and the fallback is a persistent
> floating dialog (`LrInitPlugin` + `presentFloatingDialog{ blockTask = false,
> save_frame = … }`), which has OS window chrome and cannot dock.

---

## Custom metadata schema (`CustomMetadata.lua`)

| Field ID | Type | Access | Description |
|---|---|---|---|
| `inat_observation_id` | `string` | editable | iNaturalist observation ID |
| `inat_observation_url` | `url` | read-only | Direct URL to the observation |
| `inat_taxon_id` | `string` | read-only | Taxon ID of the community determination |
| `inat_taxon_name` | `string` | read-only | Scientific name of the taxon |
| `inat_common_name` | `string` | read-only | Vernacular/common name |
| `inat_quality_grade` | `string` | read-only | `casual`, `needs_id`, or `research` |
| `inat_last_synced` | `string` | read-only | ISO 8601 timestamp of last sync |
| `inat_crop` | `string` | editable | iNat-specific crop, `x,y,w,h` |
| `inat_action_sync` | `url` | read-only | Panel action link |
| `inat_action_link` | `url` | read-only | Panel action link |

Everything mirroring iNaturalist state is read-only: an edit would be silently
overwritten by the next sync, which is worse than not being editable. The
observation ID stays editable on purpose — pasting one is how a photo adopts an
observation that already exists.

These fields appear in Lightroom's **Metadata** panel under either iNaturalist
preset.

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
SyncCore.lua reads inat_observation_id from each photo
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
