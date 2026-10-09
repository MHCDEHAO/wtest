#!/bin/bash
# ============================================================
# psu.sh —— 电源在位 / 冗余 / 模块FRU / 整机功耗 检测
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   sudo bash psu.sh                # 一条命令，四段全出
#   sudo bash psu.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数。功耗告警线要改就用环境变量，见第三节。
#
#   【典型输出】
#     ✅ PSU1 Status | 70h | ok | 10.1 | Presence Detected   【OK】
#     ⚠️  PSU2 Status | 71h | ns | 10.2 | No Reading   【WARN】无有效读数（多为不在位或未接 AC）
#     ✅ PSU Redundancy | 72h | ok | 10.3 | Fully Redundant   【OK】完全冗余
#     整机功耗 [System Power]: 320 W（BMC 上限 1200 W，占用约 27%）
#     【判定】PASS —— 电源模块与冗余状态正常
#
# ---- 二、参数一览 ----
#   【必给】无
#   【有默认值】
#     -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     POWER_WARN_PCT=90   整机功耗达到 BMC 上限的这个百分比时记 WARN
#
# ---- 四、它做什么 ----
#   分四段跑，一段一段打：
#     1) 电源模块状态：ipmitool sdr 里匹配 power supply / psu（排除冗余传感器）
#     2) 电源冗余状态：ipmitool sdr 里匹配 redundan
#     3) 电源模块 FRU：ipmitool fru 里的 PSU 段（型号 / 序列号，可直接填验收表）
#     4) 整机功耗：ipmitool sensor 里的 System Power 行，含 BMC 上限与占用百分比
#
# ---- 五、判定口径与退出码 ----
#   PASS     每条电源类传感器的状态都是明确的正常值，冗余未降级
#   FAIL     状态含 fail / fault / error / critical / insufficient；
#            或冗余丢失（Redundancy Lost —— 再坏一个电源即宕机）
#   Pending  下列任一（都算"没测出来 / 没法确认"，故计入退出码 1）：
#              · 一条电源类传感器都没识别到（BMC 未暴露 / 非 root 读不到）
#              · 有传感器的读数读不到（ns / na / no reading）
#              · 有传感器的状态词认不出，或认得出但不是明确的正常值
#              · 冗余降级（Degraded）
#
#   ★ 只有明确"正常"的表述（ok / presence detected / state deasserted /
#     device present / 0x00 / fully redundant）才给 OK；认不出的状态一律判
#     Pending 交人工确认 —— 绝不因为"这个词没见过"就当成正常（假 PASS）。
#   ★ 「电源模块不在位」记 WARN、不影响判定：那是配置问题（少装一个电源），
#     不是电源坏了。但会明确打出来，避免被忽略。
#   ★ 功耗逼近上限记 WARN、不影响判定：预检阶段是待机功耗，判断电源余量
#     要在烤机满载时再看一次。
#
#   退出码：0 = PASS   1 = FAIL / 环境不满足（没测出来）   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：sudo bash psu.sh | tee psu_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 冗余传感器单独归类：原写法把 `PSU Redundancy` 一起 grep 进电源模块列表，
#     于是「电源模块状态」下面冒出一条 Redundancy，语义不对。
#   ★ 为什么判定用整行匹配、展示也用原始行：
#     `ipmitool sdr` 各版本 / 各家 BMC 的列数不一致（3 列 名称|读数|状态 与
#     5 列 名称|ID|状态|实体|读数 都见过）。电源/冗余这类离散量的"状态文本"
#     到底落在第几列各家不同 —— 有的在状态列写 ok、真正的状态文本
#     （Presence Detected / Fully Redundant）落在最后一列。写死列号必然
#     张冠李戴；而把原始行直接打出来，无论哪种布局你看到的都是 BMC 原文，
#     判定也据此做，可复查、跨机型一致。
#   ★ 为什么"不在位"不判 FAIL：少装一个电源是配置问题，不是电源坏了。
#   ★ 功耗的 BMC 上限不是电源额定容量：ipmitool sensor 第 8 列是
#     Upper Non-Critical，即 BMC 认定的告警线，别拿它当"电源够不够"的依据。
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

