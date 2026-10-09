#!/bin/bash
# ============================================================
# fan.sh —— 风扇状态与转速检测（读 BMC 风扇传感器）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   sudo bash fan.sh                # 一条命令，直接出结论
#   sudo bash fan.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数。阈值要改就用环境变量，见第三节。
#
#   【典型输出】
#     ✅ FAN1 : 5100 RPM | ok   【OK】
#     ⚠️  FAN7 : No Reading | ns   【WARN】BMC 未给出有效状态
#     【判定】PASS —— 12 台风扇状态与转速均正常
#
# ---- 二、参数一览 ----
#   【必给】无
#   【有默认值】
#     -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     FAN_MIN_RPM=500     转速下限，低于它记 WARN
#     FAN_MAX_RPM=20000   转速上限，高于它记 WARN
#
# ---- 四、它做什么 ----
#   跑一条 ipmitool sdr type Fan，把每台风扇的 名称/读数/状态 逐条打出来并判定，
#   最后统计有效转速台数、给出整机结论。
#
# ---- 五、判定口径与退出码 ----
#   PASS     每台风扇状态都是明确的正常值，且至少读到 1 个有效转速
#   FAIL     任一台风扇状态是 fail / fault / error / critical / not present
#   Pending  下列任一（都算"没测出来 / 没法确认"，故计入退出码 1）：
#              · 一台有效转速都没读到（BMC 未暴露读数，或非 root 读不到接口）
#              · 有风扇的 BMC 状态读不到（空 / ns / na / no reading / disabled）
#              · 有风扇的状态词认不出，或认得出但不是明确的正常值
#
#   ★ 只有明确"正常"的状态才给 OK（ok / presence detected / state deasserted /
#     device present）。认不出的状态一律判 Pending 交人工确认 —— 绝不因为
#     "这个词没见过"就当成正常（那会变成假 PASS）。
#   ★ 转速超出 FAN_MIN_RPM ~ FAN_MAX_RPM 只记 WARN、不影响判定：
#     空载/降速时风扇会低于 500 RPM，硬判 FAIL 会整片误报。
#   ★ "状态确认正常、只是没给转速读数"也只记 WARN、不影响判定 ——
#     状态是主判据，转速是补充。但若整机一台转速都没读到，仍判 Pending。
#
#   退出码：0 = PASS   1 = FAIL / 环境不满足（没测出来）   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：sudo bash fan.sh | tee fan_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 为什么不写死列号：
#     `ipmitool sdr` 各版本 / 各家 BMC 的列数不一致，常见两种：
#       3 列   名称 | 读数 | 状态             （FAN1 | 5100 RPM | ok）
#       5 列   名称 | 传感器ID | 状态 | 实体 | 读数
#     若写死「$2 是读数、$NF 是状态」，在 5 列布局下会把传感器ID（30h）
#     当成转速 → 每台风扇都报「转速异常」，是典型的静默错判。
#     所以这里按语义认列：状态列 = 命中已知状态词；读数列 = 含数字且不像
#     ID / 实体号的字段。两种布局都能正确解析，读不到就如实说读不到。
#   ★ 为什么"读不到"不判 FAIL：多数 BMC 根本不暴露转速，非 root 也读不到接口。
#     那是"没测出来"，不是"测出来坏了"，记 Pending 交人工确认。
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

: "${FAN_MIN_RPM:=500}"
: "${FAN_MAX_RPM:=20000}"

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -*)        err "未知参数 $1"; usage; exit 2 ;;
        *)         err "多余的位置参数 $1"; usage; exit 2 ;;
    esac
done

# ---------- 前置检查 ----------
if ! command -v ipmitool >/dev/null 2>&1; then
    err "找不到 ipmitool，无法读取风扇传感器"
    info "安装：apt install ipmitool   或   yum install ipmitool"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    warn "当前非 root：本地 IPMI 接口（/dev/ipmi0）通常读不到，若下面为空请改用 sudo"
fi

# ---------- sdr 输出拆列（不假设列序，理由见头部第七节） ----------
# 把一行 sdr 输出拆成三段，结果写入全局变量 S_NAME / S_READ / S_STATUS
# ★ 状态词表只用来"认列"。认不出就不填 S_STATUS —— 让调用方走"无法确认"分支，
#   绝不因为"这个词没见过"就当成正常（那会变成假 PASS）。
SDR_ST_RE='^(ok|ns|na|nc|cr|nr|unr|lcr|lnc|lnr|unc|uc|no reading|not reading|disabled|not present|not installed|device absent|device not present|absent|unknown|n/a|fail|failed|failure|fault|faulty|error|critical|non-critical|non critical|non-recoverable|non recoverable|predictive failure|degraded|insufficient|presence detected|presence not detected|state asserted|state deasserted|asserted|deasserted|redundancy lost|fully redundant)$'

