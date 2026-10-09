#!/bin/bash
# ============================================================
# 硬盘 SMART 验收脚本
# 【两套独立检测逻辑：NVMe 一组 | SATA+SAS 一组，混插兼容】
# 变更说明：
# 1、移除脚本自动判定硬盘是否合格，不再输出【验收通过/不通过】
# 2、每项指标增加中文说明，解释指标含义
# 3、单盘检测结束提示改为：请测试人员自行判断
# 4、保留指标FAIL/WARN颜色标记，仅作为异常提醒，不做自动结论
# 5、磁盘枚举改为「只挑物理数据盘」：排除 U 盘 / 移动硬盘盒 / 软驱 / 光驱 /
#    内存盘(zram,ram) / 回环(loop) / 网络块设备(nbd,rbd) / 远端 LUN(iscsi,fc)，
#    并打印每块盘的排除原因（规则与 fio.sh 保持一致）
# 6、NVMe/SATA 检测项各补入「通电次数」（Power Cycles / Power_Cycle_Count）：
#    判定与阈值（PWR_CYCLE_WARN，默认10000）早已实现，此前只漏在展示清单里，
#    导致该项从未输出；现接线，超阈值仅提示关注，不作合格判据
# 用法：sudo bash smart.sh
# 返回码：0（脚本正常执行完毕，不再代表硬盘全部合格）
# ============================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "【错误】必须使用 root 权限运行！"
    exit 1
fi

# 终端颜色，输出到文件自动关闭颜色
if [ -t 1 ]; then
    GREEN='\033[32m'
    YELLOW='\033[33m'
    RED='\033[31m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    RED=''
    NC=''
fi

# 通电次数（Power Cycle Count）的参考告警阈值：超过仅提示关注，不作合格判据
# 可用环境变量覆盖，例如：PWR_CYCLE_WARN=5000 sudo bash smart.sh
: "${PWR_CYCLE_WARN:=10000}"

echo -e "\n==================== 硬盘 SMART 验收检测 ===================="

# ============================================================
# 磁盘枚举：只挑「物理数据盘」（排除 U 盘 / 虚拟设备）
# ------------------------------------------------------------
# 老写法 `lsblk -d -o NAME,TYPE | grep disk | grep -v loop` 只挡了 loop，实机上两头出错：
#   误纳入：fd0 软驱（TYPE 同样是 disk）、zram/ram 内存盘、sr0 光驱、
#           USB 装机 U 盘与移动硬盘盒、iSCSI / FC 远端 LUN、nbd / rbd 网络块设备；
#   实测本机（系统跑在 USB 启动盘上）老写法会把 sda 这块 U 盘选进来自检。
# 现按 fio.sh 同一套规则逐条过滤，并打印每块盘的排除原因。
# 说明：virtio / xen 这类虚拟机的「数据盘」保留可测——它们是 VM 里真实存在的盘；
#       排除的是 loop / zram / nbd / rbd 这种没有实体的伪设备。
# 【同步维护】smart.sh / fio.sh 两处过滤规则保持一致
# ============================================================

# -------- lsblk 列能力探测 --------
# TRAN（传输总线）用于识别 USB 装机盘 / iSCSI / FC 远端盘，util-linux 2.27+ 才有；
# RO（只读）2.28+ 才有。老系统上探测失败就退回最小列集，不因缺列直接挂掉。
LSBLK_FMT="-dn -P -o NAME,TYPE,SIZE"
if lsblk -dn -P -o NAME,TYPE,TRAN,SIZE,RO >/dev/null 2>&1; then
    LSBLK_FMT="-dn -P -o NAME,TYPE,TRAN,SIZE,RO"
fi

# 明显不是物理数据盘的设备名（软驱 / 光驱 / 回环 / 内存盘 / 网络块设备）
is_name_blacklisted() {
    case "$1" in
        fd*|sr*|loop*|ram*|zram*|nbd*|rbd*) return 0 ;;
        *) return 1 ;;
    esac
}

