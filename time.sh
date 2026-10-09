#!/bin/bash
# ============================================================
# time.sh —— RTC 走时 / 时区口径 / NTP 同步 验收
#
# 一句话：分三段独立判 —— ①RTC 硬件好不好、②RTC 时区口径对不对、
#         ③系统时间能不能和外部时间源对齐。三段互不牵连，各自出结论。
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   【1】最常用：一条命令，直接出结论
#         sudo bash time.sh
#
#   【2】想连 BMC 时间一起比（可选）
#         sudo bash time.sh --bmc 10.10.10.20 -U admin -P 'xxx'
#         sudo bash time.sh          ← 不给 --bmc 时，本机自动走系统接口
#                                      （-I open，免 BMC 账号密码，需 root）
#
#   【3】校准 BMC 时间（★ 会【写】BMC 时钟；默认只读、不写）
#         sudo bash time.sh --fix                                ← 本机免密校准
#         sudo bash time.sh --bmc 10.10.10.20 -U admin -P 'xxx' --fix
#         ★ 硬门禁：本机 NTP 必须【在运行且已联网同步】，否则拒绝校准并退 2
#
#   【4】指定外部时间源当"真值参考"（最准，需要能出网）
#         sudo bash time.sh --ref-ntp ntp.aliyun.com
#         sudo bash time.sh --ref-ntp ntp.aliyun.com,cn.pool.ntp.org
#
#   【5】被测机出不了网，用控制机当参考（控制机自己必须先同步好）
#         sudo bash time.sh --ref-host root@10.10.10.5
#
#   【6】只看现状、不判定（免 root，随便跑）
#         bash time.sh --list
#
#   ★ 必给参数：无。不带任何参数也能跑出完整结论。
#
# ---- 二、参数一览 ----
#
#   【必给】无
#
#   【有默认值，通常不用给】
#     --offset-max SEC   与参考源的偏差上限，默认 1.0 秒；超了判 FAIL
#     --ppm-max PPM      时钟频率偏差提示线，默认 100 ppm；超了只记录不判不合格
#     --rtc-tol SEC      RTC 与系统时间的允许偏差，默认 5 秒
#     --bmc-tol SEC      与 BMC 时间的容差，默认 60 秒；超了只记录不判不合格
#     --fix-tol SEC      --fix 校准后复检的残差上限，默认 2 秒；超了判 FAIL
#     --drift-min MIN    RTC 走时漂移测量时长（分钟），默认 0 = 不测
#     --drift-max PPM    漂移上限，默认 50 ppm（仅 --drift-strict 时参与判定）
#     --drift-strict     漂移参与判定（默认只记录）
#     -h, --help         打印本段帮助
#
#   【给了才跑】
#     --ref-ntp SRV[,SRV]  外部 NTP 时间源，当"真值参考"（只查不改时间）
#     --ref-host USER@IP   用一台已同步好的机器当参考（NTP 四时间戳法）
#     --bmc IP             BMC 地址；不给则走本机系统接口（-I open，免密，需 root）
#     -U USER / -P PASS    BMC 账号密码（走网络时必给）
#
#   【模式开关】
#     --list               免 root，只列现状、不做判定、恒退 0
#     --no-rtc-check       跳过 RTC 段（某些虚拟平台没有 RTC）
#     --fix                ★ 校准 BMC 时间为本机 UTC（会【写】；默认只读不写）
#
# ---- 三、环境变量（同名大写可覆盖） ----
#     OFFSET_MAX=1.0    PPM_MAX=100     RTC_TOL=5      BMC_TOL=60
#     DRIFT_MIN=0       DRIFT_MAX=50    DRIFT_STRICT=0  FIX_TOL=2
#     REF_NTP=          REF_HOST=
#     BMC_IP=  BMC_USER=  BMC_PASS=     IPMI_OPTS=
#     SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8'
#     RTC_SYS=/sys/class/rtc/rtc0        个别平台 RTC 不叫 rtc0 时可改；自测也用它注入
#     ADJTIME_FILE=/etc/adjtime          同上，供无 timedatectl 的环境降级读取
#
# ---- 四、它做什么 ----
#
#   ① RTC 硬件段
#      · RTC 设备在不在（/dev/rtc0 或 /sys/class/rtc/rtc0）
#      · RTC 在不在走 —— 隔 2 秒读两次秒计数，增量≈2 才算在走
#        ★ 这条能抓出「纽扣电池没电导致 RTC 停走」；与 bat.sh 互补：
#          bat.sh 测电池【电压】，本脚本测 RTC【功能】
#      · RTC 与系统时间的偏差（hwclock --compare；没装 hwclock 时降级直读 sysfs）
#        ★ 该偏差只有在参考系 ≥L1（系统时间已被外部源证明可信）时才判 PASS/FAIL；
#          L3（无参考系）时一律 Pending —— 因为「两者一致」可能只是被一起设错了，
#          不能当"走时准"。详见第五节参考系分级。
#      ※ 不重复测电池电压 —— 那是 bat.sh 的事，这里只提示
#
#   ② RTC 时区口径段
#      · RTC 存的是 UTC 还是本地时间（timedatectl 的 LocalRTC；降级读 /etc/adjtime）
#      · 系统时区、systemd 是否托管 NTP
#
#   ③ NTP 同步段
#      · 客户端类型（chronyd / ntpd / systemd-timesyncd 三条路都支持）
#      · 服务是否在跑、是否开机自启
#      · 上游源是否可达、源数量
#      · 当前偏差 offset（秒）与频率偏差 Frequency（ppm）
#
#   ④ BMC 时间段（给了 --bmc，或本机有系统接口且有 root 时跑）
#      · 通道：给了 --bmc 走 lanplus（要 -U/-P）；否则走本机 -I open（免密，需 root）
#      · 读 BMC 时间（sel time get，回退 mc selftime get），与系统时间比
#        ★ 偏差超 --bmc-tol 只记录、不判不合格（BMC 时钟普遍不准且不接 NTP）
#      · ★ 只有加 --fix 才写：先过前置门禁（本机 NTP 在跑且已同步），再下发
#          ipmitool ... sel time set "$(date -u '+%m/%d/%Y %H:%M:%S')"
#        写完立刻读回复检，残差 <= --fix-tol 才 PASS
#        ★ IPMI SEL 时间是【不带时区的 UTC 时间戳】，故一律用 date -u；
#          格式是美式 MM/DD/YYYY HH:MM:SS。Web 上差 8 小时是【时区】问题 ——
#          去 BMC Web 里把时区设成 Asia/Shanghai，别把值改成北京时间。
#        ★ 只改 BMC 会被覆盖：BMC 启动/轮询会从主板 RTC 或 ME 取时间。
#          要稳住，先保证宿主时间准，再 hwclock --systohc 写进 RTC。
#        ★ 改 BMC 时间会让之后【新产生】的 SEL 事件按新时钟打时间戳
#          （历史事件不变）—— 验收留档请一并记录本次校准动作。
#
#   ⑤ RTC 走时漂移长测（--drift-min > 0 才跑）
#
# ---- 五、判定口径与退出码 ----
#
#   ★ 参考系分级（本脚本的地基）
#     判「准不准」必须先有一个"准"的参照物。按可信度降级取第一个「能被证明可信」的：
#       L0  外部 NTP 真值源（--ref-ntp 且连得上）   毫秒级 → 能判「准不准」
#       L1  已同步的系统时间（NTP 已同步）           毫秒级 → 判 RTC 与它的偏差
#       L2  控制机时间（--ref-host，且它自己准）     毫秒级 → 判偏差
#       L3  无参考系                                 ★ 只能判「一致性」，
#                                                      绝对精度未验证 → 该段 Pending
#     ★ 报告里一定会打印用了哪一级参考系 —— 否则事后无法判断
#       当时那个 PASS 是在什么基准下得出的。
#     ★ 参考系本身必须先被证明可信，再拿去比对。所以本脚本先探参考系，后做判定。
#     ★ ★ L3 下「RTC 与系统时间一致」≠「RTC 准」：两者可能被【一起设错】
#       （装机现场很常见 —— 装完机系统时间就是错的，RTC 跟着一起错，偏差 0）。
#       所以 L3 时 RTC 偏差项一律判 Pending（只说明"两者一致"，不代表走时正确），
#       绝不给 PASS —— 拿一个未经证明的钟当基准去判另一个钟，本身就是伪证。
#
#   三态：
#     PASS    —— 达标
#     FAIL    —— 明确不合格
#     Pending —— 无法判定（虚拟机没有 RTC / 没装任何 NTP 客户端 / 无参考系 / 测量时长不足）
#
#   ★ 两条关键边界，别搞反：
#     ·「没装任何 NTP 客户端」→ Pending，不判 FAIL（机器没毛病，是环境没配）
#     ·「装了客户端但同步不上」→ FAIL（网络不通 / 配置错 / 时间源是假的，属交付缺陷）
#
#   ★ 按设计只记录、不参与判定的三项（避免误杀）：
#     · 频率偏差 ppm 超提示线 —— 属晶振偏老，不影响交付
#     · BMC 时间偏差超容差   —— BMC 时钟普遍不准且不接 NTP
#     · 走时漂移 ppm         —— 除非显式加 --drift-strict
#
#   退出码：0 = 没有 FAIL（可能含 Pending，结论行会显式写出 Pending 项数）
#           1 = 有 FAIL
#           2 = 用法错误；或 --fix 时前置条件不满足（本机时间不可信，拒绝校准）
#
# ---- 六、产物 ----
#   全部打屏，不落盘（与 fan.sh / bat.sh / psu.sh / fru.sh 一致）。
#   要留档：sudo bash time.sh 2>&1 | tee time_$(date +%Y%m%d).txt
#
# ---- 七、设计说明（为什么这么写） ----
#
#   · 「RTC 在不在走」和「时区口径」两项不需要参考系 —— 前者是自洽检查
#     （自己和自己比），后者是纯配置检查。所以哪怕完全离线、NTP 都没装，
#     这两项照样能给出确定结论。
#
#   · Frequency(ppm) 与 System time(秒) 别搞混：
#       Frequency   = chronyd 估算的本机时钟频率偏差，接近硬件晶振指标
#       System time = 当前这一刻与 NTP 的偏差，是同步质量指标
#     所以前者超线只记录，后者超线才判 FAIL。
#
#   · 漂移长测的参考系用【单调时钟】而不是系统时间 —— 系统时间会被 NTP
#     的 step 跳变污染，单调时钟不会（CLOCK_MONOTONIC_RAW 更是完全不受影响）。
#     但它测出来的仍只是「RTC 相对 CPU 时基的相对漂移」，不是绝对漂移，
#     所以默认只记录、不判定。
#
#   · ★ RTC 只有秒级精度（/sys/class/rtc/rtc0/since_epoch 是整数秒），
#     所以漂移测量的分辨率 = 1e6 / 测量秒数 ppm。想测到 ±10 ppm 需要约 28 小时。
#     报告里会一并打印"测量分辨率"；时长不足以判定时会明确标 Pending，
#     不硬给结论 —— 宁可说"测不出来"，也不给一个假的数。
#
#   · 本脚本与 bat.sh 的分工：bat.sh 测电池【电压】（静态），本脚本测 RTC
#     【功能】（走时）。电池临界失效的现场正是「电压还在 2.9V，但 RTC 已停走」。
#
#   · ★「读不到」不填 0：任何取不到的读数一律留空，并报「本项不可得 / 待判定」。
#     默认值只在「语义上确实等于该值」时才能填 —— 否则就是把「读不到」伪装成
#     「达标」，属于报假成功。
#
#   · ★「跳过」不报 PASS：本段一条判定都没产生时，汇总行写「判定：跳过」，
#     不写 PASS —— 0 条判定 = 未验证，不等于合格。
#
#   · ★「一致」不报 PASS：L3 无参考系时，RTC 与系统时间一致只证明【两者同步】，
#     不证明【走时准】—— 装机时系统时间本身可能是错的，RTC 跟着一起错，偏差照样 0。
#     所以该场景判 Pending，不判 PASS。与上一条同理：拿一个未经验证的基准去做判定，
#     等于报假绿。判定前必须先拿到 ≥L1 的参考系（外部 NTP 真值 / 已同步的系统时间 /
#     已同步的控制机），否则只能报"一致"，不能报"准"。
#
#   · ★ 为什么 --fix 默认关：本脚本的主身份是【验收】，原则是如实报告、
#     不修机器（同理不自动装包）。校准属于"动手改被测机"，是另一类动作，
#     所以做成显式开关；不加 --fix 时全脚本只读，SOP 里对 time.sh 的
#     描述（只读验收）继续成立。
#
#   · ★ --fix 的硬门禁：本机 NTP 必须在运行且已联网同步。本机时间不可信时
#     拿它去校准 BMC，等于把错误传播出去 —— 宁可不做（拒绝并退 2）。
#
#   · 依赖与装法（缺了只影响对应那一段，不影响其余判定）：
#       hwclock   → Ubuntu 22.04：apt-get install -y util-linux
#                   Debian 12 / Ubuntu 24.04 起已拆到 util-linux-extra
#                   （没装也能跑：本脚本降级直读 /sys/class/rtc/rtc0/{date,time}）
#       ipmitool  → apt-get install -y ipmitool（只影响 ④ BMC 时间段）
#     ★ 本脚本**不会**自动安装任何包 —— 验收脚本的职责是如实报告，
#       不是把被测机修好再报告；自动装包会抹掉「装机漏装依赖」这个交付缺陷。
# ============================================================

