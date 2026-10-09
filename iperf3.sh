#!/bin/bash
# ============================================================
# iperf3 网络打流验收脚本
#
# 功能：
#   - 本机双口自回环：两个网口分别放进独立网络命名空间，流量真走线缆
#   - 自动挑选两个链路已连接的物理网口
#   - 两台机器对打（IPERF_PAIRS）
#   - 带宽达标判定：达标线由被测网口的"协商速率"推导，不需要手填数字
#
# 用法：
#   sudo ./iperf3.sh eth0 eth1                          本机两个网口对打
#   sudo IPERF_AUTO_LOOPBACK=1 bash iperf3.sh           自动挑两个已插线的网口
#   sudo IPERF_PAIRS="10.0.1.1:10.0.1.2" bash iperf3.sh 两台机器对打
#   ./iperf3.sh --list                                  只看网口与链路状态（免 root）
#   ./iperf3.sh --help
#
# 可选参数（同名环境变量亦可）：              默认值
#   --time N           打流时长（秒）             IPERF_TIME=30
#   --parallel N       并行流数                   IPERF_PARALLEL=8
#   --port N           端口                       IPERF_PORT=5202
#   --interval N       iperf3 区间报告间隔（秒）   IPERF_INTERVAL=5
#   --threshold-pct N  达标线 = 协商速率 × N%      IPERF_THRESHOLD_PCT=85
#   --min-rate R       绝对达标线，如 90G/90000M   IPERF_MIN_RATE（优先于百分比）
#   --max-retr N       重传数 > N 时告警（不算失败） IPERF_MAX_RETR（默认只显示不告警）
#   -y, --yes          跳过"动口前确认"（批量自动化用） IPERF_YES=1
#   --force            允许把管理口也搬进命名空间     IPERF_FORCE=1（会断网，风险自负）
#
# 管理口保护（重要）：
#   自回环测试会把两个网口移进网络命名空间，期间这两个口中断。
#   脚本会自动识别"默认路由所在口"和"当前 SSH 连接所在口"：
#     - 自动选口时跳过这些口
#     - 手动指定时直接拒绝，需显式 IPERF_FORCE=1 才执行
#   例：ssh 到管理口 eth0 时执行 ./iperf3.sh eth0 eth1 会被拒绝并给出提示。
#
# 达标线怎么来（不用手填）：
#   读被测网口协商速率 /sys/class/net/<if>/speed（兜底 ethtool），
#   双向对打取两个网口里较小的那个，再乘 --threshold-pct。
#   读不到速率（虚拟口 / bond / 链路未协商）时不做达标判定，只给警告，避免误报。
#
# 退出码：0 = 通过（可含警告）   1 = 不通过   2 = 用法错误
# ============================================================

# ---------- 默认值 ----------
: "${IPERF_PAIRS:=}"
: "${IPERF_AUTO_LOOPBACK:=0}"
: "${IPERF_AUTO_IFACES:=}"
: "${IPERF_PORT:=5202}"
: "${IPERF_TIME:=30}"
: "${IPERF_PARALLEL:=8}"
: "${IPERF_INTERVAL:=5}"
: "${IPERF_THRESHOLD_PCT:=85}"
: "${IPERF_MIN_RATE:=}"
: "${IPERF_MAX_RETR:=}"
: "${IPERF_CONNECT_TIMEOUT:=10000}"
: "${IPERF_FORCE:=0}"              # =1 允许把管理口也搬进命名空间（会断网，风险自负）
: "${IPERF_YES:=0}"                # =1 跳过动口前的交互确认（批量自动化用）
DO_LIST=0
POS=()

# ---------- 参数解析（放在所有环境检查之前，保证 --help/--list 随时可用）----------
usage() {
    # 打印文件头注释块：跳过 shebang 和第一条 === 分隔线，打印到下一条分隔线
    awk '
        NR == 1 { next }
        !started { if ($0 ~ /^# ===/) started = 1; next }
        /^# ===/ { exit }
        { sub(/^# ?/, ""); print }
    ' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -l|--list)        DO_LIST=1; shift ;;
        -t|--time)        IPERF_TIME="$2"; shift 2 ;;
        -P|--parallel)    IPERF_PARALLEL="$2"; shift 2 ;;
        -p|--port)        IPERF_PORT="$2"; shift 2 ;;
        -i|--interval)    IPERF_INTERVAL="$2"; shift 2 ;;
        --threshold-pct)  IPERF_THRESHOLD_PCT="$2"; shift 2 ;;
        --min-rate)       IPERF_MIN_RATE="$2"; shift 2 ;;
        --max-retr)       IPERF_MAX_RETR="$2"; shift 2 ;;
        -y|--yes)         IPERF_YES=1; shift ;;
        --force)          IPERF_FORCE=1; shift ;;
        --)               shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
        -*)               echo "错误：未知参数 $1"; echo; usage; exit 2 ;;
        *)                POS+=("$1"); shift ;;
    esac
done

