# 归档索引（ARCHIVE）

> 本文件是 `rustfs-fnos` 项目的**收尾入口**：项目现在处于什么状态、文档该看哪一份、哪些旧结论已经作废、哪些东西必须留着。
> 如果你只读一份文档，读这份；如果你在排障，去 `docs/pitfalls.md`。

---

## 1. 项目最终状态

`rustfs-fnos` 把 RustFS（S3 兼容对象存储）封装成飞牛 fnOS 的 `.fpk` 应用：应用中心一键安装、桌面图标在 fnOS 窗口内直接打开控制台。仓库 `https://github.com/a10463981/rustfs-fnos`，**最新正式版 `v1.0.4-2`（`draft=false` / `prerelease=false` / `releases/latest` 指向它）**，发布包 **`rustfs-fnos-1.0.4-2-all.fpk`（96,133 B）**，`platform=all`，同一包适用于 `x86_64` 与 `aarch64`；随包发布 `SHA256SUMS` 与 `build-info.json`，匿名下载的 sha256 与两者一致。发布链路已端到端由 CI 完成（`fpk-release` 14 步全绿）。

**资产命名规则**：`<appname>-<version>-<platform>.fpk`，例如 `rustfs-fnos-1.0.4-2-all.fpk`；配套资产固定为 `SHA256SUMS`、`build-info.json` 两个。

**版本号约定**：**前三段对齐上游镜像版本**（`rustfs/rustfs:1.0.4` → 本项目 `1.0.4`），**`-N` 是本项目的打包修订号**（`-1`、`-2` 为同一上游版本的重新打包）。`fnpack` 只接受 `x.y.z` 或 `x.y.z-N`；不允许四段、不允许前导零（见 `pitfalls.md` P17）。版本号由 `scripts/stamp-manifest.sh` 单一来源生成，不手改 `manifest`。

**支持矩阵**

| 形态 | 平台字段 | x86_64 | aarch64 | 状态 |
|---|---|---|---|---|
| 在线版 | `all` | 已验证可装可用 | **可安装，未真机验证** | 已发布（`v1.0.4-2`，latest） |
| 离线版 | 按包内镜像 | 已做过可行性实测 | 未验证 | **已设计、未启用**（workflow 中 `offline` job 关闭，包内不夹带镜像） |

> 「未真机验证」是明确写进 Release 说明的事实，不是待办饰词：上游 `rustfs:1.0.4` 在 ghcr 有 `linux/arm64`、`nginx:1.27-alpine` 也是多架构，但项目侧没有 arm 设备跑过。Release 正文给了 7 条三分钟自测（`uname -m`、镜像架构、两个容器、`health/ready`、控制台、`app.sock`、`main status`），有设备的人跑一遍即可定论。

---

## 2. 文档地图

仓库根：

| 文件 | 作用 |
|---|---|
| `README.md` | 项目定位、安装入口、下载哪个包、最短上手路径 |
| `CHANGELOG.md` | 按版本记录变更（含打包修订号） |
| `NOTICE` / `LICENSE` | 上游归属声明与许可（重打包分发的前提，见 `docs/licensing.md`） |
| `SECURITY.md` | 漏洞与凭据泄露的上报方式 |

`docs/`：

| 文件 | 一句话作用 |
|---|---|
| `install-fnos.md` | 在 fnOS 上安装/升级/卸载的完整步骤，含卸载重装前要预热镜像（`pitfalls.md` P15） |
| `data-location.md` | 数据到底落在哪（`TRIM_PKGVAR` / 共享目录）、`data.old-*` 是什么、怎么搬回 |
| `upgrade-safety.md` | 升级前后的安全动作：备份、版本核对、失败回退口径 |
| `faq.md` | 高频问题直答（打不开、登录失败、版本没变、数据找不到） |
| `build.md` | 本地构建与打包：fnpack 用法、stamp、preflight、产物校验 |
| `licensing.md` | 上游许可与本项目分发边界、NOTICE 的填法 |
| `verify.md` | 发布物校验：sha256 三方比对、包内 `manifest` 与 `app/images` 抽查 |
| `first-release.md` | 首次发布（v1.0.0）的过程记录与当时的约束，历史参考 |
| `development-history.md` | 开发主线编年：每个阶段做了什么决策、为什么（**读「为什么」看这份**） |
| `pitfalls.md` | **踩坑总览，按症状检索**：症状→根因→怎么确认→修法→状态（**排障第一站**） |
| `ARCHIVE.md` | 本文件：归档索引、已作废结论、保留/清理清单 |

---

## 3. 已作废的旧结论 —— 不要再按这些判断

下面每一条都曾经在某个阶段被当作事实写下来过，后来被实测推翻。**保留在此是为了防止有人翻到旧记录后重新踩一遍**，不是待办事项。

