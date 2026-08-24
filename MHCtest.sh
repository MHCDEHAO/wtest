#!/bin/bash
# ============================================================
# 服务器整机检测脚本（纯检测：预检+巡检+点灯+USB）
# 包含：CPU/GPU/风扇/电源/硬盘SMART/网卡/PCIe/CMOS 预检、
#       iperf3 打流、dmesg/SEL 巡检、硬盘点灯、USB 速率检测
# 压力项目（FIO/CPU/内存/GPU/NCCL）由 MHC.sh 脚本执行
# 用法：sudo bash MHCtest.sh
# 自动化：TEST_ID=DWZN123456 SERVER_SN=SN0001 LED_TEST=0 \
#   IPERF_PAIRS="10.0.1.1:10.0.1.2 10.0.2.1:10.0.2.2" \
#   全自动自回环（无需对端机器）：IPERF_AUTO_LOOPBACK=1，IPERF_PAIRS留空，自动找2个物理网口打流
#   sudo bash MHCtest.sh
# 日志输出：运行目录下 <SN>test1.log/ 文件夹
# ============================================================

# 纽扣电池低压告警阈值(V)
: "${BAT_LOW_VOLT:=2.7}"

# iperf3 打流配置：每根网线一组 "本机IP:对端IP"，自动逐对双向打流（先本机发送，再本机接收）
: "${IPERF_PAIRS:=}"              # 例："10.0.1.1:10.0.1.2 10.0.2.1:10.0.2.2"，插几根线写几组，为空则跳过；自回环：两个IP都写本机网卡IP（2口一组，4口两两一组），两网口需网线互连或接同一交换机
: "${IPERF_AUTO_LOOPBACK:=1}"       # 1=全自动自回环（IPERF_PAIRS留空时生效：自动找2个链路正常的物理网口打流，无需对端机器）
: "${IPERF_AUTO_IFACES:=}"          # 全自动自回环指定网口，如 "eth0 eth3"，空则自动挑选
: "${IPERF_PORT:=5202}"           # iperf 端口（默认5202，避开部分系统 iperf3 服务占用的5201）
: "${IPERF_TIME:=30}"             # 单次打流时长(秒)
: "${IPERF_PARALLEL:=8}"          # 并行流数
: "${IPERF_CONNECT_TIMEOUT:=10000}" # 单次连接超时(ms)，对端不可达时防止长时间卡住

# 网卡固件升级（默认关闭，避免误升级）
: "${NIC_FW_LOCAL_DIR:=./nic_fw}" # 网卡固件本地目录（预留）
: "${NIC_AUTO_UPGRADE:=0}"        # 1开启网卡固件升级，0关闭（预留）
: "${NIC_ONLINE_UPDATE:=0}"       # 0本地固件，1在线拉取固件（需外网）（预留）

# 自动化开关
: "${TEST_ID:=}"                  # 非交互模式下的测试人员工号
: "${SERVER_SN:=}"                # 非交互模式下的服务器 SN
: "${LED_TEST:=1}"                # 0 跳过硬盘指示灯人工确认测试
: "${MIN_YEAR:=2025}"             # 系统时间年份下限校验

# 全局标记
GLOBAL_FAIL=0
SN=""
testid=""
TEST_DIR=""                 # 专属日志文件夹：<SN>test1.log
LOG=""                      # 主日志
DMESG_LOG=""                # dmesg 专项日志（仅关键报错+原因注释）
SEL_LOG=""                  # BMC SEL 专项日志（仅关键告警+原因注释）
IPERF_PIDS=()              # iperf3 服务端后台进程PID列表
LB_NS_A="" LB_NS_B="" LB_IF_A="" LB_IF_B="" LB_RESTORE_A="" LB_RESTORE_B=""  # 自回环打流临时状态（异常退出时恢复用）

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
    pkg_map["iperf3"]="iperf3"
    pkg_map["ledctl"]="ledmon"
    pkg_map["dmesg"]="util-linux"
    pkg_map["findmnt"]="util-linux"
    pkg_map["lsblk"]="util-linux"
    pkg_map["lsusb"]="usbutils"

    # 不通过系统包管理器自动安装的工具
    local skip_auto=("nvidia-smi")

    # 全量检测清单
    local deps=("lspci" "findmnt" "lsblk" "lsusb" "ipmitool" "smartctl" "nvidia-smi" "iperf3" "dmesg" "ledctl")
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
            ${PKG_MGR} install -y epel-release >/dev/null 2>&1
        fi

        # 执行批量安装
        if [ "${PKG_MGR}" = "apt" ]; then
            apt update -y >/dev/null 2>&1
            apt install -y "${to_install[@]}" >/dev/null 2>&1
        else
            ${PKG_MGR} install -y "${to_install[@]}" >/dev/null 2>&1
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

    echo 

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