if [ "${#POS[@]}" -eq 2 ]; then
    IPERF_AUTO_LOOPBACK=1
    IPERF_AUTO_IFACES="${POS[0]} ${POS[1]}"
    echo "检测到命令行参数，将测试网口 ${POS[0]} ↔ ${POS[1]}"
elif [ "${#POS[@]}" -gt 0 ]; then
    echo "错误：参数个数不正确，用法：$0 [网口1 网口2]"
    echo "      或不带参数，通过环境变量控制（见 $0 --help）"
    exit 2
fi

# ---------- 颜色 ----------
if [ -t 1 ]; then
    GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; NC='\033[0m'; BOLD='\033[1m'
else
    GREEN=''; YELLOW=''; RED=''; NC=''; BOLD=''
fi

# ---------- 全局计数与状态 ----------
PASSED=0; FAILS=0; WARNS=0; CANCELED=0
IPERF_PIDS=()
SRV_LOG=""
PORTS_MAP=""
LB_NS_A="" LB_NS_B="" LB_IF_A="" LB_IF_B="" LB_RESTORE_A="" LB_RESTORE_B=""

# ---------- 清理（不留日志：服务端输出只用临时文件，退出即删）----------
reset_lb_state() {
    LB_NS_A=""; LB_NS_B=""; LB_IF_A=""; LB_IF_B=""; LB_RESTORE_A=""; LB_RESTORE_B=""
}

teardown_lb() {
    [ -n "$LB_NS_A" ] && ip netns del "$LB_NS_A" 2>/dev/null
    [ -n "$LB_NS_B" ] && ip netns del "$LB_NS_B" 2>/dev/null
    sleep 1
    [ -n "$LB_IF_A" ] && ip link set "$LB_IF_A" up 2>/dev/null
    [ -n "$LB_IF_B" ] && ip link set "$LB_IF_B" up 2>/dev/null
    local a
    for a in ${LB_RESTORE_A}; do [ -n "$LB_IF_A" ] && ip addr add "$a" dev "$LB_IF_A" 2>/dev/null; done
    for a in ${LB_RESTORE_B}; do [ -n "$LB_IF_B" ] && ip addr add "$a" dev "$LB_IF_B" 2>/dev/null; done
    reset_lb_state
}

# ---- 进程树回收 ----
# iperf3 -s 会为每条连接 fork 一个子进程，只 kill 主 PID 会留下孤儿继续占着端口
# （下一轮测试就得靠"自动换端口"掩盖问题）；跑在 netns 里的服务端子进程还可能导致
# teardown_lb 之后命名空间清理不干净。所以按进程树逐个回收。
# 注意：PID 合法性校验必须排在 kill -0 存活探测之前 —— kill -TERM 0 作用于整个进程组，
# 会把脚本自己也杀掉。
kill_pid_tree() {
    local pid="$1" sig="${2:-TERM}" child
    [ -n "${pid}" ] || return 0
    case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${pid}" -gt 1 ] || return 0
    kill -0 "${pid}" 2>/dev/null || return 0
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "${pid}" 2>/dev/null); do
            kill_pid_tree "${child}" "${sig}"
        done
    fi
    kill -"${sig}" "${pid}" 2>/dev/null
}

# 先 TERM 优雅退出，最多等 3s，仍在则 KILL
stop_iperf_tree() {
    local pid="$1" i
    [ -n "${pid}" ] || return 0
    case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${pid}" -gt 1 ] || return 0
    kill -0 "${pid}" 2>/dev/null || return 0
    kill_pid_tree "${pid}" TERM
    for i in 1 2 3; do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 1
    done
    kill_pid_tree "${pid}" KILL
    return 0
}

cleanup() {
    local pid
    for pid in "${IPERF_PIDS[@]}"; do [ -n "$pid" ] && stop_iperf_tree "$pid"; done
    for pid in "${IPERF_PIDS[@]}"; do [ -n "$pid" ] && wait "$pid" 2>/dev/null; done
    IPERF_PIDS=()
    [ -n "$LB_NS_A" ] || [ -n "$LB_NS_B" ] && teardown_lb
    [ -n "$SRV_LOG" ] && rm -f "$SRV_LOG"
    SRV_LOG=""
    return 0    # 关键：EXIT trap 的最后一条命令会覆盖脚本退出码，这里必须成功返回
}
trap cleanup EXIT
trap 'echo ""; echo "已中断（SIGINT），正在清理..."; exit 130' INT
trap 'echo ""; echo "已中断（SIGTERM），正在清理..."; exit 143' TERM

# ---------- 小工具 ----------
# 精确查某个 IP 落在哪个网口上（不用正则，避免 IP 里的 . 当通配符）
iface_of_ip() {
    local want="$1"
    ip -o -4 addr show 2>/dev/null | awk -v want="$want" '
        { a = $4; sub(/\/.*/, "", a); if (a == want) { print $2; exit } }'
}

