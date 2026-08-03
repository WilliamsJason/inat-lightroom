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
  type at all. The two deliberate exceptions are the observation ID -- pasting
  one is how you link a photo to an observation that already exists -- and the
  crop, which the export dialog writes but a user may want to clear.
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

    -- -----------------------------------------------------------------------
    -- Panel actions
    --
    -- Not data: these hold "lightroom://com.github.inat-lightroom/<action>"
    -- URLs so the Metadata panel renders a clickable row, which is the closest
    -- thing to a button the panel offers. See PanelActions.lua.
    -- -----------------------------------------------------------------------
    {
      id          = "inat_action_sync",
      title       = LOC "$$$/iNatLightroom/Meta/ActionSync=Sync from iNaturalist",
      dataType    = "url",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },
    {
      id          = "inat_action_link",
      title       = LOC "$$$/iNatLightroom/Meta/ActionLink=Link to Observation…",
      dataType    = "url",
      searchable  = false,
      browsable   = false,
      readOnly    = true,
    },
  },

  -- Schema version; increment when adding/removing fields to allow migration.
  -- v2 added the two panel action fields and marked the synced fields
  -- readOnly. Both are additive, so there is nothing to rewrite -- but the SDK
  -- still wants the hook present once the version moves.
  schemaVersion = 2,

  updateFromEarlierSchemaVersion = function(_catalog, _previousSchemaVersion, _progressScope)
    -- v1 -> v2 adds fields and tightens permissions. Existing values stay
    -- valid, and the action URLs are written lazily by PanelActions rather
    -- than backfilled here, so this deliberately does nothing.
  end,
}
