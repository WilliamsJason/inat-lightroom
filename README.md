# inat-lightroom

Exploratory work around [iNaturalist](https://www.inaturalist.org/) APIs, with the long-term goal of producing an Adobe Lightroom Classic plugin.

---

## Goals

### 1. Upload photos to iNaturalist

- **iNat-specific crop** – choose a crop used only for the iNaturalist upload, independent of the main Lightroom crop.
- **Multi-photo observations** – select multiple photos of the same species and associate them with a single iNaturalist observation record.
- **Native resolution** – export at iNaturalist's recommended maximum (2048 px on the long edge) so Lightroom never has to upscale or over-downscale.
- **Two-way link** – write the iNaturalist observation ID back to the Lightroom photo as custom metadata so the two records stay connected.
- **Rich metadata at upload time** – choose from AI species recommendations, add the observation to a project, and optionally override the location or timestamp before submitting.

### 2. Sync iNaturalist data back to Lightroom

Using the stored observation ID, pull the latest community determination from iNaturalist and write the full taxonomic tree (kingdom → species) into the photo's keywords/metadata so that searching for any taxonomic rank returns the correct photos.

### 3. Future ideas

Any other useful functionality identified as the project matures.

---

## Status

The plugin does the full round trip today: export a photo from Lightroom, have
it become an iNaturalist observation with the image attached, and sync the
community determination back as a taxonomic keyword tree. Verified end to end
against the live API — there is no iNaturalist sandbox, so every test writes to
a real account.

Authentication is currently a pasted API token, which expires daily. The
frictionless path needs an approved iNaturalist application, and since 2022
those are reviewed manually. See [`plugin/README.md`](plugin/README.md).

Rough edges worth knowing: single-photo observations only so far, the iNat crop
and project fields are not wired up yet, and the AI species suggestions are
prototyped in Python but not in the plugin.

---

## Repository layout

```
inat-lightroom/
├── docs/                        # Notes, API reference, architecture decisions
│   ├── inat-api-notes.md        # iNaturalist REST API traps, verified live
│   ├── lightroom-sdk-notes.md   # Lightroom SDK traps, found the hard way
│   └── plugin-architecture.md   # Lightroom plugin design
│
├── explore/                     # Python exploration + the Lua test harness
│   ├── README.md
│   ├── inat_api.py              # Direct API client; the Lua mirrors this
│   ├── feasibility_test.py      # Full round trip against the live API
│   ├── suggest_species.py       # Computer-vision species suggestions
│   ├── lua_harness.py           # Runs the plugin's Lua outside Lightroom
│   ├── check_lua.py             # Parses the plugin under Lua 5.1
│   └── test_*_lua.py            # Tests over the plugin's actual Lua
│
└── plugin/                      # Adobe Lightroom Classic plugin (Lua)
    ├── README.md
    └── inat.lrplugin/
        ├── Info.lua             # Plugin identity, version, menu, tagsets, URL handler
        ├── InatMenu.lua         # The single Plug-in Extras entry
        ├── PluginInit.lua       # Legacy "Set Up Credentials" menu item
        ├── CredentialsDialog.lua # The credentials dialog itself
        ├── InatAuth.lua         # Token acquisition and credential storage
        ├── InatAPI.lua          # HTTP client for the iNaturalist REST API
        ├── ExportServiceProvider.lua  # Upload service
        ├── SyncObservation.lua  # Menu script: launches a sync
        ├── SyncCore.lua         # Sync taxon data → Lightroom keywords
        ├── PanelActions.lua     # Clickable actions for the Metadata panel
        ├── URLHandler.lua       # Receives those clicks and dispatches
        ├── TagsetInat*.lua      # Metadata panel presets
        ├── CustomMetadata.lua   # Custom metadata schema
        ├── Log.lua              # Shared logger
        └── json.lua             # Bundled JSON encoder/decoder
```

---

## Quick start (Python exploration)

```powershell
cd explore
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Put an API token from <https://www.inaturalist.org/users/api_token> in `.env`
as `INAT_API_TOKEN`, then:

```powershell
# Species suggestions for a photo
.\.venv\Scripts\python.exe suggest_species.py --photo C:\path\to\photo.jpg

# Full upload/update/sync round trip -- creates a real observation
.\.venv\Scripts\python.exe feasibility_test.py --photo C:\path\to\photo.jpg
```

See [`explore/README.md`](explore/README.md) for full details.

---

## Quick start (Lightroom plugin)

See [`plugin/README.md`](plugin/README.md) for installation and development instructions.

---

## Contributing

This is currently a personal exploratory project. If you have ideas or want to collaborate, open an issue to start the conversation.

---

## License

MIT – see [LICENSE](LICENSE).
