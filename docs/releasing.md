# Releasing and in-app updates

NimbusSync updates itself with [Sparkle 2](https://sparkle-project.org). Installed copies read
one appcast, `https://jorben.github.io/NimbusSync/appcast.xml`, served by GitHub Pages from the
`gh-pages` branch.

## What users get

| | Behaviour |
|---|---|
| Channels | Stable releases are on the default channel. Prereleases are on `beta`, offered only with Settings › General › **Include beta versions**. That switch starts on for builds that are themselves prereleases (`-rc.N`), off otherwise. Turning it off never downgrades; the next stable release arrives once it is newer than the installed beta. |
| Checks | Once a day (`SUScheduledCheckInterval` = 86400) while **Check for updates automatically** is on (the default), plus **Check for Updates…** in Settings and the Dock menu. |
| Reminders | Right after launch Sparkle shows its update window. Later in the day, NimbusSync reminds gently instead: a dot on the menu bar icon, a banner in the menu bar panel and, if notifications are allowed, one notification. |
| Skipping | Sparkle's update window offers **Skip This Version**. A skipped version is not offered again; a newer one is. |
| Automatic updates | Off by default. With **Download and install automatically** on, updates download in the background and install when NimbusSync quits; the panel offers **Restart** to install now and relaunch. |

The Dev build (`NimbusSyncDev`, `NIMBUSSYNC_UPDATES_ENABLED = NO`) never updates itself. A build
without `SUPublicEDKey` keeps the updater off, and the release workflow refuses to ship one.

## One-time setup

1. **EdDSA key.** On a Mac, using Sparkle's tools (after building once they are in
   `<BUILD_ROOT>/source-packages/artifacts/sparkle/Sparkle/bin`):

   ```sh
   ./generate_keys            # creates the key in your login Keychain, prints the public key
   ./generate_keys -x sparkle-private-key.txt
   ```

   - Put the printed public key in `Config/NimbusSync-Info.plist` › `SUPublicEDKey`.
   - Store the contents of `sparkle-private-key.txt` as the repository secret
     `SPARKLE_PRIVATE_KEY`, then delete the file. Keep the Keychain copy as the backup: losing
     the key means installed copies can never update again.
2. **GitHub Pages.** After the first publish created `gh-pages`: Settings › Pages › Deploy from a
   branch › `gh-pages` / root.
3. The notarization secrets used by the build (`APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`,
   `APPLE_TEAM_ID`) are also read by the publish workflow.

## Shipping a release

1. Push a tag (`0.2.0-rc.1`, or `0.2.0` for a release you intend to promote).
   `create-prerelease.yml` creates the GitHub prerelease, which starts
   `build-and-upload-macos.yml`: signed universal app, DMG + ZIP, notarization submitted.
2. **Beta, automatic:** when the build succeeds, *Publish Appcast* starts by itself
   (`workflow_run`) and publishes the prerelease to the `beta` channel as soon as Apple has
   accepted its notarization. It checks the notary history once a minute for up to 60 minutes
   (`NOTARIZATION_WAIT_MINUTES`); **Invalid**/**Rejected** fails the run, and so does a
   timeout. After a timeout, run *Actions › Publish Appcast* by hand (tag, channel `beta`) once
   `xcrun notarytool history` shows **Accepted**. Publishes run one at a time, so a stable
   publish queued behind a beta one that is still waiting starts when that one finishes.
3. **Stable:** promote the prerelease to a full release on GitHub. Its `released` event runs
   *Publish Appcast* for the `stable` channel. Nothing is rebuilt: the prerelease's notarized
   ZIP is republished without a channel, replacing its beta entry. Only tags without a suffix
   can go stable. A release promoted before its beta publish ran is skipped by the beta run,
   and a late beta publish never takes a stable build back to `beta`.

*Publish Appcast* refuses to publish when the ZIP's checksum, bundle identifier, version,
team signature or notarization doesn't check out, or when `SPARKLE_PRIVATE_KEY` does not match
the app's `SUPublicEDKey`. It signs the ZIP and the feed (`SURequireSignedFeed`) with the EdDSA
key and pushes `appcast.xml` to `gh-pages`. `Scripts/update-appcast.py` does the XML merge.

## Sandbox and signing notes

- The app is sandboxed, so Sparkle installs through its installer launcher XPC service
  (`SUEnableInstallerLauncherService`), which needs the
  `com.apple.security.temporary-exception.mach-lookup.global-name` entries `-spks` / `-spki` in
  `Config/NimbusSyncRelease.entitlements`. Downloads stay in the app (network client).
- Sparkle's nested helpers ship ad-hoc signed. `Scripts/build.sh` re-signs them with the
  Developer ID identity and the hardened runtime, then re-signs the app; the release workflow
  verifies every helper's team, timestamp and runtime flag.
- An update replaces the whole bundle, File Provider extensions included. Before
  **Restart** hands over to Sparkle the app records that it is not running, as Quit does.
