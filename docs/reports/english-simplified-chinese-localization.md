# English and Simplified Chinese localization — Phase 4 follow-up

Date: 2026-11-14

This increment implements English (`en`) and Simplified Chinese (`zh-Hans`). The wider Phase 4 release plan and its remaining language/platform/release gates are not declared complete by this increment.

## Implementation

- DomainKit owns native shared resources, language matching, the App Group preference and presentation of stable sync error codes. The source table has 424 strings and nine plural entries.
- Settings offers Follow System, English and 简体中文. Main app windows and commands update without replacing view identity. Existing errors retain their underlying error and format their text again when the language changes.
- Native picker options use stable localization keys. AppKit window titles and menu headers update, and app commands use reactive verbatim text so their accessibility representation updates too.
- The app and both extensions package the same resource files. Debug and Release keep separate App Group identities.
- Finder manifests use the platform's action keys and UI extension point. Original action identifiers remain canonical; Chinese display aliases are allowlisted and normalize to those existing handlers.
- Item presentation includes a stable language code and localized decoration labels. Projection schema revision 5 and the existing bounded durable working-set refresh update cached metadata without changing content versions, names, capabilities or transfer policy. A language selection also requests the refresh from the app; extension startup independently resumes persisted work.

## Verified evidence

Main application runtime checks used a signed Debug app on the current macOS host:

| Check | Evidence |
| --- | --- |
| English and Simplified Chinese update existing Settings and native application commands | [Runtime check](../evidence/localization/runtime-check.txt) |
| Existing Add Domain window, entered address and displayed validation error survive a language change | [English](../evidence/localization/add-domain.en.png), [简体中文](../evidence/localization/add-domain.zh-Hans.png) |
| Native theme options and language picker render in the selected language | [English Settings](../evidence/localization/general.en.png), [简体中文设置](../evidence/localization/general.zh-Hans.png) |
| Simplified Chinese preference survives app relaunch | [Persistence check](../evidence/localization/persistence-check.txt) |
| Menu bar popover labels use the selected language | [English](../evidence/localization/popover.en.json), [简体中文](../evidence/localization/popover.zh-Hans.json) |
| Follow System resolves the host language and the original effective preference is restored | [Final UI check](../evidence/localization/final-ui-check.txt) |
| Real Finder metadata and visible Quick Actions use English / Simplified Chinese without unresolved keys | [Sanitized Finder evidence](../evidence/localization/finder-runtime.json) |
| Dev File Provider remains enabled after verification | [Integration state](../evidence/localization/integration-state.txt) |
| Native resource keys and interpolation arguments match | `python3 Scripts/check-localization.py` |
| Compiler-extracted localization keys are covered | `python3 Scripts/check-localization.py --build-root <derived-data-path>` |

Real Finder validation is recorded separately from the Swift tests and builds. It uses the system-managed Debug extension and an existing test domain; no remote mutation action is executed. Only sanitized action labels and language codes belong in committed evidence, not file names, paths, account data or daemon dumps.

## Audit follow-up (2026-11-14)

An independent completion audit found four gaps; all are addressed:

1. **App-owned error codes:** `SyncErrorText` now covers every `CoreErrorCode` plus the `download_failed` / `upload_failed` fallbacks. A regression test enumerates `CoreErrorCode.allCases` and requires a Han-script presentation in Simplified Chinese, so newly added codes cannot silently fall back to English. Unknown server-provided text still passes through unchanged.
2. **Accessibility placeholder:** the log-folder VoiceOver label is produced by `SettingsDiagnosticsText.logFolderAccessibilityLabel`, which localizes only the `unavailable` placeholder and keeps a real path verbatim.
3. **Compound counts:** `%lld of %lld domains need attention` is a native plural entry keyed on the affected count with positional arguments (`1 of 2 domains needs attention` / `2 of 3 domains need attention`; Chinese keeps the total). Covered for 1/2, 1/3 and 2/3 in both languages.
4. **Key-screen runtime coverage:** `Scripts/LocalizationPreview/run.sh` renders the actual shared SwiftUI/AppKit components in an isolated, network-free app identity (no Store, credentials or File Provider) with the same main-bundle and package resources as the shipping targets. [UI coverage evidence](../evidence/localization/ui-coverage/) contains English and Simplified Chinese captures of the Domains page (820 pt and narrow 580 pt), all four Add Domain authorization stages, the conflict window, the Finder integration guide and the open menu bar popover. `runtime-events.json` records three consecutive language switches with the popover kept open: the same panel window stayed visible and updated each time.

## Build and test evidence

- `swift test --disable-sandbox` (after the audit follow-up): 292 main-module tests + 51 File Provider tests, 343 total, zero failures. One pre-existing assertion that encoded the incorrect `1 of 2 domains need attention` was corrected to `needs`.
- Unsigned Debug Xcode build using a temporary `BUILD_ROOT`/derived-data directory: succeeded, including both embedded extensions.
- Signed Debug build in a separate temporary directory: succeeded and used for main-application runtime checks.
- Native-resource check: 428 strings and ten plural entries validated in both languages; compiler extraction from 51 Swift compilation records covered (previous build).
- `git diff --check`: passed.

Finder's signed Debug extension was reloaded through System Settings. The running extension and daemon reported `nimbussyncLanguage = en` / `zh-Hans` for the same test item, and the visible Quick Actions were respectively `Check for Updates`, `Keep Downloaded`, `Open in NimbusSync` and `检查文件更新`, `保留下载`, `在 NimbusSync 中打开`. Neither menu exposed localization keys. No mutating action was invoked.

## Environment-dependent limits

Release distribution, notarization, the full macOS compatibility matrix and extended sync endurance remain outside this local localization increment. Signed Finder runtime evidence is recorded separately above.

Updating the system-selected workspace Dev artifact completed its Xcode build and passed deep bundle signature verification, but the build script's subsequent Sparkle Installer helper re-sign encountered a filesystem `Operation not permitted` restriction in that in-use directory. The original generated bundle was backed up before the attempt, the Dev integration switch was restored to enabled, and the separate temporary-directory signed build completed fully. This observation is not release/notarization evidence.