set -u

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then BLUE=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; fi
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${CYAN}   $1${NC}"; }
note() { echo -e "${YELLOW}   · $1${NC}"; }

usage() {
    awk 'NR==1{next} !s{if($0 ~ /^# ===/){s=1} next} /^# ===/{exit} {sub(/^# ?/,"");print}' "$0"
}

cleanup() {
    # 本脚本不落盘、不建临时文件；这里只负责中断时把终端颜色复位
    [ -t 1 ] && printf '\033[0m'
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 默认值 ----------
OFFSET_MAX="${OFFSET_MAX:-1.0}"
PPM_MAX="${PPM_MAX:-100}"
RTC_TOL="${RTC_TOL:-5}"
BMC_TOL="${BMC_TOL:-60}"
FIX_TOL="${FIX_TOL:-2}"
DRIFT_MIN="${DRIFT_MIN:-0}"
DRIFT_MAX="${DRIFT_MAX:-50}"
DRIFT_STRICT="${DRIFT_STRICT:-0}"
REF_NTP="${REF_NTP:-}"
REF_HOST="${REF_HOST:-}"
BMC_IP="${BMC_IP:-}"
BMC_USER="${BMC_USER:-}"
BMC_PASS="${BMC_PASS:-}"
IPMI_OPTS="${IPMI_OPTS:-}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8}"

DO_LIST=0
SKIP_RTC=0
DO_FIX=0

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)       usage; exit 0 ;;
        --list)          DO_LIST=1; shift ;;
        --no-rtc-check)  SKIP_RTC=1; shift ;;
        --drift-strict)  DRIFT_STRICT=1; shift ;;
        --fix)           DO_FIX=1; shift ;;
        # ★ 每个带值选项都必须先确认"还有第 2 个参数"，否则 shift 2 在只剩 1 个参数时
        #   会报错却【不改变 $#】，while [ $# -gt 0 ] 随即死循环（纯内建空转，SIGTERM
        #   都难杀掉，只能 SIGKILL）。守卫一律放在取值之前。
        --offset-max)    [ $# -ge 2 ] || { err "--offset-max 需要一个参数（秒）"; usage; exit 2; }
                         OFFSET_MAX="$2"; shift 2 ;;
        --ppm-max)       [ $# -ge 2 ] || { err "--ppm-max 需要一个参数（ppm）"; usage; exit 2; }
                         PPM_MAX="$2";    shift 2 ;;
        --rtc-tol)       [ $# -ge 2 ] || { err "--rtc-tol 需要一个参数（秒）"; usage; exit 2; }
                         RTC_TOL="$2";    shift 2 ;;
        --bmc-tol)       [ $# -ge 2 ] || { err "--bmc-tol 需要一个参数（秒）"; usage; exit 2; }
                         BMC_TOL="$2";    shift 2 ;;
        --fix-tol)       [ $# -ge 2 ] || { err "--fix-tol 需要一个参数（秒）"; usage; exit 2; }
                         FIX_TOL="$2"; shift 2 ;;
        --drift-min)     [ $# -ge 2 ] || { err "--drift-min 需要一个参数（分钟）"; usage; exit 2; }
                         DRIFT_MIN="$2";  shift 2 ;;
        --drift-max)     [ $# -ge 2 ] || { err "--drift-max 需要一个参数（ppm）"; usage; exit 2; }
                         DRIFT_MAX="$2";  shift 2 ;;
        --ref-ntp)       [ $# -ge 2 ] || { err "--ref-ntp 需要一个参数（时间源，可逗号分隔）"; usage; exit 2; }
                         REF_NTP="$2";    shift 2 ;;
        --ref-host)      [ $# -ge 2 ] || { err "--ref-host 需要一个参数（USER@IP）"; usage; exit 2; }
                         REF_HOST="$2";   shift 2 ;;
        --bmc)           [ $# -ge 2 ] || { err "--bmc 需要一个参数（BMC 地址）"; usage; exit 2; }
                         BMC_IP="$2";     shift 2 ;;
        -U)              [ $# -ge 2 ] || { err "-U 需要一个参数（BMC 用户名）"; usage; exit 2; }
                         BMC_USER="$2";   shift 2 ;;
        -P)              [ $# -ge 2 ] || { err "-P 需要一个参数（BMC 密码）"; usage; exit 2; }
                         BMC_PASS="$2";   shift 2 ;;
        --)              shift; break ;;
        -*)              err "未知参数：$1"; usage; exit 2 ;;
        *)               err "多余的位置参数：$1"; usage; exit 2 ;;
    esac