: "${POWER_WARN_PCT:=90}"

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
    err "找不到 ipmitool，无法读取电源信息"
    info "安装：apt install ipmitool   或   yum install ipmitool"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    warn "当前非 root：本地 IPMI 接口（/dev/ipmi0）通常读不到，若下面为空请改用 sudo"
fi

# 去首尾空白（纯 bash，不起子进程）
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

FAIL_N=0; WARN_N=0; OK_N=0; RECOG=0; UNK_N=0

echo "==================== 电源在位 & 功率检测 ===================="
echo "命令：ipmitool sdr / ipmitool fru / ipmitool sensor"
echo ""

# ==================== 1) 电源模块状态 ====================
echo "---- 1) 电源模块状态 ----"
PS_LIST=$(ipmitool sdr 2>/dev/null | grep -iE 'power supply|psu' | grep -viE 'redundan')
if [ -z "${PS_LIST}" ]; then
    warn "未识别到电源模块传感器（匹配 power supply / psu）"
    info "换一条路：ipmitool sdr | grep -iE 'ps[0-9]|power'"
else
    while IFS= read -r line; do
        LC="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
        [ -z "$(printf '%s' "${LC}" | tr -d '[:space:]|')" ] && continue
        RECOG=$((RECOG + 1))
        LINE_T="$(trim "${line}")"
        if printf '%s' "${LC}" | grep -qiE 'not present|not installed|absent'; then
            warn "${LINE_T}   【WARN】电源模块不在位"
            WARN_N=$((WARN_N + 1))
        elif printf '%s' "${LC}" | grep -qiE 'fail|fault|error|critical|insufficient'; then
            err "${LINE_T}   【FAIL】电源模块状态异常"
            FAIL_N=$((FAIL_N + 1))
        elif printf '%s' "${LC}" | grep -qiE 'no reading|not reading|(^|[^a-z])(ns|na)([^a-z]|$)'; then
            warn "${LINE_T}   【WARN】无有效读数（多为不在位或未接 AC）"
            UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1))
        elif printf '%s' "${LC}" | grep -qiE '(^|[^a-z])ok([^a-z]|$)|presence detected|state deasserted|device present|0x00'; then
            ok "${LINE_T}   【OK】"
            OK_N=$((OK_N + 1))
        else
            warn "${LINE_T}   【WARN】状态表述未识别，请人工确认"
            UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1))
        fi
    done <<< "${PS_LIST}"
fi
echo ""

# ==================== 2) 电源冗余状态 ====================
echo "---- 2) 电源冗余状态 ----"
RED_LIST=$(ipmitool sdr 2>/dev/null | grep -iE 'redundan')
if [ -z "${RED_LIST}" ]; then
    warn "未识别到电源冗余传感器（匹配 redundan）"
    info "这条不是必测项：单电源机型本来就没有冗余传感器"
else
    while IFS= read -r line; do
        LC="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"
        [ -z "$(printf '%s' "${LC}" | tr -d '[:space:]|')" ] && continue
        RECOG=$((RECOG + 1))
        LINE_T="$(trim "${line}")"
        # ★ non-redundant 必须显式列出：否则它会落到下面的 'redundant' 分支，
        #   把「无冗余」判成【OK】完全冗余（假阳性）。
        #   注意 "not redundant" 与 "non-redundant" 是两种写法，都要覆盖。
        if printf '%s' "${LC}" | grep -qiE 'redundancy lost|insufficient|failure|failed|not redundant|non-redundant|non redundant'; then
            err "${LINE_T}   【FAIL】冗余已丢失，再坏一个电源即宕机"
            FAIL_N=$((FAIL_N + 1))
        elif printf '%s' "${LC}" | grep -qiE 'degraded'; then
            warn "${LINE_T}   【WARN】冗余降级，请人工确认"
            UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1))
        elif printf '%s' "${LC}" | grep -qiE 'fully redundant|redundant'; then
            ok "${LINE_T}   【OK】完全冗余"
            OK_N=$((OK_N + 1))
        else
            warn "${LINE_T}   【WARN】冗余状态未识别，请人工确认"
            UNK_N=$((UNK_N + 1)); WARN_N=$((WARN_N + 1))
        fi
    done <<< "${RED_LIST}"
fi
echo ""