# 读网口协商速率（Mb/s）；读不到返回空
get_link_speed_mbps() {
    local ifc="$1" s=""
    if [ -r "/sys/class/net/$ifc/speed" ]; then
        s=$(cat "/sys/class/net/$ifc/speed" 2>/dev/null)
    fi
    case "$s" in ''|*-1*|-1) s="" ;; esac
    if [ -z "$s" ] && command -v ethtool >/dev/null 2>&1; then
        s=$(ethtool "$ifc" 2>/dev/null | sed -n 's/.*[Ss]peed: *\([0-9][0-9]*\)Mb\/s.*/\1/p' | head -1)
    fi
    printf '%s' "$s"
}

# 取两个数里较小的（空的忽略）
min_num() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        if (a == "") { print b; exit }
        if (b == "") { print a; exit }
        print ((a + 0) < (b + 0)) ? a : b
    }'
}

# "197 Gbits/sec" → Mbit/s（数值）；认不出返回空
bw_to_mbps() {
    awk -v r="$1" 'BEGIN{
        n = split(r, a, " "); if (n < 2) { print ""; exit }
        v = a[1] + 0; u = a[2]; m = -1
        if      (u == "bits/sec")    m = 0.000001
        else if (u == "Kbits/sec")   m = 0.001
        else if (u == "Mbits/sec")   m = 1
        else if (u == "Gbits/sec")   m = 1000
        else if (u == "Tbits/sec")   m = 1000000
        else if (u == "Bytes/sec")   m = 0.000008
        else if (u == "KBytes/sec")  m = 0.008
        else if (u == "MBytes/sec")  m = 8
        else if (u == "GBytes/sec")  m = 8000
        if (m < 0) { print ""; exit }
        printf "%.3f", v * m
    }'
}

# "90G" / "90000M" / "1500" → Mbit/s
rate_to_mbps() {
    awk -v r="$1" 'BEGIN{
        s = r; gsub(/[ \t]/, "", s); u = "M"
        if      (s ~ /[Gg]$/) { u = "G"; sub(/[Gg]$/, "", s) }
        else if (s ~ /[Mm]$/) { u = "M"; sub(/[Mm]$/, "", s) }
        else if (s ~ /[Kk]$/) { u = "K"; sub(/[Kk]$/, "", s) }
        v = s + 0
        if (u == "G") v = v * 1000; else if (u == "K") v = v / 1000
        printf "%.0f", v
    }'
}

# 从 iperf3 输出解析平均带宽，输出 "数值 单位"
# 注意：receiver 行没有 Retr 字段（比 sender 行少一列），
#       所以要锚定"以 sec 结尾的那一列"，不能按固定列号取。
parse_bw() {
    awk '
        /receiver/ {
            v = ""; u = ""
            for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i + 3); u = $(i + 4) }
            if (u ~ /^(K|M|G|T)?bits\/sec$/ || u ~ /^(K|M|G|T)?Bytes\/sec$/) { lv = v; lu = u }
        }
        END { if (lv != "") print lv, lu }
    '
}

# 从 iperf3 输出的 sender 汇总行里取重传次数（receiver 行没有这个字段）
# 重传多通常意味着线缆/光模块/网卡有问题，是硬件验收的重点线索
parse_retr() {
    awk '
        /sender/ {
            u = ""; r = ""
            for (i = 1; i <= NF; i++) if ($i == "sec") { u = $(i + 4); r = $(i + 5) }
            if (u ~ /bits\/sec$/) lr = r
        }
        END { if (lr != "") print lr }
    '
}

threshold_mbps() {
    local link="$1"
    if [ -n "$IPERF_MIN_RATE" ]; then rate_to_mbps "$IPERF_MIN_RATE"; return; fi
    if [ -n "$link" ]; then awk -v l="$link" -v p="$IPERF_THRESHOLD_PCT" 'BEGIN{ printf "%.0f", l * p / 100 }'; return; fi
    printf ''
}

threshold_src_text() {
    local link="$1"
    if [ -n "$IPERF_MIN_RATE" ]; then printf '指定 %s' "$IPERF_MIN_RATE"; return; fi
    if [ -n "$link" ]; then printf '协商速率 %s × %s%%' "$link" "$IPERF_THRESHOLD_PCT"; return; fi
    printf '无'
}

# 失败时的简短诊断
diag_hint() {
    local out="$1"
    if printf '%s' "$out" | grep -qi "Connection refused"; then
        echo -e "${YELLOW}     诊断：连不上服务端（服务端没起来 / 端口被占 / 地址没就绪）${NC}"
    elif printf '%s' "$out" | grep -qi "No route to host"; then
        echo -e "${YELLOW}     诊断：无路由到对端（检查网线、两端是否同网段）${NC}"
    elif printf '%s' "$out" | grep -qi "unable to bind\|bind failed"; then
        echo -e "${YELLOW}     诊断：本端地址绑定失败（-B 指定的 IP 是否在本机网卡上）${NC}"
    elif printf '%s' "$out" | grep -qi "unrecognized option\|unknown option\|invalid option"; then
        echo -e "${YELLOW}     诊断：iperf3 不支持某个参数（版本过老）${NC}"
    elif printf '%s' "$out" | grep -qi "timed out\|timeout"; then
        echo -e "${YELLOW}     诊断：连接/传输超时（链路是否真的通、对端防火墙）${NC}"
    fi
}

