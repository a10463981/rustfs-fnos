# 开发演进史（写给半年后来接手的人）

这份文档不解释「代码是什么」，只解释**「为什么长成这样」**。
仓库里只有最终版代码，所有「看着奇怪、但其实是踩过坑才这么写」的判断都记在这里，每条都按 **当时的问题 → 结论 → 证据** 三段写。

阅读建议：**先读最后一节「如果你现在要改这个项目，先读这 5 段」**，再回头按需查具体条目。

约定：
- 文中数字与路径都是真机实测值，设备为 `192.168.100.64`（fnOS，4 核 / 3.8 GiB / `/vol1` btrfs 20 GB）。
- **卷号（`/vol1`、`/vol2`）与 UID/GID 因设备而异**：那台机器上应用用户是 `uid=996`、`gid=901(AppUsers)`，组还有 `1001(Users)`、`994(docker)`、`990(rustfs-fnos)`。别把 996/901 当常量。
- 「实测」= 在那台机器上跑过、有原始输出；「未证实」= 推断或只在小样本上验证，别当结论用。

---

## 一、项目起点与形态选择

### 要解决的问题

NAS 用户要一个**局域网内的 S3 端点**，典型用途三种：

1. **备份目标** —— 很多备份软件支持「S3 兼容存储」，把备份写进自家 NAS，数据不出门；
2. **媒体库 / 图床后端** —— 媒体服务器、相册类应用把对象存储当后端；
3. **给其它自托管应用提供对象存储** —— 存附件、导出包、日志归档。

这三类的共同点：**要长期跑、要能被别的应用用 AK/SK 连上、数据不能丢**。所以关键不在「能不能跑起来」，而在**卸载/升级/失败回滚时数据还在不在**。整个项目的复杂度几乎都花在这上面。

### 为什么是「Docker 模板 fpk 承载官方镜像」

| 备选 | 为什么没选 |
|---|---|
| native 打包 RustFS 二进制 | 要自己跟上游编译、处理依赖与 glibc 变体；上游发版就得重编；上游镜像本来就是官方交付物，重打包等于多一层不被信任的构建 |
| 让用户手工写 `docker-compose.yml` | 与「应用中心一键安装」的目标直接冲突 |
| **Docker 模板 fpk，镜像用官方 `docker.io/rustfs/rustfs:<tag>`** | 上游怎么发我们就怎么用；包里只有配置与生命周期脚本，体积小（初期 18 KB，v12 带真图标 72 KB）；升级 = 换 tag |

镜像事实（实测）：`ghcr.io/rustfs/rustfs` 与 `docker.io/rustfs/rustfs` 都在，**amd64 + arm64 双架构**，解压约 **299 MB**；容器默认以非 root `10001:10001` 运行；端口 `9000` = S3 API、`9001` = Console，**Console 真实路径是 `/rustfs/console/`**（访问 `/` 返回 XML 403）。

### 为什么 fpk 里不再叠 supervisor / pm2

镜像本身就是「一个进程跑到底」的模型，容器已经由应用中心托管启停。再叠一层进程管理器只会：

- 让「应用状态」与「容器状态」出现两个真相源；
- 把健康检查变成「supervisor 活着」而不是「S3 就绪」；
- 出问题时多一层日志要翻。

所以 `cmd/main` 的 `start`/`stop` 基本是**空实现**，真正的判活交给 `status` 用 HTTP 探针（见 §二-4）。

---

## 二、关键技术决策与依据

### 1. 数据必须落 `TRIM_PKGVAR`，不能放 `TRIM_APPDEST`

**问题**：一开始把数据目录放在程序目录（`TRIM_APPDEST`，即安装后的 target）旁边，图省事。

**结论**：数据只放 `TRIM_PKGVAR`（`/vol<N>/@appdata/<app>`）；`TRIM_APPDEST` 视为**可被整体替换**的只读程序区；配置放 `TRIM_PKGETC`。

**证据**：fpk 升级的语义是「用新包替换 target」，`TRIM_APPDEST` 下的内容在升级时会被整体覆盖。而 `TRIM_PKGVAR` 是平台认可的数据区（卸载时还能让用户选择是否保留）。这条如果搞错，第一次升级就会清空用户数据。

> 后续补充（见 §二-10）：`@appdata` 这个默认位置**本身**也有风险 —— 安装失败触发平台 `rollback` 时可能被一起删。所以 v7 起支持把数据放到用户自己的存储空间，默认位置仍保留但会在安装时 `WARN` 空间与回滚风险。

### 2. 符号链接挂载：compose 拿不到我们的变量，空变量会静默变砖

**问题**：数据目录要支持「用户自己选路径」，自然想让 compose 直接读这个路径。

**结论**：**compose 的挂载行固定写 `${TRIM_PKGVAR}/<subdir>:/data`，物理位置由一个符号链接决定**。换目录 = 换链接，不搬数据。

**证据**：
- compose 的变量只有应用中心注入的那批（`TRIM_*` / `wizard_*`），**它不会 source 我们的 `settings.env`**；一旦某个变量为空，挂载会变成 `:/data` 或 `/data`，容器直接起不来（静默变砖，最难查）。
- 现有 compose 里 `${wizard_console_port:-9201}` 带兜底值且恰好等于默认端口，**无法反证**向导值会传给 compose —— 所以不能赌。
- 真机验证（Docker 28.5.2）：`docker run -v <链接>:/data` 与 `docker compose` 两条路径，**docker 都会解析 bind 源的符号链接**，数据确实落到链接指向的真实目录；非 root UID `996:990` 通过链接写入也成功。
- **但**：`docker inspect` 的 `Mounts[].Source` 记录的是**链接路径**，不是解析后的真实路径。所以**改了链接指向必须重建容器**（`docker rm`/`up --force-recreate`），`docker restart` 不会重新解析。

