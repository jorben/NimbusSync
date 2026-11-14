# NimbusSync localization

## Scope and resource ownership

NimbusSync supports English (`en`) and Simplified Chinese (`zh-Hans`). User content, opaque identifiers, protocol values, server response text and diagnostic log bodies are not translated.

| Surface | Source | Localization responsibility |
| --- | --- | --- |
| Settings, Dock menus, application windows and alerts | `Apps/NimbusSync/NimbusSyncApp.swift` | Titles, actions, explanations, error presentation and language selection |
| Updates and update notifications | `Apps/NimbusSync/AppUpdater.swift` | NimbusSync-owned copy; Sparkle retains its own localization |
| Menu bar, domain cards, onboarding and Finder guide | `Packages/NimbusSyncDesignSystem/Sources/` | Visible copy, accessibility labels, tooltips, counts and formatting |
| Conflict center, exclusions and product notifications | `Packages/NimbusSyncProductKit/Sources/` | UI text; persisted task/conflict values remain stable |
| Authorization and domain lifecycle errors | AuthKit and DomainKit | Localized user descriptions; diagnostic descriptions remain stable |
| File Provider UI | `Extensions/NimbusSyncFileProviderUI/` | Opening-item message and declared Finder actions |
| Finder actions and badges | `Config/NimbusSyncFileProvider*-Info.plist` and extension resources | System-loaded titles/labels; verify independently in a signed Finder session |

Shared text resources and language resolution live in DomainKit, which is reachable from both UI packages and the File Provider stack. Native `.lproj/Localizable.strings` and `.stringsdict` resources support both SwiftPM and Xcode builds. Xcode references the same files in the application and both extension bundles, including system-loaded Finder action labels. ProductKit's public copy entry point delegates to the shared service.

There are currently 428 shared strings and ten plural entries. Edit the Simplified Chinese table's English source keys and Chinese values, then run `python3 Scripts/check-localization.py --generate-english` to regenerate the identity English table. Plural entries are authored in both native `.stringsdict` files. Keys under `finder.action.` are explicit language display aliases and retain the same literal value in both bundles, so Finder's host language cannot override the selected item language. `python3 Scripts/check-localization.py --build-root <derived-data-path>` additionally checks compiler-extracted keys from `.stringsdata` records; the application build enables `SWIFT_EMIT_LOC_STRINGS` for this check.

## Language behavior

The preference offers System, English and 简体中文. The default uses Apple's preferred-localization matching against `en` and `zh-Hans`, with English as the development fallback. Language preference storage uses the build's App Group, preserving Debug/Release isolation. Regional formatting preferences remain independent of the UI language.

The main application observes language changes and updates existing SwiftUI views without replacing their identity, preserving in-progress forms, selection and scroll state. Native picker options use stable localization keys, allowing the locale environment to refresh cached segmented controls and menu labels. Errors retain their original error values and resolve presentation text when displayed, so an existing error banner can change language.

AppKit window titles and status item text also refresh. Application commands supply resolved verbatim labels through SwiftUI command groups, while the standard menu headers are updated in AppKit. New notifications use the current language; already delivered notifications remain unchanged.

For isolated previews or tests, `L10n.$languageOverride.withValue(...)` selects a language within the current task scope without writing application preferences. Normal app and extension execution reads the shared persisted preference.

Extensions read the persisted preference themselves. System-managed extension processes and Finder's cached bundle metadata require separate runtime verification; the application must not terminate them to force a language refresh.

Finder actions use `NSExtensionFileProviderActionIdentifier`, `NSExtensionFileProviderActionName`, and `NSExtensionFileProviderActionActivationRule` in their manifests, as specified by [Apple's context-menu documentation](https://developer.apple.com/documentation/fileproviderui/adding-actions-to-the-context-menu). The UI extension point is `com.apple.fileprovider-actionsui`. The original six action identifiers remain canonical. Chinese display aliases append `.zh-Hans` and are accepted only through an exact canonical allowlist; the existing operation handlers still receive the canonical identifier. Activation rules select aliases using the item's stable `nimbussyncLanguage` code. Decoration identifiers stay unchanged and their format arguments read localized labels from item userInfo.

Projection schema revision 5 adds language-aware presentation metadata without changing content versions, capabilities, file names or transfer policy. On language selection the main app requests a bounded metadata refresh, allowing an already-running extension to update Finder's cached item labels. On extension startup the same persistent working-set refresh worker compares the last successfully signalled language with the shared preference. It records the new language only after the system accepts the signal; failures and a switch back to the previous language retain and drain the durable refresh job.

## Verification

`sh Scripts/LocalizationPreview/run.sh [output-dir]` launches an isolated preview of the shared screens for layout checks in both languages; it never touches installed editions or their data.

Run `swift test --disable-sandbox`, an unsigned Debug Xcode build using a temporary `BUILD_ROOT`, and `git diff --check`. Resource tests must check both languages, interpolation and plural handling. Runtime evidence must cover System, English, 简体中文, existing windows, saved preferences after relaunch, and Finder extension behavior after reloading. Record runtime results separately from compilation and unit-test results.