done

is_num()   { case "${1:-}" in ''|*[!0-9.]*) return 1 ;; esac; return 0; }
is_uint()  { case "${1:-}" in ''|*[!0-9]*)  return 1 ;; esac; return 0; }

for _p in "OFFSET_MAX:$OFFSET_MAX" "PPM_MAX:$PPM_MAX" "RTC_TOL:$RTC_TOL" \
          "BMC_TOL:$BMC_TOL" "FIX_TOL:$FIX_TOL" "DRIFT_MAX:$DRIFT_MAX"; do
    _n="${_p%%:*}"; _v="${_p#*:}"
    is_num "$_v" || { err "$_n 必须是数字，收到 '$_v'"; exit 2; }
done
is_uint "$DRIFT_MIN" || { err "--drift-min 必须是非负整数（分钟），收到 '$DRIFT_MIN'"; exit 2; }
if [ -n "$BMC_IP" ] && [ -z "$BMC_USER" ]; then
    warn "给了 --bmc 但没给 -U（BMC 用户名），BMC 段可能失败"
fi
if [ "$DO_LIST" = "1" ] && [ "$DRIFT_MIN" -gt 0 ]; then
    info "--list 模式跳过走时漂移长测"
    DRIFT_MIN=0
fi

IS_ROOT=0
[ "$(id -u 2>/dev/null)" = "0" ] && IS_ROOT=1

# ---------- 平台守卫 ----------
# 本脚本面向 Linux 被测机。在 Windows/MSYS/macOS 上跑会「读不到 RTC」，
# 那是平台不对，不是机器不合格 —— 直接拦掉，避免报假失败。
_os="$(uname -s 2>/dev/null || echo unknown)"
case "$_os" in
    Linux) : ;;
    *)
        err "本脚本只能在 Linux 上运行（当前 uname -s = ${_os}）"
        info "请在 Ubuntu 22.04 被测机上执行：sudo bash time.sh"
        exit 2
        ;;
esac

# ---------- 判定累加器 ----------
N_PASS=0; N_FAIL=0; N_PEND=0
SEC_P=0; SEC_F=0; SEC_D=0

verdict() {  # verdict <PASS|FAIL|Pending> <文字>
    if [ "$DO_LIST" = "1" ]; then
        info "[$1] $2"
        return 0
    fi
    case "$1" in
        PASS) N_PASS=$((N_PASS+1)); ok "$2" ;;
        FAIL) N_FAIL=$((N_FAIL+1)); err "$2" ;;
        *)    N_PEND=$((N_PEND+1)); warn "$2" ;;
    esac
}

sec_begin() { SEC_P=$N_PASS; SEC_F=$N_FAIL; SEC_D=$N_PEND; }
sec_end() {  # sec_end <段名>
    if [ "$DO_LIST" = "1" ]; then return 0; fi
    local p=$((N_PASS-SEC_P)) f=$((N_FAIL-SEC_F)) d=$((N_PEND-SEC_D))
    # ★「没执行」不等于「通过」：0 条判定 = 未验证，不能报 PASS
    if [ "$p" -eq 0 ] && [ "$f" -eq 0 ] && [ "$d" -eq 0 ]; then
        echo -e "   ${BLUE}→ ${1} 判定：跳过（本段未执行 / 不适用，不计入判定）${NC}"
    elif [ "$f" -gt 0 ]; then
        echo -e "   ${RED}→ ${1} 判定：FAIL（PASS $p / FAIL $f / Pending $d）${NC}"
    elif [ "$d" -gt 0 ]; then
        echo -e "   ${YELLOW}→ ${1} 判定：Pending（PASS $p / FAIL $f / Pending $d）${NC}"
    else
        echo -e "   ${GREEN}→ ${1} 判定：PASS（PASS $p）${NC}"
    fi
}
sec_head() { echo; echo -e "${BLUE}==================== ${1} ====================${NC}"; }

# ============================================================
# 通用取值小工具
# ============================================================

field_after() {  # field_after "<关键字>" "<多行文本>" → 冒号后的内容（容忍前导空白）
    # ★ 不能要求关键字在行首：`timedatectl timesync-status` 是【右对齐】输出
    #   （`       Offset: +316us`），行首匹配会静默取不到值，再把 0 当成结果。
    printf '%s\n' "$2" | awk -v k="$1" '{ sub(/^[ \t]+/, "") } index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }'
}

first_num() {  # 抽出第一个数字（可带正负号）
    printf '%s' "${1:-}" | grep -oE '[-+]?[0-9]+(\.[0-9]+)?' | head -1
}

parse_dur() {  # "+1.234ms" / "0.000123456 seconds fast of NTP time" → 秒
    local raw="${1:-}" raw2 num unit
    raw2="$(printf '%s' "$raw" | LC_ALL=C sed 's/\xc2\xb5s/us/g')"
    num="$(first_num "$raw2")"
    [ -n "$num" ] || return 1
    unit="$(printf '%s' "$raw2" | grep -oE '[a-zA-Z]+' | head -1)"
    case "$unit" in
        ms) awk -v n="$num" 'BEGIN{printf "%.9f", n/1000}' ;;
        us) awk -v n="$num" 'BEGIN{printf "%.9f", n/1000000}' ;;
        ns) awk -v n="$num" 'BEGIN{printf "%.9f", n/1000000000}' ;;
        ppm) awk -v n="$num" 'BEGIN{printf "%.3f", n}' ;;
        *)  awk -v n="$num" 'BEGIN{printf "%.9f", n}' ;;
    esac
}

apply_sign() {  # apply_sign <数字> <原文> —— 原文没有显式正负号时，靠 fast/slow 判
    local n="${1:-}" t="${2:-}"
    case "$n" in
        -*) printf '%s' "$n" ;;
        +*) printf '%s' "${n#+}" ;;
        *)  case "$t" in
                *slow*|*" slower"*) printf -- '-%s' "$n" ;;
                *)                  printf '%s' "$n" ;;
            esac ;;
    esac
}

