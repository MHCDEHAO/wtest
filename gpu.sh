#!/bin/bash
# ============================================================
# gpu.sh —— 显卡 9 项检测（在位 / 驱动与CUDA / ECC / VBIOS一致性 / NVLink拓扑·速率·误码 / P2P可达 / 身份与规格）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   bash gpu.sh                # 一条命令，9 项全跑
#   bash gpu.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数，不需要 root。
#   ★ 只能在 Linux 上运行（非 Linux 会被平台守卫直接拦下，exit 2）。
#
#   【典型输出】
#     【1.2】GPU 在位检测        → 识别有效 NVIDIA GPU 数量: 8
#     【1.2.1】驱动与CUDA版本     → 驱动 550.90.07 / CUDA 12.4
#     【1.2.2】GPU ECC 状态       → ECC Mode 与错误计数均按卡汇总，非零项与读不到项分别标注
#     【1.2.3】VBIOS 与型号一致性 → VBIOS 一致 / 型号一致 / 序列号唯一且完整
#     【1.2.4】NVLink 拓扑        → 打印 topo -m，人工判定
#     【1.2.5】NVLink 链路速率    → GPU0: 18 条链路 | 26.562 GB/s ×18
#     【1.2.6】NVLink 误码计数    → GPU0: 已检查 54 项计数 | 全部为 0（18 链路 × 3 类）
#     【1.2.7】GPU P2P 可达矩阵   → 打印 topo -p2p r，并给出非 OK 项（对角线除外）计数
#     【1.2.8】GPU 身份与规格     → 序号/槽位/UUID/显存/功耗上限（含上限一致性）
#     【判定】PASS —— 8 张卡在位、无混批，ECC 无异常计数
#
# ---- 二、参数一览 ----
#   【必给】无
#   【有默认值】
#     -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     无
#
# ---- 四、它做什么 ----
#   1.2   GPU 在位检测        —— PCIe 层计数 + nvidia-smi 可用性
#   1.2.1 驱动与 CUDA 版本    —— driver_version / CUDA Version 采集
#   1.2.2 GPU ECC 状态        —— ECC Mode 按卡汇总 + 错误计数三态（非零 / 全 0 / 读不到）+ 非零明细（带卡号）
#   1.2.3 显卡 VBIOS 与型号一致性 —— 8 卡模组混批核对（型号/VBIOS/序列号）
#   1.2.4 NVLink 拓扑         —— nvidia-smi topo -m，人工判定
#   1.2.5 NVLink 链路速率     —— nvidia-smi nvlink -s，按卡汇总链路速率分布
#   1.2.6 NVLink 误码计数     —— nvidia-smi nvlink -e，按卡区分「非零」与「读不到」
#   1.2.7 GPU P2P 可达矩阵    —— nvidia-smi topo -p2p r，打印矩阵 + 非 OK 项计数
#   1.2.8 GPU 身份与规格      —— UUID / 槽位 / 显存 / 功耗上限（含上限一致性对比）
#
# ---- 五、判定口径与退出码 ----
#   PASS     nvidia-smi 可用，且未发现混批
#   FAIL     下列任一：
#              · PCIe 层识别到卡、但 nvidia-smi 不通（有卡无驱动 / 驱动异常）
#              · VBIOS 版本不一致（混批）
#              · 显卡型号不一致（混批）
#              · 序列号重复（数量少于卡数）
#   Pending  nvidia-smi 不可用、或未检测到 NVIDIA 卡 —— 没测出来，不算不合格
#
#   ★ ECC 项只做展示，不作合格判据：ECC 计数非零
#     时给 WARN 提示交人工判断，不判 FAIL。判断 ECC 是否合格要看差值是否
#     随测试增长，那是计数器快照/差值那一层的职责。
#   ★ 序列号读不到（[N/A]，消费卡常见）不计入混批，只提示。
#   ★ 1.2.5 / 1.2.6 / 1.2.7 / 1.2.8 只做展示，不计入 GPU_FAIL_N，不影响退出码：
#     这几项反映的是链路速率、链路误码、P2P 可达性与功耗上限的实测现状，
#     脚本只如实列出，不作合格判据。
#
#   退出码：0 = PASS   1 = FAIL / Pending   2 = 用法错误
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：bash gpu.sh | tee gpu_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 在位检测的类别不能只认 VGA / 3D controller：部分固件把数据中心卡
#     报成 "Processing accelerators"，漏掉会让"有卡但驱动异常"的判断失效。
#   ★ VBIOS 核对为什么要带槽位列：槽位取自 pci.bus_id（形如 00000000:01:00.0），
#     是这张卡在机箱里的物理位置标识，判定出问题时便于换件定位。
#     个别旧驱动读不到该字段时自动退回四列（省略槽位），不影响其余判定。
#   ★ CUDA 版本为什么按字段名抽：nvidia-smi 表头行末尾是 "|"（表格右边界），
#     awk '{print $NF}' 取到的是它而不是版本号，必须用 sed 按 "CUDA Version:" 抽。
#   ★ 序列号唯一值个数为什么要剔 [N/A]：消费卡读不到序列号属正常，
#     若把 [N/A] 当成一个"值"去重，8 张卡会算成 1 个唯一值 → 误判混批。
#   ★ 为什么 NVLink 要分成 1.2.4 / 1.2.5 / 1.2.6 三项：topo -m 只能看出
#     "有没有 NVLink"，一条降速链路在 topo -m 里仍显示 NV18；只有 nvlink -s
#     能暴露速率、nvlink -e 能暴露误码，三者互补，缺一项就可能漏掉链路级劣化。
#   ★ 为什么 ECC 计数要分「非零 / 全 0 / 读不到」三态：消费卡或未启用 ECC 的卡，
#     整段计数都是 [N/A]。把它并进「全 0」会输出「全部为 0（N 项）」——
#     那是「读不到」，不是「没错误」，语义正好相反，会掩盖掉需要现场确认的情况。
#   ★ 为什么 ECC 展示段不认字段名：ECC Errors 的字段名随架构/驱动变化
#     （Fermi 时代是 Single Bit / Double Bit，现代是 DRAM / SRAM 的
#     Correctable / Uncorrectable），写死字段名会在换卡或换驱动后静默失效，
#     所以只按"段内数值非零"抽取。
#   ★ 为什么 nvlink -e 要把「读不到」单独报：N/A 表示这条链路取不到计数
#     （链路未启用或已故障），语义上比"误码非零"更严重；把它混进"非零"
#     会让现场往误码方向查，查错地方。
#   ★ 为什么 ECC Mode 要按卡汇总：原实现 `grep -A2 | head -2` 只取到第一张卡，
#     8 卡机上若某张卡 ECC 被单独关掉，输出里看不出来。
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