### 3. 凭据走 `_FILE` 变体，且 v7 起由用户在向导里自设

**问题**：初版是安装时随机生成 AK/SK 写到 `${TRIM_PKGETC}/credentials/`，日志里打印一次。实际使用时用户抱怨：**「装完不知道去哪找登录密码」** —— 对 NAS 用户来说，「去某个路径翻文件」是不可接受的。

**结论**：
- 凭据**只落文件**（`600`），通过 `RUSTFS_ACCESS_KEY_FILE` / `RUSTFS_SECRET_KEY_FILE` 注入，**绝不进容器 env** —— `docker inspect` 里看不到；
- v7 起向导提供「管理员账号（默认 `admin`）/ 管理员密码」，用户自己填；两个都填 = 用填的；两个都留空 = 沿用已有的，没有才随机生成并在安装结果里显著打印一次；
- 账号规则 `^[A-Za-z0-9._-]{3,32}$` —— **不能含 `/`**（SigV4 scope 解析会错）；密码 8–64 位、不含空白；
- 上游默认的 `rustfsadmin/rustfsadmin` **必须被覆盖**。

**证据**：真机用向导设的 `admin/TestPass2026` 做 SigV4 全链路：`CreateBucket 200 / PutObject 200 / GetObject 200 / DeleteObject 204` 全通；而用 `rustfsadmin` 请求返回 4 次 `403 InvalidAccessKeyId`。官方文档也明确：同时设置直接变量与 `_FILE` 是硬错误，`_FILE` 只读第一行并去空白与 CR。

### 4. `status` 用 `/health/ready` 判就绪，不看「容器在跑」

**问题**：早期 `status` 只检查容器 `State.Running`，结果出现「应用中心显示运行中，但 S3 连不上」。

**结论**：`status` 以 `GET /health/ready` 返回 200 为准，并采用三态退出码：**0 = 运行中（含「已就绪但待校验」）**、**1 = 故障**、**3 = 未运行**。探针在宿主侧做（不依赖镜像内是否有 curl/wget）。

**证据**：真机全过程用 `curl :9200/health/ready` 判定，200/503 区分明确；容器「running 但未 ready」的窗口期确实存在（首次启动建库时）。

> 顺带：compose 里的 `healthcheck` 依赖镜像内的 `curl`/`wget`，若镜像都没有它会一直 unhealthy —— 所以 `status` **不依赖**它，宿主侧自测。

### 5. 升级不能依赖「包用户自己 pull 镜像」

**问题**：v2/v3 阶段想「升级时自己拉新镜像再重建」。

**结论**：**不行**。fnOS 的镜像站要求请求带签名头（`X-Meta-Sign` / `X-Meta-Token`），这组头只写在 **`/root/.docker/config.json`**；应用以包用户运行，读不到 → 自行 `docker pull` 会回落直连 `registry-1.docker.io` 并超时。于是改成：

- **拉取交给 root 侧**（应用中心启动时以 root 拉，或管理员 `sudo docker pull`）；
- 脚本只做**事后强校验**：`容器镜像 id == compose 声明的目标镜像 id`；
- 不满足时进入**待校验状态机**（`pending_verify.env`），**宽限期 15 分钟，按墙钟算**（`CREATED_TS` + `DEADLINE_MINUTES`），到期才判失败并给出「三步修复 + 回滚命令」。

**证据**：
- 完整错误链：`10237`/`pull` 失败 → 诊断输出里明确写「当前身份没有镜像站签名头（只在 root 的 docker 配置里）」；同一镜像以 root `docker pull` 正常（新 tag 30 秒～1 分 20 秒）。
- **一次自我纠正**：v3 阶段曾观察到「2.6 秒拉完」，当时误判为「网络变好了」；核对后发现是 **cache hit**（本地已有该层），不是真的拉取成功。这条被写进报告，避免以后又拿这个数字当证据。
- 宽限期为什么要按墙钟：早期按「检查次数」计（20 次），真机上**连续 20 次 `status` 只要 3 秒**就推满了，镜像还在拉就判死。改成墙钟后，`CREATED_TS` 改早 20 分钟 → 立刻返回 1；几秒内连跑 25 次 → 全部返回 0（`ATTEMPTS` 涨到 26 也不判死）。

### 6. `main start` 的漂移自愈：不假设平台会调用我们的回调

**问题**：一直有个悬而未决的问题 —— **Web UI 升级时，平台到底会不会执行 `compose up`、会不会调用我们的 `upgrade_callback`？** 真机查到：`appcenter-cli` 没有 upgrade 子命令；`stop → start` 之后容器 id 与镜像**都不变**（平台没有替我们 `compose up`）。

**结论**：**不赌平台**。`cmd/main start` 自己做三值比对：

