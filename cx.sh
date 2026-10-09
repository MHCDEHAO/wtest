#!/bin/bash
# =============================================================================
# NVIDIA / Mellanox 网卡验收脚本（多型号兼容 + 配置单符合性核对，只读检查）
#
# 本脚本是「旧 cx.sh（单一 CX-7 配置单验收）」与「cx_multi.sh（多型号自动发现）」
# 的合并版，一个脚本覆盖两种用法：
#
#   1) 配置单验收（默认）：按 EXPECT_* 核对数量 / 部件号 / 速率 / PCIe，不符即判不合格
#   2) 纯普查（CX_SCAN_ONLY=1 或清空 EXPECT_*）：不比对配置单，只列配置并逐卡判定
#
# 兼容策略（关键）：
#   内置「部件号 → 预期规格」对照表。表内型号做完整判定；表外型号不会误判，
#   自动降级为「只列配置 + 提示可扩展」，PCIe 预期仍按代次推导。
#   新增型号只需往 SPEC_TABLE 加一行。
#
# 预期值的来源与优先级（每判定项都会在输出里标注实际用了哪一路）：
#   PCIe 速率/宽度：LnkCap（设备自报能力，lspci -vv 读，通用于所有型号）
#                 > 规格表 > 代次默认 > 不判定
#   端口总带宽   ：mlxlink 的 Enabled Link Speed（设备自报）× 端口数
#                 > 规格表 > 不判定
#   注意：端口速率**不能**从 lspci 读 —— PCIe 配置空间里没有网络端口规格，
#   且同一 Device ID（如 15b3:1021）覆盖 400G/200G/100G 多种型号，推不出来。
#
# 身份信息（部件号/序列号）不依赖 MFT：
#   mlxconfig 的 Name/Device type > lspci -vvv 的 VPD [PN]/[SN] > PCI 描述关键字
#   VPD 只有 -vvv 才输出（-vv 看不到），它是没装 MFT 时唯一的部件号来源。
#
# 用法：
#   sudo bash cx.sh                      # 按默认配置单验收
#   EXPECT_CARDS=4 EXPECT_PN=MCX75310AAS-NEAT sudo bash cx.sh   # 换订单
#   CX_SCAN_ONLY=1 sudo bash cx.sh       # 纯普查，不比对配置单
#   EXPECT_LINK_LAYER=IB sudo bash cx.sh # 预期链路层为 IB（默认 ETH，即 RoCEv2）
#
# 返回码（与全局约定一致）：
#   0 = PASS     所有检查项均判定通过（可能附若干 WARN，需人工留意）
#   1 = FAIL / Pending
#                FAIL    —— 存在明确不合格项
#                Pending —— 有检查项因「信息缺失」或「未接线」而无法判定，
#                           不算通过，补装工具 / 接好线之后必须复测
# =============================================================================

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------- 配置单预期值（环境变量可覆盖；CX_SCAN_ONLY=1 时全部忽略）----------
EXPECT_CARDS=${EXPECT_CARDS:-8}                 # 预期网卡数量
EXPECT_PN=${EXPECT_PN:-MCX75310AAS-NEAT}       # 预期部件号
EXPECT_RATE=${EXPECT_RATE:-0}                   # 预期单口速率(Gb/s)，0=由设备能力推导
EXPECT_LINK_LAYER=${EXPECT_LINK_LAYER:-ETH}    # 预期链路层：ETH(RoCEv2) / IB / 空=只记录不判定
EXPECT_PCIE_SPEED=${EXPECT_PCIE_SPEED:-0}      # 预期 PCIe 速率(GT/s)，0=取 LnkCap
EXPECT_PCIE_WIDTH=${EXPECT_PCIE_WIDTH:-0}      # 预期 PCIe 宽度，0=取 LnkCap
CX_SCAN_ONLY=${CX_SCAN_ONLY:-0}                # 1=纯普查，不做配置单比对
if [ "$CX_SCAN_ONLY" = "1" ]; then
    EXPECT_CARDS=0; EXPECT_PN=""; EXPECT_RATE=0
    EXPECT_PCIE_SPEED=0; EXPECT_PCIE_WIDTH=0
    EXPECT_LINK_LAYER=""            # 纯普查：Link layer 只打印不判定
fi

ERRORS=0
WARNINGS=0
PENDING=0       # 因「信息缺失 / 未接线」而无法判定的项数 —— 三态的第三态，最终 exit 1

ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; WARNINGS=$((WARNINGS + 1)); }
err()     { echo -e "${RED}❌ $1${NC}";  ERRORS=$((ERRORS + 1)); }
pending() { echo -e "${YELLOW}⏳ $1${NC}"; PENDING=$((PENDING + 1)); }

gv() { printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -n 1; }

# ---------- 部件号 → 预期规格表 ----------
# 格式：PN前7位 | 代次 | 预期总带宽(Gb/s) | 预期PCIe速度(GT/s) | 预期PCIe宽度
# 预期总带宽 = 各端口速率之和（例：CX-6 双口各 100G → 200）
# 未收录的型号请按实际规格往这里加一行
SPEC_TABLE="MCX7531|ConnectX7|400|32|16
MCX7551|ConnectX7|400|32|16
MCX6531|ConnectX6|200|16|16
MCX6231|ConnectX6|200|16|16"

lookup_spec() {
    local pn="$1" key p dt bw sp wd
    key=$(printf '%s' "$pn" | tr '[:lower:]' '[:upper:]' | cut -c1-7)
    [ -z "$key" ] && return 1
    while IFS='|' read -r p dt bw sp wd; do
        [ -z "$p" ] && continue
        if [ "$key" = "$p" ]; then printf '%s|%s|%s|%s\n' "$dt" "$bw" "$sp" "$wd"; return 0; fi
    done <<< "$SPEC_TABLE"
    return 1
}

