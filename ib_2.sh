#!/bin/bash
# ============================================================
# IB / RoCE 两张网卡对打测试（同一台机器，两个不同的 CA）
#
# 前提：两张网卡已用线缆物理连接（DAC 直连，或 两个光模块 + 光纤）
#
# 用法：
#   sudo bash ib_2.sh mlx5_0 mlx5_1          指定两张卡
#   sudo bash ib_2.sh mlx5_0 mlx5_1 400      指定卡 + 预期单口速率(Gb/s)
#   bash ib_2.sh --list                      只看设备与链路状态（免 root）
#   bash ib_2.sh --help
#
# 环境变量：
#   PORT1 / PORT2       指定每张卡用哪个端口；默认自动挑 State=ACTIVE 的口
#   EXPECT_RATE=400     预期单口速率(Gb/s)；未给则从端口 rate 推导
#   QP=8                QP 数（perftest -q），默认 8
#   MTU_ARG="-m 1024"   perftest 的 MTU 参数
#   DURATION=10         打流时长（秒）
#   BIDIR=1             双向打流（perftest -b）
#   THRESHOLD_PCT=90    达标线 = 单口速率 × N%
#   IP1 / IP2           对打用的两个 IP，默认 192.168.100.1 / 192.168.100.2
#   PORTNUM=18515       打流端口
#   SKIP_CABLE_CHECK=1  跳过「数据是否真走线缆」的端口计数器核对
#
# 与 nic_loop.sh 的分工：
#   本脚本   = 两张【不同 CA】的卡对打
#   nic_loop.sh = 同一张【多口卡】的两个口自环（本脚本用不了的场景）
#   TCP 请用 iperf3.sh（本脚本只测 RDMA）
#
# 本版相对旧版（2026-09-20）的改动：
#   1) 修 netdev 取法。旧版 `device/net/ | head -1` 永远只认端口 1，
#      多口卡把线插在 port 2 时会配错口、必然失败。现按端口号精确取
#      （优先 ports/<p>/gid_attrs/ndevs，回退按端口序号索引 device/net）。
#   2) 加链路预检。State / Physical state 不达标直接退出并说清原因，
#      不再让你对着一句「测试失败」猜。
#   3) 加 Link layer / LINK_TYPE 打印；RoCE 卡给出 RoCE v2 GID 索引。
#   4) 加 -q（QP 数）、MTU、时长、双向打流参数。
#   5) 加达标判定（单口速率 × THRESHOLD_PCT，默认 90%）。
#   6) 加「数据是否真走线缆」的端口计数器核对（tx/rx 增量）。
#
# 退出码（与全局约定一致）：
#   0 = PASS —— 通过
#   1 = FAIL / Pending —— 不通过、环境不满足，或打流跑通了但读不到端口速率
#       因而未做达标判定（Pending）。Pending 不算通过，补测后必须复测。
#   2 = 用法错误（未知参数 / 缺少必填项）
# ============================================================

set -u

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then BLUE=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; fi

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${CYAN}   $1${NC}"; }

# ---------- 默认值 ----------
PORT1="${PORT1:-}"; PORT2="${PORT2:-}"
QP="${QP:-8}"
MTU_ARG="${MTU_ARG:--m 1024}"
DURATION="${DURATION:-10}"
BIDIR="${BIDIR:-0}"
THRESHOLD_PCT="${THRESHOLD_PCT:-90}"
IP1="${IP1:-192.168.100.1}"
IP2="${IP2:-192.168.100.2}"
PORTNUM="${PORTNUM:-18515}"
SKIP_CABLE_CHECK="${SKIP_CABLE_CHECK:-0}"

# ---------- usage：打印文件头注释块 ----------
usage() {
    awk '
        NR == 1 { next }
        !started { if ($0 ~ /^# ===/) started = 1; next }
        /^# ===/ { exit }
        { sub(/^# ?/, ""); print }
    ' "$0"
}

# ---------- 参数解析 ----------
DO_LIST=0
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -l|--list) DO_LIST=1; shift ;;
        --)        shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
        -*)        err "未知参数 $1"; echo; usage; exit 2 ;;
        *)         POS+=("$1"); shift ;;
    esac