| # | 旧结论（已作废） | 现在的正确判断 |
|---|---|---|
| 1 | ~~`type: iframe` 不可用，只能新标签页打开~~ | **已实现窗口内打开**：网关 `app.sock` + 上游 `RUSTFS_CONSOLE_PREFIX` 组合即可在 fnOS 窗口内打开控制台。若再看到「只能新标签」，那是旧文档。 |
| 2 | ~~首次安装用默认数据位置就能绕开权限问题~~ | **错，且相反**：全新机器 + 默认数据位置曾经**必失败**（平台尚未建 `@appdata/<app>`，父目录 `root:root 755` 导致安装前写探测判不可写）。已由「平台代建豁免」修复，见 `pitfalls.md` P04。 |
| 3 | ~~登录必须手填服务器地址~~ | **已自动化**：通过 HTML 注入预置服务器地址，用户不需要手填；并在「同主机异端口」时覆盖旧值（`pitfalls.md` P13）。 |
| 4 | ~~`docker pull` 走镜像站，2.6 秒就成功~~ | **那不是加速，是 cache hit**：本地已有镜像层，不产生真实网络拉取。真实联网只有 **root** 能拉（签名头只在 `/root/.docker/config.json`），应用用户拉不动。见 `pitfalls.md` P10 / P11。 |
| 5 | ~~四段版本号可用~~ | **不可用**。`fnpack` 只接受 `x.y.z` 或 `x.y.z-N`；更危险的是 `1.04.01` 这种**能打包成功但被解析成 `1.4.1`**。见 `pitfalls.md` P17。 |
| 6 | ~~应用中心没有 Docker 条目 = 缺 Docker~~ | **无关**：fnOS 把 Docker 作为**系统服务**提供，应用中心里有没有条目与 Docker 是否可用/就绪没有关系。判断 Docker 是否可用要看 `docker version` 的系统侧输出。 |

> 判断规则：任何与上表冲突的旧记录，以本表和 `docs/pitfalls.md` 为准；两者都冲突时，以**当前版本实测**为准，并回来更新这两份文件。

---

## 4. 归档建议

### 4.1 值得长期保留（不要删）

| 对象 | 为什么留 |
|---|---|
| 正式发布包 `v1.0.4-2`、`v1.0.4-1` 的 `.fpk` + `SHA256SUMS` + `build-info.json` | 已对外分发的产物；用户回退、问题复现、sha256 比对都要用。**已发布的 Release 与 tag 永不删除**。 |
| 用户数据目录（`@appdata/<app>`、`@appconf/<app>`、共享目录下的数据） | 用户资产，不属于过程产物。任何清理动作前先 `scripts/backup-data.sh`。 |
| 备份目录（`backup-data.sh` 的产出） | 升级/重装失败时的唯一退路；保留至少两个版本跨度。 |
| `upgrade-history.log` | 升级路径的唯一时间线证据；排查「升级后版本没变」「迁移是否执行」全靠它。 |
| `docs/` 全量（含 `pitfalls.md`、`development-history.md`） | 决策依据与踩坑记录的载体，比代码更难重建。 |
| `deploy/fnos/` 与 `scripts/`、`.github/workflows/` | 可复现打包的唯一来源；丢了等于发布物无法重建。 |
| `data.old-<时间戳>` 目录 | **刻意保留**的旧库。除非确认新库正常且已备份，否则不删（`pitfalls.md` P14）。 |

### 4.2 可以清理（过程产物）

| 对象 | 说明 |
|---|---|
| 中间版本包 `v7`–`v17.3` | 开发期迭代产物，从未对外分发，保留最新正式版即可。 |
| `probe1` 及同类的探针目录/脚本产物 | 一次性验证用，结论已进 `pitfalls.md`。 |
| `/tmp` 下的沙箱目录 | 临时解包/试装残留。 |
| `data.old-*`（**仅在确认后**） | 见 4.1：默认保留；确认新库可用且有备份后才清。 |
| 多余的镜像 tag（非当前版本、非回退目标） | 会持续占盘；清理前确认不是回退目标、不是离线包依赖。 |
| 本地重建的中间 `.fpk`（与 CI 产物 sha256 不同者） | 仅供本机测试，**不是发布物**；注意 CI 与本地因 gzip/tar 元数据差异，大小会差几十到百余字节，属正常。 |

### 4.3 明确「不要删」的三条红线

1. **已发布的 tag 与 Release**（含 `v1.0.4`、`v1.0.4-1`、`v1.0.4-2`）—— 删了会让已分发的 sha256 失去可追溯来源。
2. **`upgrade-history.log` 与备份目录** —— 出事时的唯一证据链。
3. **用户数据目录与 `data.old-*`** —— 数据事故的代价远高于磁盘成本；宁可先改名归档，也不要 `rm -rf`。

---

## 5. 归档后如何继续

- 只想知道「怎么装」→ `docs/install-fnos.md`
- 遇到现象想查原因 → `docs/pitfalls.md`（按症状速查表）
- 想知道「当初为什么这么做」→ `docs/development-history.md`
- 想重新打包发版 → `docs/build.md` + `scripts/preflight.sh`（先跑 preflight，再看 `Packing successfully`）
- 想确认下载物是否被篡改 → `docs/verify.md`（sha256 三方比对）
- 想启用离线版 → 打开 workflow 的 `offline` job，并按 `pitfalls.md` P19 的三条约束验证（镜像在 `app/` 下、包内 tar 可读、`docker load` 在 `install_init`）