# ========== 创建文件夹：<SN>test1.log ==========
TEST_DIR="./${SN}test1.log"
mkdir -p "${TEST_DIR}"

LOG="${TEST_DIR}/main.log"
DMESG_LOG="${TEST_DIR}/dmesg.log"
SEL_LOG="${TEST_DIR}/sel.log"

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

# ========== 测试前双清空 ==========
echo -e "\n[INIT] 清空内核环形缓冲区（dmesg -C），开始记录本次测试内核日志" | tee -a "${LOG}"
dmesg -C 2>/dev/null

if command -v ipmitool &>/dev/null; then
    echo "[INIT] 清空 BMC 系统事件日志（ipmitool sel clear），开始记录本次测试硬件告警" | tee -a "${LOG}"
    ipmitool sel clear 2>/dev/null
    sleep 1
fi

# 异常退出清理函数
cleanup(){
    echo -e "\n[CLEANUP] 收到终止信号，清理临时文件" | tee -a "${LOG}"
    rm -rf pcinfo.txt pcinfo1.txt pcinfo2.txt net.txt block.txt /tmp/dmesg_filter_*.tmp /tmp/sel_filter_*.tmp

    # 异常退出自动熄灭所有硬盘灯
    command -v ledctl &>/dev/null && ledctl off=all 2>/dev/null

    # 关闭打流期间后台启动的 iperf3 服务端
    for pid in "${IPERF_PIDS[@]}";do
        kill "${pid}" 2>/dev/null
    done

    # 自回环中途被中断时：删除 netns 并恢复网口原IP
    if [ -n "${LB_NS_A}" ] || [ -n "${LB_NS_B}" ]; then
        echo "[CLEANUP] 清理自回环环境（${LB_NS_A}/${LB_NS_B}）并恢复网口IP" | tee -a "${LOG}"
        for p in $(ip netns pids "${LB_NS_A}" 2>/dev/null); do kill "${p}" 2>/dev/null; done
        for p in $(ip netns pids "${LB_NS_B}" 2>/dev/null); do kill "${p}" 2>/dev/null; done
        ip netns del "${LB_NS_A}" 2>/dev/null
        ip netns del "${LB_NS_B}" 2>/dev/null
        sleep 1
        [ -n "${LB_IF_A}" ] && ip link set "${LB_IF_A}" up 2>/dev/null
        [ -n "${LB_IF_B}" ] && ip link set "${LB_IF_B}" up 2>/dev/null
        for a in ${LB_RESTORE_A}; do [ -n "${LB_IF_A}" ] && ip addr add "${a}" dev "${LB_IF_A}" 2>/dev/null; done
        for a in ${LB_RESTORE_B}; do [ -n "${LB_IF_B}" ] && ip addr add "${a}" dev "${LB_IF_B}" 2>/dev/null; done
        LB_NS_A=""; LB_NS_B=""; LB_IF_A=""; LB_IF_B=""; LB_RESTORE_A=""; LB_RESTORE_B=""
    fi
}
trap cleanup SIGINT SIGTERM EXIT

