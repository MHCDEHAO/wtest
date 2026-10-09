#!/bin/bash
# ============================================================
# 网卡「芯片自环」测试（mlxlink -l PH）—— 不用插任何线
#
# 为什么需要这个脚本？
#   ib_2.sh / nic_loop.sh 都是 RDMA 打流，要求端口 LinkUp —— 也就是必须先插线。
#   而 mlxlink 的 PH 模式是【PHY 内部 Tx-to-Rx 自环】，信号不出芯片：
#   不用对端、不用线缆、不用光纤。单口卡也能跑，所以 8 张单口 CX-7 可以逐张过。
#
# 它证明什么：
#   只证明【第 1 段】—— 芯片 SerDes / TX 驱动 / RX 均衡 的通路是好的。
#   它【不能】证明：封装、PCB 后端、笼子、光模块、光纤、对端端口。
#   ★ 自环跑出的带宽数字不能当性能验收值，它只回答「通不通」，不回答「够不够快」。
#
# 注意（ConnectX-7 及以后）：
#   1) 配环回必须在链路【完全 down】时才能设进去 —— 所以本脚本要求先拔线。
#   2) 端口可能因为「笼子里没有模块」而起不来。若设完环回端口仍不上，
#      先插一个光模块（不用接线、不用装光纤）再跑一次。
#   3) 测完会自动把环回恢复成 NO（trap 保证，Ctrl+C 也会恢复）。
#   4) 灌流量打的 ib_write_bw 带了 --report_gbits，所以屏幕上的数字单位是 Gb/s。
#      （perftest 默认输出的是 MiB/sec，1 Gb/s = 119.2 MiB/s；不带这个开关，
#        400G 口会显示成 47680，容易被误读成 47680 Gb/s，差 119 倍。）
#
# 用法：
#   sudo bash chip_loop.sh                 自动发现所有 RDMA 设备，逐端口做芯片自环
#   sudo bash chip_loop.sh mlx5_0          只做指定 CA 的所有端口
#   sudo bash chip_loop.sh mlx5_0 1        只做指定 CA 的指定端口
#   bash chip_loop.sh --list               只看设备/端口/环回状态（免 root；不改设备配置，root 下会 mst start 以读取链路类型）
#   bash chip_loop.sh --help
#
# 环境变量：
#   RUN_BW=1             端口起来后跑 ib_write_bw 灌流量（0 = 只验链路与计数器）
#   BW_DURATION=5        打流时长（秒）
#   QP=8                 QP 数
#   MTU_ARG="-m 1024"    perftest 的 MTU 参数
#   LINK_UP_TIMEOUT=20   设完环回后等端口 LinkUp 的秒数
#   IP_SELF=192.168.211.1  自环用的本口 IP（仅 RoCE/以太网模式需要）
#   SKIP_RESTORE=1       测完【不】把环回恢复成 NO（默认一定恢复）
#   PORTNUM=18525        打流端口
#
# 判定口径（三态，与验收记录表一致）：
#   PASS    端口在 PH 自环下起来了（Physical state=LinkUp）
#   FAIL    mlxlink 设环回失败 —— 工具/驱动层面就没通过
#   Pending 环回设上了但端口没起来（多半是笼子里缺模块），
#           或者端口当前还是 LinkUp、前置条件没满足 —— 都不代表卡有问题
#
# 退出码：0 = 有 PASS 且无 FAIL      1 = 有 FAIL，或一个 PASS 都没有（全 Pending）
#         2 = 用法错误
#
# 不落盘：本脚本不生成任何日志文件，所有结果（含改前/改后计数器对比）都打印到屏幕。
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

# ---------- 参数 ----------
DO_LIST=0
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -l|--list) DO_LIST=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
        -*) err "未知参数 $1"; usage; exit 2 ;;
        *)  POS+=("$1"); shift ;;
    esac
done