# ---------- 管理口识别：默认路由所在口 + 当前 SSH 会话所在口 ----------
# 这两个口一旦被移进 netns，远程连接会立刻断开，且要等整个测试跑完才恢复。
# 必须在"动口"之前识别出来：自动选口时跳过，手动指定时直接拒绝。
mgmt_ifaces() {
    local def_ifs="" ssh_if="" cip
    # 多条默认路由（多出口）都要保护，所以这里不 exit
    def_ifs=$(ip -o -4 route show default 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1)}}')
    if [ -n "${SSH_CONNECTION:-}" ]; then
        cip=$(printf '%s' "$SSH_CONNECTION" | awk '{print $3}')
        if [ -n "$cip" ]; then
            ssh_if=$(ip -o -4 route get "$cip" 2>/dev/null \
                     | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        fi
    fi
    printf '%s\n%s\n' "$def_ifs" "$ssh_if" | sed '/^[[:space:]]*$/d' | sort -u
}

# 链路预检
check_link() {
    local ifc="$1" car
    if [ ! -d "/sys/class/net/$ifc" ]; then
        echo -e "${RED}  ❌ 网口 $ifc 不存在${NC}"
        FAILS=$((FAILS + 1)); return 1
    fi
    car=$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null)
    if [ "$car" != "1" ]; then
        echo -e "${RED}  ❌ 网口 $ifc 链路未就绪（carrier=${car:-读不到}），请检查网线/对端网口${NC}"
        FAILS=$((FAILS + 1)); return 1
    fi
    return 0
}

# 等 iperf3 服务端真正进入监听状态（比 sleep 固定秒数可靠）
wait_server() {
    local pid="$1" logf="$2" i=0
    while [ "$i" -lt 60 ]; do
        if grep -q "Server listening on" "$logf" 2>/dev/null; then return 0; fi
        if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# 一条方向的判定与打印
report_rate() {
    local label="$1" raw="$2" link="$3" rc="$4" out="$5" retr="${6:-}"
    local mbps disp util thresh src retr_txt=""
    if [ "$rc" -ne 0 ]; then
        echo -e "  ${RED}❌ ${label}：iperf3 退出码 ${rc}，本次未取得有效结果${NC}"
        diag_hint "$out"
        FAILS=$((FAILS + 1)); return 1
    fi
    if [ -z "$raw" ]; then
        echo -e "  ${RED}❌ ${label}：未能从 iperf3 输出解析出带宽${NC}"
        diag_hint "$out"
        FAILS=$((FAILS + 1)); return 1
    fi
    mbps=$(bw_to_mbps "$raw")
    if [ -z "$mbps" ]; then
        echo -e "  ${RED}❌ ${label}：带宽单位无法识别（${raw}）${NC}"
        FAILS=$((FAILS + 1)); return 1
    fi
    disp=$(awk -v m="$mbps" 'BEGIN{ if (m >= 1000) printf "%.1f Gbits/sec", m / 1000; else printf "%.0f Mbits/sec", m }')

    # 重传统计：只展示，默认不影响判定；设了 IPERF_MAX_RETR 才告警
    if [ -n "$retr" ]; then
        case "$retr" in
            ''|*[!0-9]*) : ;;
            *)  retr_txt="  重传 ${retr}"
                if [ -n "$IPERF_MAX_RETR" ] && [ "$retr" -gt "$IPERF_MAX_RETR" ]; then
                    retr_txt="${retr_txt} ⚠️（超过设定上限 ${IPERF_MAX_RETR}，检查线缆/光模块）"
                    WARNS=$((WARNS + 1))
                fi ;;
        esac
    fi

    thresh=$(threshold_mbps "$link")
    src=$(threshold_src_text "$link")
    if [ -z "$thresh" ]; then
        echo -e "  ${YELLOW}⚠️  ${label}：${disp}${retr_txt}   —— 链路速率未知，本次未做达标判定${NC}"
        WARNS=$((WARNS + 1)); return 0
    fi

    util=$(awk -v m="$mbps" -v l="$link" 'BEGIN{ if (l + 0 > 0) printf "%.1f", m / l * 100; else printf "?" }')
    if awk -v m="$mbps" -v t="$thresh" 'BEGIN{ exit !((m + 0) >= (t + 0)) }'; then
        echo -e "  ${GREEN}✅${NC} ${label}：${disp}${retr_txt}   链路 ${link}Mb/s  利用率 ${util}%  ≥ 达标线 ${thresh}Mb/s（${src}）"
        PASSED=$((PASSED + 1)); return 0
    fi
    echo -e "  ${RED}❌${NC} ${label}：${disp}${retr_txt}   链路 ${link}Mb/s  利用率 ${util}%  < 达标线 ${thresh}Mb/s（${src}）"
    FAILS=$((FAILS + 1)); return 1
}

