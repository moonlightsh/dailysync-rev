#!/usr/bin/env bash
#
# Garmin 同步启动脚本 (供 crontab / 手动调用)
#
# 用法:
#   ./run_sync.sh                     # 默认: 同步 中国区 -> 国际区 (sync_cn)
#   ./run_sync.sh sync_cn             # 同步 中国区 -> 国际区
#   ./run_sync.sh sync_global         # 同步 国际区 -> 中国区
#   ./run_sync.sh migrate_cn          # 迁移历史: 中国区 -> 国际区
#   ./run_sync.sh migrate_global      # 迁移历史: 国际区 -> 中国区
#
# 关键点:
#   - 加载 .env (项目未接 dotenv, 必须手动 source)
#   - 用 flock 防止上一次任务未结束时重复启动 (重复登录会加剧 429)
#   - 复用 db/garmin.db 中的 session, 避免每次密码登录被限流
#   - 直接调 ts-node, 不走 yarn (项目是 Yarn 3, yarn sync_cn 会因 lockfile 校验失败)

set -euo pipefail

# ---- 脚本所在目录 (保证 cron 里也能定位) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---- 可选: 代理设置 ----
# 国外服务器可直连, 通常不需要. 如需代理, 取消下面注释并改成实际端口.
# export https_proxy="http://127.0.0.1:7890"
# export http_proxy="http://127.0.0.1:7890"

# ---- 参数 -> 目标脚本 ----
TARGET="${1:-sync_cn}"
case "$TARGET" in
  sync_cn)        ENTRY="src/sync_garmin_cn_to_global.ts" ;;
  sync_global)    ENTRY="src/sync_garmin_global_to_cn.ts" ;;
  migrate_cn)     ENTRY="src/migrate_garmin_cn_to_global.ts" ;;
  migrate_global) ENTRY="src/migrate_garmin_global_to_cn.ts" ;;
  *)
    echo "未知任务: $TARGET" >&2
    echo "可选: sync_cn | sync_global | migrate_cn | migrate_global" >&2
    exit 2
    ;;
esac

# ---- 前置检查 ----
if [[ ! -f ".env" ]]; then
  echo "[$(date '+%F %T')] 错误: 找不到 .env 文件 (需在 $SCRIPT_DIR 下配置账号)" >&2
  exit 1
fi

TS_NODE="./node_modules/.bin/ts-node"
if [[ ! -x "$TS_NODE" ]]; then
  echo "[$(date '+%F %T')] 错误: 未找到 ts-node, 请先在服务器执行 npm install / yarn install" >&2
  exit 1
fi

# ---- 加载 .env ----
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ---- 执行 (带并发锁) ----
# flock: 同一时刻只允许一个同步任务运行; 拿不到锁就直接退出, 不阻塞、不排队.
run() {
  echo "[$(date '+%F %T')] 开始任务: $TARGET ($ENTRY)"
  "$TS_NODE" "$ENTRY"
  local code=$?
  echo "[$(date '+%F %T')] 任务结束: $TARGET, 退出码=$code"
  return $code
}

LOCK_FILE="/tmp/dailysync_${TARGET}.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "[$(date '+%F %T')] 上一次 $TARGET 任务仍在运行, 本次跳过" >&2
    exit 0
  fi
  run
else
  # 兜底: 无 flock (如 macOS) 时不加锁直接跑
  run
fi
