#!/bin/bash
# =============================================================================
# 单张双口网卡 端口自环测试脚本（同一张卡 port1 <-> port2）
#
# 为什么需要这个脚本？
#   ib_2.sh 要求两个【不同的 CA 名】（/sys/class/infiniband/<dev>），且显式拒绝
#   DEV1=DEV2。而一张双口卡只有一个 CA（如 mlx5_8），两个口是它的 port 1 / port 2。
#   所以「管理/存储面只有一张网卡」时，ib_2.sh 用不了，必须用本脚本。
#   （另外 ib_2.sh 取接口名那句 `device/net/ | head -1` 对同一 CA 会返回同一个
#     netdev，两个口会撞在一起 —— 本脚本按 port 索引精确取 netdev。）
#
# 前提：
#   1) 网卡两个端口已用 DAC 直连，或 两个光模块 + 光纤 对接
#   2) 卡上至少 2 个端口
#
# 用法：
#   sudo bash nic_loop.sh                    # 自动发现双口卡（多张时列出让选）
#   sudo bash nic_loop.sh mlx5_8             # 指定 CA
#   sudo bash nic_loop.sh mlx5_8 100         # 指定 CA + 预期单口速率(Gb/s)
#
# 环境变量：
#   EXPECT_RATE=100    预期单口速率(Gb/s)，未给则自动从端口能力推导
#   IP_A / IP_B        自环用的两个 IP，默认 192.168.201.1 / 192.168.201.2
#   USE_TCP=1          只跑 iperf3（TCP），跳过 RDMA
#   RUN_TCP=1          额外跑 iperf3 自环段（USE_TCP=1 时自动开启）
#                      ⚠️ 同主机双 IP 的 TCP 会被内核 local 路由表交给 lo，
#                         测到的是内存带宽而非网口带宽 —— TCP 请用 iperf3.sh
#   MTU_ARG="-m 4096"  覆盖 perftest 的 MTU 参数（默认 -m 1024）
#   THRESHOLD_PCT=90   达标线 = 单口速率 × N%（与 ib_2.sh 同一口径、见 SOP 7.4.2）
#
# 判定口径（与 ib_2.sh / chip_loop.sh 一致，三态）：
#   PASS    取到带宽且 ≥ 达标线（单口速率 × THRESHOLD_PCT）
#   FAIL    取到带宽但低于达标线；或 RDMA 自环跑不起来
#   Pending 未给预期速率（EXPECT_RATE 为空且端口能力读不到）时只记录不判定
# 退出码：0 = PASS   1 = FAIL / 无任何有效结果
# =============================================================================

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限（sudo bash $0）"
    exit 1
fi

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then BLUE=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; fi

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${CYAN}   $1${NC}"; }

PORTNUM=18515
IP_A="${IP_A:-192.168.201.1}"
IP_B="${IP_B:-192.168.201.2}"
USE_TCP="${USE_TCP:-0}"
# 达标线百分比：与 ib_2.sh 的 THRESHOLD_PCT 同口径（SOP 7.4.2）
: "${THRESHOLD_PCT:=90}"
RUN_TCP="${RUN_TCP:-0}"
MTU_ARG="${MTU_ARG:--m 1024}"

# ---------- 依赖 ----------
HAVE_PERF=0; HAVE_IPERF=0
command -v ib_write_bw >/dev/null 2>&1 && HAVE_PERF=1
command -v iperf3     >/dev/null 2>&1 && HAVE_IPERF=1
if [ "$USE_TCP" != "1" ] && [ "$HAVE_PERF" -eq 0 ]; then
    warn "ib_write_bw 未安装（apt install perftest），本次只跑 TCP"
    USE_TCP=1
fi
if [ "$HAVE_IPERF" -eq 0 ]; then
    warn "iperf3 未安装（apt install iperf3），TCP 部分跳过"
fi
# USE_TCP=1（只跑 TCP）时自动开启 TCP 段；默认 RUN_TCP=0，见文件头说明
[ "$USE_TCP" = "1" ] && RUN_TCP=1

