#!/usr/bin/env python3
"""生成 build-info.json —— Release 附带的构建溯源信息。

字段说明：
  asset_sha256   本次 .fpk 的 sha256（与 SHA256SUMS 同源）
  image.ref      compose 里声明的镜像引用（tag 固定）
  image.digest   registry 侧 manifest digest（CI 里用 docker manifest inspect 取，取不到为 null）
  image.id       镜像 image id —— 需在设备侧 docker pull 后才有；CI 不拉镜像，恒为 null
  fnpack         CI 使用的 fnpack 版本与二进制 sha256（版本漂移会让产物不可复现）

用法（CI 里就是这样调的）：
  python3 scripts/make-build-info.py --asset rustfs-fnos-1.0.4-x86.fpk \
      --image-ref docker.io/rustfs/rustfs:1.0.4 --image-digest sha256:... --out build-info.json
"""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def now_utc() -> str:
    try:
        return subprocess.check_output(
            ["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except Exception:
        return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--asset", required=True, help="产物文件名（当前目录下的 .fpk）")
    ap.add_argument("--image-ref", default="", help="compose 里声明的镜像引用")
    ap.add_argument("--image-digest", default="", help="registry 侧 digest（可为空）")
    ap.add_argument("--out", default="build-info.json")
    a = ap.parse_args()

    if not os.path.exists(a.asset):
        print(f"输入非法：找不到产物 {a.asset}", file=sys.stderr)
        return 1

    info = {
        "appname": os.environ.get("APPNAME", ""),
        "version": os.environ.get("VERSION", ""),
        "platform": os.environ.get("PLATFORM", ""),
        "asset": a.asset,
        "asset_sha256": sha256_file(a.asset),
        "asset_size_bytes": os.path.getsize(a.asset),
        "git_tag": os.environ.get("GITHUB_REF_NAME", ""),
        "git_commit": os.environ.get("GITHUB_SHA", ""),
        "git_commit_short": (os.environ.get("GITHUB_SHA") or "")[:7],
        "fnpack": {
            "version": os.environ.get("FN_PACK_VERSION", ""),
            "sha256": os.environ.get("FN_PACK_SHA256", ""),
        },
        "image": {
            "ref": a.image_ref or None,
            "digest": a.image_digest or None,
            "id": None,
            "note": "image id 需在设备侧 docker pull 后才有；CI 不拉镜像（约 300MB），故为 null；"
                    "有 digest 时可作为同一性依据，与设备侧 `docker image inspect --format {{.Id}}` 对照需另行取。",
        },
        "build": {
            "runner_os": os.environ.get("RUNNER_OS", ""),
            "runner_arch": platform.machine(),
            "built_at_utc": now_utc(),
            "workflow_run": "{}/{}".format(
                os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_RUN_ID", "")
            ),
        },
    }

    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"已生成 {a.out}（{a.asset} → {info['asset_sha256']}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
