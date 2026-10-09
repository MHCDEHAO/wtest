#!/bin/bash
# ============================================================
# BIOS 设置检查脚本
# 功能：检查关键 BIOS 设置（可查的自动查，不可查的提示人工确认）
# 用法：sudo ./check_bios.sh
# 返回码：0=所有可查项通过，1=存在异常
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "【错误】请使用 root 权限运行此脚本！"
    exit 1
fi

# 颜色
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
fi

FAIL=0
WARN=0

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  BIOS 设置检查${NC}"
echo -e "${BLUE}============================================================${NC}"

# ============================================================
# 1. BIOS 版本信息
# ============================================================
echo -e "\n${YELLOW}【1. BIOS 版本】${NC}"
if command -v dmidecode &>/dev/null; then
    dmidecode -t bios 2>/dev/null | grep -E "Vendor|Version|Release Date" | sed 's/^[[:space:]]*//' | while read line; do
        echo "  $line"
    done
else
    echo -e "  ${RED}dmidecode 未安装${NC}"
    ((FAIL++))
fi

# ============================================================
# 2. Secure Boot
# ============================================================
echo -e "\n${YELLOW}【2. Secure Boot】${NC}"
if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null | awk '{print $NF}')
    if [ "$SB_STATE" = "enabled" ] || [ "$SB_STATE" = "on" ]; then
        echo -e "  ${RED}Secure Boot: ${SB_STATE}（建议关闭，可能影响驱动加载）${NC}"
        ((WARN++))
    elif [ "$SB_STATE" = "disabled" ] || [ "$SB_STATE" = "off" ]; then
        echo -e "  ${GREEN}Secure Boot: ${SB_STATE}（已关闭）${NC}"
    else
        echo "  Secure Boot: ${SB_STATE:-未知}"
    fi
else
    echo -e "  ${YELLOW}mokutil 未安装，跳过检查${NC}"
fi

# ============================================================
# 3. NUMA + SNC
# ============================================================
echo -e "\n${YELLOW}【3. NUMA 与 SNC】${NC}"
if command -v numactl &>/dev/null; then
    # 原写法 grep -oE '[0-9]+' 会把 "available: 2 nodes (0-1)" 拆成 2/0/1 三行，
    # 导致下面的 [ "$NODE_COUNT" -gt 0 ] 报 "integer expression expected"，
    # SNC 检测被静默跳过。改为只取 available 后的第一个字段。
    NODE_COUNT=$(numactl -H 2>/dev/null | awk '/available:/{print $2; exit}')
    case "${NODE_COUNT}" in ''|*[!0-9]*) NODE_COUNT="" ;; esac

    CPU_PHYSICAL=$(lscpu 2>/dev/null | grep "Socket(s)" | awk '{print $2}')
    [ -z "$CPU_PHYSICAL" ] && CPU_PHYSICAL=$(grep 'physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
    # 部分 CPU(AMD/虚拟机) 没有 physical id 字段，wc -l 会返回 0 而不是空，
    # 0 会让后面的 SNC 比值判断失真，这里一并兜底为 1
    case "${CPU_PHYSICAL}" in ''|*[!0-9]*) CPU_PHYSICAL=1 ;; esac
    [ "$CPU_PHYSICAL" -lt 1 ] && CPU_PHYSICAL=1

    if [ -n "$NODE_COUNT" ] && [ "$NODE_COUNT" -gt 0 ]; then
        echo "  物理 CPU 数: ${CPU_PHYSICAL}"
        echo "  NUMA 节点数: ${NODE_COUNT}"
        if [ "$NODE_COUNT" -eq "$CPU_PHYSICAL" ]; then
            echo -e "  ${GREEN}✅ SNC 已关闭（节点数 = CPU 数，推荐状态）${NC}"
        elif [ "$NODE_COUNT" -eq $((CPU_PHYSICAL * 2)) ]; then
            echo -e "  ${YELLOW}⚠️ SNC 已开启（节点数 = CPU 数 × 2），验收建议关闭${NC}"
            ((WARN++))
        else
            echo -e "  ${YELLOW}⚠️ 节点数 (${NODE_COUNT}) 与 CPU 数 (${CPU_PHYSICAL}) 关系不明确，请人工确认 SNC 状态${NC}"
            ((WARN++))
        fi
    else
        echo "  numactl 输出异常，跳过"
    fi
else
    echo -e "  ${YELLOW}numactl 未安装，跳过 SNC 检测${NC}"
    ((WARN++))
fi