done

# ---------- 小工具 ----------
# 读 /sys 里的状态文件，剥掉 "4: ACTIVE" 这种数字前缀
sysf() {
    local v
    v=$(cat "$1" 2>/dev/null)
    printf '%s' "${v##*: }"
}

# 列出某 CA 的所有端口号（升序）
ports_of() {
    ls -d "/sys/class/infiniband/$1"/ports/[0-9]* 2>/dev/null \
        | xargs -r -n1 basename 2>/dev/null | sort -n
}

# 挑端口：显式指定优先；否则挑 State=ACTIVE 的口；都没有就取第一个
pick_port() {
    local ca="$1" want="${2:-}" p st
    if [ -n "$want" ]; then printf '%s' "$want"; return 0; fi
    for p in $(ports_of "$ca"); do
        st=$(sysf "/sys/class/infiniband/$ca/ports/$p/state")
        [ "$st" = "ACTIVE" ] && { printf '%s' "$p"; return 0; }
    done
    ports_of "$ca" | head -1
}

# 取某个端口对应的 netdev。
# 正确做法：读 ports/<p>/gid_attrs/ndevs/<idx>（RoCE 的 GID 会指向它的 netdev）。
# 回退：按端口序号索引 device/net 的排序结果（单口卡两者等价）。
netdev_of_port() {
    local ca="$1" p="$2" nd name
    local -a nds
    for nd in "/sys/class/infiniband/$ca/ports/$p"/gid_attrs/ndevs/*; do
        [ -e "$nd" ] || continue
        name=$(head -1 "$nd" 2>/dev/null)
        [ -n "$name" ] && { printf '%s' "$name"; return 0; }
    done
    mapfile -t nds < <(ls "/sys/class/infiniband/$ca/device/net/" 2>/dev/null | sort)
    [ "${#nds[@]}" -eq 0 ] && return 1
    printf '%s' "${nds[$((p - 1))]:-${nds[0]}}"
}

# 端口速率(Gb/s)：优先 ports/<p>/rate，回退 netdev 的 /sys/class/net/<nd>/speed
port_rate_gbps() {
    local ca="$1" p="$2" nd="${3:-}" v=""
    v=$(cat "/sys/class/infiniband/$ca/ports/$p/rate" 2>/dev/null | awk '{print $1+0}')
    if [ -z "$v" ] || [ "$v" = "0" ]; then
        if [ -n "$nd" ] && [ -r "/sys/class/net/$nd/speed" ]; then
            v=$(awk '{printf "%.0f", $1/1000}' "/sys/class/net/$nd/speed" 2>/dev/null)
        fi
    fi
    printf '%s' "${v:-0}"
}

# 读端口累计字节计数器：优先 ethtool -S 的 PHY 计数（RDMA 流量也算），回退 sysfs
read_counter() {
    local nd="$1" which="$2" v="" key
    case "$which" in
        tx) key="tx_bytes_phy" ;;
        rx) key="rx_bytes_phy" ;;
    esac
    if command -v ethtool >/dev/null 2>&1; then
        v=$(ethtool -S "$nd" 2>/dev/null \
            | awk -v k="$key" -F: '$1 ~ ("^[[:space:]]*" k "[[:space:]]*$") {gsub(/[ \t]/,"",$2); print $2+0; exit}')
    fi
    if [ -z "$v" ]; then
        case "$which" in
            tx) v=$(cat "/sys/class/net/$nd/statistics/tx_bytes" 2>/dev/null) ;;
            rx) v=$(cat "/sys/class/net/$nd/statistics/rx_bytes" 2>/dev/null) ;;
        esac
    fi
    printf '%s' "${v:-}"
}

# 链路信息块（State / Physical state / Rate / Link layer）
print_port_state() {
    local ca="$1" p="$2" nd="${3:-}"
    local st ph rt
    st=$(sysf "/sys/class/infiniband/$ca/ports/$p/state")
    ph=$(sysf "/sys/class/infiniband/$ca/ports/$p/phys_state")
    rt=$(cat "/sys/class/infiniband/$ca/ports/$p/rate" 2>/dev/null)
    printf '  %s port %s   netdev %-12s State=%-9s Physical=%-9s Rate=%s\n' \
        "$ca" "$p" "${nd:-未取到}" "${st:-未知}" "${ph:-未知}" "${rt:-未知}"
}

# ---------- 设备一览（免 root）----------
list_all() {
    local ca n p nd ll st ph rt
    printf '%s\n' "==================== 本机 RDMA 设备 ===================="
    n=0
    for ca in /sys/class/infiniband/*; do
        [ -e "$ca" ] || continue
        n=$((n + 1))
        printf '\n%s\n' "--- $(basename "$ca") ---"
        for p in $(ports_of "$(basename "$ca")"); do
            nd=$(netdev_of_port "$(basename "$ca")" "$p")
            print_port_state "$(basename "$ca")" "$p" "$nd"
        done
    done
    if [ "$n" -eq 0 ]; then
        err "未检测到任何 RDMA 设备"
        info "检查：lsmod | grep mlx5 ; lspci | grep -i mellanox"
        return 1
    fi
    echo ""
    printf '%s\n' "提示：State=ACTIVE 且 Physical=LinkUp 才说明线已插好。"
    printf '%s\n' "     两张卡对打请挑两个【不同 CA】；同一张卡的两个口请用 nic_loop.sh。"
}

show_device_help() {
    local rc="${1:-2}"
    echo ""
    list_all
    echo ""
    echo -e "${YELLOW}正确用法：${NC}"
    echo "  sudo bash $0 <设备1> <设备2> [预期单口速率]"
    echo ""
    echo "示例："
    echo "  sudo bash $0 mlx5_0 mlx5_1"
    echo "  sudo bash $0 mlx5_0 mlx5_1 400"
    echo ""
    echo "只想看设备与链路状态（免 root）："
    echo "  bash $0 --list"
    exit "$rc"
}

# ---------- --list 模式 ----------
if [ "$DO_LIST" = "1" ]; then
    list_all || exit 1
    exit 0
fi

# ---------- 参数校验 ----------
if [ "${#POS[@]}" -eq 0 ]; then
    err "必须指定两个设备名（或加 --list 只看设备）"
    show_device_help 2
fi
if [ "${#POS[@]}" -lt 2 ]; then
    err "参数个数不正确：需要 2 个设备名，收到 ${#POS[@]} 个"
    show_device_help 2
fi
if [ "${#POS[@]}" -gt 3 ]; then
    err "参数过多：最多 3 个（设备1 设备2 [预期速率]）"
    show_device_help 2
fi

DEV1="${POS[0]}"; DEV2="${POS[1]}"
RATE_ARG="${POS[2]:-${EXPECT_RATE:-0}}"

if [ "$DEV1" = "$DEV2" ]; then
    err "两个设备不能相同（$DEV1）"
    info "同一张卡的两个口请用 nic_loop.sh；本脚本要两张不同的卡。"
    exit 1
fi
for d in "$DEV1" "$DEV2"; do
    if [ ! -d "/sys/class/infiniband/$d" ]; then
        err "设备 '$d' 不存在"
        info "现有设备：$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
done

if [ "$(id -u)" -ne 0 ]; then
    err "需要 root 权限（要配 IP、起 ib_write_bw）"
    info "只看设备与链路状态可用：bash $0 --list"
    exit 1
fi

if ! command -v ib_write_bw >/dev/null 2>&1; then
    err "未检测到 ib_write_bw"
    info "安装：apt install perftest   （RHEL: yum install perftest）"
    exit 1
fi

# ---------- 挑端口 / 取 netdev ----------
P1=$(pick_port "$DEV1" "$PORT1")
P2=$(pick_port "$DEV2" "$PORT2")

if [ -z "$P1" ] || [ -z "$P2" ]; then
    err "无法确定端口号（$DEV1 -> ${P1:-无}，$DEV2 -> ${P2:-无}）"
    exit 1
fi

ND1=$(netdev_of_port "$DEV1" "$P1" || true)
ND2=$(netdev_of_port "$DEV2" "$P2" || true)

echo ""
echo -e "${BLUE}========== 两张网卡对打测试 ==========${NC}"
echo "  设备 1 : $DEV1  (port $P1, netdev ${ND1:-未取到})"
echo "  设备 2 : $DEV2  (port $P2, netdev ${ND2:-未取到})"
echo "  参数   : QP=$QP  MTU=$MTU_ARG  时长=${DURATION}s  双向=$([ "$BIDIR" = "1" ] && echo 是 || echo 否)"

if [ -z "$ND1" ] || [ -z "$ND2" ]; then
    err "无法取到 netdev，IP 配不上去"
    info "手工排查：ls /sys/class/infiniband/$DEV1/ports/$P1/gid_attrs/ndevs/"
    info "          ls /sys/class/infiniband/$DEV1/device/net/"
    exit 1
fi

# ---------- 链路预检 ----------
echo ""
echo -e "${BLUE}==================== 链路状态 ====================${NC}"
print_port_state "$DEV1" "$P1" "$ND1"
print_port_state "$DEV2" "$P2" "$ND2"

LL1=$(ibstat "$DEV1" 2>/dev/null | sed -n 's/^[[:space:]]*Link layer:[[:space:]]*//p' | head -1)
LL2=$(ibstat "$DEV2" 2>/dev/null | sed -n 's/^[[:space:]]*Link layer:[[:space:]]*//p' | head -1)
[ -n "$LL1" ] && echo "  Link layer : $DEV1=$LL1  $DEV2=${LL2:-未知}"

# LINK_TYPE：1=IB  2=ETH。按 PCI BDF 精确匹配 mst 设备，避免多卡时读错卡
link_type_of() {
    local ca="$1" bdf mdev
    command -v mlxconfig >/dev/null 2>&1 || return 1
    command -v mst >/dev/null 2>&1 || return 1
    mst start >/dev/null 2>&1
    bdf=$(basename "$(readlink -f "/sys/class/infiniband/$ca/device" 2>/dev/null)" 2>/dev/null)
    if [ -n "$bdf" ] && command -v mst >/dev/null 2>&1; then
        mdev=$(mst status -v 2>/dev/null | awk -v b="$bdf" '$0 ~ b {for(i=1;i<=NF;i++) if($i ~ /^\/dev\/mst\//){print $i; exit}}')
    fi
    # 回退：单卡场景直接取第一个 mst 设备
    if [ -z "${mdev:-}" ]; then
        mdev=$(mst status 2>/dev/null | grep -oE '/dev/mst/[^[:space:]]*' | head -1)
        [ -n "${mdev:-}" ] && warn "未能按 PCI($bdf) 匹配 mst 设备，回退用第一个：$mdev（多卡时可能读错卡）" >&2
    fi
    [ -z "${mdev:-}" ] && return 1
    mlxconfig -d "$mdev" query 2>/dev/null \
        | sed -n 's/^[[:space:]]*LINK_TYPE[^:]*:[[:space:]]*//p' | head -1
}

LT1=$(link_type_of "$DEV1" || true)
LT2=$(link_type_of "$DEV2" || true)
[ -n "${LT1:-}${LT2:-}" ] && echo "  LINK_TYPE  : $DEV1=${LT1:-未知}  $DEV2=${LT2:-未知}   （1=IB  2=ETH）"

# 预检判定：State 必须 ACTIVE，Physical 必须 LinkUp
LINK_OK=1
for pair in "$DEV1|$P1|$ND1" "$DEV2|$P2|$ND2"; do
    ca="${pair%%|*}"; rest="${pair#*|}"; p="${rest%%|*}"; nd="${rest#*|}"
    st=$(sysf "/sys/class/infiniband/$ca/ports/$p/state")
    ph=$(sysf "/sys/class/infiniband/$ca/ports/$p/phys_state")
    if [ "$st" != "ACTIVE" ] || [ "$ph" != "LinkUp" ]; then
        err "$ca port $p 链路未就绪：State=${st:-未知}  Physical=${ph:-未知}"
        LINK_OK=0
    fi
done

if [ "$LINK_OK" -ne 1 ]; then
    echo ""
    err "链路预检不通过，直接退出（不再白跑一遍打流）"
    info "排查：① 两个口之间是否真的插了线（DAC 直连，或 两个光模块 + 光纤）"
    info "      ② 是否误把两个口接到了同一台交换机（会成环被 block）"
    info "      ③ IB 模式需要 Subnet Manager，否则 State 会停在 Initializing"
    info "      ④ 光模块是否与卡/线匹配（速率、封装、厂商兼容）"
    exit 1
fi
ok "两个端口链路均 ACTIVE / LinkUp"

# ---------- 配 IP ----------
cleanup() {
    ip addr del "$IP1/24" dev "$ND1" 2>/dev/null
    ip addr del "$IP2/24" dev "$ND2" 2>/dev/null
    pkill -f "ib_write_bw -d $DEV1 -p $PORTNUM" 2>/dev/null
    pkill -f "ib_write_bw -d $DEV2 -p $PORTNUM" 2>/dev/null
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

echo ""
echo -e "${BLUE}==================== 配置对打 IP ====================${NC}"
ip addr del "$IP1/24" dev "$ND1" 2>/dev/null
ip addr del "$IP2/24" dev "$ND2" 2>/dev/null
ip link set "$ND1" up 2>/dev/null
ip link set "$ND2" up 2>/dev/null
ip addr add "$IP1/24" dev "$ND1" 2>/dev/null
ip addr add "$IP2/24" dev "$ND2" 2>/dev/null

if ! ip addr show "$ND1" | grep -q "$IP1"; then err "$ND1 配置 $IP1 失败"; exit 1; fi
if ! ip addr show "$ND2" | grep -q "$IP2"; then err "$ND2 配置 $IP2 失败"; exit 1; fi
ok "$ND1 = $IP1    $ND2 = $IP2"

# ---------- RoCE 模式下确认 GID ----------
if [ "${LL1:-}" != "InfiniBand" ] && [ "${LL2:-}" != "InfiniBand" ]; then
    GID_HINT=""
    for gi in "/sys/class/infiniband/$DEV2/ports/$P2"/gid_attrs/types/*; do
        [ -e "$gi" ] || continue
        case "$(cat "$gi" 2>/dev/null)" in
            *v2*) GID_HINT="$(basename "$gi")"; break ;;
        esac
    done
    info "RoCE 模式：$DEV2 port $P2 的 RoCE v2 GID 索引 = ${GID_HINT:-未识别}"
    [ -n "$GID_HINT" ] && info "若 RDMA 连不上，可加 -g $GID_HINT 重试"
fi

# ---------- 达标线 ----------
if [ "${RATE_ARG:-0}" -eq 0 ] 2>/dev/null; then
    R1=$(port_rate_gbps "$DEV1" "$P1" "$ND1")
    R2=$(port_rate_gbps "$DEV2" "$P2" "$ND2")
    RATE_ARG=$(awk -v a="${R1:-0}" -v b="${R2:-0}" 'BEGIN{ if(a>0&&b>0) printf "%d", (a<b?a:b); else printf "%d", (a>b?a:b) }')
fi
THRESHOLD=0
if [ "${RATE_ARG:-0}" -gt 0 ] 2>/dev/null; then
    THRESHOLD=$(awk -v r="$RATE_ARG" -v p="$THRESHOLD_PCT" 'BEGIN{printf "%.1f", r*p/100}')
fi

# ---------- 走线缆核对：记基线 ----------
C_TX_BEFORE=""; C_RX_BEFORE=""
if [ "$SKIP_CABLE_CHECK" != "1" ]; then
    C_TX_BEFORE=$(read_counter "$ND2" tx)   # 客户端发
    C_RX_BEFORE=$(read_counter "$ND1" rx)   # 服务端收
fi

# ---------- 打流 ----------
echo ""
echo -e "${BLUE}==================== RDMA 打流 ====================${NC}"
echo "  $DEV1 (port $P1)  <->  $DEV2 (port $P2)"
# 必须带 --report_gbits：perftest 默认输出 MiB/sec，不带这个开关时下面 awk 取到的
# 第 4 列是 MiB/s 的数值，却被按 Gb/s 打印和比较 —— 达标线会被放大 119 倍（恒 PASS）。
# 加了它，第 4 列才是真正的 Gb/sec。
echo "  ib_write_bw -q $QP $MTU_ARG --report_gbits -D $DURATION $([ "$BIDIR" = "1" ] && echo -b)"
echo ""

ib_write_bw -d "$DEV1" -i "$P1" -p "$PORTNUM" $MTU_ARG -q "$QP" --report_gbits >/dev/null 2>&1 &
SRV=$!
sleep 3

CLIENT_EXTRA=""
[ "$BIDIR" = "1" ] && CLIENT_EXTRA="-b"

OUT=$(timeout $((DURATION + 30)) ib_write_bw -d "$DEV2" -i "$P2" -p "$PORTNUM" $MTU_ARG -q "$QP" \
        --report_gbits -D "$DURATION" $CLIENT_EXTRA "$IP1" 2>&1)
RC=$?

# 指定 MTU 失败时退回默认 MTU 再试一次
if [ $RC -ne 0 ] && [ "$MTU_ARG" != "-m 1024" ]; then
    warn "指定 MTU（$MTU_ARG）失败，退回默认 MTU 重试..."
    kill $SRV 2>/dev/null
    ib_write_bw -d "$DEV1" -i "$P1" -p "$((PORTNUM + 1))" -q "$QP" --report_gbits >/dev/null 2>&1 &
    SRV=$!
    sleep 3
    OUT=$(timeout $((DURATION + 30)) ib_write_bw -d "$DEV2" -i "$P2" -p "$((PORTNUM + 1))" -q "$QP" \
            --report_gbits -D "$DURATION" $CLIENT_EXTRA "$IP1" 2>&1)
    RC=$?
fi

kill $SRV 2>/dev/null
wait $SRV 2>/dev/null

# ---------- 走线缆核对：读增量 ----------
CABLE_VERDICT="未核对"
if [ "$SKIP_CABLE_CHECK" != "1" ]; then
    C_TX_AFTER=$(read_counter "$ND2" tx)
    C_RX_AFTER=$(read_counter "$ND1" rx)
    if [ -n "$C_TX_BEFORE" ] && [ -n "$C_TX_AFTER" ]; then
        D_TX=$(awk -v a="$C_TX_BEFORE" -v b="$C_TX_AFTER" 'BEGIN{printf "%.0f", b-a}')
        D_RX=$(awk -v a="${C_RX_BEFORE:-0}" -v b="${C_RX_AFTER:-0}" 'BEGIN{printf "%.0f", b-a}')
        if [ "${D_TX:-0}" -gt 0 ] 2>/dev/null; then
            CABLE_VERDICT="通过（$ND2 发出 +$D_TX 字节，$ND1 收到 +$D_RX 字节）"
        else
            CABLE_VERDICT="可疑（$ND2 发出计数未增长，数据可能没走物理口）"
        fi
    else
        CABLE_VERDICT="无法核对（读不到计数器）"
    fi
fi

# ---------- 结果 ----------
# perftest 输出形如：
#    #bytes  #iterations  BW peak[Gb/sec]  BW average[Gb/sec]  MsgRate[Mpps]
#    65536   1000         0.00             98.50               0.188
# 第 1 列是 #bytes（表头那行不是纯数字，会被跳过），BW average 在第 4 列。
# 多 QP 时会输出多行：末行通常是合计值，故取最后一个数字行。
BW_ROWS=$(printf '%s\n' "$OUT" | awk '$1 ~ /^[0-9]+$/ && NF>=4' | wc -l | tr -d ' ')
BW=$(printf '%s\n' "$OUT" | awk '$1 ~ /^[0-9]+$/ && NF>=4 {v=$4} END{if(v!="") print v}')

echo ""
echo -e "${BLUE}==================== 结果 ====================${NC}"

if [ $RC -ne 0 ] || [ -z "$BW" ]; then
    err "RDMA 打流失败（退出码 $RC）"
    printf '%s\n' "$OUT" | tail -6 | sed 's/^/     /'
    echo ""
    info "排查：① 上面链路状态是否 ACTIVE / LinkUp"
    info "      ② RoCE 需指定 GID：加 -g <索引>"
    info "      ③ IB 模式需 Subnet Manager"
    info "      ④ 两端 MTU / PFC 配置是否一致"
    info "      ⑤ 试 SKIP_CABLE_CHECK=1 排除核对逻辑干扰"
    echo ""
    echo "  走线缆核对 : $CABLE_VERDICT"
    exit 1
fi

printf '%s\n' "$OUT" | grep -E 'Gb/sec' | tail -4 | sed 's/^/     /'
if [ "${BW_ROWS:-1}" -gt 1 ] 2>/dev/null; then
    info "共解析到 $BW_ROWS 行结果，取末行作为带宽（perftest 多 QP 时末行通常是合计）。"
    info "若上面原始输出里没有合计行，请用 QP=1 重跑，或按各行人工相加核对。"
fi

PASS=1
PENDING=0
if [ "$THRESHOLD" != "0" ]; then
    if awk -v a="$BW" -v b="$THRESHOLD" 'BEGIN{exit !(a+0>=b+0)}'; then
        ok "RDMA $([ "$BIDIR" = "1" ] && echo 双向 || echo 单向) $BW Gb/s ≥ 达标线 $THRESHOLD Gb/s（单口 ${RATE_ARG}G 的 ${THRESHOLD_PCT}%）"
    else
        err "RDMA $([ "$BIDIR" = "1" ] && echo 双向 || echo 单向) $BW Gb/s < 达标线 $THRESHOLD Gb/s（单口 ${RATE_ARG}G 的 ${THRESHOLD_PCT}%）"
        PASS=0
    fi
else
    # ★ 没做达标判定 = 本次没有结论，不能算通过。
    #   之前这里只 warn、PASS 仍为 1，收尾会打出「两卡对打测试通过」+ exit 0，
    #   而输出里却写着「未做达标判定」—— 这是伪装性最强的假绿。
    PENDING=1
    warn "RDMA $([ "$BIDIR" = "1" ] && echo 双向 || echo 单向) $BW Gb/s —— 读不到端口速率，本次未做达标判定"
fi

echo "  走线缆核对 : $CABLE_VERDICT"
case "$CABLE_VERDICT" in
    可疑*) warn "端口发出计数没有增长，建议确认数据是否真从物理口出去（而不是本地捷径）" ;;
esac

echo ""
echo -e "${BLUE}==================== 汇总 ====================${NC}"
echo "  设备 1        : $DEV1  port $P1  netdev $ND1"
echo "  设备 2        : $DEV2  port $P2  netdev $ND2"
echo "  Link layer    : ${LL1:-未知}"
echo "  QP / MTU      : $QP / $MTU_ARG"
echo "  RDMA $([ "$BIDIR" = "1" ] && echo 双向 || echo 单向)     : $BW Gb/s"
echo "  达标线        : ${THRESHOLD} Gb/s"

if [ "$PASS" -ne 1 ]; then
    err "【判定】FAIL —— 两卡对打测试不通过"
    exit 1
elif [ "$PENDING" -eq 1 ]; then
    warn "【判定】Pending —— 打流完成（$BW Gb/s），但读不到端口速率，未做达标判定，本次不算通过"
    info "补判办法：显式给出预期单口速率重跑，例如  sudo bash ib_2.sh $DEV1 $DEV2 <单口速率Gb/s>"
    exit 1
else
    ok "【判定】PASS —— 两卡对打测试通过"
    exit 0
fi
