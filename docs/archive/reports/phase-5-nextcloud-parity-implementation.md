# NimbusSync File Provider parity implementation report

日期：2026-09-05  
基线：feat/macos-parity 当前工作树  
方案：[08-file-provider-nextcloud-parity-implementation.md](../../08-file-provider-nextcloud-parity-implementation.md)

## 实施结果

| 阶段 | 本地实现结果 | 本地证据 |
|---|---|---|
| A Store、版本、接口基础 | schema v7、v6→v7 fence/epoch/signal、immutable journal payload、anchor/page v2 checksum、Swift/Rust manifest、async/task/capability contracts；补齐真实 v6 列类型迁移和读侧 process fence | testV6ToV7MigrationPreservesDirtyWorkAndCreatesFreshSignal、testV6ShapeMigrationKeepsItemColumnTypes、testSwiftSchemaManifestIsV7AndHasNoDuplicateTables、Rust store/protocol tests |
| B Enumerator 与 journal delivery | working-set keyset、directory snapshot generation/TTL、旧 snapshot TTL 续页、未完成 hydration 持久 cursor、trash keyset、bounded replay、immutable payload、fold/sort、批量事件统一 visibility path、冷目录 snapshot exclusion filter、view-state 变化时 snapshot 失效 | testV7JournalPayloadIsImmutableAcrossLiveRowUpdates、testDirectorySnapshotPublishesOnlyAfterCompleteGeneration、testDirectorySnapshotReadFiltersExcludedItem、testJournalFoldOrdersParentsBeforeChildrenAndDeletesLast、testBatchJournalCommitUsesExclusionAndViewRemovalSemantics、testBatchProviderChangeDeduplicationIncludesViewState |
| C system-set 与 projection | materialized/pending staging、partial/capped 保留、owner/generation/domain-version fencing、item local state、child-count、pin/evict projection、认证状态与 action 投影隔离 | testMaterializedPartialGenerationDoesNotClearPreviousFact、testSystemSetClaimsFenceConcurrentOwners、testSystemSetClaimFencesChangedDomainVersion、testProjectionPreservesMaterializationPinAndChildCountUnknown |
| D async transfer 与 conflict | suspended/register/resume task transport（目录、Trash、内容及 mutation）、Progress/cancellation、streaming download/upload、chunk checkpoint/source replay、conditional capability gate、zero-byte gate、conflict source validation/export、resolution journal、operation base/fields evidence、download/delete task state、safe transfer compaction；Cloudreve Remote/Qiniu/Upyun wire adapter | testSourceFingerprintIsStreamingAndRejectsMismatchedConflictSource、testAwaitingSourceReplayRemainsActiveOperation、testCreateSourceReplayMismatchDoesNotStartSecondRemoteWrite、testTransferCompactionRetainsRecoverableSessionUntilCommit、testConflictResolutionCommitsProviderChangeForOverwrite、RemoteProviderWireTests（Remote/Qiniu/Upyun URLProtocol）；真实 Cloudreve matrix 尚未运行 |
| E parent/trash/exclusion/actions | bounded ParentResolver 接入 backend、目录 rename/move descendant refresh、trash/restore/purge gates、intent+version/path protection、统一 exclusion matcher、Settings 排除规则入口、tri-state keep policy、non-UI eviction/actions、opaque UI routes | testParentResolverFailsClosedAcrossScopeAndDepth、testExclusionViewFilterIsAtomicAndNeverDeletesRemoteItem、testExclusionViewRestorationClearsHiddenState、Info.plist/entitlement scan；signed Finder 尚未运行 |
| F refresh/release | projection-schema refresh job、journal-first refresh、contentVersion 不变、special-file policy、静态安全 gate、读写 process fence、统一 Xcode/build script、local Store p50/p95/p99 benchmark、external evidence validator | 102 Swift tests、swift build -c debug/release、Xcode unsigned build、Scripts/build.sh、28 Rust tests、cargo fmt/clippy、git diff --check；100,000 item 本地 Store benchmark 通过 |

## FP 需求追踪

