# Product website deployment evidence

The NimbusSync product website was implemented in commit `7f27ec8` and deployed through
[Deploy Website run 43658453561](https://github.com/jorben/NimbusSync/actions/runs/43658453561).
The run completed successfully. GitHub Pages now uses `build_type: workflow`.

- Chinese: <https://jorben.github.io/NimbusSync/>
- English: <https://jorben.github.io/NimbusSync/?lang=en>
- Sparkle feed: <https://jorben.github.io/NimbusSync/appcast.xml>

## Verified evidence

- `python3 -m unittest discover -s website -p 'test_*.py' -v`: all four tests passed.
  These cover exact feed/signature copying, rejection of missing or malformed feeds, protection
  of existing/source directories, and local links/assets in the assembled artifact.
- `node --check website/script.js`: passed.
- `actionlint .github/workflows/deploy-website.yml .github/workflows/publish-appcast.yml`: passed.
- `git diff --check`: passed.
- Browser checks at 320, 390, 768, and 1440 CSS pixels in both languages: no horizontal overflow
  or broken loaded images. FAQ expansion, language switching in both directions, localized
  screenshot selection, and a visible keyboard focus outline were verified.
- With JavaScript disabled, the Chinese content, native FAQ controls, and latest-release download
  link remain available. The unavailable language switch stays hidden.
- The public homepage, stylesheet, script, app icon, and both localized screenshots returned HTTP 200.
- Live browser verification confirmed the English heading/title, `?lang=en`, English screenshot,
  latest-release download URL, and no horizontal overflow.
- The public appcast matched the current `gh-pages/appcast.xml` byte for byte: 59,422 bytes,
  SHA-256 `d1c2c5f407a3b5c87abcf474bfc3646390fa261a2d59f5e3fd11c634c64f29af`.
  This digest records the feed at verification time; future application releases will change it.

## Screenshots

Captured from the deployed website:

- [Desktop, Chinese, 1440 × 1000](desktop-zh.png)
- [Mobile, English, 390 × 844](mobile-en.png)

## Scope limits

The website deployment and existing feed delivery were verified. A future release-triggered
`Publish Appcast` → `Deploy Website` run and the installed application's Sparkle update/install
flow were not exercised by this website task. No Swift app or File Provider behavior changed.