# ---------- 代次 → 默认 PCIe 预期（部件号未收录时用）----------
gen_pcie() {
    case "$1" in
        ConnectX7|ConnectX8|ConnectX-7|ConnectX-8) printf '32|16\n' ;;
        ConnectX6*|ConnectX-6*)                    printf '16|16\n' ;;
        ConnectX5*|ConnectX-5*)                    printf '16|16\n' ;;
        ConnectX4*|ConnectX-4*)                    printf '8|16\n' ;;
        *)                                         printf '0|0\n' ;;
    esac
}

# ---------- 代次名归一化 ----------
# 同一张卡可能从不同来源拿到 "ConnectX7"(mlxconfig) / "ConnectX-7"(PCI 描述) /
# "ConnectX 7"，不归一化的话汇总会按名字分成两组统计。统一成无分隔符形式。
norm_gen() {
    printf '%s' "${1:-}" | sed 's/[[:space:]]*-\?[[:space:]]*\([0-9]\)/\1/; s/[[:space:]]//g'
}

# ---------- 部件号 → 代次（VPD 读到 PN 但规格表未收录时用）----------
pn_to_gen() {
    case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
        MCX7*)  printf 'ConnectX7\n' ;;
        MCX6*)  printf 'ConnectX6\n' ;;
        MCX5*)  printf 'ConnectX5\n' ;;
        MCX4*)  printf 'ConnectX4\n' ;;
        B3*|BF3*|BLUEFIELD3*) printf 'BlueField3\n' ;;
        *)      printf '' ;;
    esac
}

# ---------- 解析 ibstat：CA|Port|State|Physical|Rate|LinkLayer ----------
parse_ibstat() {
    ibstat 2>/dev/null | awk '
        function flush() {
            if (ca != "" && port != "")
                printf "%s|%s|%s|%s|%s|%s\n", ca, port, (st==""?"-":st), (ph==""?"-":ph), (rt==""?"-":rt), (ll==""?"-":ll)
        }
        /^CA / { flush(); ca=$0; sub(/^CA /, "", ca); gsub(/\047/, "", ca); port=""; st=""; ph=""; rt=""; ll=""; next }
        /^[[:space:]]*Port [0-9]+:/ { flush(); port=$1" "$2; sub(/:$/, "", port); st=""; ph=""; rt=""; ll=""; next }
        /^[[:space:]]*State:/          { st=$0; sub(/^[[:space:]]*State:[[:space:]]*/, "", st); next }
        /^[[:space:]]*Physical state:/ { ph=$0; sub(/^[[:space:]]*Physical state:[[:space:]]*/, "", ph); next }
        /^[[:space:]]*Rate:/           { rt=$0; sub(/^[[:space:]]*Rate:[[:space:]]*/, "", rt); next }
        /^[[:space:]]*Link layer:/     { ll=$0; sub(/^[[:space:]]*Link layer:[[:space:]]*/, "", ll); next }
        END { flush() }
    '
}

# ---------- 权限 ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "$0")"
if [ "$(id -u)" -ne 0 ]; then
    if [ -n "$CX_ELEVATED" ]; then
        :
    elif command -v sudo >/dev/null 2>&1; then
        echo "当前非 root，正在通过 sudo 提权后重新执行本脚本..."
        sudo env CX_ELEVATED=1 bash "$SELF" "$@"; exit $?
    else
        echo -e "${YELLOW}警告：非 root 且无 sudo，lspci -vv / mst / mstflint 可能读不到完整信息。${NC}"
    fi
fi

# ---------- 依赖自动安装 ----------
# 能 apt/dnf/yum 装上的都自动装；MFT 系列（mst/mlxconfig/mlxlink）装不到，只提示。
# 装失败按「该工具是否影响主判定」分级：lspci 缺失无法清点网卡 → FAIL，其余 → WARN
install_deps() {
    echo -e "${BLUE}==================== 依赖检查与自动安装 ====================${NC}"
    local NEED="lspci ibstat ibv_devinfo mstflint"
    local MISSING=""
    local c
    for c in $NEED; do command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"; done

    if [ -z "$MISSING" ]; then
        echo -e "${GREEN}✅ 必要工具均已安装（lspci / ibstat / ibv_devinfo / mstflint）。${NC}"
    else
        echo -e "${YELLOW}缺失命令：$MISSING，尝试自动安装...${NC}"
        local INSTALL_CMD="" PKG_LIST=""
        if command -v apt >/dev/null 2>&1; then
            INSTALL_CMD="apt install -y"; PKG_LIST="pciutils infiniband-diags ibverbs-utils mstflint"
        elif command -v dnf >/dev/null 2>&1; then
            INSTALL_CMD="dnf install -y"; PKG_LIST="pciutils infiniband-diags libibverbs-utils mstflint"
            rpm -q epel-release >/dev/null 2>&1 || dnf install -y epel-release >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            INSTALL_CMD="yum install -y"; PKG_LIST="pciutils infiniband-diags libibverbs-utils mstflint"
            rpm -q epel-release >/dev/null 2>&1 || yum install -y epel-release >/dev/null 2>&1
        fi

        if [ -z "$INSTALL_CMD" ]; then
            warn "未识别到 apt/dnf/yum，无法自动安装：$MISSING（请手动安装）"
        else
            local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
            $SUDO $INSTALL_CMD $PKG_LIST >/dev/null 2>&1
            local STILL=""
            for c in $NEED; do command -v "$c" >/dev/null 2>&1 || STILL="$STILL $c"; done
            if [ -n "$STILL" ]; then
                warn "以下工具仍缺失：$STILL（手动安装包：$PKG_LIST）"
            else
                echo -e "${GREEN}✅ 依赖安装完成。${NC}"
            fi
        fi
    fi

    # MFT 系列：不在任何发行版源里，只能提示
    local MFT_MISS=""
    for c in mst mlxconfig mlxlink; do
        command -v "$c" >/dev/null 2>&1 || MFT_MISS="$MFT_MISS $c"
    done
    if [ -n "$MFT_MISS" ]; then
        warn "MFT 工具不可用：$MFT_MISS（属 MFT/MLNX_OFED，发行版源里没有，需单独下载安装）。"
        echo -e "${CYAN}      缺失期间脚本会自动降级：部件号走 lspci -vvv 的 VPD，固件走 ibstat，端口能力走规格表。${NC}"
    fi
    if command -v mst >/dev/null 2>&1; then
        mst start >/dev/null 2>&1 || warn "mst start 失败，固件层字段可能读不到"
    fi
    echo ""
}
install_deps