表内 Swift 用例分别位于 [主测试套件](../../../Tests/SwiftUnitTests/NimbusSyncTests.swift)、[File Provider 专项测试](../../../Tests/FileProviderUnitTests/FileProviderParityTests.swift) 和 [Provider wire 测试](../../../Tests/FileProviderUnitTests/RemoteProviderWireTests.swift)；Rust 不变量位于各 crate 的 `#[cfg(test)]` 模块，命令与结果见下方“已执行命令”。

| 需求 ID | 实现与源码 | 本地测试/证据 | 仍需外部能力门禁 |
|---|---|---|---|
| FP-001 | `FileProviderContainerKind`、`WorkingSetEnumerator`、`DirectoryEnumerator`、`TrashEnumerator`；[FileProviderKit](../../../Packages/NimbusSyncFileProviderKit/Sources/NimbusSyncFileProviderKit.swift) | `testWorkingSetEnumeratorUsesOpaqueKeysetCursor`、`testDirectorySnapshotPublishesOnlyAfterCompleteGeneration`、`testDirectorySnapshotReadFiltersExcludedItem` | `stable_root_identity`、`complete_pagination`、`snapshot_safe_pagination`、`trash_restore`、signed Finder |
| FP-002 | immutable journal payload、bounded sequence replay、[JournalChangeFold](../../../Packages/NimbusSyncStoreBridge/Sources/JournalFold.swift) | `testV7JournalPayloadIsImmutableAcrossLiveRowUpdates`、`testJournalFoldOrdersParentsBeforeChildrenAndDeletesLast`、`testRecursiveTombstonePublishesChildrenBeforeParent` | signed Finder callback kill/replay |
| FP-003 | `SyncAnchor`/`PageToken` v2、epoch/checksum/process fence | `testAnchorCorruptionAndCompactionFailClosedAsExpired`、`testPageTokenValidationRejectsCrossContainerShapeAsCannotSynchronize`、`testV6ToV7MigrationPreservesDirtyWorkAndCreatesFreshSignal` | signed Finder anchor expiry/restart |
| FP-004 | [SystemSetCoordinator](../../../Packages/NimbusSyncFileProviderKit/Sources/SystemSetCoordinator.swift)、generation/owner/domain-version fencing | `testMaterializedPartialGenerationDoesNotClearPreviousFact`、`testSystemSetClaimsFenceConcurrentOwners`、`testSystemSetClaimFencesChangedDomainVersion` | signed Finder materialized/pending/eviction |
| FP-005 | `NimbusSyncFileProviderItem` projection、local state、[SpecialFilePolicy](../../../Packages/NimbusSyncFileProviderKit/Sources/SpecialFilePolicy.swift) | `testProjectionPreservesMaterializationPinAndChildCountUnknown`、`testProjectionDoesNotMarkPendingUploadAsUploaded`、`testSpecialSymlinkPolicyFailsClosed` | signed Finder item fidelity and special-file matrix |
| FP-006 | [AsyncFileProviderBackend](../../../Packages/NimbusSyncFileProviderKit/Sources/AsyncFileProviderBackend.swift)、suspended/register/resume、stream/checkpoint/cancellation | `testURLSessionTaskRegistrationRequiresSuspendedTaskBeforeResume`、source fingerprint/replay tests | signed Provider upload/download、large-file RSS and task registration |
| FP-007 | async conditional write gate、conflict source validation/resolution、native conflict hard-off | `testCapabilityWriteRequiresVerifiedRecoveryAndZeroByteSupport`、`testAsyncConflictReplayCompletesConflictAfterCommittedOutcome`、`testCreateSourceReplayMismatchDoesNotStartSecondRemoteWrite` | `conditional_content_write`、`idempotent_create`、`native_conflict_copy`、真实 Cloudreve |
| FP-008 | [ParentResolver](../../../Packages/NimbusSyncFileProviderKit/Sources/ParentResolver.swift)、descendant URI refresh | `testParentResolverFailsClosedAcrossScopeAndDepth`、journal parent/child ordering tests | signed Finder move/root identity |
| FP-009 | trash/restore/purge capability gate、stable original parent、idempotent purge | `testTrashRestoreRetainsOriginalParent`、recursive tombstone tests | `trash_restore`、`delete_semantics`、真实 Cloudreve |
| FP-010 | exclusion matcher、view journal、one-shot exclusion intent、Settings rule path | `testExclusionViewFilterIsAtomicAndNeverDeletesRemoteItem`、`testExclusionIntentConsumptionRequiresRevisionAndGeneration`、`testExclusionViewRestorationClearsHiddenState` | signed Finder cleanup callback |
| FP-011 | tri-state keep policy、non-UI evict/keep actions、opaque UI routes | `testProjectionUsesInheritedKeepPolicyAndRefreshesMetadataBoundary`、`testExclusionRuleValidationAndDeepLinksAreOpaque` | signed Finder action/eviction behavior |
| FP-012 | [FrameworkCacheRefreshCoordinator](../../../Packages/NimbusSyncFileProviderKit/Sources/FrameworkCacheRefreshCoordinator.swift)、journal-first bounded refresh | `testProjectionRefreshFailureRetainsResumableCursor`、`testProjectionRefreshPageCommitsJournalAndCursorTogether` | signed Finder cache refresh、`performance`、100,000-item and long-run evidence |

