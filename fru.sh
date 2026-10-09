#!/bin/bash
# ============================================================
# fru.sh —— 整机 FRU 信息读取（型号 / 序列号，供验收记录表填写）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   sudo bash fru.sh                        # 只看整机 FRU（型号 + 序列号 + 完整明细）
#   sudo bash fru.sh --sn SN0001            # 顺便与录入的 SN 比对（不一致只告警）
#   SERVER_SN=SN0001 sudo bash fru.sh       # 同上，走环境变量
#   sudo bash fru.sh --help                 # 打印这段帮助
#
#   ★ 没有必填参数。不给 --sn 就跳过一致性比对，只把 FRU 读出来。
#
#   【典型输出】
#     整机型号:    S2600WFT
#     整机序列号:  SYS-SN-0001
#     SN一致性: 人工录入与BMC FRU一致
#     【判定】PASS —— 已读到整机型号与序列号
#
# ---- 二、参数一览 ----
#   【必给】无
#   【可选】
#     -s SN / --sn SN     人工录入的整机序列号，用于与 BMC FRU 比对
#                         不给则跳过比对（不影响读取型号/序列号）
#   【有默认值】
#     -h / --help         打印本段帮助
#
# ---- 三、环境变量 ----
#     SERVER_SN=SN0001    人工录入的整机序列号；等同 --sn
#
# ---- 四、它做什么 ----
#   读 `ipmitool fru` 里**非 PSU 段**（整机 / 主板 / 机箱），给出：
#     ① 整机型号（优先 Product Name，回退 Board Product）
#     ② 整机序列号（优先 Product Serial，回退 Chassis Serial，再回退 Board Serial）
#     ③ 完整 FRU 明细（排除 PSU 段，PSU 的型号/序列号请用 psu.sh）
#   给了 --sn 就再做一次一致性比对（不一致只告警，不判失败）。
#
# ---- 五、判定口径与退出码 ----
#   PASS     读到整机型号或整机序列号至少一项
#   WARN     人工录入的 SN 与 BMC FRU 序列号不一致（只告警，不判失败 —— 见第七节）
#   Pending  读不到任何 FRU 信息（BMC 未写入 / 不支持 ipmitool fru / 非 root）
#
#   退出码：0 = PASS   1 = Pending / 环境不满足   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：sudo bash fru.sh | tee fru_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 字段优先级必须用「优先级变量」，不能用「首个非空即锁定」：
#     FRU 里 Board 段排在 Product 段**之前**，若用 `!m` 那种"第一个非空就锁定"的
#     写法，会被低优先级的 Board Product / Board Serial 抢占，
#     整机型号变成主板型号。这里用 pri 变量让 Product 段无论先后都能覆盖。
#   ★ SN 比对只告警、不判失败：不同厂商的 FRU 序列号格式可能和机箱铭牌不完全
#     一致（有的带前缀、有的少几位），判 FAIL 会误伤。它真正的作用是提醒
#     "是不是拿错机器了 / 是不是录错了"。
#   ★ SN 归一化必须分两步 tr：`tr -d '_-'` 里的 `-` 会被当成范围
#     （空格到下划线 0x20-0x5F），把大小写字母和数字全删光，
#     两边都变空串 → 永远判"一致"。所以先删空白、再单独删 `_` 和 `-`。
#   ★ 只取非 PSU 段：PSU 的 FRU 由 psu.sh 单独处理，这里排除避免重复。
# ============================================================

set -u

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then BLUE=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; fi
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${CYAN}   $1${NC}"; }

usage() {
    awk 'NR==1{next} !s{if($0 ~ /^# ===/){s=1} next} /^# ===/{exit} {sub(/^# ?/,"");print}' "$0"
}

: "${SERVER_SN:=}"
SN_IN="${SERVER_SN}"

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -s|--sn)
            if [ $# -lt 2 ]; then
                err "参数 $1 后面要跟一个 SN，例如：--sn SN0001"
                usage; exit 2
            fi
            SN_IN="$2"; shift 2 ;;
        -*)        err "未知参数 $1"; usage; exit 2 ;;
        *)         err "多余的位置参数 $1"; usage; exit 2 ;;
    esac
done

# ---------- 前置检查 ----------
if ! command -v ipmitool >/dev/null 2>&1; then
    err "找不到 ipmitool，无法读取 FRU"
    info "安装：apt install ipmitool   或   yum install ipmitool"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    warn "当前非 root：本地 IPMI 接口（/dev/ipmi0）通常读不到，若下面为空请改用 sudo"
fi

# ==================== 整机 FRU ====================
echo "==================== 整机 FRU 信息 ===================="
echo "命令：ipmitool fru（只取非 PSU 段；PSU 段请用 psu.sh）"
if [ -n "${SN_IN}" ]; then
    echo "人工录入 SN：${SN_IN}（将与 BMC FRU 序列号比对）"
