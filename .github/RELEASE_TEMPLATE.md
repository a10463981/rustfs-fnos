## RustFS <VERSION>

> 上游版本：RustFS <UPSTREAM_VERSION>（本包封装自其官方镜像）

### 安装

1. 到下方 Assets 下载对应架构的包（当前仅 x86）：`rustfs-fnos-<VERSION>-x86.fpk`
2. 同页下载 `SHA256SUMS`
3. 校验（**建议做**）：
   - Linux：`sha256sum -c SHA256SUMS`
   - macOS：`shasum -a 256 -c SHA256SUMS`
   - Windows：`Get-FileHash .\rustfs-fnos-<VERSION>-x86.fpk -Algorithm SHA256`
4. 飞牛 fnOS → 应用中心 → 手动安装 → 选择该 `.fpk`
5. 装完点桌面图标，或访问 `http://<你的NAS地址>:9201`

详细步骤见 [docs/install-fnos.md](docs/install-fnos.md)。

### 下载校验值

```text
<粘贴 SHA256SUMS 内容>
```

### 本版要点

<!-- 面向用户的变化，不要贴 commit 列表 -->

-

### 升级注意

<!-- 会不会动数据、要不要先备份、能不能回退；首版写"首次安装，无升级路径" -->

- 数据目录：升级不会覆盖数据
- 建议升级前自行备份数据目录（对象存储里的东西通常没有第二份）

### 已知问题

- 仅支持 x86（amd64）
- 安装时需要设备能访问容器镜像仓库；无外网环境需先手工 `docker load` 导入镜像
- 未提供 HTTPS，需要请自行加反向代理
- 单机单盘部署不支持原地扩容（上游限制），扩容需新建实例并迁移数据

### 兼容性

| 项 | 本版 |
|---|---|
| fnOS 版本 | <!-- 待回填：实测通过的版本 --> |
| 架构 | x86（amd64） |
| 上游 RustFS | <UPSTREAM_VERSION> |
| 容器镜像 | `rustfs/rustfs:<UPSTREAM_VERSION>` |

### 构建信息

- commit：`<sha>`
- 打包工具：`fnpack 1.2.3`
- 构建来源：GitHub Actions（本仓库 tag `<TAG>`）
- 构建时间：`<ISO8601>`

<!--
发布前检查（勾掉后删除本段）：
[ ] 对外文案统一写「RustFS」，不加限定词；NOTICE 与 docs/licensing.md 里的上游归属、Apache-2.0、商标声明必须完整保留（许可义务，不得删）
[ ] version 与 tag 一致（tag v1.0.4 → version 1.0.4）
[ ] 资产含 .fpk + SHA256SUMS + build-info.json，且 SHA256SUMS 里列全了所有 .fpk
[ ] 本说明里的 sha256 与 SHA256SUMS 一致
[ ] 已在干净设备上装过一次并跑通建桶/上传/下载
[ ] 草稿 → 核对无误 → 再点发布
-->
