#!/bin/bash
# ============================================================
# 作者：蒙泓呈
#个人学习项目，仅用于求职技术展示
#服务器整机老化测试脚本（burn-in test）
# 适用：x86 服务器（GPU/数据盘/BMC 可选，缺失项自动跳过）
# 用法：sudo bash DWlhtest.sh
# 自动化/非交互运行示例：
#   TEST_ID=DWZN123456 SERVER_SN=SN0001 \
#   TEST_TIME=600 FIO_RUN_TIME=300 MEM_RATIO=75 \
#   sudo bash DWlhtest.sh
# 日志输出：运行目录下 <SN>_test.log/ 文件夹
# ============================================================

# 时长配置（秒），均支持环境变量覆盖
: "${TEST_TIME:=3600}"            # CPU/GPU 压力测试时长
: "${FIO_RUN_TIME:=600}"          # 单块硬盘FIO顺序写/读各跑时长
: "${MEM_RATIO:=75}"              # memtester 占用内存比例(%)
: "${MEMT_TIMEOUT:=0}"            # memtester 超时限制(秒)，0=不限制
: "${CPU_TEMP_ALERT:=80}"         # CPU 温度告警阈值(℃)
: "${BAT_LOW_VOLT:=2.7}"          # 纽扣电池低压告警阈值(V)

# 网卡固件升级（默认关闭，避免误升级）
: "${NIC_FW_LOCAL_DIR:=./nic_fw}" # 网卡固件本地目录（预留）
: "${NIC_AUTO_UPGRADE:=0}"        # 1开启网卡固件升级，0关闭（预留）
: "${NIC_ONLINE_UPDATE:=0}"       # 0本地固件，1在线拉取固件（需外网）（预留）

# 自动化开关
: "${TEST_ID:=}"                  # 非交互模式下的测试人员工号
: "${SERVER_SN:=}"                # 非交互模式下的服务器 SN
: "${MIN_YEAR:=2025}"             # 系统时间年份下限校验

# 全局标记
GLOBAL_FAIL=0
CPU_PID=""
MEM_PID=""
GPU_PID=""
MONITOR_PID=""
FIO_PIDS=()
SN=""
testid=""
TEST_DIR=""                 # 专属日志文件夹：SN_test.log
LOG=""                      # 主日志
DMESG_LOG=""                # dmesg 专项日志（仅关键报错+原因注释）
SEL_LOG=""                  # BMC SEL 专项日志（仅关键告警+原因注释）
MONITOR_CSV=""              # 监控采样CSV
TEMP_ALERT_FILE="/tmp/cpu_temp_alert_$$"   # 温度告警标记文件

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

    # 工具名 → 系统包名映射（Debian/Ubuntu 和 CentOS/RHEL 通用）
    declare -A pkg_map
    pkg_map["lspci"]="pciutils"
    pkg_map["ipmitool"]="ipmitool"
    pkg_map["smartctl"]="smartmontools"
    pkg_map["fio"]="fio"
    pkg_map["stress-ng"]="stress-ng"
    pkg_map["memtester"]="memtester"
    pkg_map["dmesg"]="util-linux"
    pkg_map["findmnt"]="util-linux"
    pkg_map["lsblk"]="util-linux"

    # 不通过系统包管理器自动安装的工具
    local skip_auto=("nvidia-smi" "gpu-burn")

    # 全量检测清单
    local deps=("lspci" "findmnt" "lsblk" "ipmitool" "smartctl" "fio" "stress-ng" "memtester" "nvidia-smi" "dmesg" "gpu-burn")
    local missing=()
    local to_install=()

    # 第一步：批量检测缺失
    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
            # 仅系统包加入自动安装列表
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

    # 第二步：识别系统包管理器，安装基础依赖
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

        # CentOS 系先补 epel 扩展源
        if [ "${PKG_MGR}" = "yum" ] || [ "${PKG_MGR}" = "dnf" ]; then
            timeout 300 ${PKG_MGR} install -y epel-release >/dev/null 2>&1
        fi

        # 执行批量安装
        if [ "${PKG_MGR}" = "apt" ]; then
            timeout 300 apt update -y >/dev/null 2>&1
            timeout 600 apt install -y "${to_install[@]}" >/dev/null 2>&1
        else
            timeout 600 ${PKG_MGR} install -y "${to_install[@]}" >/dev/null 2>&1
        fi

        # 安装后二次校验
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

    echo ""

    # 第三步：单独处理 gpu-burn（snap 渠道，仅装了显卡驱动才尝试）
    if command -v nvidia-smi &>/dev/null; then
        if ! command -v gpu-burn &>/dev/null; then
            echo "  [INFO] 检测到NVIDIA显卡驱动，尝试通过 snap 安装 gpu-burn 烤机工具..."
            if command -v snap &>/dev/null; then
                snap install gpu-burn >/dev/null 2>&1
                if command -v gpu-burn &>/dev/null; then
                    echo "  [INFO] gpu-burn 安装成功"
                else
                    echo "  [WARN] gpu-burn snap 安装失败，GPU 烤机测试将跳过"
                fi
            else
                echo "  [WARN] 未检测到 snap 命令，无法自动安装 gpu-burn"
                echo "        可手动执行：snap install gpu-burn"
            fi
        fi
    else
        if [[ " ${missing[*]} " =~ " gpu-burn " ]]; then
            echo "  [INFO] 未检测到 NVIDIA 显卡驱动，gpu-burn 无需安装，GPU 测试项将跳过"
        fi
    fi

    # 单独提示 nvidia-smi
    if [[ " ${missing[*]} " =~ " nvidia-smi " ]]; then
        echo ""
        echo "  [INFO] nvidia-smi 需手动安装 NVIDIA 显卡驱动，GPU 相关测试项将跳过"
    fi

    echo "============================================================"
    echo ""
}
check_deps_preview

