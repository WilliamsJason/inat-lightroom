--[[
  Info.lua
  --------
  Manifest for the SDK probe: a throwaway plugin that answers questions about
  the Lightroom SDK which cannot be answered by dumping binaries.

  Deliberately a separate plugin rather than a menu item bolted onto
  inat.lrplugin. It reads the catalog and builds dialogs; nothing it does
  should ever be able to ship by accident, and installing it does not disturb
  the copy of the real plugin Lightroom already points at.

  Its toolkit identifier is distinct from the real plugin's, so both can be
  installed at once.
--]]

return {
  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = "com.github.inat-lightroom.sdkprobe",
  LrPluginName        = "iNat SDK Probe",

  LrExportMenuItems = {
    {
      title = "iNat Probe: Catalog APIs…",
      file  = "CatalogProbeMenu.lua",
      id    = "inat_probe_catalog",
    },
    {
      title = "iNat Probe: Scrolled View…",
      file  = "ScrollProbeMenu.lua",
      id    = "inat_probe_scroll",
    },
  },

  VERSION = { major = 0, minor = 0, revision = 1, display = "probe" },
}
