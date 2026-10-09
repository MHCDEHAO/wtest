#!/bin/bash
# ============================================================
# mem.sh —— 内存条信息读取（dmidecode 解析：槽位/容量/类型/频率/电压/SN）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   sudo bash mem.sh                # 一条命令，逐条列出内存并给汇总
#   sudo bash mem.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数。
#   ★ 只能在 Linux 上运行（非 Linux 会被平台守卫直接拦下，exit 2）。
#   ★ 需要 root：dmidecode 读 SMBIOS 表要 root，非 root 会拿到空结果。
#
#   【典型输出】
#     槽位: DIMM_A1 | 单条容量: 64 GB | 类型: DDR5 | 最大支持频率: 5600 | 当前频率: 5600 | 电压: 1.1 V | SN: 80AD01...
#     槽位: DIMM_A2 | 单条容量: 64 GB | 类型: DDR5 | 最大支持频率: 5600 | 当前频率: 5600 | 电压: 1.1 V | SN: 80AD02...
#
#     内存条数: 16 条
#     总容量: 1024.00 GB (1048576 MB)
#     【判定】PASS —— 识别到 16 条内存，总容量 1024.00 GB
#
# ---- 二、参数一览 ----
#   【必给】无
#   【有默认值】
#     -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     DEBUG=0           设为 1 时把每个字段的解析过程打到 stderr（排查解析问题用）
#                       也可以不改脚本，直接：DEBUG=1 sudo -E bash mem.sh
#
# ---- 四、它做什么 ----
#   跑 dmidecode -t 17（内存设备表），逐 handle 解析：
#     槽位 Locator / 单条容量 Size / 类型 Type / 最大支持频率 Speed /
#     当前频率 Configured Memory Speed / 电压 Configured Voltage / 序列号
#   跳过空槽（No Module Installed），最后汇总条数与总容量。
#
# ---- 五、判定口径与退出码 ----
#   PASS    读到 >= 1 条已安装内存
#   Pending 一条都没读到（全是空槽，或 dmidecode 读不到 SMBIOS）
#
#   ★ 本脚本【不判定】内存是否合格：条数、容量、频率是否符合配置单，
#     要拿配置单来比对，脚本自己判不了。这里只把事实读出来供人工核对。
#
#   退出码：0 = PASS   1 = Pending（没读到）   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：sudo bash mem.sh | tee mem_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 为什么要按 handle 分块解析，而不是逐行 grep：
#     dmidecode -t 17 每根内存是一个 Handle 块，块内字段名会重复
#     （Size 有 "Size" 和 "Logical Size"、Speed 有 "Speed" 和
#      "Configured Memory Speed"），逐行 grep 会把不同字段混在一起。
#   ★ 为什么要排除 Logical Size / Type Detail / Configured：
#     "Logical Size" 会覆盖真实容量、"Type Detail" 会覆盖真实类型、
#     "Configured Memory Speed" 必须与 "Speed"（最大支持）分开取，
#     否则当前频率会把最大频率顶掉，两列显示同一个数。
#   ★ 为什么要处理 GB / MB 两种单位并换算成 MB 再汇总：
#     部分机型混插不同容量，直接按"条数 × 首条容量"算总容量会错。
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

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -*)        err "未知参数 $1"; usage; exit 2 ;;
        *)         err "多余的位置参数 $1"; usage; exit 2 ;;
    esac
done

# ---------- 前置检查 ----------
# 平台守卫：dmidecode 读 SMBIOS，非 Linux 上根本没有这个命令 ——
# 不拦会报「找不到 dmidecode」，让人误以为是没装包（§3.24）。
_os="$(uname -s 2>/dev/null || echo unknown)"
case "${_os}" in
    Linux) : ;;
    *) err "本脚本只能在 Linux 上运行（当前 uname -s = ${_os}）"
       info "请在 Ubuntu 22.04 被测机上执行：sudo bash mem.sh"
       exit 2 ;;
esac

if ! command -v dmidecode >/dev/null 2>&1; then
    err "找不到 dmidecode，无法读取内存信息"
    info "安装：apt install dmidecode   或   yum install dmidecode"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    warn "当前非 root：dmidecode 读 SMBIOS 表需要 root，下面多半是空结果，请改用 sudo"
fi

DEBUG="${DEBUG:-0}"

echo "==================== 内存条信息 ===================="
echo "命令：dmidecode -t 17"
echo ""