# ---------- 网口一览（免 root）----------
list_ifaces() {
    printf '%-14s %-8s %-11s %-14s %s\n' "网口" "carrier" "速率Mb/s" "类型/状态" "IPv4"
    printf '%-14s %-8s %-11s %-14s %s\n' "----" "-------" "--------" "---------" "----"
    local d ifc car sp kind st addrs
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        ifc=$(basename "$d")
        [ "$ifc" = "lo" ] && continue
        car=$(cat "$d/carrier" 2>/dev/null); car=${car:-"-"}
        sp=$(get_link_speed_mbps "$ifc"); sp=${sp:-"-"}
        if [ -d "$d/device" ]; then kind="物理"; else kind="虚拟"; fi
        if [ "$car" = "1" ]; then st="已连接"; else st="未连接"; fi
        addrs=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | paste -sd, -)
        [ -z "$addrs" ] && addrs="-"
        printf '%-14s %-8s %-11s %-14s %s\n' "$ifc" "$car" "$sp" "${kind}/${st}" "$addrs"
    done
}

# ---------- 自回环打流（网络命名空间，流量真走线缆）----------
self_loopback_iperf() {
    local ip_a="$1" ip_b="$2" iface_b="$3"
    local iface_a link_a link_b link_min port srv_pid fwd_output rev_output fwd_rc rev_rc
    iface_a=$(iface_of_ip "$ip_a")
    if [ -z "$iface_a" ]; then
        echo -e "${RED}  ❌ 自回环配对 ${ip_a} 未配置在本机网卡上${NC}"
        FAILS=$((FAILS + 1)); return 1
    fi
    if [ "$iface_a" = "$iface_b" ]; then
        echo -e "${RED}  ❌ 自回环配对 ${ip_a}/${ip_b} 落在同一网口（${iface_a}），需要 2 个不同网口${NC}"
        FAILS=$((FAILS + 1)); return 1
    fi

    echo ""
    echo "----- 自回环 ${ip_a}（${iface_a}）↔ ${ip_b}（${iface_b}）-----"

    # ---------- 管理口保护（必须在把网口搬进命名空间之前）----------
    # 一旦把默认路由/SSH 所在口移进 netns，远程连接立即断开，
    # 要到测试结束才恢复，且期间无法干预。默认直接拒绝。
    if [ "$IPERF_FORCE" != "1" ]; then
        local mgmt hit=""
        mgmt=" $(mgmt_ifaces | tr '\n' ' ') "
        case "$mgmt" in *" $iface_a "*) hit="$hit $iface_a" ;; esac
        case "$mgmt" in *" $iface_b "*) hit="$hit $iface_b" ;; esac
        if [ -n "${hit// /}" ]; then
            echo -e "${RED}  ❌ 拒绝测试：${hit} 是管理口（默认路由或当前 SSH 连接所在）${NC}"
            echo "     把它移进网络命名空间会立刻断开远程连接，且需等测试结束才恢复。"
            echo "     请改用其它网口；确需测试请设 IPERF_FORCE=1（风险自负）。"
            echo "     当前识别到的管理口：$(mgmt_ifaces | tr '\n' ' ')"
            FAILS=$((FAILS + 1)); return 1
        fi
    fi

    # ---------- 动口前二次确认（非管理口也可能承载业务）----------
    if [ "$IPERF_YES" != "1" ] && [ -t 0 ]; then
        printf '%s' "      即将把 ${iface_a} / ${iface_b} 暂时移出主命名空间，期间两口中断，确认？(y/N) "
        read -r _iperf_ans || _iperf_ans=""
        echo
        case "${_iperf_ans}" in
            y|Y) : ;;
            *)
                echo -e "${YELLOW}  已取消该对测试（记为未完成）${NC}"
                CANCELED=$((CANCELED + 1)); return 1 ;;
        esac
    fi

    # 预检必须在把网口搬进命名空间之前做
    check_link "$iface_a" || return 1
    check_link "$iface_b" || return 1
    link_a=$(get_link_speed_mbps "$iface_a")
    link_b=$(get_link_speed_mbps "$iface_b")
    link_min=$(min_num "$link_a" "$link_b")
    if [ -z "$link_min" ]; then
        echo -e "${YELLOW}  ⚠️  读不到协商速率（${iface_a}=${link_a:-未知}，${iface_b}=${link_b:-未知}），本次只测通断、不判带宽${NC}"
    else
        echo "  链路速率：${iface_a}=${link_a:-未知}Mb/s  ${iface_b}=${link_b:-未知}Mb/s  取小值 ${link_min}Mb/s"
    fi

    SRV_LOG=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/iperf3_srv_$$.log")
    : > "$SRV_LOG"

    LB_RESTORE_A=$(ip -o -4 addr show dev "$iface_a" 2>/dev/null | awk '{print $4}')
    LB_RESTORE_B=$(ip -o -4 addr show dev "$iface_b" 2>/dev/null | awk '{print $4}')
    LB_IF_A="$iface_a"; LB_IF_B="$iface_b"
    LB_NS_A="dwt_lb_a_$$"; LB_NS_B="dwt_lb_b_$$"

    if ! ip netns add "$LB_NS_A" 2>/dev/null || ! ip netns add "$LB_NS_B" 2>/dev/null; then
        echo -e "${RED}  ❌ 创建网络命名空间失败（需要 root，且内核需支持 netns）${NC}"
        ip netns del "$LB_NS_A" 2>/dev/null; ip netns del "$LB_NS_B" 2>/dev/null
        reset_lb_state
        FAILS=$((FAILS + 1)); return 1
    fi
    if ! ip link set "$iface_a" netns "$LB_NS_A" 2>/dev/null; then
        echo -e "${RED}  ❌ 把 $iface_a 移入命名空间失败${NC}"
        teardown_lb; FAILS=$((FAILS + 1)); return 1
    fi
    if ! ip link set "$iface_b" netns "$LB_NS_B" 2>/dev/null; then
        echo -e "${RED}  ❌ 把 $iface_b 移入命名空间失败${NC}"
        teardown_lb; FAILS=$((FAILS + 1)); return 1
    fi

    ip netns exec "$LB_NS_A" ip link set lo up 2>/dev/null
    ip netns exec "$LB_NS_A" ip link set "$iface_a" up 2>/dev/null
    ip netns exec "$LB_NS_A" ip addr replace "$ip_a/32" dev "$iface_a" 2>/dev/null
    ip netns exec "$LB_NS_A" ip route replace "$ip_b/32" dev "$iface_a" 2>/dev/null
    ip netns exec "$LB_NS_B" ip link set lo up 2>/dev/null
    ip netns exec "$LB_NS_B" ip link set "$iface_b" up 2>/dev/null
    ip netns exec "$LB_NS_B" ip addr replace "$ip_b/32" dev "$iface_b" 2>/dev/null
    ip netns exec "$LB_NS_B" ip route replace "$ip_a/32" dev "$iface_b" 2>/dev/null

    port="$IPERF_PORT"
    echo "开始双向打流（端口 ${port}，每方向 ${IPERF_TIME}s × ${IPERF_PARALLEL} 流）..."
    ip netns exec "$LB_NS_B" iperf3 -s -B "$ip_b" -p "$port" > "$SRV_LOG" 2>&1 &
    srv_pid=$!
    IPERF_PIDS+=("$srv_pid")
    if ! wait_server "$srv_pid" "$SRV_LOG"; then
        echo -e "${RED}  ❌ 服务端未就绪，本次未打流。服务端输出：${NC}"
        sed 's/^/      /' "$SRV_LOG" 2>/dev/null | head -8
        stop_iperf_tree "$srv_pid"
        teardown_lb
        FAILS=$((FAILS + 1)); return 1
    fi

    echo "== 正向（${iface_a}→${iface_b}）=="
    fwd_output=$(timeout $((IPERF_TIME + 20)) ip netns exec "$LB_NS_A" iperf3 -c "$ip_b" -B "$ip_a" \
        -p "$port" -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -i "$IPERF_INTERVAL" 2>&1)
    fwd_rc=$?
    echo "$fwd_output"

    echo "== 反向（${iface_b}→${iface_a}）=="
    rev_output=$(timeout $((IPERF_TIME + 20)) ip netns exec "$LB_NS_A" iperf3 -c "$ip_b" -B "$ip_a" \
        -p "$port" -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -i "$IPERF_INTERVAL" -R 2>&1)
    rev_rc=$?
    echo "$rev_output"

    stop_iperf_tree "$srv_pid"
    wait "$srv_pid" 2>/dev/null
    teardown_lb

    echo ""
    echo -e "${BOLD}===== 吞吐量汇总 =====${NC}"
    report_rate "正向（${iface_a}→${iface_b}）" "$(printf '%s\n' "$fwd_output" | parse_bw)" "$link_min" "$fwd_rc" "$fwd_output" "$(printf '%s\n' "$fwd_output" | parse_retr)"
    report_rate "反向（${iface_b}→${iface_a}）" "$(printf '%s\n' "$rev_output" | parse_bw)" "$link_min" "$rev_rc" "$rev_output" "$(printf '%s\n' "$rev_output" | parse_retr)"
    return 0
}