| 情形 | 条件 | 行为 |
|---|---|---|
| 0 | 容器不存在 | 什么都不做（交给应用中心创建） |
| 1 | 声明 == 实际 且 id 一致 | 不动（保持空实现语义，不与平台抢启停权） |
| 2 | **漂移** 且 目标镜像**在本地** | `up --force-recreate` → 校验容器 id；不一致则改写 compose 回上一版并 `up`，退出 1 |
| 3 | **漂移** 且 目标镜像**不在本地** | 只登记 `pending_verify.env`，**不 pull、不 up、不失败**，退出 0 |

**证据**：真机全程**没有调用 `upgrade_callback`**，只跑了一次 `main start`，容器就从 `1.0.4` 换到 `1.0.1-preview.17`，容器 image id 真的变了，审计写了行，`status` 返回 0。反过来也验过：把 compose 指向本地没有的 tag → 只写 pending、容器 `StartedAt` 未变、退出 0。

### 7. 版本号唯一真源 = git tag

**问题**：手工改 `manifest.version` 与实际镜像 tag 很容易脱节。

**结论**：仓库里 `deploy/fnos/manifest` **恒写 `version = 0.0.0`**（占位），真实版本由 `scripts/stamp-manifest.sh` 从 tag 注入（`v1.2.3` → `1.2.3`；`v1.2.3-1` → 预发布）。CI 与本地构建都必须先 stamp 再 build。配套 `scripts/check-image-bump.sh` 拦「`version` 涨了但 compose 的 `image:` 没换」（反向也拦：image 变了 version 没变）。

**证据**：
- `fnpack` 只接受 `x.y.z` 或 `x.y.z-<整数>`，`1.0.0-beta` 被直接拒绝。
- 真机踩过：**没 stamp 直接 build**，产出的包里 `version = 0.0.0`，装上 NAS 后应用中心显示 0.0.0，与镜像 tag `1.0.4` 对不上；`stamp` 后重打才正常。这条现在写进 `docs/build.md` 顶部警告块，并给出「解包回读 version」的一条命令。
- 为什么必须机器拦：真机验证过「`version` 从 1.0.8 涨到 1.0.9、`image:` 完全没变」的包，运行时**报「升级完成」**（它按 compose 声明执行，`target_id == container_id` 即成功）—— 运行时根本分辨不出来，只能在打包前拦。

### 8. `fnpack build` 失败时退出码仍是 0

**问题**：CI 里习惯用 `if fnpack build; then ok; fi`。

**结论**：**不能看退出码**，必须解析输出里的关键字 `Packing successfully`。这条写进了 CI 两个 workflow 和 `preflight.sh`。

**证据**：真机实测多次 —— 打包失败（缺文件、manifest 非法）时 `fnpack build` 的 `exit=0`，但输出里没有 `Packing successfully`。如果按退出码判断，CI 会把坏包当成成功发布出去。

### 9. 写探测取代「属主比对」（TrimACL 的真相）

**问题**：`install_callback` 原本这样判断数据目录能不能用：

```bash
if [ "${owner_uid}" != "${TRIM_UID}" ] && [ "${owner_uid}" != "${run_uid}" ]; then fail "属主不对…"; fi
```

结果真机上用户填 `/vol1/1000/RustFS`（他在「文件管理」里建的目录，属主 `admin`、权限显示 `0`）时，**安装直接失败**并让用户去 `sudo chown`。

**结论**：**判断标准从「属主是谁」改成「以应用身份真的写一次」**（`probe_writable`）。属主信息只作提示，不作判断；root 身份探测时必须 `setpriv --reuid <uid> --regid <gid> --clear-groups` 降权（root 写什么都成功，用它探测等于没检查）。

**证据**：
- fnOS 在卷上挂了 **TrimACL**（挂载项 `trimacl` + `system.trim_acl` xattr），会给**具体的应用 uid** 挂一条 `rwxpdDaAeEc` 的 ACE。实测：`/vol1/1000/RustFS` 属主 `admin:Users`、`ls -ldn` 显示 `d---------`，但 `sudo setpriv --reuid 996 --regid 990 --clear-groups touch /vol1/1000/RustFS/probe` **成功**，`test -w` 也是 YES。
- 关键对照：把包用户**从 `Users` 组移出**后仍然能写 → 说明这不是组权限，而是 TrimACL 按 uid 授权。所以 `join-groups: ["docker","Users"]` **不是**「免 sudo」的依据（保留无害，只为兼容组可写 775 的老式目录）。
- 改完后真机三个入口（`config_init` / `config_callback` / `install_init`）全部放行该目录，输出一行 `属主是 admin:Users（UID 1000），不是本应用用户（UID 996），但实际可写（fnOS 的 TrimACL 已授权）。继续。`，**全程没有一句 sudo 要求**。
- 同时验证降权有效：以 root 跑、目标是 `root:root 700` 的目录 → `exit=1` 报「成因A」，说明探测不再恒真。

### 10. 数据目录可自定义，默认留在 `@appdata/<app>/data`

**问题**：默认位置在应用数据目录里，空间通常小，而且**安装失败触发平台回滚时可能被一起删**（见 §三 第六轮）。

**结论**：
- 默认位置不变：`/vol<N>/@appdata/<app>/data`（`DATA_DIR_MODE=default`，真实目录，不是链接）；
- 用户可在向导里指到自己的存储空间（`DATA_DIR_MODE=custom`，`var/data` 变符号链接）；
- 设置页提供**三态**：`不修改` / `改到指定目录` / `恢复默认位置`；
- **切换只改指向，不搬数据**（几十 GB 到几 TB 的复制可能几十分钟、中途失败更难收拾）；
- 从默认切走时，原库**改名**为 `data.old-<时间戳>` 保留（同一路径不可能既是真实目录又是指向别处的链接，只能挪开）；
- **回到默认位置时会主动列出 `data.old-*` 的路径、体积、条目数，并打印搬回命令**（含 `cp -a <旧>/. <新>/` 与 `chown`）。