# ---------- 列出多口 CA ----------
# 端口数直接数 /sys/class/infiniband/<ca>/ports/* 下的数字目录
list_multi_port_cas() {
    local ca n
    for ca in /sys/class/infiniband/*; do
        [ -e "$ca" ] || continue
        n=$(ls -d "$ca"/ports/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -ge 2 ] && printf '%s|%s\n' "$(basename "$ca")" "$n"
    done
}

# ---------- 选择 CA ----------
CA="${1:-}"
RATE_ARG="${2:-${EXPECT_RATE:-0}}"

if [ -z "$CA" ]; then
    CAND=$(list_multi_port_cas)
    CNT=$(printf '%s\n' "$CAND" | grep -c . )
    if [ "$CNT" -eq 0 ]; then
        err "未发现任何多端口 RDMA 设备"
        echo "  检查：lsmod | grep mlx5 ； lspci | grep -i mellanox"
        echo "  提示：只有单口卡时无法做端口自环，需两张卡对接（用 ib_2.sh）"
        exit 1
    fi
    echo -e "${BLUE}==================== 可自环的双口/多口网卡 ====================${NC}"
    printf '%s\n' "$CAND" | while IFS='|' read -r c n; do
        [ -n "$c" ] && echo "  $c  （$n 个端口）"
    done
    echo ""
    if [ "$CNT" -eq 1 ]; then
        CA=$(printf '%s\n' "$CAND" | head -1 | cut -d'|' -f1)
        echo -e "${CYAN}自动选用：$CA${NC}"
    else
        err "检测到多个多口设备，请显式指定："
        echo "  sudo bash $0 <CA名> [预期速率]"
        exit 1
    fi
fi

if [ ! -d "/sys/class/infiniband/$CA" ]; then
    err "设备 '$CA' 不存在"
    echo "  现有设备：$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

PORTS=($(ls -d "/sys/class/infiniband/$CA"/ports/[0-9]* 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -n))
if [ "${#PORTS[@]}" -lt 2 ]; then
    err "$CA 只有 ${#PORTS[@]} 个端口，无法做端口自环"
    echo "  单口卡请改用 ib_2.sh（需两张卡对接）"
    exit 1
fi
P1="${PORTS[0]}"; P2="${PORTS[1]}"

# ---------- 取每个 port 对应的 netdev ----------
# 正确做法：读 ports/<p>/gid_attrs/ndevs/<idx>（RoCE 的 GID 会指向其 netdev）。
# 取不到时退回 device/net/ 的排序结果（按端口号排，通常是 ...f0np0 / ...f0np1）。
netdev_of_port() {
    local ca="$1" p="$2" nd name
    for nd in "$ca/ports/$p"/gid_attrs/ndevs/*; do
        [ -e "$nd" ] || continue
        name=$(cat "$nd" 2>/dev/null | head -1)
        [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
    done
    return 1
}

# ---------- 取某个 CA 对应的 mst 设备节点 ----------
# 为什么不能 `mst status | ... | head -1`：
#   多卡机上 mst status 会列出所有 mlx5 卡（8 卡机就有 8 个节点），head -1 永远
#   拿第一张 —— 读到的 LINK_TYPE / 端口能力都是别的卡的，阈值会被抬到那张卡的
#   速率（例如把 100G 的口按 400G 判 360G 下限），验收结论直接错。
# 正确做法：用本 CA 的 PCI BDF 去 mst status -v 的表里匹配。
mdev_of_ca() {
    local ca="$1" bdf="${2:-}" dev
    if [ -z "$bdf" ]; then
        [ -e "/sys/class/infiniband/$ca/device" ] || return 1
        bdf=$(basename "$(readlink -f "/sys/class/infiniband/$ca/device" 2>/dev/null)")
    fi
    [ -n "$bdf" ] || return 1

    # 格式一：mst status -v 的表格（同一行内既有 PCI BDF 又有 /dev/mst/ 节点）
    dev=$(mst status -v 2>/dev/null | awk -v b="$bdf" '
        { bd = ""
          for (i = 1; i <= NF; i++)
              if ($i ~ /^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]$/) bd = $i
          if (bd == b) { print $NF; exit } }')
    [ -n "$dev" ] && { printf "%s\n" "$dev"; return 0; }

    # 格式二：mst status 的块状输出（设备名一行，紧随其后那行带 domain:bus:dev.fn=）
    dev=$(mst status 2>/dev/null | awk -v b="$bdf" '
        /^\/dev\/mst\// { cand = $1; next }
        cand != "" && index($0, b) > 0 { print cand; exit }')
    [ -n "$dev" ] || return 1
    printf "%s\n" "$dev"
}

# ---------- 读 ethtool 计数器（核对数据是否真的过线缆）----------
read_counter() {
    ethtool -S "$1" 2>/dev/null | awk -v k="$2" -F: \
        '$1 ~ ("^[[:space:]]*" k "[[:space:]]*$") { gsub(/[ \t]/, "", $2); print $2 + 0; exit }'
}

# 不同驱动版本的「物理层发送字节数」计数器叫法不同，探测一个能用的
pick_tx_counter() {
    local nd="$1" c
    for c in tx_bytes_phy port_xmit_data tx_bytes; do
        [ -n "$(read_counter "$nd" "$c")" ] && { printf "%s" "$c"; return 0; }
    done
    return 1
}

ND1=$(netdev_of_port "/sys/class/infiniband/$CA" "$P1" || true)
ND2=$(netdev_of_port "/sys/class/infiniband/$CA" "$P2" || true)
ND_SRC="gid_attrs/ndevs"
if [ -z "$ND1" ] || [ -z "$ND2" ] || [ "$ND1" = "$ND2" ]; then
    # 退回排序法
    mapfile -t NDS < <(ls "/sys/class/infiniband/$CA/device/net/" 2>/dev/null | sort)
    ND1="${NDS[0]:-}"; ND2="${NDS[1]:-}"
    ND_SRC="device/net 排序（回退）"
fi

echo -e "${BLUE}==================== 设备与端口 ====================${NC}"
echo "  CA          : $CA"
echo "  自环端口    : port $P1 <-> port $P2"
echo "  netdev      : ${ND1:-未取到}  <->  ${ND2:-未取到}   （来源：$ND_SRC）"

# Link layer：本单是 RoCEv2，应为 Ethernet。IB 模式下自环需要 Subnet Manager。
LL_INFO=$(ibstat "$CA" 2>/dev/null | sed -n 's/^[[:space:]]*Link layer:[[:space:]]*//p' | head -1)
[ -n "$LL_INFO" ] && echo "  Link layer  : $LL_INFO"
# mst 设备节点：必须按 BDF 匹配本 CA，不能 head -1（多卡机会读错卡）
MDEV=""
if command -v mst >/dev/null 2>&1; then
    mst start >/dev/null 2>&1
    MDEV=$(mdev_of_ca "$CA" || true)
fi
if [ -n "$MDEV" ] && command -v mlxconfig >/dev/null 2>&1; then
    LT=$(mlxconfig -d "$MDEV" query 2>/dev/null | sed -n 's/^[[:space:]]*LINK_TYPE[^:]*:[[:space:]]*//p' | head -1)
    [ -n "$LT" ] && echo "  LINK_TYPE   : $LT   （1=IB  2=ETH）"
elif command -v mst >/dev/null 2>&1; then
    _bdf=$(basename "$(readlink -f "/sys/class/infiniband/$CA/device" 2>/dev/null)")
    warn "未按 BDF 匹配到 $CA（${_bdf:-未知}）的 mst 设备节点，跳过 LINK_TYPE / 端口能力读取"
    echo "     手动核对：mst status -v"
fi

# ---------- 端口链路状态 ----------
echo ""
echo -e "${BLUE}==================== 端口链路状态 ====================${NC}"
ibstat "$CA" 2>/dev/null | awk -v p1="$P1" -v p2="$P2" '
    /^[[:space:]]*Port [0-9]+:/ { cur=$2; sub(/:$/,"",cur) }
    cur==p1 || cur==p2 {
        if (/State:/ && !/Physical/) printf "  port %s State          : %s\n", cur, substr($0, index($0,":")+2)
        if (/Physical state:/)      printf "  port %s Physical state : %s\n", cur, substr($0, index($0,":")+2)
        if (/Rate:/)                printf "  port %s Rate           : %s\n", cur, substr($0, index($0,":")+2)
    }'

CAP_RATE=""
# 复用上面按 BDF 匹配到的 MDEV，不要再 mst status | head -1（会读错卡）
if command -v mlxlink >/dev/null 2>&1 && [ -n "$MDEV" ]; then
    CAP_RATE=$(mlxlink -d "$MDEV" -p "$P1" 2>/dev/null \
        | grep -i 'Enabled Link Speed' | sed -n 's/.*(\([^)]*\)).*/\1/p' | cut -d',' -f1 | tr -cd '0-9')
fi
[ -n "$CAP_RATE" ] && echo "  端口能力    : ${CAP_RATE}Gb/s（来源 mlxlink）"

if [ "${RATE_ARG:-0}" -eq 0 ] && [ -n "$CAP_RATE" ] && [ "$CAP_RATE" -gt 0 ]; then
    RATE_ARG="$CAP_RATE"
fi

# ---------- 链路预检 ----------
# RDMA 没有软件回环：QP 要绑到物理 port 的 GID 上，两个口都必须 LinkUp，
# 否则后面只会白等 3s + 40s 超时。这里提前拦掉。（只跑 TCP 时不需要插线）
if [ "$USE_TCP" != "1" ]; then
    read -r ST1 ST2 < <(ibstat "$CA" 2>/dev/null | awk -v p1="$P1" -v p2="$P2" '
        /^[[:space:]]*Port [0-9]+:/ { cur=$2; sub(/:$/, "", cur) }
        cur==p1 || cur==p2 { if (/Physical state:/) v[cur]=substr($0, index($0,":")+2) }
        END { printf "%s %s\n", (v[p1] ? v[p1] : "?"), (v[p2] ? v[p2] : "?") }')
    if [ "$ST1" != "LinkUp" ] || [ "$ST2" != "LinkUp" ]; then
        err "端口未 LinkUp（port $P1=${ST1:-?}，port $P2=${ST2:-?}），RDMA 无软件回环，必须先插线"
        echo "  对照：DAC 直连 / 两个光模块 + 光纤对接"
        echo "  复看：ibstat $CA"
        exit 1
    fi
    ok "两口物理链路已 LinkUp（port $P1 / port $P2）"
fi

# ---------- 配 IP ----------
if [ -z "$ND1" ] || [ -z "$ND2" ] || [ "$ND1" = "$ND2" ]; then
    err "无法确定两个端口各自的 netdev，自环 IP 配置不了"
    echo "  手动排查：ls /sys/class/infiniband/$CA/ports/*/gid_attrs/ndevs/"
    echo "            ls /sys/class/infiniband/$CA/device/net/"
    exit 1
fi

cleanup() {
    ip addr del "$IP_A/24" dev "$ND1" 2>/dev/null
    ip addr del "$IP_B/24" dev "$ND2" 2>/dev/null
    [ "$HAVE_PERF" -eq 1 ] && pkill -f "ib_write_bw -d $CA" 2>/dev/null
    [ "$HAVE_IPERF" -eq 1 ] && pkill -f "iperf3 -s -p $PORTNUM" 2>/dev/null
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

echo ""
echo -e "${BLUE}==================== 配置自环 IP ====================${NC}"
ip addr del "$IP_A/24" dev "$ND1" 2>/dev/null
ip addr del "$IP_B/24" dev "$ND2" 2>/dev/null
ip link set "$ND1" up 2>/dev/null
ip link set "$ND2" up 2>/dev/null
ip addr add "$IP_A/24" dev "$ND1" 2>/dev/null
ip addr add "$IP_B/24" dev "$ND2" 2>/dev/null

if ! ip addr show "$ND1" | grep -q "$IP_A"; then err "$ND1 配置 $IP_A 失败"; exit 1; fi
if ! ip addr show "$ND2" | grep -q "$IP_B"; then err "$ND2 配置 $IP_B 失败"; exit 1; fi
ok "$ND1 = $IP_A    $ND2 = $IP_B"

# ---------- RoCE 模式下确认 GID ----------
if [ "$USE_TCP" != "1" ] && [ "${LL_INFO:-}" != "InfiniBand" ]; then
    GID_HINT=""
    for gi in "/sys/class/infiniband/$CA/ports/$P2"/gid_attrs/types/*; do
        [ -e "$gi" ] || continue
        t=$(cat "$gi" 2>/dev/null)
        case "$t" in
            *v2*) GID_HINT="$(basename "$gi")"; break ;;
        esac
    done
    echo ""
    echo -e "${CYAN}   RoCE 模式：port $P2 的 RoCE v2 GID 索引 = ${GID_HINT:-未识别}${NC}"
    echo -e "${CYAN}   若 RDMA 连不上，用：ib_write_bw ... -g ${GID_HINT:-<索引>}${NC}"
fi

# ---------- 测 RDMA ----------
RDMA_FAIL=0
RDMA_BW=""; RDMA_RC=1
TX_CNT=""; TX1_BEFORE=""; TX2_BEFORE=""
if [ "$USE_TCP" != "1" ]; then
    echo ""
    echo -e "${BLUE}==================== RDMA 带宽（ib_write_bw 自环）====================${NC}"
    # 必须带 --report_gbits：perftest 默认输出 MiB/sec，不带这个开关时下面 awk 取到的
    # 第 4 列是 MiB/s 的数值，却被按 Gb/s 打印和比较 —— 达标线会被放大 119 倍（恒 PASS），
    # 屏幕上的数字也会冒充 Gb/s。加了它，第 4 列才是真正的 Gb/sec。
    echo "  $CA port $P1  <->  port $P2   ${MTU_ARG}  -q 8  --report_gbits  -D 10"
    echo ""

    # 跑前记录物理层发送字节数，跑后比对 —— 有增量才证明数据真的过了线缆，
    # 而不是又绕回了软件路径（这是「自环测试是否有效」的关键证据）
    TX_CNT=$(pick_tx_counter "$ND1" || true)
    if [ -n "$TX_CNT" ]; then
        TX1_BEFORE=$(read_counter "$ND1" "$TX_CNT")
        TX2_BEFORE=$(read_counter "$ND2" "$TX_CNT")
    fi

    ib_write_bw -d "$CA" -i "$P1" -p "$PORTNUM" $MTU_ARG -q 8 --report_gbits >/tmp/nl_srv.$$ 2>&1 &
    SRV=$!
    sleep 3

    OUT=$(timeout 40 ib_write_bw -d "$CA" -i "$P2" -p "$PORTNUM" $MTU_ARG -q 8 --report_gbits -D 10 "$IP_A" 2>&1)
    RDMA_RC=$?

    if [ $RDMA_RC -ne 0 ]; then
        # 带 -m 4096 失败时退回默认 MTU 再试一次
        if [ "$MTU_ARG" != "-m 1024" ]; then
            warn "指定 MTU 失败，退回默认 MTU 重试..."
            kill $SRV 2>/dev/null
            ib_write_bw -d "$CA" -i "$P1" -p "$((PORTNUM+1))" -q 8 --report_gbits >/tmp/nl_srv.$$ 2>&1 &
            SRV=$!
            sleep 3
            OUT=$(timeout 40 ib_write_bw -d "$CA" -i "$P2" -p "$((PORTNUM+1))" -q 8 --report_gbits -D 10 "$IP_A" 2>&1)
            RDMA_RC=$?
        fi
    fi

    # 取 BW average 列（第 4 列）。表头行第 1 列是 "#bytes" 非数字，会被跳过，
    # 避免把表头里的 "#iterations" 当成带宽值。
    RDMA_BW=$(printf '%s\n' "$OUT" | awk '$1 ~ /^[0-9]+$/ && NF>=4 {v=$4} END{if(v!="") print v}')

    if [ $RDMA_RC -eq 0 ] && [ -n "$RDMA_BW" ]; then
        if [ "${RATE_ARG:-0}" -gt 0 ]; then
            # 达标线 = 单口速率 × THRESHOLD_PCT（默认 90%，与 ib_2.sh 一致）
            TH=$(awk -v r="$RATE_ARG" -v p="$THRESHOLD_PCT" 'BEGIN{printf "%.1f", r*p/100}')
            if awk -v a="$RDMA_BW" -v b="$TH" 'BEGIN{exit !(a+0>=b+0)}'; then
                ok "RDMA 单向 $RDMA_BW Gb/s，达到达标线（单口 ${RATE_ARG}G × ${THRESHOLD_PCT}% = ${TH} Gb/s）"
            else
                err "RDMA 单向 $RDMA_BW Gb/s，低于达标线 ${TH} Gb/s（单口 ${RATE_ARG}G × ${THRESHOLD_PCT}%）"
                RDMA_FAIL=1
            fi
        else
            echo -e "${GREEN}✅ RDMA 单向 $RDMA_BW Gb/s（无预期值，仅记录，判定 Pending）${NC}"
        fi
        printf '%s\n' "$OUT" | grep -E 'Gb/sec' | head -2 | sed 's/^/     /'
    else
        err "RDMA 自环测试失败"
        printf '%s\n' "$OUT" | tail -5 | sed 's/^/     /'
        echo -e "${CYAN}     排查：① 两口是否真的对接了（看上面 Physical state）${NC}"
        echo -e "${CYAN}          ② RoCE 需指定 GID：加 -g <索引>${NC}"
        echo -e "${CYAN}          ③ IB 模式需 Subnet Manager，否则 State 会停在 Initializing${NC}"
    fi
    kill $SRV 2>/dev/null
    wait $SRV 2>/dev/null

    # ---------- 走线缆核对 ----------
    if [ -n "$TX_CNT" ] && [ -n "$TX1_BEFORE" ] && [ -n "$TX2_BEFORE" ]; then
        TX1_AFTER=$(read_counter "$ND1" "$TX_CNT")
        TX2_AFTER=$(read_counter "$ND2" "$TX_CNT")
        D1=$(( ${TX1_AFTER:-0} - TX1_BEFORE ))
        D2=$(( ${TX2_AFTER:-0} - TX2_BEFORE ))
        if [ "$D1" -gt 0 ] || [ "$D2" -gt 0 ]; then
            ok "数据确实过物理线缆（port$P1 tx +${D1}B，port$P2 tx +${D2}B，计数器 $TX_CNT）"
        else
            warn "物理层计数器无增量（$TX_CNT 未增长），带宽数字可疑，请人工确认接线"
        fi
    else
        info "本驱动未提供物理层字节计数器（tx_bytes_phy/port_xmit_data），跳过走线缆核对"
    fi
fi

# ---------- 测 TCP ----------
TCP_BW=""
# 默认不跑：同主机双 IP 会被内核 local 路由表交给 lo，测到的是内存带宽。
# 需要真实 TCP 带宽请用 iperf3.sh（它用 netns 隔离，真走线缆）。
if [ "$HAVE_IPERF" -eq 1 ] && [ "$RUN_TCP" = "1" ]; then
    echo ""
    echo -e "${BLUE}==================== TCP 带宽（iperf3 自环，仅供参考）====================${NC}"
    warn "同主机双 IP（$IP_A ↔ $IP_B）的 TCP 走 lo，数字不是网口带宽"
    echo -e "${CYAN}     要测真实 TCP 带宽请用 iperf3.sh（netns 隔离）${NC}"
    iperf3 -s -p "$PORTNUM" -1 >/dev/null 2>&1 &
    sleep 1
    OUT3=$(timeout 30 iperf3 -c "$IP_A" -p "$PORTNUM" -t 10 -P 4 2>&1)
    # iperf3 sender 行形如： [SUM] 0.00-10.00 sec 1.10 GBytes 945 Mbits/sec  sender
    # 单位可能是 Mbits/sec 或 Gbits/sec，值+单位一起取，避免单位写死
    TCP_BW=$(printf '%s\n' "$OUT3" | awk '/sender/ {v=$(NF-2)" "$(NF-1)} END{if(v!="") print v}')
    if [ -n "$TCP_BW" ]; then
        echo -e "${GREEN}✅ TCP 多流合计 $TCP_BW${NC}"
    else
        warn "iperf3 未取到结果"
        printf '%s\n' "$OUT3" | tail -3 | sed 's/^/     /'
    fi
fi

# ---------- 汇总 ----------
echo ""
echo -e "${BLUE}==================== 汇总 ====================${NC}"
echo "  CA            : $CA"
echo "  Link layer    : ${LL_INFO:-未知}"
echo "  自环端口      : port $P1 <-> port $P2"
[ -n "$RDMA_BW" ] && echo "  RDMA 单向     : $RDMA_BW Gb/s" || echo "  RDMA 单向     : 未测出"
[ -n "$TCP_BW" ]  && echo "  TCP 多流合计  : $TCP_BW  （走 lo，非网口带宽）"

if [ "${RDMA_FAIL:-0}" -eq 1 ]; then
    echo -e "${RED}❌ RDMA 带宽低于达标线（单口 ${RATE_ARG}G × ${THRESHOLD_PCT}%），判定 FAIL${NC}"
    exit 1
fi

if [ -n "$RDMA_BW" ] || [ -n "$TCP_BW" ]; then
    echo -e "${GREEN}✅ 端口自环测试完成${NC}"
    exit 0
else
    echo -e "${RED}❌ 未取得任何有效结果，请按上面提示排查${NC}"
    exit 1
fi