# 走这些总线的盘一律不自检：USB 是可插拔设备（机箱上常插着装机 U 盘），
# iscsi / fc 是远端 LUN，SMART 读数与被测整机无关
is_remote_or_removable() {
    case "$1" in
        usb|iscsi|fc) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 lsblk -P 的单行键值对里取值：pval 'NAME="sda" TYPE="disk"' NAME -> sda
# 纯 bash 实现，不走管道——设备多时省掉几百个进程；只用于取不含空格的键值。
pval() {
    local kv
    for kv in $1; do
        case "$kv" in
            "${2}="*)
                kv="${kv#"${2}="}"
                kv="${kv#\"}"
                kv="${kv%\"}"
                printf '%s' "$kv"
                return 0
                ;;
        esac
    done
    return 0
}

# 内核的可移动标志（U 盘 / 移动硬盘盒）。TRAN 缺列的老板子上靠它兜底，
# 也挡得住「USB 硬盘盒桥接芯片不上报 TRAN」的情况——那类盘要走 sysfs 才认得出。
is_removable() {
    local name="$1" rm
    rm=$(cat "/sys/block/$name/removable" 2>/dev/null)
    if [ -z "$rm" ]; then
        rm=$(lsblk -dn -o RM "/dev/$name" 2>/dev/null | tr -d ' ')
    fi
    [ "$rm" = "1" ]
}

# -------- 枚举主流程：输出 DISK_LIST / SKIPPED_REPORT --------
# 用 heredoc 而非 `< <(...)` 进程替换：规避无 /dev/fd 的环境（沙箱、精简容器）报错
DISK_LIST=()
SKIPPED_REPORT=()
SKIPPED_NAMES=()

while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(pval "$line" NAME); [ -z "$name" ] && continue
    dtype=$(pval "$line" TYPE)
    tran=$(pval "$line" TRAN)
    ro=$(pval "$line" RO)

    # 先判伪设备名（loop / sr / fd / zram 等的 TYPE 五花八门，
    # 放在 TYPE 判断之前才能被统计进排除清单，不会静默消失）
    if is_name_blacklisted "$name"; then
        SKIPPED_NAMES+=("$name")
        continue
    fi
    [ "$dtype" = "disk" ] || continue

    if is_remote_or_removable "$tran"; then
        SKIPPED_REPORT+=("$name|走 ${tran} 总线（可插拔设备或远端存储）")
    elif is_removable "$name"; then
        SKIPPED_REPORT+=("$name|内核标记为可移动设备（U 盘 / 移动硬盘盒）")
    elif [ "$ro" = "1" ]; then
        SKIPPED_REPORT+=("$name|设备处于只读状态")
    else
        DISK_LIST+=("$name")
    fi
done <<EOF
$(lsblk $LSBLK_FMT 2>/dev/null)
EOF