# ============================================================
# 4. 虚拟化支持（VT-x / AMD-V）
# ============================================================
echo -e "\n${YELLOW}【4. 虚拟化支持（VT-x/AMD-V）】${NC}"
VIRT=$(lscpu | grep Virtualization | awk '{print $2}')
if [ -n "$VIRT" ]; then
    echo -e "  ${GREEN}虚拟化: ${VIRT}（已启用）${NC}"
else
    echo -e "  ${YELLOW}未检测到虚拟化支持（可能未开启或 CPU 不支持）${NC}"
    ((WARN++))
fi

# ============================================================
# 5. Above 4G Decoding
# ============================================================
echo -e "\n${YELLOW}【5. Above 4G Decoding】${NC}"
if dmesg | grep -qi "above 4g"; then
    echo -e "  ${GREEN}Above 4G Decoding: 已启用${NC}"
    dmesg | grep -i "above 4g" | head -1 | sed 's/^[[:space:]]*/    /'
elif dmesg | grep -qi "iommu.*supported"; then
    echo -e "  ${YELLOW}未显式检测到 Above 4G Decoding，但 IOMMU 可能已启用${NC}"
    ((WARN++))
else
    echo -e "  ${YELLOW}未检测到 Above 4G Decoding（可能未开启或未记录日志）${NC}"
    ((WARN++))
fi

# ============================================================
# 6. Resizable BAR
# ============================================================
echo -e "\n${YELLOW}【6. Resizable BAR】${NC}"
if dmesg | grep -qi "resizable bar"; then
    echo -e "  ${GREEN}Resizable BAR: 已启用${NC}"
    dmesg | grep -i "resizable bar" | head -1 | sed 's/^[[:space:]]*/    /'
else
    echo -e "  ${YELLOW}未检测到 Resizable BAR（可能未开启或 GPU 不支持）${NC}"
    ((WARN++))
fi

# ============================================================
# 7. SR-IOV
# ============================================================
echo -e "\n${YELLOW}【7. SR-IOV】${NC}"
if lspci -vv 2>/dev/null | grep -qi "SR-IOV" && lspci -vv 2>/dev/null | grep -q "Virtual Function"; then
    echo -e "  ${GREEN}SR-IOV: 已启用（设备支持）${NC}"
elif lspci -vv 2>/dev/null | grep -qi "SR-IOV"; then
    echo -e "  ${YELLOW}SR-IOV: 设备支持，但状态未确认${NC}"
    ((WARN++))
else
    echo -e "  ${YELLOW}未检测到 SR-IOV 支持（可能未开启或硬件不支持）${NC}"
    ((WARN++))
fi

# ============================================================
# 8. 启动模式（UEFI / Legacy）
# ============================================================
echo -e "\n${YELLOW}【8. 启动模式】${NC}"
if [ -d "/sys/firmware/efi" ]; then
    echo -e "  ${GREEN}UEFI 模式（已启用）${NC}"
else
    echo -e "  ${YELLOW}Legacy BIOS 模式（建议使用 UEFI）${NC}"
    ((WARN++))
fi

# ============================================================
# 9. 需要人工确认的 BIOS 设置
# ============================================================
echo -e "\n${YELLOW}【9. 需要人工确认（重启进 BIOS 查看）】${NC}"

cat << 'EOF'
  以下设置无法通过命令行检测，请在 BIOS 中人工确认：
  
  ┌─────────────────────────────────────────────────────┬───────────┐
  │ 设置项                                             │ 推荐值     │
  ├─────────────────────────────────────────────────────┼───────────┤
  │ AC Power Loss Recovery（断电恢复策略）              │ Power On  │
  │ CPU Performance Mode                               │ Maximum   │
  │ C-States                                           │ Disabled  │
  │ PCIe ASPM                                          │ Disabled  │
  │ PCIe Max Link Speed                                │ Gen5      │
  │ SNC（如检测到开启）                                │ Disabled  │
  └─────────────────────────────────────────────────────┴───────────┘
  
  进入 BIOS 方法：开机按 F1（联想） / F2（Dell） / Del（通用）
EOF

# ============================================================
# 汇总
# ============================================================
echo -e "\n${BLUE}============================================================${NC}"
echo -e "${YELLOW}汇总:${NC}"
echo -e "  警告项: ${WARN}"
echo -e "  错误项: ${FAIL}"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "${GREEN}✅ 所有可查 BIOS 设置正常${NC}"
    exit 0
elif [ "$FAIL" -eq 0 ] && [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}⚠️ 有 ${WARN} 个警告项，建议人工确认${NC}"
    exit 0
else
    echo -e "${RED}❌ 有 ${FAIL} 个错误项，请检查${NC}"
    exit 1
fi