# ---------- 工具与驱动 ----------
echo -e "${BLUE}==================== 工具与驱动环境 ====================${NC}"
MISSING=""
for c in lspci ibv_devinfo ibstat mstflint; do
    command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
[ -n "$MISSING" ] && warn "缺少工具：$MISSING （相关字段读不到）"
if command -v ofed_info >/dev/null 2>&1; then
    OFED=$(ofed_info -s 2>/dev/null)
    [ -n "$OFED" ] && echo -e "${CYAN}  MLNX_OFED：$OFED${NC}"
else
    V=$(modinfo mlx5_core 2>/dev/null | awk -F: '/^version:/{gsub(/^[[:space:]]+/,"",$2); print $2}')
    [ -n "$V" ] && echo -e "${CYAN}  未装 MLNX_OFED，mlx5_core 模块版本：$V${NC}"
fi
# mlx5 未加载等于驱动层不可用，端口/固件都读不到，按不合格处理
if ! lsmod 2>/dev/null | grep -qE '^mlx5'; then
    err "mlx5 模块未加载，网卡驱动未生效（先装 MLNX_OFED 或加载 inbox mlx5_core）"
fi

# ---------- 网卡自动发现 ----------
echo -e "\n${BLUE}==================== 网卡自动发现 ====================${NC}"
BDFS=()
if ! command -v lspci >/dev/null 2>&1; then
    err "lspci 不可用，无法发现网卡"; exit 1
fi
while IFS= read -r line; do
    [ -z "$line" ] && continue
    BDFS+=("$(printf '%s' "$line" | awk '{print $1}')")
done < <(lspci -Dnn 2>/dev/null | grep -i '15b3:')
CARD_N=${#BDFS[@]}
echo "发现 $CARD_N 张 Mellanox/NVIDIA 网卡"
if [ "$CARD_N" -eq 0 ]; then
    err "未发现任何 Mellanox/NVIDIA 网卡（15b3:），请检查硬件或驱动"
    exit 1
fi

# MST 设备列表
DEVICES=()
while IFS= read -r d; do [ -n "$d" ] && DEVICES+=("$d"); done < <(mst status 2>/dev/null | grep -oE '/dev/mst/[^[:space:]]*' | awk '!seen[$0]++')
CFG_TOOL=""
for t in mlxconfig mstconfig; do command -v "$t" >/dev/null 2>&1 && { CFG_TOOL="$t"; break; }; done
[ -z "$CFG_TOOL" ] && warn "缺少 mlxconfig/mstconfig，部件号(型号PN)可能读不到"

# BDF ↔ mlx5 设备名 映射（sysfs）
declare -A BDF2CA 2>/dev/null || true
for ca in /sys/class/infiniband/*; do
    [ -e "$ca" ] || continue
    name=$(basename "$ca")
    bdf=$(readlink -f "$ca/device" 2>/dev/null | awk -F'/' '{print $NF}')
    [ -n "$bdf" ] && BDF2CA["$bdf"]="$name"
done

# BDF ↔ MST 设备：优先 mst status -v 里的 PCI 地址，失败则按出现顺序粗匹配
declare -A BDF2MST 2>/dev/null || true
MSTV=$(mst status -v 2>/dev/null)
if [ -n "$MSTV" ]; then
    while IFS= read -r l; do
        dev=$(printf '%s' "$l" | grep -oE '/dev/mst/[^[:space:]]*' | head -1)
        bdf=$(printf '%s' "$l" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | head -1)
        [ -n "$dev" ] && [ -n "$bdf" ] && BDF2MST["$bdf"]="$dev"
    done <<< "$MSTV"
fi

# MST 设备 ↔ RDMA 设备名（sysfs 不可用时的备用关联）：
# ibstat 的 "CA type: MT4129" 与 mst 设备名 /dev/mst/mt4129_pciconf0 同源，
# 可借此把 CA 名挂到 mst 设备上，再由 BDF2MST 反查到 PCI 地址。
declare -A MST2CA 2>/dev/null || true
if [ ${#DEVICES[@]} -gt 0 ]; then
    while IFS='|' read -r ca ct; do
        if [ -z "$ca" ] || [ -z "$ct" ]; then continue; fi
        key=$(printf '%s' "$ct" | tr '[:upper:]' '[:lower:]')
        for d in "${DEVICES[@]}"; do
            # 同型号多张卡时设备名前缀相同，必须跳过已占用的那个，
            # 否则每张卡都会命中第一个设备，第 2 张起全部关联不上。
            [ -n "${MST2CA[$d]:-}" ] && continue
            case "$(basename "$d")" in
                *"$key"*) MST2CA["$d"]="$ca"; break ;;
            esac
        done
    done < <(ibstat 2>/dev/null | awk '
        /^CA / { ca=$0; sub(/^CA /, "", ca); gsub(/\047/, "", ca); next }
        /CA type:/ { ct=$0; sub(/^.*CA type:[[:space:]]*/, "", ct); if (ca != "") printf "%s|%s\n", ca, ct }
    ')
