--[[
  CustomMetadata.lua
  ------------------
  Defines the custom metadata fields that appear in Lightroom's Metadata panel
  under the "iNaturalist" panel set.

  These fields store the two-way link between a Lightroom photo and its
  iNaturalist observation, as well as the latest synced taxon data.

  Field IDs must be unique and stable; changing them will break existing
  catalogs that already have values stored.

  Almost everything here is readOnly because it mirrors state that lives on
  iNaturalist: a user editing the synced taxon name in Lightroom would have it
  silently overwritten by the next sync, which is worse than not letting them
  type at all. The deliberate exceptions are the observation ID -- pasting one
  is how you link a photo to an observation that already exists -- the species
  guess, which is an instruction to the uploader rather than synced state, and
  the crop.
--]]

return {
  metadataFieldsForPhotos = {

    -- -----------------------------------------------------------------------
    -- Primary link to iNaturalist
    --
    -- The ID stays editable on purpose: typing an existing observation ID into
    -- the Metadata panel and syncing is the only way to adopt an observation
    -- that was created outside Lightroom.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_observation_id",
      title       = LOC "$$$/iNatLightroom/Meta/ObsId=Observation ID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = false,
    },

    -- The observation's UUID, and the reason it is stored rather than derived.
    --
    -- A publish service hands photos to the plugin one at a time, so "these
    -- three frames are one observation" cannot be expressed by the act of
    -- publishing them together the way an export batch could. It has to be
    -- recorded on the photos. Photos carrying the same UUID publish into the
    -- same observation; a photo with none gets a fresh observation, and
    -- iNaturalist's own response supplies the UUID we then store.
    --
    -- readOnly because a hand-edited UUID silently attaches a photo to a
    -- stranger's observation, or to nothing at all. Grouping gets a real
    -- button rather than a text field to mistype.
    {
      id          = "inat_observation_uuid",
      title       = LOC "$$$/iNatLightroom/Meta/ObsUuid=Observation UUID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },
    {
      id          = "inat_observation_url",
      title       = LOC "$$$/iNatLightroom/Meta/ObsUrl=Observation URL",
      dataType    = "url",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Community-determined taxon
    -- -----------------------------------------------------------------------
    {
      id          = "inat_taxon_id",
      title       = LOC "$$$/iNatLightroom/Meta/TaxonId=Taxon ID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = true,
    },
    {
      id          = "inat_taxon_name",
      title       = LOC "$$$/iNatLightroom/Meta/TaxonName=Taxon Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },
    {
      id          = "inat_common_name",
      title       = LOC "$$$/iNatLightroom/Meta/CommonName=Common Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Observation quality
    -- -----------------------------------------------------------------------
    {
      id          = "inat_quality_grade",
      title       = LOC "$$$/iNatLightroom/Meta/QualityGrade=Quality Grade",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- Sync housekeeping
    -- -----------------------------------------------------------------------
    {
      id          = "inat_last_synced",
      title       = LOC "$$$/iNatLightroom/Meta/LastSynced=Last Synced",
      dataType    = "string",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },

    -- -----------------------------------------------------------------------
    -- What to upload
    --
    -- Kept apart from inat_taxon_name on purpose. That field holds what the
    -- iNaturalist community decided, and every sync overwrites it; if the same
    -- field also carried the user's intent, syncing a photo would quietly
    -- change what a later publish uploads. This one is only ever read by the
    -- uploader and never written by a sync.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_species_guess",
      title       = LOC "$$$/iNatLightroom/Meta/SpeciesGuess=Species Guess (upload)",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
      readOnly    = false,
    },

    -- -----------------------------------------------------------------------
    -- iNat-specific crop (stored as "x,y,w,h" fraction string)
    -- Written by the Export dialog before the photo is rendered.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_crop",
      title       = LOC "$$$/iNatLightroom/Meta/Crop=iNat Crop (x,y,w,h)",
      dataType    = "string",
      searchable  = false,
      browsable   = false,
      readOnly    = false,
    },
  },

  -- Schema version; increment when adding/removing fields to allow migration.
  --
  -- v2 added two "url" fields holding lightroom:// links, because a url field
  -- renders as a clickable row and that was the only button the Metadata panel
  -- would give us. v3 removes them: the panel supplies its own "Go to URL"
  -- arrow that a plugin cannot relabel or retarget, and it fires even when the
  -- field is empty, which on Windows opens Explorer. Those actions now live on
  -- the publish service. v3 also adds the observation UUID that lets several
  -- photos publish into one observation, and the species guess.
  schemaVersion = 3,

  updateFromEarlierSchemaVersion = function(_catalog, _previousSchemaVersion, _progressScope)
    -- Nothing to rewrite. Removed fields are dropped by Lightroom, and the
    -- added ones are filled in by the first publish or sync rather than
    -- backfilled here -- the UUID is not something this plugin can invent for
    -- a photo it has never uploaded.
  end,
}
