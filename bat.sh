#!/bin/bash
# ============================================================
# bat.sh —— CMOS 纽扣电池检测（读 BMC 电池传感器 + 电压四档判定）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   sudo bash bat.sh                # 一条命令，直接出结论
#   sudo bash bat.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数。阈值要改就用环境变量，见第三节。
#   ★ 电压只有在【断开 AC 电源】后测才代表电池真实状态，见第五节。
#
#   【典型输出】
#     ✅ BMC 报告电池状态正常（ok）
#     当前电压  : 3.05 V
#     ✅ 纽扣电池电压正常（3.05V，正常区间 2.9~3.3V）   【PASS】
#     【判定】PASS —— 纽扣电池状态与电压均正常
#
# ---- 二、参数一览 ----
#   【必给】无
#   【有默认值】
#     -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     BAT_LOW_VOLT=2.7    低于此值判 FAIL（该换了）
#     BAT_WARN_VOLT=2.9   低于此值（且 >= 下限）记 WARN，判 Pending
#     BAT_MAX_VOLT=3.3    高于此值视为测量条件有误（多半没断 AC），判 Pending
#
# ---- 四、它做什么 ----
#   用 `ipmitool sdr list` 里第一条电池类传感器（匹配 battery / bat / vbat），
#   拆出 名称 / 读数 / 状态，先判硬件状态，再按四档判电压，最后给整机结论。
#
# ---- 五、判定口径与退出码 ----
#   PASS     状态是明确的正常值，且电压落在 [BAT_WARN_VOLT, BAT_MAX_VOLT]
#   FAIL     状态是 fail / fault / error / critical；或电压 < BAT_LOW_VOLT
#   Pending  下列任一（都算"没测出来/没法定"，故计入退出码 1）：
#              · BMC 未暴露电池传感器（多数机型如此）
#              · 状态认不出 / 是 ns、na、no reading、disabled
#              · 只给状态不给电压读数
#              · 电压落在临界区（2.7~2.9V）—— 记录实测值、列入更换计划
#              · 电压 > 3.3V —— 疑为没断 AC 时读到的主板供电，请复测
#
#   ★ 判定电压必须在【断开 AC 电源】后进行：AC 接通时 BMC 读到的约 3.3V
#     来自主板供电，不是电池电压，会把失效电池误判为正常。
#
#   退出码：0 = PASS   1 = FAIL / 环境不满足（没测出来）   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：sudo bash bat.sh | tee bat_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 修掉原实现的三处误判：
#     1) 多数 BMC 根本不暴露电池传感器，传感器缺失 ≠ 电池不在位，
#        原写法直接把这种情况判 FAIL；这里改成 Pending + 提示人工目视。
#     2) 原写法 `[ "$bat_status" != "ok" ]`：各家状态列大小写/措辞不一
#        （ok / OK / 0x00 / ns），只要不是小写 ok 就判 FAIL。这里先归一化
#        （转小写）再按词表判定，且只有明确正常才给 PASS。
#     3) 原写法取"整行第一个 x.y 数字"当电压，可能取到传感器编号；
#        且离散量 0x00 会被当成 0.0V 判"电压过低"。这里只在读数列取电压，
#        并排除 0x.. / no reading 这类非电压值。
#   ★ 为什么不写死列号：`ipmitool sdr list` 各版本/BMC 列数不一致
#     （3 列 名称|读数|状态 与 5 列 名称|ID|状态|实体|读数 都见过），
#     写死 $2 / $NF 在另一种布局下会张冠李戴。这里按语义认列。
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

: "${BAT_LOW_VOLT:=2.7}"
: "${BAT_WARN_VOLT:=2.9}"
: "${BAT_MAX_VOLT:=3.3}"

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
    err "找不到 ipmitool，无法读取电池传感器"
    info "安装：apt install ipmitool   或   yum install ipmitool"
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    warn "当前非 root：本地 IPMI 接口（/dev/ipmi0）通常读不到，若下面为空请改用 sudo"
fi