# ---------- 平台守卫 ----------
# 本脚本依赖 nvidia-smi / lspci。Windows 上可能也有个 nvidia-smi.exe，
# 那会读到「别的机器」的显卡信息并产出错误结论 —— 先在平台层拦掉（§3.24）。
_os="$(uname -s 2>/dev/null || echo unknown)"
case "${_os}" in
    Linux) : ;;
    *) err "本脚本只能在 Linux 上运行（当前 uname -s = ${_os}）"
       info "请在 Ubuntu 22.04 被测机上执行：bash gpu.sh"
       exit 2 ;;
esac

# ---------- 全局状态 ----------
GPU_FAIL_N=0        # FAIL 计数（决定退出码）
PENDING=0           # 有项没测出来
HAS_SMI=0           # nvidia-smi 是否可用
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    HAS_SMI=1
fi

# ==================== 【1.2】GPU 在位检测 ====================
check_gpu_present(){
    echo "==================== 【1.2】GPU 在位检测 ===================="

    local pci_gpu_cnt=0
    if command -v lspci >/dev/null 2>&1; then
        # 类别不能只认 VGA / 3D controller：部分固件把数据中心卡报成
        # "Processing accelerators"，漏掉会让下面"有卡但驱动异常"的判断失效
        pci_gpu_cnt=$(lspci 2>/dev/null | grep -i "nvidia" \
                      | grep -iE "VGA|3D controller|Processing accelerator" | wc -l)
    else
        warn "找不到 lspci（pciutils），无法做 PCIe 层显卡计数"
    fi

    if [ "${HAS_SMI}" -eq 1 ]; then
        ok "识别有效 NVIDIA GPU 数量: ${pci_gpu_cnt}"
        echo "  nvidia-smi -L:"
        nvidia-smi -L 2>/dev/null | sed 's/^/    /'
    elif command -v nvidia-smi >/dev/null 2>&1; then
        err "NVIDIA 驱动存在但显卡异常（nvidia-smi 无法正常执行）   【FAIL】"
        if [ "${pci_gpu_cnt}" -gt 0 ]; then
            info "物理 PCIe 层识别到 ${pci_gpu_cnt} 张 NVIDIA 显卡，但驱动无法通信"
            GPU_FAIL_N=$((GPU_FAIL_N + 1))
        fi
    else
        if [ "${pci_gpu_cnt}" -gt 0 ]; then
            warn "检测到 ${pci_gpu_cnt} 张 NVIDIA 物理显卡，但未安装驱动，GPU 相关项将跳过   【WARN】"
        else
            warn "未检测到 NVIDIA 显卡硬件，跳过 GPU 相关检测   【WARN】"
        fi
        PENDING=1
    fi
    echo ""
}