if [ "${#POS[@]}" -gt 2 ]; then
    err "参数过多（最多 <CA名> [端口号]）"
    usage; exit 2
fi
CA_ARG="${POS[0]:-}"
PORT_ARG="${POS[1]:-}"
if [ -n "$PORT_ARG" ] && [ -z "$CA_ARG" ]; then
    err "给了端口号却没给 CA 名"
    usage; exit 2
fi

# ---------- 环境变量默认值 ----------
RUN_BW="${RUN_BW:-1}"
BW_DURATION="${BW_DURATION:-5}"
QP="${QP:-8}"
MTU_ARG="${MTU_ARG:--m 1024}"
LINK_UP_TIMEOUT="${LINK_UP_TIMEOUT:-20}"
IP_SELF="${IP_SELF:-192.168.211.1}"
SKIP_RESTORE="${SKIP_RESTORE:-0}"
PORTNUM="${PORTNUM:-18525}"
# sysfs 根目录，留出可覆盖的口子便于离线单测（真机不用改）
SYSIB="${SYSIB:-/sys/class/infiniband}"

if [ "$DO_LIST" != "1" ] && [ "$(id -u 2>/dev/null)" != "0" ]; then
    err "需要 root 权限（sudo bash $0）—— 配置环回要写设备"
    echo "  只想看状态：bash $0 --list"
    exit 1
fi

# ---------- 依赖 ----------
for c in mlxlink mst ibstat; do
    if ! command -v "$c" >/dev/null 2>&1; then
        if [ "$DO_LIST" = "1" ] && [ "$c" != "mlxlink" ]; then
            continue
        fi
        err "缺少命令：$c"
        case "$c" in
            mlxlink) info "MFT 不在 apt 源里，需从 NVIDIA 官网下载（约 89MB）："
                     info "  1) 依赖  sudo apt install -y gcc make dkms linux-headers-\$(uname -r)"
                     info "  2) 下载  wget https://www.mellanox.com/downloads/MFT/mft-4.36.0-147-x86_64-deb.tgz"
                     info "  3) 安装  tar zxf mft-4.36.0-147-x86_64-deb.tgz && cd mft-*/ && sudo ./install.sh"
                     info "  4) 启动  sudo mst start && sudo mst status"
                     info "  （版本号随发布更新，以官网为准；已装 MLNX_OFED 的一般自带 mst/mlxlink）" ;;
            mst)     info "mst 随 MFT 一起安装" ;;
            ibstat)  info "apt install infiniband-diags" ;;
        esac
        exit 1
    fi
done

HAVE_PERF=0
command -v ib_write_bw >/dev/null 2>&1 && HAVE_PERF=1
if [ "$RUN_BW" = "1" ] && [ "$HAVE_PERF" -eq 0 ] && [ "$DO_LIST" != "1" ]; then
    warn "ib_write_bw 未安装（apt install perftest），本次只验链路与计数器" >&2
    RUN_BW=0
fi

# ---------- 基础读取函数 ----------
# 用 $() 捕获输出的函数里，任何提示都必须走 stderr，否则会污染返回值
bdf_of_ca() {
    basename "$(readlink -f "$SYSIB/$1/device" 2>/dev/null)" 2>/dev/null
}

