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

## Repository layout

```
inat-lightroom/
├── docs/                        # Notes, API reference, architecture decisions
│   ├── inat-api-notes.md        # iNaturalist REST API cheat-sheet
│   └── plugin-architecture.md  # Planned Lightroom plugin design
│
├── explore/                     # Python scripts for rapid API exploration
│   ├── README.md
│   ├── requirements.txt
│   ├── inat_client.py           # Thin authenticated wrapper (pyinaturalist)
│   ├── upload_observation.py    # Prototype: create observation + attach photo
│   └── sync_observation.py      # Prototype: fetch taxon tree from observation ID
│
└── plugin/                      # Adobe Lightroom Classic plugin (Lua)
    ├── README.md
    └── inat.lrplugin/
        ├── Info.lua             # Plugin identity & SDK version
        ├── PluginInit.lua       # Startup hooks & menu items
        ├── ExportServiceProvider.lua  # Publish / upload service
        ├── SyncObservation.lua  # Sync taxon data → Lightroom keywords
        ├── InatAPI.lua          # Lua HTTP helpers for iNaturalist REST API
        └── CustomMetadata.lua   # Custom metadata schema (observation ID, taxon)
```

---

## Quick start (Python exploration)

```bash
cd explore
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# Copy and fill in your iNaturalist OAuth credentials
cp .env.example .env

# Upload a test observation
python upload_observation.py --photo /path/to/photo.jpg --species "Quercus robur"

# Sync an existing observation's taxon data
python sync_observation.py --observation-id 12345678
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