absf() { awk -v v="${1:-0}" 'BEGIN{printf "%.6f", (v<0?-v:v)}'; }
le()   { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{print (a<=b)?1:0}'; }

rtc_sysfs_epoch() {  # 直读 sysfs 的 RTC 墙上时间，按「该读数即 UTC」换算成 epoch
    # 跨日翻转时两次 date 读数会不一致 → 直接失败：宁可报「取不到」也不给错数
    local d1 t d2
    d1="$(cat "$RTC_SYS/date" 2>/dev/null | tr -d ' \t\r\n')"
    t="$(cat "$RTC_SYS/time" 2>/dev/null | tr -d ' \t\r\n')"
    d2="$(cat "$RTC_SYS/date" 2>/dev/null | tr -d ' \t\r\n')"
    [ -n "$d1" ] && [ -n "$t" ] || return 1
    [ "$d1" = "$d2" ] || return 1
    TZ=UTC date -d "$d1 $t" +%s 2>/dev/null || return 1
}

rtc_judge() {  # rtc_judge <偏差绝对值> <来源说明> —— 三态判定集中一处
    local d="${1:-0}"
    if [ "$REF_LEVEL" = "L3" ]; then
        # ★ L3 无参考系：只能判「一致性」，绝对精度未验证 —— 一律 Pending，绝不给 PASS。
        #   否则「系统时间和 RTC 被一起设错」（装机现场很常见）会因偏差为 0 而报绿，
        #   那只是「一致」，不是「准」，属于报假绿。
        if [ "$(le "$d" "$RTC_TOL")" = "1" ]; then
            verdict Pending "RTC 与系统时间一致（偏差 ${d}s ≤ 容差 ${RTC_TOL}s；来源：$2）—— 但无参考系，只能判「一致性」，绝对精度未验证"
        else
            verdict Pending "RTC 与系统时间偏差 ${d}s 超容差 ${RTC_TOL}s —— 但系统时间本身未与外部源同步，无法判断是谁不准"
        fi
    elif [ "$(le "$d" "$RTC_TOL")" = "1" ]; then
        verdict PASS "RTC 与系统时间偏差 ${d}s（容差 ${RTC_TOL}s；来源：$2；参考系 ${REF_LEVEL}）"
    else
        verdict FAIL "RTC 与系统时间偏差 ${d}s 超容差 ${RTC_TOL}s（参考系 ${REF_LEVEL} 可信，说明 RTC 偏了）"
    fi
}

# ============================================================
# 阶段 A：静默探测（先定参考系，再做判定）
# ============================================================
echo -e "${BLUE}==================== 环境与参考系 ====================${NC}"

VIRT="unknown"
if have systemd-detect-virt; then
    VIRT="$(systemd-detect-virt 2>/dev/null)"
    [ -n "$VIRT" ] || VIRT="none"
fi
# 没有 systemd-detect-virt 时补一层容器探测 —— 容器里没有 RTC 是正常的，
# 不能因此判 FAIL（这正是「报假失败」的典型场景）
if [ "$VIRT" = "unknown" ]; then
    if [ -f /.dockerenv ] || grep -qaE 'docker|lxc|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        VIRT="container"
    fi
fi
echo "主机名        : $(hostname 2>/dev/null || echo '?')"
echo "内核          : $(uname -sr 2>/dev/null || echo '?')"
echo "虚拟化        : ${VIRT}"
echo "运行身份      : $([ "$IS_ROOT" = 1 ] && echo 'root' || echo '非 root（RTC 偏差项可能取不到，建议 sudo）')"

# ---------- RTC 设备 ----------
RTC_SYS="${RTC_SYS:-/sys/class/rtc/rtc0}"
ADJTIME_FILE="${ADJTIME_FILE:-/etc/adjtime}"
RTC_DEV=""
for _d in /dev/rtc0 /dev/rtc; do
    [ -e "$_d" ] && { RTC_DEV="$_d"; break; }
done
if [ -z "$RTC_DEV" ]; then
    RTC_DEV="$(ls /dev/rtc* 2>/dev/null | head -1)"
fi
RTC_PRESENT=0
{ [ -n "$RTC_DEV" ] || [ -d "$RTC_SYS" ]; } && RTC_PRESENT=1

rtc_epoch() {  # RTC 的秒计数（免 root，走 sysfs）
    [ -r "$RTC_SYS/since_epoch" ] || return 1
    cat "$RTC_SYS/since_epoch" 2>/dev/null
}

# ---------- RTC 时区口径（① 段的 sysfs 降级与 ② 段的判定都要用，故提前探） ----------
# ★ systemd 的属性名是 LocalRTC；RTCInLocalTZ 只是 `timedatectl status` 的
#   人类可读标签「RTC in local TZ:」，用 `show -p` 查不到（真机实测）。
RTC_IN_LOCAL=""
RTC_TZ_SRC=""
TZ_NAME=""
NTP_SD=""
if have timedatectl && timedatectl show >/dev/null 2>&1; then
    for _p in LocalRTC RTCInLocalTZ; do
        _v="$(timedatectl show -p "$_p" --value 2>/dev/null || true)"
        case "$_v" in
            yes|no) RTC_IN_LOCAL="$_v"; RTC_TZ_SRC="timedatectl ${_p}"; break ;;
        esac
    done
    TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    NTP_SD="$(timedatectl show -p NTP --value 2>/dev/null || true)"
fi
if [ -z "$RTC_IN_LOCAL" ] && [ -r "$ADJTIME_FILE" ]; then
    _adj="$(sed -n '3p' "$ADJTIME_FILE" 2>/dev/null | tr -d ' \t\r' | tr 'a-z' 'A-Z')"
    case "$_adj" in
        UTC)   RTC_IN_LOCAL="no";  RTC_TZ_SRC="$ADJTIME_FILE" ;;
        LOCAL) RTC_IN_LOCAL="yes"; RTC_TZ_SRC="$ADJTIME_FILE" ;;
    esac
fi

# ---------- NTP 客户端探测 ----------
NTP_UNIT=""
if have systemctl; then
    for _u in chronyd chrony ntp ntpsec systemd-timesyncd; do
        if systemctl cat "$_u" >/dev/null 2>&1; then NTP_UNIT="$_u"; break; fi
    done
fi
if [ -z "$NTP_UNIT" ]; then
    if have chronyc; then NTP_UNIT="chronyd"
    elif have ntpq; then NTP_UNIT="ntp"
    elif have timedatectl && timedatectl show >/dev/null 2>&1; then NTP_UNIT="systemd-timesyncd"
    fi
fi

NTP_KIND=""
case "$NTP_UNIT" in
    chronyd|chrony)     NTP_KIND="chrony" ;;
    ntp|ntpsec)         NTP_KIND="ntpd" ;;
    systemd-timesyncd)  NTP_KIND="timesyncd" ;;
esac

NTP_ACTIVE=no; NTP_ENABLED=no
if have systemctl && [ -n "$NTP_UNIT" ]; then
    systemctl is-active  --quiet "$NTP_UNIT" 2>/dev/null && NTP_ACTIVE=yes
    systemctl is-enabled --quiet "$NTP_UNIT" 2>/dev/null && NTP_ENABLED=yes
fi

# ---------- 采集 NTP 细节 ----------
NTP_PROBE_ERR=""
NTP_SYNCED_OK=0
LEAP=""
CUR_OFF_RAW=""; CUR_OFF=""; CUR_OFF_ABS=""
CUR_FREQ_RAW=""; CUR_FREQ=""; CUR_FREQ_ABS=""
N_SRC=0; N_SYNC=0; N_REACH=0
NTP_DETAIL=""