**证据**（真实的用户可见故障）：
- 默认位置建桶 `def-check` → 切到自定义目录 → 再恢复默认 → 应用面对的是新建空库，`GetObject` 返回 **404**；而旧库完整躺在 `data.old-20261027193301/`（**21,379 字节**，桶与对象都在、未损坏）。**没有一处提示告诉用户它去哪了** —— 这就是 v11 补的东西。
- `DATA_DIR_MODE` 必须由**事实**派生（挂载点是链接 → custom；否则比实际路径），不能由「值是不是来自向导」决定。第一版用「两边 `readlink -f` 再比」，自定义目录时链接解析到同一目标 → **永远判 default**，实测立刻暴露。
- 搬回命令里 `cp -a <源>/. <目标>/` 结尾的 `/.` **不能省**：写成 `cp -a <源> <目标>/` 会变成 `<目标>/<源目录名>/`，多套一层，控制台里还是看不见数据。

### 11. 卸载会清凭据、并会移除应用使用的镜像 tag；`install-local` 等于卸载重装

**结论**（三条都是真机结论，用户必须知道）：

| 行为 | 说明 |
|---|---|
| 卸载清凭据 | 配置目录（含 AK/SK）随卸载删除；重装后所有已接入的 S3 客户端会收到 `403 InvalidAccessKeyId` |
| 卸载移除镜像 tag | 实测：卸载后 `docker images` 里 `rustfs/rustfs:1.0.4` 这个 **tag 消失**，只剩 `latest`（同一 image id）。重装时若本地没有该 tag，应用自己拉不动 → 进入待校验状态、约 15 分钟后判失败。**应对：重装前 `sudo docker pull <镜像:tag>`** |
| `install-local` = 卸载再装 | 它会卸掉现有应用再装，凭据重新生成；且它**就地取材于源目录**，源目录权限是 `700` 时包用户执行不了 → `10237 fork/exec … permission denied` |

**证据**：`10237` 的根因是**源目录权限 700**（`deploy/fnos` 与 `cmd` 都是 `drwx------`，继承自创建者的 umask），appcenter 把源目录原样复制到 `/tmp/appcenter.pack.<reqid>/` 再 exec，包用户既进不去也执行不了；而 `install-fpk`（走 fpk 包）会把 `cmd/*` 规范化成 `root:root 755`，所以一直没出问题。**修法两层**：仓库里 `cmd/*` 与目录一律 755/644（`git` 只记可执行位、不记目录权限，所以还要在 `preflight.sh` 里加权限检查）。

---

## 三、真机验证时间线

只列「验了什么 → 抓到什么 → 怎么修」，每轮都能在 `generated/` 下的对应报告里找到原始输出。