# PCIe设备打印函数（正则精准解析速率/带宽，异常仅提示不终止）
# PCIe设备打印函数（正则精准解析速率/带宽，异常仅提示不终止）
sl(){
    lspci -D > pcinfo.txt
    lspci -D -vvv > pcinfo1.txt
    ls -l /sys/class/net | grep -v virtual > net.txt
    ls -l /sys/class/block | grep -v virtual > block.txt
    l=${m:-1}
    p=(Mellanox Co-processor VGA nvidia SAS Eth Fibre Non-Volatile)

    green=''
    yellow=''
    END=''
    ss=''
    if [ -t 1 ];then
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
    echo -e "\n【1.6 CMOS纽扣电池检测】" | tee -a "${LOG}"
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

    # 2. 硬件状态检测
    if [ "${bat_status}" != "ok" ]; then
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
            health_status="FAILED"
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
# 5.iperf3打流
##############################################################################
##############################################################################
# 5.1 本机双网口自回环打流（不需要对端机器）
# 用法：IPERF_PAIRS 里两个IP都写本机网卡IP即自回环，如 "10.0.1.1:10.0.1.2"
#      4网口可两两一组：IPERF_PAIRS="10.0.1.1:10.0.1.2 10.0.2.1:10.0.2.2"
# 前提：每个配对的2个网口用网线互连，或都接入同一台交换机；
#       脚本用 netns 把2个网口隔离成独立命名空间，流量真实经过物理网卡和
#       网线（不走过回环口lo）；测试期间2个网口会短暂脱离主机网络配置，
#       测完自动恢复原IP。若网口被SSH远程使用，请改用其他口管理。
##############################################################################
self_loopback_iperf(){
    local ip_a="$1" ip_b="$2" iface_b="$3"
    local iface_a
    iface_a=$(ip -o addr show 2>/dev/null | awk -v ip="${ip_a}" '$4 ~ "^"ip"/" {print $2; exit}')
    if [ -z "${iface_a}" ]; then
        echo "WARN: 自回环配对 ${ip_a} 未配置在本机网卡上，跳过该对" | tee -a "${LOG}"
        return
    fi
    if [ "${iface_a}" = "${iface_b}" ]; then
        echo "WARN: 自回环配对 ${ip_a}/${ip_b} 在同一网口（${iface_a}），本机自回环需要2个不同的网口，跳过该对" | tee -a "${LOG}"
        return
    fi
    local carrier_a carrier_b
    carrier_a=$(cat /sys/class/net/"${iface_a}"/carrier 2>/dev/null)
    carrier_b=$(cat /sys/class/net/"${iface_b}"/carrier 2>/dev/null)
    if [ "${carrier_a}" != "1" ] || [ "${carrier_b}" != "1" ]; then
        echo "WARN: 自回环网口链路未就绪（${iface_a}=${carrier_a:-无}，${iface_b}=${carrier_b:-无}），请用网线互连两个网口或接入同一交换机后重试" | tee -a "${LOG}"
        return
    fi

    local ns_a="dwt_lb_a_$$" ns_b="dwt_lb_b_$$"
    echo "" | tee -a "${LOG}"
    echo "----- 本机自回环对 ${ip_a}（${iface_a}）↔ ${ip_b}（${iface_b}）打流测试 -----" | tee -a "${LOG}"

    # 记录原IP配置（netns 删除后用于恢复）
    LB_RESTORE_A=$(ip -o addr show dev "${iface_a}" 2>/dev/null | awk '$3=="inet"{print $4}')
    LB_RESTORE_B=$(ip -o addr show dev "${iface_b}" 2>/dev/null | awk '$3=="inet"{print $4}')
    LB_IF_A="${iface_a}"; LB_IF_B="${iface_b}"; LB_NS_A="${ns_a}"; LB_NS_B="${ns_b}"

    ip netns add "${ns_a}" 2>/dev/null || { echo "FAIL: 创建 netns ${ns_a} 失败，跳过自回环" | tee -a "${LOG}"; GLOBAL_FAIL=1; return; }
    ip netns add "${ns_b}" 2>/dev/null || { echo "FAIL: 创建 netns ${ns_b} 失败，跳过自回环" | tee -a "${LOG}"; ip netns del "${ns_a}" 2>/dev/null; GLOBAL_FAIL=1; return; }

    if ! ip link set "${iface_a}" netns "${ns_a}" 2>/dev/null; then
        echo "FAIL: 移动 ${iface_a} 到 ${ns_a} 失败，跳过自回环" | tee -a "${LOG}"
        ip netns del "${ns_a}" 2>/dev/null; ip netns del "${ns_b}" 2>/dev/null
        GLOBAL_FAIL=1; return
    fi
    if ! ip link set "${iface_b}" netns "${ns_b}" 2>/dev/null; then
        echo "FAIL: 移动 ${iface_b} 到 ${ns_b} 失败，跳过自回环" | tee -a "${LOG}"
        ip netns del "${ns_a}" 2>/dev/null; ip netns del "${ns_b}" 2>/dev/null
        GLOBAL_FAIL=1; return
    fi

    # 两个 netns 内各自配置IP与对端路由（/32 + 显式路由，不依赖子网划分）
    ip netns exec "${ns_a}" ip link set lo up 2>/dev/null
    ip netns exec "${ns_a}" ip link set "${iface_a}" up 2>/dev/null
    ip netns exec "${ns_a}" ip addr add "${ip_a}/32" dev "${iface_a}" 2>/dev/null
    ip netns exec "${ns_a}" ip route add "${ip_b}/32" dev "${iface_a}" 2>/dev/null
    ip netns exec "${ns_b}" ip link set lo up 2>/dev/null
    ip netns exec "${ns_b}" ip link set "${iface_b}" up 2>/dev/null
    ip netns exec "${ns_b}" ip addr add "${ip_b}/32" dev "${iface_b}" 2>/dev/null
    ip netns exec "${ns_b}" ip route add "${ip_a}/32" dev "${iface_b}" 2>/dev/null

    echo "自回环环境已就绪（${ns_a}/${ns_b}），开始双向打流..." | tee -a "${LOG}"
    echo "== 正向（${iface_a} 发送 → ${iface_b} 接收）==" | tee -a "${LOG}"
    ip netns exec "${ns_b}" iperf3 -s -B "${ip_b}" -p "${IPERF_PORT}" >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 0.5
    timeout "${iperf_timeout}" ip netns exec "${ns_a}" iperf3 -c "${ip_b}" -B "${ip_a}" -p "${IPERF_PORT}" -t "${IPERF_TIME}" -P "${IPERF_PARALLEL}" ${CONNECT_TIMEOUT_OPT} 2>&1 | tee -a "${LOG}"
    local fwd_rc=${PIPESTATUS[0]}
    echo "== 反向（${iface_b} 发送 → ${iface_a} 接收）==" | tee -a "${LOG}"
    timeout "${iperf_timeout}" ip netns exec "${ns_a}" iperf3 -c "${ip_b}" -B "${ip_a}" -p "${IPERF_PORT}" -t "${IPERF_TIME}" -P "${IPERF_PARALLEL}" -R ${CONNECT_TIMEOUT_OPT} 2>&1 | tee -a "${LOG}"
    local rev_rc=${PIPESTATUS[0]}

    # 清理：停服务端、删 netns（网口自动回到主机命名空间）、恢复原IP
    kill "${srv_pid}" 2>/dev/null
    for p in $(ip netns pids "${ns_b}" 2>/dev/null); do kill "${p}" 2>/dev/null; done
    for p in $(ip netns pids "${ns_a}" 2>/dev/null); do kill "${p}" 2>/dev/null; done
    ip netns del "${ns_a}" 2>/dev/null
    ip netns del "${ns_b}" 2>/dev/null
    sleep 1
    ip link set "${iface_a}" up 2>/dev/null
    ip link set "${iface_b}" up 2>/dev/null
    for a in ${LB_RESTORE_A}; do ip addr add "${a}" dev "${iface_a}" 2>/dev/null; done
    for a in ${LB_RESTORE_B}; do ip addr add "${a}" dev "${iface_b}" 2>/dev/null; done
    LB_NS_A=""; LB_NS_B=""; LB_IF_A=""; LB_IF_B=""; LB_RESTORE_A=""; LB_RESTORE_B=""

    if [ "${fwd_rc}" -ne 0 ] || [ "${rev_rc}" -ne 0 ];then
        echo "FAIL：自回环对 ${ip_a} ↔ ${ip_b} 打流异常（正向RC=${fwd_rc}，反向RC=${rev_rc}），请检查网线/网口" | tee -a "${LOG}"
        GLOBAL_FAIL=1
    else
        echo "自回环对 ${ip_a} ↔ ${ip_b} 双向打流 PASS（时长${IPERF_TIME}s，并行${IPERF_PARALLEL}流）" | tee -a "${LOG}"
    fi
}

##############################################################################
# 5.2 全自动自回环打流（无需配IP、无需指定IPERF_PAIRS）
# 触发：IPERF_AUTO_LOOPBACK=1 且 IPERF_PAIRS 为空
# 行为：自动挑选2个"链路已连接(carrier=1)的物理网口"，临时分配
#       192.0.2.1 / 192.0.2.2（RFC5737 文档保留网段，不会与真实网络冲突），
#       双向打流完成后自动清理临时IP并恢复原配置
# 指定网口：IPERF_AUTO_IFACES="eth0 eth3"（可选；不填则自动挑选）
# 注意：自动挑选可能选中管理网口，测试期间该口会短暂断网，建议用
#       IPERF_AUTO_IFACES 明确指定非管理网口
##############################################################################
auto_loopback_iperf(){
    local if_a="" if_b=""
    if [ -n "${IPERF_AUTO_IFACES}" ]; then
        set -- ${IPERF_AUTO_IFACES}
        if_a="$1"; if_b="$2"
        if [ -z "${if_a}" ] || [ -z "${if_b}" ] || [ "${if_a}" = "${if_b}" ]; then
            echo "FAIL: IPERF_AUTO_IFACES 需指定2个不同的网口（如 eth0 eth3），跳过自回环" | tee -a "${LOG}"
            GLOBAL_FAIL=1
            return
        fi
        if [ ! -d "/sys/class/net/${if_a}" ] || [ ! -d "/sys/class/net/${if_b}" ]; then
            echo "FAIL: 指定的网口不存在（${if_a}/${if_b}），跳过自回环" | tee -a "${LOG}"
            GLOBAL_FAIL=1
            return
        fi
    else
        # 自动挑选：链路已连接(carrier=1)的物理网口（有 /sys/class/net/<if>/device 视为物理口）
        local picked=()
        for d in /sys/class/net/*; do
            local ifc
            ifc=$(basename "${d}")
            [ "${ifc}" = "lo" ] && continue
            [ -d "${d}/device" ] || continue
            [ "$(cat "${d}/carrier" 2>/dev/null)" = "1" ] || continue
            picked+=("${ifc}")
            [ ${#picked[@]} -ge 2 ] && break
        done
        if [ ${#picked[@]} -lt 2 ]; then
            echo "WARN: 自动未找到2个链路已连接的物理网口（找到：${picked[*]:-无}），跳过自回环打流" | tee -a "${LOG}"
            return
        fi
        if_a="${picked[0]}"; if_b="${picked[1]}"
    fi

    echo "" | tee -a "${LOG}"
    echo "----- 全自动自回环打流：${if_a} ↔ ${if_b}（临时IP 192.0.2.1 / 192.0.2.2） -----" | tee -a "${LOG}"
    echo "WARN: 测试期间 ${if_a}/${if_b} 会短暂脱离主机网络配置，测完自动恢复" | tee -a "${LOG}"

    local ca cb
    ca=$(cat /sys/class/net/"${if_a}"/carrier 2>/dev/null)
    cb=$(cat /sys/class/net/"${if_b}"/carrier 2>/dev/null)
    if [ "${ca}" != "1" ] || [ "${cb}" != "1" ]; then
        echo "WARN: 网口链路未连接（${if_a}=${ca:-无}，${if_b}=${cb:-无}），请确认两个口已用网线互连或接同一交换机" | tee -a "${LOG}"
        return
    fi

    # 临时IP（RFC5737 文档保留网段，避免冲突）
    local tmp_a="192.0.2.1" tmp_b="192.0.2.2"
    ip addr add "${tmp_a}/32" dev "${if_a}" 2>/dev/null
    ip addr add "${tmp_b}/32" dev "${if_b}" 2>/dev/null

    self_loopback_iperf "${tmp_a}" "${tmp_b}" "${if_b}"

    # 清理临时IP
    ip addr del "${tmp_a}/32" dev "${if_a}" 2>/dev/null
    ip addr del "${tmp_b}/32" dev "${if_b}" 2>/dev/null
    echo "全自动自回环打流结束，临时IP已清理" | tee -a "${LOG}"
}

run_iperf(){
    echo -e "\n【1.5 网卡iperf3打流测试】" | tee -a "${LOG}"
    if ! command -v iperf3 &>/dev/null;then
        echo "iperf3未安装，跳过打流" | tee -a "${LOG}"
        return
    fi
    if [ -z "${IPERF_PAIRS}" ];then
        if [ "${IPERF_AUTO_LOOPBACK}" = "1" ]; then
            auto_loopback_iperf
        else
            echo "未配置打流网口对（IPERF_PAIRS），跳过打流；如需全自动自回环请设 IPERF_AUTO_LOOPBACK=1" | tee -a "${LOG}"
        fi
        return
    fi

    # ===== 超时兜底设置（防止连接卡死/异常挂起） =====
    # 单次打流命令超时 = 打流时长 + 20秒余量
    iperf_timeout=$(( IPERF_TIME + 20 ))
    # 整段打流总超时 = 网口对数 × 2（正向+反向）× 单次超时 + 30秒启动/收尾余量
    pair_count=$(echo ${IPERF_PAIRS} | wc -w)
    IPERF_START=$(date +%s)
    IPERF_DEADLINE=$(( IPERF_START + pair_count * 2 * iperf_timeout + 30 ))
    # iperf3 连接超时参数（3.9+支持；老版本自动去掉该参数，仅靠 timeout 兜底）
    CONNECT_TIMEOUT_OPT=""
    if iperf3 --help 2>/dev/null | grep -q -- "--connect-timeout"; then
        CONNECT_TIMEOUT_OPT="--connect-timeout ${IPERF_CONNECT_TIMEOUT}"
    fi
    echo "打流超时设置：单次≤${iperf_timeout}s，整段≤${IPERF_DEADLINE}（截止时刻），连接超时=${IPERF_CONNECT_TIMEOUT}ms" | tee -a "${LOG}"

    # 第一遍：为"本机对远端"模式在本机后台启动 iperf3 服务端；
    # 自回环配对（两个IP都在本机）统一在 self_loopback_iperf 里处理，这里不起服务端
    for pair in ${IPERF_PAIRS}; do
        local_ip="${pair%%:*}"
        [ -z "${local_ip}" ] && continue

        peer_ip="${pair#*:}"
        if [ -n "${peer_ip}" ]; then
            lb_iface=$(ip -o addr show 2>/dev/null | awk -v ip="${peer_ip}" '$4 ~ "^"ip"/" {print $2; exit}')
            [ -n "${lb_iface}" ] && continue
        fi

        # 打流前自动校验：本机IP是否已配置在网卡上、网线是否插好（不合法提前提示，不白等）
        iface=$(ip -o addr show 2>/dev/null | awk -v ip="${local_ip}" '$4 ~ "^"ip"/" {print $2; exit}')
        if [ -z "${iface}" ]; then
            echo "WARN: 本机IP ${local_ip} 未配置在网卡上，该对打流将失败（请检查IPERF_PAIRS配置）" | tee -a "${LOG}"
        else
            carrier=$(cat /sys/class/net/"${iface}"/carrier 2>/dev/null)
            if [ "${carrier}" != "1" ]; then
                echo "WARN: ${local_ip}（网口${iface}）网线未连接（carrier=${carrier:-无}），请检查网线/对端设备" | tee -a "${LOG}"
            fi
        fi

        iperf3 -s -B "${local_ip}" -p "${IPERF_PORT}" >/dev/null 2>&1 &
        srv_pid=$!
        IPERF_PIDS+=(${srv_pid})
        sleep 0.3
        if kill -0 "${srv_pid}" 2>/dev/null; then
            echo "本机服务端已启动：${local_ip}:${IPERF_PORT}（后台，测试结束自动关闭）" | tee -a "${LOG}"
        else
            echo "WARN: 本机服务端启动失败（${local_ip}:${IPERF_PORT}，端口被占用或IP未配置），本机打流不受影响，但对端连入本机可能失败" | tee -a "${LOG}"
        fi
    done
    sleep 1

    # 第二遍：逐对双向打流（先本机发送（正向），再本机接收（反向 -R））
    for pair in ${IPERF_PAIRS}; do
        # 整段总超时兜底：超过截止时刻直接终止剩余网口对，防止意外卡死
        if [ "$(date +%s)" -ge "${IPERF_DEADLINE}" ]; then
            echo "WARN: 打流总时长已达上限，提前终止剩余网口对（防止卡死）" | tee -a "${LOG}"
            break
        fi
        local_ip="${pair%%:*}"
        peer_ip="${pair#*:}"
        if [ -z "${local_ip}" ] || [ -z "${peer_ip}" ];then
            echo "WARN: 打流配置格式错误（应为 本机IP:对端IP）：${pair}，跳过该对" | tee -a "${LOG}"
            continue
        fi
        # 对端IP也是本机网卡地址 → 本机双口自回环（无需对端机器）
        lb_iface=$(ip -o addr show 2>/dev/null | awk -v ip="${peer_ip}" '$4 ~ "^"ip"/" {print $2; exit}')
        if [ -n "${lb_iface}" ]; then
            self_loopback_iperf "${local_ip}" "${peer_ip}" "${lb_iface}"
            continue
        fi
        echo "" | tee -a "${LOG}"
        echo "----- 网口对 ${local_ip} ↔ ${peer_ip} 打流测试 -----" | tee -a "${LOG}"
        echo "== 正向（本机发送 → 对端接收）==" | tee -a "${LOG}"
        timeout "${iperf_timeout}" iperf3 -c "${peer_ip}" -B "${local_ip}" -p "${IPERF_PORT}" -t "${IPERF_TIME}" -P "${IPERF_PARALLEL}" ${CONNECT_TIMEOUT_OPT} 2>&1 | tee -a "${LOG}"
        fwd_rc=${PIPESTATUS[0]}
        echo "== 反向（对端发送 → 本机接收）==" | tee -a "${LOG}"
        timeout "${iperf_timeout}" iperf3 -c "${peer_ip}" -B "${local_ip}" -p "${IPERF_PORT}" -t "${IPERF_TIME}" -P "${IPERF_PARALLEL}" -R ${CONNECT_TIMEOUT_OPT} 2>&1 | tee -a "${LOG}"
        rev_rc=${PIPESTATUS[0]}
        if [ "${fwd_rc}" -ne 0 ] || [ "${rev_rc}" -ne 0 ];then
            echo "FAIL：网口对 ${local_ip} ↔ ${peer_ip} 打流异常（正向RC=${fwd_rc}，反向RC=${rev_rc}）" | tee -a "${LOG}"
            GLOBAL_FAIL=1
        else
            echo "网口对 ${local_ip} ↔ ${peer_ip} 双向打流 PASS（时长${IPERF_TIME}s，并行${IPERF_PARALLEL}流）" | tee -a "${LOG}"
        fi
    done
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
    run_iperf
    nic_fw_update

    echo -e "\n【1.7 PCIe带宽链路信息采集】" | tee -a "${LOG}"
    m=1
    sl 2>/dev/null | tee -a "${LOG}"

    echo -e "\n【1.8 BMC待机功耗读取】" | tee -a "${LOG}"
    if command -v ipmitool &> /dev/null;then
        ipmitool sensor 2>/dev/null | grep -i power | tee -a "${LOG}"
    fi

    check_cmos_battery

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
# 内核日志 & BMC SEL 日志巡检
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
# 硬盘指示灯点灯测试
##############################################################################
hdd_led_test(){
    echo -e "\n==================== 硬盘指示灯点灯测试 ====================" | tee -a "${LOG}"
    echo "【3.3 HDD LED 定位/故障灯测试】" | tee -a "${LOG}"

    if [ "${LED_TEST}" != "1" ]; then
        echo "WARN: LED_TEST=${LED_TEST}，已跳过硬盘指示灯人工确认测试" | tee -a "${LOG}"
        return
    fi
    if [ ! -t 0 ]; then
        echo "WARN: 当前为非交互终端，无法人工确认指示灯，跳过点灯测试" | tee -a "${LOG}"
        echo "  如需无人值守运行请设置 LED_TEST=0" | tee -a "${LOG}"
        return
    fi

    if ! command -v ledctl &>/dev/null; then
        echo "WARN: 未检测到 ledctl 命令，跳过硬盘点灯测试" | tee -a "${LOG}"
        echo "  安装方式：CentOS执行 yum install -y ledmon；Ubuntu执行 apt install -y ledmon" | tee -a "${LOG}"
        return
    fi

    SYS_DISK=$(get_root_disk)
    if [ -z "${SYS_DISK}" ]; then
        echo "WARN：无法识别系统盘，为安全起见跳过点灯测试" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi
    echo "识别到系统盘: /dev/${SYS_DISK}（自动排除，不参与点灯）" | tee -a "${LOG}"

    DISK_LIST=$(lsblk -d -o NAME,TYPE | grep -E "disk" | grep -v loop | awk '{print $1}' | grep -v NAME | grep -v "^${SYS_DISK}$")

    if [ -z "${DISK_LIST}" ]; then
        echo "WARN：未找到可测试的数据盘，跳过点灯测试" | tee -a "${LOG}"
        return
    fi

    disk_str=""
    disk_count=0
    for d in ${DISK_LIST}; do
        disk_str="${disk_str}/dev/${d},"
        disk_count=$((disk_count + 1))
    done
    disk_str=${disk_str%,}

    echo "待测数据盘数量: ${disk_count}" | tee -a "${LOG}"
    echo "待点灯设备: ${disk_str}" | tee -a "${LOG}"
    echo ""

    # 第1步：蓝色定位灯
    echo ">>> 第1步：点亮蓝色定位灯（locate）" | tee -a "${LOG}"
    ledctl locate="${disk_str}" 2>/dev/null
    read -n1 -p "  请目视确认蓝灯正常闪烁，确认请按 y，其他键终止测试：" input1
    echo ""
    if [ "${input1}" != "y" ]; then
        echo "FAIL：蓝灯测试未通过，已终止" | tee -a "${LOG}"
        ledctl off="${disk_str}" 2>/dev/null
        GLOBAL_FAIL=1
        return
    fi
    echo "  蓝色定位灯测试 PASS" | tee -a "${LOG}"

    # 第2步：橙色故障灯
    echo ">>> 第2步：点亮橙色故障灯（failure）" | tee -a "${LOG}"
    ledctl failure="${disk_str}" 2>/dev/null
    read -n1 -p "  请目视确认橙灯正常点亮，确认请按 y，其他键终止测试：" input2
    echo ""
    if [ "${input2}" != "y" ]; then
        echo "FAIL：橙灯测试未通过，已终止" | tee -a "${LOG}"
        ledctl off="${disk_str}" 2>/dev/null
        GLOBAL_FAIL=1
        return
    fi
    echo "  橙色故障灯测试 PASS" | tee -a "${LOG}"

    # 第3步：熄灭所有指示灯
    echo ">>> 第3步：熄灭所有指示灯（off）" | tee -a "${LOG}"
    ledctl off="${disk_str}" 2>/dev/null
    read -n1 -p "  请目视确认所有指示灯已熄灭，确认请按 y，其他键终止测试：" input3
    echo ""
    if [ "${input3}" != "y" ]; then
        echo "FAIL：灭灯测试未通过" | tee -a "${LOG}"
        GLOBAL_FAIL=1
        return
    fi
    echo "  指示灯熄灭测试 PASS" | tee -a "${LOG}"

    echo ""
    echo "硬盘指示灯三项测试全部 PASS" | tee -a "${LOG}"
    echo "========================================================" | tee -a "${LOG}"
}
##############################################################################
##############################################################################
# USB 接口/设备速率检测（人工插拔判定模式）
# 显示lsusb信息供参考，人工插拔确认后填入数量，不判FAIL
##############################################################################
usb_check(){
    echo -e "\n==================== USB 接口速率检测（人工判定）====================" | tee -a "${LOG}"
    if ! command -v lsusb &>/dev/null; then
        echo "WARN: 未找到 lsusb（usbutils），跳过 USB 检测" | tee -a "${LOG}"
        return
    fi
    echo "==== USB 总线拓扑（每个口/设备的速率）====" | tee -a "${LOG}"
    lsusb -t | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"
    echo "==== 所有已接设备的速率分布（参考）====" | tee -a "${LOG}"
    lsusb -t | grep -oiE "driver=[^,]+, [0-9]+M" | sort | uniq -c | sort -rn | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"
    echo "==== 主控制器类型（xhci=支持USB3，ehci/ohci=仅USB2）====" | tee -a "${LOG}"
    lsusb -t | grep "root_hub" | sed 's/^.*Driver=//' | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"
    echo "说明：请依次将USB设备插入各端口，观察lsusb速率（5000M=USB3.x，480M=USB2.0，12M=USB1.1），确认后填写下方数量" | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"

    # 人工录入数量
    usb3_count=0
    usb2_count=0
    usb1_count=0

    read -p "请输入检测到的 USB3.x (5000M) 设备数量: " usb3_count
    read -p "请输入检测到的 USB2.0  (480M)  设备数量: " usb2_count
    read -p "请输入检测到的 USB1.1  (12M)   设备数量: " usb1_count

    echo "" | tee -a "${LOG}"
    echo "==== USB 人工判定结果 ====" | tee -a "${LOG}"
    echo "USB3.x (5000M): ${usb3_count} 个" | tee -a "${LOG}"
    echo "USB2.0 (480M):  ${usb2_count} 个" | tee -a "${LOG}"
    echo "USB1.1 (12M):   ${usb1_count} 个" | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"
    echo "【USB检测结果】人工判定完成，无FAIL项，请确认数量无误后继续" | tee -a "${LOG}"
    echo "========================================================" | tee -a "${LOG}"
}

# ====================== 主流程执行（整机检测：预检→巡检→点灯→USB） ======================
START_TS=$(date +%s)

hardware_pre_check

# 日志巡检（dmesg + SEL）
error_log_check

# 人工判定：硬盘指示灯点灯测试
hdd_led_test

# USB 接口速率检测（放最后面）
usb_check

# 最终结论
ELAPSED=$(( $(date +%s) - START_TS ))
echo -e "\n================整机检测完成 $(date)================" | tee -a "${LOG}"
echo "设备SN:        ${SN}" | tee -a "${LOG}"
echo "测试人员工号:  ${testid}" | tee -a "${LOG}"
echo "日志目录:      ${TEST_DIR}" | tee -a "${LOG}"
echo "测试总耗时:    $((ELAPSED/3600))时$(((ELAPSED%3600)/60))分$((ELAPSED%60))秒" | tee -a "${LOG}"
echo "" | tee -a "${LOG}"
echo "----- 本次测试问题项汇总（FAIL）-----" | tee -a "${LOG}"
grep -E "FAIL" "${LOG}" | grep -v "问题项汇总" | tee -a "${LOG}" || true
if [ "${GLOBAL_FAIL}" -eq 0 ];then
    echo "【最终结果】ALL TEST PASS（人为判定项目请确保无误）" | tee -a "${LOG}"
    exit 0
else
    echo "【最终结果】TEST FAIL：存在异常项，请查看日志！" | tee -a "${LOG}"
    exit 1
fi
