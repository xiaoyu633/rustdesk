#!/usr/bin/env bash
# ============================================================
# RustDesk 客户端配置注入脚本（v2 — 修正版）
# ============================================================
# 重要：libs/hbb_common 是 Git Submodule！
#   必须先用 `git clone --recursive` 拉取，否则 config.rs 不存在。
#
# 重要：不要用 custom.txt 方案！
#   custom.txt 需 RustDesk 官方私钥签名（sign::verify），裸文本会被丢弃。
#   唯一可靠路径 = 直接改源码常量。
#
# 用法：bash scripts/inject-config.sh [配置文件] [源码目录]
# ============================================================
set -euo pipefail

CONFIG_FILE="${1:-config/custom.txt}"
SOURCE_DIR="${2:-source}"

echo "=================================================="
echo " RustDesk 客户端配置注入 v2"
echo "=================================================="
echo "配置文件: $CONFIG_FILE"
echo "源码目录: $SOURCE_DIR"
echo ""

# ---------- 读取配置 ----------
get_val() {
  local key="$1" default="$2"
  local val
  val=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | xargs || true)
  echo "${val:-$default}"
}

RD_SERVER=$(get_val "RENDEZVOUS_SERVER" "")
RD_API_OVERRIDE=$(get_val "API_SERVER" "")
RD_KEY=$(get_val "KEY" "")
RD_APPNAME=$(get_val "APP_NAME" "RustDesk")

if [ -z "$RD_SERVER" ]; then
  echo "❌ RENDEZVOUS_SERVER 未配置，退出"
  exit 1
fi
if [ -z "$RD_KEY" ]; then
  echo "❌ KEY 未配置（hbbs 公钥），退出"
  exit 1
fi

echo "ID/中继服务器 : $RD_SERVER"
echo "API 服务器    : ${RD_API_OVERRIDE:-(自动推导)}"
echo "Key           : ${RD_KEY:0:24}..."
echo ""

# ---------- 定位源码（关键：submodule 路径）----------
CFG="$SOURCE_DIR/libs/hbb_common/src/config.rs"
if [ ! -f "$CFG" ]; then
  echo "❌ 未找到 $CFG"
  echo ""
  echo "原因：libs/hbb_common 是 Git submodule，clone 时必须加 --recursive。"
  echo "正确命令：git clone --depth 1 --recursive --branch <ver> https://github.com/rustdesk/rustdesk.git source"
  echo ""
  echo "当前 libs/hbb_common 目录内容："
  ls -la "$SOURCE_DIR/libs/hbb_common" 2>/dev/null || echo "  (目录不存在)"
  exit 1
fi
echo "✅ 找到源码文件: $CFG"
echo ""

# ---------- 注入前快照 ----------
echo "--- 注入前 ---"
grep -nE 'pub const (RENDEZVOUS_SERVERS|RS_PUB_KEY)' "$CFG" || true
echo ""

# ---------- 执行注入 ----------
# 用 python 保证跨平台（windows runner 的 sed 行为不同）
python3 - "$CFG" "$RD_SERVER" "$RD_KEY" <<'PYEOF'
import re, sys, io

# Windows console defaults to cp1252/GBK; force UTF-8 to avoid UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

path, server, key = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
orig = s

# 1) RENDEZVOUS_SERVERS, e.g. &["rs-ny.rustdesk.com"]
pat_servers = re.compile(
    r'pub const RENDEZVOUS_SERVERS:\s*&\[&str\]\s*=\s*&\[[^\]]*\]\s*;'
)
s, n1 = pat_servers.subn(
    f'pub const RENDEZVOUS_SERVERS: &[&str] = &["{server}"];', s)

# 2) RS_PUB_KEY, e.g. "OeVuKk..."
pat_key = re.compile(
    r'pub const RS_PUB_KEY:\s*&str\s*=\s*"[^"]*"\s*;'
)
s, n2 = pat_key.subn(
    f'pub const RS_PUB_KEY: &str = "{key}";', s)

if s == orig:
    print("[FAIL] no substitution happened; source layout may have changed")
    print("       check that config.rs still contains RENDEZVOUS_SERVERS / RS_PUB_KEY")
    sys.exit(1)

open(path, 'w', encoding='utf-8').write(s)
print(f"[OK] RENDEZVOUS_SERVERS replaced: {n1}")
print(f"[OK] RS_PUB_KEY replaced: {n2}")

if n1 == 0:
    print("[FAIL] RENDEZVOUS_SERVERS not replaced - client would connect to official servers")
    sys.exit(1)
if n2 == 0:
    print("[FAIL] RS_PUB_KEY not replaced - encrypted handshake would fail")
    sys.exit(1)
PYEOF

echo ""
echo "--- 注入后 ---"
grep -nE 'pub const (RENDEZVOUS_SERVERS|RS_PUB_KEY)' "$CFG"
echo ""

# ---------- 可选：强制 API 服务器为 https 地址 ----------
if [ -n "$RD_API_OVERRIDE" ]; then
  echo "=================================================="
  echo " 注入 API 服务器（覆盖自动推导逻辑）"
  echo "=================================================="
  COMMON="$SOURCE_DIR/src/common.rs"
  if [ -f "$COMMON" ]; then
    python3 - "$COMMON" "$RD_API_OVERRIDE" <<'PYEOF'
import re, sys, io
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

path, api = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()

# Hardcode the final fallback inside get_api_server_
# before: "https://admin.rustdesk.com".to_owned()
# after:  "<our API>".to_owned()
old = '"https://admin.rustdesk.com".to_owned()'
if old in s:
    # only that occurrence inside get_api_server_ (unique in file)
    s = s.replace(old, f'"{api}".to_owned()')
    open(path, 'w', encoding='utf-8').write(s)
    print(f"[OK] API fallback set to {api}")
else:
    print("[WARN] admin.rustdesk.com fallback not found, skipped")
PYEOF
    echo ""
    grep -n "admin.rustdesk.com\|fuyou135" "$COMMON" | head -5 || true
  else
    echo "⚠️  未找到 $COMMON，跳过 API 覆盖"
  fi
  echo ""
fi

# ---------- 最终校验 ----------
echo "=================================================="
echo " 校验"
echo "=================================================="
if grep -q "$RD_SERVER" "$CFG"; then
  echo "✅ 服务器地址已写入源码"
else
  echo "❌ 服务器地址未写入源码！构建产物将是原版客户端"
  exit 1
fi
if grep -q "$RD_KEY" "$CFG"; then
  echo "✅ KEY 已写入源码"
else
  echo "❌ KEY 未写入源码！"
  exit 1
fi

echo ""
echo "=================================================="
echo " 注入完成 —— 可以开始编译"
echo "=================================================="