# ===================== 系统与BMC时间双重拦截 =====================
time_precheck() {
    echo ""
    echo "============================================================"
    echo "  [初始时间预检] 正在验证系统时间和 BMC 硬件时钟..."
    echo "------------------------------------------------------------"

    SYS_YEAR=$(date +%Y)
    if [ "${SYS_YEAR}" -lt "${MIN_YEAR}" ]; then
        echo "【严重错误】系统时间发生严重回退（${SYS_YEAR} < ${MIN_YEAR}）！"
        echo "   脚本终止。请手动在终端执行以下命令校准："
        echo "   date -s \"YYYY-MM-DD HH:MM:SS\" && hwclock -w"
        exit 1
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
            echo "【严重错误】系统时间与 BMC 时间偏差超过 1分钟，强制终止测试！"
            echo "   请手动在终端校准时间后重试。"
            exit 1
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

# ===================== 工号输入（交互/环境变量/管道 三种模式） =====================
validate_testid() {
    if [ -z "$1" ];then
        echo "【错误】工号不能为空，请重新输入！"
        return 1
    elif [ ${#1} -ne 10 ];then
        echo "【错误】工号必须一共10位，当前输入${#1}位，请核对格式！"
        return 1
    elif [[ "$1" != DWZN* ]];then
        echo "【错误】工号必须以大写DWZN开头，例：DWZN123456"
        return 1
    fi
    return 0
}
get_testid() {
    if [ -n "${TEST_ID}" ];then
        testid="${TEST_ID}"
        echo "使用环境变量工号: ${testid}"
        return
    fi
    if [ ! -t 0 ];then
        read -r testid
        if ! validate_testid "${testid}"; then
            echo "【错误】非交互模式下工号无效，请改用 TEST_ID 环境变量传入，例如："
            echo "  TEST_ID=DWZN123456 SERVER_SN=xxx sudo bash $0"
            exit 1
        fi
        return
    fi
    while true; do
        read -p "测试人员工号(格式：DWZN+6位数字，合计10位，例DWZN123456)： " testid
        validate_testid "${testid}" && break
    done
}

# ===================== SN序列号输入 =====================
get_sn() {
    if [ -n "${SERVER_SN}" ];then
        SN="${SERVER_SN}"
        echo "使用环境变量SN: ${SN}"
        return
    fi
    if [ ! -t 0 ];then
        read -r SN
        if [ -z "${SN}" ];then
            echo "【错误】非交互模式下SN为空，请改用 SERVER_SN 环境变量传入"
            exit 1
        fi
        return
    fi
    while true; do
        read -p "输入服务器SN序列号： " SN
        [ -n "${SN}" ] && break
        echo "【错误】SN序列号不能为空，请重新输入！"
    done
}

get_testid
get_sn

# ========== 创建文件夹：SN_test.log ==========
TEST_DIR="./${SN}_test.log"
mkdir -p "${TEST_DIR}"

LOG="${TEST_DIR}/main.log"
DMESG_LOG="${TEST_DIR}/dmesg.log"
SEL_LOG="${TEST_DIR}/sel.log"
MONITOR_CSV="${TEST_DIR}/monitor.csv"

# 初始化日志文件
> "${LOG}"
> "${DMESG_LOG}"
> "${SEL_LOG}"

# 写入日志头部
echo "========================================" >> "${LOG}"
echo "测试人员工号: ${testid}" >> "${LOG}"
echo "服务器SN: ${SN}" >> "${LOG}"
echo "测试启动时间: $(date)" >> "${LOG}"
echo "日志目录: ${TEST_DIR}" >> "${LOG}"
echo "========================================" >> "${LOG}"

# ========== 压测前双清空 ==========
echo -e "\n[INIT] 清空内核环形缓冲区（dmesg -C），开始记录本次测试内核日志" | tee -a "${LOG}"
dmesg -C 2>/dev/null

if command -v ipmitool &>/dev/null; then
    echo "[INIT] 清空 BMC 系统事件日志（ipmitool sel clear），开始记录本次测试硬件告警" | tee -a "${LOG}"
    ipmitool sel clear 2>/dev/null
    sleep 1
fi

# 异常退出清理函数
cleanup(){
    echo -e "\n[CLEANUP] 收到终止信号，清理后台进程" | tee -a "${LOG}"
    [ -n "${CPU_PID}" ] && kill "${CPU_PID}" 2>/dev/null
    [ -n "${MEM_PID}" ] && kill "${MEM_PID}" 2>/dev/null
    [ -n "${GPU_PID}" ] && kill "${GPU_PID}" 2>/dev/null
    [ -n "${MONITOR_PID}" ] && kill "${MONITOR_PID}" 2>/dev/null
    for pid in "${FIO_PIDS[@]}";do
        kill "${pid}" 2>/dev/null
    done
    rm -rf pcinfo.txt pcinfo1.txt pcinfo2.txt net.txt block.txt /tmp/mlxup_query.txt /tmp/mlxup_after.txt /tmp/fio_*.tmp /tmp/dmesg_filter_*.tmp /tmp/sel_filter_*.tmp
    rm -f "${TEMP_ALERT_FILE}"
}
trap cleanup SIGINT SIGTERM EXIT

# PCIe设备打印函数（修复版：正则精准解析速率/带宽，异常仅提示不终止）
sl(){
    lspci -D > pcinfo.txt
    lspci -D -vvv > pcinfo1.txt
    ls -l /sys/class/net | grep -v virtual > net.txt
    ls -l /sys/class/block | grep -v virtual > block.txt
    l=${m:-1}
    p=(Mellanox Co-processor VGA nvidia SAS Eth Fibre Non-Volatile)

    red=''
    green=''
    yellow=''
    END=''
    ss=''
    if [ -t 1 ];then
        red='\033[31m'
        green='\033[32m'
        yellow='\033[33m'
        END='\033[0m'
        ss='\033[5m'
    fi

    for o in "${p[@]}"
    do
        n=$(grep -i "${o}" pcinfo.txt | grep -vc "ASPEED")
        if [ "${n}" -eq 0 ];then
            continue
        fi
        echo ""
        echo -e "${o}\t${n}"
        y=1

        # 遍历每一个匹配的设备BDF
        while IFS= read -r dev_bdf; do
            [ -z "${dev_bdf}" ] && continue
            ID1=$(cat /sys/bus/pci/devices/"${dev_bdf}"/vendor 2>/dev/null | awk -F"0x" '{print $2}')
            ID2=$(cat /sys/bus/pci/devices/"${dev_bdf}"/device 2>/dev/null | awk -F"0x" '{print $2}')
            ID3=$(cat /sys/bus/pci/devices/"${dev_bdf}"/subsystem_vendor 2>/dev/null | awk -F"0x" '{print $2}')
            ID4=$(cat /sys/bus/pci/devices/"${dev_bdf}"/subsystem_device 2>/dev/null | awk -F"0x" '{print $2}')
            ID1=${ID1:-0000};ID2=${ID2:-0000};ID3=${ID3:-0000};ID4=${ID4:-0000}

            name=$(grep "^${dev_bdf}" pcinfo.txt | cut -d: -f3- | sed -e 's/^[ ]*//' -e 's/[ ]*$//')
            name=${name:-Unknown}

            # 精准提取PCIe能力、状态行
            local lnkcap lnksta
            lnkcap=$(grep "^${dev_bdf}" -A 40 pcinfo1.txt 2>/dev/null | grep "LnkCap:" | head -n1)
            lnksta=$(grep "^${dev_bdf}" -A 40 pcinfo1.txt 2>/dev/null | grep "LnkSta:" | head -n1)

            local cap_speed cap_width sta_speed sta_width
            # 正则提取，不受字段位置影响，兼容所有厂商设备
            cap_speed=$(echo "${lnkcap}" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}' | head -n1)
            cap_width=$(echo "${lnkcap}" | grep -oE 'Width x[0-9]+' | awk '{print $2}' | head -n1)
            sta_speed=$(echo "${lnksta}" | grep -oE 'Speed [0-9.]+GT/s' | awk '{print $2}' | head -n1)
            sta_width=$(echo "${lnksta}" | grep -oE 'Width x[0-9]+' | awk '{print $2}' | head -n1)

            cap_speed=${cap_speed:-未知}
            cap_width=${cap_width:-未知}
            sta_speed=${sta_speed:-未知}
            sta_width=${sta_width:-未知}

            # 判定速率宽度是否匹配（仅提示，不设置全局失败）
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

            # 拼接输出
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

##############################################################################
# 1.CPU在位检查
##############################################################################
check_cpu(){
    echo -e "\n【1.1 CPU在位检测】" | tee -a "${LOG}"
    CPU_PHYSICAL=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)
    CPU_CORE=$(grep -c '^processor' /proc/cpuinfo)
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
    echo "CPU型号:${CPU_MODEL}" | tee -a "${LOG}"
    echo "物理CPU颗数:${CPU_PHYSICAL}" | tee -a "${LOG}"
    echo "逻辑CPU数量:${CPU_CORE}" | tee -a "${LOG}"
    if [ "${CPU_PHYSICAL}" -lt 1 ];then
        echo "FAIL：未识别到CPU" | tee -a "${LOG}"
        GLOBAL_FAIL=1
    else
        echo "CPU在位检测 PASS" | tee -a "${LOG}"
    fi
}

##############################################################################
# 2.GPU在位检查（无显卡仅提示，不终止压测）
##############################################################################
check_gpu_present(){
    echo -e "\n【1.2 GPU显卡在位检测】" | tee -a "${LOG}"
    # PCI层扫描物理NVIDIA显卡硬件数量
    local pci_gpu_cnt
    pci_gpu_cnt=$(lspci 2>/dev/null | grep -i "nvidia" | grep -iE "VGA|3D controller" | wc -l)
    local gpu_valid=0

    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi &>/dev/null; then
            gpu_valid=${pci_gpu_cnt}
            echo "识别有效NVIDIA GPU数量: ${gpu_valid}" | tee -a "${LOG}"
            nvidia-smi -L 2>/dev/null | tee -a "${LOG}"
            echo "GPU在位检测 PASS" | tee -a "${LOG}"
        else
            echo "WARN：NVIDIA驱动存在但显卡异常，跳过GPU压测项" | tee -a "${LOG}"
        fi
    else
        if [ "${pci_gpu_cnt}" -gt 0 ]; then
            echo "WARN：检测到NVIDIA物理显卡，但未安装驱动，跳过GPU压测项" | tee -a "${LOG}"
        else
            echo "未检测到NVIDIA显卡硬件，跳过GPU相关检测" | tee -a "${LOG}"
        fi
    fi
}

##############################################################################
# 3.风扇检查
##############################################################################
check_fan(){
    echo -e "\n【1.3 风扇信息检测】" | tee -a "${LOG}"
    if command -v ipmitool &>/dev/null;then
        FAN_RAW=$(ipmitool sdr type Fan 2>/dev/null)
        echo "${FAN_RAW}" | tee -a "${LOG}"
        FAN_COUNT=$(echo "${FAN_RAW}" | awk -F'|' 'NF>=2 && $2 !~ /no reading/ && $2 !~ /^[ ]*$/ {n++} END{print n+0}')
        echo "有效风扇数量:${FAN_COUNT}" | tee -a "${LOG}"
        if [ "${FAN_COUNT}" -lt 1 ];then
            echo "WARN：未读到有效风扇转速，请确认BMC" | tee -a "${LOG}"
        fi
    else
        echo "ipmitool不存在，跳过风扇检测" | tee -a "${LOG}"
    fi
}

##############################################################################
# 电源在位及功率检测
##############################################################################
check_power_supply(){
    echo -e "\n【1.3.1 电源在位&功率检测】" | tee -a "${LOG}"
    if ! command -v ipmitool &>/dev/null;then
        echo "WARN: ipmitool不存在，跳过电源检测" | tee -a "${LOG}"
        return
    fi

    PS_LIST=$(ipmitool sdr 2>/dev/null | grep -iE "power supply|psu|redundan" | grep -v "no reading")
    if [ -z "${PS_LIST}" ];then
        echo "WARN: 未识别到电源传感器信息" | tee -a "${LOG}"
    else
        echo "电源模块状态:" | tee -a "${LOG}"
        while IFS= read -r line; do
            ps_name=$(echo "${line}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
            ps_status=$(echo "${line}" | awk -F'|' '{print $NF}' | sed 's/^[ ]*//;s/[ ]*$//')
            echo "  ${ps_name} : ${ps_status}" | tee -a "${LOG}"
            if echo "${ps_status}" | grep -qi "not present\|fail\|error\|fault\|warn"; then
                echo "    FAIL!!! 电源状态异常" | tee -a "${LOG}"
                GLOBAL_FAIL=1
            fi
        done <<< "${PS_LIST}"
    fi

    power_val=$(ipmitool sensor 2>/dev/null \
        | grep -iE "system power|total power|功耗" \
        | head -n1 \
        | awk -F'|' '{print $2}' \
        | grep -oE '[0-9]+\.?[0-9]*')
    if [ -n "${power_val}" ];then
        echo "当前系统总功率: ${power_val} W" | tee -a "${LOG}"
    fi
}

##############################################################################
# CMOS纽扣电池检测（ipmitool sdr方式：在位+电压双检测）
##############################################################################
check_cmos_battery(){
    echo -e "\n【1.5 CMOS纽扣电池检测】" | tee -a "${LOG}"
    if ! command -v ipmitool &>/dev/null; then
        echo "WARN: ipmitool不存在，跳过纽扣电池检测" | tee -a "${LOG}"
        return
    fi

    # 抓取电池SDR信息
    local bat_info
    bat_info=$(ipmitool sdr list 2>/dev/null | grep -i "bat")

    # 1. 在位检测
    if [ -z "${bat_info}" ]; then
        echo "FAIL：未检测到主板纽扣电池（不在位）" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi

    # 提取字段：电池名称、电压数值、硬件状态
    local bat_name
    local bat_volt
    local bat_status
    bat_name=$(echo "${bat_info}" | awk -F'|' '{print $1}' | sed 's/^[ ]*//;s/[ ]*$//')
    bat_volt=$(echo "${bat_info}" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/) {print $i; exit}}')
    bat_status=$(echo "${bat_info}" | awk -F'|' '{print $NF}' | sed 's/^[ ]*//;s/[ ]*$//')

    echo "电池标识: ${bat_name}" | tee -a "${LOG}"
    echo "当前电压: ${bat_volt} Volts" | tee -a "${LOG}"
    echo "硬件状态: ${bat_status}" | tee -a "${LOG}"

    # 2. 硬件状态检测（忽略大小写）
    if ! echo "${bat_status}" | grep -iq "ok"; then
        echo "FAIL：纽扣电池硬件状态异常" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi

    # 3. 电压阈值检测（低于设定阈值判定亏电）
    local low_volt
    low_volt=$(awk -v v="${bat_volt}" -v t="${BAT_LOW_VOLT}" 'BEGIN{if(v < t) print 1; else print 0}')
    if [ "${low_volt}" -eq 1 ]; then
        echo "FAIL：纽扣电池电压过低（低于${BAT_LOW_VOLT}V），建议更换" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi

    echo "纽扣电池在位检测 PASS，电压正常" | tee -a "${LOG}"
}

##############################################################################
# 4.硬盘在位&SMART检测
##############################################################################
check_disk_present(){
    echo -e "\n【1.4 硬盘在位&SMART健康检测】" | tee -a "${LOG}"
    DISK_LIST=$(lsblk -d -o NAME,TYPE | grep -E "disk" | grep -v loop | awk '{print $1}' | grep -v NAME)

    if [ -z "${DISK_LIST}" ];then
        echo "FAIL：未识别到任何磁盘设备" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi

    if ! command -v smartctl &>/dev/null;then
        echo "WARN: smartctl未安装，仅执行基础在位检测" | tee -a "${LOG}"
        for d in ${DISK_LIST};do
            CAP=$(lsblk "/dev/${d}" -dn -o SIZE)
            echo " /dev/${d} | 容量:${CAP} | 通电时长:未获取 | SMART状态:未检测" | tee -a "${LOG}"
        done
        echo "硬盘在位检测 PASS" | tee -a "${LOG}"
        return
    fi

    for d in ${DISK_LIST};do
        DEV="/dev/${d}"
        CAP=$(lsblk "${DEV}" -dn -o SIZE)
        power_hours="未知"
        health_status="UNKNOWN"

        smartctl -H "${DEV}" >/dev/null 2>&1
        if [ $? -eq 0 ];then
            health_status="OK"
        else
            health_status="N/A"
            echo "  [INFO] ${DEV} SMART 状态获取失败（可能为U盘或不支持SMART），跳过失败标记" | tee -a "${LOG}"
        fi

        if [ -d "/sys/block/${d}/device/nvme" ];then
            power_hours=$(smartctl -a "${DEV}" 2>/dev/null | grep -i "Power On Hours" | awk '{print $NF}')
        else
            power_hours=$(smartctl -A "${DEV}" 2>/dev/null | grep -i "Power_On_Hours\|Power On Hours" | awk '{print $NF}' | head -n1)
        fi
        [ -z "${power_hours}" ] && power_hours="未知"

        echo " ${DEV} | 容量:${CAP} | 通电时长:${power_hours}小时 | SMART状态:${health_status}" | tee -a "${LOG}"
    done
    echo "硬盘检测完成" | tee -a "${LOG}"
}

##############################################################################
# 网卡固件信息采集与升级（预留功能，默认仅采集不升级）
##############################################################################
nic_fw_update(){
    echo -e "\n【1.5.1 网卡固件信息采集与升级】" | tee -a "${LOG}"
    NIC_LIST=$(lspci -D 2>/dev/null | grep -iE "ethernet|infiniband|network controller" | grep -viE "virtual|vmware|qemu" || true)
    if [ -z "${NIC_LIST}" ]; then
        echo "INFO: 未识别到物理网卡（虚拟/云环境网卡已忽略），跳过网卡固件检测" | tee -a "${LOG}"
        return
    fi
    echo "识别到物理网卡:" | tee -a "${LOG}"
    echo "${NIC_LIST}" | tee -a "${LOG}"

    if [ "${NIC_AUTO_UPGRADE}" != "1" ]; then
        echo "INFO: NIC_AUTO_UPGRADE=${NIC_AUTO_UPGRADE}（默认0），仅采集信息，不执行固件升级" | tee -a "${LOG}"
        return
    fi

    if ! command -v mlxup &>/dev/null; then
        echo "WARN: 未找到 mlxup（Mellanox Firmware Tools），跳过固件升级" | tee -a "${LOG}"
        echo "  如需升级请安装 MFT（Mellanox Firmware Tools）后重试" | tee -a "${LOG}"
        return
    fi
    if [ ! -d "${NIC_FW_LOCAL_DIR}" ] || [ -z "$(ls -A "${NIC_FW_LOCAL_DIR}" 2>/dev/null)" ]; then
        echo "WARN: 本地固件目录 ${NIC_FW_LOCAL_DIR} 不存在或为空，跳过固件升级" | tee -a "${LOG}"
        return
    fi
    echo "开始执行网卡固件升级（本地目录: ${NIC_FW_LOCAL_DIR}）..." | tee -a "${LOG}"
    mlxup 2>&1 | tee -a "${LOG}"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo "网卡固件升级执行完成" | tee -a "${LOG}"
    else
        echo "WARN: 网卡固件升级返回非零，请人工检查（不纳入本次老化判定）" | tee -a "${LOG}"
    fi
}

##############################################################################
# 预检总入口
##############################################################################
hardware_pre_check(){
    echo -e "\n==================== 阶段1：硬件信息预检开始 ====================" | tee -a "${LOG}"
    check_cpu
    check_gpu_present
    check_fan
    check_power_supply
    check_disk_present
    check_cmos_battery
    nic_fw_update

    echo -e "\n【1.7 PCIe带宽链路信息采集】" | tee -a "${LOG}"
    m=1
    sl 2>/dev/null | tee -a "${LOG}"

    echo -e "\n【1.8 BMC待机功耗读取】" | tee -a "${LOG}"
    if command -v ipmitool &> /dev/null;then
        ipmitool sensor 2>/dev/null | grep -i power | tee -a "${LOG}"
    fi

    echo -e "\n==================== 阶段1：硬件预检结束 ====================" | tee -a "${LOG}"
    if [ "${GLOBAL_FAIL}" -ne 0 ];then
        echo -e "\n########## 硬件预检发现异常，不进入压力测试，直接退出 ##########" | tee -a "${LOG}"
        echo "设备SN:        ${SN}" | tee -a "${LOG}"
        echo "测试人员工号:  ${testid}" | tee -a "${LOG}"
        echo "【最终结果】PRE-CHECK FAIL" | tee -a "${LOG}"
        exit 1
    fi
    echo "硬件预检全部PASS，准备进入压力老化测试" | tee -a "${LOG}"
}

##############################################################################
# 工具函数：递归查找根分区对应的物理磁盘
##############################################################################
get_root_disk() {
    local root_source
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | tr -d '[]')
    [ -z "${root_source}" ] && return 1
    
    local dev_name
    dev_name="${root_source#/dev/}"
    local parent=""
    
    while true; do
        parent=$(lsblk -no pkname "/dev/${dev_name}" 2>/dev/null | head -n1)
        [ -z "${parent}" ] && break
        dev_name="${parent}"
    done
    
    echo "${dev_name}"
}

##############################################################################
# FIO磁盘压测
##############################################################################
run_disk_fio(){
    echo -e "\n【2.1 FIO 顺序读写压测（每盘写${FIO_RUN_TIME}s + 读${FIO_RUN_TIME}s，块大小128k）】" | tee -a "${LOG}"

    SYS_DISK=$(get_root_disk)
    if [ -z "${SYS_DISK}" ]; then
        echo "FAIL：无法识别系统盘，为数据安全起见，终止FIO压测" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi
    echo "识别到系统盘: /dev/${SYS_DISK}（自动排除）" | tee -a "${LOG}"

    DISK_LIST=$(lsblk -d -o NAME,TYPE | grep -E "disk" | grep -v loop | awk '{print $1}' | grep -v NAME | grep -v "^${SYS_DISK}$")

    if [ -z "${DISK_LIST}" ]; then
        echo "WARN：未找到可测试的数据盘（仅识别到系统盘），跳过FIO压测" | tee -a "${LOG}"
        return
    fi

    if echo "${DISK_LIST}" | grep -qw "${SYS_DISK}"; then
        echo "FAIL：安全校验异常，系统盘仍在压测列表中，终止FIO压测" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi

    echo "本次FIO测试磁盘列表:" | tee -a "${LOG}"
    for d in ${DISK_LIST}; do
        echo "  /dev/${d}" | tee -a "${LOG}"
    done

    # ========== 顺序写测试 ==========
    echo "" | tee -a "${LOG}"
    echo "--- 128k 顺序写测试 ---" | tee -a "${LOG}"
    FIO_WRITE_PIDS=()
    write_fail=0
    for d in ${DISK_LIST}; do
        fio --name="write_${d}" \
            --filename="/dev/${d}" \
            --direct=1 \
            --iodepth=32 \
            --thread \
            --rw=write \
            --ioengine=libaio \
            --bs=128k \
            --size=100% \
            --runtime="${FIO_RUN_TIME}" \
            --time_based \
            --group_reporting \
            --output="/tmp/fio_${d}_write.tmp" >/dev/null 2>&1 &
        local pid=$!
        FIO_WRITE_PIDS+=("${pid}")
        FIO_PIDS+=("${pid}")
    done

    # 总超时保护：FIO_RUN_TIME 基础上再加 120 秒缓冲，防止异常卡死
    local fio_deadline=$(( $(date +%s) + FIO_RUN_TIME + 120 ))
    for pid in "${FIO_WRITE_PIDS[@]}"; do
        # 轮询等待单个进程退出（区分僵尸态），超过总时限则强制终止剩余进程
        while kill -0 "${pid}" 2>/dev/null && [ "$(awk '{print $3}' /proc/${pid}/stat 2>/dev/null)" != "Z" ]; do
            if [ "$(date +%s)" -ge "${fio_deadline}" ]; then
                echo "WARN：FIO 写测试超过总时限，强制终止剩余进程" | tee -a "${LOG}"
                kill "${FIO_WRITE_PIDS[@]}" 2>/dev/null
                wait "${FIO_WRITE_PIDS[@]}" 2>/dev/null
                write_fail=1
                break 2
            fi
            sleep 2
        done
        if ! wait "${pid}"; then
            write_fail=1
        fi
    done

    # 提取核心指标写入主日志
    for d in ${DISK_LIST}; do
        tmp_file="/tmp/fio_${d}_write.tmp"
        if [ -f "${tmp_file}" ]; then
            bw=$(grep "WRITE:" "${tmp_file}" | awk '{print $2}' | grep -oE '[0-9]+\.?[0-9]*[KMGT]?B/s' | head -n1)
            iops=$(grep "WRITE:" "${tmp_file}" | awk '{print $3}' | grep -oE '[0-9]+\.?[0-9]*' | head -n1)
            echo "  /dev/${d} | 写带宽: ${bw:-未知} | 平均IOPS: ${iops:-未知}" | tee -a "${LOG}"
            if grep -qiE "err=[1-9]|io error|I/O error|failed" "${tmp_file}"; then
                echo "  [WARN] /dev/${d} FIO写测试输出含错误信息，请查看完整日志" | tee -a "${LOG}"
                write_fail=1
            fi
            rm -f "${tmp_file}"
        else
            echo "  /dev/${d} | 写测试异常退出" | tee -a "${LOG}"
        fi
    done

    if [ "${write_fail}" -ne 0 ]; then
        echo "WARN：FIO顺序写测试有磁盘异常" | tee -a "${LOG}"
        GLOBAL_FAIL=1
    else
        echo "128k 顺序写测试全部完成" | tee -a "${LOG}"
    fi

    # ========== 顺序读测试 ==========
    echo "" | tee -a "${LOG}"
    echo "--- 128k 顺序读测试 ---" | tee -a "${LOG}"
    FIO_READ_PIDS=()
    read_fail=0
    for d in ${DISK_LIST}; do
        fio --name="read_${d}" \
            --filename="/dev/${d}" \
            --direct=1 \
            --iodepth=32 \
            --thread \
            --rw=read \
            --ioengine=libaio \
            --bs=128k \
            --size=100% \
            --runtime="${FIO_RUN_TIME}" \
            --time_based \
            --group_reporting \
            --output="/tmp/fio_${d}_read.tmp" >/dev/null 2>&1 &
        local pid=$!
        FIO_READ_PIDS+=("${pid}")
        FIO_PIDS+=("${pid}")
    done

    # 总超时保护：FIO_RUN_TIME 基础上再加 120 秒缓冲，防止异常卡死
    local fio_deadline=$(( $(date +%s) + FIO_RUN_TIME + 120 ))
    for pid in "${FIO_READ_PIDS[@]}"; do
        # 轮询等待单个进程退出（区分僵尸态），超过总时限则强制终止剩余进程
        while kill -0 "${pid}" 2>/dev/null && [ "$(awk '{print $3}' /proc/${pid}/stat 2>/dev/null)" != "Z" ]; do
            if [ "$(date +%s)" -ge "${fio_deadline}" ]; then
                echo "WARN：FIO 读测试超过总时限，强制终止剩余进程" | tee -a "${LOG}"
                kill "${FIO_READ_PIDS[@]}" 2>/dev/null
                wait "${FIO_READ_PIDS[@]}" 2>/dev/null
                read_fail=1
                break 2
            fi
            sleep 2
        done
        if ! wait "${pid}"; then
            read_fail=1
        fi
    done

    # 提取核心指标写入主日志
    for d in ${DISK_LIST}; do
        tmp_file="/tmp/fio_${d}_read.tmp"
        if [ -f "${tmp_file}" ]; then
            bw=$(grep "READ:" "${tmp_file}" | awk '{print $2}' | grep -oE '[0-9]+\.?[0-9]*[KMGT]?B/s' | head -n1)
            iops=$(grep "READ:" "${tmp_file}" | awk '{print $3}' | grep -oE '[0-9]+\.?[0-9]*' | head -n1)
            echo "  /dev/${d} | 读带宽: ${bw:-未知} | 平均IOPS: ${iops:-未知}" | tee -a "${LOG}"
            if grep -qiE "err=[1-9]|io error|I/O error|failed" "${tmp_file}"; then
                echo "  [WARN] /dev/${d} FIO读测试输出含错误信息，请查看完整日志" | tee -a "${LOG}"
                read_fail=1
            fi
            rm -f "${tmp_file}"
        else
            echo "  /dev/${d} | 读测试异常退出" | tee -a "${LOG}"
        fi
    done

    if [ "${read_fail}" -ne 0 ]; then
        echo "WARN：FIO顺序读测试有磁盘异常" | tee -a "${LOG}"
        GLOBAL_FAIL=1
    else
        echo "128k 顺序读测试全部完成" | tee -a "${LOG}"
    fi

    # ========== FIO 压测后 SMART 健康复查 ==========
    echo "" | tee -a "${LOG}"
    echo "--- FIO压测后 SMART 健康复查 ---" | tee -a "${LOG}"
    for d in ${DISK_LIST}; do
        DEV="/dev/${d}"
        if smartctl -H "${DEV}" >/dev/null 2>&1; then
            echo "  ${DEV} SMART健康复查: OK" | tee -a "${LOG}"
        else
            echo "  ${DEV} SMART健康复查: 获取失败/不支持SMART（请人工确认）" | tee -a "${LOG}"
        fi
    done

    echo "" | tee -a "${LOG}"
    echo "全部磁盘FIO压测完成" | tee -a "${LOG}"
}

##############################################################################
# 后台监控循环
##############################################################################
MONITOR_LOOP(){
    : > "${MONITOR_CSV}"
    echo "采集时间,CPU最高温度( ℃  ),整机功耗(W),GPU最高温度( ℃  ),GPU总功耗(W),GPU最大利用率(%),内存使用率(%),风扇最高转速(RPM)" > "${MONITOR_CSV}"
    
    while true
    do
        local TS
        TS=$(date "+%Y-%m-%d %H:%M:%S")
        local cpu_max_temp=0
        local power_val=0
        local gpu_max_temp=0
        local gpu_power_sum=0
        local gpu_util_max=0
        local mem_usage=0
        local fan_max_rpm=0

        echo "===== 实时监控 ${TS} =====" >> "${LOG}"

        # CPU温度 + 功耗 + 风扇转速
        if command -v ipmitool &> /dev/null;then
            cpu_max_temp=$(ipmitool sdr type Temperature 2>/dev/null \
                | grep -v "no reading" \
                | awk -F'|' '{print $2}' \
                | grep -oE '[0-9]+\.?[0-9]*' \
                | sort -n \
                | tail -n1)
            cpu_max_temp=${cpu_max_temp:-0}
            
            if [ "${cpu_max_temp}" != "0" ];then
                echo "CPU最高温度: ${cpu_max_temp} ℃" >> "${LOG}"
                local over_temp
                over_temp=$(awk -v temp="${cpu_max_temp}" -v th="${CPU_TEMP_ALERT}" 'BEGIN{if(temp>th) print 1; else print 0}')
                if [ "${over_temp}" -eq 1 ];then
                    echo "WARN!!! CPU温度超过${CPU_TEMP_ALERT}℃阈值，当前最高 ${cpu_max_temp}℃" >> "${LOG}"
                    touch "${TEMP_ALERT_FILE}"
                fi
            fi

            # 整机功耗
            power_val=$(ipmitool sensor 2>/dev/null \
                | grep -iE "system power|total power|功耗" \
                | head -n1 \
                | awk -F'|' '{print $2}' \
                | grep -oE '[0-9]+\.?[0-9]*')
            power_val=${power_val:-0}
            [ "${power_val}" != "0" ] && echo "整机功耗: ${power_val} W" >> "${LOG}"

            # 风扇最高转速
            fan_max_rpm=$(ipmitool sdr type Fan 2>/dev/null \
                | grep -v "no reading" \
                | awk -F'|' '{print $2}' \
                | grep -oE '[0-9]+' \
                | sort -n \
                | tail -n1)
            fan_max_rpm=${fan_max_rpm:-0}
        fi

        # GPU数据（驱动异常自动补0）
        if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null;then
            local gpu_info
            gpu_info=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
            gpu_max_temp=$(echo "${gpu_info}" | awk '{print $1}' | sort -nr | head -n1)
            gpu_power_sum=$(echo "${gpu_info}" | awk '{sum+=$2}END{printf "%.1f", sum}')
            gpu_util_max=$(echo "${gpu_info}" | awk '{print $3}' | sort -nr | head -n1)
            echo "GPU最高温度: ${gpu_max_temp}℃ | GPU总功耗: ${gpu_power_sum}W | GPU最大利用率: ${gpu_util_max}%" >> "${LOG}"
        fi

        # 内存使用率
        mem_usage=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.2f", $3/$2*100}')
        mem_usage=${mem_usage:-0}
        [ "${mem_usage}" != "0" ] && echo "内存使用率: ${mem_usage}%" >> "${LOG}"

        # 写入CSV
        echo "${TS},${cpu_max_temp},${power_val},${gpu_max_temp},${gpu_power_sum},${gpu_util_max},${mem_usage},${fan_max_rpm}" >> "${MONITOR_CSV}"
        
        sleep 60
    done
}

##############################################################################
# 内核日志 & BMC SEL 日志巡检（SEL白名单：清空日志记录不触发告警）
##############################################################################
error_log_check() {
    echo -e "\n==================== 错误日志巡检 ====================" | tee -a "${LOG}"

    # ========== 1. dmesg 内核日志 ==========
    echo -e "\n【3.1 内核日志（dmesg）巡检】" | tee -a "${LOG}"
    if command -v dmesg &>/dev/null; then
        local tmp_raw="/tmp/dmesg_filter_$$.tmp"
        local tmp_filtered="/tmp/dmesg_filtered_$$.tmp"
        dmesg > "${tmp_raw}"

        # 无害日志白名单
        local dmesg_ignore=(
            "floppy0: floppy_queue_rq: timeout handler died"
            "apparmor.*profile_replace.*same as current profile, skipping"
            "loop[0-9]*: detected capacity change"
            "snap.*apparmor.*STATUS.*unconfined"
            "audit: type=1400 audit.*apparmor.*STATUS"
        )

        # 致命错误关键词
        local dmesg_fatal_keys=(
            "Uncorrected error"
            "Machine check"
            "Hardware Error"
            "MCE"
            "Uncorrected (Fatal)"
            "PCIe Bus Error"
            "buffer I/O error"
            "I/O error"
            "panic"
            "Oops:"
            "BUG:"
        )
        local dmesg_fatal_reasons=(
            "【严重】内存ECC不可纠正错误，内存颗粒硬件故障"
            "CPU机器检查异常，CPU/内存/总线硬件故障"
            "硬件级致命错误，通常为CPU或主板故障"
            "CPU机器检查异常，核心硬件故障"
            "【严重】PCIe致命不可纠正错误，PCIe设备硬件故障"
            "PCIe总线错误，网卡/RAID卡/GPU等PCIe设备接触不良或损坏"
            "磁盘IO错误，硬盘或存储链路故障"
            "块设备IO错误，存储介质或链路异常"
            "【严重】内核崩溃，系统级严重故障"
            "内核严重异常，驱动或硬件故障导致"
            "内核BUG触发，通常为驱动或硬件兼容性问题"
        )
        # 软性告警关键词
        local dmesg_warn_keys=(
            "Corrected error"
            "ECC"
            "AER"
            "timeout"
            "reset"
            "fault"
            "Uncorrected"
        )
        local dmesg_warn_reasons=(
            "【警告】内存ECC可纠正错误，内存稳定性下降"
            "内存ECC校验错误，需关注内存硬件状态"
            "PCIe高级错误报告，PCIe链路信号异常"
            "设备超时，硬件无响应或链路不稳定"
            "设备异常复位，硬件不稳定导致"
            "硬件/内存页故障"
            "存在不可纠正类事件，需结合上下文判断"
        )

        # 过滤无害日志
        cp "${tmp_raw}" "${tmp_filtered}"
        for ig in "${dmesg_ignore[@]}"; do
            grep -vi "${ig}" "${tmp_filtered}" > "${tmp_filtered}.tmp" && mv "${tmp_filtered}.tmp" "${tmp_filtered}"
        done

        # 匹配错误关键词
        > "${DMESG_LOG}"
        local fatal_hit=0
        local warn_hit=0
        while IFS= read -r line; do
            [ -z "${line}" ] && continue
            local reason=""
            for i in "${!dmesg_fatal_keys[@]}"; do
                if echo "${line}" | grep -qi "${dmesg_fatal_keys[$i]}"; then
                    reason="${dmesg_fatal_reasons[$i]}"
                    fatal_hit=1
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # 【FAIL】${reason}" >> "${DMESG_LOG}"
                continue
            fi
            for i in "${!dmesg_warn_keys[@]}"; do
                if echo "${line}" | grep -qi "${dmesg_warn_keys[$i]}"; then
                    reason="${dmesg_warn_reasons[$i]}"
                    warn_hit=1
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # 【WARN】${reason}" >> "${DMESG_LOG}"
            fi
        done < "${tmp_filtered}"

        # 结果判定
        if [ "${fatal_hit}" -eq 1 ]; then
            echo "  [FAIL] 检测到硬件致命报错，详情见 ${DMESG_LOG}" | tee -a "${LOG}"
            GLOBAL_FAIL=1
        elif [ "${warn_hit}" -eq 1 ]; then
            echo "  [WARN] 检测到软性/可恢复告警（不判失败），详情见 ${DMESG_LOG}" | tee -a "${LOG}"
        else
            echo "本次测试未检测到内核关键报错" > "${DMESG_LOG}"
            echo "  [PASS] 未检测到内核硬件级关键报错" | tee -a "${LOG}"
        fi

        rm -f "${tmp_raw}" "${tmp_filtered}" "${tmp_filtered}.tmp"
    else
        echo "dmesg工具不可用，跳过内核日志巡检" > "${DMESG_LOG}"
        echo "WARN: dmesg 不可用，跳过内核日志巡检" | tee -a "${LOG}"
    fi

    # ========== 2. BMC SEL 日志（白名单过滤：清空日志记录不触发告警） ==========
    echo -e "\n【3.2 BMC 系统事件日志（SEL）巡检】" | tee -a "${LOG}"
    if command -v ipmitool &>/dev/null; then
        local tmp_sel_raw="/tmp/sel_filter_$$.tmp"
        ipmitool sel list > "${tmp_sel_raw}" 2>/dev/null

        # SEL 白名单：正常操作记录，不计入故障
        local sel_whitelist=(
            "Log area reset/cleared"
            "Event Logging Disabled #0x52"
        )

        local sel_err_keys=(
            "Non-recoverable"
            "Critical"
            "Failure"
            "Uncorrectable Error"
            "Correctable Error"
            "Memory error"
            "ECC"
            "Over Temp"
            "Temperature Warning"
            "Power Fault"
            "Power Supply"
            "Voltage"
            "Fan Failure"
            "asserted"
        )
        local sel_err_reasons=(
            "【严重】不可恢复硬件故障"
            "【严重】严重硬件告警"
            "硬件部件失效"
            "【严重】内存不可纠正ECC错误"
            "内存可纠正ECC错误"
            "内存硬件错误"
            "内存ECC校验告警"
            "温度过温告警，散热异常"
            "温度预警，接近阈值"
            "电源故障"
            "电源模块状态异常"
            "电压异常，电源或主板供电故障"
            "风扇失效，散热系统故障"
            "硬件告警事件触发"
        )

        > "${SEL_LOG}"
        local sel_has_error=0

        while IFS= read -r line; do
            [ -z "${line}" ] && continue

            # 先匹配白名单，命中直接记录但不判定为故障
            local is_white=0
            for w in "${sel_whitelist[@]}"; do
                if [[ "${line}" == *"${w}"* ]]; then
                    is_white=1
                    break
                fi
            done
            if [ "${is_white}" -eq 1 ]; then
                echo "${line}  # BMC日志清空操作记录，非硬件故障" >> "${SEL_LOG}"
                continue
            fi

            # 匹配故障关键词
            local reason=""
            for i in "${!sel_err_keys[@]}"; do
                if echo "${line}" | grep -qi "${sel_err_keys[$i]}"; then
                    reason="${sel_err_reasons[$i]}"
                    sel_has_error=1
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # ${reason}" >> "${SEL_LOG}"
            fi
        done < "${tmp_sel_raw}"

        # 结果判定（仅真实故障才标记失败）
        if [ "${sel_has_error}" -eq 1 ]; then
            echo "  [FAIL] 检测到BMC硬件告警，详情见 ${SEL_LOG}" | tee -a "${LOG}"
            GLOBAL_FAIL=1
        else
            echo "本次测试未检测到BMC硬件关键报错" > "${SEL_LOG}"
            echo "  [PASS] 未检测到BMC硬件级关键告警" | tee -a "${LOG}"
        fi

        rm -f "${tmp_sel_raw}"
    else
        echo "ipmitool不可用，跳过BMC SEL日志巡检" > "${SEL_LOG}"
        echo "WARN: ipmitool 不可用，跳过 BMC SEL 日志巡检" | tee -a "${LOG}"
    fi

    echo "========================================================" | tee -a "${LOG}"
}

##############################################################################
# 压力老化总入口
##############################################################################
stress_stage(){
    echo -e "\n==================== 阶段2：压力老化测试开始 ====================" | tee -a "${LOG}"

    MONITOR_LOOP &
    MONITOR_PID=$!
    echo "后台实时温度功耗监控已启动" | tee -a "${LOG}"

    run_disk_fio

    echo -e "\n【2.2 CPU压力测试 ${TEST_TIME}秒】" | tee -a "${LOG}"
    if command -v stress-ng &>/dev/null;then
        stress-ng --cpu $(nproc) --cpu-method all --timeout ${TEST_TIME} >/dev/null 2>&1 &
        CPU_PID=$!
        echo "CPU压力测试已启动，共 $(nproc) 个逻辑核心" | tee -a "${LOG}"
    else
        echo "WARN: stress-ng未找到，跳过CPU压力测试" | tee -a "${LOG}"
    fi

    echo -e "\n【2.3 Memtester内存压力测试】" | tee -a "${LOG}"
    if command -v memtester &>/dev/null;then
        MEM_SIZE=$(LC_ALL=C free -m | awk -v r="${MEM_RATIO}" '/^Mem:/{print int($2*r/100)}')
        if [ -z "${MEM_SIZE}" ] || [ "${MEM_SIZE}" -lt 64 ];then
            echo "WARN: 无法确定可用内存或内存过小（${MEM_SIZE:-0}MB），跳过 memtester" | tee -a "${LOG}"
        else
            if [ -n "${MEMT_TIMEOUT}" ] && [ "${MEMT_TIMEOUT}" -gt 0 ]; then
                timeout "${MEMT_TIMEOUT}" memtester ${MEM_SIZE}M 1 >/dev/null 2>&1 &
            else
                memtester ${MEM_SIZE}M 1 >/dev/null 2>&1 &
            fi
            MEM_PID=$!
            echo "内存压力测试已启动，测试容量 ${MEM_SIZE}MB（约${MEM_RATIO}%总内存）" | tee -a "${LOG}"
        fi
    else
        echo "WARN: memtester未找到，跳过内存压力测试" | tee -a "${LOG}"
    fi

    echo -e "\n【2.4 GPU双精度压力烤机】" | tee -a "${LOG}"
    GPU_PID=""
    if command -v nvidia-smi &>/dev/null && command -v gpu-burn &>/dev/null && nvidia-smi &>/dev/null;then
        gpu-burn -d ${TEST_TIME} >/dev/null 2>&1 &
        GPU_PID=$!
        
        sleep 2
        if kill -0 "${GPU_PID}" 2>/dev/null; then
            echo "GPU双精度烤机已启动，时长 ${TEST_TIME} 秒" | tee -a "${LOG}"
        else
            echo "WARN：GPU双精度烤机启动失败，请检查 gpu-burn 及CUDA环境" | tee -a "${LOG}"
        fi
    else
        echo "WARN：缺少 gpu-burn 或显卡驱动异常，跳过GPU烤机" | tee -a "${LOG}"
    fi

    local wait_pids=()
    [ -n "${CPU_PID}" ] && wait_pids+=("${CPU_PID}")
    [ -n "${MEM_PID}" ] && wait_pids+=("${MEM_PID}")
    [ -n "${GPU_PID}" ] && wait_pids+=("${GPU_PID}")
    
    # 总超时保护：TEST_TIME 基础上再加 600 秒缓冲，防止压力项卡死
    local stress_deadline=$(( $(date +%s) + TEST_TIME + 600 ))
    if [ ${#wait_pids[@]} -gt 0 ]; then
        echo "所有压力项已启动，等待测试完成..." | tee -a "${LOG}"
        for pid in "${wait_pids[@]}"; do
            # 轮询等待单个进程退出（区分僵尸态），超过总时限则强制终止剩余进程
            while kill -0 "${pid}" 2>/dev/null && [ "$(awk '{print $3}' /proc/${pid}/stat 2>/dev/null)" != "Z" ]; do
                if [ "$(date +%s)" -ge "${stress_deadline}" ]; then
                    echo "WARN：压力测试超过总时限，强制终止剩余进程" | tee -a "${LOG}"
                    kill "${wait_pids[@]}" 2>/dev/null
                    wait "${wait_pids[@]}" 2>/dev/null
                    break 2
                fi
                sleep 2
            done
            wait "$pid"; rc=$?
            if [ ${rc} -ne 0 ]; then
                if [ "$pid" = "${CPU_PID}" ]; then
                    echo "WARN：CPU压力测试异常退出（返回码${rc}）" | tee -a "${LOG}"
                elif [ "$pid" = "${MEM_PID}" ]; then
                    if [ "${rc}" -eq 124 ]; then
                        echo "WARN：memtester 超过时限被终止（未发现错误，但未完成一轮完整校验）" | tee -a "${LOG}"
                    else
                        echo "WARN：内存压力测试异常退出（返回码${rc}，可能检测到内存错误）" | tee -a "${LOG}"
                        GLOBAL_FAIL=1
                    fi
                elif [ "$pid" = "${GPU_PID}" ]; then
                    echo "WARN：GPU双精度烤机异常退出（返回码${rc}），可能存在计算错误或硬件不稳定" | tee -a "${LOG}"
                fi
            fi
        done
    fi

    kill "${MONITOR_PID}" 2>/dev/null
    wait "${MONITOR_PID}" 2>/dev/null
    echo "后台实时监控已停止" | tee -a "${LOG}"

    # NCCL 带宽测试
    echo -e "\n【2.5 NCCL带宽测试】" | tee -a "${LOG}"
    export NCCL_IB_DISABLE=1
    export NCCL_P2P_DISABLE=0

    local gpu_cnt=0
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        gpu_cnt=$(nvidia-smi -L | wc -l)
    fi
    echo "   当前机器识别到有效 GPU 数量: ${gpu_cnt} 张" | tee -a "${LOG}"

    NCCL_TEST_DIR="./nccl-tests/build"
    NCCL_TEST_BIN="${NCCL_TEST_DIR}/all_reduce_perf"

    if [ ! -x "${NCCL_TEST_BIN}" ]; then
        echo "WARN：未找到 nccl-tests 可执行文件，跳过 NCCL 带宽测试" | tee -a "${LOG}"
    elif [ "${gpu_cnt}" -lt 2 ]; then
        echo "INFO：机器仅识别到 ${gpu_cnt} 张 GPU，无需进行多卡 NCCL 带宽测试，跳过。" | tee -a "${LOG}"
    else
        echo "开始执行 NCCL All Reduce 带宽测试 (使用 ${gpu_cnt} 张GPU)..." | tee -a "${LOG}"
        ${NCCL_TEST_BIN} -b 8M -e 1G -f 2 -g ${gpu_cnt} 2>&1 | tee -a "${LOG}"
        NCCL_RET=${PIPESTATUS[0]}
        
        if [ ${NCCL_RET} -eq 0 ]; then
            echo "NCCL 带宽测试执行完成 (PASS)" | tee -a "${LOG}"
        else
            echo "【警告】NCCL 带宽测试执行失败，返回码: ${NCCL_RET}" | tee -a "${LOG}"
            echo "   建议检查：GPU驱动、NVLink物理连接、PCIe降速情况。" | tee -a "${LOG}"
        fi
    fi

    echo -e "\n==================== 阶段2：压力老化测试结束 ====================" | tee -a "${LOG}"
}

# ====================== 主流程执行（顺序：预检→压测→日志巡检→温度告警） ======================
START_TS=$(date +%s)
hardware_pre_check
stress_stage

# 第一步：所有自动日志采集（dmesg + SEL）
error_log_check

# 第二步：检查温度告警
if [ -f "${TEMP_ALERT_FILE}" ];then
    echo -e "\n检测到CPU温度过高的告警记录" | tee -a "${LOG}"
    GLOBAL_FAIL=1
    rm -f "${TEMP_ALERT_FILE}"
fi

# 最终结论
ELAPSED=$(( $(date +%s) - START_TS ))
echo -e "\n================全部测试完成 $(date)================" | tee -a "${LOG}"
echo "设备SN:        ${SN}" | tee -a "${LOG}"
echo "测试人员工号:  ${testid}" | tee -a "${LOG}"
echo "日志目录:      ${TEST_DIR}" | tee -a "${LOG}"
echo "测试总耗时:    $((ELAPSED/3600))时$(((ELAPSED%3600)/60))分$((ELAPSED%60))秒" | tee -a "${LOG}"
echo "" | tee -a "${LOG}"
echo "----- 本次测试问题项汇总（FAIL）-----" | tee -a "${LOG}"
grep -E "FAIL" "${LOG}" | grep -v "问题项汇总" | tee -a "${LOG}" || true
if [ "${GLOBAL_FAIL}" -eq 0 ];then
    echo "【最终结果】ALL TEST PASS" | tee -a "${LOG}"
    exit 0
else
    echo "【最终结果】TEST FAIL：存在异常项，请查看日志！" | tee -a "${LOG}"
    exit 1
fi