case "$NTP_KIND" in
    chrony)
        TRK="$(chronyc tracking 2>&1 || true)"
        if printf '%s' "$TRK" | grep -qE 'Cannot talk to daemon|Could not connect|Connection refused|^506 '; then
            NTP_PROBE_ERR="chronyc 连不上 chronyd（506 Cannot talk to daemon）"
        else
            LEAP="$(field_after 'Leap status' "$TRK")"
            # ★ 取不到就留空，绝不 `|| echo 0`（那会把「读不到」伪装成「偏差 0，达标」）
            CUR_OFF_RAW="$(field_after 'System time' "$TRK")"
            if [ -n "$CUR_OFF_RAW" ]; then
                if CUR_OFF="$(parse_dur "$CUR_OFF_RAW")"; then
                    CUR_OFF="$(apply_sign "$CUR_OFF" "$CUR_OFF_RAW")"
                    CUR_OFF_ABS="$(absf "$CUR_OFF")"
                fi
            fi
            CUR_FREQ_RAW="$(field_after 'Frequency' "$TRK")"
            if [ -n "$CUR_FREQ_RAW" ]; then
                if CUR_FREQ="$(parse_dur "$CUR_FREQ_RAW")"; then
                    CUR_FREQ="$(apply_sign "$CUR_FREQ" "$CUR_FREQ_RAW")"
                    CUR_FREQ_ABS="$(absf "$CUR_FREQ")"
                fi
            fi

            SRC="$(chronyc sources 2>&1 || true)"
            # 注意：Reach 是八进制，这里只判「非 0」，不做数值换算
            # ★ 用 herestring 而不是 heredoc —— 未加引号的 heredoc 会展开 awk 里的 $1/$5
            _cnt="$(printf '%s\n' "$SRC" | awk '
    /^\^/ { n++; if (substr($1,2,1)=="*") s++; if ($5+0>0) r++ }
    END { printf "%d %d %d", n+0, s+0, r+0 }')"
            read -r N_SRC N_SYNC N_REACH <<<"$_cnt"
            NTP_DETAIL="$(printf '%s\n' "$SRC" | grep -E '^\^' | head -4)"
        fi
        ;;
    ntpd)
        RV="$(ntpq -c rv 2>&1 || true)"
        NP="$(ntpq -pn 2>&1 || true)"
        if printf '%s' "$RV" | grep -qiE 'connection refused|cannot|timed out|no response'; then
            NTP_PROBE_ERR="ntpq 连不上 ntpd"
        else
            CUR_OFF_RAW="$(printf '%s' "$RV" | grep -oE 'offset=[-0-9.]+'    | head -1 | cut -d= -f2)"
            CUR_FREQ_RAW="$(printf '%s' "$RV" | grep -oE 'frequency=[-0-9.]+' | head -1 | cut -d= -f2)"
            # ★ 同样不填 0：取不到就留空
            if [ -n "$CUR_OFF_RAW" ]; then
                CUR_OFF="$(apply_sign "$CUR_OFF_RAW" "$CUR_OFF_RAW")"
                CUR_OFF_ABS="$(absf "$CUR_OFF")"
            fi
            if [ -n "$CUR_FREQ_RAW" ]; then
                CUR_FREQ="$(apply_sign "$CUR_FREQ_RAW" "$CUR_FREQ_RAW")"
                CUR_FREQ_ABS="$(absf "$CUR_FREQ")"
            fi
            _cnt="$(printf '%s\n' "$NP" | awk '
    $1=="remote" { next }
    /^=+/        { next }
    NF>=10 { n++; if ($1 ~ /^\*/) s++; if ($7+0>0) r++ }
    END { printf "%d %d %d", n+0, s+0, r+0 }')"
            read -r N_SRC N_SYNC N_REACH <<<"$_cnt"
            NTP_DETAIL="$(printf '%s\n' "$NP" | grep -E '^[*+#o.x-]' | head -4)"
            [ "$N_SYNC" -gt 0 ] && LEAP="Normal"
        fi
        ;;
    timesyncd)
        SYNCED_FLAG="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '')"
        [ "$SYNCED_FLAG" = "yes" ] && LEAP="Normal"
        TSS="$(timedatectl timesync-status 2>&1 || true)"
        # ★ 取不到就留空，绝不 `|| echo 0` —— 填 0 会把「读不到」伪装成「偏差 0，达标」
        CUR_OFF_RAW="$(field_after 'Offset' "$TSS")"
        if [ -n "$CUR_OFF_RAW" ]; then
            if CUR_OFF="$(parse_dur "$CUR_OFF_RAW")"; then
                CUR_OFF_ABS="$(absf "$CUR_OFF")"
            fi
        fi
        CUR_FREQ_RAW="$(field_after 'Frequency' "$TSS")"
        if [ -n "$CUR_FREQ_RAW" ]; then
            if CUR_FREQ="$(parse_dur "$CUR_FREQ_RAW")"; then
                CUR_FREQ_ABS="$(absf "$CUR_FREQ")"
            fi
        fi
        SRV_LINE="$(field_after 'Server' "$TSS")"
        [ -n "$SRV_LINE" ] && NTP_DETAIL="上游：$SRV_LINE"
        N_SRC=1
        [ "$SYNCED_FLAG" = "yes" ] && N_SYNC=1 && N_REACH=1
        ;;
esac

if [ "$NTP_KIND" = "chrony" ] && [ -z "$NTP_PROBE_ERR" ]; then
    [ "$LEAP" = "Normal" ] && [ "$N_SYNC" -gt 0 ] && NTP_SYNCED_OK=1
elif [ "$NTP_KIND" = "ntpd" ] && [ -z "$NTP_PROBE_ERR" ]; then
    [ "$N_SYNC" -gt 0 ] && NTP_SYNCED_OK=1
elif [ "$NTP_KIND" = "timesyncd" ]; then
    [ "$LEAP" = "Normal" ] && NTP_SYNCED_OK=1
fi

# ---------- 参考系定级（L0 → L1 → L2 → L3） ----------
REF_LEVEL="L3"
REF_DESC="L3 无参考系 —— 只能判「一致性」，绝对精度未验证"

ref_ntp_offset() {  # → 秒；失败返回 1
    local srv="${1:-}" out="" v=""
    if have ntpdate; then
        out="$(ntpdate -q -t 5 "$srv" 2>&1 || true)"
        v="$(printf '%s\n' "$out" | grep -oE 'offset [+-]?[0-9.]+' | head -1 | awk '{print $2}')"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    if have sntp; then
        out="$(sntp -t 3 "$srv" 2>&1 || true)"
        v="$(printf '%s\n' "$out" | grep -oE '^[+-]?[0-9]+\.[0-9]+' | head -1)"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    return 1
}

ref_host_ok() {  # 控制机自己是否已同步
    local h="${1:-}" r=""
    r="$(ssh $SSH_OPTS "$h" 'if command -v chronyc >/dev/null 2>&1; then chronyc tracking 2>/dev/null | grep -i "Leap status"; else timedatectl show -p NTPSynchronized --value 2>/dev/null; fi' 2>/dev/null || true)"
    case "$r" in *Normal*|*yes*) return 0 ;; esac
    return 1
}

ref_host_offset() {  # → "offset delay"；失败返回 1
    local h="${1:-}" t1 t4 tr out=""
    t1="$(date +%s.%N 2>/dev/null)" || return 1
    out="$(ssh $SSH_OPTS "$h" 'date +%s.%N' 2>/dev/null || true)"
    t4="$(date +%s.%N 2>/dev/null)" || return 1
    tr="$(printf '%s' "$out" | grep -oE '^[0-9]+\.[0-9]+' | head -1)"
    [ -n "$tr" ] || return 1
    awk -v a="$t1" -v b="$tr" -v c="$t4" 'BEGIN{
        printf "%.6f %.6f", b - (a+c)/2, c - a
    }'
}

if [ -n "$REF_NTP" ]; then
    _oldifs="$IFS"; IFS=','
    set -f                       # 关掉 glob，避免时间源里的 * 被展开
    for _s in $REF_NTP; do
        _s="$(printf '%s' "$_s" | tr -d ' \t')"
        [ -n "$_s" ] || continue
        if _o="$(ref_ntp_offset "$_s")"; then
            REF_LEVEL="L0"
            REF_DESC="L0 外部 NTP 真值源 ${_s}（查询偏差 ${_o}s）"
            break
        fi
    done
    set +f
    IFS="$_oldifs"