else
    echo "人工录入 SN：未提供（跳过一致性比对，可加 --sn 或设 SERVER_SN）"
fi
echo ""

FRU_RAW=$(ipmitool fru 2>/dev/null)
if [ -z "${FRU_RAW}" ]; then
    warn "未读到任何 FRU 信息（BMC 可能未写入，或不支持 ipmitool fru）"
    info "换一条路：ipmitool mc info / ipmitool fru print 0"
    echo ""
    echo "【判定】Pending —— 读不到 FRU，型号与序列号需查看机箱铭牌"
    exit 1
fi

# 字段优先级：Product 段 > Board 段。整机身份以 Product 段为准
SYS_MODEL=$(printf '%s\n' "${FRU_RAW}" | awk '
    tolower($0) ~ /fru device description/ { hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1; next }
    hit && tolower($0) ~ /^ *product name *:/ { v=$0; sub(/^[^:]*:[ ]*/, "", v); m=v; pri=2 }
    hit && tolower($0) ~ /^ *board product *:/ && pri < 2 { v=$0; sub(/^[^:]*:[ ]*/, "", v); m=v; pri=1 }
    END { print m }')

SYS_SN=$(printf '%s\n' "${FRU_RAW}" | awk '
    tolower($0) ~ /fru device description/ { hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1; next }
    hit && tolower($0) ~ /^ *product serial *:/ { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=2 }
    hit && tolower($0) ~ /^ *chassis serial *:/ && spri < 2 { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=1 }
    hit && tolower($0) ~ /^ *board serial *:/ && spri < 1 { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=0 }
    END { print s }')

if [ -n "${SYS_MODEL}" ]; then
    echo "整机型号:    ${SYS_MODEL}"
else
    echo "整机型号:    未读到（FRU 中无 Product Name / Board Product，需查看机箱铭牌）"
fi
if [ -n "${SYS_SN}" ]; then
    echo "整机序列号:  ${SYS_SN}"
else
    echo "整机序列号:  未读到（FRU 中无 Serial 字段，需查看机箱铭牌）"
fi

# ---- 与人工录入的 SN 比对：不一致多半是录错或拿错机器 ----
MISMATCH=0
if [ -n "${SN_IN}" ] && [ -n "${SYS_SN}" ]; then
    # 注意 tr 的坑：' -_' 里的 - 会被当成范围（空格到下划线 0x20-0x5F），
    # 把大小写字母和数字全删光，两边都变空串导致永远判"一致"。
    # 分两步删，避免连字符被解释成范围。
    a=$(printf '%s' "${SN_IN}" | tr -d '[:space:]' | tr -d '_-' | tr '[:lower:]' '[:upper:]')
    b=$(printf '%s' "${SYS_SN}" | tr -d '[:space:]' | tr -d '_-' | tr '[:lower:]' '[:upper:]')
    if [ "${a}" != "${b}" ]; then
        warn "人工录入 SN（${SN_IN}）与 BMC FRU 序列号（${SYS_SN}）不一致，请核对是否拿错机器   【WARN】"
        MISMATCH=1
    else
        ok "SN一致性: 人工录入与 BMC FRU 一致   【OK】"
    fi
elif [ -z "${SN_IN}" ]; then
    info "未提供人工录入 SN，跳过一致性比对"
fi
echo ""

# ---- 完整 FRU 明细（排除 PSU 段） ----
FRU_OUT=$(printf '%s\n' "${FRU_RAW}" | awk '
    tolower($0) ~ /fru device description/ {
        hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1
        if (hit) { n=$0; sub(/^[^:]*:[ ]*/, "", n); if (++c > 1) print ""; print "  [" n "]" }
        next
    }
    hit && tolower($0) ~ /(chassis|board|product)[ ]*(type|mfg date|mfg|manufacturer|product|name|part number|serial|version|asset tag|extra|custom)/ {
        l=$0; sub(/^[ ]+/, "", l); print "    " l
    }')
if [ -n "${FRU_OUT}" ]; then
    echo "整机 FRU 明细（不含 PSU 段）:"
    echo "${FRU_OUT}"
else
    warn "整机 FRU 明细为空（非 PSU 段里没有可识别的字段）"
fi

# ==================== 结论 ====================
echo ""
if [ -z "${SYS_MODEL}" ] && [ -z "${SYS_SN}" ]; then
    echo "【判定】Pending —— FRU 里既没有型号也没有序列号，需查看机箱铭牌"
    exit 1
fi
if [ "${MISMATCH}" -gt 0 ]; then
    echo "【判定】PASS（附 1 条 WARN）—— 已读到整机型号与序列号，但人工录入 SN 与 FRU 不一致，请核对"
    exit 0
fi
echo "【判定】PASS —— 已读到整机型号与序列号"
exit 0