| 轮次 | 验了什么 | 抓到的问题 | 怎么修的 |
|---|---|---|---|
| 摸底 | 设备环境、fnpack 能力 | `fnpack build` 失败退出码 0；`manifest.version` 拒 `1.0.0-beta`；官网 1.2.4 下载 404 | 判关键字；版本只用 `x.y.z`/`x.y.z-N`；CI 锁 1.2.3 + sha256 |
| 第一轮（v1） | 骨架原样安装 | **装不上**：包用户（996）访问不了 `root:docker 660` 的 `docker.sock`（`install_init` 硬 fail）；桌面入口 `url: /` 打开是 **XML 403** | `config/privilege` 加 `join-groups: ["docker"]`；入口改为 `/rustfs/console/` |
| 第二轮（v2） | 升级路径 | `docker compose pull` **不走 daemon 的镜像加速** → 换 tag 升级会**静默用旧镜像** | 改 `docker pull` 硬前置 + `image inspect` 校验 + 容器 id 比对 + 回滚 + 审计 |
| 第三轮（v3） | 复验拉取 | 包用户 `docker pull` **必然失败**（缺签名头）；曾把 2.6 秒误判为成功，实为 cache hit | 否决「复制 root 的 docker 配置」；改为「不自己拉，双分支 + 待校验」 |
| 第四轮（v4） | 漂移与审计 | 审计行出现 `unknown unknown`；到期文案的回滚行在 `previous_image` 缺失时**留空**（「改回 ⬜ 后执行」） | 版本列取真值或 `-` + `trigger=drift`；回滚 ref 三级兜底或纯文字指引 |
| 第五轮（v5） | 「无 pending 也能自愈」 | 20 次 `status` 3 秒推满就判死（按次数）；`stop→start` 不执行 `compose up` | 宽限期改墙钟 15 分钟；`start` 自己比对声明 vs 实际；`status` 发现漂移也自动登记 |
| 事故定性 | 安装失败后数据消失 | 平台在 install task 内失败会执行 **`msg=rollback`**，把 `@appdata`/`@appconf`/`@apphome` 一起删（`@appmeta` 幸存）。对照：失败发生在 task **之前**时数据完好；我们的 `uninstall_callback` keep 分支**没有任何 `rm`** | 承认这条不受我们控制；`docs/upgrade-safety.md` + `scripts/backup-data.sh`（备份放 `@app*` 之外） |
| 卸载尝试 | 想用 HTTP API 无头卸载 | 拿不到会话（登录接口不存在，浏览器用长期 cookie）；且**「是否保留数据」不是接口参数，而是应用自己的卸载向导** | 停止无头尝试，改由用户在界面点；`wizard/uninstall` 写清「保留/删除」与「凭据会被清」 |
| v7 符号链接 | 自定义数据目录 | 符号链接挂载**可用**（run/compose 都行）；但自建目录属主 `admin`/755 被 `install_callback` 判为不可写 | 先误以为是权限问题，后来查明是 TrimACL（见 §二-9） |
| 路径校验归因 | 用户 19:11 安装失败 | `install_init` 的 `PROG_PARENT=$(dirname $(dirname $TRIM_APPDEST))` = **`/vol1`**，于是规则 `${PROG_PARENT}/*` 把**整个 `/vol1` 下的用户目录**都当成「程序安装目录」拒掉 | 改成按「路径里出现 `@` 开头的一段」拦平台/应用目录区，只放行本项目自己的 `@appdata/@appconf/@apptemp/@apphome`；16 条路径用例回归 |
| v9 写探测 | 「属主 admin 但可写」 | 三入口全部放行、无 sudo 要求；root 探测确实降权（`root:root 700` → `exit=1`）；探针无残留 | 保留为最终实现 |
| v10 三态 | 设置页能否回默认 | **改不回去**（`wizard_data_dir` 为空 = 「不修改」）；且重复保存会**白重建一次容器** | 加 `wizard_data_mode` 三态；`config_callback` 实现「恢复默认位置」；无变化跳过 `--force-recreate` |
| v11 收尾 | 切回默认后数据看着不见了 | 恢复默认后读 `def-check` = **404**，数据在 `data.old-20261027193301/`（21,379 B）但**无任何提示**；卸载移除镜像 tag | 回到默认时打印 `data.old-*` 路径/体积/条目 + 搬回命令；卸载时打印镜像 tag 提示；顺带拒绝「在设置页改数据子目录名」 |
| v12 图标 | 真实 logo | 源图是 256×256 的**横排 wordmark**（内容框 227×43）；缩到 64px 后内容仅 **56×10**，不可辨 | 4 个图标都生成 + 补 `sRGB` chunk + 尺寸断言；64px 观感问题挂起（见 §五） |
| v16 窗口内登录① | 用户：窗口内登录一直失败 | 先怀疑凭据（`ListBuckets` 200，凭据有效）、再怀疑网关（**网关日志一条 POST 都没有**）——实际是**登录页第三个框「服务器地址」默认 `http://localhost:9000`**，那指的是用户自己电脑。另查明 `NEXT_PUBLIC_SERVER_HOST` 是 **build-time**，运行期 env 注入无效（探针里设置后登录页出现 0 次） | 文档写清「首次要填 `http://<NAS>:<S3端口>`，填一次记住」；不做 sub_filter 注入（hash 文件名 + RSC 流，脆弱） |
| v16 窗口内登录② | 填对服务器地址仍失败 | **CORS**：窗口内 origin 是平台地址（`http://<NAS>:5666`），登录请求直连 S3 端口（跨源），而 S3 API **不返回任何 `Access-Control-*`**（预检 200 但无 CORS 头）→ 浏览器丢弃。镜像里有官方开关 `RUSTFS_CORS_ALLOWED_ORIGINS`（另 `RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS` 默认 `*`）。探针实测：精确源模式返回 `allow-origin`+`allow-methods`+`allow-headers:*`+**`allow-credentials:true`**；`*` 模式**不给** credentials；不匹配源不返回该头（正确）。**另一条路被否决**：把 S3 API 经 nginx 前缀反代做同源 —— SigV4 的 canonical URI 参与签名，剥前缀必 `SignatureDoesNotMatch`，不剥前缀 RustFS 只认根路径 → 404 | 主线加 `RUSTFS_CORS_ALLOWED_ORIGINS`（向导可填「允许访问的来源」，留空回退 `*`）；`settings.env` 落 `CORS_ORIGINS` 便于排查；改它必须重建容器（已纳入 `meta_changed`） |
| v1.0.5 逻辑修复（L5 平台代建豁免） | `.212` **全新机器 + 默认数据位置**安装必失败：`install error 10237` + 「成因B：父目录 /vol1/@appdata 不允许本应用写入（root:root 755）」 | 根因是**我们的 L5 写探测时机太早**：默认位置是 `/vol<X>/@appdata/rustfs-fnos/data`，而**首次安装时 `@appdata/rustfs-fnos` 尚不存在**，最近已存在祖先是 `/vol1/@appdata`（`root:root 755`）→ 包用户不能在里面 mkdir → 判「不可写」。同机旁证：其它应用目录属主都是**各自的包用户**（916/922/967/970/976/977…）→ 说明 `@appdata/<app>` 是**平台在安装过程中**创建并 chown 的。`.64` 一直没踩到，是因为那台的 `@appdata/rustfs-fnos` 早已存在。**结论：这是打包缺陷，不是用户操作问题；上一轮「用默认位置就能绕开」的说法是错的，已更正** | ① **L5a 平台代建豁免**（`install_init`/`config_init` 共用段，逐字相同）：三条件**同时**满足才跳过写探测 —— 目标在**本项目自己的**应用目录下（`allow` 前缀）+ 目标不存在 + 最近已存在祖先**恰为平台根**（`/vol*/@appdata|@appconf|@apptemp|@apphome`）；豁免时 `say` 一句 + `trace` 留痕；**其余情况一律照旧真实写探测**（`root:root 700/755` 仍被拦）。② `install_callback` 在**目录创建后**补一次真实写探测（失败 `fail`，原因写进 `TRIM_TEMP_LOGFILE`）—— 真正的守门人。③ 文案：指向平台目录时报错**明确说“这是我们的问题、请贴日志”并禁止 `chown` 平台目录**；首次安装+默认位置两条提示均指向“不该走到这里”。④ 发布闸改造：`check-image-bump.sh` 新增 `--allow-same-image` + CHANGELOG `packaging-only:` 标记，允许「包版本涨、镜像不变」的**纯打包修订**发布（两种条件缺一仍 FAIL，`image` 变而 `version` 不变仍 FAIL） |
| v1.0.5 权限文案 | 新环境装不上，报「数据目录不可写」 | 根因 = **TrimACL 授权时机**：fnOS 用 TrimACL 给**具体应用用户**授权（`allow uid:<uid> rwxpdDaAeEc inherit:self,file,dir`），而该用户是**安装过程中**才创建的。用户「先在文件管理建目录、后装应用」→ 建目录时用户不存在 → 目录没有对应 ACE → 安装期写探测失败。`.64` 三条实测证据：① `/vol1/1000`（用户空间根）**不可写**、连 mkdir 都失败；② `/vol1/1000/RustFS`（文件管理器建的、属主 `admin:Users`、mode `0`）**有 `allow uid:996` → 写得进去**；③ `/vol1/symlink-test`（`root:root 755`、无 w）**被正确拦下** → 证明 L5 真实写探测判定正确（既不放错也不拦错），**代码逻辑无需修改** | 只改**文案与文档**：① 把「不可写」报错重写成「现象+真实值 / 为什么（TrimACL 时机）/ 三条可粘的路」；② `wizard/install` 与 `wizard/config` 各加一条顺序建议，并把 install 里旧「先建目录再装」的建议**改成「先装默认位置、再改目录」**（否则自相矛盾）；③ `docs/faq.md` 新增「首次安装为什么建议先用默认数据位置」。uid/gid 全部来自运行时 `${TRIM_UID}`/`${TRIM_GID}`，无硬编码 |
| v17.3 形态耦合 | 有人把注入脚本写成逗号连写（`var k=…,p = 9200,…`，JS 语义等价） | **渲染会静默失效**：`render_gateway_conf` 的正则是 `s/(var p = )[0-9]+;/${api};/g`，只认「单独一条语句、分号结尾」的 `var p = <数字>;`；逗号形态匹配不到 → **装出来的端口停在模板值 9200**，而安装流程不会报错。实测：把逗号形态喂给该函数 → `rc=1`、`p` 仍是 `9200`。这类“看起来只是排版”的差异最难查 | 定下**形态契约**：`var p = <数字>;` 必须是单独语句、分号结尾（写进 `gateway.conf` 注释，防止后人“优化”回逗号）；`render_gateway_conf` 增加**三段断言**：① 数量为 0 时区分「文件不对」与「写法不对」，后者 `warn` 出可操作提示；② 替换前后数量必须相等（漏一个就报错）；③ 目标端口 ≠ 模板值时，渲染后不得残留 `var p = 9200;`（防“部分替换”）。**没有采纳**“兼容两种形态”的宽松正则：那等于默认允许写法漂移，而单形态 + 断言能在安装时就把错的挡下来 |
| v17.2 注入策略修正 | 用户反馈「每次重装都要去设置里清一次服务器地址才可用」 | 真因不是浏览器：localStorage 按 **origin 持久保存**，旧版注入只在「没有值」时写（`if(!s||s.getItem(k))return;`），所以重装后端口变了、旧值还在，注入一直被跳过 → 用旧端口登录失败 → 用户手清一次才写对。**这是 v17 的设计缺陷，不是偶发** | v17.2 改成按 hostname 判断：① 无值 → 写；② 同 hostname 但端口不同 → **覆盖**（重装/改端口场景）；③ hostname 不同 → **不动**（尊重用户指向别的机器/域名）；④ 值解析失败 → 覆盖。脚本里 `var p = <数字>;` 保持「单独一条语句、分号结尾」，否则 `render_gateway_conf` 的 sed 匹配不到（逗号连写会漏） |
| v17.1 注入验证 | 真机验「自动填服务器地址」是否成立 | 三条实测结论：① `sub_filter` 在 `nginx:1.27-alpine` 上**可用**（`nginx -t` 通过 + 实测替换成功），首页 `</head>` **恰好 1 次**，且**必须**保留 `proxy_set_header Accept-Encoding ""`（否则上游 br/gzip 压缩导致匹配不到）；② `localStorage["rustfs-server-host"]` 存的是**纯 URL 字符串**（控制台里 `new URL(e)` 直接解析、全程无 `JSON.parse`），且只取 `protocol//host`、**路径被丢弃** → 注入不需要带 `/app/rustfs-fnos` 前缀；③ **坑：自查必须走 unix socket** —— `curl http://127.0.0.1:<控制台端口>/…` 不经过 gateway，永远返回 0，会误判成「注入失败」（第一轮就是这么被绕进去的） | 删掉 `sub_filter_types`（默认已含，留着只会产生 duplicate MIME 警告）；给 `/auth/login/` 也加一份精确注入；`render_gateway_conf` 改为**全量替换 + 数量断言**（三个 location 各一份，漏一个就报错而不是静默）；文档自查命令统一改成 `--unix-socket` 形态 |
| v15 内嵌落地 | 用户确认 probe1 可窗口内打开 | 完整踩坑链：`type:iframe` 无网关字段 → 卡死；加字段+sidecar → **502**（nginx 非 root 缺 `/var/cache/nginx` 写权限，`[emerg]` 无限重启、socket 从不生成）；给 gateway 加两个 `tmpfs` → 起来、`via-socket` 200、**用户确认窗口内可打开**。另查明平台转发时**保留** `/app/rustfs-fnos` 前缀（nginx 请求行原样），且 nginx 不改写 URI | 主线正式化：`RUSTFS_CONSOLE_PREFIX` + gateway sidecar + `gateway*` 入口字段；`docs/faq.md` 改写；`licensing`/`NOTICE` 补 nginx |
| v13 入口改 iframe | 用户实测：点桌面图标 | **卡死/闪退**，但容器仍 running、直连 `<console>/rustfs/console/` 完全正常，`/health/ready` 200。原以为「没有 `X-Frame-Options` 就能嵌」，实测证明限制在**平台 iframe 入口的实现方式**，不在 HTTP 头 | 入口改回 `"type": "url"`（v12 形态），并把这条写成定论（`docs/faq.md` + 本文 §五） |
| **CI 首跑**（不是真机抓到的，是 GitHub Actions 抓到的） | 仓库首次 push 触发 `fpk-ci` | 第 6 步「结构预检」红：`§5b` 报 9 个 `cmd/*` **缺少 others 可执行位**，而**本地跑 preflight 是全绿的**。根因：本工作区 git 的 **`core.filemode=false`**，`chmod 755` 不被记录，入库是 `100644`；CI 从仓库克隆，自然不可执行。这类问题**只有在「从仓库克隆」时才暴露**，本地怎么试都发现不了 | `git config core.filemode true` + `git update-index --chmod=+x`（13 个文件），核对 `git ls-files -s` 全为 `100755`。现在 `docs/build.md` 有专门一节讲这个陷阱 + 「干净克隆验证」命令 |

