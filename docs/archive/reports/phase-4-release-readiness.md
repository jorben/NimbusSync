# Phase 4 Release Readiness Report

> 状态：Conditional Go / No-Go for 1.0 release
> 日期：2026-09-05
> 依据：`docs/07-phase-4-product-release.md`
> 后续对齐实施：[Phase 5 parity implementation report](./phase-5-nextcloud-parity-implementation.md)

## 1. 已实现并验证

- 菜单栏 Popover、Settings、Onboarding 和 Conflict Center 基础窗口。
- 持久 ProductTask/ProductConflict projection、任务重试/取消模型、状态优先级。
- 通知分类、dedupe、deep link opaque ID 路由。
- Gitignore 风格本机排除规则编译、预览、dirty preservation gate 和 intent 复用。
- 诊断 manifest、health check、privacy preview、secret redaction、metrics projection。
- 11 个 locale 标识、String Catalog 基础、动态/本地化字节格式 API、VoiceOver labels、键盘可达标准控件。
- Finder thumbnail、decoration、non-UI custom action 和 File Provider UI action 基础 Target。
- schema/generation upgrade fence、release manifest/checksum、release verification/uninstall preparation scripts。

## 2. Review 修复记录

1. 修复 String Catalog 缺少 `version` 导致 Xcode 构建失败。
2. 修复 macOS 13 不支持 `onChange(of:)` 的 UI API，改用兼容的 `onReceive`。
3. ProductKit 偏好保存不再直接访问原始同步表；规则通过 Store API 保存。
4. Deep link 只接受本地 opaque conflict/task/domain ID，拒绝远端路径和非法 ID。
5. 未验证能力继续显示 read-only/unsupported，产品 UI 不把 unverified provider 变成可写。
6. 菜单栏 App 现在从 registry/Domain store 恢复 Domain、operation、conflict projection；Onboarding 已接入 site ping、OAuth/PKCE、账号/根校验和 provisioning saga。
7. File Provider UI action 使用本地 opaque item ID deep link；App 可按 item ID 解析 Cloudreve `/home?path=...&open=...`，不把远端路径直接放入路由。
8. Finder callback 的枚举、下载、mutation、thumbnail 使用 bounded worker，并持久化 materialized/pending refresh intent；item 时间、权限和下载状态映射到 File Provider metadata。
9. 任务 projection 接入持久取消、retry 和 history hide；通知点击携带 opaque deep link；Conflict Center 接入 item selection、远端版本二次校验、pending callback resolution 和 Finder decoration。

## 3. 验证结果

| 验证 | 结果 |
|---|---|
| Rust workspace tests | 通过，28 tests（13 + 12 + 3） |
| Swift Package tests | 通过，102 tests（主套件 87、File Provider 专项 15，含 Provider wire 4） |
| Swift Debug/Release build | 通过 |
| Xcode unsigned Debug build | 通过，三产品 Target 和 ProductKit resource catalog |
| `Scripts/build.sh` unsigned package | 通过，生成 App、zip 和 SHA-256 |
| `cargo fmt --all --check` / `cargo clippy --workspace --all-targets -- -D warnings` / `git diff --check` | 通过 |
| Secret/release scan | 通过本地 gate |
| Universal2 | 未验证，当前仅 arm64 Rust/Xcode build evidence |
| Developer ID codesign | 未验证，无发布签名配置/证书 |
| notarization/Gatekeeper | 未验证 |
| clean-machine install/upgrade/uninstall | 未验证 |
| 11-language snapshot/accessibility audit | 未验证，静态 label/locale foundation 已完成 |
| real Finder action/thumbnail/decoration | 未验证，需要签名 Extension 和实机 |

## 4. File Provider parity implementation update

Phase 5 已在当前 `feat/macos-parity` 工作树落地 Phase A–F 的本地实现基线：v7 Store/migration、immutable provider journal、v2 anchor/page、directory snapshot generation、materialized/pending system-set fencing、async task registration、chunk/source replay、conditional capability gate、conflict source validation、parent/trash/exclusion/action projection 和 projection-schema refresh。

本地新增专项覆盖包括 cold-directory exclusion filtering、batch view-state deduplication、immutable working-set audience/revision fencing、operation base/changed-fields persistence、projection refresh cursor recovery、`awaiting_source_replay` recovery、transfer compaction、Qiniu/Upyun/Remote URLProtocol wire contract，以及 dirty-data Domain removal preservation。详细文件清单、命令、产物和证据边界见 [phase-5 report](./phase-5-nextcloud-parity-implementation.md)。

Release entitlement 静态门禁确认 testing-mode 仅存在于 Debug 配置；macOS 26 native conflict capability 当前仍关闭。上述 unsigned/local evidence 不改变签名 Finder、Cloudreve contract、macOS version matrix、性能、72 小时长稳、公证和 Gatekeeper 的 No-Go 状态。

## 5. 发布决策

当前不能关闭 Phase 4 release candidate 条件，1.0 结论为 **No-Go**。原因是阶段方案明确把签名、公证、Gatekeeper、升级/卸载、真实 Finder E2E、Provider 支持矩阵和长稳作为发布阻断项；这些证据不应由本地静态测试替代。

本轮 review 还确认：菜单栏/设置/冲突中心、重新授权、通知触发、任务控制和三类冲突动作已有本地实现，但完整 dirty-data removal/recovery、11 语言运行时 catalog、真实 Finder action/decoration、签名/发布证据以及 Rust FFI runtime ownership 仍未达到 1.0 全量验收标准；这些边界不能用本地单元测试替代。

代码可以继续作为 Technical Preview/Beta 的工程基线，保持 Phase 0 至 3 的 `Conditional Go` 和所有 unverified capability 的 fail-closed 边界。
