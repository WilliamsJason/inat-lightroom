# Security

## Reporting a problem

Please report anything security-relevant privately, through
[GitHub's private vulnerability reporting](https://github.com/WilliamsJason/inat-lightroom/security/advisories/new)
rather than as a public issue. Include what you did, what happened, and what
version you were running — the version is in **File → Plug-in Manager →
iNaturalist**.

This is a spare-time project, so please do not expect a same-day reply.

## What the plugin handles

**Your iNaturalist credentials.** The API token you paste is stored with
`LrPasswords`, which is Lightroom's wrapper around the OS credential vault —
Windows Credential Manager or the macOS Keychain. It is not written to disk by
the plugin and it is not written to its log. Use **Clear Stored Credentials**
on the Account tab of the settings window to remove it.

The plugin never asks for your iNaturalist password.

**Your photos and their locations.** Uploads go to iNaturalist over HTTPS. What
travels with them is yours to decide in the settings window: an observation's
geoprivacy, whether the photo's GPS coordinates are sent at all, and how much
metadata stays in the uploaded JPEG.

## Updating, and what you are trusting

The plugin can update itself. When it does, it downloads a release archive from
this repository's GitHub releases over HTTPS and verifies it against the
`SHA256SUMS` file published with that release.

Be clear about what that checksum does. It ships from the same place as the
archive, so anyone who could replace one could replace the other. It catches a
corrupted or truncated download; it is not a defence against a compromised
GitHub account or repository. **TLS and GitHub's identity are the trust
boundary**, and what is downloaded includes scripts that run on your machine.

If you would rather not extend that trust:

- Untick **Check for updates automatically** in the Plug-in Manager. Nothing is
  ever downloaded or installed without you clicking a button.
- Install by hand from a release you have looked at yourself.

The plugin only ever downloads from
`https://github.com/WilliamsJason/inat-lightroom/releases/download/...`, and
refuses any asset URL that does not start with exactly that, whatever the
release metadata says.

## What the plugin runs

It shells out twice, both times to scripts that ship inside the plugin folder:

- `fix_window_z_order.ps1` — Windows only, gives the floating panel an owner
  window so it stops floating over every other application.
- `install_update.ps1` / `install_update.sh` — verifies and unpacks a
  downloaded update into a staging folder.

Neither takes input from iNaturalist. The updater's script receives a file path
and a hex digest.

## Scope

This plugin talks to iNaturalist's public API with your own account. Problems
with iNaturalist itself belong at <https://www.inaturalist.org>, not here.