# ---------- sdr 输出拆列（不假设列序，理由见头部第七节） ----------
# 把一行 sdr 输出拆成三段，结果写入全局变量 S_NAME / S_READ / S_STATUS
# ★ 状态词表只用来"认列"。认不出就不填 S_STATUS —— 让调用方走"无法判定"分支，
#   绝不因为"这个词没见过"就当成正常（那会变成假 PASS）。
SDR_ST_RE='^(ok|ns|na|nc|cr|nr|unr|lcr|lnc|lnr|unc|uc|no reading|not reading|disabled|not present|not installed|device absent|device not present|absent|unknown|n/a|fail|failed|failure|fault|faulty|error|critical|non-critical|non critical|non-recoverable|non recoverable|predictive failure|degraded|insufficient|presence detected|presence not detected|state asserted|state deasserted|asserted|deasserted|redundancy lost|fully redundant)$'

sdr_split() {
    local line="$1" f i
    local -a F=()
    S_NAME=''; S_READ=''; S_STATUS=''
    IFS='|' read -r -a F <<< "$line"
    [ ${#F[@]} -eq 0 ] && return 1
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
        if [ -z "$S_STATUS" ] && printf '%s' "$f" | grep -qiE "$SDR_ST_RE"; then
            S_STATUS="$f"; continue
        fi
        if [ -z "$S_READ" ]; then
            if printf '%s' "$f" | grep -qE '[0-9]' \
               && ! printf '%s' "$f" | grep -qE '^([0-9A-Fa-f]{1,2}h|0x[0-9A-Fa-f]+|[0-9]+\.[0-9]+)$'; then
                S_READ="$f"; continue
            fi
        fi
    done
    return 0
}

# ==================== 纽扣电池检测 ====================
echo "==================== CMOS 纽扣电池检测 ===================="
echo "命令：ipmitool sdr list | grep -iE 'battery|bat|vbat' | head -1"
echo "阈值：<${BAT_LOW_VOLT}V FAIL | ${BAT_LOW_VOLT}~${BAT_WARN_VOLT}V WARN | ${BAT_WARN_VOLT}~${BAT_MAX_VOLT}V PASS | >${BAT_MAX_VOLT}V 疑未断AC"
echo ""

BAT_LINE=$(ipmitool sdr list 2>/dev/null | grep -iE 'battery|\bbat\b|vbat' | head -1)
if [ -z "${BAT_LINE}" ]; then
    warn "BMC 未暴露纽扣电池传感器（多数机型不提供该读数），无法自动检测"
    info "请人工目视确认主板纽扣电池在位、无松动、无锈蚀（此项不判失败）"
    echo ""
    echo "【判定】Pending —— 读不到电池传感器，需人工目视确认"
    exit 1
fi

echo "原始行：${BAT_LINE}"
echo ""

sdr_split "${BAT_LINE}"
echo "电池标识  : ${S_NAME}"
echo "传感器读数: ${S_READ:-无}"
echo "硬件状态  : ${S_STATUS:-未识别}"
echo ""

HARD_FAIL=0; PENDING=0; WARN_N=0
BOTH="$(printf '%s %s' "${S_STATUS}" "${S_READ}" | tr '[:upper:]' '[:lower:]')"

# ---- 状态判定：先归一化再比较，只对"确定性故障"判 FAIL ----
# ★ critical 前必须排除 non- 前缀：否则 'non-critical'（轻度预警）会被这条吃掉判成 FAIL，
#   下面专门处理 non-critical 的分支永远走不到（死代码）。
if printf '%s' "${BOTH}" | grep -qiE 'fail|fault|error|(^|[^a-z-])critical|predictive|non-recoverable|non recoverable'; then
    err "纽扣电池硬件状态异常（${S_STATUS:-${S_READ}}）   【FAIL】"
    HARD_FAIL=1
elif [ -z "${S_STATUS}" ] \
     || printf '%s' "${S_STATUS}" | grep -qiE '^(ns|na|no reading|not reading|disabled|unknown|n/a|not present|not installed|device absent|device not present)$'; then
    warn "BMC 未给出电池有效状态（${S_STATUS:-未识别}），无法自动判定   【WARN】"
    info "请人工目视确认主板纽扣电池在位、无松动、无锈蚀（此项不判失败）"
    PENDING=1
elif printf '%s' "${BOTH}" | grep -qiE 'non-critical|non critical'; then
    warn "电池状态为 ${S_STATUS:-${S_READ}}（轻度预警，尚未到故障线）   【WARN】"
    WARN_N=$((WARN_N + 1))
    PENDING=1
elif printf '%s' "${BOTH}" | grep -qiE '\bok\b|state deasserted|device present|presence detected|0x00'; then
    ok "BMC 报告电池状态正常（${S_STATUS:-${S_READ}}）"
else
    warn "未知的电池状态表述（${S_STATUS}），请人工确认（不判失败）   【WARN】"
    PENDING=1
fi

# ---- 电压判定：0x.. 是离散量不是电压，不能拿来当伏特数 ----
if [ "${HARD_FAIL}" -eq 0 ] && [ "${PENDING}" -eq 0 ]; then
    bat_volt=""
    if ! printf '%s' "${S_READ}" | grep -qiE '^0x|no reading|not available|^ns$|^disabled$|^$'; then
        bat_volt=$(printf '%s' "${S_READ}" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    fi

    if [ -z "${bat_volt}" ]; then
        warn "传感器只提供状态量（${S_READ:-无}）不提供电压读数，无法判定电压   【WARN】"
        info "电压才是纽扣电池的关键判据，需人工测量或换机型确认（不判失败）"
        PENDING=1
    else
        echo "当前电压  : ${bat_volt} V"
        info "测量提示：判定电压须在【断开 AC 电源】后进行"
        info "          （AC 接通时读到的是主板供电，不是电池真实电压）"
        echo ""

        # 四档：过低 FAIL / 临界区 WARN+Pending / 正常 PASS / 超上限 WARN+Pending
        volt_grade=$(awk -v v="${bat_volt}" -v lo="${BAT_LOW_VOLT}" \
                         -v mid="${BAT_WARN_VOLT}" -v hi="${BAT_MAX_VOLT}" 'BEGIN{
            if      (v < lo)   print "LOW"
            else if (v < mid)  print "CRIT"
            else if (v > hi)   print "OVER"
            else               print "OK"
        }')
        case "${volt_grade}" in
            LOW)
                err "纽扣电池电压过低（${bat_volt}V < ${BAT_LOW_VOLT}V），需更换   【FAIL】"
                HARD_FAIL=1 ;;
            CRIT)
                warn "纽扣电池电压进入临界区（${bat_volt}V，区间 ${BAT_LOW_VOLT}~${BAT_WARN_VOLT}V），记录实测值并列入更换计划   【WARN】"
                WARN_N=$((WARN_N + 1)); PENDING=1 ;;
            OVER)
                warn "电压读数 ${bat_volt}V > ${BAT_MAX_VOLT}V，疑为未断开 AC 时读到的主板供电，请断 AC 后复测   【WARN】"
                WARN_N=$((WARN_N + 1)); PENDING=1 ;;
            *)
                ok "纽扣电池电压正常（${bat_volt}V，正常区间 ${BAT_WARN_VOLT}~${BAT_MAX_VOLT}V）   【PASS】" ;;
        esac
    fi
fi

# ==================== 结论 ====================
echo ""
if [ "${HARD_FAIL}" -gt 0 ]; then
    echo "【判定】FAIL —— 纽扣电池状态异常或电压过低，需更换"
    exit 1
fi
if [ "${PENDING}" -gt 0 ]; then
    echo "【判定】Pending —— 无法自动判定（另有 ${WARN_N} 条 WARN），需人工目视 / 断 AC 后测量"
    exit 1
fi
echo "【判定】PASS —— 纽扣电池状态与电压均正常"
exit 0