fi

if [ "$REF_LEVEL" = "L3" ] && [ "$NTP_SYNCED_OK" = "1" ]; then
    REF_LEVEL="L1"
    REF_DESC="L1 已同步的系统时间（${NTP_KIND}，偏差 ${CUR_OFF_ABS:-?}s，Leap=${LEAP:-?}）"
fi

if [ "$REF_LEVEL" = "L3" ] && [ -n "$REF_HOST" ]; then
    if ref_host_ok "$REF_HOST"; then
        if _ro="$(ref_host_offset "$REF_HOST")"; then
            REF_LEVEL="L2"
            REF_DESC="L2 控制机 ${REF_HOST}（偏差 $(printf '%s' "$_ro" | awk '{print $1}')s，往返时延 $(printf '%s' "$_ro" | awk '{print $2}')s）"
        else
            note "--ref-host $REF_HOST 可达但取不到时间戳（SSH 免密？）"
        fi
    else
        note "--ref-host $REF_HOST 自身未与外部时间源同步，不能当参考（参考系不能是另一个不确定的钟）"
    fi
fi

echo "参考系        : ${REF_DESC}"
if [ -n "$REF_HOST" ] && [ "$REF_LEVEL" != "L2" ]; then
    echo "              （已给 --ref-host 但未采用：当前已有更高等级参考系或该机不可用）"
fi

# ============================================================
# ① RTC 硬件段
# ============================================================
sec_head "① RTC 硬件"
sec_begin

if [ "$SKIP_RTC" = "1" ]; then
    info "按 --no-rtc-check 跳过本段"
else
    # 1) 设备在位
    if [ "$RTC_PRESENT" = "1" ]; then
        verdict PASS "RTC 设备在位：${RTC_DEV:-$RTC_SYS}"
    else
        case "$VIRT" in
            none|unknown) verdict FAIL "未发现 RTC 设备（/dev/rtc0 与 $RTC_SYS 都不存在）" ;;
            *)            verdict Pending "未发现 RTC 设备 —— 当前是虚拟化环境（$VIRT），本来就没有 RTC" ;;
        esac
    fi

    # 2) 在不在走（★ 抓「电池没电导致 RTC 停走」）
    if [ "$RTC_PRESENT" = "1" ]; then
        _ra="$(rtc_epoch 2>/dev/null || true)"
        _s0="$(date +%s.%N 2>/dev/null || date +%s)"
        sleep 2
        _rb="$(rtc_epoch 2>/dev/null || true)"
        _s1="$(date +%s.%N 2>/dev/null || date +%s)"
        if is_uint "$_ra" && is_uint "$_rb"; then
            _d=$(( _rb - _ra ))
            _e="$(awk -v x="$_s0" -v y="$_s1" 'BEGIN{printf "%.2f", y-x}')"
            if [ "$_d" -le 0 ]; then
                verdict FAIL "RTC 已停走：${_e}s 内秒计数增量只有 ${_d}s（晶振或纽扣电池失效的典型症状）"
            elif [ "$_d" -ge 1 ]; then
                verdict PASS "RTC 在走：${_e}s 内走了 ${_d}s"
            else
                verdict Pending "RTC 秒计数异常（增量 ${_d}）"
            fi
        else
            verdict Pending "读不到 RTC 秒计数（$RTC_SYS/since_epoch），无法判断是否在走"
        fi
    fi

    # 3) RTC 与系统时间偏差
    if [ "$IS_ROOT" != "1" ]; then
        verdict Pending "需要 root 才能读 RTC 偏差，请 sudo 重跑"
    elif have hwclock; then
        _hc="$(hwclock --compare 2>&1 || true)"
        _hd="$(printf '%s\n' "$_hc" | awk '/Time diff/ { for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]/) { print $i; exit } }')"
        if [ -z "$_hd" ]; then
            verdict Pending "hwclock --compare 无有效输出，取不到 RTC 偏差"
        else
            rtc_judge "$(absf "$_hd")" "hwclock --compare"
        fi
    else
        # 降级：没装 hwclock 也能直读 sysfs 的 RTC 墙上时间
        # （Ubuntu 24.04 起 hwclock 已不随系统发布，真机上同样会缺）
        _re="$(rtc_sysfs_epoch 2>/dev/null || true)"
        if [ -z "$_re" ]; then
            verdict Pending "没装 hwclock，且读不到 $RTC_SYS/{date,time}，无法取 RTC 偏差"
            note "装法：apt-get install -y util-linux-extra（Ubuntu 22.04 上是 util-linux）"
        else
            _hs="$(date +%s)"
            _ha="$(absf "$(( _re - _hs ))")"
            if [ "$RTC_IN_LOCAL" = "no" ]; then
                rtc_judge "$_ha" "sysfs 直读（口径已确认为 UTC）"
            elif [ "$RTC_IN_LOCAL" = "yes" ]; then
                info "sysfs 直读 RTC 与系统时间相差 ${_ha}s（RTC 存本地时间，该差值含时区偏移）"
                verdict Pending "没装 hwclock，且 RTC 口径为本地时间，无法单独算出真实偏差"
            else
                info "sysfs 直读 RTC 与系统时间相差 ${_ha}s（RTC 时区口径未知，该差值含时区偏移）"
                verdict Pending "没装 hwclock，且 RTC 时区口径未知，本项不可得 —— 装上 hwclock 或确认口径后复测"
            fi
        fi
    fi

    note "电池【电压】不在本脚本范围，请看 bat.sh（本脚本测 RTC 功能，两者互补）"
fi
sec_end "① RTC 硬件"

# ============================================================
# ② RTC 时区口径段
# ============================================================
sec_head "② RTC 时区口径"
sec_begin

# 口径探测已在「阶段 A」完成（① 段的降级路径也要用），这里只做判定
[ -n "$TZ_NAME" ] && info "系统时区：$TZ_NAME（UTC 或 Asia/Shanghai 都正常，不作为判定项）"
[ -n "$NTP_SD" ]  && info "systemd 托管 NTP：$NTP_SD"
[ -n "$RTC_TZ_SRC" ] && info "口径来源：$RTC_TZ_SRC"

if [ -z "$RTC_IN_LOCAL" ]; then
    verdict Pending "读不到 RTC 时区口径（timedatectl 没有 LocalRTC 属性，且 $ADJTIME_FILE 不存在）"
    note "$ADJTIME_FILE 由 hwclock / systemd 首次校时时才生成，全新系统上本就不存在，属正常"
    note "装上 hwclock（apt-get install -y util-linux-extra）后重跑，即可判定本项"
elif [ "$RTC_IN_LOCAL" = "no" ]; then
    verdict PASS "RTC 存的是 UTC（符合 Linux 惯例，跨时区/夏令时不会跳）"
else
    verdict FAIL "RTC 存的是【本地时间】—— 跨时区或夏令时会跳变，应执行：timedatectl set-local-rtc 0"
fi
sec_end "② RTC 时区口径"

# ============================================================
# ③ NTP 同步段
# ============================================================
sec_head "③ NTP 同步"
sec_begin

if [ -z "$NTP_KIND" ]; then
    verdict Pending "未装任何 NTP 客户端（chronyd / ntpd / systemd-timesyncd 都没有）—— 机器本身没毛病，属环境未配置，待环境就绪后复测"
