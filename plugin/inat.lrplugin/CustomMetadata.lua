--[[
  CustomMetadata.lua
  ------------------
  Defines the custom metadata fields that appear in Lightroom's Metadata panel
  under the "iNaturalist" panel set.

  These fields store the two-way link between a Lightroom photo and its
  iNaturalist observation, as well as the latest synced taxon data.

  Field IDs must be unique and stable; changing them will break existing
  catalogs that already have values stored.
--]]

return {
  metadataFieldsForPhotos = {

    -- -----------------------------------------------------------------------
    -- Primary link to iNaturalist
    -- -----------------------------------------------------------------------
    {
      id          = "inat_observation_id",
      title       = LOC "$$$/iNatLightroom/Meta/ObsId=Observation ID",
      dataType    = "string",
      searchable  = true,
      browsable   = false,
    },
    {
      id          = "inat_observation_url",
      title       = LOC "$$$/iNatLightroom/Meta/ObsUrl=Observation URL",
      dataType    = "url",
      searchable  = false,
      browsable   = false,
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
    },
    {
      id          = "inat_taxon_name",
      title       = LOC "$$$/iNatLightroom/Meta/TaxonName=Taxon Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
    },
    {
      id          = "inat_common_name",
      title       = LOC "$$$/iNatLightroom/Meta/CommonName=Common Name",
      dataType    = "string",
      searchable  = true,
      browsable   = true,
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
    },
  },

  -- Schema version; increment when adding/removing fields to allow migration
  schemaVersion = 1,
}
