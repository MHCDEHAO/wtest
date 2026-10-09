#!/bin/bash
# ============================================================
# 服务器整机检测脚本（只做硬件预检，不采集/不巡检任何日志）
# 包含：CPU/GPU/风扇/电源/硬盘SMART/网卡/CMOS 预检、
#       驱动/CUDA版本/ECC/NVLink/内存信息检查
# 用法：sudo bash test.sh（SN 自动从 BMC FRU 读取，无需输入）
#
# 注：内核日志（dmesg）与 BMC SEL 的采集与巡检已移交 log.sh，
#     本脚本不写任何日志文件、不做日志巡检、不做 PASS/FAIL 总判定。
# ============================================================

# ========== 全局颜色定义 ==========
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# 纽扣电池电压阈值(V) —— 必须在【断开 AC 电源】后测量，CR2032 标称 3 V
#   AC 接通时 BMC 读到的约 3.3V 来自主板供电，不是电池电压，会把失效电池误判为正常
#   < BAT_LOW_VOLT            过低        FAIL
#   BAT_LOW_VOLT ~ BAT_WARN_VOLT  临界区   WARN（记录并列入更换计划）
#   BAT_WARN_VOLT ~ BAT_MAX_VOLT  正常     PASS
#   > BAT_MAX_VOLT            疑为未断 AC  WARN（提示复测，不作合格判据）
: "${BAT_LOW_VOLT:=2.7}"    # 低于此值判 FAIL
: "${BAT_WARN_VOLT:=2.9}"   # 低于此值（且 ≥ BAT_LOW_VOLT）记 WARN
: "${BAT_MAX_VOLT:=3.3}"    # 高于此值视为测量条件有误

# 风扇转速阈值环境变量
: "${FAN_MIN_RPM:=500}"
: "${FAN_MAX_RPM:=20000}"

# 硬盘通电次数（Power Cycle Count）参考告警阈值：超过仅提示关注，不作合格判据
: "${PWR_CYCLE_WARN:=10000}"

# 硬盘温度阈值(℃) —— 与 lhtest.sh 保持【同名同值】，两个脚本的口径必须一致
#   HDD（东芝欧洲 Rainer Kaese）：功能极限 60~70℃；故障率以"平均 40℃ → 年故障率 0.4%"为基准，
#        50℃→1.5 倍、55℃→2 倍、60℃→3 倍；建议 40℃ 左右、最高不超过 45℃
#   SSD（Samsung PM9A3 datasheet）：WCTEMP 80℃ / CCTEMP 83℃ / 80℃ 起降频 / 97℃ 关机，
#        Case 工作温度 0~70℃；Micron 7450 工作温度（datasheet 注明为 SMART 读数）0~+70℃
#   test.sh 的 SATA 分支不区分盘型（HDD 与 SATA-SSD 共用 Temperature_Celsius），
#   因此按更保守的 HDD 口径取值
: "${DISK_TEMP_WARN_HDD:=53}"     # 机械盘告警
: "${DISK_TEMP_ABORT_HDD:=58}"    # 机械盘判不合格
: "${DISK_TEMP_WARN_SSD:=68}"     # 固态盘告警
: "${DISK_TEMP_ABORT_SSD:=78}"    # 固态盘判不合格

# 自动化开关
: "${MIN_YEAR:=2025}"
: "${SEL_STRICT:=0}"        # =1 时 BMC SEL 的 WARN 级事件也计入失败（默认仅 FAIL 级判不合格）

# 全局标记
GLOBAL_FAIL=0
SN=""

# ========== 前置权限校验 ==========
if [ "$(id -u)" -ne 0 ]; then
    echo "【错误】请使用 root 权限运行此脚本！"
    exit 1
fi