else
    verdict PASS "NTP 客户端：${NTP_KIND}（unit：${NTP_UNIT}）"

    if [ "$NTP_ACTIVE" = "yes" ]; then
        verdict PASS "服务运行中（${NTP_UNIT} active）"
    else
        verdict FAIL "客户端已安装但服务未运行 —— systemctl start ${NTP_UNIT}"
    fi

    if [ "$NTP_ENABLED" = "yes" ]; then
        verdict PASS "已设开机自启（重启后会自动同步）"
    else
        verdict FAIL "未设开机自启 —— 重启后不会自动同步：systemctl enable ${NTP_UNIT}"
    fi

    if [ -n "$NTP_PROBE_ERR" ]; then
        verdict FAIL "$NTP_PROBE_ERR"
    else
        # 上游源
        case "$NTP_KIND" in
            timesyncd)
                if [ -n "$NTP_DETAIL" ]; then
                    info "$NTP_DETAIL"
                    verdict PASS "上游源已配置（systemd-timesyncd）"
                else
                    # 取不到 Server 行就不报 PASS —— 无证据的合格等于假绿
                    verdict Pending "取不到上游源信息（timesync-status 无 Server 行）—— 通常意味着还没同步成功"
                fi
                ;;
            *)
                if [ "$N_SRC" -eq 0 ]; then
                    verdict FAIL "未配置任何 NTP 源（上游列表为空）"
                elif [ "$N_REACH" -eq 0 ]; then
                    verdict FAIL "所有 NTP 源都不可达（Reach 全 0）—— 检查网络与防火墙 UDP/123"
                elif [ "$N_SYNC" -eq 0 ]; then
                    verdict FAIL "没有任何源被选中同步（${N_SRC} 个源，0 个 ^*）—— 源质量或层级有问题"
                else
                    verdict PASS "NTP 上游可达：共 ${N_SRC} 个源，${N_SYNC} 个已选中，${N_REACH} 个可达"
                    [ "$N_SRC" -lt 2 ] && note "只配了 ${N_SRC} 个源，无冗余，建议至少 2 个"
                fi
                [ -n "$NTP_DETAIL" ] && info "$NTP_DETAIL"
                ;;
        esac

        # 同步状态
        if [ "$NTP_SYNCED_OK" = "1" ]; then
            verdict PASS "同步状态正常（Leap status: ${LEAP:-Normal}）"
        else
            verdict FAIL "未同步上（Leap status: ${LEAP:-未知}）—— 检查上游配置与网络"
        fi

        # 当前偏差（同步质量指标，超线判 FAIL）
        if [ "$NTP_SYNCED_OK" != "1" ]; then
            note "未同步，跳过偏差判定（此时 offset 无意义）"
        elif [ -z "$CUR_OFF_ABS" ]; then
            verdict Pending "本客户端不提供 offset 读数（systemd-timesyncd 老版本），本项不可得 —— 不填 0"
        elif [ "$(le "$CUR_OFF_ABS" "$OFFSET_MAX")" = "1" ]; then
            verdict PASS "与参考源的偏差 ${CUR_OFF_ABS}s（≤ ${OFFSET_MAX}s）"
        else
            verdict FAIL "与参考源的偏差 ${CUR_OFF_ABS}s 超上限 ${OFFSET_MAX}s"
        fi

        # 频率偏差（硬件晶振指标，按设计只记录）
        if [ -n "$CUR_FREQ_ABS" ]; then
            if [ "$(le "$CUR_FREQ_ABS" "$PPM_MAX")" = "1" ]; then
                verdict PASS "时钟频率偏差 ${CUR_FREQ_ABS} ppm（≤ 提示线 ${PPM_MAX} ppm）"
            else
                note "时钟频率偏差 ${CUR_FREQ_ABS} ppm 超提示线 ${PPM_MAX} ppm —— 属晶振偏老，不影响交付，按设计只记录"
                verdict PASS "时钟频率偏差 ${CUR_FREQ_ABS} ppm（已记录，未参与判定）"
            fi
        fi
    fi
fi
sec_end "③ NTP 同步"

# ============================================================
# ④ BMC 时间段（可选；只有 --fix 才写）
# ============================================================
sec_head "④ BMC 时间"
sec_begin

FIX_BLOCKED=0

# ---- 通道选择：给了 --bmc 走网络；否则试本机系统接口（免密，需 root） ----
BMC_CH_DESC=""
BMC_ARGV_DISPLAY=""
BMC_ARGV=()
BMC_TRY=0
if [ -n "$BMC_IP" ]; then
    BMC_TRY=1
    BMC_ARGV=(-I lanplus -H "$BMC_IP")
    [ -n "$BMC_USER" ] && BMC_ARGV+=(-U "$BMC_USER")
    [ -n "$BMC_PASS" ] && BMC_ARGV+=(-P "$BMC_PASS")
    # shellcheck disable=SC2206
    [ -n "$IPMI_OPTS" ] && BMC_ARGV+=($IPMI_OPTS)
    BMC_CH_DESC="网络 lanplus ${BMC_IP}"
    # ★ 回显用的串必须把密码掩掉，别把 -P 的真实值打进日志
    BMC_ARGV_DISPLAY="-I lanplus -H ${BMC_IP} -U ${BMC_USER:-<user>} -P <pass>"
elif [ "$IS_ROOT" = "1" ] && { [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ]; }; then
    BMC_TRY=1
    BMC_ARGV=(-I open)
    BMC_CH_DESC="本机系统接口 -I open（免密）"
    BMC_ARGV_DISPLAY="-I open"
fi

if [ "$BMC_TRY" != "1" ]; then
    info "未给 --bmc，且本机系统接口不可用，本段跳过"
    note "两种用法：① 本机 sudo 重跑（走 -I open，免密）；② --bmc <IP> -U <用户> -P '<密码>' 走网络"
elif ! have ipmitool; then
    verdict Pending "没装 ipmitool，无法读 BMC 时间"
    note "装法：apt-get install -y ipmitool"
else
    info "通道：${BMC_CH_DESC}"

    _raw="$(ipmitool "${BMC_ARGV[@]}" sel time get 2>/dev/null || true)"
    _via="sel time get"
    if [ -z "$_raw" ]; then
        _raw="$(ipmitool "${BMC_ARGV[@]}" mc selftime get 2>/dev/null || true)"
        _via="mc selftime get"
        [ -n "$_raw" ] && note "sel time get 不支持，已回退 mc selftime get"
    fi
    _raw="$(printf '%s' "$_raw" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')"

    if [ -z "$_raw" ]; then
        verdict Pending "读不到 BMC 时间（两种命令都失败）—— 检查 IP / 账号 / 网络，或本机 IPMI 驱动"
    else
        _be="$(TZ=UTC date -d "$_raw" +%s 2>/dev/null || true)"
        if [ -z "$_be" ]; then
            verdict Pending "BMC 返回的时间格式无法解析：$_raw"
        else
            _bd=$(( _be - $(date +%s) ))
            _bda="$(absf "$_bd")"
            info "BMC 时间（$_via）：$_raw"
            info "本机 UTC         ：$(date -u '+%m/%d/%Y %H:%M:%S')"
            if [ "$(le "$_bda" "$BMC_TOL")" = "1" ]; then
                verdict PASS "BMC 时间与系统时间偏差 ${_bd}s（容差 ${BMC_TOL}s）"
            else
                note "BMC 时间与系统时间偏差 ${_bd}s 超容差 ${BMC_TOL}s —— BMC 时钟普遍不准且不接 NTP，按设计只记录"
                verdict PASS "BMC 时间偏差 ${_bd}s（已记录，未参与判定）"
            fi

            # ---- --fix：校准 BMC 时间（默认不做，只读是主行为） ----
            if [ "$DO_FIX" = "1" ]; then
                # ★ 硬门禁：本机时间必须可信，否则拒绝写
                if [ -z "$NTP_KIND" ] || [ "$NTP_ACTIVE" != "yes" ] || [ "$NTP_SYNCED_OK" != "1" ]; then
                    FIX_BLOCKED=1
                    err "拒绝校准：前置条件不满足 —— 本机时间校验工具必须【在运行且已联网同步】"
                    note "当前：客户端=${NTP_KIND:-无}  active=${NTP_ACTIVE}  已同步=${NTP_SYNCED_OK}（Leap=${LEAP:-?}）"
                    note "本机时间不可信时拿它校准 BMC，等于把错误传播出去 —— 未对 BMC 做任何写操作"
                else
                    _ts="$(date -u '+%m/%d/%Y %H:%M:%S')"
                    _out="$(ipmitool "${BMC_ARGV[@]}" sel time set "$_ts" 2>&1)"
                    _rc=$?
                    info "执行：ipmitool ${BMC_ARGV_DISPLAY} sel time set \"$_ts\""
                    [ -n "$_out" ] && info "输出：$_out"
                    if [ "$_rc" -ne 0 ] || printf '%s' "$_out" | grep -qiE 'insufficient|privilege|not supported|invalid|denied|fail'; then
                        verdict FAIL "写 BMC 时间被拒绝（rc=${_rc}）：${_out:-无输出}"
                        note "① 部分固件不允许在系统接口（-I open）上写 —— 改用 --bmc <IP> -U <用户> -P '<密码>' 走网络"
                        note "② 账号权限不足（写需要 Operator 及以上）  ③ 时间格式不对"
                    else
                        verdict PASS "已下发校准：BMC <- ${_ts}（UTC）"
                        sleep 1
                        _raw2="$(ipmitool "${BMC_ARGV[@]}" sel time get 2>/dev/null || true)"
                        _raw2="$(printf '%s' "$_raw2" | tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//')"
                        _be2="$(TZ=UTC date -d "$_raw2" +%s 2>/dev/null || true)"
                        if [ -z "$_be2" ]; then
                            verdict Pending "校准后读不到 BMC 时间，无法复检"
                        else
                            _d2=$(( _be2 - $(date +%s) ))
                            info "复检 BMC 时间：$_raw2"
                            if [ "$(le "$(absf "$_d2")" "$FIX_TOL")" = "1" ]; then
                                verdict PASS "复检通过：残差 ${_d2}s（容差 ${FIX_TOL}s）"
                            else
                                verdict FAIL "复检残差 ${_d2}s 超容差 ${FIX_TOL}s"
                                note "① BMC 可能又跟主板 RTC / ME 对过表 —— 先 hwclock --systohc 再重试"
                                note "② 时区口径不一致（IPMI 是 UTC，Web 显示的是本地时间）"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi
