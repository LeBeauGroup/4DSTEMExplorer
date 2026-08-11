# 4DSTEM Explorer

Native macos application for the dynamic exploration of 4D STEM data aquired with the EMPAD detector. 

To cite:

J. M. LeBeau, "4D STEM Explorer” (2018): doi:10.5281/zenodo.1325482


Privacy policy: No user data is collected.

[![DOI](https://zenodo.org/badge/116034666.svg)](https://zenodo.org/badge/latestdoi/116034666)

## Releasing

The application updates itself through [Sparkle](https://sparkle-project.org),
reading an appcast from S3. `Product ▸ Archive` in Xcode runs
`Scripts/make_release.sh` as a post-action; the script can also be run on its
own, with or without an already-built app:

```
Scripts/make_release.sh                  # builds Release itself
Scripts/make_release.sh /path/to.app     # signs an app you already have
```

It signs (Sparkle's nested code first, then the plugin bundles, then the app),
notarises, staples, zips, and regenerates `4DSTEMExplorerAppcast.xml`, then
prints the two `aws s3 cp` commands to run. **Upload the zip before the
appcast** — the feed points at the zip, so a feed naming a file that is not
there yet fails the update check for every running copy.

Releases are built from `dist/release/`, which is deliberately not in the
repository but is worth keeping locally: `generate_appcast` rebuilds the whole
feed from the archives it finds there, so a folder with only the newest zip
produces a feed with only the newest version.

### One-time setup

| What | Where it lives | How to create it |
| --- | --- | --- |
| Developer ID certificate | login Keychain | Xcode ▸ Settings ▸ Accounts |
| Notarisation credentials | Keychain profile `4dstem-notary` | `xcrun notarytool store-credentials 4dstem-notary --apple-id YOUR_APPLE_ID --team-id 67JZ53W5NK` (needs an app-specific password) |
| Sparkle EdDSA key | login Keychain, service `https://sparkle-project.org` | already present — shared with the group's other applications |
| S3 credentials | `aws` profile `default` | `aws configure` |

The bucket (`4dstem-explorer`) must serve the appcast and the zips publicly
over HTTPS. Nothing secret goes in it: the public half of the signing key is in
`Info.plist` and the private half never leaves the Keychain, which is what
stops someone with write access to the bucket from shipping code.

The app is **not sandboxed**. It is distributed with a Developer ID rather than
through the App Store — which Sparkle rules out anyway — and it reads data from
arbitrary paths, materialises files from iCloud and Dropbox, walks user-chosen
directory trees for batch runs, and loads third-party plugin bundles. The
hardened runtime and notarisation are what Gatekeeper actually checks, and both
stay on.