补充测试：testWorkingSetEnumeratorUsesOpaqueKeysetCursor、testURLSessionTaskRegistrationRequiresSuspendedTaskBeforeResume、
testExclusionViewFilterIsAtomicAndNeverDeletesRemoteItem、testV6ToV7MigrationPreservesDirtyWorkAndCreatesFreshSignal，
testRecursiveTombstonePublishesChildrenBeforeParent、testAsyncConflictReplayCompletesConflictAfterCommittedOutcome、
testProjectionRefreshFailureRetainsResumableCursor、testAwaitingSourceReplayRemainsActiveOperation、
testCreateSourceReplayMismatchDoesNotStartSecondRemoteWrite、testDirectorySnapshotReadFiltersExcludedItem、
testBatchProviderChangeDeduplicationIncludesViewState、testTransferCompactionRetainsRecoverableSessionUntilCommit、
testProjectionRefreshPageCommitsJournalAndCursorTogether、testProjectionRefreshDoesNotAdvanceAppliedRevisionBeforeSignalSucceeds、
testStaleStoreCannotWriteAfterAnotherProcessPublishesGeneration，
testMissingPrimaryEntityKeepsContentVersionStableAndDisablesContentWrite，
testContinuationRejectsFutureAnchorAndUnboundDirectoryGeneration，
testWorkingSetReplayUsesJournalAudienceAfterEviction、testWorkingSetPageRejectsRevisionChangeInsteadOfSilentlySkipping，
testRootScopeFiltersPriorCanonicalItemsWithoutRemoteDeletion，
以及 Swift/Rust 共享 schema-manifest parity 检查；Rust 新增
`missing_primary_entity_is_not_treated_as_a_content_version` 和
`complete_provider_matrix_is_required_before_write_is_allowed`；
Swift 当前共 102 项测试通过（主套件 87，File Provider 专项 15，其中 Provider wire 4）。

## 变更重点

- SQLiteStateStore 是唯一生产 migration owner，schema revision 为 7；旧 journal 没有完整 payload 时只清理不可重放的 delivery cache，不重建历史，不删除 dirty operation/item。
- SyncAnchor/PageToken 使用版本、scope、projection revision、checksum 和 bounded fields；anchor 失败映射为 .syncAnchorExpired，migration/process fence 保持 .cannotSynchronize。
- 系统 materialized/pending 观察使用 generation、claimed owner、advisory lock 和原子 publish；不完整、失败或 capped 扫描不清除上一代事实。
- Cloudreve writes 逐 operation 由能力矩阵门禁；未验证 conditional/content/trash/purge/move 不会被异步路径开放。CapabilitySnapshot 现在显式保存 complete/cursor/snapshot-safe 分页、内容版本、Provider 恢复/完成/零字节、删除、refresh 和 thumbnail 证据，旧快照缺字段时保持 fail-closed。
- working-set journal 在 commit 时固化 delivery audience；working-set page token 同时绑定 membership revision，状态变化时拒绝旧 token，避免 keyset 分页静默漏项。
- 所有本地排除都使用一次性 intent，并绑定版本、路径 hash、rule revision、source generation 和 expiry；intent 不会调用远端 delete。
- 异步目录/Trash 枚举与内容/ mutation 共用 suspended/register/resume task 合同；未完成目录 hydration 保留 durable cursor，不把 live page 作为已发布 snapshot。
- 条件写冲突不伪造服务端版本；tombstone 后同一远端实体重现时复用原 opaque item ID；冲突解决结果与 conflict copy 均写入 provider journal/outbox。
- system-set claim 同时绑定 generation 与 domain-version；root/epoch 改变会 fence 旧 owner。排除 matcher 已统一到 DomainKit，且 Settings 已接入 per-Domain 规则编辑。

