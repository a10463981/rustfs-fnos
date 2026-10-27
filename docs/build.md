# 构建与发布

本应用是 fnOS 的 fpk 包：`deploy/fnos/` 是 fnpack 项目目录（打进 `.fpk` 的东西都在这里），仓库根的 `scripts/` 是发布前的检查脚本。

> ## ⚠️ 动手之前先读这一条：**直接 `fnpack build` 会得到 `version = 0.0.0` 的包**
>
> 这不是 bug。仓库里的 `deploy/fnos/manifest` **恒为占位值 `version = 0.0.0`**，真实版本由 **git tag** 在构建时注入（唯一真源）。所以：
>
> | 路径 | 谁负责注入版本 | 你会得到 |
> |---|---|---|
> | **CI（推荐）**：推 `v1.2.3` tag | `fpk-release.yml` 自动跑 `stamp-manifest.sh` | `version = 1.2.3` 的包 + Release |
> | **本地手打** | **你**，必须先跑 `stamp-manifest.sh` | 跑过 → `1.2.3`；**没跑 → `0.0.0`** |
>
> 本地正确姿势（两步，缺一不可）：
>
> ```bash
> # ① 注入版本（把 1.0.4 换成你要发的版本）
> bash scripts/stamp-manifest.sh deploy/fnos --version 1.0.4
>
> # ② 再打包
> cd deploy/fnos && fnpack build
> ```
>
> **打完包必须回读确认版本真的进去了**（一条命令，直接粘）：
>
> ```bash
> tar -xzOf deploy/fnos/rustfs-fnos.fpk manifest | grep -E '^[[:space:]]*version[[:space:]]*=' >   && echo "↑ 这一行必须是你要发的版本；如果是 0.0.0 说明忘了 stamp，这个包不能发"
> ```
>
> 想让它变成「不对就报错」的形式（CI 里用的就是这种）：
>
> ```bash
> got="$(tar -xzOf deploy/fnos/rustfs-fnos.fpk manifest \
>        | awk -F= '/^[[:space:]]*version[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}')"
> [ "$got" = "1.0.4" ] && echo "OK: 包内 version=$got" || { echo "FAIL: 包内 version=$got，期望 1.0.4（未 stamp？）"; exit 1; }
> ```
>
> **不要用 `unzip -p … | grep version` 这类靠猜的方式**：`.fpk` 是 **tar.gz**，`manifest` 是包内的顶层文件；上面这条命令就是唯一口径，CI 也用它。
>
> 真机踩过的坑：未 stamp 直接打包，装到 NAS 上应用中心显示 `0.0.0`，与镜像 tag `1.0.4` 对不上。

## 一次完整构建

```bash
# 1) 打包（产物落在当前工作目录，文件名固定是 <appname>.fpk）
cd deploy/fnos
fnpack build
ls -l rustfs-fnos.fpk
```

**判定成败只看输出关键字**：必须出现

```
Packing successfully. The output file rustfs-fnos.fpk can be found in the working directory.
```

`fnpack build` 失败时**退出码仍然是 0**（实测），所以任何脚本都不能用 `set -e` + 退出码判断，必须 grep 上面这句。

```bash
# 2) 结构预检（必需文件 / manifest / JSON / 图标尺寸 / 硬编码 / 真跑一次 build）
bash scripts/preflight.sh deploy/fnos        # 期望 FAIL=0 WARN=0
```

## 发布前必过的第二道闸：`scripts/check-image-bump.sh`

### 它防的是什么

`manifest.version` 涨了、但 compose 里 `image:` 没换，是**运行时发现不了**的错误：

真机实测过一次 —— `version` 从 1.0.8 涨到 1.0.9、`image:` 保持 `rustfs/rustfs:1.0.x` 不变，应用照 compose 声明执行，容器 id 等于"目标"id，于是日志里写的是「升级完成」，用户以为升级了，跑的其实是同一个镜像。

所以这条必须在**打包前**拦。

### 用法

```bash
# ① 有 git 历史：拿上一个发布 tag 当基线（推荐，CI 里也用它）
bash scripts/check-image-bump.sh deploy/fnos --baseline-git v1.0.4

# ② 没有 git，但手上有上一版的项目目录
bash scripts/check-image-bump.sh deploy/fnos --baseline ../rustfs-fnos-1.0.4

# ③ 只有上一版 compose 文件（只比 image，版本列会提示读不到）
bash scripts/check-image-bump.sh deploy/fnos --baseline ../1.0.4/docker-compose.yaml

# ④ 真的没有基线（例如首次发版、或从别处接手）：降级为只告警
bash scripts/check-image-bump.sh deploy/fnos --allow-no-baseline

# 项目目录不在 deploy/fnos 时，自己指定前缀
bash scripts/check-image-bump.sh <目录> --baseline-git v1.0.4 --project-prefix <相对仓库根的路径>
```

### 退出码约定

| 退出码 | 含义 | 发布流程里的处理 |
|---|---|---|
| `0` | 通过（可能带 WARN） | 继续 |
| `1` | **断言失败**（版本与镜像没同步变化 / 用了 `:latest` / 无可用基线） | **停止发布** |
| `2` | 用法错误（参数缺失、目录不存在、两个基线参数同时给） | 修命令后重跑 |

### 它检查的四件事

1. `manifest.version` 变了 → `image:` 也必须变；
2. `image:` 变了 → `manifest.version` 也必须变（否则应用中心不认为有更新）；
3. `image:` 不许用 `:latest`，必须有明确 tag 或 `@sha256:` digest；
4. 两者都没变 → 只 WARN（"重打包同一内容"，仅在改脚本/向导/图标时允许）。

### 没有 git 基线时怎么降级

- **首选**：保留上一版的项目目录（或至少一份 `docker-compose.yaml`），用 `--baseline <路径>`。这条最稳，不依赖 git 状态。
- **次选**：`--baseline-git <tag>`。注意 CI 里 `actions/checkout` 默认是浅克隆，取不到旧 tag，需要 `fetch-depth: 0`。
- **兜底**：`--allow-no-baseline`。它把"无法断言"降级为 WARN，**但 `:latest` 之类的硬错误仍然 FAIL**。这是给"确实没有历史"的场景（首次发版、接手别人仓库）留的出口，不要日常使用。
- 无论哪种降级，`0` 退出都**不等于**"版本与镜像确实同步变了"——只是"没能检查"。发布人要在 PR 描述里写清用了哪种降级方式。

### 建议的发布顺序

```bash
cd deploy/fnos && fnpack build          # 关键字判定
cd - && bash scripts/preflight.sh deploy/fnos
bash scripts/check-image-bump.sh deploy/fnos --baseline-git "$(git describe --tags --abbrev=0)"
sha256sum deploy/fnos/rustfs-fnos.fpk   # 与产物一起发布
```

## 已知盲区（脚本拦不住的）

**上游把同一个 tag 重推了新内容（tag 不变、digest 变）** —— `version` 与 `image:` 都没变，`check-image-bump.sh` 只能看到字符串没变；docker 的默认 `pull_policy: missing` 也不会重拉；我们也没有权限去比对该 tag 在 registry 上的当前 digest。

唯一可靠的做法是**发布纪律：每次发版换新 tag，不复用旧 tag**（例如 `1.0.4` → `1.0.5`，而不是把 `1.0.4` 重新推一遍）。