---

## 四、发布纪律

写给以后发版的人。**这些不是建议，是踩过坑之后的最低要求。**

1. **每次发版必须换一个新的镜像 tag**，不要复用同一个 tag。
   - 原因：我们只比对「镜像引用字符串」。上游若把同一 tag 重推了新内容（digest 变了），字符串完全一样，我们**检测不到**，docker 的默认 `pull_policy: missing` 也不会重拉。这是已知盲区，没有自动手段（没权限比对 registry）。
2. **发版前必跑三件事**：

   ```bash
   bash scripts/stamp-manifest.sh deploy/fnos --version <x.y.z>
   bash scripts/preflight.sh deploy/fnos          # 期望 FAIL=0
   bash scripts/check-image-bump.sh deploy/fnos --baseline-git <上一个 tag>
   cd deploy/fnos && fnpack build                  # 只看 "Packing successfully"
   # 最后必须回读：
   tar -xzOf rustfs-fnos.fpk manifest | grep -E '^[[:space:]]*version[[:space:]]*='
   ```

   `preflight.sh` 里有两节容易被忽略但很关键：**权限节**（目录 `755`、`cmd/*` 可执行，否则 `install-local` 必踩 `10237`）与**两份脚本一致性节**（`data-dir-check` / `writable-probe` 段在多个脚本里必须逐字相同，否则逻辑会各改一份慢慢走偏）。