# 多卡机上 mst status | head -1 会读错卡（8 卡机有 9 个节点），必须按 PCI BDF 匹配
mdev_of_ca() {
    local ca="$1" bdf="${2:-}" dev
    [ -z "$bdf" ] && bdf=$(bdf_of_ca "$ca")
    [ -n "$bdf" ] || return 1

    dev=$(mst status -v 2>/dev/null | awk -v b="$bdf" '
        { bd = ""
          for (i = 1; i <= NF; i++)
              if ($i ~ /^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]$/) bd = $i
          if (bd == b) { print $NF; exit } }')
    [ -n "$dev" ] && { printf '%s\n' "$dev"; return 0; }

    dev=$(mst status 2>/dev/null | awk -v b="$bdf" '
        /^\/dev\/mst\// { cand = $1; next }
        cand != "" && index($0, b) > 0 { print cand; exit }')
    [ -n "$dev" ] || return 1
    printf '%s\n' "$dev"
}

# 多口卡按端口号精确取 netdev（head -1 永远只认端口 1）
netdev_of_port() {
    local ca="$SYSIB/$1" p="$2" nd name
    for nd in "$ca/ports/$p"/gid_attrs/ndevs/*; do
        [ -e "$nd" ] || continue
        name=$(head -1 "$nd" 2>/dev/null)
        [ -n "$name" ] && { printf '%s\n' "$name"; return 0; }
    done
    local -a nds=()
    mapfile -t nds < <(ls "$ca/device/net/" 2>/dev/null | sort)
    printf '%s' "${nds[$((p - 1))]:-${nds[0]:-}}"
}

# /sys 里的状态带数字前缀："5: LinkUp" / "4: ACTIVE"
sysf() { local v; v=$(cat "$1" 2>/dev/null); printf '%s' "${v##*: }"; }
phys_state()  { sysf "$SYSIB/$1/ports/$2/phys_state"; }
state_of_port() { sysf "$SYSIB/$1/ports/$2/state"; }

ports_of_ca() {
    ls -d "$SYSIB/$1"/ports/[0-9]* 2>/dev/null | xargs -r -n1 basename 2>/dev/null | sort -n
}

list_cas() {
    local ca
    for ca in $SYSIB/*; do
        [ -e "$ca" ] || continue
        basename "$ca"
    done
}

# Link layer：优先 ibstat（最可靠），mlxconfig 的 LINK_TYPE 只作交叉核对
link_layer_of_ca() {
    ibstat "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Link layer:[[:space:]]*//p' | head -1
}

# LINK_TYPE：1=IB  2=ETH（RoCE）。mlxconfig 各版本输出格式不同：
#   有冒号的  "LINK_TYPE            : 2"
#   无冒号的  "LINK_TYPE            Ethernet(2)    Ethernet(2)"
# 所以先剥标签，再取【第一个】字段，最后只留数字 —— 否则两列格式会被拼成 "22"。
read_link_type() {
    local dev="$1" v
    command -v mlxconfig >/dev/null 2>&1 || return 1
    v=$(mlxconfig -d "$dev" query 2>/dev/null \
        | sed -n 's/^[[:space:]]*LINK_TYPE[[:space:]]*:*[[:space:]]*//p' | head -1)
    [ -n "$v" ] || return 1
    v=$(printf '%s' "$v" | awk '{print $1}' | tr -cd '0-9')
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# mlxlink 没有专门的环回查询开关，只能从它的普通输出里捞；捞不到返回空
read_loopback() {
    mlxlink -d "$1" -p "$2" 2>/dev/null \
        | sed -n 's/^[[:space:]]*Loopback[^:]*:[[:space:]]*//p' | head -1
}

# 设环回。有些版本只认小写，先大写再小写各试一次。
# 返回 0 不代表端口一定起来了 —— 调用方必须以端口状态为准。
set_loopback() {
    local dev="$1" p="$2" mode="$3" out rc
    out=$(mlxlink -d "$dev" -p "$p" -l "$mode" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        out=$(mlxlink -d "$dev" -p "$p" -l "$(printf '%s' "$mode" | tr 'A-Z' 'a-z')" 2>&1); rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" >&2
        return 1
    fi
    return 0
}

# 找该端口的 RoCE v2 GID 索引
gid_index_of_port() {
    local gi
    for gi in "$SYSIB/$1/ports/$2"/gid_attrs/types/*; do
        [ -e "$gi" ] || continue
        case "$(cat "$gi" 2>/dev/null)" in
            *v2*) basename "$gi"; return 0 ;;
        esac
    done
    return 1
}

# ---------- 恢复环回（trap 保证）----------
RESTORE_LIST=()
cleanup() {
    local item dev p
    if [ "$SKIP_RESTORE" != "1" ] && [ "${#RESTORE_LIST[@]}" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}   收尾：把环回恢复成 NO${NC}"
        for item in "${RESTORE_LIST[@]}"; do
            dev="${item%%|*}"; p="${item##*|}"
            [ -n "$dev" ] && [ -n "$p" ] || continue
            if set_loopback "$dev" "$p" NO >/dev/null 2>&1; then
                echo -e "${CYAN}     port $p -> NO 已恢复${NC}"
            else
                echo -e "${YELLOW}     port $p 恢复失败，请手动跑：mlxlink -d $dev -p $p -l NO${NC}"
            fi
        done
    fi
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

# ---------- --list：不改设备配置（root 下会 mst start 以读 LINK_TYPE） ----------
if [ "$DO_LIST" = "1" ]; then
    echo -e "${BLUE}==================== RDMA 设备与端口 ====================${NC}"
    CAS=$(list_cas)
    if [ -z "$CAS" ]; then
        err "没有发现任何 RDMA 设备"
        info "检查：lsmod | grep mlx5 ； lspci | grep -i mellanox"
        exit 1
    fi
    MDEV_OK=0
    if command -v mst >/dev/null 2>&1; then
        mst start >/dev/null 2>&1 && MDEV_OK=1
    fi
    for ca in $CAS; do
        [ -n "$CA_ARG" ] && [ "$ca" != "$CA_ARG" ] && continue
        mdev=""
        [ "$MDEV_OK" = "1" ] && mdev=$(mdev_of_ca "$ca" || true)
        ll=""
        [ -n "$mdev" ] && ll=$(read_link_type "$mdev" || true)
        case "${ll:-}" in
            1) ll_txt="IB(1)" ;;
            2) ll_txt="ETH(2)" ;;
            *) ll_txt="未读到" ;;
        esac
        llayer=$(link_layer_of_ca "$ca")
        echo ""
        echo -e "${CYAN}$ca    PCI $(bdf_of_ca "$ca")    Link layer=${llayer:-未读到}    LINK_TYPE=$ll_txt${NC}"
        [ -z "$mdev" ] && echo "     （未按 BDF 匹配到 mst 节点，LINK_TYPE/环回读不到；手动核对 mst status -v）"
        for p in $(ports_of_ca "$ca"); do
            nd=$(netdev_of_port "$ca" "$p")
            ps=$(phys_state "$ca" "$p")
            st=$(state_of_port "$ca" "$p")
            lb=""
            [ -n "$mdev" ] && lb=$(read_loopback "$mdev" "$p")
            printf '     port %-2s  State=%-12s Physical=%-10s netdev=%-12s Loopback=%s\n' \
                "$p" "${st:-?}" "${ps:-?}" "${nd:-未取到}" "${lb:-未读到}"
        done
    done
    echo ""
    info "本模式只读，没有改动任何设备状态"
    exit 0
fi

# ---------- 选设备 ----------
if [ -z "$CA_ARG" ]; then
    mapfile -t CA_LIST < <(list_cas)
    if [ "${#CA_LIST[@]}" -eq 0 ]; then
        err "没有发现任何 RDMA 设备"
        info "检查：lsmod | grep mlx5 ； lspci | grep -i mellanox"
        exit 1
    fi
else
    if [ ! -d "$SYSIB/$CA_ARG" ]; then
        err "设备 '$CA_ARG' 不存在"
        echo "  现有设备：$(list_cas | tr '\n' ' ')"
        exit 1
    fi
    CA_LIST=("$CA_ARG")
fi

echo -e "${BLUE}==================== 芯片自环（mlxlink -l PH）====================${NC}"
echo "  被测设备    : ${CA_LIST[*]}"
echo "  自环模式    : PH（PHY 内部 Tx-to-Rx，不用线缆/对端）"
echo "  灌流量      : $([ "$RUN_BW" = "1" ] && echo "开（ib_write_bw ${BW_DURATION}s，QP=$QP）" || echo "关（只验链路与计数器）")"
echo "  落盘        : 无（不生成任何日志文件，结果全部打印到屏幕）"

if command -v mst >/dev/null 2>&1; then
    mst start >/dev/null 2>&1
fi

PASS_N=0; FAIL_N=0; PEND_N=0
SUMMARY=()

# 单个端口：0=PASS 1=FAIL 3=Pending
do_port() {
    local ca="$1" p="$2" ll="$3"
    local mdev nd ps st lb_before lb_after
    local i up=0 gid="" out rc bw="" srv=""
    local CNT_BEFORE="" CNT_AFTER="" FEC_OUT="" TX_OUT=""

    echo ""
    echo -e "${BLUE}==================== $ca  port $p ====================${NC}"

    mdev=$(mdev_of_ca "$ca" || true)
    if [ -z "$mdev" ]; then
        err "未按 PCI BDF 匹配到 $ca 的 mst 设备节点（BDF=$(bdf_of_ca "$ca")）"
        info "手动核对：mst status -v"
        return 1
    fi
    echo "  mst 节点      : $mdev"

    nd=$(netdev_of_port "$ca" "$p")
    ps=$(phys_state "$ca" "$p")
    st=$(state_of_port "$ca" "$p")
    echo "  netdev        : ${nd:-未取到}"
    echo "  State         : ${st:-?}"
    echo "  Physical state: ${ps:-?}"

    if [ "$ps" = "LinkUp" ]; then
        warn "端口当前是 LinkUp —— 配环回必须链路完全 down，本口这次没测"
        info "先拔掉这个口的线（或 ip link set ${nd:-<if>} down）再跑本脚本"
        info "这是【前置条件没满足】，不代表卡有问题，所以记 Pending 而不是 FAIL"
        return 3
    fi

    lb_before=$(read_loopback "$mdev" "$p")
    echo "  环回（改前）  : ${lb_before:-未读到（按 NO 处理）}"

    # 改前的物理计数器，用来做前后对比（不落盘，存在变量里）
    CNT_BEFORE=$(mlxlink -d "$mdev" -p "$p" -c 2>&1)

    echo ""
    echo -e "${CYAN}   设 PH 环回 ...${NC}"
    if ! set_loopback "$mdev" "$p" PH; then
        warn "直接设置失败，尝试先把 ${nd:-该口} 置 down 再设一次"
        [ -n "$nd" ] && ip link set "$nd" down 2>/dev/null
        sleep 1
        if ! set_loopback "$mdev" "$p" PH; then
            err "PH 环回设置失败（两次都失败）"
            info "把上面 mlxlink 的原始输出发我，或手动试：mlxlink -d $mdev -p $p -l PH"
            return 1
        fi
    fi
    RESTORE_LIST+=("$mdev|$p")
    ok "已设 PH 环回（测完会自动恢复成 NO）"

    echo -n "  等待端口起来（最多 ${LINK_UP_TIMEOUT}s）"
    for i in $(seq 1 "$LINK_UP_TIMEOUT"); do
        ps=$(phys_state "$ca" "$p")
        if [ "$ps" = "LinkUp" ]; then up=1; break; fi
        sleep 1
        echo -n "."
    done
    echo ""
    lb_after=$(read_loopback "$mdev" "$p")

    if [ "$up" -ne 1 ]; then
        warn "端口没起来（Physical state=${ps:-?}，环回=${lb_after:-未读到}）"
        info "最常见原因：OSFP 笼子里没有模块。插一个光模块（不用接线、不用装光纤）再跑一次。"
        info "插了模块仍不上，把这段发我：mlxlink -d $mdev -p $p"
        return 3
    fi
    ok "端口已起来（Physical state=LinkUp，环回=${lb_after:-?}）"

    # ---------- 灌流量 ----------
    if [ "$RUN_BW" = "1" ]; then
        echo ""
        if [ "$ll" = "InfiniBand" ]; then
            echo -e "${CYAN}==================== 灌流量 ====================${NC}"
            warn "Link layer 是 InfiniBand，本脚本的 ib_write_bw 自环只做了 RoCE 路径"
            info "IB 模式要跑流量得先配 IPoIB，这里跳过；链路与计数器已验"
        elif [ -z "$nd" ]; then
            warn "取不到 netdev，无法配 IP，跳过灌流量"
        else
            [ -z "$ll" ] && warn "读不到 Link layer（ibstat 没输出），按以太网(RoCE)路径试一次"
            echo -e "${BLUE}==================== 灌流量（ib_write_bw 同口自环）====================${NC}"
            gid=$(gid_index_of_port "$ca" "$p" || true)
            ip link set "$nd" up 2>/dev/null
            ip addr add "$IP_SELF/24" dev "$nd" 2>/dev/null
            if ! ip addr show "$nd" 2>/dev/null | grep -q -- "$IP_SELF"; then
                warn "给 $nd 配 $IP_SELF 失败，跳过灌流量"
            else
                echo "  $nd = $IP_SELF    GID 索引=${gid:-未识别}    ${MTU_ARG}  -q $QP  -D $BW_DURATION"
                for attempt in "with_gid" "no_gid"; do
                    [ "$attempt" = "with_gid" ] && [ -z "$gid" ] && continue
                    GARG=""
                    [ "$attempt" = "with_gid" ] && GARG="-g $gid"
                    ib_write_bw -d "$ca" -i "$p" -p "$PORTNUM" $MTU_ARG -q "$QP" $GARG \
                        --report_gbits > /dev/null 2>&1 &
                    srv=$!
                    sleep 3
                    out=$(timeout 60 ib_write_bw -d "$ca" -i "$p" -p "$PORTNUM" $MTU_ARG -q "$QP" \
                          $GARG --report_gbits -D "$BW_DURATION" "$IP_SELF" 2>&1)
                    rc=$?
                    kill "$srv" 2>/dev/null
                    wait "$srv" 2>/dev/null
                    if [ "$rc" -eq 0 ]; then
                        bw=$(printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ && NF>=4 {v=$4} END{if(v!="") print v}')
                        [ -n "$bw" ] && break
                    fi
                    [ "$attempt" = "with_gid" ] && [ -n "$gid" ] && warn "带 GID 失败，退回不带 GID 再试"
                done
                if [ -n "$bw" ]; then
                    ok "ib_write_bw 单向 $bw Gb/s（★ 自环数字，只作「通不通」的证据，不能当性能验收值）"
                    # 上面这个数字之所以是 Gb/s：命令里带了 --report_gbits。
                    # perftest 默认输出的是 MiB/sec（RESULT_FMT），1 Gb/s = 119.2 MiB/s，
                    # 少了这个开关就会把 47680(MiB/s) 读成 47680(Gb/s)，差 119 倍。
                    printf '%s\n' "$out" \
                        | grep -E 'BW (average|peak)|^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]' \
                        | head -3 | sed 's/^/     /'
                else
                    warn "ib_write_bw 未取到结果（同口自环的地址解析在部分版本上不稳）"
                    printf '%s\n' "$out" | tail -4 | sed 's/^/     /'
                    info "端口已 LinkUp 是硬证据；流量失败不判 FAIL，记为 Pending"
                fi
            fi
        fi
    fi

    # ---------- 物理计数器 / BER 前后对比 ----------
    echo ""
    echo -e "${BLUE}==================== 物理计数器 / BER ====================${NC}"
    CNT_AFTER=$(mlxlink -d "$mdev" -p "$p" -c 2>&1)
    if [ -n "$CNT_AFTER" ]; then
        printf '%s\n' "$CNT_AFTER" \
            | grep -iE 'error|err |BER|symbol|CRC|FEC|uncorrect|Rate|Speed' | head -20 | sed 's/^/     /'
        if [ -n "$CNT_BEFORE" ]; then
            if [ "$CNT_BEFORE" = "$CNT_AFTER" ]; then
                info "与改前相比：计数器完全一致，无新增误码"
            else
                echo -e "${CYAN}   与改前相比的变化（< 改前 / > 改后）：${NC}"
                diff <(printf '%s\n' "$CNT_BEFORE") <(printf '%s\n' "$CNT_AFTER") \
                    | head -20 | sed 's/^/     /'
            fi
        fi
    else
        info "mlxlink -c 无输出，跳过计数器展示"
    fi

    FEC_OUT=$(mlxlink -d "$mdev" -p "$p" --show_fec 2>&1)
    if [ -n "$FEC_OUT" ]; then
        echo -e "${CYAN}   FEC：${NC}"
        printf '%s\n' "$FEC_OUT" | head -10 | sed 's/^/     /'
    fi

    TX_OUT=$(mlxlink -d "$mdev" -p "$p" --show_serdes_tx 2>&1)
    if [ -n "$TX_OUT" ]; then
        echo -e "${CYAN}   SerDes TX：${NC}"
        printf '%s\n' "$TX_OUT" | head -12 | sed 's/^/     /'
    fi

    return 0
}

for ca in "${CA_LIST[@]}"; do
    ll0=$(link_layer_of_ca "$ca")

    if [ -n "$PORT_ARG" ]; then
        if [ ! -d "$SYSIB/$ca/ports/$PORT_ARG" ]; then
            err "$ca 没有 port $PORT_ARG"
            continue
        fi
        PORTS=("$PORT_ARG")
    else
        mapfile -t PORTS < <(ports_of_ca "$ca")
    fi

    if [ "${#PORTS[@]}" -eq 0 ]; then
        warn "$ca 下没有发现端口"
        continue
    fi

    for p in "${PORTS[@]}"; do
        do_port "$ca" "$p" "$ll0"
        rc=$?
        case "$rc" in
            0) PASS_N=$((PASS_N + 1));   SUMMARY+=("PASS     $ca port $p") ;;
            3) PEND_N=$((PEND_N + 1));   SUMMARY+=("Pending  $ca port $p") ;;
            *) FAIL_N=$((FAIL_N + 1));   SUMMARY+=("FAIL     $ca port $p") ;;
        esac
    done
done

# ---------- 汇总 ----------
echo ""
echo -e "${BLUE}==================== 汇总 ====================${NC}"
for line in "${SUMMARY[@]}"; do
    case "$line" in
        PASS*)   echo -e "  ${GREEN}$line${NC}" ;;
        Pending*) echo -e "  ${YELLOW}$line${NC}" ;;
        *)       echo -e "  ${RED}$line${NC}" ;;
    esac
done
echo ""
echo "  PASS=$PASS_N   FAIL=$FAIL_N   Pending=$PEND_N"
echo ""
info "判定口径：PASS = 端口在 PH 自环下 LinkUp；FAIL = 设环回就失败；Pending = 前置条件没满足，或环回设上但端口没起"
info "★ 自环只覆盖第 1 段（芯片 SerDes/TX/RX），证明不了 PCB 后端、笼子、模块、光纤、对端"
info "★ 自环带宽数字不能当性能验收值"

if [ "$FAIL_N" -gt 0 ] || [ "$PASS_N" -eq 0 ]; then
    if [ "$FAIL_N" -eq 0 ]; then
        info "没有任何端口 PASS（全是 Pending）—— 本次没验出结果，按 1 报"
    fi
    exit 1
fi
exit 0