# -------- 打印排除明细 --------
if [ ${#SKIPPED_NAMES[@]} -gt 0 ] || [ ${#SKIPPED_REPORT[@]} -gt 0 ]; then
    echo -e "${YELLOW}以下设备已被自动跳过：${NC}"
    if [ ${#SKIPPED_NAMES[@]} -gt 0 ]; then
        shown="${SKIPPED_NAMES[@]:0:8}"          # 最多列 8 个名字，其余只计数
        [ ${#SKIPPED_NAMES[@]} -gt 8 ] && shown="${shown} ..."
        printf '  %-12s %s\n' "（${#SKIPPED_NAMES[@]}个）" \
            "软驱 / 光驱 / 回环 / 内存盘 / 网络块设备，不是物理数据盘：${shown}"
    fi
    for item in "${SKIPPED_REPORT[@]}"; do
        printf '  %-12s %s\n' "${item%%|*}" "${item#*|}"
    done
    echo
fi

if [[ ${#DISK_LIST[@]} -eq 0 ]]; then
    echo -e "${RED}FAIL：未识别到任何磁盘设备${NC}"
    echo -e "${YELLOW}      可能全是 U 盘 / 虚拟设备，或被上述规则排除——如确需检测某块盘，"
    echo -e "      请显式指定：smartctl -a /dev/sdX${NC}"
    exit 1
fi

echo -e "${GREEN}自动识别到待检硬盘：${DISK_LIST[*]}${NC}"

if ! command -v smartctl &>/dev/null; then
    echo -e "${RED}错误：未找到 smartctl，请先安装 smartmontools${NC}"
    exit 1
fi

# ---------- SMART 健康状态判定（解析输出文本，不依赖 smartctl 退出码）----------
# 为什么不能用退出码：RAID 卡背后的盘、SMART 被屏蔽、USB 桥接、权限不足、NVMe 与 SCSI
# 语义不一致等场景下，smartctl 的返回码与"硬盘是否健康"没有稳定对应关系，
# 原写法 if smartctl -H ...; then OK else FAILED 会把"读不到"当成"不合格"。
# 输出：PASSED / FAILED / UNSUPPORTED / UNKNOWN
# 【同步维护】smart.sh / fio.sh 两处保持同一份实现
smart_health() {
    local dev="$1" out line
    out=$(smartctl -H "$dev" 2>&1)
    line=$(printf '%s\n' "$out" \
           | grep -iE 'overall-health self-assessment|SMART Health Status' | head -1)
    if [ -z "$line" ]; then
        # 没有健康结论行：区分"设备/链路不支持"与"smartctl 本身没跑起来"
        if printf '%s\n' "$out" | grep -qiE 'unable to detect device|device open failed|no such device|command not found|Permission denied'; then
            printf '%s' "UNKNOWN"
        else
            printf '%s' "UNSUPPORTED"
        fi
        return
    fi
    if printf '%s' "$line" | grep -qiE 'PASSED|Health Status: OK|: *OK'; then
        printf '%s' "PASSED"
    elif printf '%s' "$line" | grep -qiE 'FAILED|FAILURE'; then
        printf '%s' "FAILED"
    else
        printf '%s' "UNKNOWN"
    fi
}

# ==============================================
# 【NVMe 盘判定函数 - 独立模块】
# 入参：name=指标名称，val=指标原始值
# 作用：读取指标，输出指标说明 + 异常标记，不自动判定整盘合格
# ==============================================
check_nvme_attr() {
    local name="$1"
    local val="$2"
    local attr_fail=0  # 仅标记该项是否异常，不再用于自动判定整盘结果

    case "${name}" in
        "Critical Warning")
            # 含义：NVMe关键警告标志，由多位掩码组成，非0代表存在严重故障（介质故障、温度告警、备份空间耗尽等）
            if [[ "${val}" != "0x00" && "${val}" != "0" ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】严重警告标志非0，存在严重故障风险${NC}"
            else
                echo -e "    → ${GREEN}【正常】无严重警告${NC}"
            fi
            ;;
        "Available Spare")
            # 含义：SSD可用备用块百分比，NAND颗粒磨损后会消耗备用块，备用块越低，盘故障风险越高
            num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            if [[ ${num} -lt 10 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】备用空间低于10% (当前${num}%)，剩余备用块不足${NC}"
            else
                echo -e "    → ${GREEN}【正常】备用空间充足 (${num}%)${NC}"
            fi
            ;;
        "Percentage Used")
            # 含义：SSD寿命消耗百分比，基于写入量、颗粒磨损评估；新盘一般接近0%
            num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            if [[ ${num} -gt 10 ]]; then
                echo -e "    → ${YELLOW}【WARN】寿命使用超过10% (${num}%)，盘体已较多消耗${NC}"
            elif [[ ${num} -gt 5 ]]; then
                echo -e "    → ${YELLOW}【注意】寿命使用 ${num}%${NC}"
            else
                echo -e "    → ${GREEN}【正常】寿命使用正常 (${num}%)${NC}"
            fi
            ;;
        "Media and Data Integrity Errors")
            # 含义：介质完整性错误，NAND读写时出现无法纠正的数据错误，代表闪存存在损坏风险
            if [[ "${val}" != "0" && "${val}" != "0x0" ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】介质错误数非0 (${val})，闪存介质存在损坏风险${NC}"
            else
                echo -e "    → ${GREEN}【正常】无介质错误${NC}"
            fi
            ;;
        "Error Information Log Entries")
            # 含义：错误日志条目计数，记录盘上报的各类硬件、命令异常日志
            if [[ "${val}" != "0" && "${val}" != "0x0" ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】错误日志条目非0 (${val})，硬盘存在异常事件${NC}"
            else
                echo -e "    → ${GREEN}【正常】无错误日志${NC}"
            fi
            ;;
        "Unsafe Shutdowns")
            # 含义：非正常断电次数（掉电、强制关机，未正常下盘），频繁异常掉电会损坏SSD固件与数据
            num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            if [[ ${num} -gt 20 ]]; then
                echo -e "    → ${YELLOW}【注意】非正常断电次数较多(${num})，需核查供电稳定性${NC}"
            else
                echo -e "    → ${GREEN}【正常】非正常断电次数可接受 (${num})${NC}"
            fi
            ;;
        "Temperature")
            # 含义：硬盘当前工作温度，持续高温会加速闪存老化、触发降速
            num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            if [[ ${num} -gt 70 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】温度过高 (${num}℃)，散热异常${NC}"
            elif [[ ${num} -gt 60 ]]; then
                echo -e "    → ${YELLOW}【警告】温度偏高 (${num}℃)，建议检查散热${NC}"
            else
                echo -e "    → ${GREEN}【正常】温度正常 (${num}℃)${NC}"
            fi
            ;;
        "Power On Hours")
            # 含义：通电时长，硬盘累计上电运行小时数，仅作为盘新旧参考，不做故障判定
            # 先 tr -d ',' 去千分位再取数：smartctl 对 NVMe 会输出 "6,478" 这种带逗号的时长，
            # 直接 grep -oE '[0-9]+' | head -1 会取到 6，把跑了 6478 小时的盘显示成 6 小时
            num=$(echo "${val}" | tr -d ',' | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            echo -e "    → 通电时间 ${num} 小时（参考值，仅评估盘使用时长）"
            ;;
        "Power Cycles")
            # 含义：通电次数（NVMe 规范字段名即 Power Cycles，ATA 规范叫 Power_Cycle_Count）
            #      与"通电时长"配合可判断开关机频繁程度：次数多而时长短 = 频繁上下电。
            #      仅作参考，不作合格判据。
            # 先 tr -d ',' 去掉千分位分隔符再取数字，避免 "1,234" 被拆成 1
            num=$(echo "${val}" | tr -d ',' | grep -oE '[0-9]+' | head -1)
            num=${num:-0}
            if [[ ${num} -gt ${PWR_CYCLE_WARN} ]]; then
                echo -e "    → ${YELLOW}【注意】通电次数 ${num} 次，超过参考阈值 ${PWR_CYCLE_WARN} 次，关注盘的使用强度${NC}"
            else
                echo -e "    → 通电次数 ${num} 次（参考值，与通电时长共同评估盘使用强度与新度）"
            fi
            ;;
        *)
            echo -e "    → 参考值"
            ;;
    esac
    return ${attr_fail}
}

# ==============================================
# 【SATA / SAS 盘判定函数 - 独立模块】
# 入参：name=指标名称，val=指标原始值
# 作用：读取指标，输出指标说明 + 异常标记，不自动判定整盘合格
# ==============================================
check_sata_attr() {
    local name="$1"
    local val="$2"
    local attr_fail=0  # 仅标记该项是否异常，不再用于自动判定整盘结果

    case "${name}" in
        "Reallocated_Sector_Ct"|"Reallocated_Sector_Count")
            # 含义：重映射扇区计数，硬盘发现坏扇区后，用备用扇区替换坏扇区；>0代表已经出现坏道
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】已重映射坏块数 ${val}，硬盘存在坏扇区${NC}"
            else
                echo -e "    → ${GREEN}【正常】无重映射坏块${NC}"
            fi
            ;;
        "Current_Pending_Sector"|"Current_Pending_Sector_Count")
            # 含义：待重映射扇区，硬盘检测到不稳定扇区，等待后续读写确认是否标记为坏道
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】存在待重映射扇区 ${val}，存在潜在坏道风险，建议备份数据${NC}"
            else
                echo -e "    → ${GREEN}【正常】无待重映射扇区${NC}"
            fi
            ;;
        "Offline_Uncorrectable"|"Offline_Uncorrectable_Sector")
            # 含义：离线不可纠正扇区，硬盘后台自检发现无法读取修复的坏扇区
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】离线不可纠正坏道 ${val}，硬盘存在永久性坏扇区${NC}"
            else
                echo -e "    → ${GREEN}【正常】无离线不可纠正坏道${NC}"
            fi
            ;;
        "UDMA_CRC_Error_Count"|"UDMA_CRC_Error")
            # 含义：UDMA CRC错误，传输链路校验错误，大概率是SATA线、背板、接口接触不良，不一定是盘本体损坏
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                echo -e "    → ${YELLOW}【注意】CRC传输错误 ${val}，优先检查线缆/背板接触${NC}"
            else
                echo -e "    → ${GREEN}【正常】无CRC传输错误${NC}"
            fi
            ;;
        "Raw_Read_Error_Rate")
            # 含义：原始读取错误率，磁头读取扇区时发生的读取错误，机械盘本身会存在少量基数
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                echo -e "    → ${YELLOW}【注意】原始读取错误率 ${val}，关注磁头状态${NC}"
            else
                echo -e "    → ${GREEN}【正常】读取错误率正常${NC}"
            fi
            ;;
        "Reported_Uncorrect"|"Reported_Uncorrectable")
            # 含义：报告不可纠正错误，硬盘上报、无法修复的读写错误，存在数据丢失风险
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                attr_fail=1
                echo -e "    → ${RED}【FAIL】不可纠正错误 ${val}，存在数据丢失风险${NC}"
            else
                echo -e "    → ${GREEN}【正常】无不可纠正错误${NC}"
            fi
            ;;
        "Command_Timeout")
            # 含义：命令超时计数，硬盘无响应、命令执行超时，可能盘故障或链路不稳定
            if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                echo -e "    → ${YELLOW}【注意】命令超时 ${val}，链路或硬盘响应异常${NC}"
            else
                echo -e "    → ${GREEN}【正常】无命令超时${NC}"
            fi
            ;;
        "Power_Cycle_Count"|"Power_Cycles")
            # 含义：通电次数，硬盘累计上电次数（ATA 规范 ID 12）
            #      与"通电时长"配合可判断开关机频繁程度，仅作参考，不作合格判据
            if [[ "${val}" =~ ^[0-9]+$ ]]; then
                if [[ ${val} -gt ${PWR_CYCLE_WARN} ]]; then
                    echo -e "    → ${YELLOW}【注意】通电次数 ${val} 次，超过参考阈值 ${PWR_CYCLE_WARN} 次，关注盘的使用强度${NC}"
                else
                    echo -e "    → 通电次数 ${val} 次（参考值，与通电时长共同评估盘使用强度与新度）"
                fi
            else
                echo -e "    → 通电次数 ${val}（参考值）"
            fi
            ;;
        "Temperature_Celsius")
            # 含义：硬盘当前工作温度，高温会加速磁头、盘片老化
            if [[ "${val}" =~ ^[0-9]+$ ]]; then
                if [[ ${val} -gt 60 ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】温度过高 (${val}℃)，散热异常${NC}"
                elif [[ ${val} -gt 50 ]]; then
                    echo -e "    → ${YELLOW}【注意】温度偏高 (${val}℃)${NC}"
                else
                    echo -e "    → ${GREEN}【正常】温度正常 (${val}℃)${NC}"
                fi
            fi
            ;;
        "Power_On_Hours"|"Power_On_Hours_RAW")
            # 含义：通电时长，机械盘累计上电运行小时数，仅作为盘新旧参考，不做故障判定
            if [[ "${val}" =~ ^[0-9]+$ ]]; then
                echo -e "    → 通电时间 ${val} 小时（参考值，仅评估盘使用时长）"
            fi
            ;;
        *)
            echo -e "    → 参考值"
            ;;
    esac
    return ${attr_fail}
}

# ==============================================
# 主循环：遍历所有磁盘，自动判断盘类型，调用对应检测模块
# ==============================================
for d in "${DISK_LIST[@]}"; do
    DEV="/dev/${d}"
    CAP=$(lsblk "${DEV}" -dn -o SIZE)
    echo -e "\n======= ${DEV} （${CAP}） ======="

    # 获取盘基础信息
    INFO=$(smartctl -i "${DEV}" 2>/dev/null)
    model=$(echo "${INFO}" | grep -iE "Model Number:|Device Model:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
    serial=$(echo "${INFO}" | grep -i "Serial Number:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
    fw=$(echo "${INFO}" | grep -i "Firmware Version:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
    echo "  型号    : ${model:-未获取}"
    echo "  序列号  : ${serial:-未获取}"
    echo "  固件    : ${fw:-未获取}"

    # SMART整体健康状态（四态，本脚本不自动判定合格，仅如实呈现）
    case "$(smart_health "${DEV}")" in
        PASSED)      echo -e "  SMART状态: ${GREEN}PASSED（自检通过）${NC}" ;;
        FAILED)      echo -e "  SMART状态: ${RED}FAILED（硬盘自检不通过）${NC}" ;;
        UNSUPPORTED) echo -e "  SMART状态: ${YELLOW}不支持/不可读（被RAID卡屏蔽或设备无SMART，非硬盘故障）${NC}" ;;
        *)           echo -e "  SMART状态: ${YELLOW}未知（smartctl 执行异常）${NC}" ;;
    esac

    # ========= 识别NVMe盘：名字前缀 nvme =========
    if [[ "${d}" == nvme* ]]; then
        echo "  ========== [NVMe 盘检测模块] =========="
        DATA=$(smartctl -x "${DEV}" 2>/dev/null)
        NVME_TARGETS=(
            "Critical Warning"
            "Available Spare"
            "Percentage Used"
            "Media and Data Integrity Errors"
            "Error Information Log Entries"
            "Unsafe Shutdowns"
            "Temperature"
            "Power On Hours"
            "Power Cycles"          # 通电次数（此前只在判定函数里、没接线，故从未显示）
        )
        for target in "${NVME_TARGETS[@]}"; do
            line=$(echo "${DATA}" | grep -i "${target}" | head -1)
            if [[ -n "${line}" ]]; then
                val=$(echo "${line}" | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
                printf "    %-30s : %s\n" "${target}" "${val}"
                check_nvme_attr "${target}" "${val}"
            else
                printf "    %-30s : %s\n" "${target}" "未获取"
                echo -e "    → ${YELLOW}【警告】该字段未获取，硬盘或smartctl不支持读取该属性${NC}"
            fi
        done
    else
        echo "  ========== [SATA / SAS 盘检测模块] =========="
        DATA=$(smartctl -A "${DEV}" 2>/dev/null)
        SATA_TARGETS=(
            "Reallocated_Sector_Ct"
            "Current_Pending_Sector"
            "Offline_Uncorrectable"
            "UDMA_CRC_Error_Count"
            "Raw_Read_Error_Rate"
            "Reported_Uncorrect"
            "Command_Timeout"
            "Temperature_Celsius"
            "Power_On_Hours"
            "Power_Cycle_Count"     # 通电次数（此前只在判定函数里、没接线，故从未显示）
        )
        for target in "${SATA_TARGETS[@]}"; do
            line=$(echo "${DATA}" | grep -i "${target}" | head -1)
            if [[ -n "${line}" ]]; then
                val=$(echo "${line}" | awk '{print $NF}')
                printf "    %-30s : %s\n" "${target}" "${val}"
                check_sata_attr "${target}" "${val}"
            else
                printf "    %-30s : %s\n" "${target}" "未获取"
                echo -e "    → ${YELLOW}【警告】该属性未获取，设备可能不支持${NC}"
            fi
        done
    fi
    # 单盘末尾提示
    echo -e "  ${YELLOW}>>> 请测试人员自行判断 <<<${NC}"
done

# 全局收尾，去掉原来的全部通过/失败汇总，只提示脚本执行完毕
echo -e "\n==================== 全部检测完成 ===================="
echo "脚本执行完毕，请测试人员根据上面各项指标人工评估硬盘状态"
exit 0

