"""Prove the updater tests catch what they claim to.

The updater is the one part of this plugin that can replace the plugin, so
"the tests pass" is worth less here than usual and "the tests would have
noticed" is worth more. Each mutation below is a mistake that is easy to make,
easy to miss in review, and silent in the host until it has already done
something -- offered a downgrade, applied half an update, or trusted a download
it never checked.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).parent.parent / "plugin" / "inat.lrplugin"
TARGETS = {
    "Updater": PLUGIN / "Updater.lua",
    "UpdateInstall": PLUGIN / "UpdateInstall.lua",
    "UpdateCore": PLUGIN / "UpdateCore.lua",
    "PluginInfoProvider": PLUGIN / "PluginInfoProvider.lua",
}

TESTS = [
    "test_updater_lua.py",
    "test_update_install_lua.py",
    "test_update_core_lua.py",
    "test_plugin_info_provider_lua.py",
]

MUTATIONS = [
    # -- Finding out whether there is an update -----------------------------
    (
        "Updater",
        "versions are compared as strings, so 0.10.0 is older than 0.9.0",
        "  local fields = { \"major\", \"minor\", \"revision\" }\n"
        "  for _, field in ipairs(fields) do\n"
        "    local left  = candidate[field] or 0\n"
        "    local right = installed[field] or 0\n"
        "    if left > right then return true end\n"
        "    if left < right then return false end\n"
        "  end\n\n  return false",
        "  return Updater.versionString(candidate) > Updater.versionString(installed)",
    ),
    (
        "Updater",
        "the version you already have counts as an update",
        "    if left > right then return true end",
        "    if left >= right then return true end",
    ),
    (
        "Updater",
        "an older release is offered as an upgrade",
        "    if left < right then return false end",
        "    if left < right then return true end",
    ),
    (
        "Updater",
        "an asset hosted anywhere at all is downloaded",
        "    if type(name) == \"string\" and type(url) == \"string\"\n"
        "       and url:sub(1, #Updater.ASSET_URL_PREFIX) == Updater.ASSET_URL_PREFIX then",
        "    if type(name) == \"string\" and type(url) == \"string\" then",
    ),
    (
        "Updater",
        "an archive is verified against some other file's checksum",
        "    if digest and name == assetName and #digest == 64 then",
        "    if digest and #digest == 64 then",
    ),
    (
        "Updater",
        "a truncated digest is accepted as a checksum",
        "    if digest and name == assetName and #digest == 64 then",
        "    if digest and name == assetName then",
    ),
    (
        "Updater",
        "an HTTP error page is parsed as if it were a release",
        "  local status = headers and tonumber(headers.status)\n  if status and status ~= 200 then",
        "  local status = headers and tonumber(headers.status)\n  if false then",
    ),
    # -- Putting it on disk --------------------------------------------------
    (
        "UpdateInstall",
        "files dropped from a release are left behind forever",
        "    if not wanted[path] and not isStaging then\n"
        "      plan.delete[#plan.delete + 1] = path\n    end",
        "    if false then\n      plan.delete[#plan.delete + 1] = path\n    end",
    ),
    (
        "UpdateInstall",
        "the swap deletes the staging folder it is still copying from",
        "    local isStaging = path == UpdateInstall.STAGING_DIR\n"
        "      or path:sub(1, #UpdateInstall.STAGING_DIR + 1)\n"
        "         == (UpdateInstall.STAGING_DIR .. \"/\")",
        "    local isStaging = false",
    ),
    (
        "UpdateInstall",
        "a half-unpacked staging folder is applied over the plugin",
        "  local marker = UpdateInstall.readyMarkerPath(pluginPath)\n"
        "  if not fs.exists(marker) then return nil end",
        "  local marker = UpdateInstall.readyMarkerPath(pluginPath)",
    ),
    (
        "UpdateInstall",
        "a failed swap throws its staging folder away, so it never retries",
        "    logger:error(\"Updater: could not apply \" .. tostring(tag) .. \": \" ..\n"
        "      tostring(result))\n    return nil",
        "    UpdateInstall.discard(pluginPath, fs)\n    return nil",
    ),
    (
        "UpdateInstall",
        "the staging folder is left in place after a successful swap",
        "  UpdateInstall.discard(pluginPath, fs)\n  logger:info(\"Updater: applied \"",
        "  logger:info(\"Updater: applied \"",
    ),
    (
        "UpdateInstall",
        "a read-only plugin folder is discovered only after downloading",
        "  local writable, whyNot = UpdateInstall.canWrite(pluginPath, fs)\n"
        "  if not writable then\n    return nil, whyNot\n  end",
        "  local writable, whyNot = UpdateInstall.canWrite(pluginPath, fs)",
    ),
    (
        "UpdateInstall",
        "anything at all is accepted as the expected checksum",
        "  if type(hash) ~= \"string\" or not hash:match(\"^%x%x+$\") then",
        "  if false then",
    ),
    # -- Deciding when, and what to say --------------------------------------
    (
        "UpdateCore",
        "turning off automatic checks does not turn them off",
        "  if enabled == false then return false end",
        "  if false then return false end",
    ),
    (
        "UpdateCore",
        "a stopped clock switches the daily check off forever",
        "  if lastChecked > now then return true end",
        "  if lastChecked > now then return false end",
    ),
    (
        "UpdateCore",
        "the check runs on every launch instead of once a day",
        "  return (now - lastChecked) >= UpdateCore.CHECK_INTERVAL_SECONDS",
        "  return true",
    ),
    (
        "UpdateCore",
        "an offline week means a request on every single launch",
        "  Settings.set(\"update_last_checked\", LrDate.currentTime())\n\n  if not result then",
        "  if not result then",
    ),
    (
        "UpdateCore",
        "a failed check reads as 'nothing new' rather than 'could not check'",
        "  if err then\n    return \"Could not check for updates: \" .. tostring(err)\n  end",
        "  if err then\n    return \"Version is the latest release.\"\n  end",
    ),
    (
        "UpdateCore",
        "you are told about the same release every single morning",
        "  return tag ~= alreadyNotifiedTag",
        "  return true",
    ),
    (
        "UpdateCore",
        "the startup check installs the update by itself",
        "    local result = UpdateCore.check()\n"
        "    if not UpdateCore.shouldNotify(result, Settings.get(\"update_notified_tag\")) then\n"
        "      return\n    end",
        "    local result = UpdateCore.check()\n"
        "    if result and result.canInstall then UpdateCore.install(result) end\n"
        "    if not UpdateCore.shouldNotify(result, Settings.get(\"update_notified_tag\")) then\n"
        "      return\n    end",
    ),
    (
        "UpdateCore",
        "the startup check blocks Lightroom while it loads plugins",
        "  LrTasks.startAsyncTask(function()\n    LrTasks.sleep(UpdateCore.STARTUP_DELAY_SECONDS)",
        "  do\n    LrTasks.sleep(UpdateCore.STARTUP_DELAY_SECONDS)",
    ),
    # -- The Plug-in Manager section ----------------------------------------
    #
    # This one is not hypothetical. It shipped, and it is why the section
    # rendered with the version and the status line both blank.
    (
        "PluginInfoProvider",
        "every bound field falls through to the preferences and renders blank",
        "        bind_to_object = props,\n",
        "",
    ),
    (
        "PluginInfoProvider",
        "the version is read once and can never update on screen",
        "  props.installedVersion = Updater.versionString(Updater.currentVersion())",
        "  props.installedVersion = props.installedVersion or\n"
        "    Updater.versionString(Updater.currentVersion())",
    ),
    (
        "PluginInfoProvider",
        "turning automatic checks off is forgotten as soon as the dialog closes",
        "  if props.update_check_automatically ~= nil then\n"
        "    Settings.set(\"update_check_automatically\", props.update_check_automatically)\n"
        "  end",
        "  if props.update_check_automatically then\n"
        "    Settings.set(\"update_check_automatically\", props.update_check_automatically)\n"
        "  end",
    ),
    (
        "PluginInfoProvider",
        "Install runs on whatever the last check found, even nothing",
        "  local result = props.result\n  if not result or not result.canInstall then",
        "  local result = props.result\n  if false then",
    ),
]


def main() -> int:
    backups = {name: path.read_text(encoding="utf-8") for name, path in TARGETS.items()}
    survivors = []

    try:
        for name, description, old, new in MUTATIONS:
            path = TARGETS[name]
            source = backups[name]

            if old not in source:
                print(f"SKIP  {description}\n      (anchor not found -- fix the script)")
                survivors.append(description)
                continue

            path.write_text(source.replace(old, new, 1), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, "-m", "pytest", *TESTS, "-q",
                 "--no-header", "-x", "--tb=no", "-p", "no:cacheprovider"],
                cwd=Path(__file__).parent,
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                print(f"SURVIVED  {description}")
                survivors.append(description)
            else:
                print(f"caught    {description}")
    finally:
        for name, path in TARGETS.items():
            path.write_text(backups[name], encoding="utf-8")

    print()
    if survivors:
        print(f"{len(survivors)} of {len(MUTATIONS)} mutations survived:")
        for s in survivors:
            print(f"  - {s}")
        return 1

    print(f"All {len(MUTATIONS)} mutations caught.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