sdr_split() {
    local line="$1" f i
    local -a F=()
    S_NAME=''; S_READ=''; S_STATUS=''
    IFS='|' read -r -a F <<< "$line"
    [ ${#F[@]} -eq 0 ] && return 1
    # 逐段去首尾空白（纯 bash，不起子进程）
    for ((i=0; i<${#F[@]}; i++)); do
        f="${F[i]}"
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        F[i]="$f"
    done
    S_NAME="${F[0]}"
    for ((i=1; i<${#F[@]}; i++)); do
        f="${F[i]}"
        [ -z "$f" ] && continue
        # 状态列：命中已知状态词
        if [ -z "$S_STATUS" ] && printf '%s' "$f" | grep -qiE "$SDR_ST_RE"; then
            S_STATUS="$f"; continue
        fi
        # 读数列：含数字，且不是传感器ID(xxh / 0x..) 也不是实体号(n.m)
        if [ -z "$S_READ" ]; then
            if printf '%s' "$f" | grep -qE '[0-9]' \
               && ! printf '%s' "$f" | grep -qE '^([0-9A-Fa-f]{1,2}h|0x[0-9A-Fa-f]+|[0-9]+\.[0-9]+)$'; then
                S_READ="$f"; continue
            fi
        fi
    done
    return 0
}

# ==================== 风扇检测 ====================
echo "==================== 风扇检测（BMC 风扇传感器） ===================="
echo "命令：ipmitool sdr type Fan"
echo "阈值：${FAN_MIN_RPM} ~ ${FAN_MAX_RPM} RPM（超出只记 WARN，不影响判定）"
echo ""

FAN_RAW=$(ipmitool sdr type Fan 2>/dev/null)
if [ -z "${FAN_RAW}" ]; then
    err "未获取到风扇传感器数据（BMC 未暴露 Fan 类型传感器，或读不到 IPMI 接口）"
    info "换一条路试试：ipmitool sensor | grep -i fan"
    info "非 root 时请改用 sudo 重跑"
    echo ""
    echo "【判定】Pending —— 读不到风扇传感器，无法判定"
    exit 1
fi

echo "---- 原始输出 ----"
echo "${FAN_RAW}"
echo ""

FAIL_N=0; WARN_N=0; OK_N=0; VALID_N=0; UNK_N=0

while IFS= read -r line; do
    [ -z "${line//[[:space:]]/}" ] && continue
    sdr_split "${line}" || continue
    [ -z "${S_NAME}" ] && continue

    # 1) 确定性故障：状态出现 fail/fault/error/critical/not present 直接 FAIL
    if printf '%s' "${S_STATUS}" | grep -qiE 'fail|fault|error|critical|not present|not installed|absent|degraded'; then
        err "${S_NAME} : ${S_READ:-无读数} | ${S_STATUS}   【FAIL】状态异常"
        FAIL_N=$((FAIL_N + 1)); continue
    fi

    # 2) 状态读不到 / 无效 → 没法确认，记 Pending
    if [ -z "${S_STATUS}" ] \
       || printf '%s' "${S_STATUS}" | grep -qiE '^(ns|na|no reading|not reading|disabled|unknown|n/a)$'; then
        warn "${S_NAME} : ${S_READ:-无读数} | ${S_STATUS:-未识别}   【WARN】BMC 未给出有效状态"
        info "原始行：${line}"
        UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1)); continue
    fi

    # 3) 状态词认得出，但不是明确的"正常" → 同样没法确认，记 Pending
    if ! printf '%s' "${S_STATUS}" | grep -qiE '^(ok|presence detected|state deasserted|device present)$'; then
        warn "${S_NAME} : ${S_READ:-无读数} | ${S_STATUS}   【WARN】状态不是明确的正常值，请人工确认"
        UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1)); continue
    fi

    # 4) 状态已确认正常，只是没给转速读数 → 只记 WARN，不影响判定
    if [ -z "${S_READ}" ] \
       || printf '%s' "${S_READ}" | grep -qiE 'no reading|not reading|^ns$|^na$'; then
        warn "${S_NAME} : ${S_READ:-无读数} | ${S_STATUS}   【WARN】无有效转速读数（状态已确认正常）"
        WARN_N=$((WARN_N + 1)); continue
    fi

    # 5) 状态正常且读数在手 → 取转速比阈值
    speed=$(printf '%s' "${S_READ}" | grep -oE '[0-9]+' | head -1)
    if [ -z "${speed}" ]; then
        warn "${S_NAME} : ${S_READ} | ${S_STATUS}   【WARN】读数里解析不出转速"
        WARN_N=$((WARN_N + 1)); continue
    fi
    VALID_N=$((VALID_N + 1))
    if [ "${speed}" -lt "${FAN_MIN_RPM}" ] || [ "${speed}" -gt "${FAN_MAX_RPM}" ]; then
        warn "${S_NAME} : ${S_READ} | ${S_STATUS}   【WARN】转速超出 ${FAN_MIN_RPM}-${FAN_MAX_RPM} RPM"
        WARN_N=$((WARN_N + 1))
    else
        ok "${S_NAME} : ${S_READ} | ${S_STATUS}   【OK】"
        OK_N=$((OK_N + 1))
    fi
done <<< "${FAN_RAW}"

# ==================== 结论 ====================
echo ""
echo "有效转速 ${VALID_N} 台 | 正常 ${OK_N} | 警告 ${WARN_N} | 失败 ${FAIL_N} | 未能确认 ${UNK_N}"
echo ""

if [ "${FAIL_N}" -gt 0 ]; then
    echo "【判定】FAIL —— 有 ${FAIL_N} 台风扇状态异常，需更换或查线"
    exit 1
fi
if [ "${VALID_N}" -eq 0 ]; then
    echo "【判定】Pending —— 一台有效转速都没读到，无法判定（非 root 时请用 sudo 重跑）"
    exit 1
fi
if [ "${UNK_N}" -gt 0 ]; then
    echo "【判定】Pending —— 有 ${UNK_N} 台风扇状态未能确认，需人工查看原始行"
    exit 1
fi
if [ "${WARN_N}" -gt 0 ]; then
    echo "【判定】PASS —— ${VALID_N} 台风扇状态正常，另有 ${WARN_N} 条 WARN 需人工留意"
    exit 0
fi
echo "【判定】PASS —— ${VALID_N} 台风扇状态与转速均正常"
exit 0