fi

# ---------- 逐卡判定 ----------
echo -e "\n${BLUE}==================== 逐卡判定 ====================${NC}"
declare -A GEN_TOTAL GEN_OK GEN_PEND 2>/dev/null || true

idx=0; UNPLUGGED=0
FW_LIST=(); PSID_LIST=(); PN_LIST=()
for bdf in "${BDFS[@]}"; do
    idx=$((idx + 1))
    DESC=$(lspci -Dnn -s "$bdf" 2>/dev/null | sed 's/.*\]://; s/^[[:space:]]*//')

    # MST 设备：先查映射，再按顺序粗匹配
    dev="${BDF2MST[$bdf]:-}"
    if [ -z "$dev" ] && [ ${#DEVICES[@]} -gt 0 ]; then
        dev="${DEVICES[$((idx-1))]:-}"
    fi

    DEVTYPE=""; PN=""; PSID=""; FW=""; FW_SRC=""; SN=""
    if [ -n "$dev" ] && command -v mstflint >/dev/null 2>&1; then
        Q=$(mstflint -d "$dev" q 2>/dev/null)
        PSID=$(gv "$Q" "PSID"); FW=$(gv "$Q" "FW Version"); SN=$(gv "$Q" "Device Serial Number")
        [ -n "$FW" ] && FW_SRC="mstflint"
        if [ -n "$CFG_TOOL" ]; then
            MCFG=$($CFG_TOOL -d "$dev" query 2>/dev/null)
            DEVTYPE=$(gv "$MCFG" "Device type"); PN=$(gv "$MCFG" "Name")
        fi
    fi
    # lspci -vvv 一次取三样东西（注意：VPD 只有 -vvv 才输出，-vv 看不到）：
    #   [PN]/[SN] = VPD 里的部件号与序列号（免 MFT）
    #   LnkCap    = 设备自报 PCIe 能力 → 当预期
    #   LnkSta    = 当前协商状态       → 当实测
    LSPCI_VVV=$(lspci -vvv -s "$bdf" 2>/dev/null)
    VPD_PN=$(printf '%s\n' "$LSPCI_VVV" | sed -n 's/^[[:space:]]*\[PN\][^:]*:[[:space:]]*//p' | head -n1)
    VPD_SN=$(printf '%s\n' "$LSPCI_VVV" | sed -n 's/^[[:space:]]*\[SN\][^:]*:[[:space:]]*//p' | head -n1)
    # 型号来源优先级：mlxconfig Device type > 部件号推导 > 规格表 > PCI 描述关键字
    [ -z "$PN" ] && [ -n "$VPD_PN" ] && PN="$VPD_PN"
    [ -z "$SN" ] && [ -n "$VPD_SN" ] && SN="$VPD_SN"
    [ -z "$DEVTYPE" ] && [ -n "$PN" ] && DEVTYPE=$(pn_to_gen "$PN")

    # 预期规格
    if SPEC=$(lookup_spec "$PN"); then
        EXP_DT=$(printf '%s' "$SPEC" | cut -d'|' -f1)
        [ -z "$DEVTYPE" ] && DEVTYPE="$EXP_DT"
        EXP_BW=$(printf '%s' "$SPEC" | cut -d'|' -f2)
        EXP_SP=$(printf '%s' "$SPEC" | cut -d'|' -f3)
        EXP_WD=$(printf '%s' "$SPEC" | cut -d'|' -f4)
        KNOWN=1
    else
        EXP_DT="${DEVTYPE:-未知}"
        EXP_BW=0
        DPC=$(gen_pcie "$DEVTYPE")
        EXP_SP=$(printf '%s' "$DPC" | cut -d'|' -f1)
        EXP_WD=$(printf '%s' "$DPC" | cut -d'|' -f2)
        KNOWN=0
    fi

    # 最后兜底：PCI 描述里的代次关键字。随后统一归一化，
    # 否则同一张卡可能一处叫 ConnectX7 一处叫 ConnectX-7，汇总会被拆成两组。
    [ -z "$DEVTYPE" ] && DEVTYPE=$(printf '%s' "$DESC" | grep -oiE 'ConnectX-?[0-9]+|BlueField-?[0-9]+' | head -1)
    DEVTYPE=$(norm_gen "$DEVTYPE")

    # RDMA 设备名：优先 sysfs 反查，拿不到时走 mst 设备名 → CA 的备用关联
    CA="${BDF2CA[$bdf]:-}"
    [ -z "$CA" ] && [ -n "$dev" ] && CA="${MST2CA[$dev]:-}"

    # 端口速率预期：lspci 读不到（PCIe 配置空间没有网络端口规格，且同一 Device ID
    # 可能对应不同速率型号），优先用 mlxlink 读设备自报的 Enabled Link Speed，
    # 乘以端口数得到预期总带宽；mlxlink 不可用时才退回规格表。
    PORT_CNT=0; CAP_RATE=0; BW_SRC=""
    if [ -n "$CA" ]; then
        PORT_CNT=$(parse_ibstat | awk -F'|' -v c="$CA" '$1==c && $2!=""' | wc -l | tr -d ' ')
    fi
    if command -v mlxlink >/dev/null 2>&1 && [ -n "$dev" ]; then
        CAP_RATE=$(mlxlink -d "$dev" -p 1 2>/dev/null \
                   | grep -i 'Enabled Link Speed' \
                   | sed -n 's/.*(\([^)]*\)).*/\1/p' | cut -d',' -f1 | tr -cd '0-9')
    fi
    # 预期优先级：配置单单口速率×端口数 > mlxlink 设备能力×端口数 > 规格表
    if [ "${EXPECT_RATE:-0}" -gt 0 ] && [ "$PORT_CNT" -gt 0 ]; then
        EXP_BW=$((EXPECT_RATE * PORT_CNT))
        BW_SRC="配置单(${EXPECT_RATE}G×${PORT_CNT}口)"
    elif [ -n "$CAP_RATE" ] && [ "$CAP_RATE" -gt 0 ] && [ "$PORT_CNT" -gt 0 ]; then
        EXP_BW=$((CAP_RATE * PORT_CNT))
        BW_SRC="mlxlink设备能力(${CAP_RATE}G×${PORT_CNT}口)"
    elif [ "$KNOWN" -eq 1 ]; then
        BW_SRC="规格表"
    fi

    # PCIe：先取设备自报能力 LnkCap（当预期）与当前协商状态 LnkSta（当实测）。
    # LnkCap 通用于所有型号，比查规格表可靠，故优先级最高。
    LNKSTA=$(printf '%s\n' "$LSPCI_VVV" | grep -m 1 'LnkSta:')
    LNKCAP=$(printf '%s\n' "$LSPCI_VVV" | grep -m 1 'LnkCap:')
    STA_SP=$(printf '%s' "$LNKSTA" | sed -n 's/.*Speed \([0-9.]*\)GT\/s.*/\1/p')
    STA_WD=$(printf '%s' "$LNKSTA" | sed -n 's/.*Width x\([0-9]*\).*/\1/p')
    DG=$(printf '%s' "$LNKSTA" | grep -c 'downgraded')
    CAP_SP=$(printf '%s' "$LNKCAP" | sed -n 's/.*Speed \([0-9.]*\)GT\/s.*/\1/p')
    CAP_WD=$(printf '%s' "$LNKCAP" | sed -n 's/.*Width x\([0-9]*\).*/\1/p')
    # 预期优先级：配置单 EXPECT_* > LnkCap 设备能力 > 规格表 > 代次默认
    if [ "${EXPECT_PCIE_SPEED:-0}" -gt 0 ] && [ "${EXPECT_PCIE_WIDTH:-0}" -gt 0 ]; then
        EXP_SP="$EXPECT_PCIE_SPEED"; EXP_WD="$EXPECT_PCIE_WIDTH"; PCIE_SRC="配置单"
    elif [ -n "$CAP_SP" ] && [ -n "$CAP_WD" ]; then
        EXP_SP="$CAP_SP"; EXP_WD="$CAP_WD"; PCIE_SRC="LnkCap设备能力"
    elif [ "${EXP_SP:-0}" -gt 0 ]; then
        PCIE_SRC="规格表"
    else
        PCIE_SRC="代次默认"
    fi

    EXP_TXT=""
    [ "${EXP_BW:-0}" -gt 0 ] && EXP_TXT="预期 ${EXP_BW}Gb/s, "
    [ "${EXP_SP:-0}" -gt 0 ] && EXP_TXT="${EXP_TXT}PCIe ${EXP_SP}GT/s x${EXP_WD}"
    echo -e "${CYAN}$bdf → ${DEVTYPE:-未知型号} (${EXP_TXT:-规格未收录})${NC}"
    [ -n "$DESC" ] && echo -e "${CYAN}    $DESC${NC}"

    CARD_ERR=0      # 本卡有明确不合格项
    CARD_PEND=0     # 本卡有项因信息缺失 / 未接线而未判定（不算通过，也不算不合格）

    # --- 判定1：PCIe 链路（LnkSta 实测 vs 上面定好的预期）---
    if [ -z "$STA_SP" ] || [ -z "$STA_WD" ]; then
        pending "$bdf 读不到 LnkSta（可能非 root 或设备异常），PCIe 判定待定"; CARD_PEND=1
    elif [ "${EXP_SP:-0}" -eq 0 ]; then
        echo -e "${CYAN}    PCIe：x${STA_WD} @ ${STA_SP}GT/s（无预期值，不判定）${NC}"
    elif awk -v s="$STA_SP" -v w="$STA_WD" -v es="$EXP_SP" -v ew="$EXP_WD" \
         'BEGIN{exit !(s+0>=es+0 && w+0>=ew+0)}'; then
        if [ "$DG" -gt 0 ]; then
            err "$bdf PCIe 已降级（当前 x${STA_WD} @ ${STA_SP}GT/s，标记 downgraded，预期 x${EXP_WD} @ ${EXP_SP}GT/s）"; CARD_ERR=1
        else
            ok "$bdf PCIe 正常（x${STA_WD} @ ${STA_SP}GT/s，预期 x${EXP_WD} @ ${EXP_SP}GT/s，来源 ${PCIE_SRC}）"
        fi
    else
        err "$bdf PCIe 未达预期（当前 x${STA_WD} @ ${STA_SP}GT/s，预期 x${EXP_WD} @ ${EXP_SP}GT/s，来源 ${PCIE_SRC}）"; CARD_ERR=1
    fi

    # --- 判定2：端口速率与状态 ---
    if [ -z "$CA" ]; then
        pending "$bdf 未找到对应的 RDMA 设备名（mlx5_x），端口检查未做"; CARD_PEND=1
    else
        P_TOT=0; P_UP=0; BW_SUM=0; P_DOWN=""; P_PH=""; RATE_BAD=""; POLLING_BAD=""
        P_LL=""; LL_ODD=""
        while IFS='|' read -r ca portp st ph rt ll; do
            [ "$ca" != "$CA" ] && continue
            [ -z "$portp" ] && continue
            P_TOT=$((P_TOT + 1))
            [ -z "$P_PH" ] && P_PH="$ph"
            # Link layer（parse_ibstat 输出的第 6 列，此前解析了但全文未引用）
            if [ -n "$ll" ] && [ "$ll" != "-" ]; then
                [ -z "$P_LL" ] && P_LL="$ll"
                printf '%s' "$ll" | grep -qi 'ethernet' || LL_ODD="$LL_ODD $portp($ll)"
            fi
            case "$st" in
                Active)
                    P_UP=$((P_UP + 1))
                    if printf '%s' "$rt" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
                        BW_SUM=$(awk -v a="$BW_SUM" -v b="$rt" 'BEGIN{printf "%.0f", a+b}')
                        # 逐口检查：只看合计会漏掉「一口正常、另一口降速」——
                        # 那种情况合计仍可能达标，但降速的口是实打实的故障。
                        if [ "${EXPECT_RATE:-0}" -gt 0 ] &&
                           ! awk -v v="$rt" -v e="$EXPECT_RATE" 'BEGIN{exit !(v+0>=e+0)}'; then
                            RATE_BAD="$RATE_BAD $portp(${rt}Gb/s)"
                        fi
                    fi ;;
                *) P_DOWN="$P_DOWN $portp($st)"
                   # 《基础测试》5.3：「物理链路状态不得为 Polling」列为 WARN。
                   # 全部端口都 Polling 属未接线（上面已中性处理），这里记的是混在 Up 里的 Polling
                   [ "$ph" = "Polling" ] && POLLING_BAD="$POLLING_BAD $portp" ;;
            esac
        done <<< "$(parse_ibstat)"

        # 未接线识别：全部端口都 Down，且物理层是 Polling / LinkDown / Disabled
        # → 是「没插线或对端没起」，不是硬件故障。只给中性提示，不计警告也不计错误，
        #   否则裸机预检（不接线）阶段每张卡都会飘红。
        UNPLUG=0
        if [ "$P_TOT" -gt 0 ] && [ "$P_UP" -eq 0 ]; then
            case "$P_PH" in
                Polling|LinkDown|Disabled) UNPLUG=1 ;;
            esac
        fi

        if [ "$UNPLUG" -eq 1 ]; then
            # ★ 未接线 = 这项没做，不是通过。计入 PENDING，否则「8 张卡全不插线」
            #   会得到 ERRORS=0 / WARNINGS=0，最终打出「所有网卡检查通过」。
            UNPLUGGED=$((UNPLUGGED + 1)); CARD_PEND=1
            pending "未接线：${P_TOT} 个端口均 Down（Physical state=${P_PH}），端口速率未判定，接线后复测"
            [ "${CAP_RATE:-0}" -gt 0 ] && echo -e "${CYAN}    设备端口能力：${CAP_RATE}Gb/s（来源 mlxlink，不依赖链路）${NC}"
        else
            PORT_TXT="端口速率合计 ${BW_SUM}Gb/s（${P_UP}/${P_TOT} 个端口 Active"
            [ "$P_TOT" -gt 1 ] && PORT_TXT="$PORT_TXT，每口约 $(awk -v a="$BW_SUM" -v b="$P_UP" 'BEGIN{if(b>0) printf "%.0f", a/b; else print 0}')Gb/s）" || PORT_TXT="$PORT_TXT）"

            if [ "${EXP_BW:-0}" -gt 0 ]; then
                BW_NOTE="${BW_SRC:-规格表}"
                if awk -v a="$BW_SUM" -v b="$EXP_BW" 'BEGIN{exit !(a+0>=b+0)}'; then
                    ok "$PORT_TXT，达到预期 ${EXP_BW}Gb/s（来源 ${BW_NOTE}）"
                elif [ -n "$P_DOWN" ]; then
                    # 有端口没 Up：带宽不足可能是没接线造成的，不算硬件降速，只警告
                    warn "$PORT_TXT，低于预期 ${EXP_BW}Gb/s（来源 ${BW_NOTE}，但存在未 Up 端口，先接线再复测）"
                else
                    err "$PORT_TXT，低于预期 ${EXP_BW}Gb/s（来源 ${BW_NOTE}，端口全 Up 仍不足，疑似链路降速）"; CARD_ERR=1
                fi
            else
                echo -e "${CYAN}    $PORT_TXT（无预期值，不判定速率）${NC}"
            fi
            # 《基础测试》5.3：「链路状态 State 不得为 Down」列为 FAIL。
            # 只有「全部端口都 Down 且物理层 Polling/LinkDown」才判未接线，那种情况
            # 已在上面单独处理成中性提示；能走到这里说明有口是 Up 的，
            # 此时还有口 Down 属于真故障（掉了线、口坏了、对端没起）。
            [ -n "$P_DOWN" ] && { err "$bdf 以下端口 State 非 Active：$P_DOWN"; CARD_ERR=1; }
            [ -n "$POLLING_BAD" ] && warn "$bdf 以下端口 Physical state 为 Polling（对端未起）：$POLLING_BAD"
            [ -n "$RATE_BAD" ] && { err "$bdf 以下端口速率低于配置单 ${EXPECT_RATE}Gb/s：$RATE_BAD"; CARD_ERR=1; }
        fi

        # Link layer 核对：本批机器参数面走 RoCEv2，应为 Ethernet。
        # 若卡被配成 IB 模式（需要 Subnet Manager 才能起来），与 RoCEv2 组网不符，
        # 提示人工确认是否刻意为之。该字段不依赖链路，未接线时也照样输出。
        if [ -n "$P_LL" ]; then
            echo -e "${CYAN}    Link layer：$P_LL${NC}"
            if [ "$EXPECT_LINK_LAYER" = "IB" ]; then
                if [ -n "$LL_ODD" ]; then
                    ok "$bdf Link layer 为 IB，与预期一致"
                else
                    warn "$bdf Link layer 为 Ethernet，但预期是 IB（EXPECT_LINK_LAYER=IB）"
                fi
            elif [ -n "$EXPECT_LINK_LAYER" ] && [ -n "$LL_ODD" ]; then
                warn "$bdf 以下端口 Link layer 非 Ethernet：$LL_ODD（本单为 RoCEv2 组网，确认是否刻意配成 IB）"
            fi
        fi
    fi

    # --- 判定3：型号 / 部件号（配置单比对优先）---
    if [ -z "$DEVTYPE" ] && [ -z "$PN" ]; then
        pending "$bdf 读不到 Device type / 部件号（缺 mlxconfig 或 mst 未起），型号核对待定"; CARD_PEND=1
    elif [ -n "$EXPECT_PN" ] && [ -n "$PN" ]; then
        # 注意 tr 的坑：'-' 放在字符类中间会被当成范围，必须分开删再统一大小写
        a=$(printf '%s' "$PN" | tr -d '[:space:]' | tr -d '_-' | tr '[:lower:]' '[:upper:]')
        b=$(printf '%s' "$EXPECT_PN" | tr -d '[:space:]' | tr -d '_-' | tr '[:lower:]' '[:upper:]')
        if [ "$a" = "$b" ]; then
            ok "$bdf 部件号 ${PN} 与配置单一致（Device type=${DEVTYPE:-?}）"
        else
            err "$bdf 部件号不符：${PN}（配置单预期 ${EXPECT_PN}）"; CARD_ERR=1
        fi
    elif [ -n "$EXPECT_PN" ] && [ -z "$PN" ]; then
        pending "$bdf 配置单要求 ${EXPECT_PN}，但读不到实际部件号（缺 mlxconfig/mstflint 且 VPD 无 PN），无法核对"; CARD_PEND=1
    elif [ "$KNOWN" -eq 1 ]; then
        ok "$bdf Device type=${DEVTYPE:-?}，部件号 ${PN:-（未读到）}（未指定配置单部件号，只记录）"
    else
        echo -e "${CYAN}    型号：Device type=${DEVTYPE:-?} 部件号=${PN:-（未读到）}（规格表未收录，只记录不判定，可往 SPEC_TABLE 加一行）${NC}"
    fi

    # --- 判定4：固件版本 ---
    # mstflint 拿不到时，退回 ibstat 每个 CA 头里的 Firmware version
    if [ -z "$FW" ] && [ -n "$CA" ]; then
        FW=$(ibstat 2>/dev/null | awk -v c="$CA" '
            /^CA / { n=$0; sub(/^CA /, "", n); gsub(/\047/, "", n); on=(n==c); next }
            on && /Firmware version:/ { v=$0; sub(/^.*Firmware version:[[:space:]]*/, "", v); print v; exit }')
        [ -n "$FW" ] && FW_SRC="ibstat"
    fi
    if [ -n "$FW" ]; then
        ok "$bdf 固件版本 ${FW}（来源 ${FW_SRC:-未知}，PSID=${PSID:-未读到}，SN=${SN:-未读到}）"
    else
        # 《基础测试》5.3：「固件可读性——所有卡均可读到固件版本」列为 FAIL。
        # mstflint 与 ibstat 双重兜底都拿不到，说明驱动层确实有问题，按不合格处理。
        if [ -z "$CA" ]; then
            err "$bdf 读不到固件版本（无 mstflint，且 sysfs 里看不到 RDMA 设备名故 ibstat 也关联不上；SN=${SN:-未读到}）"; CARD_ERR=1
        else
            err "$bdf 读不到固件版本（无 mstflint，且 ibstat 未给出 $CA 的 Firmware version；SN=${SN:-未读到}）"; CARD_ERR=1
        fi
    fi

    # 收集用于全局一致性比对（固件是否统一、PSID 是否混插）
    [ -n "$FW" ]   && FW_LIST+=("$FW")
    [ -n "$PSID" ] && PSID_LIST+=("$PSID")
    [ -n "$PN" ]   && PN_LIST+=("$PN")

    # 汇总计数
    GEN="${DEVTYPE:-未知}"
    GEN_TOTAL["$GEN"]=$(( ${GEN_TOTAL["$GEN"]:-0} + 1 ))
    # 只有「既没明确不合格、也没有未判定项」的卡才算通过
    if [ "$CARD_ERR" -eq 0 ] && [ "$CARD_PEND" -eq 0 ]; then
        GEN_OK["$GEN"]=$(( ${GEN_OK["$GEN"]:-0} + 1 ))
    elif [ "$CARD_ERR" -eq 0 ]; then
        GEN_PEND["$GEN"]=$(( ${GEN_PEND["$GEN"]:-0} + 1 ))
    fi
    echo ""
done

# ---------- 汇总 ----------
echo -e "${BLUE}==================== 全局一致性 ====================${NC}"

# 1) 卡数与配置单
if [ "${EXPECT_CARDS:-0}" -gt 0 ]; then
    if [ "$CARD_N" -eq "$EXPECT_CARDS" ]; then
        ok "网卡数量 ${CARD_N} 张，与配置单一致"
    else
        err "网卡数量 ${CARD_N} 张，配置单要求 ${EXPECT_CARDS} 张（少装/多装/未识别）"
    fi
else
    echo -e "${CYAN}  网卡数量 ${CARD_N} 张（未指定配置单数量，只记录）${NC}"
fi

# 2) PCI 层数量 vs RDMA 层数量：不一致说明有卡没绑定 mlx5 驱动
if [ "${#BDF2CA[@]}" -gt 0 ] && [ "${#BDF2CA[@]}" -ne "$CARD_N" ]; then
    warn "PCI 层识别 ${CARD_N} 张，但只有 ${#BDF2CA[@]} 张绑定了 RDMA 设备名，可能有网卡未绑定 mlx5 驱动"
fi

# 3) MST 设备节点数与网卡数量一致（基础测试 5.3 列为 FAIL 项）
#    没装 MFT 时 DEVICES 为空，只提示不判不合格，避免误伤
if [ "${#DEVICES[@]}" -eq 0 ]; then
    warn "未取到 MST 设备节点（mst 未启动或未装 MFT），跳过「MST 节点数与网卡数一致」核对"
elif [ "${#DEVICES[@]}" -ne "$CARD_N" ]; then
    err "MST 设备节点数 ${#DEVICES[@]} 与网卡数量 ${CARD_N} 不一致，可能有卡未被 mst 识别"
else
    ok "MST 设备节点数 ${#DEVICES[@]} 与网卡数量一致"
fi

# 3) 固件版本一致性：多卡固件不一致是实打实的验收问题
if [ "${#FW_LIST[@]}" -gt 1 ]; then
    UNIQ_FW=$(printf '%s\n' "${FW_LIST[@]}" | sort -u | wc -l | tr -d ' ')
    if [ "$UNIQ_FW" -gt 1 ]; then
        err "固件版本不一致（${UNIQ_FW} 种）：$(printf '%s\n' "${FW_LIST[@]}" | sort -u | tr '\n' ' ')"
    else
        ok "${#FW_LIST[@]} 张卡固件版本一致（${FW_LIST[0]}）"
    fi
elif [ "${#FW_LIST[@]}" -eq 1 ]; then
    ok "固件版本 ${FW_LIST[0]}（仅 1 张卡读到）"
fi
if [ "${EXPECT_CARDS:-0}" -gt 0 ] && [ "${#FW_LIST[@]}" -lt "$CARD_N" ]; then
    warn "有 $((CARD_N - ${#FW_LIST[@]})) 张卡读不到固件版本"
fi

# 4) PSID 一致性：不一致通常意味着混插了不同配置的卡
if [ "${#PSID_LIST[@]}" -gt 1 ]; then
    UNIQ_PSID=$(printf '%s\n' "${PSID_LIST[@]}" | sort -u | wc -l | tr -d ' ')
    if [ "$UNIQ_PSID" -gt 1 ]; then
        warn "PSID 不一致（可能存在混插）：$(printf '%s\n' "${PSID_LIST[@]}" | sort -u | tr '\n' ' ')"
    else
        ok "${#PSID_LIST[@]} 张卡 PSID 一致（${PSID_LIST[0]}）"
    fi
fi
echo ""

echo -e "${BLUE}==================== 汇总 ====================${NC}"
echo "共发现 $CARD_N 张网卡"
for g in "${!GEN_TOTAL[@]}"; do
    t="${GEN_TOTAL[$g]}"; p="${GEN_OK[$g]:-0}"; q="${GEN_PEND[$g]:-0}"
    if [ "$p" -eq "$t" ]; then
        echo -e "${GREEN}$g: $t 张，全部通过${NC}"
    elif [ "$q" -gt 0 ] && [ "$((p + q))" -eq "$t" ]; then
        echo -e "${YELLOW}$g: $t 张，通过 $p 张，待判定 $q 张（信息缺失或未接线）${NC}"
    else
        echo -e "${RED}$g: $t 张，通过 $p 张，异常 $((t - p - q)) 张${NC}"
    fi
done
[ "$UNPLUGGED" -gt 0 ] && echo -e "${CYAN}其中 ${UNPLUGGED} 张未接线（端口速率未判定，接线后需复测）${NC}"
echo -e "错误项 ${RED}$ERRORS${NC} 个，警告项 ${YELLOW}$WARNINGS${NC} 个，待判定项 ${YELLOW}$PENDING${NC} 个"
if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}❌ 【判定】FAIL —— 存在 $ERRORS 个错误项${NC}"; exit 1
elif [ "$PENDING" -gt 0 ]; then
    echo -e "${YELLOW}⏳ 【判定】Pending —— 有 $PENDING 项因信息缺失 / 未接线无法判定，本次不算通过${NC}"
    [ "$UNPLUGGED" -gt 0 ] && echo -e "${YELLOW}   其中 ${UNPLUGGED} 张卡未接线，接好线后请复测${NC}"
    exit 1
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}⚠️ 【判定】PASS（附 $WARNINGS 条 WARN）—— 请人工确认${NC}"; exit 0
else
    echo -e "${GREEN}✅ 【判定】PASS —— 所有网卡检查通过${NC}"; exit 0
fi