3. **Release 资产**：`<appname>-<version>-<platform>.fpk` + `SHA256SUMS` + `build-info.json`（含 commit、fnpack 版本与 sha256、镜像 ref/digest、构建时间）。Release 正文即 changelog。
4. **CI 工具链**：`fnpack 1.2.3`（官网可下载，sha256 `54b97fa7b70968c4d05c79840f5daeff508957d0bb2062fdb0376d00d9615c93`），runner **必须 x86_64**（官网 `linux-arm64` 实测 404）。1.2.4 官网无下载，团队本地那份只用于对照。
5. **仓库里 `manifest.version` 永远保持 `0.0.0`**。它被 stamp 改动后要改回来，别提交真实版本号 —— 否则「版本真源」就有两个。

---

## 五、已知限制与未完成项（诚实清单）

| # | 限制 | 现状 / 影响 |
|---|---|---|
| 1 | **64px 图标不可辨** | 源 logo 是横排 wordmark（内容 227×43），缩到 64px 剩 56×10，看起来是一条蓝线。256px 没问题。要彻底解决需一张**方形图形 logo**（或只取首字母 R 的构图，属于改设计） |
| 1b | **桌面内弹窗（`type: iframe`）：已解决（v15）** | 结论：**可以在 fnOS 窗口内打开**，方案 = 平台网关 + 应用提供 `app.sock` + 上游前缀开关 `RUSTFS_CONSOLE_PREFIX=/app/rustfs-fnos` + 一个极小 nginx sidecar。踩坑链（按发生顺序）：① 直接 `type:iframe` 无网关字段 → 卡死（平台加载 `/app/<app>` 没有内容）；② 加 gateway 字段 + sidecar → **502**，因为 nginx 以非 root 运行、`/var/cache/nginx` 写不了 → `[emerg] mkdir failed` → 无限重启 → socket 从不生成；③ 给 gateway 加两个 `tmpfs` → 起来、socket 生成、via-socket 200、用户确认**窗口内能打开**。已知代价：多一个 `nginx:1.27-alpine` 容器（挂了只影响窗口内打开，S3/控制台直连不受影响）。启动 socket 权限为 `0666`（平台连接权限不是瓶颈——`trim.preview` 的 socket 是 root:root 0660 也能弹窗），如需收紧可后续处理 |
| 2 | **「Web UI 升级时平台是否执行 `compose up`」未直接证实** | 我们已改成**不依赖**它：`main start` / `status` 自己比对声明与实际镜像，能自愈。但平台行为本身仍无定论 |
| 3 | **上游同 tag 重推检测不到** | 见 §四-1。只能靠纪律 |
| 4 | **数据目录切换不自动搬数据** | 设计选择（大目录复制慢、失败难收拾）。代价：切走后旧数据在 `data.old-*`，需要用户按命令搬 |
| 5 | **`install_type` / `install_dep_apps` 未声明** | 不写 `install_type` = 让用户在安装时选存储位置（写 `root` 会落到系统分区）；不写 `install_dep_apps` = 无法确认 docker 是可声明的依赖名，改由 `install_init` 运行期检测并降级为 WARN |
| 6 | `os_min_version` / `os_max_version` 未声明 | 等同「不做兼容性承诺」，文档里必须写明「仅在实测版本上验证过」 |
| 7 | 宽限期 15 分钟是写死默认 | 可在 `pending_verify.env` 里手工改 `DEADLINE_MINUTES`，未来可做成应用设置项 |
| 8 | 安装结果日志含账号明文（密码不回显） | 日志落 `/var/log/apps/<app>.log`（root 可读）。密码不回显是有意为之 |
| 9 | 卸载会清凭据、会移除镜像 tag | 见 §二-11；只能靠文档与提示，不做「偷偷保 tag」的补偿（会留僵尸镜像） |
| 10 | 仅 x86 | `manifest.platform = x86`；镜像本身是双架构，但 ARM 未实测，不发 |

