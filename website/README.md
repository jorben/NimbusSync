# NimbusSync website

NimbusSync 的静态产品介绍页，发布地址：<https://jorben.github.io/NimbusSync/>。
使用 HTML、CSS 和少量 JavaScript，不需要 npm、第三方运行时依赖或外部字体服务。
默认中文，顶部可切换英文；`?lang=en` 可直接分享英文页面。没有 JavaScript 时仍能浏览
中文内容、展开常见问题并进入 GitHub Releases 下载。

## 本地预览

从仓库根目录运行：

```sh
python3 -m http.server 8080 --directory website
```

打开 <http://localhost:8080>。页面图片均为仓库素材的本地副本：应用图标来自
`Design/AppIcon-Light.png`，分享图来自 `Design/Banner.png`，Cloudreve 图标来自共享设计包，
应用截图来自 `docs/evidence/localization/ui-coverage/domains-wide.*.png`，均使用示例数据。
首页 Finder 视图是标明用途的工作方式示意图。

下载入口使用 GitHub 的 `/releases/latest`，始终进入最新正式版页面，用户可查看发布说明、
DMG 和校验和；无需浏览器调用 GitHub API，也不需要每次发版修改官网版本号。

## 构建与检查

需要 Python 3.9+，JavaScript 语法检查需要 Node.js。

```sh
python3 -m unittest discover -s website -p 'test_*.py' -v
node --check website/script.js
git diff --check
python3 website/build.py --output /tmp/nimbussync-site
```

`--output` 必须是不存在的目录，且不能位于 `website/` 内，也不能包含源码目录。
构建只发布 HTML、CSS、JavaScript、`assets/` 和 `.nojekyll`，不会上传 Python 源码和说明。
输出到临时目录可避免在工作区产生构建产物。

## GitHub Pages 与应用更新

官网和 Sparkle 共用同一站点，`appcast.xml` 的公开 URL 保持不变：
<https://jorben.github.io/NimbusSync/appcast.xml>。

`.github/workflows/deploy-website.yml` 的触发条件：

- `master` 上的 `website/**` 或该工作流更新：校验、构建并部署。
- Pull Request 修改上述文件：校验和构建产物，供评审使用。
- **Publish Appcast** 成功：读取最新官网源码与 `gh-pages` 中的最新 feed，重新部署。
- 手动运行：可用来首次部署或重试；只有 `master` 可以部署到正式站点。

CI 读取 `gh-pages` 中的 `appcast.xml`（以及存在时的 `appcast.xml.sig`），校验 XML 后
**逐字节复制**到网站产物中，不重新序列化、不修改签名，也不把官网文件写回 `gh-pages`。
缺少或损坏的 appcast 会直接让构建失败，避免部署只含官网、却使已安装应用失去更新入口的站点。
官网部署使用独立的串行队列；原有 `publish-appcast` 的串行签名发布队列保持原配置。

一次性配置（迁移现有站点时按此顺序执行）：

1. 把网站与 `Deploy Website` 工作流合入 `master`。
2. 在仓库 **Settings → Pages → Build and deployment → Source** 选择 **GitHub Actions**，
   替代原来的 `Deploy from a branch`。`gh-pages` 仍用来保存签名 feed。
3. 在 **Actions → Deploy Website → Run workflow** 中选择 `master` 并运行。
4. 确认部署成功，并同时检查首页和 `appcast.xml`。之后官网与 feed 都会自动更新。

工作流使用 GitHub 自带的 `GITHUB_TOKEN`，不需要额外 PAT 或网站发布密钥。发布 job 仅授予
`pages: write` 与 `id-token: write`，构建与 PR job 只读取仓库。`GITHUB_TOKEN` 向分支推送
通常不会触发分支式 Pages 构建，所以 appcast 的部署由 `workflow_run` 显式触发。

如果新的 appcast 已推送但网站部署失败，公共 feed 仍是上一次成功部署的版本。修复后手动
重跑 **Deploy Website** 即可，无需重新构建或签名应用。