# ---------- 自动/指定网口自回环 ----------
auto_loopback_iperf() {
    local if_a="" if_b=""
    if [ -n "$IPERF_AUTO_IFACES" ]; then
        # shellcheck disable=SC2206
        local want=($IPERF_AUTO_IFACES)
        if [ "${#want[@]}" -ne 2 ]; then
            echo -e "${RED}  ❌ 需要恰好 2 个网口，例如 eth0 eth3${NC}"
            FAILS=$((FAILS + 1)); return 1
        fi
        if_a="${want[0]}"; if_b="${want[1]}"
        if [ "$if_a" = "$if_b" ]; then
            echo -e "${RED}  ❌ 两个网口不能相同（${if_a}）${NC}"
            FAILS=$((FAILS + 1)); return 1
        fi
        if [ ! -d "/sys/class/net/$if_a" ] || [ ! -d "/sys/class/net/$if_b" ]; then
            echo -e "${RED}  ❌ 指定的网口不存在（${if_a}/${if_b}）${NC}"
            FAILS=$((FAILS + 1)); return 1
        fi
    else
        local picked=() d ifc mgmt
        mgmt=" $(mgmt_ifaces | tr '\n' ' ') "
        # IFACE_SCAN_DIR 默认为 /sys/class/net，仅用于测试时指向假目录
        for d in "${IFACE_SCAN_DIR:-/sys/class/net}"/*; do
            [ -e "$d" ] || continue
            ifc=$(basename "$d")
            [ "$ifc" = "lo" ] && continue
            [ -d "$d/device" ] || continue
            [ "$(cat "$d/carrier" 2>/dev/null)" = "1" ] || continue
            # 跳过管理口：宁可少选，也不能把 SSH/默认路由所在口搬走
            case "$mgmt" in
                *" $ifc "*)
                    echo -e "${YELLOW}  跳过管理口 ${ifc}（默认路由/SSH 所在，可用 IPERF_FORCE=1 覆盖）${NC}"
                    continue ;;
            esac
            picked+=("$ifc")
            [ "${#picked[@]}" -ge 2 ] && break
        done
        if [ "${#picked[@]}" -lt 2 ]; then
            echo -e "${RED}  ❌ 未找到 2 个链路已连接、且非管理口的物理网口${NC}"
            echo "     当前网口状态："
            list_ifaces | sed 's/^/     /'
            FAILS=$((FAILS + 1)); return 1
        fi
        if_a="${picked[0]}"; if_b="${picked[1]}"
    fi

    echo ""
    echo "----- 自回环网口：${if_a} ↔ ${if_b}（临时IP 192.0.2.1/192.0.2.2）-----"
    echo "注意：测试期间这两个网口会短暂离开主命名空间（若误选管理口会断远程连接）"
    ip addr replace "192.0.2.1/32" dev "$if_a" 2>/dev/null
    ip addr replace "192.0.2.2/32" dev "$if_b" 2>/dev/null
    self_loopback_iperf "192.0.2.1" "192.0.2.2" "$if_b"
    local ret=$?
    ip addr del "192.0.2.1/32" dev "$if_a" 2>/dev/null
    ip addr del "192.0.2.2/32" dev "$if_b" 2>/dev/null
    echo "临时IP已清理"
    return $ret
}

# ---------- 两台机器对打 ----------
port_for_ip() {
    local kv
    for kv in $PORTS_MAP; do
        [ "${kv%%:*}" = "$1" ] && { printf '%s' "${kv##*:}"; return; }
    done
    printf '%s' "$IPERF_PORT"
}

run_manual_pairs() {
    local pair local_ip peer_ip iface lb_iface port sp n started
    local iperf_timeout=$((IPERF_TIME + 20))
    local connect_timeout_opt=""
    if iperf3 --help 2>/dev/null | grep -q -- "--connect-timeout"; then
        connect_timeout_opt="--connect-timeout ${IPERF_CONNECT_TIMEOUT}"
    fi

    # ---- 起本机服务端（对端是本机的配对走自回环，不需要服务端）----
    for pair in $IPERF_PAIRS; do
        local_ip="${pair%%:*}"; peer_ip="${pair#*:}"
        [ -n "$(iface_of_ip "$peer_ip")" ] && continue
        if [ -z "$(iface_of_ip "$local_ip")" ]; then
            echo -e "${RED}  ❌ 本机未配置 ${local_ip}，该对无法作为服务端${NC}"
            FAILS=$((FAILS + 1)); continue
        fi
        port="$IPERF_PORT"; n=0; sp=""; started=0
        while [ "$n" -lt 5 ]; do
            SRV_LOG=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/iperf3_srv_$$_$n.log")
            : > "$SRV_LOG"
            iperf3 -s -B "$local_ip" -p "$port" > "$SRV_LOG" 2>&1 &
            sp=$!
            if wait_server "$sp" "$SRV_LOG"; then started=1; break; fi
            stop_iperf_tree "$sp"; wait "$sp" 2>/dev/null
            if grep -qi "address already in use" "$SRV_LOG" 2>/dev/null; then
                echo "  端口 ${port} 已被占用，自动换用 $((port + 1))"
            else
                echo -e "${RED}  ❌ 服务端 ${local_ip}:${port} 启动失败：${NC}"
                sed 's/^/      /' "$SRV_LOG" 2>/dev/null | head -5
            fi
            rm -f "$SRV_LOG"; SRV_LOG=""
            port=$((port + 1)); n=$((n + 1))
        done
        if [ "$started" = "1" ]; then
            IPERF_PIDS+=("$sp")
            PORTS_MAP="$PORTS_MAP $local_ip:$port"
            echo "  服务端已就绪：${local_ip}:${port}"
        else
            FAILS=$((FAILS + 1))
        fi
    done
    sleep 0.5

    # ---- 逐对打流 ----
    for pair in $IPERF_PAIRS; do
        local_ip="${pair%%:*}"; peer_ip="${pair#*:}"
        if [ -z "$local_ip" ] || [ -z "$peer_ip" ] || [ "$local_ip" = "$peer_ip" ]; then
            echo -e "${RED}  ❌ 配对格式错误（应为 本机IP:对端IP）：${pair}${NC}"
            FAILS=$((FAILS + 1)); continue
        fi
        iface=$(iface_of_ip "$local_ip")
        if [ -z "$iface" ]; then
            echo -e "${RED}  ❌ 本机未配置 ${local_ip}${NC}"
            FAILS=$((FAILS + 1)); continue
        fi
        lb_iface=$(iface_of_ip "$peer_ip")
        if [ -n "$lb_iface" ]; then        # 对端也是本机 → 自回环
            self_loopback_iperf "$local_ip" "$peer_ip" "$lb_iface"
            continue
        fi
        check_link "$iface" || continue
        port=$(port_for_ip "$local_ip")
        local link fo ro fr rr
        link=$(get_link_speed_mbps "$iface")
        echo ""
        echo "----- 网口对 ${local_ip}（${iface}）↔ ${peer_ip} : 端口 ${port} -----"
        if [ -n "$link" ]; then echo "  本端链路速率：${link}Mb/s"; else echo -e "  ${YELLOW}⚠️  读不到本端协商速率，本次不判带宽${NC}"; fi

        echo "== 正向（本机→对端）=="
        fo=$(timeout "$iperf_timeout" iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" \
            -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -i "$IPERF_INTERVAL" $connect_timeout_opt 2>&1); fr=$?
        echo "$fo"
        echo "== 反向（对端→本机）=="
        ro=$(timeout "$iperf_timeout" iperf3 -c "$peer_ip" -B "$local_ip" -p "$port" \
            -t "$IPERF_TIME" -P "$IPERF_PARALLEL" -i "$IPERF_INTERVAL" -R $connect_timeout_opt 2>&1); rr=$?
        echo "$ro"

        echo ""
        echo -e "${BOLD}===== 该对吞吐量汇总 =====${NC}"
        report_rate "正向（本机→${peer_ip}）" "$(printf '%s\n' "$fo" | parse_bw)" "$link" "$fr" "$fo" "$(printf '%s\n' "$fo" | parse_retr)"
        report_rate "反向（${peer_ip}→本机）" "$(printf '%s\n' "$ro" | parse_bw)" "$link" "$rr" "$ro" "$(printf '%s\n' "$ro" | parse_retr)"
    done
}

# ===================== 主入口 =====================
if [ "$DO_LIST" = "1" ]; then
    list_ifaces
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "【错误】请使用 root 权限运行（需要创建网络命名空间、搬动网口）"
    echo "        仅查看网口与链路状态可用：$(basename "$0") --list"
    exit 1
fi

if ! command -v iperf3 >/dev/null 2>&1; then
    echo "【错误】未检测到 iperf3，请先安装（Debian/Ubuntu: apt install iperf3，RHEL: yum install iperf3）"
    exit 1
fi

echo ""
echo "==================== iperf3 网络打流验收 ===================="
echo "配置: 端口=${IPERF_PORT}  时长=${IPERF_TIME}s  并行=${IPERF_PARALLEL}  区间=${IPERF_INTERVAL}s"
if [ -n "$IPERF_MIN_RATE" ]; then
    echo "达标线: ${IPERF_MIN_RATE}（命令行指定）"
else
    echo "达标线: 网口协商速率 × ${IPERF_THRESHOLD_PCT}%（自动读取，不需要手填）"
fi

if [ -n "$IPERF_PAIRS" ]; then
    run_manual_pairs
elif [ "$IPERF_AUTO_LOOPBACK" = "1" ]; then
    auto_loopback_iperf
else
    echo ""
    echo "未配置 IPERF_PAIRS，也未启用自回环，没有测试任务。"
    echo "用法示例见：$(basename "$0") --help"
    exit 2
fi

cleanup
echo ""
echo "==================== 打流测试完成 ===================="
echo "结果统计：通过 ${PASSED} 项，不通过 ${FAILS} 项，警告 ${WARNS} 项，取消 ${CANCELED} 项"
if [ "$FAILS" -gt 0 ]; then
    echo -e "${RED}有 ${FAILS} 项不通过，请检查上方输出${NC}"
    exit 1
fi
if [ "$PASSED" -eq 0 ]; then
    if [ "$CANCELED" -gt 0 ]; then
        echo -e "${YELLOW}全部 ${CANCELED} 项测试被取消（未执行），不能算通过${NC}"
    else
        echo -e "${YELLOW}没有任何一项完成达标判定（全被跳过或速率未知），不能算通过，请人工确认${NC}"
    fi
    exit 1
fi
echo -e "${GREEN}所有打流测试通过${NC}"
exit 0