# ========== 依赖工具预检 + 自动安装 ==========
check_deps_preview() {
    echo "============================================================"
    echo "  依赖工具预检 & 自动安装"
    echo "------------------------------------------------------------"

    declare -A pkg_map
    pkg_map["lspci"]="pciutils"
    pkg_map["ipmitool"]="ipmitool"
    pkg_map["smartctl"]="smartmontools"
    pkg_map["dmesg"]="util-linux"
    pkg_map["findmnt"]="util-linux"
    pkg_map["lsblk"]="util-linux"
    # rasdaemon：把 EDAC 的 mc/csrow 编号翻译成主板丝印（DIMM_A2 这种），
    # 提供 --register-labels / --layout / --errors 三个命令。
    # 缺失时降级为「只读 sysfs 计数器」，不阻断流程。
    pkg_map["ras-mc-ctl"]="rasdaemon"

    local skip_auto=("nvidia-smi")
    local deps=("lspci" "findmnt" "lsblk" "ipmitool" "smartctl" "nvidia-smi" "dmesg" "ras-mc-ctl")
    local missing=()
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
            if [[ ! " ${skip_auto[*]} " =~ " ${dep} " ]]; then
                to_install+=("${pkg_map[${dep}]}")
            fi
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "  [INFO] 所有核心依赖工具均已就绪"
        echo "============================================================"
        echo ""
        return
    fi

    echo "  [WARN] 以下工具未安装："
    echo "        ${missing[*]}"
    echo ""

    PKG_MGR=""
    if command -v apt &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    fi

    if [ ${#to_install[@]} -gt 0 ] && [ -n "${PKG_MGR}" ]; then
        echo "  [INFO] 检测到包管理器：${PKG_MGR}，正在自动安装基础依赖..."
        echo "  待安装包：${to_install[*]}"
        if [ "${PKG_MGR}" = "yum" ] || [ "${PKG_MGR}" = "dnf" ]; then
            ${PKG_MGR} install -y epel-release >/dev/null 2>&1
        fi
        if [ "${PKG_MGR}" = "apt" ]; then
            apt update -y >/dev/null 2>&1
            apt install -y "${to_install[@]}" >/dev/null 2>&1
        else
            ${PKG_MGR} install -y "${to_install[@]}" >/dev/null 2>&1
        fi

        local install_fail=()
        for dep in "${!pkg_map[@]}"; do
            if ! command -v "${dep}" &>/dev/null; then
                install_fail+=("${dep}")
            fi
        done

        if [ ${#install_fail[@]} -gt 0 ]; then
            echo "  [WARN] 以下工具自动安装失败，对应测试项将跳过："
            echo "        ${install_fail[*]}"
        else
            echo "  [INFO] 所有基础依赖均已安装完成"
        fi
    else
        echo "  [INFO] 无可自动安装的基础依赖包，对应测试项将自动跳过"
    fi

    if [[ " ${missing[*]} " =~ " nvidia-smi " ]]; then
        echo ""
        echo "  [INFO] nvidia-smi 需手动安装 NVIDIA 显卡驱动，GPU 相关测试项将跳过"
    fi

    echo "============================================================"
    echo ""
}

# rasdaemon 服务保障（独立于 check_deps_preview —— 那个函数在「依赖齐全」时会提前 return，
# 服务启动逻辑写在里面会被跳过）。包可能刚被装上，但 daemon 默认不随包启动；
# 不起服务就拿不到 --errors 的历史记录（--register-labels / --layout 读 sysfs，不受影响）。
ensure_rasdaemon_service(){
    command -v ras-mc-ctl &>/dev/null || return 0
    command -v systemctl &>/dev/null || return 0
    systemctl is-active --quiet rasdaemon 2>/dev/null && return 0
    echo "  [INFO] 检测到 rasdaemon 未运行，尝试启动服务..."
    if systemctl enable --now rasdaemon >/dev/null 2>&1; then
        echo "  [INFO] rasdaemon 服务已启动"
    else
        echo "  [WARN] rasdaemon 服务启动失败，内存错误定位将退化为只读 sysfs 计数器"
    fi
}
check_deps_preview
ensure_rasdaemon_service

# ===================== 系统与BMC时间双重拦截（永不中断） =====================
time_precheck() {
    echo ""
    echo "============================================================"
    echo "  [初始时间预检] 正在验证系统时间和 BMC 硬件时钟..."
    echo "------------------------------------------------------------"

    SYS_YEAR=$(date +%Y)
    if [ "${SYS_YEAR}" -lt "${MIN_YEAR}" ]; then
        echo "【严重错误】系统时间发生严重回退（${SYS_YEAR} < ${MIN_YEAR}）！"
        echo "   建议手动校准时间，但脚本将继续执行。"
        GLOBAL_FAIL=1
    fi

    SYS_DATE=$(date "+%Y-%m-%d %H:%M:%S")
    echo "  [系统时间]  已读取: ${SYS_DATE} (年份正常)"

    BMC_VALID=0
    BMC_DATE=""
    if command -v ipmitool &>/dev/null; then
        BMC_TIME_RAW=$(ipmitool sel time get 2>/dev/null)
        if [[ -n "${BMC_TIME_RAW}" ]]; then
            BMC_TS=$(date -d "${BMC_TIME_RAW}" +%s 2>/dev/null)
            if [[ -n "${BMC_TS}" && "${BMC_TS}" =~ ^[0-9]+$ ]]; then
                BMC_YEAR=$(date -d "@${BMC_TS}" +"%Y")
                BMC_DATE=$(date -d "@${BMC_TS}" +"%Y-%m-%d %H:%M:%S")
                if [ "${BMC_YEAR}" -ge "${MIN_YEAR}" ]; then
                    BMC_VALID=1
                    echo "  [BMC 时间]  已读取: ${BMC_DATE} (年份正常)"
                else
                    echo "  [BMC 时间]  读取成功，但年份异常 (${BMC_YEAR} < ${MIN_YEAR})，已跳过 BMC 对比。"
                fi
            else
                echo "  [BMC 时间]  无法解析 BMC 时间格式，跳过 BMC 对比。"
            fi
        else
            echo "  [BMC 时间]  未能读取到 BMC 时间，跳过 BMC 对比。"
        fi
    else
        echo "  [BMC 时间]  未检测到 ipmitool 命令，跳过 BMC 对比。"
    fi

    if [ "${BMC_VALID}" -eq 1 ]; then
        SYS_TS=$(date +%s)
        OFFSET=$(( SYS_TS - BMC_TS ))
        ABS_OFFSET=$(awk -v off="${OFFSET}" 'BEGIN{if(off<0) off=-off; print off}')
        echo "  [偏差比对]  系统与 BMC 时间偏差为: ${ABS_OFFSET} 秒"

        if [ "${ABS_OFFSET}" -gt 60 ]; then
            echo "【严重错误】系统时间与 BMC 时间偏差超过 1分钟，建议校准，但脚本将继续执行。"
            GLOBAL_FAIL=1
        else
            echo "  [偏差比对]  系统与 BMC 时间偏差在1分钟内，通过！"
        fi
    else
        echo "  [最终判定]  系统时间年份正常，无 BMC 依赖，校验通过。"
    fi

    echo "============================================================"
    echo ""
}
time_precheck

# ========== SN：自动从 BMC FRU 读取（不再交互输入） ==========
#   check_system_fru 用 ipmitool fru 读出整机序列号后回填 SN，报告头直接引用。
#   读不到时保持为空，显示为「未读到」。故此处不再需要输入函数。

# ========== 日志功能已全部移除（采集 + 巡检）==========
#   历史：台账目录 <SN>test1.log/、main.log/dmesg.log/sel.log 落盘，
#   dmesg -C、dmesg -w 后台跟采、ipmitool sel clear，以及 dmesg/SEL 巡检，
#   以上全部删除。会话级记录与内核/SEL 巡检统一由 log.sh 负责。
# ========== 异常退出清理函数 ==========
cleanup(){
    echo -e "\n[CLEANUP] 收到终止信号，清理临时文件"
    rm -rf pcinfo.txt pcinfo1.txt net.txt block.txt
    # 计数器快照（中断时主流程末尾的 rm 走不到，这里兜底）
    rm -f /tmp/hwcounter_before_$$.log /tmp/hwcounter_after_$$.log
}
# ★ 三条分开写：把 INT/TERM 塞进 EXIT 那条 trap 会吞掉信号 ——
#   脚本不终止反而继续跑完并 exit 0（§3.28 实测）。lhtest.sh 已是此写法。
#   130 = 128+SIGINT(2)，143 = 128+SIGTERM(15)，均触发 EXIT trap 跑 cleanup
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# ========== PCIe设备打印函数 ==========
sl(){
    lspci -D > pcinfo.txt
    lspci -D -vvv > pcinfo1.txt
    ls -l /sys/class/net | grep -v virtual > net.txt
    ls -l /sys/class/block | grep -v virtual > block.txt
    l=${m:-1}
    p=(Mellanox Co-processor VGA nvidia SAS Eth Fibre Non-Volatile)

    for o in "${p[@]}"
    do
        n=$(grep -i "${o}" pcinfo.txt | grep -vc "ASPEED")
        if [ "${n}" -eq 0 ];then
            continue
        fi
        echo ""
        echo -e "${o}\t${n}"
        y=1

        while IFS= read -r dev_bdf; do
            [ -z "${dev_bdf}" ] && continue
            ID1=$(cat /sys/bus/pci/devices/"${dev_bdf}"/vendor 2>/dev/null | awk -F"0x" '{print $2}')
            ID2=$(cat /sys/bus/pci/devices/"${dev_bdf}"/device 2>/dev/null | awk -F"0x" '{print $2}')
            ID3=$(cat /sys/bus/pci/devices/"${dev_bdf}"/subsystem_vendor 2>/dev/null | awk -F"0x" '{print $2}')
            ID4=$(cat /sys/bus/pci/devices/"${dev_bdf}"/subsystem_device 2>/dev/null | awk -F"0x" '{print $2}')
            ID1=${ID1:-0000};ID2=${ID2:-0000};ID3=${ID3:-0000};ID4=${ID4:-0000}

            name=$(grep "^${dev_bdf}" pcinfo.txt | cut -d: -f3- | sed -e 's/^[ ]*//' -e 's/[ ]*$//')
            name=${name:-Unknown}

            local lnkcap lnksta
            lnkcap=$(grep "^${dev_bdf}" -A 40 pcinfo1.txt 2>/dev/null | grep "LnkCap:" | head -n1)
            lnksta=$(grep "^${dev_bdf}" -A 40 pcinfo1.txt 2>/dev/null | grep "LnkSta:" | head -n1)

            local cap_speed cap_width sta_speed sta_width
            cap_speed=$(echo "${lnkcap}" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}' | head -n1)
            cap_width=$(echo "${lnkcap}" | grep -oE 'Width x[0-9]+' | awk '{print $2}' | head -n1)
            sta_speed=$(echo "${lnksta}" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}' | head -n1)
            sta_width=$(echo "${lnksta}" | grep -oE 'Width x[0-9]+' | awk '{print $2}' | head -n1)

            cap_speed=${cap_speed:-未知}
            cap_width=${cap_width:-未知}
            sta_speed=${sta_speed:-未知}
            sta_width=${sta_width:-未知}

            local speed_note width_note
            if [ "${cap_speed}" = "${sta_speed}" ] && [ "${cap_speed}" != "未知" ];then
                speed_note="正常"
            else
                speed_note="警告：速率不匹配"
            fi
            if [ "${cap_width}" = "${sta_width}" ] && [ "${cap_width}" != "未知" ];then
                width_note="正常"
            else
                width_note="警告：宽度不匹配"
            fi

            SW="[${dev_bdf} ${name}  能力:${cap_speed} ${cap_width} | 当前:${sta_speed} ${sta_width} | ${speed_note} ${width_note}]"

            if [ "${n}" -lt "${l}" ];then
                echo -en "\t${SW}"
            else
                if [ $(( y % l )) -ne 0 ];then
                    echo -en "\t${SW}"
                else
                    echo -e "\t${SW}"
                fi
            fi
            y=$((y+1))
        done < <(grep -i "${o}" pcinfo.txt | grep -vi "ASPEED" | awk '{print $1}')

        y=1
    done
    echo ""
    rm -rf pcinfo.txt pcinfo1.txt net.txt block.txt
}

# ============================================================
# 硬件检测函数
# ============================================================

# ========== 整机 FRU 信息（型号/序列号，供验收记录表填写）==========
# 读 ipmitool fru 里的非 PSU 段（整机/主板/机箱），并把人工录入的 SN 拿来做一致性比对。
# PSU 的 FRU 由 check_power_supply 单独处理，这里排除，避免重复。
check_system_fru(){
    echo -e "\n【1.1 整机FRU信息】"
    if ! command -v ipmitool &>/dev/null;then
        echo "WARN: ipmitool不存在，跳过整机FRU读取"
        return
    fi

    fru_raw=$(ipmitool fru 2>/dev/null)
    if [ -z "${fru_raw}" ];then
        echo "WARN: 未读到任何FRU信息（BMC可能未写入或不支持ipmitool fru）"
        return
    fi

    # 字段优先级：Product 段 > Board 段。整机身份以 Product 段为准
    local SYS_MODEL SYS_SN a b fru_out
    # 注意：FRU 里 Board 段排在 Product 段之前，用 "!m"（首个非空即锁定）会被低优先级的
    # Board 字段抢占。必须用优先级变量，让 Product 段无论先后都能覆盖。
    SYS_MODEL=$(printf '%s\n' "${fru_raw}" | awk '
        tolower($0) ~ /fru device description/ { hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1; next }
        hit && tolower($0) ~ /^ *product name *:/ { v=$0; sub(/^[^:]*:[ ]*/, "", v); m=v; pri=2 }
        hit && tolower($0) ~ /^ *board product *:/ && pri < 2 { v=$0; sub(/^[^:]*:[ ]*/, "", v); m=v; pri=1 }
        END { print m }')
    SYS_SN=$(printf '%s\n' "${fru_raw}" | awk '
        tolower($0) ~ /fru device description/ { hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1; next }
        hit && tolower($0) ~ /^ *product serial *:/ { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=2 }
        hit && tolower($0) ~ /^ *chassis serial *:/ && spri < 2 { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=1 }
        hit && tolower($0) ~ /^ *board serial *:/ && spri < 1 { v=$0; sub(/^[^:]*:[ ]*/, "", v); s=v; spri=0 }
        END { print s }')

    if [ -n "${SYS_MODEL}" ];then
        echo "整机型号:    ${SYS_MODEL}"
    else
        echo "整机型号:    未读到（FRU中无 Product Name / Board Product，需查看机箱铭牌）"
    fi
    if [ -n "${SYS_SN}" ];then
        echo "整机序列号:  ${SYS_SN}"
    else
        echo "整机序列号:  未读到（FRU中无 Serial 字段，需查看机箱铭牌）"
    fi

    # SN 不再人工录入：直接用 BMC FRU 读到的整机序列号作为本次测试的 SN，
    # 供后续报告头引用。FRU 读不到时保持为空（报告显示「未读到」）。
    if [ -n "${SYS_SN}" ] && [ -z "${SN}" ];then
        SN="${SYS_SN}"
    fi

    # 完整 FRU 明细（排除 PSU 段）
    fru_out=$(printf '%s\n' "${fru_raw}" | awk '
        tolower($0) ~ /fru device description/ {
            hit = (tolower($0) ~ /psu|power supply/) ? 0 : 1
            if (hit) { n=$0; sub(/^[^:]*:[ ]*/, "", n); if (++c > 1) print ""; print "  [" n "]" }
            next
        }
        hit && tolower($0) ~ /(chassis|board|product)[ ]*(type|mfg date|mfg|manufacturer|product|name|part number|serial|version|asset tag|extra|custom)/ {
            l=$0; sub(/^[ ]+/, "", l); print "    " l
        }')
    if [ -n "${fru_out}" ];then
        echo "整机FRU明细:"
        echo "${fru_out}"
    fi
}

# ========== CPU物理颗数解析增加fallback ==========
check_cpu(){
    echo -e "\n【1.2 CPU在位检测】"
    
    CPU_PHYSICAL=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)
    if [ "${CPU_PHYSICAL}" -eq 0 ] || [ -z "${CPU_PHYSICAL}" ]; then
        if [ -d "/sys/devices/system/cpu" ]; then
            CPU_SOCKETS=$(ls -d /sys/devices/system/cpu/cpu*/topology/physical_package_id 2>/dev/null | xargs cat 2>/dev/null | sort -u | wc -l)
            if [ -n "${CPU_SOCKETS}" ] && [ "${CPU_SOCKETS}" -gt 0 ]; then
                CPU_PHYSICAL="${CPU_SOCKETS}"
            else
                if command -v lscpu &>/dev/null; then
                    CPU_PHYSICAL=$(lscpu 2>/dev/null | grep -E "^Socket\(s\):" | awk '{print $2}')
                    [ -z "${CPU_PHYSICAL}" ] && CPU_PHYSICAL=0
                fi
            fi
        fi
    fi
    
    CPU_CORE=$(grep -c '^processor' /proc/cpuinfo)
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
    echo "CPU型号:${CPU_MODEL}"
    echo "物理CPU颗数:${CPU_PHYSICAL}"
    echo "逻辑CPU数量:${CPU_CORE}"
    if [ "${CPU_PHYSICAL}" -lt 1 ];then
        echo "FAIL：未识别到CPU"
        GLOBAL_FAIL=1
    else
        echo "CPU在位检测 PASS"
    fi
}

# ========== GPU检测 ==========
check_gpu_present(){
    echo -e "\n【1.3 GPU显卡在位检测】"
    local pci_gpu_cnt
    # 类别不能只认 VGA / 3D controller：部分固件把数据中心卡报成
    # "Processing accelerators"，漏掉会让下面"有卡但驱动异常"的判断失效
    pci_gpu_cnt=$(lspci 2>/dev/null | grep -i "nvidia" \
                  | grep -iE "VGA|3D controller|Processing accelerator" | wc -l)
    local gpu_valid=0

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi &>/dev/null; then
            gpu_valid=${pci_gpu_cnt}
            echo "识别有效NVIDIA GPU数量: ${gpu_valid}"
            nvidia-smi -L 2>/dev/null || echo "  [WARN] nvidia-smi -L 执行失败"
            echo "GPU在位检测 PASS"
        else
            echo "WARN：NVIDIA驱动存在但显卡异常（nvidia-smi 无法正常执行）"
            if [ "${pci_gpu_cnt}" -gt 0 ]; then
                echo "  物理PCIe层识别到 ${pci_gpu_cnt} 张NVIDIA显卡，但驱动无法通信"
                GLOBAL_FAIL=1
            fi
        fi
    else
        if [ "${pci_gpu_cnt}" -gt 0 ]; then
            echo "WARN：检测到NVIDIA物理显卡，但未安装驱动，跳过GPU压测项"
        else
            echo "未检测到NVIDIA显卡硬件，跳过GPU相关检测"
        fi
    fi
}

# ========== 驱动和CUDA版本检查 ==========
check_nvidia_version(){
    echo -e "\n【1.3.1 NVIDIA驱动与CUDA版本】"
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        # 表头行末尾是 "|"（表格右边界），awk '{print $NF}' 取到的是它而不是版本号，
        # 必须按字段名抽数字
        CUDA_VER=$(nvidia-smi 2>/dev/null | grep "CUDA Version" \
                   | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)
        echo "  驱动版本: ${DRIVER_VER:-未获取}"
        echo "  CUDA版本: ${CUDA_VER:-未获取}"
    else
        echo "  nvidia-smi 不可用，无法获取驱动/CUDA版本"
    fi
}

# ========== ECC状态检查 ==========
check_ecc(){
    echo -e "\n【1.3.2 GPU ECC状态】"
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        ECC_MODE=$(nvidia-smi -q | grep -A2 "ECC Mode" | grep -E "Current|Pending" | sed 's/^[ ]*//' | head -2)
        if [ -n "$ECC_MODE" ]; then
            echo "$ECC_MODE"
        else
            echo "  ECC信息未获取（可能GPU不支持ECC）"
        fi
        ECC_ERRORS=$(nvidia-smi -q | grep -A5 "ECC Errors" | grep -E "Single Bit|Double Bit" | sed 's/^[ ]*//')
        if [ -n "$ECC_ERRORS" ]; then
            echo "  ECC错误计数:"
            echo "$ECC_ERRORS"
        fi
    else
        echo "  nvidia-smi 不可用，跳过ECC检查"
    fi
}

# ========== 显卡 VBIOS / 型号 / 序列号 一致性核对 ==========
# 目的：8 卡模组交付时，型号 / VBIOS / 序列号必须同批一致，不一致即混批，须换件。
# 槽位：取自 PCIe 总线地址（pci.bus_id，形如 00000000:01:00.0），
#       用于把判定结果对应到机箱里的物理位置，便于换件时定位。
# 说明：nvidia-smi 的 serial 在消费卡上返回 [N/A]，属正常，不计入混批。
check_gpu_vbios(){
    echo -e "\n【1.3.3 显卡 VBIOS 与型号一致性】"
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
        echo "  nvidia-smi 不可用，跳过显卡 VBIOS 核对"
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
        echo "  ${YELLOW}[WARN]${NC} 未取到 VBIOS 信息（本版驱动可能不支持该字段），本项 Pending"
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
        echo "  ${YELLOW}[WARN]${NC} 本版驱动读不到 PCIe 槽位，已省略该列"
    fi
    printf '%s\n' "${raw}" | sed 's/^/    /'

    if [ "${gpu_cnt}" -le 1 ]; then
        echo "  ${BLUE}[INFO]${NC} 单卡机型，无一致性可比对"
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
        echo "  ${RED}[FAIL]${NC} VBIOS 版本不一致，共 ${vbios_uniq} 种："
        printf '%s\n' "${raw}" | awk -F',' -v n="${C_VBIOS}" '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}' \
            | sort | uniq -c | sed 's/^/         /'
        bad=1
    else
        echo "  ${GREEN}[OK]${NC} VBIOS 版本一致"
    fi

    if [ "${name_uniq}" -gt 1 ]; then
        echo "  ${RED}[FAIL]${NC} 显卡型号不一致，共 ${name_uniq} 种"
        bad=1
    else
        echo "  ${GREEN}[OK]${NC} 显卡型号一致"
    fi

    if [ "${serial_uniq}" -eq 0 ]; then
        echo "  ${YELLOW}[WARN]${NC} 序列号不可读（消费卡常见），跳过序列号核对"
    elif [ "${serial_uniq}" -lt "${gpu_cnt}" ]; then
        echo "  ${RED}[FAIL]${NC} 序列号重复：仅 ${serial_uniq} 个唯一值 / 共 ${gpu_cnt} 张卡"
        bad=1
    else
        echo "  ${GREEN}[OK]${NC} 序列号唯一且完整（${serial_uniq} 个）"
    fi

    if [ "${bad}" -eq 1 ]; then
        GLOBAL_FAIL=1
        echo "  ${RED}>>> 显卡混批：换件后须重跑全部对应项 <<<${NC}"
    fi
}

# ========== NVLink拓扑显示（人工判定） ==========
show_nvlink_topology(){
    echo -e "\n【1.3.4 NVLink拓扑（请人工判定是否正常）】"
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        nvidia-smi topo -m 2>/dev/null | head -20
        echo -e "  ${YELLOW}>>> 请人工确认所有GPU之间互联状态（NVLink/PCIe）<<<${NC}"
    else
        echo "  nvidia-smi 不可用，跳过NVLink拓扑"
    fi
}

# ========== 内存信息检查（精准解析版，整合自mem.sh） ==========
check_memory_info(){
    echo -e "\n【1.4 内存条信息】"
    if ! command -v dmidecode &>/dev/null; then
        echo "  dmidecode 未安装，跳过内存信息检查"
        return
    fi

    echo "  内存条列表:"
    DEBUG=0   # 调试开关：设为1可输出调试信息到stderr
    dmidecode -t 17 2>/dev/null | awk -v debug="$DEBUG" '
    BEGIN {
        total_mb = 0
        count = 0
        in_handle = 0
        size = ""; type = ""; max_speed = ""; current_speed = ""; voltage = ""; sn = ""; slot = ""
    }
    /^Handle 0x/ {
        if (debug) print "DEBUG: Found Handle" > "/dev/stderr"
        # 处理上一个 handle
        if (in_handle && size != "" && size !~ /No Module/ && size !~ /None/) {
            # 计算容量
            if (size ~ /GB/) {
                gsub(/ GB/, "", size)
                total = size * 1024
                display_size = size " GB"
            } else if (size ~ /MB/) {
                gsub(/ MB/, "", size)
                total = size
                display_size = size " MB"
            } else {
                total = 0
                display_size = size
            }
            if (current_speed == "" || current_speed == "Unknown" || current_speed == "Not Specified")
                current_speed = "N/A"
            if (max_speed == "" || max_speed == "Unknown" || max_speed == "Not Specified")
                max_speed = "N/A"
            if (slot == "") slot = "N/A"
            if (voltage == "") voltage = "N/A"
            if (sn == "" || sn == "Not Specified" || sn == "[Empty]") sn = "无"
            printf "  槽位: %s | 单条容量: %s | 类型: %s | 最大支持频率: %s | 当前频率: %s | 电压: %s | SN: %s\n", slot, display_size, type, max_speed, current_speed, voltage, sn
            total_mb += total
            count++
        }
        # 重置变量
        size = ""; type = ""; max_speed = ""; current_speed = ""; voltage = ""; sn = ""; slot = ""
        in_handle = 1
        next
    }
    in_handle {
        # 提取字段（使用更精确的匹配）
        if ($0 ~ /^[[:space:]]*Size:/ && $0 !~ /Logical Size/) {
            sub(/^[[:space:]]*Size:[[:space:]]*/, "")
            size = $0
            gsub(/[[:space:]]+$/, "", size)
            if (debug) print "DEBUG: size = " size > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Type:/ && $0 !~ /Type Detail/) {
            sub(/^[[:space:]]*Type:[[:space:]]*/, "")
            type = $0
            gsub(/[[:space:]]+$/, "", type)
            if (debug) print "DEBUG: type = " type > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Locator:/) {
            sub(/^[[:space:]]*Locator:[[:space:]]*/, "")
            slot = $0
            gsub(/[[:space:]]+$/, "", slot)
            if (debug) print "DEBUG: slot = " slot > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Speed:/ && $0 !~ /Configured/ && $0 !~ /Max/) {
            sub(/^[[:space:]]*Speed:[[:space:]]*/, "")
            max_speed = $0
            gsub(/[[:space:]]+$/, "", max_speed)
            gsub(/ MT\/s/, "", max_speed)
            if (debug) print "DEBUG: max_speed = " max_speed > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Configured Memory Speed:/) {
            sub(/^[[:space:]]*Configured Memory Speed:[[:space:]]*/, "")
            current_speed = $0
            gsub(/[[:space:]]+$/, "", current_speed)
            gsub(/ MT\/s/, "", current_speed)
            if (debug) print "DEBUG: current_speed = " current_speed > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Configured Voltage:/) {
            sub(/^[[:space:]]*Configured Voltage:[[:space:]]*/, "")
            voltage = $0
            gsub(/[[:space:]]+$/, "", voltage)
            if (debug) print "DEBUG: voltage = " voltage > "/dev/stderr"
        }
        else if ($0 ~ /^[[:space:]]*Serial Number:/) {
            sub(/^[[:space:]]*Serial Number:[[:space:]]*/, "")
            sn = $0
            gsub(/[[:space:]]+$/, "", sn)
            if (debug) print "DEBUG: sn = " sn > "/dev/stderr"
        }
    }
    END {
        # 处理最后一个 handle
        if (in_handle && size != "" && size !~ /No Module/ && size !~ /None/) {
            if (size ~ /GB/) {
                gsub(/ GB/, "", size)
                total = size * 1024
                display_size = size " GB"
            } else if (size ~ /MB/) {
                gsub(/ MB/, "", size)
                total = size
                display_size = size " MB"
            } else {
                total = 0
                display_size = size
            }
            if (current_speed == "" || current_speed == "Unknown" || current_speed == "Not Specified")
                current_speed = "N/A"
            if (max_speed == "" || max_speed == "Unknown" || max_speed == "Not Specified")
                max_speed = "N/A"
            if (slot == "") slot = "N/A"
            if (voltage == "") voltage = "N/A"
            if (sn == "" || sn == "Not Specified" || sn == "[Empty]") sn = "无"
            printf "  槽位: %s | 单条容量: %s | 类型: %s | 最大支持频率: %s | 当前频率: %s | 电压: %s | SN: %s\n", slot, display_size, type, max_speed, current_speed, voltage, sn
            total_mb += total
            count++
        }
        # 输出汇总信息
        if (count > 0) {
            printf "\n  内存条数: %d 条\n", count
            total_gb = total_mb / 1024
            printf "  总容量: %.2f GB (%d MB)\n", total_gb, total_mb
        } else {
            printf "未识别到任何已安装的内存条\n"
        }
    }'
    echo ""
}

# ========== 风扇转速阈值使用环境变量 ==========
check_fan(){
    echo -e "\n【1.5 风扇信息检测】"
    if ! command -v ipmitool &>/dev/null; then
        echo "ipmitool不存在，跳过风扇检测"
        return
    fi

    FAN_RAW=$(ipmitool sdr type Fan 2>/dev/null)
    if [ -z "${FAN_RAW}" ]; then
        echo "WARN: 未获取到风扇传感器数据"
        return
    fi

    echo "${FAN_RAW}"
    echo ""

    local fan_fail=0
    local valid_count=0
    local unk_count=0
    # ipmitool sdr 的列数/列序随固件版本不同会变，实测至少两种：
    #   3 列：FAN1 | 5100 RPM | ok
    #   5 列：FAN1 | 30h | ok | 7.1 | 5100 RPM
    # 写死 $2（读数）/ $NF（状态）在另一种布局下必然张冠李戴
    # （把传感器 ID 当转速、把转速当状态，状态异常就此漏判），
    # 所以这里不认列号、只认内容语义。
    local SDR_ST_RE='^(ok|ns|na|nc|cr|nr|unr|lcr|lnc|lnr|unc|uc|no reading|not reading|disabled|not present|not installed|device absent|device not present|absent|unknown|n/a|fail|failed|failure|fault|faulty|error|critical|non-critical|non critical|non-recoverable|non recoverable|predictive failure|degraded|insufficient|presence detected|presence not detected|state asserted|state deasserted|asserted|deasserted|redundancy lost|fully redundant)$'
    local name="" reading="" status="" f i
    local -a F

    while IFS= read -r line; do
        # ---- 按 | 切分，逐段去首尾空白 ----
        F=()
        IFS='|' read -r -a F <<< "$line"
        for ((i=0; i<${#F[@]}; i++)); do
            f="${F[i]}"
            f="${f#"${f%%[![:space:]]*}"}"
            f="${f%"${f##*[![:space:]]}"}"
            F[i]="$f"
        done

        name="${F[0]}"
        [ -z "$name" ] && continue

        # ---- 语义认列：状态列认状态词，读数列认「含数字且不像 ID/实体号」----
        reading=""; status=""
        for ((i=1; i<${#F[@]}; i++)); do
            f="${F[i]}"
            [ -z "$f" ] && continue
            if [ -z "$status" ] && echo "$f" | grep -qiE "${SDR_ST_RE}"; then
                status="$f"
                continue
            fi
            if [ -z "$reading" ] \
               && echo "$f" | grep -qE '[0-9]' \
               && ! echo "$f" | grep -qE '^([0-9A-Fa-f]{1,2}h|0x[0-9A-Fa-f]+|[0-9]+\.[0-9]+)$'; then
                reading="$f"
                continue
            fi
        done

        if echo "$status" | grep -qiE "not present|fail|error|fault|unknown"; then
            echo -e "  ${name} : ${reading} | ${status}   ${RED}【FAIL】状态异常${NC}"
            fan_fail=1
            continue
        fi

        if echo "$reading" | grep -qiE "no reading|disabled|unknown"; then
            echo -e "  ${name} : ${reading} | ${status}   ${YELLOW}【WARN】无有效转速${NC}"
            continue
        fi

        speed=$(echo "$reading" | grep -oE '[0-9]+' | head -1)
        if [ -n "$speed" ]; then
            valid_count=$((valid_count + 1))
            if [ "$speed" -lt "${FAN_MIN_RPM}" ] || [ "$speed" -gt "${FAN_MAX_RPM}" ]; then
                echo -e "  ${name} : ${reading} | ${status}   ${YELLOW}【WARN】转速异常 (${speed} RPM，正常范围 ${FAN_MIN_RPM}-${FAN_MAX_RPM})${NC}"
            else
                echo -e "  ${name} : ${reading} | ${status}   ${GREEN}【OK】${NC}"
            fi
        else
            unk_count=$((unk_count + 1))
            if [ -z "$status" ]; then
                # 列布局不认识：转速和状态都没认出来，不能当作通过
                echo -e "  ${name} : ${reading} | ${status}   ${RED}【FAIL】转速与状态均无法识别（ipmitool sdr 列布局未知）${NC}"
            else
                echo -e "  ${name} : ${reading} | ${status}   ${YELLOW}【WARN】状态未识别，无法确认是否正常${NC}"
            fi
        fi
    done <<< "${FAN_RAW}"

    echo ""
    echo "有效风扇数量: ${valid_count}"

    if [ ${valid_count} -eq 0 ]; then
        echo "WARN：未读到任何有效风扇转速，请确认BMC"
    fi

    if [ ${fan_fail} -ne 0 ]; then
        echo "FAIL：检测到风扇状态异常"
        GLOBAL_FAIL=1
    elif [ ${unk_count} -ne 0 ]; then
        echo "FAIL：有 ${unk_count} 个风扇的转速/状态无法识别，不能确认其是否正常"
        GLOBAL_FAIL=1
    else
        echo "风扇检测完成"
    fi
}

# ========== 电源状态区分“不在位”和“故障” ==========
check_power_supply(){
    echo -e "\n【1.6 电源在位&功率检测】"
    if ! command -v ipmitool &>/dev/null;then
        echo "WARN: ipmitool不存在，跳过电源检测"
        return
    fi

    # 冗余传感器（常见名 "PSU Redundancy"）单独归类：
    # 旧写法把它一起 grep 进 PS_LIST，会在「电源模块状态」下冒出一条 Redundancy，语义不对
    PS_LIST=$(ipmitool sdr 2>/dev/null | grep -iE "power supply|psu" | grep -viE "redundan" | grep -v "no reading")
    RED_LIST=$(ipmitool sdr 2>/dev/null | grep -iE "redundan" | grep -v "no reading")
    if [ -z "${PS_LIST}" ] && [ -z "${RED_LIST}" ];then
        echo "WARN: 未识别到电源传感器信息"
    else
        local power_fail=0
        [ -n "${PS_LIST}" ] && echo "电源模块状态:"
        while IFS= read -r line; do
            ps_name=$(echo "${line}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
            ps_status=$(echo "${line}" | awk -F'|' '{print $NF}' | sed 's/^[ ]*//;s/[ ]*$//')
            
            if echo "${ps_status}" | grep -qi "not present"; then
                echo -e "  ${ps_name} : ${ps_status}   ${YELLOW}【WARN】电源模块不在位${NC}"
            elif echo "${ps_status}" | grep -qi "fail\|error\|fault\|warn"; then
                echo -e "  ${ps_name} : ${ps_status}   ${RED}【FAIL】电源模块状态异常${NC}"
                power_fail=1
            else
                echo -e "  ${ps_name} : ${ps_status}   ${GREEN}【OK】${NC}"
            fi
        done <<< "${PS_LIST}"

        # ---- 电源冗余：状态文本是 IPMI 标准冗余语义，单独解读 ----
        if [ -n "${RED_LIST}" ];then
            echo "电源冗余状态:"
            while IFS= read -r line; do
                r_name=$(echo "${line}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
                r_status=$(echo "${line}" | awk -F'|' '{print $NF}' | sed 's/^[ ]*//;s/[ ]*$//')
                if echo "${r_status}" | grep -qiE "redundancy lost|insufficient|failure|failed"; then
                    echo -e "  ${r_name} : ${r_status}   ${RED}【FAIL】冗余已丢失，再坏一个电源即宕机${NC}"
                    power_fail=1
                elif echo "${r_status}" | grep -qiE "degraded"; then
                    echo -e "  ${r_name} : ${r_status}   ${YELLOW}【WARN】冗余降级${NC}"
                elif echo "${r_status}" | grep -qiE "fully redundant"; then
                    echo -e "  ${r_name} : ${r_status}   ${GREEN}【OK】完全冗余${NC}"
                else
                    echo -e "  ${r_name} : ${r_status}   【INFO】冗余状态未识别，请人工确认${NC}"
                fi
            done <<< "${RED_LIST}"
        fi

        if [ ${power_fail} -ne 0 ]; then
            echo "    FAIL!!! 电源状态异常"
            GLOBAL_FAIL=1
        fi
    fi

    # ---- 电源模块 FRU：型号 / 序列号，可直接填进验收记录表 ----
    fru_raw=$(ipmitool fru 2>/dev/null)
    if [ -n "${fru_raw}" ];then
        psu_fru=$(printf '%s\n' "${fru_raw}" | awk '
            tolower($0) ~ /fru device description/ {
                hit = (tolower($0) ~ /psu|power supply/) ? 1 : 0
                if (hit) { n=$0; sub(/^[^:]*:[ ]*/, "", n); if (++cnt > 1) print ""; print "  [" n "]" }
                next
            }
            hit && tolower($0) ~ /(board|product)[ ]*(mfg|manufacturer|product|name|part number|serial|version)/ {
                l=$0; sub(/^[ ]+/, "", l); print "    " l
            }')
        if [ -n "${psu_fru}" ];then
            echo "电源模块 FRU（型号/序列号）:"
            echo "${psu_fru}"
        fi
    fi

    # ---- 整机功耗 + BMC 上限阈值 ----
    # ipmitool sensor 列序：名称|读数|单位|状态|下限NR|下限C|下限NC|上限NC|上限C|上限NR
    # 第 8 列是 Upper Non-Critical，即 BMC 认定的功率上限告警线（不是电源额定容量）
    power_line=$(ipmitool sensor 2>/dev/null | grep -iE "system power|total power|功耗" | head -n1)
    if [ -n "${power_line}" ];then
        power_name=$(echo "${power_line}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
        power_val=$(echo "${power_line}" | awk -F'|' '{print $2}' | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        power_max=$(echo "${power_line}" | awk -F'|' '{print $8}' | grep -oE '[0-9]+\.?[0-9]*' | head -1)
        if [ -n "${power_val}" ];then
            if [ -n "${power_max}" ] && [ "${power_max}" != "0" ];then
                power_pct=$(awk -v a="${power_val}" -v b="${power_max}" 'BEGIN{printf "%.0f", a*100/b}')
                echo "整机功耗 [${power_name}]: ${power_val} W（BMC 上限 ${power_max} W，占用约 ${power_pct}%）"
                if [ "${power_pct}" -ge 90 ] 2>/dev/null;then
                    echo -e "  ${YELLOW}【WARN】功耗已接近 BMC 上限${NC}"
                fi
            else
                echo "整机功耗 [${power_name}]: ${power_val} W（BMC 未提供上限阈值）"
            fi
            echo "  注：预检阶段为待机功耗，判断电源余量请以 lhtest.sh 烤机满载时的读数为准"
        fi
    fi
}

# ========== CMOS 纽扣电池检测（不把"读不到"误判为"不在位/故障"）==========
# 修正的三处误判：
#   1) 多数 BMC 根本不暴露电池传感器，传感器缺失 ≠ 电池不在位，原写法直接判 FAIL
#   2) 原写法 [ "$bat_status" != "ok" ]，而各厂商状态列大小写/措辞不一（ok/OK/0x00/ns），
#      只要不是小写 ok 就判 FAIL
#   3) 原写法取"整行第一个 x.y 数字"当电压，可能取到传感器编号；
#      且离散量 0x00 会被当成 0.0V 判"电压过低"
check_cmos_battery(){
    echo -e "\n【1.8 CMOS纽扣电池检测】"
    if ! command -v ipmitool &>/dev/null; then
        echo "WARN: ipmitool不存在，跳过纽扣电池检测"
        return
    fi

    # 传感器命名各家不同：Battery / CMOS Battery / VBAT / Bat
    local bat_info
    bat_info=$(ipmitool sdr list 2>/dev/null | grep -iE 'battery|\bbat\b|vbat' | head -1)

    if [ -z "${bat_info}" ]; then
        echo "WARN：BMC 未暴露纽扣电池传感器（多数机型不提供该读数），无法自动检测"
        echo "      请人工目视确认主板纽扣电池在位、无松动、无锈蚀（此项不判失败）"
        return
    fi

    local bat_name bat_read bat_status
    bat_name=$(echo "${bat_info}"   | awk -F'|' '{print $1}'  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    bat_read=$(echo "${bat_info}"   | awk -F'|' '{print $2}'  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    bat_status=$(echo "${bat_info}" | awk -F'|' '{print $NF}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "电池标识  : ${bat_name}"
    echo "传感器读数: ${bat_read}"
    echo "硬件状态  : ${bat_status}"

    # ---- 状态判定：先归一化再比较，只对"确定性故障"判 FAIL ----
    local st
    st=$(printf '%s' "${bat_status}" | tr '[:upper:]' '[:lower:]')
    case "${st}" in
        ok|'0x00'|'state deasserted'|'device present'|'presence detected')
            echo -e "  ${GREEN}【OK】BMC 报告电池状态正常${NC}" ;;
        ''|'no reading'|'ns'|'not available'|'n/a'|'unknown'|'disabled'|\
        'not present'|'device not present'|'not installed'|'device absent')
            echo -e "  ${YELLOW}【WARN】BMC 未给出电池有效状态（${bat_status:-空}），请人工目视确认${NC}"
            return ;;
        *'non-critical'*|*'non critical'*)
            echo -e "  ${YELLOW}【WARN】电池状态为 ${bat_status}（轻度预警，尚未到故障线）${NC}"
            return ;;
        *fail*|*error*|*fault*|*critical*|*predictive*|*lower*)
            echo -e "  ${RED}【FAIL】纽扣电池硬件状态异常（${bat_status}）${NC}"
            GLOBAL_FAIL=1
            return ;;
        *)
            echo -e "  ${YELLOW}【WARN】未知的电池状态表述（${bat_status}），请人工确认（不判失败）${NC}"
            return ;;
    esac

    # ---- 电压判定：0x.. 是离散量不是电压，不能拿来当伏特数 ----
    local bat_volt=""
    if ! printf '%s' "${bat_read}" | grep -qiE '^0x|no reading|not available|^ns$|^disabled$|^$'; then
        bat_volt=$(printf '%s' "${bat_read}" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    fi

    if [ -z "${bat_volt}" ]; then
        echo "WARN：传感器只提供状态量（${bat_read}）不提供电压读数，跳过电压阈值检测（不判失败）"
        echo "纽扣电池检测完成：状态正常，电压未采集"
        return
    fi

    echo "当前电压  : ${bat_volt} V"
    echo "测量提示  : 判定电压须在断开 AC 电源后进行"
    echo "             （AC 接通时读到的是主板供电，非电池真实电压）"

    # 四档判定：过低 FAIL / 临界区 WARN / 正常 PASS / 超上限 WARN
    local volt_grade
    volt_grade=$(awk -v v="${bat_volt}" -v lo="${BAT_LOW_VOLT}" \
                      -v warn="${BAT_WARN_VOLT}" -v hi="${BAT_MAX_VOLT}" 'BEGIN{
        if      (v < lo)   print "LOW"
        else if (v < warn) print "CRIT"
        else if (v > hi)   print "OVER"
        else               print "OK"
    }')
    case "${volt_grade}" in
        LOW)
            echo -e "  ${RED}【FAIL】纽扣电池电压过低（${bat_volt}V < ${BAT_LOW_VOLT}V），需更换${NC}"
            GLOBAL_FAIL=1 ;;
        CRIT)
            echo -e "  ${YELLOW}【WARN】纽扣电池电压进入临界区（${bat_volt}V，区间 ${BAT_LOW_VOLT}~${BAT_WARN_VOLT}V），记录实测值并列入更换计划${NC}" ;;
        OVER)
            echo -e "  ${YELLOW}【WARN】电压读数 ${bat_volt}V > ${BAT_MAX_VOLT}V，疑为未断开 AC 时读到的主板供电，非电池真实电压；请断开 AC 后复测（此项不作合格判据）${NC}" ;;
        *)
            echo -e "  ${GREEN}【PASS】纽扣电池电压正常（${bat_volt}V，正常区间 ${BAT_WARN_VOLT}~${BAT_MAX_VOLT}V）${NC}" ;;
    esac
}

# ---------- SMART 健康状态判定（解析输出文本，不依赖 smartctl 退出码）----------
# 为什么不能用退出码：RAID 卡背后的盘、SMART 被屏蔽、USB 桥接、权限不足、NVMe 与 SCSI
# 语义不一致等场景下，smartctl 的返回码与"硬盘是否健康"没有稳定对应关系，
# 原写法 if smartctl -H ...; then OK else FAILED 会把"读不到"当成"不合格"。
# 输出：PASSED / FAILED / UNSUPPORTED / UNKNOWN
# 【同步维护】test.sh / smart.sh / fio.sh 三处保持同一份实现
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

# ---------- 从 lsblk -P 的单行键值对里取值 ----------
# pval 'NAME="sda" TYPE="disk"' NAME -> sda
# 纯 bash 实现，不走管道（设备多时省掉几百个进程）。只用于取不含空格的键值。
# 【同步维护】test.sh / smart.sh / fio.sh 三处保持同一份实现
disk_pval() {
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

# ========== 硬盘检测（含NVMe/SATA双套逻辑，已增加USB过滤） ==========
check_disk_present(){
    echo -e "\n【1.7 硬盘在位&SMART健康检测】"
    
    # ========== 只挑「物理数据盘」：排除 U 盘 / 虚拟设备 / 远端盘 ==========
    # 老写法 `lsblk -d -o NAME,TYPE,TRAN | grep disk | grep -v loop | grep -v usb` 有三处问题：
    #   ① 只挡了 loop 和 usb，误纳入 fd0 软驱（TYPE 同样是 disk）、sr0 光驱、
    #      zram/ram 内存盘、nbd/rbd 网络块设备、iSCSI/FC 远端 LUN；
    #   ② 老 util-linux（<2.27）没有 TRAN 列，整条 lsblk 会直接失败
    #      → 误报「未识别到任何磁盘设备」，把缺列当成缺盘；
    #   ③ USB 硬盘盒的桥接芯片常不上报 TRAN，光靠 grep -v usb 挡不住，要读 sysfs 的 removable。
    # 现按 fio.sh / smart.sh 同一套规则过滤。
    # 说明：virtio / xen 这类虚拟机的「数据盘」保留可测——它们是 VM 里真实存在的盘；
    #       排除的是 loop / zram / nbd / rbd 这种没有实体的伪设备。
    # 【同步维护】test.sh / smart.sh / fio.sh 三处过滤规则保持一致
    _lsblk_fmt="-dn -P -o NAME,TYPE,SIZE"
    if lsblk -dn -P -o NAME,TYPE,TRAN,SIZE,RO >/dev/null 2>&1; then
        _lsblk_fmt="-dn -P -o NAME,TYPE,TRAN,SIZE,RO"
    fi

    DISK_LIST=""
    SKIPPED_DISKS=""
    while IFS= read -r _line; do
        [ -z "${_line}" ] && continue
        _n=$(disk_pval "${_line}" NAME); [ -z "${_n}" ] && continue
        # 伪设备名先判（loop 的 TYPE 五花八门，放在 TYPE 判断之前才统计得到）
        case "${_n}" in
            fd*|sr*|loop*|ram*|zram*|nbd*|rbd*) SKIPPED_DISKS="${SKIPPED_DISKS} ${_n}"; continue ;;
        esac
        [ "$(disk_pval "${_line}" TYPE)" = "disk" ] || continue
        case "$(disk_pval "${_line}" TRAN)" in
            usb|iscsi|fc) SKIPPED_DISKS="${SKIPPED_DISKS} ${_n}"; continue ;;
        esac
        _rm=$(cat "/sys/block/${_n}/removable" 2>/dev/null)
        [ -z "${_rm}" ] && _rm=$(lsblk -dn -o RM "/dev/${_n}" 2>/dev/null | tr -d ' ')
        if [ "${_rm}" = "1" ]; then SKIPPED_DISKS="${SKIPPED_DISKS} ${_n}"; continue; fi
        [ "$(disk_pval "${_line}" RO)" = "1" ] && continue
        DISK_LIST="${DISK_LIST} ${_n}"
    done <<EOF
$(lsblk ${_lsblk_fmt} 2>/dev/null)
EOF
    DISK_LIST="${DISK_LIST# }"
    SKIPPED_DISKS="${SKIPPED_DISKS# }"

    if [ -n "${SKIPPED_DISKS}" ]; then
        echo -e "  ${YELLOW}【跳过】非数据盘（U盘/虚拟/远端/只读）：${SKIPPED_DISKS}${NC}"
    fi

    if [ -z "${DISK_LIST}" ]; then
        echo "FAIL：未识别到任何磁盘设备"
        echo "      可能全是 U 盘 / 虚拟设备，或被上述规则排除——如确需检测某块盘，请显式执行 smartctl -a /dev/sdX"
        GLOBAL_FAIL=1
        return
    fi

    if ! command -v smartctl &>/dev/null; then
        echo "WARN: smartctl未安装，仅执行基础在位检测"
        for d in ${DISK_LIST}; do
            CAP=$(lsblk "/dev/${d}" -dn -o SIZE)
            echo " /dev/${d} | 容量:${CAP} | 型号:未获取 | 序列号:未获取 | 通电:未获取 | SMART:未检测"
        done
        echo "硬盘在位检测 PASS（基础）"
        return
    fi

    # ---------- 内部函数：NVMe 属性解释与异常标记 ----------
    check_nvme_attr() {
        local name="$1" val="$2"
        local attr_fail=0
        case "${name}" in
            "Critical Warning")
                if [[ "${val}" != "0x00" && "${val}" != "0" ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】严重警告标志非0，存在严重故障风险${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无严重警告${NC}"
                fi
                ;;
            "Available Spare")
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
                if [[ "${val}" != "0" && "${val}" != "0x0" ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】介质错误数非0 (${val})，闪存介质存在损坏风险${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无介质错误${NC}"
                fi
                ;;
            "Error Information Log Entries")
                if [[ "${val}" != "0" && "${val}" != "0x0" ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】错误日志条目非0 (${val})，硬盘存在异常事件${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无错误日志${NC}"
                fi
                ;;
            "Unsafe Shutdowns")
                num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
                num=${num:-0}
                if [[ ${num} -gt 20 ]]; then
                    echo -e "    → ${YELLOW}【注意】非正常断电次数较多(${num})，需核查供电稳定性${NC}"
                else
                    echo -e "    → ${GREEN}【正常】非正常断电次数可接受 (${num})${NC}"
                fi
                ;;
            "Temperature")
                num=$(echo "${val}" | grep -oE '[0-9]+' | head -1)
                num=${num:-0}
                if [[ ${num} -gt ${DISK_TEMP_ABORT_SSD} ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】温度过高 (${num}℃，阈值 ${DISK_TEMP_ABORT_SSD}℃)，散热异常${NC}"
                elif [[ ${num} -gt ${DISK_TEMP_WARN_SSD} ]]; then
                    echo -e "    → ${YELLOW}【警告】温度偏高 (${num}℃，告警线 ${DISK_TEMP_WARN_SSD}℃)，建议检查散热${NC}"
                else
                    echo -e "    → ${GREEN}【正常】温度正常 (${num}℃)${NC}"
                fi
                ;;
            "Power On Hours")
                # 先 tr -d ',' 去千分位再取数：smartctl 对 NVMe 会输出 "6,478" 这种带逗号的时长，
                # 直接 grep -oE '[0-9]+' | head -1 会取到 6，把跑了 6478 小时的盘显示成 6 小时
                num=$(echo "${val}" | tr -d ',' | grep -oE '[0-9]+' | head -1)
                num=${num:-0}
                echo -e "    → 通电时间 ${num} 小时（参考值）"
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

    # ---------- 内部函数：SATA/SAS 属性解释与异常标记 ----------
    check_sata_attr() {
        local name="$1" val="$2"
        local attr_fail=0
        case "${name}" in
            "Reallocated_Sector_Ct"|"Reallocated_Sector_Count")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】已重映射坏块数 ${val}，硬盘存在坏扇区${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无重映射坏块${NC}"
                fi
                ;;
            "Current_Pending_Sector"|"Current_Pending_Sector_Count")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】存在待重映射扇区 ${val}，存在潜在坏道风险${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无待重映射扇区${NC}"
                fi
                ;;
            "Offline_Uncorrectable"|"Offline_Uncorrectable_Sector")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】离线不可纠正坏道 ${val}，硬盘存在永久性坏扇区${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无离线不可纠正坏道${NC}"
                fi
                ;;
            "UDMA_CRC_Error_Count"|"UDMA_CRC_Error")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    echo -e "    → ${YELLOW}【注意】CRC传输错误 ${val}，优先检查线缆/背板接触${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无CRC传输错误${NC}"
                fi
                ;;
            "Raw_Read_Error_Rate")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    echo -e "    → ${YELLOW}【注意】原始读取错误率 ${val}，关注磁头状态${NC}"
                else
                    echo -e "    → ${GREEN}【正常】读取错误率正常${NC}"
                fi
                ;;
            "Reported_Uncorrect"|"Reported_Uncorrectable")
                if [[ "${val}" =~ ^[0-9]+$ && ${val} -gt 0 ]]; then
                    attr_fail=1
                    echo -e "    → ${RED}【FAIL】不可纠正错误 ${val}，存在数据丢失风险${NC}"
                else
                    echo -e "    → ${GREEN}【正常】无不可纠正错误${NC}"
                fi
                ;;
            "Command_Timeout")
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
                if [[ "${val}" =~ ^[0-9]+$ ]]; then
                    if [[ ${val} -gt ${DISK_TEMP_ABORT_HDD} ]]; then
                        attr_fail=1
                        echo -e "    → ${RED}【FAIL】温度过高 (${val}℃，阈值 ${DISK_TEMP_ABORT_HDD}℃)，散热异常${NC}"
                    elif [[ ${val} -gt ${DISK_TEMP_WARN_HDD} ]]; then
                        echo -e "    → ${YELLOW}【注意】温度偏高 (${val}℃，告警线 ${DISK_TEMP_WARN_HDD}℃)${NC}"
                    else
                        echo -e "    → ${GREEN}【正常】温度正常 (${val}℃)${NC}"
                    fi
                fi
                ;;
            "Power_On_Hours"|"Power_On_Hours_RAW")
                if [[ "${val}" =~ ^[0-9]+$ ]]; then
                    echo -e "    → 通电时间 ${val} 小时（参考值）"
                fi
                ;;
            *)
                echo -e "    → 参考值"
                ;;
        esac
        return ${attr_fail}
    }

    # ---------- 主循环 ----------
    for d in ${DISK_LIST}; do
        DEV="/dev/${d}"
        CAP=$(lsblk "${DEV}" -dn -o SIZE)
        echo ""
        echo "======= ${DEV} （${CAP}） ======="

        INFO=$(smartctl -i "${DEV}" 2>/dev/null)
        model=$(echo "${INFO}" | grep -iE "Model Number:|Device Model:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
        serial=$(echo "${INFO}" | grep -i "Serial Number:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
        fw=$(echo "${INFO}" | grep -i "Firmware Version:" | head -1 | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
        echo "  型号    : ${model:-未获取}"
        echo "  序列号  : ${serial:-未获取}"
        echo "  固件    : ${fw:-未获取}"

        # 四态判定：只有 BMC/硬盘明确报 FAILED 才判不合格；
        # "不支持/读不到" 属环境问题，给 WARN 交人工确认，不算硬盘故障
        case "$(smart_health "${DEV}")" in
            PASSED)
                echo -e "  SMART状态: ${GREEN}PASSED（自检通过）${NC}" ;;
            FAILED)
                echo -e "  SMART状态: ${RED}FAILED（硬盘自检不通过，需排查/更换）${NC}"
                GLOBAL_FAIL=1 ;;
            UNSUPPORTED)
                echo -e "  SMART状态: ${YELLOW}不支持/不可读（被RAID卡屏蔽或设备无SMART，非硬盘故障，请人工确认）${NC}" ;;
            *)
                echo -e "  SMART状态: ${YELLOW}未知（smartctl 执行异常，请人工确认）${NC}" ;;
        esac

        if [[ "${d}" == nvme* ]]; then
            echo "  ========== [NVMe 盘检测] =========="
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
                "Power Cycles"
            )
            for target in "${NVME_TARGETS[@]}"; do
                line=$(echo "${DATA}" | grep -i "${target}" | head -1)
                if [[ -n "${line}" ]]; then
                    val=$(echo "${line}" | cut -d: -f2- | sed 's/^[ ]*//;s/[ ]*$//')
                    printf "    %-30s : %s\n" "${target}" "${val}"
                    check_nvme_attr "${target}" "${val}"
                    if [ $? -ne 0 ]; then
                        GLOBAL_FAIL=1
                    fi
                else
                    printf "    %-30s : %s\n" "${target}" "未获取"
                    echo -e "    → ${YELLOW}【警告】该字段未获取，硬盘或smartctl不支持读取该属性${NC}"
                fi
            done
        else
            echo "  ========== [SATA / SAS 盘检测] =========="
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
                "Power_Cycle_Count"
            )
            for target in "${SATA_TARGETS[@]}"; do
                line=$(echo "${DATA}" | grep -i "${target}" | head -1)
                if [[ -n "${line}" ]]; then
                    # RAW_VALUE 是属性表的第 10 列。用 $NF 会在 Temperature_Celsius
                    # 这类行尾带 "(Min/Max 20/45)" 的属性上取到 "20/45)"，
                    # 下游 [[ =~ ^[0-9]+$ ]] 不成立 → 整个温度分支静默跳过
                    val=$(echo "${line}" | awk '{print $10}')
                    [ -z "${val}" ] && val=$(echo "${line}" | awk '{print $NF}')
                    printf "    %-30s : %s\n" "${target}" "${val}"
                    check_sata_attr "${target}" "${val}"
                    if [ $? -ne 0 ]; then
                        GLOBAL_FAIL=1
                    fi
                else
                    printf "    %-30s : %s\n" "${target}" "未获取"
                    echo -e "    → ${YELLOW}【警告】该属性未获取，设备可能不支持${NC}"
                fi
            done
        fi

        echo -e "  ${YELLOW}>>> 请测试人员自行判断 <<<${NC}"
    done
    echo "硬盘检测完成"
}

# ===================== 硬件错误计数器：已移除 =====================
#   计数器快照 / 差值报告 / rasdaemon 丝印定位（snapshot_counters、
#   counter_diff_report、ras_label_report）已全部删除：
#   本脚本只做硬件预检，不再采集/比对任何日志或计数器。
#   会话级内核日志与 SEL 巡检由 log.sh 负责。

# ===================== 预检总入口（永不中断） =====================
hardware_pre_check(){
    echo -e "\n==================== 阶段1：硬件信息预检开始 ===================="
    check_system_fru
    check_cpu
    check_gpu_present
    check_nvidia_version
    check_ecc
    check_gpu_vbios
    show_nvlink_topology
    check_memory_info
    check_fan
    check_power_supply
    check_disk_present
    check_cmos_battery

    echo -e "\n【1.9 PCIe带宽链路信息采集】"
    m=1
    sl 2>/dev/null

    echo -e "\n【1.10 BMC待机功耗读取】"
    if command -v ipmitool &> /dev/null;then
        ipmitool sensor 2>/dev/null | grep -i power
    fi

    echo -e "\n==================== 硬件预检结束 ===================="
    # 本脚本只输出检测数据，不做 PASS/FAIL 总判定（与主流程末尾的说明一致）。
    # 各 check 函数仍会置 GLOBAL_FAIL 标记，但这里不再汇总成结论 —— 判定由人来做。
}

# ===================== 错误日志巡检：已移除 =====================
#   dmesg / BMC SEL 巡检（error_log_check）已整体删除。
#   内核日志与 SEL 的采集与巡检由 log.sh 在会话级完成（口径更准：
#   会话开始清空环形缓冲 / 留 SEL 基线，收尾只报会话内新增）。

# ====================== 主流程 ======================
START_TS=$(date +%s)

hardware_pre_check

ELAPSED=$(( $(date +%s) - START_TS ))
echo -e "\n================整机检测完成 $(date)================"
echo "设备SN:        ${SN:-未读到}"
echo "测试总耗时:    $((ELAPSED/3600))时$(((ELAPSED%3600)/60))分$((ELAPSED%60))秒"
echo ""
# 最终 PASS/FAIL 总判定与退出码已移除：本脚本只输出检测数据，不判定是否通过