# ==================== 3) 电源模块 FRU（型号 / 序列号） ====================
echo "---- 3) 电源模块 FRU（型号 / 序列号） ----"
fru_raw=$(ipmitool fru 2>/dev/null)
if [ -z "${fru_raw}" ]; then
    warn "未读到 FRU 信息（BMC 可能未写入或不支持 ipmitool fru）"
else
    psu_fru=$(printf '%s\n' "${fru_raw}" | awk '
        tolower($0) ~ /fru device description/ {
            hit = (tolower($0) ~ /psu|power supply/) ? 1 : 0
            if (hit) { n=$0; sub(/^[^:]*:[ ]*/, "", n); if (++cnt > 1) print ""; print "  [" n "]" }
            next
        }
        hit && tolower($0) ~ /(board|product)[ ]*(mfg|manufacturer|product|name|part number|serial|version)/ {
            l=$0; sub(/^[ ]+/, "", l); print "    " l
        }')
    if [ -n "${psu_fru}" ]; then
        echo "${psu_fru}"
        info "以上型号 / 序列号可直接填入《服务器整机验收记录表》的电源模块行"
    else
        warn "FRU 里没有 PSU 段（BMC 未给电源模块 FRU，需看电源本体标签）"
    fi
fi
echo ""

# ==================== 4) 整机功耗 ====================
echo "---- 4) 整机功耗 ----"
# ipmitool sensor 列序：名称|读数|单位|状态|下限NR|下限C|下限NC|上限NC|上限C|上限NR
# 第 8 列是 Upper Non-Critical，即 BMC 认定的功率上限告警线（不是电源额定容量）
power_line=$(ipmitool sensor 2>/dev/null | grep -iE 'system power|total power|功耗' | head -n1)
if [ -z "${power_line}" ]; then
    warn "未读到整机功耗（BMC 未暴露 System Power 传感器）"
else
    power_name=$(printf '%s' "${power_line}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
    power_val=$(printf '%s' "${power_line}" | awk -F'|' '{print $2}' | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    power_max=$(printf '%s' "${power_line}" | awk -F'|' '{print $8}' | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    if [ -n "${power_val}" ]; then
        if [ -n "${power_max}" ] && [ "${power_max}" != "0" ]; then
            power_pct=$(awk -v a="${power_val}" -v b="${power_max}" 'BEGIN{printf "%.0f", a*100/b}')
            echo "整机功耗 [${power_name}]: ${power_val} W（BMC 上限 ${power_max} W，占用约 ${power_pct}%）"
            if [ "${power_pct}" -ge "${POWER_WARN_PCT}" ] 2>/dev/null; then
                warn "功耗已达 BMC 上限的 ${power_pct}%（>= ${POWER_WARN_PCT}%）   【WARN】"
                WARN_N=$((WARN_N + 1))
            fi
        else
            echo "整机功耗 [${power_name}]: ${power_val} W（BMC 未提供上限阈值）"
        fi
        info "注：这是当前时刻的功耗（待机/空载）。判断电源余量要在烤机满载时再看一次"
    else
        warn "功耗行存在但读不出数值：${power_line}"
    fi
fi

# ==================== 结论 ====================
echo ""
echo "识别到电源类传感器 ${RECOG} 条 | 正常 ${OK_N} | 警告 ${WARN_N} | 失败 ${FAIL_N} | 未能确认 ${UNK_N}"
echo ""

if [ "${FAIL_N}" -gt 0 ]; then
    echo "【判定】FAIL —— 有 ${FAIL_N} 项电源状态异常（模块故障或冗余丢失）"
    exit 1
fi
if [ "${RECOG}" -eq 0 ]; then
    echo "【判定】Pending —— 一条电源类传感器都没识别到，无法判定（非 root 时请用 sudo 重跑）"
    exit 1
fi
if [ "${UNK_N}" -gt 0 ]; then
    echo "【判定】Pending —— 有 ${UNK_N} 项电源状态未能确认，需人工查看原始行"
    exit 1
fi
if [ "${WARN_N}" -gt 0 ]; then
    echo "【判定】PASS —— 电源模块与冗余状态正常，另有 ${WARN_N} 条 WARN 需人工留意"
    exit 0
fi
echo "【判定】PASS —— 电源模块与冗余状态均正常"
exit 0