## 已执行命令

~~~text
swift test --disable-sandbox                         # 102 passed (87 + 15; Provider wire 4)
swift build -c debug --disable-sandbox                # passed
swift build -c release --disable-sandbox              # passed

(cd Rust && cargo test --workspace)                   # 28 passed (13 + 12 + 3)
(cd Rust && cargo fmt --all --check)                  # passed
(cd Rust && cargo clippy --workspace --all-targets -- -D warnings) # passed
git diff --check                                      # passed

xcodebuild -project NimbusSync.xcodeproj -scheme NimbusSync -configuration Debug -destination platform=macOS -derivedDataPath /private/tmp/nimbussync-final-build-19/derived -clonedSourcePackagesDirPath /private/tmp/nimbussync-final-build-19/source-packages -packageCachePath /private/tmp/nimbussync-final-build-19/package-cache -skipPackageUpdates build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO # passed

NIMBUSSYNC_CONFIG=/dev/null NIMBUSSYNC_EXTERNAL_EVIDENCE=docs/archive/reports/phase-5-external-evidence.example.json SIGNING_MODE=unsigned CONFIGURATION=Debug BUILD_ROOT=/private/tmp/nimbussync-final-build-19 DIST_DIR=/private/tmp/nimbussync-final-dist-19 ./Scripts/build.sh # passed
shasum -a 256 -c /private/tmp/nimbussync-final-dist-19/NimbusSync-0.1.0.zip.sha256 # OK
Scripts/validate-phase-5-evidence.sh docs/archive/reports/phase-5-external-evidence.example.json # 27 unverified; --require-go rejected
Scripts/run-local-benchmarks.sh # 100,000 items, 100 samples, 10 warmups; passed
NIMBUSSYNC_SIGNING_MODE=unsigned Scripts/generate-release-manifest.sh /private/tmp/nimbussync-final-dist-19/NimbusSync-0.1.0.zip docs/archive/reports/phase-5-external-evidence.example.json # JSON/redaction validation passed
~~~

静态扫描确认 Release entitlements/project 未包含 File Provider testing entitlement、任意 HTTP exception 或 credential-like artifacts；Debug testing entitlement 仅保留在 Debug 配置。最终重跑生成了 `/private/tmp/nimbussync-final-dist-19/NimbusSync.app`、zip 和 SHA-256 文件；zip SHA-256 为 `24a2f89d36e0bac5a8e46393d6f198bbe80da35e1a67c449deacd66f6a512285`（5,881,826 bytes）。`sh -n Scripts/build.sh`、Release 静态禁用项扫描和产物 credential-like 扫描均通过。新增 [外部验收证据模板](./phase-5-external-evidence.example.json) 与 [证据校验脚本](../../../Scripts/validate-phase-5-evidence.sh)，模板当前刻意保留 27 项 `unverified`，`--require-go` 会阻断发布。

## 本地 Store 性能样本

通过 [本地 benchmark 入口](../../../Scripts/run-local-benchmarks.sh) 在 macOS 26.6.2 arm64、Release 配置、100,000 个目录 item、page size 200、10 次 warmup 和 100 次样本上运行：

| 查询 | p50 | p95 | p99 | 最大值 |
|---|---:|---:|---:|---:|
| directory offset page | 6.51 ms | 11.43 ms | 11.76 ms | 11.96 ms |
| working-set keyset page | 0.38 ms | 0.44 ms | 0.59 ms | 0.60 ms |

该样本只证明临时 SQLite Store 查询层，不包含 signed Finder/fileproviderd、网络、system-set callback、10 GB 传输 RSS、多 Domain fairness 或 72 小时长稳；这些仍保持未验证。

