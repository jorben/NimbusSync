# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-11-13
### :sparkles: New Features
- [`15a9e0f`](https://github.com/jorben/NimbusSync/commit/15a9e0f8e158f606acd67120ed8a0f79ec2dba37) - **macos**: ✨ Complete Phase 0-4 review hardening *(commit by [@jorben](https://github.com/jorben))*
- [`58e99a9`](https://github.com/jorben/NimbusSync/commit/58e99a9d525eb8181cb53253798638ee72e71729) - ✨ Add menu bar UI and single-instance window routing *(commit by [@jorben](https://github.com/jorben))*
- [`f4a3cdd`](https://github.com/jorben/NimbusSync/commit/f4a3cdd317862960e6319686c14dfa7c78a279ba) - ✨ Advance NimbusSync macOS parity implementation *(commit by [@jorben](https://github.com/jorben))*
- [`313688a`](https://github.com/jorben/NimbusSync/commit/313688a56de093e9479cd424fe5efd626c11a264) - **sync**: ✨完善 NimbusSync 文件同步能力 *(commit by [@jorben](https://github.com/jorben))*
- [`4872bc4`](https://github.com/jorben/NimbusSync/commit/4872bc44d5f4d55506d0fcac2bc91dfb00cb7a3b) - **observability**: ✨ Add a shared activity log *(commit by [@jorben](https://github.com/jorben))*
- [`fb281e4`](https://github.com/jorben/NimbusSync/commit/fb281e465d6beadba6836b7b71cef7110362ff4e) - **ui**: ✨ Animate the menu bar icon while syncing *(commit by [@jorben](https://github.com/jorben))*
- [`d542eb0`](https://github.com/jorben/NimbusSync/commit/d542eb00e3b225f275abbea007b84099133febbd) - **observability**: ✨ Read raw log lines across processes *(commit by [@jorben](https://github.com/jorben))*
- [`f5d2975`](https://github.com/jorben/NimbusSync/commit/f5d2975888153f73a631c2c44511028a6b144f69) - **sync**: ✨ Rework full checks with progress and connection status *(commit by [@jorben](https://github.com/jorben))*
- [`ceefaf5`](https://github.com/jorben/NimbusSync/commit/ceefaf5fc6cd857264f27584e00481992cff5368) - **ui**: ✨ Show when each task last changed *(commit by [@jorben](https://github.com/jorben))*
- [`7d169b6`](https://github.com/jorben/NimbusSync/commit/7d169b632c3d67f9f8981bf6ca30f847b06e2aeb) - **ui**: ✨ Add an app icon and redraw the menu bar glyph *(commit by [@jorben](https://github.com/jorben))*
- [`e7c0937`](https://github.com/jorben/NimbusSync/commit/e7c0937d785c6d2940167d01154c520fe7780a08) - **ui**: ✨ Redesign the menu bar popover *(commit by [@jorben](https://github.com/jorben))*
- [`c7dfe77`](https://github.com/jorben/NimbusSync/commit/c7dfe77b3748b7c3498d8d0c9b0c49f7a467269d) - **ui**: ✨ Redesign the Settings window *(commit by [@jorben](https://github.com/jorben))*
- [`6f67a14`](https://github.com/jorben/NimbusSync/commit/6f67a14112ee13ee69127d6166aebefddf2477d5) - **ui**: ✨ Restyle the General, Diagnostics and About pages *(commit by [@jorben](https://github.com/jorben))*
- [`f551b79`](https://github.com/jorben/NimbusSync/commit/f551b794ea5a645045992fc512b9fd68f0c9366b) - **ui**: ✨ Redesign the Add Domain window *(commit by [@jorben](https://github.com/jorben))*
- [`5b7f315`](https://github.com/jorben/NimbusSync/commit/5b7f31541c29debdaead7d276178b0e3ca36ed3f) - **tasks**: ✨ Clear and retry issues from the popover *(commit by [@jorben](https://github.com/jorben))*
- [`b63f0d9`](https://github.com/jorben/NimbusSync/commit/b63f0d9cd1a5bdadfb26b3358762285613b65be9) - **ui**: ✨ Double the menu bar icon stroke weight *(commit by [@jorben](https://github.com/jorben))*
- [`7735420`](https://github.com/jorben/NimbusSync/commit/7735420517a7c30c4ac576f51aea3bc8b95a86ba) - **domains**: ✨ add domain renaming *(commit by [@jorben](https://github.com/jorben))*
- [`13b8e65`](https://github.com/jorben/NimbusSync/commit/13b8e65cc20eaaf6444bf65c4d33dda3b4867684) - **observability**: ✨ Log unmanaged domains at startup *(commit by [@jorben](https://github.com/jorben))*
- [`51feed0`](https://github.com/jorben/NimbusSync/commit/51feed0f470a2606f9e34a4d45efd654addb4531) - **menubar**: ✨ Add Dock icon toggle and AppKit menu bar panel *(commit by [@jorben](https://github.com/jorben))*
- [`4b3ebc9`](https://github.com/jorben/NimbusSync/commit/4b3ebc906b1b9866523af3d817afc7e918b76d42) - **observability**: ✨ Add a log level setting and stale-deletion diagnostics *(commit by [@jorben](https://github.com/jorben))*
- [`c958b4b`](https://github.com/jorben/NimbusSync/commit/c958b4b8ed4b6411a010d6f40ea1ac35984bb766) - **menubar**: ✨ Show sync state in the menu bar icon *(commit by [@jorben](https://github.com/jorben))*
- [`a24a6da`](https://github.com/jorben/NimbusSync/commit/a24a6dab72b45c5eb08148a866025016df677bfd) - **ui**: ✨ Follow the app theme for the in-app icon *(commit by [@jorben](https://github.com/jorben))*
- [`f55bd62`](https://github.com/jorben/NimbusSync/commit/f55bd62a856b1daed4c8178eeadab1425896acb2) - **config**: ✨ Move to io.github.jorben and add coexisting Dev identity *(commit by [@jorben](https://github.com/jorben))*
- [`3f5c782`](https://github.com/jorben/NimbusSync/commit/3f5c7824cde42028714f4316bcae6e7b7f6a9cd1) - **identity**: ✨ Name the Dev build NimbusSyncDev everywhere *(commit by [@jorben](https://github.com/jorben))*
- [`a31ebca`](https://github.com/jorben/NimbusSync/commit/a31ebca8359443dd9789a2e156cec022ce570627) - **ui**: ✨ Show why syncing paused when Finder integration is off *(commit by [@jorben](https://github.com/jorben))*
- [`a1cf625`](https://github.com/jorben/NimbusSync/commit/a1cf62597f4738c62cf81cf021d7a68dfdaf4334) - **version**: ✨ Show the release tag version in the app *(commit by [@jorben](https://github.com/jorben))*
- [`56d5371`](https://github.com/jorben/NimbusSync/commit/56d5371b3d127ef749f546bd80a274d00772ebc3) - **update**: ✨ Add in-app updates with Sparkle *(commit by [@jorben](https://github.com/jorben))*

### :bug: Bug Fixes
- [`8effc4d`](https://github.com/jorben/NimbusSync/commit/8effc4de53dec485ccd6fb879ef2c9c00cb9eecb) - 🐛 Harden Finder opening and notification authorization *(commit by [@jorben](https://github.com/jorben))*
- [`672c388`](https://github.com/jorben/NimbusSync/commit/672c3883674d0c09263f1de4782f61f457159ddc) - 🐛 Improve Finder opening and File Provider extension support *(commit by [@jorben](https://github.com/jorben))*
- [`e020137`](https://github.com/jorben/NimbusSync/commit/e020137b94cc4fee50536610435e18409c05d496) - 🐛 Improve File Provider recovery and shared Keychain access *(commit by [@jorben](https://github.com/jorben))*
- [`9faee56`](https://github.com/jorben/NimbusSync/commit/9faee560206791539699d5656b6b75634a1762d3) - **file-provider**: 🐛 Remove orphaned File Provider domains at launch *(commit by [@jorben](https://github.com/jorben))*
- [`ea3342f`](https://github.com/jorben/NimbusSync/commit/ea3342fab4f65bf7315f99cab79de5672d23b9d3) - **sync**: 🐛 Harden Cloudreve sync against review findings *(commit by [@jorben](https://github.com/jorben))*
- [`1e40ae8`](https://github.com/jorben/NimbusSync/commit/1e40ae85f2b32e560e8eade36263e8b0d51c2457) - **sse**: 🐛 Dispatch live updates at the blank line ending each event *(commit by [@jorben](https://github.com/jorben))*
- [`6c9ecaa`](https://github.com/jorben/NimbusSync/commit/6c9ecaa4f4261e8c063d74cdb243187a986a0c4d) - **sync**: 🐛 Recover interrupted full checks and keep their position *(commit by [@jorben](https://github.com/jorben))*
- [`6667788`](https://github.com/jorben/NimbusSync/commit/666778888f6babe4dd4e072aded811baf7211191) - **ui**: 🐛 Keep status badges on a single line *(commit by [@jorben](https://github.com/jorben))*
- [`005b1e6`](https://github.com/jorben/NimbusSync/commit/005b1e6622d0d5f514298e7699ad67064e6c2eed) - **ui**: 🐛 Blend popover surfaces into the translucent panel *(commit by [@jorben](https://github.com/jorben))*
- [`c519a08`](https://github.com/jorben/NimbusSync/commit/c519a08b5138817150a22f7b759a088feb7b7a8b) - **sse**: 🐛 Stop logging applied live changes as skipped *(commit by [@jorben](https://github.com/jorben))*
- [`fa8894d`](https://github.com/jorben/NimbusSync/commit/fa8894d8ac50f9b5bf54752dda769bc789559160) - **tasks**: 🐛 Hide superseded download failures and dead retries *(commit by [@jorben](https://github.com/jorben))*
- [`a5be019`](https://github.com/jorben/NimbusSync/commit/a5be0195fc601238470c79b266af76035db71349) - **fileprovider**: 🐛 Reuse identities recorded during a listing *(commit by [@jorben](https://github.com/jorben))*
- [`e05a90e`](https://github.com/jorben/NimbusSync/commit/e05a90e974747fabfcc0c71c6326ad84a2abb96e) - **fileprovider**: 🐛 Remove stale items whose remote object changed *(commit by [@jorben](https://github.com/jorben))*
- [`6c0fafe`](https://github.com/jorben/NimbusSync/commit/6c0fafe7fa870ca64c346d76f0798f1f7f7995f7) - **ui**: 🐛 Label the domain check as a full check *(commit by [@jorben](https://github.com/jorben))*
- [`69c6930`](https://github.com/jorben/NimbusSync/commit/69c693047d166fb112580b04f09006eb01413c65) - **store**: 🐛 Migrate populated tables with timestamp defaults *(commit by [@jorben](https://github.com/jorben))*
- [`2d98d7e`](https://github.com/jorben/NimbusSync/commit/2d98d7e41070e8f013d5140e22bacd7c8538f011) - **build**: 🐛 Fail closed when build scans cannot run *(commit by [@jorben](https://github.com/jorben))*
- [`4855bfa`](https://github.com/jorben/NimbusSync/commit/4855bfabc3829dfc83029a504d96c6f027b1b62d) - **sync**: 🐛 harden reconcile, replay and upload sessions *(commit by [@jorben](https://github.com/jorben))*
- [`8603cbe`](https://github.com/jorben/NimbusSync/commit/8603cbe64e4129ac4036dcb1649dbce4230b6233) - **fileprovider**: 🐛 avoid duplicate creates on lost replays *(commit by [@jorben](https://github.com/jorben))*
- [`497fc41`](https://github.com/jorben/NimbusSync/commit/497fc41a9c1af182d57ef96aaf77611cfe7a5913) - **events**: 🐛 keep retired runtimes from overwriting domain status *(commit by [@jorben](https://github.com/jorben))*
- [`09f2332`](https://github.com/jorben/NimbusSync/commit/09f23325913e22c9076e88e7395a8e61da24adf4) - **logging**: 🐛 log expected stream stops and anchor expiry as info *(commit by [@jorben](https://github.com/jorben))*
- [`319552c`](https://github.com/jorben/NimbusSync/commit/319552c297d8f303c4cc53a2234e8372a890c6a7) - **events**: 🐛 ignore failed checks on retired runtimes *(commit by [@jorben](https://github.com/jorben))*
- [`22c5e42`](https://github.com/jorben/NimbusSync/commit/22c5e425f21ee50a08ce779357cdc5ead23fccfd) - **domains**: 🐛 harden rename rollback and action locking *(commit by [@jorben](https://github.com/jorben))*
- [`0f11899`](https://github.com/jorben/NimbusSync/commit/0f1189967d690b67444f138d9b85ddf2276515a2) - **fileprovider**: 🐛 keep remote evidence across create replays *(commit by [@jorben](https://github.com/jorben))*
- [`809cc25`](https://github.com/jorben/NimbusSync/commit/809cc254bd019fc0bb8541a7f6e91d864b886f01) - **logging**: 🐛 log only genuine anchor expiry as info *(commit by [@jorben](https://github.com/jorben))*
- [`083dac8`](https://github.com/jorben/NimbusSync/commit/083dac8f7e0ee5ae43ff6bc1b3f3821d88854e42) - **observability**: 🐛 Keep inventory failures visible in activity log *(commit by [@jorben](https://github.com/jorben))*
- [`526a20c`](https://github.com/jorben/NimbusSync/commit/526a20c06137ec75a08877a2306e452d3a3d2305) - **fileprovider**: 🐛 Announce stale download deletions to the working set *(commit by [@jorben](https://github.com/jorben))*
- [`d4e4dd2`](https://github.com/jorben/NimbusSync/commit/d4e4dd2cd07e1cfe8135b106e88bf1efe5e1c114) - **events**: 🐛 Accept event paths relative to the domain root *(commit by [@jorben](https://github.com/jorben))*
- [`deabf54`](https://github.com/jorben/NimbusSync/commit/deabf541ef2236e8c23c3000c8e75d542a988a87) - **fileprovider**: 🐛 Verify remote identity before deleting or trashing by path *(commit by [@jorben](https://github.com/jorben))*
- [`74d3e40`](https://github.com/jorben/NimbusSync/commit/74d3e408a3172d6c452ccc0045476ca0a47aeb87) - **fileprovider**: 🐛 Stop serving deleted items to the system *(commit by [@jorben](https://github.com/jorben))*
- [`a1d453a`](https://github.com/jorben/NimbusSync/commit/a1d453a01edc7ef56f97f41e4d68a8902fe9669f) - **menubar**: 🐛 Defer panel resize until rendering finishes *(commit by [@jorben](https://github.com/jorben))*
- [`790a959`](https://github.com/jorben/NimbusSync/commit/790a959018cb4eeea1ba4b9fbf66712e78589d25) - **fileprovider**: 🐛 Distinguish repeated renames and moves in replay keys *(commit by [@jorben](https://github.com/jorben))*
- [`0eb4771`](https://github.com/jorben/NimbusSync/commit/0eb4771175359fca397d56f94b6966471d1678f8) - **activity**: 🐛 Clear stale failures once an item is gone *(commit by [@jorben](https://github.com/jorben))*
- [`9e3e26d`](https://github.com/jorben/NimbusSync/commit/9e3e26d1ce16f054ff1f2989e6d94a7f997065be) - **auth**: 🐛 Treat only rejected refresh tokens as sign-in failures *(commit by [@jorben](https://github.com/jorben))*
- [`284bcac`](https://github.com/jorben/NimbusSync/commit/284bcac999bc7f4e1e036254e9d426222a2d1527) - **fileprovider**: 🐛 Guard trashed deletes and stale renames or moves *(commit by [@jorben](https://github.com/jorben))*
- [`c7d2eb8`](https://github.com/jorben/NimbusSync/commit/c7d2eb89feadd02742147f9317e9c6f3484ab664) - **reconcile**: 🐛 Keep live changes and map server-trashed items *(commit by [@jorben](https://github.com/jorben))*
- [`1ad62ea`](https://github.com/jorben/NimbusSync/commit/1ad62eac7d249fa0a6b42220f23f7a38d448de23) - **store**: 🐛 Make multi-statement store writes atomic *(commit by [@jorben](https://github.com/jorben))*
- [`984c79c`](https://github.com/jorben/NimbusSync/commit/984c79c58b2a7e92d5e7feb947a67397417b0435) - **app**: 🐛 Show reauthorize and conflict errors in their own windows *(commit by [@jorben](https://github.com/jorben))*
- [`949f0b7`](https://github.com/jorben/NimbusSync/commit/949f0b7624ec090cbe63beb9c01c8a3960d55b88) - **config**: 🐛 Make Release signing notarizable *(commit by [@jorben](https://github.com/jorben))*
- [`8ef1f86`](https://github.com/jorben/NimbusSync/commit/8ef1f86c49f077b68589e446e0b864a94c3333fd) - **app**: 🐛 Refresh Finder integration state on File Provider domain changes *(commit by [@jorben](https://github.com/jorben))*
- [`9e007ed`](https://github.com/jorben/NimbusSync/commit/9e007ede34024cb8eb6f34aa6bffcee28d4fb5da) - **settings**: 🐛 Open Settings window on macOS 14 from menu bar *(commit by [@jorben](https://github.com/jorben))*
- [`69fc291`](https://github.com/jorben/NimbusSync/commit/69fc291d0780257148f8307319bef74ffe6c9ddf) - **release**: 🐛 Check the ZIP checksum without its build path *(commit by [@jorben](https://github.com/jorben))*
- [`04ce1d9`](https://github.com/jorben/NimbusSync/commit/04ce1d949d7840bc21f7992bb30938dcb0f30c13) - **build**: 🐛 Embed the Frameworks runpath so Sparkle loads at launch *(commit by [@jorben](https://github.com/jorben))*

### :recycle: Refactors
- [`ea55a4d`](https://github.com/jorben/NimbusSync/commit/ea55a4da7cd6ee8db31d2a7ce13ea5b389a49dec) - 🔧 streamline NimbusSync architecture and interfaces
- [`0f5ca7b`](https://github.com/jorben/NimbusSync/commit/0f5ca7b2cc5fd1cd75bc45c8c10f00ad25a35194) - 🧹 Remove obsolete sync implementation *(commit by [@jorben](https://github.com/jorben))*
- [`421e6ee`](https://github.com/jorben/NimbusSync/commit/421e6ee4bc606783d92954fe7dc1ba09fc2edc94) - ♻️ Remove the Rust workspace *(commit by [@jorben](https://github.com/jorben))*
- [`0be7785`](https://github.com/jorben/NimbusSync/commit/0be77856c821d9a5bdb7e9979ece06b5bcc6ff8d) - **ui**: ♻️ Drop the recent log from the menu bar popover *(commit by [@jorben](https://github.com/jorben))*

### :wrench: Chores
- [`8776778`](https://github.com/jorben/NimbusSync/commit/87767784c3b45fef78900efcea586a870c3e64eb) - 🔧 Remove obsolete files
- [`c413e0e`](https://github.com/jorben/NimbusSync/commit/c413e0e42eba656fc35b7b4d10a4801d62d15ff6) - 🔧 Add macOS project ignore rules
- [`30d656e`](https://github.com/jorben/NimbusSync/commit/30d656ee3734398bcc1ecb57274da0626c39139c) - 🧹 Remove macOS metadata file
- [`47b95af`](https://github.com/jorben/NimbusSync/commit/47b95afdb343baf4bb1232f4f1d25e92461f562a) - **ci**: 🔧 Unify local CI checks and configure release signing *(commit by [@jorben](https://github.com/jorben))*
- [`5d80af6`](https://github.com/jorben/NimbusSync/commit/5d80af61982b2ca17af3e825fb4474c77a1214a6) - 🔧 migrate NimbusSync identifiers and signing defaults *(commit by [@jorben](https://github.com/jorben))*
- [`dff2653`](https://github.com/jorben/NimbusSync/commit/dff265323271a4455643b7c5c21f00f76ac5c91d) - 🔧 move local build config out of repository *(commit by [@jorben](https://github.com/jorben))*
- [`b6ae339`](https://github.com/jorben/NimbusSync/commit/b6ae339f73a0ada4860f3a4ea0b285fb8cf9a71a) - 🧹 remove stale entitlement and archive phase reports *(commit by [@jorben](https://github.com/jorben))*
- [`3520fcf`](https://github.com/jorben/NimbusSync/commit/3520fcfaa6db338d99772b4dd409f7e4b2a20101) - 🔧 update NimbusSync project *(commit by [@jorben](https://github.com/jorben))*
- [`5ae3402`](https://github.com/jorben/NimbusSync/commit/5ae34023b0cc56eca9777fb5b8fac6f7992659ec) - 🔧 Ignore .pi/ agent dir and remove stray file *(commit by [@jorben](https://github.com/jorben))*
- [`a969ff6`](https://github.com/jorben/NimbusSync/commit/a969ff6ed7267e2c28e3f249dd629bfa1e07afbd) - **make**: 🔧 Wait for the old app to exit before relaunch *(commit by [@jorben](https://github.com/jorben))*
- [`a9d2578`](https://github.com/jorben/NimbusSync/commit/a9d2578a4bbfc689c1ca3f24ae5dfbc86c2fb6d4) - **build**: 🔧 harden release build and evidence scans *(commit by [@jorben](https://github.com/jorben))*
- [`f50a633`](https://github.com/jorben/NimbusSync/commit/f50a633ebadb93d1158cd693e355034dcf301ebe) - **assets**: 🔧 Update app icon artwork *(commit by [@jorben](https://github.com/jorben))*
- [`b9d7e4c`](https://github.com/jorben/NimbusSync/commit/b9d7e4c4fb482a0754ce9f18ba44287f21de7f35) - **assets**: 🔧 Update app icon artwork *(commit by [@jorben](https://github.com/jorben))*
- [`9f3c6ff`](https://github.com/jorben/NimbusSync/commit/9f3c6ff3d1846dcefbeccce97c72a045d461e79e) - **assets**: 🔧 Add a light-mode app icon variant *(commit by [@jorben](https://github.com/jorben))*
- [`9d52f9c`](https://github.com/jorben/NimbusSync/commit/9d52f9ccb3879ca215cd3437b3b01482d7f08f95) - 🔧 Point repository links to jorben/NimbusSync *(commit by [@jorben](https://github.com/jorben))*

[0.1.1]: https://github.com/jorben/NimbusSync/compare/0.0.1...0.1.1