---

## 六、如果你现在要改这个项目，先读这 5 段

1. **别相信退出码，只相信关键字。** `fnpack build` 失败时 `exit=0`；打包、发布、CI 一律用 `Packing successfully` 判成败，打包后**解包回读 `version`**。同理：`preflight.sh` 的 `FAIL=` 行、`check-image-bump.sh` 的退出码（0/1/2）也是判据。
2. **`manifest.version` 不要手改。** 仓库里恒为 `0.0.0`，真实版本由 tag 经 `stamp-manifest.sh` 注入。手改会造出两个版本真源，下一次发版就对不上镜像 tag。
3. **动数据目录之前，先想清楚「谁把它挪开」。** 同一路径不可能既是真实目录又是指向别处的链接；我们选择「改名成 `data.old-<时间戳>` 保留 + 打印搬回命令」，而不是自动搬。任何改动都**不能删**用户数据，也不能让它「看起来消失」——日志里必须给出路径。
4. **不要用「属主」判断可写性。** fnOS 的 TrimACL 会给应用 uid 单独授权，属主是 `admin` 的目录实际可写；判断必须是**以应用身份真实写一次**（root 身份要先 `setpriv` 降权）。改这段之前先读 §二-9，否则会把用户挡在门外。
5. **任何「看起来更省事」的写法，先问一句：变量从哪来？** compose 拿不到 `settings.env`；包用户拿不到镜像站签名头；`install-local` 不会规范化权限；`restart` 不会重新解析符号链接。这四条各对应一次真机事故 —— 在写「顺手优化」之前，先回 §二 找到对应那条，确认它今天仍然成立。

---

## 附：路径与变量速查

| 名称 | 典型值（因设备而异） | 说明 |
|---|---|---|
| `TRIM_APPDEST` | `/vol1/@appcenter/rustfs-fnos/target` | 程序区，升级会被整体替换，**不放数据** |
| `TRIM_PKGVAR` | `/vol1/@appdata/rustfs-fnos` | 数据区；默认数据目录是它下面的 `data/` |
| `TRIM_PKGETC` | `/vol1/@appconf/rustfs-fnos` | 配置区（`settings.env`、`credentials/`），**卸载会被清** |
| `TRIM_PKGTMP` | `/vol1/@apptemp/rustfs-fnos` | 临时区（配置备份等） |
| `TRIM_UID` / `TRIM_GID` | `996` / `901` | 容器与探测使用的运行身份 |
| 数据目录（默认） | `/vol1/@appdata/rustfs-fnos/data` | 真实目录，`DATA_DIR_MODE=default` |
| 数据目录（自定义） | 例 `/vol1/1000/RustFS` | `var/data` 是指向它的符号链接，`MODE=custom` |
| 搁浅旧库 | `/vol1/@appdata/rustfs-fnos/data.old-20261027193301` | 切走时改名保留；**不自动删除** |
| 控制台 | `http://<NAS-IP>:9201/rustfs/console/` | `/` 返回 XML 403，是正常的 |
| 健康探针 | `http://<NAS-IP>:9200/health/ready` | 200 = 就绪，503 = 未就绪 |