final-19 的脱敏 [release manifest](/private/tmp/nimbussync-final-dist-19/release-manifest.json) 已生成并通过 `jq`/redaction scan；记录了当前 commit、工作树 dirty 状态、Swift/Xcode/Rust/Cargo 工具链、artifact SHA-256，以及外部证据 `verified=0/unsupported=0/unverified=27`。manifest 不记录绝对路径、远端 URI 或凭据。

本轮代码收口还包括：旧目录 snapshot 不再因新 head 发布而提前失效；未完成 snapshot 不向 Finder 暴露 live page；Trash 列表使用 opaque keyset；异步目录/Trash 请求纳入 task registration；complete/cursor/snapshot-safe 分页证据未验证时不继续多页扫描；working-set audience 在 journal commit 时固化，membership revision 变化会拒绝旧 keyset token；v6 迁移按正确 SQLite 类型补列；批量事件复用 exclusion/descendant 语义；tombstone 后复现远端实体复用原 opaque item ID；条件冲突不伪造 remote version；mutation result 的 item、journal、outbox、operation、pending 清理和递归 tombstone 在同一事务提交；system-set owner 绑定 domain-version；排除规则从 Settings 可配置并保留远端对象；fallback conflict 未经 capability 验证不开放覆盖/keep-both；已提交 mutation 的 conflict `resolved` 生命周期可重放收敛；异步 thumbnail 传输也遵守 suspended/register/resume 合同，并使用临时文件边界；projection refresh 失败保留可恢复 cursor；content-bearing create/modify 的 source replay 绑定 fingerprint，checkpoint 取消进入 `awaiting_source_replay`，不同源不会启动第二次远端写；目录 snapshot staging 和 page read path 均执行 exclusion matcher，view-state 改变或 exclusion rule 更新会使旧 snapshot 失效；operation 持久化 base version/changed fields，download/delete task 只在 durable commit 成功后标记 succeeded；完成 operation 的 upload checkpoint 与过期 terminal task 可安全回收，恢复中的传输事实保留；Qiniu/Upyun 上传按 Cloudreve Desktop provider wire 合同补齐 part/multipart 规则；dirty-data Domain removal 在 preserve 模式保留本地事实与 Keychain 引用并显示系统保留位置。

补充收口：projection refresh 现在以 bounded page 与 cursor 原子提交；失败的 reconciliation 保留 cursor，恢复运行不会对不完整前缀推断 tombstone；系统 materialized/pending callback 在 bounded refresh 完成或持久失败后才完成 callback；完成 operation 的 upload checkpoint 与过期 terminal task 可安全回收，恢复中的传输事实保留。

本轮修复 projection refresh 的 signal-before-applied-revision 顺序，并将 job 状态与 applied revision 放入同一 SQLite 事务；signal 失败会保留 pending outbox 和可恢复 job，下一次 worker 可继续重放。

补充修复：root/epoch 写入口现在检查 process-generation fence；缺少 `primary_entity` 时不再把 `updated_at` 当作 contentVersion，文件保持只读；Swift/Rust capability snapshot 显式保存 Provider 恢复、completion 查询、zero-byte、complete/cursor/snapshot-safe 分页、删除和 refresh 语义。

审查修复补充：目录与 reconciliation 的页码终止以响应 `page/page_size/total_items` 为准，cursor 末页不再回退到 page 1；异步 create/modify 失败同步持久化 item upload error；File Provider 已保留 dirty data 并移除系统 Domain 后，Settings 提供需要用户确认的 `Finish removal`，且最终清理前再次确认系统 Domain 已不存在；release manifest 的签名模式由流水线通过 `NIMBUSSYNC_SIGNING_MODE` 显式提供，缺省值为 `unknown`，不再伪报 unsigned。

## 未完成的外部验收

当前环境没有 Apple Development Team/profile、受控 Cloudreve contract instance 或 signed Finder runtime，因此以下不能标记为已验证：

- Cloudreve atomic conditional modify、collision-safe create、trash listing/restore/purge、zero-byte、Provider upload 和 chunk resume；
- signed Finder 的 Domain registration、callback replay、materialized/pending、evict/actions、upgrade/uninstall；
- macOS 13–26 matrix、100,000 item/10 GB/多 Domain fairness、72 小时 long-run、Gatekeeper/notarization/clean-machine upgrade；

这些能力在产品中保持 capability-gated/只读/需要用户处理状态，不作为本地测试已证明的功能发布。