# ==================== 【1.2.1】驱动与 CUDA 版本 ====================
check_nvidia_version(){
    echo "==================== 【1.2.1】NVIDIA 驱动与 CUDA 版本 ===================="
    if [ "${HAS_SMI}" -eq 1 ]; then
        local DRIVER_VER CUDA_VER
        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        # 表头行末尾是 "|"（表格右边界），awk '{print $NF}' 取到的是它而不是版本号，
        # 必须按字段名抽数字
        CUDA_VER=$(nvidia-smi 2>/dev/null | grep "CUDA Version" \
                   | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)
        echo "  驱动版本: ${DRIVER_VER:-未获取}"
        echo "  CUDA版本: ${CUDA_VER:-未获取}"
    else
        warn "nvidia-smi 不可用，无法获取驱动/CUDA 版本"
    fi
    echo ""
}

# ==================== 【1.2.2】GPU ECC 状态 ====================
check_ecc(){
    echo "==================== 【1.2.2】GPU ECC 状态 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过 ECC 检查"
        echo ""
        return 0
    fi

    # ECC Mode 按卡汇总。原实现 `grep -A2 "ECC Mode" | head -2` 只取到第一张卡，
    # 8 卡机上若某张卡 ECC 被单独关掉，这一行看不出来。
    local ECC_MODE
    ECC_MODE=$(nvidia-smi -q 2>/dev/null | awk '
        /^GPU [0-9a-fA-F]/ { next }
        /^[ \t]+ECC Mode[ \t]*$/ { inm = 1; next }
        inm && /^    [A-Z]/ { inm = 0 }
        inm {
            if ($0 !~ /:/) next
            k = $0; sub(/[ \t]*:.*/, "", k); sub(/^[ \t]+/, "", k)
            v = $0; sub(/.*:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
            if ((k == "Current" || k == "Pending") && v != "") print k "=" v
        }')
    local k vals n u
    for k in Current Pending; do
        vals=$(printf '%s\n' "${ECC_MODE}" | sed -n "s/^${k}=//p")
        if [ -z "${vals}" ]; then
            echo "  ECC Mode ${k} : 未获取"
            continue
        fi
        n=$(printf '%s\n' "${vals}" | grep -c .)
        u=$(printf '%s\n' "${vals}" | sort -u | grep -c .)
        if [ "${u}" -le 1 ]; then
            echo "  ECC Mode ${k} : ${n} 张卡均为 $(printf '%s\n' "${vals}" | head -1)"
        else
            echo "  ECC Mode ${k} : 不一致，共 ${u} 种"
            printf '%s\n' "${vals}" | sort | uniq -c | sed 's/^/         /'
        fi
    done

    # ECC Errors 段按卡汇总计数。字段名随架构 / 驱动而变（Fermi 时代是 Single Bit /
    # Double Bit，现代是 DRAM / SRAM 的 Correctable / Uncorrectable），所以这里不认字段名，
    # 只按「段内数值非零」统计，避免字段改名后整段抓不到值。
    local ECC_ERRORS
    ECC_ERRORS=$(nvidia-smi -q 2>/dev/null | awk '
        /^GPU [0-9a-fA-F]/         { g++; insec = 0; next }
        /^[ \t]+ECC Errors[ \t]*$/ { insec = 1; next }
        insec && /^    [A-Z]/      { insec = 0 }
        insec {
            if ($0 !~ /:/) next
            v = $0; sub(/.*:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
            if (v ~ /^[1-9][0-9]*$/)  hit[g]++      # 非零计数
            else if (v ~ /^0+$/)      zero[g]++     # 计数为 0：正常
            else                      na[g]++       # [N/A] 等：读不到，不等于 0
        }
        END {
            for (i = 1; i <= g; i++) {
                if (hit[i] > 0) {
                    printf "    GPU%d: 非零 %d 项", i - 1, hit[i]
                    if (na[i] > 0) printf "（另有 %d 项读不到）", na[i]
                    printf "\n"
                } else if (zero[i] > 0) {
                    printf "    GPU%d: 全部为 0（%d 项）", i - 1, zero[i]
                    if (na[i] > 0) printf "（另有 %d 项读不到）", na[i]
                    printf "\n"
                } else if (na[i] > 0) {
                    printf "    GPU%d: %d 项均读不到（[N/A]）\n", i - 1, na[i]
                }
            }
        }')
    if [ -n "${ECC_ERRORS}" ]; then
        echo "  ECC错误计数（ECC Errors 段，按卡汇总）:"
        printf '%s\n' "${ECC_ERRORS}"
    fi

    # 非零明细：带卡号与 Volatile / Aggregate 段名。抓取范围比展示段宽 ——
    # 同时覆盖 Remapped Rows 段（H100 / H200 特有的行重映射计数）。
    local ECC_NZ
    ECC_NZ=$(nvidia-smi -q 2>/dev/null | awk '
        /^GPU [0-9a-fA-F]/ { g++; insec = 0; subsec = ""; next }
        /^[ \t]+(ECC Errors|Remapped Rows)[ \t]*$/ { insec = 1; subsec = ""; next }
        insec && /^    [A-Z]/ { insec = 0 }
        insec && /^[ \t]+(Volatile|Aggregate)[ \t]*$/ {
            s = $0; sub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); subsec = s; next
        }
        insec {
            if ($0 !~ /:/) next
            v = $0; sub(/.*:[ \t]*/, "", v); gsub(/[ \t]+$/, "", v)
            if (v ~ /^[1-9][0-9]*$/) {
                n = $0; sub(/[ \t]*:.*/, "", n); sub(/^[ \t]+/, "", n)
                p = (subsec == "" ? "" : subsec "/")
                printf "    GPU%d: %s%s = %s\n", g - 1, p, n, v
            }
        }')
    if [ -n "${ECC_NZ}" ]; then
        warn "存在非零 ECC 计数，请结合「测试前后差值」判断是否在本次测试中增长   【WARN】"
        printf '%s\n' "${ECC_NZ}"
    fi
    echo ""
}

# ==================== 【1.2.3】显卡 VBIOS 与型号一致性 ====================
# 目的：8 卡模组交付时，型号 / VBIOS / 序列号必须同批一致，不一致即混批，须换件。
check_gpu_vbios(){
    echo "==================== 【1.2.3】显卡 VBIOS 与型号一致性 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过显卡 VBIOS 核对"
        echo ""
        return 0
    fi

    # 一次取齐：序号 / 槽位(PCIe 总线地址) / 型号 / 序列号 / VBIOS
    # 槽位取 pci.bus_id（形如 00000000:01:00.0），是这张卡在机箱里的物理位置标识；
    # 个别旧驱动读不到该字段时自动退回四列（省略槽位），不影响其余判定。
    local raw has_slot=1
    raw=$(nvidia-smi --query-gpu=index,pci.bus_id,name,serial,vbios_version --format=csv,noheader 2>/dev/null)
    if [ -z "${raw}" ]; then
        raw=$(nvidia-smi --query-gpu=index,name,serial,vbios_version --format=csv,noheader 2>/dev/null)
        has_slot=0
    fi
    if [ -z "${raw}" ]; then
        warn "未取到 VBIOS 信息（本版驱动可能不支持该字段），本项 Pending"
        PENDING=1
        echo ""
        return 0
    fi

    # 列号随「是否带槽位列」而变，避免后续 awk 写死列位
    local C_NAME C_SERIAL C_VBIOS
    if [ "${has_slot}" -eq 1 ]; then
        C_NAME=3; C_SERIAL=4; C_VBIOS=5
    else
        C_NAME=2; C_SERIAL=3; C_VBIOS=4
    fi

    local gpu_cnt
    gpu_cnt=$(printf '%s\n' "${raw}" | grep -c .)
    if [ "${has_slot}" -eq 1 ]; then
        echo "  识别到 ${gpu_cnt} 张显卡（序号, 槽位, 型号, 序列号, VBIOS）:"
    else
        echo "  识别到 ${gpu_cnt} 张显卡（序号, 型号, 序列号, VBIOS）:"
        warn "本版驱动读不到 PCIe 槽位，已省略该列"
    fi
    printf '%s\n' "${raw}" | sed 's/^/    /'

    if [ "${gpu_cnt}" -le 1 ]; then
        info "单卡机型，无一致性可比对"
        echo ""
        return 0
    fi

    # 各列去空白后数「唯一值个数」：>1 即混批
    local vbios_uniq name_uniq serial_uniq bad=0
    vbios_uniq=$(printf '%s\n' "${raw}" | awk -F',' -v n="${C_VBIOS}" '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | sort -u | grep -c .)
    name_uniq=$(printf '%s\n' "${raw}"  | awk -F',' -v n="${C_NAME}"  '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' | sort -u | grep -c .)
    # 序列号先剔掉 [N/A] / [Not Supported]：消费卡读不到序列号属正常，不算混批
    serial_uniq=$(printf '%s\n' "${raw}" | awk -F',' -v n="${C_SERIAL}" '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' \
                  | grep -v -i -E '^\[?(n/a|not supported|unknown|invalid)\]?$' | sort -u | grep -c .)

    if [ "${vbios_uniq}" -gt 1 ]; then
        err "VBIOS 版本不一致，共 ${vbios_uniq} 种   【FAIL】"
        printf '%s\n' "${raw}" | awk -F',' -v n="${C_VBIOS}" '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' \
            | sort | uniq -c | sed 's/^/         /'
        bad=1
    else
        ok "VBIOS 版本一致"
    fi

    if [ "${name_uniq}" -gt 1 ]; then
        err "显卡型号不一致，共 ${name_uniq} 种   【FAIL】"
        bad=1
    else
        ok "显卡型号一致"
    fi

    if [ "${serial_uniq}" -eq 0 ]; then
        warn "序列号不可读（消费卡常见），跳过序列号核对   【WARN】"
    elif [ "${serial_uniq}" -lt "${gpu_cnt}" ]; then
        err "序列号重复：仅 ${serial_uniq} 个唯一值 / 共 ${gpu_cnt} 张卡   【FAIL】"
        bad=1
    else
        ok "序列号唯一且完整（${serial_uniq} 个）"
    fi

    if [ "${bad}" -eq 1 ]; then
        GPU_FAIL_N=$((GPU_FAIL_N + 1))
        err ">>> 显卡混批：换件后须重跑全部对应项 <<<"
    fi
    echo ""
}

# ==================== 【1.2.4】NVLink 拓扑（人工判定） ====================
show_nvlink_topology(){
    echo "==================== 【1.2.4】NVLink 拓扑（请人工判定） ===================="
    if [ "${HAS_SMI}" -eq 1 ]; then
        nvidia-smi topo -m 2>/dev/null | head -20 | sed 's/^/  /'
        warn ">>> 请人工确认所有 GPU 之间互联状态（NVLink / PCIe）<<<"
    else
        warn "nvidia-smi 不可用，跳过 NVLink 拓扑"
    fi
    echo ""
}

# ==================== 【1.2.5】NVLink 链路速率 ====================
# 目的：topo -m 只能看出「有没有 NVLink」，看不出链路是否降速 ——
#       一条降速链路在 topo -m 里仍显示 NV18，只有 nvlink -s 能暴露。
show_nvlink_speed(){
    echo "==================== 【1.2.5】NVLink 链路速率 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过 NVLink 链路速率"
        echo ""
        return 0
    fi

    local agg
    agg=$(nvidia-smi nvlink -s 2>/dev/null | awk -F: '
        function num(s,   x) { x = s; gsub(/[^0-9.]/, "", x); return x + 0 }
        function emit(   i, j, t, nk) {
            if (cur == "") return
            if (tot == 0) { printf "  GPU%s: 无 NVLink 链路\n", cur; return }
            nk = 0
            for (k in cnt) keys[++nk] = k
            for (i = 2; i <= nk; i++) {          # 按速率数值降序 → 输出顺序不随 awk 哈希变
                t = keys[i]
                for (j = i - 1; j >= 1 && num(keys[j]) < num(t); j--) keys[j + 1] = keys[j]
                keys[j + 1] = t
            }
            printf "  GPU%s: %d 条链路 |", cur, tot
            for (i = 1; i <= nk; i++) printf " %s ×%d", keys[i], cnt[keys[i]]
            printf "\n"
        }
        /^GPU[ \t]*[0-9]/ {
            emit()
            cur = $1; sub(/^GPU[ \t]*/, "", cur)
            split("", cnt); tot = 0
            next
        }
        /Link[ \t]+[0-9]+[ \t]*:/ {
            v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v != "") { cnt[v]++; tot++ }
        }
        END { emit() }')

    if [ -z "${agg}" ]; then
        warn "未获取 NVLink 链路速率（本机无 NVLink，或本版驱动不支持该命令）"
    else
        printf '%s\n' "${agg}"
    fi
    echo ""
}

# ==================== 【1.2.6】NVLink 误码计数 ====================
# 目的：nvlink -e 给出每条链路的累计误码计数，非零说明该链路传输出现过重传/恢复。
show_nvlink_err(){
    echo "==================== 【1.2.6】NVLink 误码计数 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过 NVLink 误码计数"
        echo ""
        return 0
    fi

    local agg
    agg=$(nvidia-smi nvlink -e 2>/dev/null | awk -F: '
        function emit() {
            if (cur == "") return
            if (tot == 0) { printf "  GPU%s: 未取到误码计数\n", cur; return }
            printf "  GPU%s: 已检查 %d 项计数 |", cur, tot
            if (nz > 0) {
                printf " 非零 %d 项", nz
                if (na > 0) printf "（另有 %d 项读不到）", na
            } else if (na > 0) {
                printf " 未取到 %d 项", na
            } else {
                printf " 全部为 0"
            }
            printf "\n"
            if (nz > 0) printf "%s", det
        }
        /^GPU[ \t]*[0-9]/ {
            emit()
            cur = $1; sub(/^GPU[ \t]*/, "", cur)
            tot = 0; nz = 0; na = 0; det = ""
            next
        }
        /Link[ \t]+[0-9]+/ {
            v = $NF; gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v == "") next
            tot++
            if (v ~ /^[0-9]+$/ && v + 0 == 0) next   # 计数为 0：正常
            if (v ~ /^[0-9]+$/) {                    # 非零误码：列明细
                nz++
                l = $0; sub(/^[ \t]+/, "", l)
                det = det "      " l "\n"
            } else {                                 # N/A / Inactive：读不到，不等于 0
                na++
            }
        }
        END { emit() }')

    if [ -z "${agg}" ]; then
        warn "未获取 NVLink 误码计数（本机无 NVLink，或本版驱动不支持该命令）"
    else
        printf '%s\n' "${agg}"
    fi
    echo ""
}

# ==================== 【1.2.7】GPU P2P 可达矩阵 ====================
# 目的：topo -m 给的是「互联类型」，p2p r 直接给「能不能点对点通信」。
#       非 OK 项在 PCIe 机型上属正常（经主机桥转发），故只展示、只记 WARN。
show_p2p_matrix(){
    echo "==================== 【1.2.7】GPU P2P 可达矩阵 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过 P2P 可达矩阵"
        echo ""
        return 0
    fi

    local raw bad
    raw=$(nvidia-smi topo -p2p r 2>/dev/null)
    if [ -z "${raw}" ]; then
        warn "未获取 P2P 可达矩阵（本版驱动不支持 topo -p2p，或本机仅 1 张卡）"
        echo ""
        return 0
    fi

    printf '%s\n' "${raw}" | sed 's/^/  /'
    bad=$(printf '%s\n' "${raw}" | awk '
        /^GPU[0-9]/ { n++; rows[n] = $0 }
        END {
            for (r = 1; r <= n; r++) {
                split(rows[r], f, /[ \t]+/)
                for (i = 1; i <= n; i++) {
                    if (i == r) continue
                    v = f[i + 1]
                    if (v != "OK" && v != "X") bad++
                }
            }
            print bad + 0
        }')
    if [ "${bad}" -eq 0 ]; then
        ok "非 OK 项（对角线除外）: 0"
    else
        warn "非 OK 项（对角线除外）: ${bad}   【WARN】"
    fi
    echo ""
}

# ==================== 【1.2.8】GPU 身份与规格 ====================
# 目的：把 UUID 与卡槽位对应起来（换件定位、与 BMC / 工单对号），
#       并把各卡功耗上限并排列出，便于核对是否被限功率。
show_gpu_identity(){
    echo "==================== 【1.2.8】GPU 身份与规格 ===================="
    if [ "${HAS_SMI}" -ne 1 ]; then
        warn "nvidia-smi 不可用，跳过 GPU 身份与规格"
        echo ""
        return 0
    fi

    local raw has_max=1
    raw=$(nvidia-smi --query-gpu=index,pci.bus_id,uuid,memory.total,power.limit,power.max_limit --format=csv,noheader 2>/dev/null)
    if [ -z "${raw}" ]; then
        raw=$(nvidia-smi --query-gpu=index,pci.bus_id,uuid,memory.total,power.limit --format=csv,noheader 2>/dev/null)
        has_max=0
    fi
    if [ -z "${raw}" ]; then
        warn "未获取 GPU 身份信息（本版驱动不支持相关字段）"
        echo ""
        return 0
    fi

    echo "  序号 | 槽位 | UUID | 显存 | 功耗上限(当前 / 最大)"
    printf '%s\n' "${raw}" | awk -F', *' -v hm="${has_max}" '
        { if (hm == 1) printf "    %s | %s | %s | %s | %s / %s\n", $1, $2, $3, $4, $5, $6
          else         printf "    %s | %s | %s | %s | %s / 未获取\n", $1, $2, $3, $4, $5 }'

    # 功耗上限对比：只做一致性展示，不作合格判据
    local pl_n pl_uniq
    pl_n=$(printf '%s\n' "${raw}" | grep -c .)
    pl_uniq=$(printf '%s\n' "${raw}" | awk -F', *' '{v = $5; gsub(/[^0-9.]/, "", v); print v}' | sort -u | grep -c .)
    if [ "${pl_uniq}" -eq 0 ]; then
        info "功耗上限一致性: 未获取（${pl_n} 张卡的 power.limit 均读不到）"
    elif [ "${pl_uniq}" -eq 1 ]; then
        info "功耗上限一致性: ${pl_n} 张卡一致"
    else
        info "功耗上限一致性: 不一致，共 ${pl_uniq} 种"
        printf '%s\n' "${raw}" | awk -F', *' '{v = $5; gsub(/[^0-9.]/, "", v); print v}' \
            | sort | uniq -c | sed 's/^/         /'
    fi
    echo ""
}

# ==================== 主流程 ====================
echo ""
check_gpu_present
check_nvidia_version
check_ecc
check_gpu_vbios
show_nvlink_topology
show_nvlink_speed
show_nvlink_err
show_p2p_matrix
show_gpu_identity

# ---------- 结论 ----------
echo "========================================================"
if [ "${GPU_FAIL_N}" -gt 0 ]; then
    echo "【判定】FAIL —— 存在 ${GPU_FAIL_N} 项失败（驱动异常 / 显卡混批），详见上方 FAIL 行"
    exit 1
fi
if [ "${PENDING}" -gt 0 ]; then
    echo "【判定】Pending —— 无法完成检测（无 NVIDIA 卡或 nvidia-smi 不可用），请人工确认"
    exit 1
fi
echo "【判定】PASS —— 显卡在位正常，未发现混批"
exit 0