sec_end "④ BMC 时间"

# ============================================================
# ⑤ RTC 走时漂移长测（可选）
# ============================================================
sec_head "⑤ RTC 走时漂移"
sec_begin

if [ "$DRIFT_MIN" -le 0 ]; then
    info "未给 --drift-min，跳过（这是分钟级长测，默认关闭）"
else
    mono_now() {
        if have perl; then
            local v
            v="$(perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC_RAW \
                 -e 'printf "%.6f", clock_gettime(CLOCK_MONOTONIC_RAW)' 2>/dev/null || true)"
            [ -n "$v" ] && { printf '%s' "$v"; return 0; }
        fi
        [ -r /proc/uptime ] || return 1
        awk '{printf "%.6f", $1}' /proc/uptime
    }
    if have perl && perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC_RAW -e 'exit 0' 2>/dev/null; then
        MONO_KIND="CLOCK_MONOTONIC_RAW（完全不受 NTP 影响）"
    else
        MONO_KIND="CLOCK_MONOTONIC / /proc/uptime（不受 NTP step 影响，受 slew 影响）"
    fi

    _r0="$(rtc_epoch 2>/dev/null || true)"
    _m0="$(mono_now 2>/dev/null || true)"
    _secs=$(( DRIFT_MIN * 60 ))

    if ! is_uint "$_r0" || [ -z "$_m0" ]; then
        verdict Pending "读不到 RTC 秒计数或单调时钟，无法测漂移"
    else
        info "开始测量 ${DRIFT_MIN} 分钟（${_secs}s），期间请勿改动系统时间……"
        sleep "$_secs"
        _r1="$(rtc_epoch 2>/dev/null || true)"
        _m1="$(mono_now 2>/dev/null || true)"

        if ! is_uint "$_r1" || [ -z "$_m1" ]; then
            verdict Pending "测量结束时读不到 RTC 或单调时钟"
        else
            _res_ppm="$(awk -v t="$_secs" 'BEGIN{printf "%.0f", 1000000/t}')"
            _ppm="$(awk -v a="$_r0" -v b="$_r1" -v x="$_m0" -v y="$_m1" 'BEGIN{
                d = y - x
                if (d <= 0) { print "nan"; exit }
                printf "%.1f", ((b - a) - d) / d * 1000000
            }')"
            info "参考系：${MONO_KIND}"
            note "测量分辨率 ±${_res_ppm} ppm（RTC 只有秒级精度，分辨率 = 1e6 / 测量秒数）"

            if [ "$_ppm" = "nan" ]; then
                verdict Pending "漂移计算失败（分母非正）"
            else
                _abs_ppm="$(absf "$_ppm")"
                _coarse="$(awk -v r="$_res_ppm" -v m="$DRIFT_MAX" 'BEGIN{print (r>m)?1:0}')"
                if [ "$DRIFT_STRICT" = "1" ]; then
                    if [ "$_coarse" = "1" ]; then
                        verdict Pending "漂移 ${_ppm} ppm，但本次时长只能分辨 ±${_res_ppm} ppm（比判定线 ${DRIFT_MAX} ppm 还粗）—— 时长不足以判定，请加大 --drift-min"
                    elif [ "$(le "$_abs_ppm" "$DRIFT_MAX")" = "1" ]; then
                        verdict PASS "RTC 走时漂移 ${_ppm} ppm（≤ ${DRIFT_MAX} ppm）"
                    else
                        verdict FAIL "RTC 走时漂移 ${_ppm} ppm 超上限 ${DRIFT_MAX} ppm"
                    fi
                else
                    note "漂移 ${_ppm} ppm —— 默认只记录不判定（加 --drift-strict 才参与）"
                    verdict PASS "RTC 走时漂移已记录：${_ppm} ppm（参考系：单调时钟）"
                fi
            fi
        fi
    fi
fi
sec_end "⑤ RTC 走时漂移"

# ============================================================
# 结论
# ============================================================
echo
echo -e "${BLUE}==================== 结论 ====================${NC}"
echo "参考系        : ${REF_DESC}"
echo "RTC 设备      : ${RTC_DEV:-未发现}"
echo "NTP 客户端    : ${NTP_KIND:-未安装}${NTP_UNIT:+（$NTP_UNIT）}"
echo "BMC 通道      : ${BMC_CH_DESC:-未使用（未给 --bmc，或本机系统接口不可用）}"
echo "BMC 校准      : $([ "$DO_FIX" = "1" ] && echo '已请求（--fix）' || echo '未请求（只读）')"
echo "阈值          : offset ≤ ${OFFSET_MAX}s / ppm 提示线 ${PPM_MAX} / RTC 容差 ${RTC_TOL}s / BMC 容差 ${BMC_TOL}s / 校准残差 ${FIX_TOL}s"

if [ "$DO_LIST" = "1" ]; then
    echo
    info "--list 模式：以上仅为现状，未做判定，退出码恒为 0"
    exit 0
fi

echo "判定计数      : PASS ${N_PASS} 项 / FAIL ${N_FAIL} 项 / Pending ${N_PEND} 项"
echo

# ★ --fix 前置不满足 = 环境不满足（不是机器不合格），优先于 FAIL 判定，退 2
if [ "${FIX_BLOCKED:-0}" = "1" ]; then
    err "整机判定：拒绝校准 —— 前置条件不满足，未对 BMC 做任何写操作（退出码 2）"
    [ "$N_FAIL" -gt 0 ] && note "另：本次还有 ${N_FAIL} 项 FAIL（见上文 ❌）；退出码按「前置不满足」取 2"
    exit 2
fi
if [ "$N_FAIL" -gt 0 ]; then
    err "整机判定：FAIL —— 有 ${N_FAIL} 项不合格，详见上文 ❌"
    exit 1
fi
if [ "$N_PEND" -gt 0 ]; then
    warn "整机判定：Pending —— 无 FAIL，但有 ${N_PEND} 项待判定（退出码仍为 0，请勿当成全绿）"
    exit 0
fi
ok "整机判定：PASS —— 全部 ${N_PASS} 项达标"
exit 0
