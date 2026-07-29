# Lightroom Plugin

This directory contains the **inat.lrplugin** Adobe Lightroom Classic plugin.

---

## Installation

1. In Lightroom Classic, open **File → Plug-in Manager**.
2. Click **Add** and navigate to the `plugin/` directory in this repository.
3. Select the `inat.lrplugin` folder and click **Add Plug-in**.
4. The plugin appears in the list; ensure it is checked (enabled).

---

## First-time setup

1. In Lightroom, go to **Library → Plug-in Extras → iNaturalist: Set Up Credentials**.
2. Enter your iNaturalist OAuth **App ID** and **App Secret** (create an app at <https://www.inaturalist.org/oauth/applications/new>), plus your **username** and **account password**.
3. Credentials are stored in Lightroom's encrypted password store (`LrPasswords`).

---

## Usage

### Upload photos as an iNaturalist observation

1. Select one or more photos in Lightroom that are of the same species.
2. Go to **File → Export** (or right-click → **Export**).
3. Choose **iNaturalist** in the Export To drop-down on the left.
4. In the export panel:
   - **Species** – type to autocomplete; pick from the suggestions.
   - **iNat crop** – optionally set a crop used only for the uploaded image.
   - **Date / Location** – override if the EXIF values are wrong.
   - **Project** – optionally add to an iNaturalist project.
5. Click **Export**.  The observation ID is written back to each photo's custom metadata.

### Sync taxon data back to Lightroom

1. Select photos that already have an iNaturalist observation ID.
2. Go to **Library → Plug-in Extras → iNaturalist: Sync Selected Photos**.
3. The plugin fetches the latest community determination from iNaturalist and:
   - Creates/updates the taxonomic keyword hierarchy under an **iNaturalist** root keyword.
   - Updates the custom metadata fields (taxon name, common name, quality grade, etc.).

---

## Custom metadata fields

These fields appear in the **Metadata** panel under the *iNaturalist* panel set:

| Field | Description |
|---|---|
| **Observation ID** | iNaturalist observation ID |
| **Observation URL** | Direct link to the observation |
| **Taxon ID** | ID of the community-determined taxon |
| **Taxon Name** | Scientific name |
| **Common Name** | Vernacular/common name |
| **Quality Grade** | `casual`, `needs_id`, or `research` |
| **Last Synced** | Timestamp of the last sync |

---

## Development

The plugin is written in **Lua** using the [Lightroom Classic SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html).

### File structure

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, version, menu items
├── PluginInit.lua             # Entry point; registers menus
├── ExportServiceProvider.lua  # Upload / publish service
├── SyncObservation.lua        # Sync taxon → Lightroom keywords
├── InatAPI.lua                # HTTP helpers for iNaturalist REST API
└── CustomMetadata.lua         # Custom metadata schema
```

### Reloading after edits

In Plug-in Manager, click **Reload Plug-in** after any Lua file change, or press **Ctrl+Alt+Shift+,** (Mac: **⌘⌥⇧,**) in Lightroom Classic.

### Logging

Set `LOG_LEVEL = "debug"` at the top of `PluginInit.lua` to enable verbose logging in Lightroom's log file (`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/`).