# ---------- 解析 ----------
# 输出说明：每根内存一行；空槽（No Module / None）直接跳过，不计入条数。
MEM_OUT=$(dmidecode -t 17 2>/dev/null | awk -v debug="$DEBUG" '
BEGIN {
    total_mb = 0
    count = 0
    in_handle = 0
    size = ""; type = ""; max_speed = ""; current_speed = ""; voltage = ""; sn = ""; slot = ""
}
/^Handle 0x/ {
    if (debug) print "DEBUG: Found Handle" > "/dev/stderr"
    # 处理上一个 handle
    if (in_handle && size != "" && size !~ /No Module/ && size !~ /None/) {
        # 计算容量
        if (size ~ /GB/) {
            gsub(/ GB/, "", size)
            total = size * 1024
            display_size = size " GB"
        } else if (size ~ /MB/) {
            gsub(/ MB/, "", size)
            total = size
            display_size = size " MB"
        } else {
            total = 0
            display_size = size
        }
        if (current_speed == "" || current_speed == "Unknown" || current_speed == "Not Specified")
            current_speed = "N/A"
        if (max_speed == "" || max_speed == "Unknown" || max_speed == "Not Specified")
            max_speed = "N/A"
        if (slot == "") slot = "N/A"
        if (voltage == "") voltage = "N/A"
        if (sn == "" || sn == "Not Specified" || sn == "[Empty]") sn = "无"
        printf "  槽位: %s | 单条容量: %s | 类型: %s | 最大支持频率: %s | 当前频率: %s | 电压: %s | SN: %s\n", slot, display_size, type, max_speed, current_speed, voltage, sn
        total_mb += total
        count++
    }
    # 重置变量
    size = ""; type = ""; max_speed = ""; current_speed = ""; voltage = ""; sn = ""; slot = ""
    in_handle = 1
    next
}
in_handle {
    # 提取字段（使用更精确的匹配）
    if ($0 ~ /^[[:space:]]*Size:/ && $0 !~ /Logical Size/) {
        sub(/^[[:space:]]*Size:[[:space:]]*/, "")
        size = $0
        gsub(/[[:space:]]+$/, "", size)
        if (debug) print "DEBUG: size = " size > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Type:/ && $0 !~ /Type Detail/) {
        sub(/^[[:space:]]*Type:[[:space:]]*/, "")
        type = $0
        gsub(/[[:space:]]+$/, "", type)
        if (debug) print "DEBUG: type = " type > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Locator:/) {
        sub(/^[[:space:]]*Locator:[[:space:]]*/, "")
        slot = $0
        gsub(/[[:space:]]+$/, "", slot)
        if (debug) print "DEBUG: slot = " slot > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Speed:/ && $0 !~ /Configured/ && $0 !~ /Max/) {
        sub(/^[[:space:]]*Speed:[[:space:]]*/, "")
        max_speed = $0
        gsub(/[[:space:]]+$/, "", max_speed)
        gsub(/ MT\/s/, "", max_speed)
        if (debug) print "DEBUG: max_speed = " max_speed > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Configured Memory Speed:/) {
        sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/, "")
        current_speed = $0
        gsub(/[[:space:]]+$/, "", current_speed)
        gsub(/ MT\/s/, "", current_speed)
        if (debug) print "DEBUG: current_speed = " current_speed > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Configured Voltage:/) {
        sub(/^[[:space:]]*Configured Voltage:[[:space:]]*/, "")
        voltage = $0
        gsub(/[[:space:]]+$/, "", voltage)
        if (debug) print "DEBUG: voltage = " voltage > "/dev/stderr"
    }
    else if ($0 ~ /^[[:space:]]*Serial Number:/) {
        sub(/^[[:space:]]*Serial Number:[[:space:]]*/, "")
        sn = $0
        gsub(/[[:space:]]+$/, "", sn)
        if (debug) print "DEBUG: sn = " sn > "/dev/stderr"
    }
}
END {
    # 处理最后一个 handle
    if (in_handle && size != "" && size !~ /No Module/ && size !~ /None/) {
        if (size ~ /GB/) {
            gsub(/ GB/, "", size)
            total = size * 1024
            display_size = size " GB"
        } else if (size ~ /MB/) {
            gsub(/ MB/, "", size)
            total = size
            display_size = size " MB"
        } else {
            total = 0
            display_size = size
        }
        if (current_speed == "" || current_speed == "Unknown" || current_speed == "Not Specified")
            current_speed = "N/A"
        if (max_speed == "" || max_speed == "Unknown" || max_speed == "Not Specified")
            max_speed = "N/A"
        if (slot == "") slot = "N/A"
        if (voltage == "") voltage = "N/A"
        if (sn == "" || sn == "Not Specified" || sn == "[Empty]") sn = "无"
        printf "  槽位: %s | 单条容量: %s | 类型: %s | 最大支持频率: %s | 当前频率: %s | 电压: %s | SN: %s\n", slot, display_size, type, max_speed, current_speed, voltage, sn
        total_mb += total
        count++
    }
    # 输出汇总信息
    if (count > 0) {
        printf "\n  内存条数: %d 条\n", count
        total_gb = total_mb / 1024
        printf "  总容量: %.2f GB (%d MB)\n", total_gb, total_mb
    } else {
        printf "未识别到任何已安装的内存条\n"
    }
}')

echo "${MEM_OUT}"
echo ""

# ---------- 结论 ----------
# awk 在一条都没读到时会输出固定提示行，据此判断（dmidecode 无输出时也会走到这里）
if printf '%s\n' "${MEM_OUT}" | grep -q '未识别到任何已安装的内存条'; then
    echo "【判定】Pending —— 未识别到已安装内存条（可能全是空槽，或 SMBIOS 未提供 / 非 root 读不到）"
    exit 1
fi

MEM_COUNT=$(printf '%s\n' "${MEM_OUT}" | grep -oE '内存条数:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
MEM_TOTAL=$(printf '%s\n' "${MEM_OUT}" | grep -oE '总容量:.*' | head -1 | sed 's/^总容量:[[:space:]]*//')

if [ -z "${MEM_COUNT}" ] || [ "${MEM_COUNT}" -lt 1 ]; then
    echo "【判定】Pending —— 解析结果里没有内存条数，无法判定"
    exit 1
fi

echo "【判定】PASS —— 识别到 ${MEM_COUNT} 条内存，总容量 ${MEM_TOTAL:-未获取}"
echo "         （条数 / 容量 / 频率是否符合配置单，请人工比对）"
exit 0
