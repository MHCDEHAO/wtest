#!/bin/bash
# ============================================================
# 服务器整机老化压力测试脚本（CPU/内存用 stress-ng，GPU 用 gpu-burn，硬盘用 fio）
# 作者：蒙泓呈
# 适用：x86 服务器（GPU 可选，缺失自动跳过）
# 用法：sudo bash lhtest.sh
# 自动化/非交互运行示例：
#   TEST_ID=任意字符串 SERVER_SN=SN0001 \
#   TEST_TIME=600 MEM_RATIO=80 \
#   sudo bash lhtest.sh
# 温度保护（阈值与《服务器整机测试验收标准作业程序（SOP）》8.2 判定标准一致）：
#   CPU：> CPU_TEMP_WARN(80℃) 记告警并计入最终 FAIL；> CPU_TEMP_ABORT(90℃) 立即中止。
#   GPU：> GPU_TEMP_WARN(87℃ = SOP 稳态线) 记告警并计入最终 FAIL；
#        > GPU_TEMP_ABORT(95℃ = SOP 热点线) 立即中止压力测试。
#   硬盘：按盘型分阈值（机械盘 WARN 53℃ / ABORT 58℃，固态盘 WARN 68℃ / ABORT 78℃）——
#        HDD 是寿命问题（45℃ 以上开始折寿，spec 工作上限 60℃），
#        SSD 是性能问题（NVMe TMT1 约 80℃ 降速、TMT2 约 85℃ 停 IO）。
#   采样粒度：CPU/GPU 10 秒，硬盘 60 秒。告警与中止都会让脚本以退出码 1（TEST FAIL）结束。
# 硬盘压测：裸盘直写（会清除盘上数据），选盘逻辑复用 fio.sh，跑前列出待测盘并人工确认；
#   多盘并行、共用 TEST_TIME；只判定有无报错，不显示带宽 / IOPS；压测后复测 SMART。
# 日志输出：运行目录下 <SN>-lhtest-log/ 文件夹
# ============================================================

# 时长配置（秒），均支持环境变量覆盖
: "${TEST_TIME:=21600}"            # CPU/GPU/内存/硬盘 压力测试时长
: "${MEM_RATIO:=75}"              # stress-ng 内存占用比例(%)
: "${CPU_TEMP_WARN:=80}"          # CPU 温度告警阈值(℃)＝SOP 8.2 合格线：超限记告警并计入最终 FAIL
: "${CPU_TEMP_ABORT:=90}"         # CPU 温度中断阈值(℃)：超过立即中止压力测试
: "${GPU_TEMP_WARN:=87}"          # GPU 温度告警阈值(℃)＝SOP 8.2 稳态线：超限记告警并计入最终 FAIL
: "${GPU_TEMP_ABORT:=95}"         # GPU 温度中断阈值(℃)＝SOP 8.2 热点线：超过立即中止压力测试
: "${GPU_CLK_WARN_PCT:=90}"       # GPU 降频告警线(%)：SM 时钟低于满频该比例即记告警并抓降频原因
: "${TEMP_ABORT_GRACE:=1}"        # 连续超阈值采样次数达到该值才中止（默认 1 次即中止）
: "${CPU_TEMP_FAIL:=95}"          # CPU 温度判 FAIL 阈值(℃)：内核日志巡检中温度读数超过该值直接判 FAIL

# 自动化开关
: "${TEST_ID:=}"                  # 非交互模式下的测试人员工号（任意字符串）
: "${SERVER_SN:=}"                # 非交互模式下的服务器 SN
: "${MIN_YEAR:=2025}"             # 系统时间年份下限校验
: "${SEL_STRICT:=0}"              # =1 时 BMC SEL 的 WARN 级事件也计入失败（默认仅 FAIL 级判不合格）

# ---- 硬盘老化压测（裸盘直写，会清除盘上数据）----
# 选盘逻辑复用 fio.sh；跑前会列出待测盘清单并要求人工确认
: "${DISK_TEST_ENABLE:=1}"        # 1=启用硬盘压测
: "${DISK_TEST_DEVS:=}"           # 显式指定盘名，如 "sdb nvme1n1"；留空则自动选盘
: "${DISK_TEST_RW:=randrw}"       # fio 读写模式
: "${DISK_TEST_RWMIXREAD:=70}"    # randrw 模式下读占比(%)
: "${DISK_TEST_BS:=4k}"           # 块大小
: "${DISK_TEST_VERIFY:=1}"        # 1=开启 crc32c 数据校验
: "${DISK_TEST_CONFIRM:=}"        # =yes 时非交互模式也直接放行（自动化用）
: "${FIO_MIN_SIZE_GB:=1}"         # 自动选盘容量下限(GiB)，沿用 fio.sh

# ---- 硬盘温度阈值（℃）----
# 依据：HDD 厂商 spec 工作上限 60℃、正常运行 30~40℃；SSD 的 NVMe TMT1 默认约 80℃。
# 在推荐值（HDD 50/55、SSD 65/75）基础上统一 +3℃。
: "${DISK_TEMP_WARN_HDD:=53}"     # 机械盘告警：超限记 WARN 并计入最终 FAIL
: "${DISK_TEMP_ABORT_HDD:=58}"    # 机械盘中止：超过立即中止压力测试
: "${DISK_TEMP_WARN_SSD:=68}"     # 固态盘告警
: "${DISK_TEMP_ABORT_SSD:=78}"    # 固态盘中止

# 全局标记
GLOBAL_FAIL=0
CPU_PID=""
GPU_PID=""
MONITOR_PID=""
DISK_PIDS=()                                 # 硬盘压测后台 PID（多盘并行）
DISK_RC=()                                   # 各盘 fio 退出码，与 DISK_DEVS 同序
DISK_DEVS=()                                 # 本次实际压测的裸设备名
DISK_STARTED=0                               # 硬盘压测是否已启动
SYS_DISK=""                                  # 系统盘设备名
DISK_COUNTERS_BEFORE=""                      # 压测前 SMART 关键计数快照
DISK_COUNTERS_AFTER=""                       # 压测后 SMART 关键计数快照
SN=""
testid=""
TEST_DIR=""
LOG=""
DMESG_LOG=""
SEL_LOG=""
DMESG_FULL_LOG=""
SEL_RAW_LOG=""
DMESG_W_PID=""
TEMP_ALERT_FILE="/tmp/cpu_temp_alert_$$"     # 告警（未达中断阈值）标记
TEMP_ABORT_FILE="/tmp/temp_abort_$$"         # 高温中断标记，内容为中文原因
STRESS_PID_FILE="/tmp/stress_pids_$$"        # 烤机进程 PID 列表，供监控循环高温时回收
THROTTLE_ALERT_FILE="/tmp/gpu_throttle_alert_$$"   # GPU 降频告警标记（只记录+取证，不中止测试）
CPU_TEMP_FALLBACK=0                          # =1 表示当前 CPU 温度取的是全量传感器最大值

# 兼容旧变量名：自动化环境若仍在用 CPU_TEMP_ALERT，按中断阈值处理
[ -n "${CPU_TEMP_ALERT:-}" ] && CPU_TEMP_ABORT="${CPU_TEMP_ALERT}"

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
    pkg_map["stress-ng"]="stress-ng"
    pkg_map["dmesg"]="util-linux"
    pkg_map["smartctl"]="smartmontools"   # 用于磁盘温度监控（可选）
    pkg_map["ipmitool"]="ipmitool"        # 用于温度监控
    # rasdaemon：把 EDAC 的 mc/csrow 编号翻译成主板丝印（DIMM_A2 这种），
    # 提供 --register-labels / --layout / --errors 三个命令。
    # 缺失时降级为「只读 sysfs 计数器」，不阻断流程。
    pkg_map["ras-mc-ctl"]="rasdaemon"
    # 硬盘压测启用时才纳入 fio：pkg_map 的 key 会被下面的安装结果复查遍历，
    # 未启用却留着 fio 会误报「自动安装失败」
    if [ "${DISK_TEST_ENABLE}" = "1" ]; then
        pkg_map["fio"]="fio"
    fi

    local skip_auto=("nvidia-smi" "gpu-burn")

    local deps=("stress-ng" "nvidia-smi" "dmesg" "smartctl" "ipmitool" "gpu-burn" "ras-mc-ctl")
    if [ "${DISK_TEST_ENABLE}" = "1" ]; then
        deps+=("fio")
    fi
    local missing=()
    local to_install=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
            if [[ ! " ${skip_auto[*]} " =~ " ${dep} " ]]; then
                to_install+=("${pkg_map[$dep]}")
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

    if [ ${#to_install[@]} -gt 0 ] && [ -n "$PKG_MGR" ]; then
        echo "  [INFO] 检测到包管理器：${PKG_MGR}，正在自动安装基础依赖..."
        echo "  待安装包：${to_install[*]}"

        if [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            $PKG_MGR install -y epel-release >/dev/null 2>&1
        fi

        if [ "$PKG_MGR" = "apt" ]; then
            # apt update 不接受 -y（会报 "Command line option -y is not understood"
            # 并直接失败），加了等于索引从未更新，而错误被 >/dev/null 吞掉
            apt update >/dev/null 2>&1
            apt install -y "${to_install[@]}" >/dev/null 2>&1
        else
            $PKG_MGR install -y "${to_install[@]}" >/dev/null 2>&1
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

    echo ""

    # 单独处理 gpu-burn（snap 渠道）
    # 判定口径：未装 NVIDIA 驱动的机器本项不适用（直接跳过，不计 FAIL）；
    #   有驱动但拿不到 gpu-burn 只记 WARN 并跳过烤机，不置 GLOBAL_FAIL。
    if command -v nvidia-smi &>/dev/null; then
        if ! command -v gpu-burn &>/dev/null; then
            echo "  [INFO] 检测到NVIDIA显卡驱动，尝试通过 snap 安装 gpu-burn 烤机工具..."
            if command -v snap &>/dev/null; then
                snap install gpu-burn >/dev/null 2>&1
                if command -v gpu-burn &>/dev/null; then
                    echo "  [INFO] gpu-burn 安装成功"
                else
                    echo "  [WARN] gpu-burn snap 安装失败，GPU 烤机测试将跳过"
                    echo "        离线环境可改用源码编译：git clone https://github.com/wilicc/gpu-burn && make"
                fi
            else
                echo "  [WARN] 未检测到 snap 命令，无法自动安装 gpu-burn"
                echo "        可手动执行：snap install gpu-burn"
                echo "        离线环境可改用源码编译：git clone https://github.com/wilicc/gpu-burn && make"
            fi
        fi
    else
        if [[ " ${missing[*]} " =~ " gpu-burn " ]]; then
            echo "  [INFO] 未检测到 NVIDIA 显卡驱动，gpu-burn 无需安装，GPU 测试项将跳过"
        fi
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

# ===================== 系统与BMC时间双重拦截 =====================
time_precheck() {
    echo ""
    echo "============================================================"
    echo "  [初始时间预检] 正在验证系统时间和 BMC 硬件时钟..."
    echo "------------------------------------------------------------"

    SYS_YEAR=$(date +%Y)
    if [ "${SYS_YEAR}" -lt "${MIN_YEAR}" ]; then
        echo "【❌ 严重错误】系统时间发生严重回退（${SYS_YEAR} < ${MIN_YEAR}）！"
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
                echo "  [BMC 时间]  ⚠️ 无法解析 BMC 时间格式，跳过 BMC 对比。"
            fi
        else
            echo "  [BMC 时间]  ⚠️ 未能读取到 BMC 时间，跳过 BMC 对比。"
        fi
    else
        echo "  [BMC 时间]  ⚠️ 未检测到 ipmitool 命令，跳过 BMC 对比。"
    fi

    if [ "${BMC_VALID}" -eq 1 ]; then
        SYS_TS=$(date +%s)
        OFFSET=$((SYS_TS - BMC_TS))
        ABS_OFFSET=$(awk -v off="${OFFSET}" 'BEGIN{if(off<0) off=-off; print off}')
        echo "  [偏差比对]  系统与 BMC 时间偏差为: ${ABS_OFFSET} 秒"

        if [ "${ABS_OFFSET}" -gt 60 ]; then
            echo "【❌ 严重错误】系统时间与 BMC 时间偏差超过 1分钟，强制终止测试！"
            echo "   请手动在终端校准时间后重试。"
            exit 1
        else
            echo "  [偏差比对]  ✅ 系统与 BMC 时间偏差在1分钟内，通过！"
        fi
    else
        echo "  [最终判定]  ✅ 系统时间年份正常，无 BMC 依赖，校验通过。"
    fi

    echo "============================================================"
    echo ""
}
time_precheck

# ===================== 工号输入（取消防呆，允许任意输入） =====================
get_testid() {
    if [ -n "${TEST_ID}" ];then
        testid="${TEST_ID}"
        echo "使用环境变量工号: ${testid}"
        return
    fi
    if [ ! -t 0 ];then
        read -r testid
        if [ -z "${testid}" ]; then
            testid="unknown"
            echo "未输入工号，自动设为: ${testid}"
        else
            echo "使用输入工号: ${testid}"
        fi
        return
    fi
    while true; do
        read -p "请输入测试人员工号（直接回车则设为 unknown）： " testid
        if [ -z "${testid}" ]; then
            testid="unknown"
            echo "工号设为默认: ${testid}"
            break
        else
            echo "工号设为: ${testid}"
            break
        fi
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

# ============================================================
# 硬盘老化压测（裸盘直写，会清除盘上数据）
# ------------------------------------------------------------
# 选盘逻辑复用 fio.sh：按类型分别收集物理盘与逻辑卷，逐条过滤
# （名字黑名单 / 总线类型 / 只读 / 容量下限 / 系统盘与挂载保护链 / 是否被上层卷覆盖），
# 并打印每块盘的排除原因。
# 与 fio.sh 的差别：
#   1. 多盘并行压测（fio.sh 是串行），每盘一个独立 fio 进程，共用 TEST_TIME；
#   2. 只判定「有没有报错」，不显示带宽 / IOPS（老化测试不关心跑多快）；
#   3. 不生成独立的磁盘日志，结论统一写入 main.log。
# ============================================================

# lsblk 列能力探测：TRAN 用于识别 USB 装机盘 / iSCSI / FC 远端盘，util-linux 2.27+ 才有；
# RO（只读）2.28+ 才有。老系统上探测失败就退回最小列集。
LSBLK_FMT="-dn -P -o NAME,TYPE,SIZE"
if lsblk -dn -P -o NAME,TYPE,TRAN,SIZE,RO >/dev/null 2>&1; then
    LSBLK_FMT="-dn -P -o NAME,TYPE,TRAN,SIZE,RO"
fi

# ROTA（是否机械盘）列能力探测：util-linux 2.27+ 才有。
# 探测失败时不能默认按机械盘兜底 —— 固态盘会套用 HDD 阈值（WARN 53 / ABORT 58），
# 59℃ 就误判 FAIL 并中止压测。MONITOR_LOOP 磁盘温度采样处按此标志决定是否采信 ROTA。
LSBLK_HAS_ROTA=0
if lsblk -dno NAME,ROTA >/dev/null 2>&1; then
    LSBLK_HAS_ROTA=1
fi

# ioengine 探测：libaio 优先，缺失则回退 psync（与 fio.sh 一致）
FIO_ENGINE="libaio"
FIO_DEPTH=32
if command -v fio >/dev/null 2>&1; then
    if ! fio --enghelp 2>/dev/null | grep -q "libaio"; then
        FIO_ENGINE="psync"
        FIO_DEPTH=1
    fi
fi

# 明显不是数据盘的设备名（软驱 / 光驱 / 回环 / 内存盘 / 网络块设备）
is_name_blacklisted() {
    case "$1" in
        fd*|sr*|loop*|ram*|zram*|nbd*|rbd*) return 0 ;;
        *) return 1 ;;
    esac
}

# 走这些总线的盘一律不自动测：USB 可插拔（机箱常插装机 U 盘），iscsi / fc 是远端 LUN
is_remote_or_removable() {
    case "$1" in
        usb|iscsi|fc) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 lsblk -P 的单行键值对里取值：pval 'NAME="sda" TYPE="disk"' NAME -> sda
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

# lsblk 的人类可读容量（1.4M / 931.5G / 1.8T）换算成字节
size_to_bytes() {
    awk -v s="$1" 'BEGIN{
        if (s == "" || !match(s, /^[0-9][0-9.]*/)) { print 0; exit }
        v = substr(s, RSTART, RLENGTH) + 0
        u = substr(s, RLENGTH + 1)
        m = 1
        if      (u ~ /^K/) m = 1024
        else if (u ~ /^M/) m = 1048576
        else if (u ~ /^G/) m = 1073741824
        else if (u ~ /^T/) m = 1099511627776
        else if (u ~ /^P/) m = 1125899906842624
        printf "%.0f", v * m
    }'
}

# /dev/mapper/xxx -> lsblk 里的 NAME（如 dm-0）
canon_dev() {
    lsblk -no NAME "$1" 2>/dev/null | head -n1
}

# 查找系统盘：逐级上溯到物理盘，guard 防止异常环境下自引用导致死循环
get_root_disk() {
    local root_source dev_name parent guard=0
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null | tr -d '[]')
    [ -z "${root_source}" ] && return 1

    dev_name="${root_source#/dev/}"
    while [ ${guard} -lt 16 ]; do
        parent=$(lsblk -no pkname "/dev/${dev_name}" 2>/dev/null | head -n1)
        [ -z "${parent}" ] && break
        [ "${parent}" = "${dev_name}" ] && break
        dev_name="${parent}"
        guard=$((guard + 1))
    done
    echo "${dev_name}"
}

# 该设备之下是否还有逻辑卷 / 阵列 / 多路径（有说明它被上层卷覆盖，不该单独测）
has_logical_child() {
    lsblk -no TYPE "$1" 2>/dev/null \
        | grep -qE '^(lvm|crypt|linear|mpath|multipath|raid[0-9]+)$'
}

# 该设备的父设备是否属于逻辑设备（multipath 成员盘常见这种挂法）
parent_is_logical() {
    local p
    p=$(lsblk -no PKNAME "$1" 2>/dev/null | head -n1)
    [ -z "$p" ] && return 1
    lsblk -no TYPE "/dev/$p" 2>/dev/null \
        | head -n1 | grep -qE '^(lvm|crypt|linear|mpath|multipath|raid[0-9]+)$'
}

# 构建「受保护设备」集合：所有已挂载文件系统的源设备、swap 设备，以及它们的父设备链。
# 上溯到物理盘是关键——root 在 LVM 上时保护集要同时盖住 dm-0 / sda3 / sda，
# 否则把 sda 当数据盘测，等于把系统写没了。
declare -A PROTECTED
build_protected() {
    local s name parent guard srcs root
    srcs=$(
        { findmnt -rno SOURCE 2>/dev/null; swapon --show=NAME --noheadings 2>/dev/null; } \
        | sed 's/\[.*//' | sort -u
    )

    # 保险：即使上面整表解析异常，系统盘也必须进保护集
    root=$(get_root_disk)
    [ -n "$root" ] && PROTECTED["$root"]=1

    while IFS= read -r s; do
        [ -z "$s" ] && continue
        case "$s" in /dev/*) ;; *) continue ;; esac
        name=$(canon_dev "$s")
        # 解析不出规范名就退回原始路径名：宁可多保护一个名字，也不能静默漏掉
        [ -z "$name" ] && name="${s#/dev/}"
        guard=0
        while [ -n "$name" ] && [ "$guard" -lt 16 ]; do
            PROTECTED["$name"]=1
            parent=$(lsblk -no PKNAME "/dev/$name" 2>/dev/null | head -n1)
            [ -z "$parent" ] && break
            [ "$parent" = "$name" ] && break
            name="$parent"
            guard=$((guard + 1))
        done
    done <<EOF
$srcs
EOF
    return 0
}

# ---------- 自动选盘 ----------
# 输出：AUTO_DEVS（可测设备名）、SKIPPED_REPORT（"名字|原因"）
AUTO_DEVS=()
SKIPPED_REPORT=()
collect_auto_disks() {
    local min_bytes line name dtype tran size ro
    local -a phys logic bad_phys

    AUTO_DEVS=(); SKIPPED_REPORT=()
    phys=(); logic=(); bad_phys=()
    min_bytes=$(( FIO_MIN_SIZE_GB * 1024 * 1024 * 1024 ))

    build_protected

    # 保护集为空说明 findmnt / swapon 一个在用设备都没读到——此时自动选盘不可信，
    # 宁可拒绝执行，也不能把系统盘当数据盘写掉。
    if [ ${#PROTECTED[@]} -eq 0 ]; then
        echo "  [FAIL] 未能构建受保护设备集（findmnt / swapon 读取失败），拒绝自动选盘"
        echo "         如确需测试，请显式指定盘名：DISK_TEST_DEVS=\"sdb\""
        return 1
    fi

    # ---------- 第一趟：物理盘（TYPE=disk）----------
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(pval "$line" NAME); [ -z "$name" ] && continue
        dtype=$(pval "$line" TYPE)
        [ "$dtype" = "disk" ] || continue
        tran=$(pval "$line" TRAN)
        size=$(pval "$line" SIZE)
        ro=$(pval "$line" RO)

        if is_name_blacklisted "$name"; then
            bad_phys+=("$name")
            SKIPPED_REPORT+=("$name|软驱 / 光驱 / 回环 / 内存盘，不是数据盘")
        elif is_remote_or_removable "$tran"; then
            bad_phys+=("$name")
            SKIPPED_REPORT+=("$name|走 ${tran} 总线（可插拔设备或远端存储）")
        elif [ "$ro" = "1" ]; then
            bad_phys+=("$name")
            SKIPPED_REPORT+=("$name|设备处于只读状态")
        elif [ -n "${PROTECTED[$name]:-}" ]; then
            SKIPPED_REPORT+=("$name|系统盘，或已挂载 / 正在用作 swap")
        elif [ "$(size_to_bytes "$size")" -lt "$min_bytes" ]; then
            SKIPPED_REPORT+=("$name|容量 ${size} 小于下限 ${FIO_MIN_SIZE_GB}GiB")
        elif has_logical_child "/dev/$name" || parent_is_logical "/dev/$name"; then
            SKIPPED_REPORT+=("$name|被上层阵列 / 逻辑卷覆盖，应测上层设备而不是成员盘")
        else
            phys+=("$name")
        fi
    done <<EOF
$(lsblk $LSBLK_FMT 2>/dev/null)
EOF

    # ---------- 第二趟：逻辑卷 / 阵列 / 多路径（TYPE 非 disk）----------
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name=$(pval "$line" NAME); [ -z "$name" ] && continue
        dtype=$(pval "$line" TYPE)
        size=$(pval "$line" SIZE)
        ro=$(pval "$line" RO)
        case "$dtype" in
            lvm|crypt|linear|mpath|multipath|raid0|raid1|raid4|raid5|raid6|raid10) ;;
            *) continue ;;
        esac

        if [ -n "${PROTECTED[$name]:-}" ]; then
            SKIPPED_REPORT+=("$name|系统盘，或已挂载 / 正在用作 swap")
            continue
        fi
        if [ "$ro" = "1" ]; then
            SKIPPED_REPORT+=("$name|设备处于只读状态")
            continue
        fi
        if [ "$(size_to_bytes "$size")" -lt "$min_bytes" ]; then
            SKIPPED_REPORT+=("$name|容量 ${size} 小于下限 ${FIO_MIN_SIZE_GB}GiB")
            continue
        fi

        # 祖先里若出现「本身就不安全」的物理盘（例如 USB 硬盘盒里做的 LVM），
        # 整个上层设备一起排除——测它等于在测那块 USB 盘。
        local anc par hit i guard bad
        anc="$name"; guard=0; bad=0
        while [ "$guard" -lt 16 ]; do
            par=$(lsblk -no PKNAME "/dev/$anc" 2>/dev/null | head -n1)
            [ -z "$par" ] && break
            hit=0
            for i in "${bad_phys[@]}"; do
                [ "$i" = "$par" ] && { hit=1; break; }
            done
            if [ "$hit" = "1" ]; then bad=1; anc="$par"; break; fi
            anc="$par"
            guard=$((guard + 1))
        done
        if [ "$bad" = "1" ]; then
            SKIPPED_REPORT+=("$name|其底层物理盘 /dev/${anc} 已被排除")
            continue
        fi

        logic+=("$name")
    done <<EOF
$(lsblk $LSBLK_FMT 2>/dev/null)
EOF

    AUTO_DEVS=("${phys[@]}" "${logic[@]}")
    return 0
}

# ---------- SMART ----------
# 健康状态判定（解析输出文本，不依赖 smartctl 退出码）
# 为什么不能用退出码：RAID 卡背后的盘、SMART 被屏蔽、USB 桥接、权限不足、NVMe 与 SCSI
# 语义不一致等场景下，smartctl 的返回码与「硬盘是否健康」没有稳定对应关系，
# 按退出码判定会把「读不到」当成「不合格」。
# 输出：PASSED / FAILED / UNSUPPORTED / UNKNOWN
# 【同步维护】smart.sh / fio.sh / lhtest.sh 三处保持同一份实现
smart_health() {
    local dev="$1" out line
    out=$(smartctl -H "$dev" 2>&1)
    line=$(printf '%s\n' "$out" \
           | grep -iE 'overall-health self-assessment|SMART Health Status' | head -1)
    if [ -z "$line" ]; then
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

# 读取一块盘的 SMART 关键计数，输出 "键=值" 行
#   NVMe：Media and Data Integrity Errors / Percentage Used / Error Information Log Entries
#   SATA/SAS：属性 5 重映射扇区 / 187 不可纠正 / 188 超时 / 197 待映射 / 198 离线不可纠正 / 199 CRC
smart_counters() {
    local dev="$1"
    case "${dev}" in
        nvme*)
            smartctl -a "/dev/${dev}" 2>/dev/null \
                | grep -iE '^(Media and Data Integrity Errors|Percentage Used|Error Information Log Entries)' \
                | awk -F':' '{k=$1; v=$2; gsub(/[^0-9]/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",k); print k"="v}'
            ;;
        *)
            smartctl -A "/dev/${dev}" 2>/dev/null \
                | awk '$1 ~ /^(5|187|188|197|198|199)$/ {gsub(/[^0-9]/,"",$NF); print $2"="($NF==""?0:$NF)}'
            ;;
    esac
}

# 汇总所有待测盘的关键计数，输出 "设备|键=值" 行
disk_counters_all() {
    local dev
    for dev in "${DISK_DEVS[@]}"; do
        while IFS= read -r kv; do
            [ -n "${kv}" ] && echo "${dev}|${kv}"
        done < <(smart_counters "${dev}")
    done
}

# 读取一块盘的温度（℃），取不到输出空
#   NVMe：优先 Composite Temperature（规范定义的综合温度），退回所有传感器最大值
#   SATA/SAS：属性 194 / 190 的 RAW_VALUE（最后一列）
# 注意：不能简单地对整行取最大数字——194 行的 WORST 列（如 050）会被误当成温度。
read_disk_temp() {
    local dev="$1" t
    case "${dev}" in
        nvme*)
            # 取 "Temperature:" 行冒号后的第一个整数。
            # 不能整行剔非数字字符：'35 Celsius (95 Fahrenheit)' 会被拼成 3595。
            t=$(smartctl -a "/dev/${dev}" 2>/dev/null \
                | awk -F: '/^Temperature:/ {if (match($2, /[0-9]+/)) print substr($2, RSTART, RLENGTH); exit}')
            if [ -z "${t}" ]; then
                t=$(smartctl -a "/dev/${dev}" 2>/dev/null \
                    | grep -iE '^Temperature Sensor [0-9]+:' \
                    | grep -oE '[0-9]+' | sort -n | tail -n1)
            fi
            ;;
        *)
            # 属性 194/190 的 RAW_VALUE：从行尾往前找第一个纯数字字段。
            # 不能直接取 $NF——部分盘带 '(Min/Max 20/45)' 尾巴，$NF 会变成 '45)'。
            t=$(smartctl -A "/dev/${dev}" 2>/dev/null \
                | awk '$1=="194" || $1=="190" {for(i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) {print $i; exit}}' \
                | sort -n | tail -n1)
            ;;
    esac
    printf '%s' "${t}"
}

# ---------- 跑前预检 + 人工确认 ----------
# 位置：工号、SN 输入之后。会清除盘上数据，必须人工确认。
disk_precheck_and_confirm() {
    local d m cap model serial mounted ans

    echo ""
    echo "============================================================"
    if [ "${DISK_TEST_ENABLE}" != "1" ]; then
        echo "  [硬盘压测] 未启用（DISK_TEST_ENABLE=${DISK_TEST_ENABLE}），跳过"
        echo "============================================================"
        return 0
    fi

    echo "  [硬盘老化压测] 正在确定待测磁盘..."
    echo "------------------------------------------------------------"

    SYS_DISK=$(get_root_disk)
    if [ -z "${SYS_DISK}" ]; then
        echo "  [FAIL] 无法识别系统盘，为安全起见跳过硬盘压测"
        GLOBAL_FAIL=1
        echo "============================================================"
        return 0
    fi

    DISK_DEVS=()
    if [ -n "${DISK_TEST_DEVS}" ]; then
        # ★ 先把用户指定的盘**全部校验完**，再决定是否进入下面的警告 + 人工确认环节。
        #   不能边校验边往 DISK_DEVS 里塞：一旦中途发现某个盘不存在就 return，
        #   前面已塞进去的盘会**绕过数据销毁警告和人工确认**直接开裸盘压测
        #   （2026-09-24 桩环境实测：DISK_TEST_DEVS="sdb sdc" 而 sdc 不存在 → sdb 无确认开压）。
        local missing=()
        for d in ${DISK_TEST_DEVS}; do
            if [ -e "/dev/${d}" ]; then
                DISK_DEVS+=("${d}")
            else
                missing+=("${d}")
            fi
        done
        if [ ${#missing[@]} -gt 0 ]; then
            for m in "${missing[@]}"; do
                echo "  [FAIL] 指定的磁盘 /dev/${m} 不存在"
            done
            echo "        为避免未经确认就对剩余磁盘裸盘压测，本次跳过硬盘压测"
            DISK_DEVS=()
            GLOBAL_FAIL=1
            echo "============================================================"
            return 0
        fi
        echo "  使用手动指定的磁盘（DISK_TEST_DEVS=${DISK_TEST_DEVS}）"
    else
        if ! collect_auto_disks; then
            GLOBAL_FAIL=1
            echo "============================================================"
            return 0
        fi
        DISK_DEVS=("${AUTO_DEVS[@]}")
    fi

    if [ ${#DISK_DEVS[@]} -eq 0 ]; then
        echo "  [WARN] 未找到可测试的磁盘（都被排除或仅剩系统盘），硬盘压测将跳过"
        if [ ${#SKIPPED_REPORT[@]} -gt 0 ]; then
            echo "  已排除的设备："
            for m in "${SKIPPED_REPORT[@]}"; do
                echo "    x /dev/${m%%|*}  —— ${m#*|}"
            done
        fi
        echo "============================================================"
        return 0
    fi

    if [ ${#SKIPPED_REPORT[@]} -gt 0 ]; then
        echo "  以下设备已自动跳过（共 ${#SKIPPED_REPORT[@]} 项）："
        for m in "${SKIPPED_REPORT[@]}"; do
            echo "    x /dev/${m%%|*}  —— ${m#*|}"
        done
        echo ""
    fi

    echo "  待测磁盘（共 ${#DISK_DEVS[@]} 块，将并行压测）："
    for d in "${DISK_DEVS[@]}"; do
        cap=$(lsblk "/dev/${d}" -dn -o SIZE 2>/dev/null | tr -d ' ')
        model=$(lsblk "/dev/${d}" -dn -o MODEL 2>/dev/null | sed 's/^[ ]*//;s/[ ]*$//')
        serial=$(lsblk "/dev/${d}" -dn -o SERIAL 2>/dev/null | sed 's/^[ ]*//;s/[ ]*$//')
        echo "    → /dev/${d}  | 容量: ${cap:-未知} | 型号: ${model:-未知} | 序列号: ${serial:-未知}"
        mounted=$(lsblk -no MOUNTPOINT "/dev/${d}" 2>/dev/null | grep -v '^$' | tr '\n' ' ')
        if [ -n "${mounted}" ]; then
            echo "        ⚠️  该盘上有分区处于挂载状态：${mounted}"
            echo "            压测会直接销毁这些分区上的数据，请先卸载！"
        fi
    done
    echo ""
    echo "  ⚠️  警告：以上磁盘将进行 fio 裸盘老化压测"
    echo "      测试会覆盖磁盘上的数据！请确认已做好数据备份！"
    echo "============================================================"
    echo ""

    # 确认：交互模式询问；非交互模式需 DISK_TEST_CONFIRM=yes
    if [ "${DISK_TEST_CONFIRM}" = "yes" ] || [ "${DISK_TEST_CONFIRM}" = "y" ]; then
        echo "  [INFO] DISK_TEST_CONFIRM=${DISK_TEST_CONFIRM}，跳过交互确认"
    elif [ ! -t 0 ]; then
        echo "  [WARN] 非交互模式且未设置 DISK_TEST_CONFIRM=yes，跳过硬盘压测"
        DISK_DEVS=()
        echo "============================================================"
        return 0
    else
        read -p "  确认要执行硬盘压测吗？(输入 yes 或 y 继续，其他则跳过硬盘压测): " ans
        if [ "${ans}" != "yes" ] && [ "${ans}" != "y" ]; then
            echo "  已取消硬盘压测，继续执行其余老化测试项。"
            DISK_DEVS=()
            echo "============================================================"
            return 0
        fi
    fi

    echo "  已确认，硬盘压测将随老化测试一同启动。"
    echo "============================================================"
    echo ""
    return 0
}

# ---------- 压测：启动（多盘并行，只启动不等待） ----------
disk_stage_start() {
    local d rw_args vf_args out
    [ ${#DISK_DEVS[@]} -gt 0 ] || return 0

    echo -e "\n【2.3 硬盘老化压测（裸盘，${TEST_TIME}秒）】" | tee -a "${LOG}"
    echo "  并行压测 ${#DISK_DEVS[@]} 块盘：${DISK_DEVS[*]}" | tee -a "${LOG}"

    # 压测前 SMART 基线
    DISK_COUNTERS_BEFORE=$(disk_counters_all)
    echo "--- 硬盘 SMART 压测前 ---" | tee -a "${LOG}"
    for d in "${DISK_DEVS[@]}"; do
        echo "  /dev/${d} 健康状态: $(smart_health "/dev/${d}")" | tee -a "${LOG}"
        while IFS= read -r kv; do
            [ -n "${kv}" ] && echo "    ${kv}" | tee -a "${LOG}"
        done < <(smart_counters "${d}")
    done

    # 启动 fio（每盘一个独立进程，共用 TEST_TIME，多盘并行）
    DISK_PIDS=()
    DISK_RC=()
    for d in "${DISK_DEVS[@]}"; do
        rw_args="--rw=${DISK_TEST_RW}"
        if [ "${DISK_TEST_RW}" = "randrw" ]; then
            rw_args="--rw=randrw --rwmixread=${DISK_TEST_RWMIXREAD}"
        fi
        vf_args=""
        [ "${DISK_TEST_VERIFY}" = "1" ] && vf_args="--verify=crc32c --verify_fatal=1"

        out="/tmp/lhtest_fio_${d}_$$.out"
        # shellcheck disable=SC2086
        fio --name=disk_${d} --filename=/dev/${d} \
            --direct=1 --iodepth=${FIO_DEPTH} --thread \
            ${rw_args} ${vf_args} \
            --ioengine=${FIO_ENGINE} --bs=${DISK_TEST_BS} \
            --size=100% --runtime=${TEST_TIME} --time_based --group_reporting \
            > "${out}" 2>&1 &
        DISK_PIDS+=("$!")
        echo "$!" >> "${STRESS_PID_FILE}"
        echo "  /dev/${d} 压测已启动（PID $!）" | tee -a "${LOG}"
    done

    DISK_STARTED=1
    echo "  压测参数：${DISK_TEST_RW} bs=${DISK_TEST_BS} iodepth=${FIO_DEPTH} ioengine=${FIO_ENGINE} verify=${DISK_TEST_VERIFY}" | tee -a "${LOG}"
    return 0
}

# ---------- 压测：收尾（判定 + SMART 复测） ----------
# 老化口径：只看有没有报错，不看带宽 / IOPS
disk_stage_finish() {
    local d rc out errs i h dev kv key bv av avl hit=0
    [ "${DISK_STARTED}" = "1" ] || return 0

    echo -e "\n--- 硬盘压测结果（只看有无报错，不看带宽/IOPS）---" | tee -a "${LOG}"

    i=0
    for d in "${DISK_DEVS[@]}"; do
        rc="${DISK_RC[$i]:-0}"
        out="/tmp/lhtest_fio_${d}_$$.out"

        if [ "${rc}" -ne 0 ] && [ -f "${TEMP_ABORT_FILE}" ]; then
            # 高温中止是脚本主动 kill 的，不是盘自身报错；主流程已按高温记 FAIL，这里不重复记
            echo "  [ABORT] /dev/${d} 压测因高温被提前中止（返回码 ${rc}）" | tee -a "${LOG}"
        elif [ "${rc}" -ne 0 ]; then
            echo "  [FAIL] /dev/${d} 压测异常退出（返回码 ${rc}）" | tee -a "${LOG}"
            if [ -f "${out}" ]; then
                errs=$(grep -iE "error|fail|verify|crc" "${out}" 2>/dev/null | head -5)
                [ -n "${errs}" ] && printf '%s\n' "${errs}" | sed 's/^/         | /' | tee -a "${LOG}"
            fi
            GLOBAL_FAIL=1
        # ★ fio 的 group_reporting 首行是 "name: (groupid=0, jobs=1): err= 0: pid=…"
        #   —— 等号后面**有空格**。写成 "err=[1-9]" 永远匹配不到 "err= 3"，
        #   这条判定会静默失效（2026-09-24 桩环境实测复现：注入 err= 3 且退出码 0 → 误判 PASS）。
        elif [ -f "${out}" ] && grep -qiE "err= *[1-9]|io error|i/o error" "${out}" 2>/dev/null; then
            echo "  [FAIL] /dev/${d} 压测输出中存在 IO 错误" | tee -a "${LOG}"
            grep -iE "err= *[1-9]|io error|i/o error" "${out}" 2>/dev/null | head -3 | sed 's/^/         | /' | tee -a "${LOG}"
            GLOBAL_FAIL=1
        else
            echo "  [PASS] /dev/${d} 压测期间无报错" | tee -a "${LOG}"
        fi

        rm -f "${out}"
        i=$((i + 1))
    done

    # 压测后 SMART 复测
    echo -e "\n--- 硬盘 SMART 压测后复测 ---" | tee -a "${LOG}"
    DISK_COUNTERS_AFTER=$(disk_counters_all)
    for d in "${DISK_DEVS[@]}"; do
        h=$(smart_health "/dev/${d}")
        case "${h}" in
            PASSED)
                echo "  /dev/${d} 健康状态: PASSED" | tee -a "${LOG}" ;;
            FAILED)
                echo "  [FAIL] /dev/${d} 健康状态: FAILED（压测后自检不通过，需排查/更换）" | tee -a "${LOG}"
                GLOBAL_FAIL=1 ;;
            UNSUPPORTED)
                echo "  [WARN] /dev/${d} 健康状态: 不支持/不可读（被 RAID 卡屏蔽或设备无 SMART，非硬盘故障，请人工确认）" | tee -a "${LOG}" ;;
            *)
                echo "  [WARN] /dev/${d} 健康状态: 未知（smartctl 执行异常，请人工确认）" | tee -a "${LOG}" ;;
        esac
    done

    # 关键计数增量对比
    if [ -n "${DISK_COUNTERS_BEFORE}" ]; then
        echo "--- 硬盘 SMART 关键计数增量（压测前 → 压测后）---" | tee -a "${LOG}"
        while IFS='|' read -r dev kv; do
            [ -z "${kv}" ] && continue
            key="${kv%%=*}"
            bv="${kv#*=}"
            avl=$(printf '%s\n' "${DISK_COUNTERS_AFTER}" | grep -F "${dev}|${key}=" | head -n1)
            av="${avl#*=}"
            [ -z "${av}" ] && continue
            # 只把「计数增长」判为 FAIL。计数回落（av < bv）不是故障 —— NVMe 控制器
            # reset 后 Error Information Log Entries 等计数会清零，按 != 判定会误报 FAIL
            if [ "$(num_gt "${av}" "${bv}")" -eq 1 ]; then
                echo "  [FAIL] /dev/${dev} ${key}: ${bv} → ${av}（压测期间增长）" | tee -a "${LOG}"
                hit=1
            elif [ "$(num_gt "${bv}" "${av}")" -eq 1 ]; then
                echo "  [WARN] /dev/${dev} ${key}: ${bv} → ${av}（计数回落，通常为控制器 reset 后清零，非故障，请人工确认）" | tee -a "${LOG}"
            fi
        done <<< "${DISK_COUNTERS_BEFORE}"
        if [ "${hit}" -eq 0 ]; then
            echo "  [PASS] 所有盘 SMART 关键计数无增长" | tee -a "${LOG}"
        else
            GLOBAL_FAIL=1
        fi
    fi
    return 0
}

get_testid
get_sn

# ========== 硬盘压测预检与人工确认（会清除盘上数据，必须确认） ==========
# 放在工号 / SN 输入之后、创建日志目录之前：
# 此时尚未开始记录日志，确认不通过就直接跳过硬盘项，其余老化测试照常进行。
disk_precheck_and_confirm

# ========== 创建日志文件夹 ==========
TEST_DIR="./${SN}-lhtest-log"
mkdir -p "${TEST_DIR}"

LOG="${TEST_DIR}/main.log"
DMESG_LOG="${TEST_DIR}/dmesg.log"
SEL_LOG="${TEST_DIR}/sel.log"
MONITOR_CSV="${TEST_DIR}/monitor.csv"
# GPU 降频核查专用日志（★ 2026-09-30 新增）：长表，一行 = 一个采样点 × 一张卡。
# 与 monitor.csv 分开存：monitor.csv 是「人眼扫一眼」的宽表（单元格里塞管道串，无法做分析），
# 这里要的是「能算能画」——导入 Excel 可直接透视、画时钟/温度/功耗曲线。
THROTTLE_CSV="${TEST_DIR}/throttle.csv"

> "${LOG}"
> "${DMESG_LOG}"
> "${SEL_LOG}"

echo "========================================" >> "${LOG}"
echo "测试人员工号: ${testid}" >> "${LOG}"
echo "服务器SN: ${SN}" >> "${LOG}"
echo "测试启动时间: $(date)" >> "${LOG}"
echo "日志目录: ${TEST_DIR}" >> "${LOG}"
echo "========================================" >> "${LOG}"

# ========== 内核日志采集（只跟随新消息；会话前历史由 log.sh 留存）==========
# ★ 2026-09-30 修订（两次）：
#   ① 与 log.sh 统一为 -W 方案（原方案 = dmesg -C 清空 + dmesg -w 跟随）：
#      · dmesg -C 会把会话前的内核日志**永久清掉**（开机自检 / 启动期 AER、ECC 报错全丢），
#        且它是全局操作，会连带清掉同机其他采集者正在看的内容；
#      · 若清空成功但跟随启动失败，等于「历史没了、新的也没采到」；
#      · 缓冲溢出时窗口期消息仍可能被覆盖。
#   ② 本脚本**不再**自己留存 dmesg.boot.log —— lhtest.sh 是在 log.sh 会话**之外**单独跑的
#      （见 log.sh 的 OUTSIDE="lhtest.sh fieldiag"），会话前历史（含开机自检）统一由
#      log.sh 的 <SN>-test-log/dmesg.boot.log 覆盖，本脚本只采运行期新消息。
#      巡检（error_log_check）时仍会抓一次全缓冲快照追加到 dmesg.full.log，可作兜底。
DMESG_FULL_LOG="${TEST_DIR}/dmesg.full.log"
SEL_RAW_LOG="${TEST_DIR}/sel_raw.log"
> "${DMESG_FULL_LOG}"

if command -v dmesg &>/dev/null; then
    echo -e "\n[INIT] 内核日志采集：只跟随运行期新消息（会话前历史见 log.sh 的 dmesg.boot.log）" | tee -a "${LOG}"
    # 持续采集：长时压测中环形缓冲区会被覆盖，后台持续落盘可避免早期报错丢失
    dmesg -W >> "${DMESG_FULL_LOG}" 2>/dev/null &
    DMESG_W_PID=$!
    sleep 1
    if kill -0 "${DMESG_W_PID}" 2>/dev/null; then
        echo "[INIT] 内核日志持续采集已启动（dmesg -W --follow-new）-> ${DMESG_FULL_LOG}" | tee -a "${LOG}"
    else
        # -W 不被支持 → 退化为 -w（会把缓冲里的历史一起打出来）
        dmesg -w >> "${DMESG_FULL_LOG}" 2>/dev/null &
        DMESG_W_PID=$!
        sleep 1
        if kill -0 "${DMESG_W_PID}" 2>/dev/null; then
            echo "[INIT][注意] 本机 dmesg 不支持 -W，已退化为 -w（跟随段可能含历史）" | tee -a "${LOG}"
        else
            DMESG_W_PID=""
            echo "[WARN] dmesg 跟随进程启动失败，将退回巡检时的一次性快照采集" | tee -a "${LOG}"
        fi
    fi
fi

if command -v ipmitool &>/dev/null; then
    echo "[INIT] 清空 BMC 系统事件日志（ipmitool sel clear）" | tee -a "${LOG}"
    if ipmitool sel clear >/dev/null 2>&1; then
        echo "[INIT] BMC SEL 已清空（注意：BMC 会保留一条 Log area reset/cleared 记录，已在巡检中白名单忽略）" | tee -a "${LOG}"
    else
        echo "[WARN] BMC SEL 清空失败，历史告警可能混入本次结果，请人工甄别" | tee -a "${LOG}"
    fi
    sleep 1
fi

# ========== 进程树清理工具 ==========
# stress-ng 会 fork 大量 worker，gpu-burn 会 fork 多个 GPU 进程，MONITOR_LOOP 里
# 还常驻一个 sleep 60。只 kill 父 PID 不保证子进程退出 —— 表现为脚本"跑完了"，
# 但 CPU/内存/GPU 压测进程仍在后台继续跑。必须按进程树逐个回收。
kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    [ -n "${pid}" ] || return 0
    # 防御：pid 非纯数字、或为 0/1 时绝不能发信号。
    # kill -TERM 0 会作用于「整个进程组」，等于把脚本自己也杀掉；
    # kill -TERM 1 会打到 init/systemd。存活检查必须放在这层校验之后。
    case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${pid}" -gt 1 ] || return 0
    kill -0 "${pid}" 2>/dev/null || return 0
    if command -v pgrep >/dev/null 2>&1; then
        for child in $(pgrep -P "${pid}" 2>/dev/null); do
            kill_tree "${child}" "${sig}"
        done
    fi
    kill -"${sig}" "${pid}" 2>/dev/null
}

# 先 TERM 优雅退出，最多等 5s，仍在则 KILL
stop_tree() {
    local pid="$1" i
    [ -n "${pid}" ] || return 0
    case "${pid}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${pid}" -gt 1 ] || return 0
    kill -0 "${pid}" 2>/dev/null || return 0
    kill_tree "${pid}" TERM
    for i in 1 2 3 4 5; do
        kill -0 "${pid}" 2>/dev/null || return 0
        sleep 1
    done
    kill_tree "${pid}" KILL
    sleep 1
    return 0
}

# ========== 异常退出清理函数 ==========
# 注意：EXIT trap 中最后一条命令的返回码会覆盖脚本原本的退出码，
# 所以先存 $?，清理完原样返回，否则 exit 1 会被吞成 0。
cleanup(){
    local rc=$?
    if [ "${CLEANUP_REASON:-normal}" = "signal" ]; then
        echo -e "\n[CLEANUP] 收到终止信号，正在回收后台进程（含子进程）" | tee -a "${LOG}"
    else
        echo -e "\n[CLEANUP] 测试结束，正在回收后台进程（含子进程）" | tee -a "${LOG}"
    fi
    stop_tree "${CPU_PID}"
    stop_tree "${GPU_PID}"
    stop_tree "${MONITOR_PID}"
    stop_tree "${DMESG_W_PID}"
    # 硬盘 fio 进程（多盘并行，可能不止一个）：信号退出时必须一起收，
    # 否则脚本已退出、裸盘上的写还在继续
    local _dp
    for _dp in "${DISK_PIDS[@]}"; do
        [ -n "${_dp}" ] && stop_tree "${_dp}"
    done
    DISK_PIDS=()
    CPU_PID=""; GPU_PID=""; MONITOR_PID=""; DMESG_W_PID=""
    rm -f /tmp/dmesg_filter_*.tmp /tmp/sel_filter_*.tmp "${TEMP_ALERT_FILE}" \
          "${TEMP_ABORT_FILE}" "${STRESS_PID_FILE}" "${THROTTLE_ALERT_FILE}" \
          /tmp/lhtest_fio_*_$$.out \
          /tmp/hwcounter_before_$$.log /tmp/hwcounter_after_$$.log
    return "${rc}"
}
trap 'CLEANUP_REASON=signal; exit 130' INT
trap 'CLEANUP_REASON=signal; exit 143' TERM
trap cleanup EXIT

# ========== 温度采样 & 高温中断 ==========
# 取 CPU 相关温度传感器的最高值（℃）。拿不到则输出空。
# 原实现直接对 `ipmitool sdr type Temperature` 全量取最大值，会把入风口、内存、
# PCIe 卡槽等非 CPU 传感器也算进来，告警来源不可靠，故先按传感器名过滤。
# 若按名过滤后为空（部分 BMC 传感器命名不含 CPU 关键字），退回全量取最大值，
# 保证不丢告警（沿用旧行为），并通过 CPU_TEMP_FALLBACK 标记提示读数仅供参考。
get_cpu_temp() {
    command -v ipmitool &>/dev/null || return 0
    local t
    t=$(ipmitool sdr type Temperature 2>/dev/null \
        | grep -iE 'cpu|processor|proc' \
        | grep -v "no reading" \
        | awk -F'|' '{print $5}' \
        | grep -oE '[0-9]+\.?[0-9]*' \
        | sort -n | tail -n1)
    if [ -n "${t}" ] && [ "${t}" != "0" ]; then
        CPU_TEMP_FALLBACK=0
    else
        t=$(ipmitool sdr type Temperature 2>/dev/null \
            | grep -v "no reading" \
            | awk -F'|' '{print $5}' \
            | grep -oE '[0-9]+\.?[0-9]*' \
            | sort -n | tail -n1)
        CPU_TEMP_FALLBACK=1
    fi
    [ "${t}" = "0" ] && t=""
    # 输出两个字段「回退标记|温度值」：本函数以 $( ) 调用，跑在子 shell 里，
    # 全局赋值传不出来，只能靠标准输出把回退标记一起带出来。
    # 不能用空格分隔：温度读不到时 t 为空，echo "${t} ${CPU_TEMP_FALLBACK}" 会输出
    # " 1"，read 吃掉前导空白后温度字段拿到的是 "1"（假的 1℃）——既在日志里冒充
    # 真实读数，又让上面「未读到温度传感器」的告警分支变成死代码。
    # 改用 | 分隔且把标记放在前面，两个字段恒有值，调用方 IFS='|' read 结果稳定。
    printf '%s|%s\n' "${CPU_TEMP_FALLBACK}" "${t}"
}

# 取所有 GPU 中最高的核心温度（℃）。拿不到则输出空。
get_gpu_temp() {
    command -v nvidia-smi &>/dev/null || return 0
    nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null \
        | grep -oE '[0-9]+' \
        | sort -n | tail -n1
}

# 数值比较：a > b 输出 1，否则 0
num_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN{print (a+0>b+0)?1:0}'
}

# 高温中断：记录原因 -> 回收烤机进程。
# 监控循环是后台子进程，读不到主 shell 的 CPU_PID / GPU_PID 变量，
# 所以主进程把 PID 写进 STRESS_PID_FILE，这里按文件逐个 stop_tree 回收。
temp_abort() {
    local what="$1" cur="$2" th="$3" p
    local msg="FAIL!!! ${what} 温度 ${cur}℃ 超过中断阈值 ${th}℃，立即中止压力测试"
    echo "${msg}（$(date '+%Y-%m-%d %H:%M:%S')）" >> "${LOG}"
    echo "${msg}" > "${TEMP_ABORT_FILE}"
    if [ -f "${STRESS_PID_FILE}" ]; then
        while read -r p; do
            [ -n "${p}" ] && stop_tree "${p}"
        done < "${STRESS_PID_FILE}"
        : > "${STRESS_PID_FILE}"
    fi
    return 0
}

# ============================
# GPU 降频：位掩码翻译（★ 2026-09-30 新增）
# ============================
# 把 clocks_throttle_reasons.active 的位掩码翻成短标签。
# 位定义（NVML nvmlClocksThrottleReason）：
#   0x01 GPU Idle            0x02 Applications Clocks Setting
#   0x04 SW Power Cap        0x08 HW Slowdown
#   0x10 Sync Boost          0x20 SW Thermal Slowdown
#   0x40 Display Clock Setting
# 注：HW Slowdown(0x08) 内部还分 HW Thermal / HW Power Brake 两种，掩码里不区分，
#     要细分就看日志里抓下来的 `nvidia-smi -q -d PERFORMANCE` 原文。
# 值为 [N/A]（老驱动）或非数字时返回 ?，调用方据此跳过。
gpu_throttle_label() {
    local m="$1" lab="" v
    case "${m}" in ''|*[!0-9xXa-fA-F]*) printf '?'; return 0 ;; esac
    v=$(( m )) 2>/dev/null || { printf '?'; return 0; }
    [ $(( v & 0x01 )) -ne 0 ] && lab="${lab}Idle "
    [ $(( v & 0x02 )) -ne 0 ] && lab="${lab}AppClk "
    [ $(( v & 0x04 )) -ne 0 ] && lab="${lab}SWPowerCap "
    [ $(( v & 0x08 )) -ne 0 ] && lab="${lab}HWSlowdown "
    [ $(( v & 0x10 )) -ne 0 ] && lab="${lab}SyncBoost "
    [ $(( v & 0x20 )) -ne 0 ] && lab="${lab}SWThermal "
    [ $(( v & 0x40 )) -ne 0 ] && lab="${lab}DisplayClk "
    [ -z "${lab}" ] && lab="无"
    printf '%s' "${lab% }"
}

# ============================
# 后台监控循环（表头已改为中文）
# ============================
MONITOR_LOOP(){
    : > "${MONITOR_CSV}"
    echo "时间戳,CPU最高温度(℃),GPU温度(℃),GPU利用率(%),磁盘温度(℃)" > "${MONITOR_CSV}"
    # ---- GPU 降频核查日志初始化（★ 2026-09-30 新增）----
    : > "${THROTTLE_CSV}"
    echo "timestamp,gpu,bus_id,sm_mhz,max_sm_mhz,pct,mem_mhz,power_w,power_limit_w,temp_c,util_pct,throttle" > "${THROTTLE_CSV}"

    # ---- 能力探测：老驱动可能不支持 clocks.* / clocks_throttle_reasons 字段 ----
    # ★ 必须先探测再拼进 query：query 里只要有一个不支持的字段，nvidia-smi 会整条报错
    #   退出、无任何输出 —— 那样连温度/利用率都采不到，现有监控会直接退化。
    #   探测失败时 GPU_CLK_FIELDS 留空，query 自动退回原来的 4 个字段。
    GPU_CLK_FIELDS=""
    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,clocks.mem,power.limit,clocks_throttle_reasons.active \
             --format=csv,noheader >/dev/null 2>&1; then
            GPU_CLK_FIELDS=",clocks.sm,clocks.max.sm,clocks.mem,power.limit,clocks_throttle_reasons.active"
        else
            echo "WARN: 当前 nvidia-smi 不支持时钟/降频字段，GPU 降频核查本次跳过（温度/利用率监控不受影响）" >> "${LOG}"
        fi
    fi

    local cpu_hits=0 gpu_hits=0 disk_hits=0 i ct gt _cfb cpu_fb
    echo "高温中断已启用：CPU > ${CPU_TEMP_ABORT}℃ 或 GPU > ${GPU_TEMP_ABORT}℃ 立即中止压力测试（10 秒粒度采样）" >> "${LOG}"
    while true
    do
        # ---- 高温把关：10 秒采样一次，满 6 次约 60 秒 ----
        # 放在循环开头而不是末尾，超阈值时最多 10 秒就中止，
        # 不用等这一分钟的 sleep 走完；同时它替代了原来末尾的 sleep 60。
        i=0
        while [ "${i}" -lt 6 ]; do
            IFS='|' read -r _cfb ct <<<"$(get_cpu_temp)"
            gt=$(get_gpu_temp)
            if [ -n "${ct}" ] && [ "$(num_gt "${ct}" "${CPU_TEMP_ABORT}")" -eq 1 ]; then
                cpu_hits=$((cpu_hits + 1))
            else
                cpu_hits=0
            fi
            if [ -n "${gt}" ] && [ "$(num_gt "${gt}" "${GPU_TEMP_ABORT}")" -eq 1 ]; then
                gpu_hits=$((gpu_hits + 1))
            else
                gpu_hits=0
            fi
            if [ "${cpu_hits}" -ge "${TEMP_ABORT_GRACE:-1}" ]; then
                temp_abort "CPU" "${ct}" "${CPU_TEMP_ABORT}"
                return 0
            fi
            if [ "${gpu_hits}" -ge "${TEMP_ABORT_GRACE:-1}" ]; then
                temp_abort "GPU" "${gt}" "${GPU_TEMP_ABORT}"
                return 0
            fi
            sleep 10
            i=$((i + 1))
        done

        TS=$(date "+%Y-%m-%d %H:%M:%S")
        CPU_TEMP="N/A"
        GPU_TEMPS=""; GPU_UTILS=""; DISK_TEMPS=""
        echo "===== 实时监控 ${TS} =====" >> "${LOG}"

        if command -v nvidia-smi &> /dev/null;then
            while IFS=, read -r gi gbid gt gu gp gs gmax gmem glim gm; do
                gi=$(echo "${gi}" | tr -d ' '); gt=$(echo "${gt}" | tr -d ' ')
                gu=$(echo "${gu}" | tr -d ' '); gp=$(echo "${gp}" | tr -d ' ')
                gbid=$(echo "${gbid}" | tr -d ' ')
                echo "GPU${gi}: 温度=${gt}℃ 利用率=${gu} 功耗=${gp}W" >> "${LOG}"
                case "${gt}" in
                    ''|*[!0-9]*) ;;
                    *)
                        if [ "$(num_gt "${gt}" "${GPU_TEMP_WARN}")" -eq 1 ]; then
                            echo "WARN!!! GPU${gi}温度 ${gt}℃ 超过${GPU_TEMP_WARN}℃告警阈值" >> "${LOG}"
                            touch "${TEMP_ALERT_FILE}"
                        fi
                        ;;
                esac
                GPU_TEMPS="${GPU_TEMPS:+${GPU_TEMPS}|}${gi}=${gt}"
                GPU_UTILS="${GPU_UTILS:+${GPU_UTILS}|}${gi}=${gu}"

                # ---- GPU 降频核查（★ 2026-09-30 新增）----
                # ★ clocks.* 和 power.draw 在 csv 输出里自带单位（"1955 MHz" / "692.34 W"），
                #   必须先剥成纯数字；否则下面的纯数字判断永远不成立，降频永远判不出来。
                #   （temperature.gpu 是不带单位的纯数字，所以原温度判断一直有效 —— 两者不一样）
                local gsm gsmx gpct gpow gtemp gutil glab gmemv glimv
                gsm=$(printf '%s' "${gs}"     | tr -cd '0-9')
                gsmx=$(printf '%s' "${gmax}"  | tr -cd '0-9')
                gpow=$(printf '%s' "${gp}"    | tr -cd '0-9.')
                gtemp=$(printf '%s' "${gt}"   | tr -cd '0-9')
                gutil=$(printf '%s' "${gu}"   | tr -cd '0-9')
                gmemv=$(printf '%s' "${gmem}" | tr -cd '0-9')
                glimv=$(printf '%s' "${glim}" | tr -cd '0-9.')
                glab="N/A"; gpct=-1
                [ -n "${gm}" ] && glab="$(gpu_throttle_label "${gm}")"
                if [ -n "${gsm}" ] && [ -n "${gsmx}" ] && [ "${gsmx}" -gt 0 ]; then
                    gpct=$(( gsm * 100 / gsmx ))
                fi
                echo "$(date '+%Y-%m-%d %H:%M:%S'),${gi},${gbid:-N/A},${gsm:-N/A},${gsmx:-N/A},${gpct},${gmemv:-N/A},${gpow:-N/A},${glimv:-N/A},${gtemp:-N/A},${gutil:-N/A},${glab}" >> "${THROTTLE_CSV}"
                # 时钟明显掉下来 → 只对这张卡抓一次可读的降频原因（开销小、证据全）
                if [ "${gpct}" -ge 0 ] && [ "${gpct}" -lt "${GPU_CLK_WARN_PCT}" ]; then
                    echo "WARN!!! GPU${gi} SM 时钟 ${gsm}/${gsmx}MHz（${gpct}%），抓取降频原因：" >> "${LOG}"
                    nvidia-smi -i "${gi}" -q -d PERFORMANCE 2>/dev/null \
                        | sed -n '/Clocks .*Reasons/,/^$/p' | head -20 >> "${LOG}"
                    touch "${THROTTLE_ALERT_FILE}"
                fi
            done < <(nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,utilization.gpu,power.draw${GPU_CLK_FIELDS} --format=csv,noheader 2>/dev/null)
        fi

        if command -v ipmitool &> /dev/null;then
            IFS='|' read -r cpu_fb cpu_max_temp <<<"$(get_cpu_temp)"
            if [ -n "${cpu_max_temp}" ] && [ "${cpu_max_temp}" != "0" ];then
                CPU_TEMP="${cpu_max_temp}"
                if [ "${cpu_fb:-0}" -eq 1 ]; then
                    echo "CPU最高温度: ${cpu_max_temp} ℃（未匹配到 CPU 命名传感器，已退回全量温度传感器最大值，可能含入风口/内存等，仅供参考）" >> "${LOG}"
                else
                    echo "CPU最高温度: ${cpu_max_temp} ℃" >> "${LOG}"
                fi
                over_temp=$(awk -v temp="${cpu_max_temp}" -v th="${CPU_TEMP_WARN}" 'BEGIN{if(temp>th) print 1; else print 0}')
                if [ "${over_temp}" -eq 1 ];then
                    echo "WARN!!! CPU温度超过${CPU_TEMP_WARN}℃告警阈值，当前最高 ${cpu_max_temp}℃" >> "${LOG}"
                    touch "${TEMP_ALERT_FILE}"
                fi
            else
                # 旧实现这里什么都不做，ipmitool 读不到数时告警与中断静默失效
                echo "WARN: ipmitool 可用但未读到任何温度传感器数值，CPU 温度告警与高温中断本次均失效" >> "${LOG}"
            fi
            ipmitool sensor 2>/dev/null | grep -iE "power|temp" >> "${LOG}"
        else
            echo "WARN: ipmitool 不可用，CPU 温度告警与高温中断本次均失效（GPU 高温中断仍生效）" >> "${LOG}"
        fi

        # 磁盘温度采样 + 高温把关（通过 smartctl，只读取温度不写数据，安全）
        # 按 ROTA 区分盘型套用不同阈值：HDD 是寿命问题（45℃+ 开始折寿，spec 上限 60℃）；
        # SSD 是性能问题（NVMe TMT1 约 80℃ 开始降速，TMT2 约 85℃ 停 IO）。
        # 采样粒度是外层循环的 60 秒（内层 6 × sleep 10 是 CPU/GPU 的 10 秒粒度），
        # 硬盘热时间常数是分钟级，60 秒粒度足够。
        if command -v smartctl &>/dev/null; then
            local disk_over=0 d_abort_what="" d_abort_cur="" d_abort_th=""
            for d in $(lsblk -d -o NAME,TYPE 2>/dev/null | grep -E "disk" | grep -v loop | awk '{print $1}' | grep -v NAME); do
                dt=$(read_disk_temp "${d}")
                [ -z "${dt}" ] && continue
                DISK_TEMPS="${DISK_TEMPS:+${DISK_TEMPS}|}${d}=${dt}"

                # ROTA 列缺失（老 util-linux）时不能按机械盘兜底：固态盘套用 HDD 阈值
                # 会在 59℃ 就误判 FAIL 并中止压测。ROTA 不可用时按设备名判断，nvme* 必为固态盘
                rota=""
                if [ "${LSBLK_HAS_ROTA}" = "1" ]; then
                    rota=$(lsblk -dno ROTA "/dev/${d}" 2>/dev/null | tr -d ' ')
                fi
                case "${rota}" in
                    0)
                        d_kind="固态盘"; d_warn="${DISK_TEMP_WARN_SSD}"; d_abort="${DISK_TEMP_ABORT_SSD}" ;;
                    "")
                        case "${d}" in
                            nvme*) d_kind="固态盘"; d_warn="${DISK_TEMP_WARN_SSD}"; d_abort="${DISK_TEMP_ABORT_SSD}" ;;
                            *)     d_kind="机械盘"; d_warn="${DISK_TEMP_WARN_HDD}"; d_abort="${DISK_TEMP_ABORT_HDD}" ;;
                        esac ;;
                    *)
                        d_kind="机械盘"; d_warn="${DISK_TEMP_WARN_HDD}"; d_abort="${DISK_TEMP_ABORT_HDD}" ;;
                esac

                if [ "$(num_gt "${dt}" "${d_abort}")" -eq 1 ]; then
                    echo "FAIL!!! ${d_kind} /dev/${d} 温度 ${dt}℃ 超过中断阈值 ${d_abort}℃" >> "${LOG}"
                    disk_over=1
                    d_abort_what="${d_kind} /dev/${d}"
                    d_abort_cur="${dt}"
                    d_abort_th="${d_abort}"
                elif [ "$(num_gt "${dt}" "${d_warn}")" -eq 1 ]; then
                    echo "WARN!!! ${d_kind} /dev/${d} 温度 ${dt}℃ 超过${d_warn}℃告警阈值" >> "${LOG}"
                    touch "${TEMP_ALERT_FILE}"
                fi
            done
            if [ -n "${DISK_TEMPS}" ]; then
                echo "磁盘温度: ${DISK_TEMPS} ℃" >> "${LOG}"
            fi
            # 连续超阈值采样次数达到 TEMP_ABORT_GRACE 才中止（与 CPU/GPU 同一套机制）
            if [ "${disk_over}" -eq 1 ]; then
                disk_hits=$((disk_hits + 1))
                if [ "${disk_hits}" -ge "${TEMP_ABORT_GRACE:-1}" ]; then
                    temp_abort "${d_abort_what}" "${d_abort_cur}" "${d_abort_th}"
                    return 0
                fi
            else
                disk_hits=0
            fi
        fi

        echo "${TS},${CPU_TEMP},${GPU_TEMPS:-N/A},${GPU_UTILS:-N/A},${DISK_TEMPS:-N/A}" >> "${MONITOR_CSV}"
        # 间隔由循环开头的高温把关（6 × sleep 10）承担，这里不再 sleep 60，
        # 否则一轮会变成 120 秒
    done
}

# ============================
# GPU 压测期降频核查汇总（★ 2026-09-30 新增）
# ============================
# 读 throttle.csv 生成；在压测结束、监控循环已停止后调用（stress_stage 末尾会 stop_tree 掉监控）。
# 判定口径：只记 WARN，不计入 GLOBAL_FAIL —— 满载时功耗顶到墙、SM 时钟随之下降是正常现象，
#           直接判 FAIL 会大面积误报。是否升级为 FAIL，由现场按机型 baseline 决定。
# 统计口径：只统计「满载采样点」（GPU 利用率 ≥ 50%）。压测前后的空闲点 util≈0，
#           混进来会把空闲降频误判成异常。
# 数据可得性：老驱动不支持 clocks.* 字段时，throttle.csv 的满频字段会全为空。
#           此时输出「未采集到 SM 时钟数据，降频核查跳过」，不报「无降频」——
#           「没采到」和「没问题」是两回事，混同会掩盖真实情况。
throttle_report() {
    echo -e "\n==================== GPU 压测期降频核查 ====================" | tee -a "${LOG}"

    if [ ! -s "${THROTTLE_CSV}" ]; then
        echo "（无 throttle.csv，本次跳过）" | tee -a "${LOG}"
        return 0
    fi

    local ts_first ts_last total npt stats
    ts_first=$(awk -F, 'NR==2{print $1}' "${THROTTLE_CSV}" 2>/dev/null)
    ts_last=$(awk -F, 'END{print $1}' "${THROTTLE_CSV}" 2>/dev/null)
    total=$(awk 'END{print NR-1}' "${THROTTLE_CSV}" 2>/dev/null)
    if [ -z "${total}" ] || [ "${total}" -le 0 ]; then
        echo "（无采样数据，本次跳过）" | tee -a "${LOG}"
        return 0
    fi

    # 输出：g|时钟峰值|满频|时钟比均值|满载点数|总点数|降频点数|最长连续|温度峰值|功耗峰值|主要原因
    stats=$(awk -F, '
        NR==1 { next }
        {
            g=$2
            if (!(g in seen)) { seen[g]=1; order[++n]=g }
            total[g]++
            if ($11+0 < 50) next
            cnt[g]++
            if ($4+0 > pk[g]) pk[g]=$4+0
            if ($5+0 > mx[g]) mx[g]=$5+0
            if ($6+0 > 0)    sumpct[g]+=$6+0
            if ($8+0 > pw[g]) pw[g]=$8+0
            if ($10+0 > tp[g]) tp[g]=$10+0
            if ($12=="无" || $12=="N/A" || $12=="?") { cur[g]=0 }
            else { thr[g]++; cur[g]++; if (cur[g]>run[g]) run[g]=cur[g]; rsn[g]=$12 }
        }
        END {
            for (i=1;i<=n;i++) {
                g=order[i]
                avg = cnt[g] ? int(sumpct[g]/cnt[g]) : -1
                printf "%s|%d|%d|%d|%d|%d|%d|%d|%d|%.2f|%s\n", g, pk[g], mx[g], avg, cnt[g], total[g], thr[g]+0, run[g]+0, tp[g], pw[g], rsn[g]
            }
        }
    ' "${THROTTLE_CSV}" 2>/dev/null)

    if [ -z "${stats}" ]; then
        echo "（throttle.csv 无有效数据，本次跳过）" | tee -a "${LOG}"
        return 0
    fi

    npt=$(awk -F, 'NR>1{n[$2]++} END{print (n[0]+0)}' "${THROTTLE_CSV}" 2>/dev/null)

    # ★ 先确认这次到底采到时钟没有：老驱动不支持 clocks.* 时（监控循环里已写 WARN），
    #   throttle.csv 的满频字段会全是 N/A。那种情况下报「无降频」是假象 ——
    #   是「没采到」，不是「没问题」，两者不能混为一谈。
    local clk_cards
    clk_cards=$(printf '%s\n' "${stats}" | awk -F'|' '$3+0>0 {c++} END{print c+0}')
    if [ "${clk_cards}" -eq 0 ]; then
        echo "（本次未采集到 SM 时钟数据：满频字段全为空，降频核查跳过）" | tee -a "${LOG}"
        echo "  温度 / 利用率监控不受影响，见 ${MONITOR_CSV}" | tee -a "${LOG}"
        echo "==========================================================" | tee -a "${LOG}"
        return 0
    fi

    # 无降频、且每张卡都有满载点 → 只打一行，不给日志增肥
    local any_issue
    any_issue=$(printf '%s\n' "${stats}" | awk -F'|' '$7+0>0 || $5+0==0 {c++} END{print c+0}')
    if [ "${any_issue}" -eq 0 ]; then
        local ngpu
        ngpu=$(printf '%s\n' "${stats}" | wc -l | tr -d ' ')
        echo "✓ GPU 压测期降频核查：全部 ${ngpu} 卡全程无降频（每卡约 ${npt} 个满载采样点）" | tee -a "${LOG}"
        echo "  明细见 ${THROTTLE_CSV}" | tee -a "${LOG}"
        echo "==========================================================" | tee -a "${LOG}"
        return 0
    fi

    echo "采样时段 : ${ts_first} → ${ts_last}" | tee -a "${LOG}"
    echo "采样粒度 : 60 秒（来自后台监控循环；每卡约 ${npt} 个点，共 ${total} 行）" | tee -a "${LOG}"
    echo "统计口径 : 只统计满载采样点（GPU 利用率 ≥ 50%），压测前后的空闲点不计入" | tee -a "${LOG}"
    echo "" | tee -a "${LOG}"
    echo "GPU | 时钟峰值/满频 | 时钟比 | 温度峰值 | 功耗峰值 | 降频点数/满载点数 | 最长连续(点) | 主要原因" | tee -a "${LOG}"
    echo "----+---------------+--------+----------+----------+-------------------+--------------+--------" | tee -a "${LOG}"

    # 同机横向对比基准：各卡「时钟比均值」的中位数
    local med
    med=$(printf '%s\n' "${stats}" | awk -F'|' '$5+0>0 && $3+0>0 {print int($4)}' \
          | sort -n | awk '{a[NR]=$1} END{if(NR==0)exit; if(NR%2)print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}')

    local g pk mx avg c tot thr run tp pw rsn pct pct_num line
    local -a warns=()
    while IFS='|' read -r g pk mx avg c tot thr run tp pw rsn; do
        [ -n "${g}" ] || continue
        pct_num=-1
        if [ "${c:-0}" -gt 0 ] && [ "${mx:-0}" -gt 0 ]; then
            pct_num=$(( pk * 100 / mx ))
            pct="${pct_num}%"
        else
            pct="N/A"
        fi
        [ "${pk:-0}" -eq 0 ] && pk="N/A"
        [ "${mx:-0}" -eq 0 ] && mx="N/A"
        if [ "${tp:-0}" -eq 0 ]; then tp="N/A"; else tp="${tp}℃"; fi
        if [ "${pw:-0}" = "0.00" ] || [ "${pw:-0}" = "0" ]; then pw="N/A"; else pw="${pw}W"; fi
        [ -z "${rsn}" ] && rsn="无"
        # 单位是「采样点」不是秒：每点约 60 秒，换算看上面的采样粒度
        line=" ${g}  | ${pk}/${mx} | ${pct} | ${tp} | ${pw} | ${thr}/${c}（总 ${tot}） | ${run}点 | ${rsn}"
        echo "${line}" | tee -a "${LOG}"

        if [ "${c:-0}" -eq 0 ] && [ "${tot:-0}" -gt 0 ]; then
            warns+=("WARN!!! GPU${g} 压测期没有任何满载采样点（利用率始终 < 50%）")
        elif [ "${pct_num}" -ge 0 ] && [ -n "${med}" ] && [ "${med}" -gt 0 ] \
             && [ "${pct_num}" -lt $(( med * 85 / 100 )) ]; then
            warns+=("WARN!!! GPU${g} 时钟比 ${pct}，低于同机中位数（${med}%）的 85%")
        fi
    done <<< "${stats}"

    echo "" | tee -a "${LOG}"
    if [ -n "${med}" ] && [ "${med}" -gt 0 ]; then
        echo "同机横向 : 各卡时钟比中位数 ${med}%（单卡低于其 85% 时记 WARN）" | tee -a "${LOG}"
    fi
    if [ ${#warns[@]} -eq 0 ]; then
        echo "✓ 未发现明显异常的降频（详见 ${THROTTLE_CSV}）" | tee -a "${LOG}"
    else
        printf '%s\n' "${warns[@]}" | tee -a "${LOG}"
        echo "→ 明细见 ${THROTTLE_CSV}（长表，可导入 Excel 透视或画时钟/温度/功耗曲线）" | tee -a "${LOG}"
        echo "  日志中已附各卡降频时刻的 nvidia-smi -q -d PERFORMANCE 原文" | tee -a "${LOG}"
        echo "  注：本项只记 WARN，不计入最终 FAIL。" | tee -a "${LOG}"
    fi
    echo "==========================================================" | tee -a "${LOG}"
}

# ============================
# 错误日志巡检（dmesg + SEL）
# ============================
error_log_check() {
    echo -e "\n==================== 错误日志巡检 ====================" | tee -a "${LOG}"

    # dmesg
    echo -e "\n【3.1 内核日志（dmesg）巡检】" | tee -a "${LOG}"
    if command -v dmesg &>/dev/null; then
        local tmp_raw="/tmp/dmesg_filter_$$.tmp"
        local tmp_filtered="/tmp/dmesg_filtered_$$.tmp"

        # ★ 2026-09-30 修订：判定源改为「本次运行期新消息」，不再用全缓冲快照。
        #   原写法 dmesg > tmp_raw 取的是「整个环形缓冲」——含开机自检、启动期 AER/ECC、
        #   log.sh 会话期等历史消息。这些历史报错会被判成本次压测 FAIL（假阳性），
        #   且与 log.sh 的「只判本次会话新增段」口径不一致。
        #   · 正常：dmesg -W 已把运行期新消息落盘到 dmesg.full.log（启动时清空过），
        #     它天然只含本次运行期 —— 直接作为判定源。
        #   · 兜底：跟随进程启动失败时 DMESG_W_PID 为空（采集段已显式置空），
        #     退回一次性全缓冲快照（此时是全脚本唯一的采集），并留存备查。
        if [ -n "${DMESG_W_PID}" ]; then
            cp "${DMESG_FULL_LOG}" "${tmp_raw}"
        else
            echo "[WARN] 内核日志跟随进程未运行，判定退回全缓冲快照（可能含会话前历史）" | tee -a "${LOG}"
            if dmesg > "${tmp_raw}" 2>/dev/null; then
                {
                    echo "===== 巡检时全缓冲快照（跟随进程未运行，此份为判定源）$(date "+%Y-%m-%d %H:%M:%S") ====="
                    cat "${tmp_raw}"
                } >> "${DMESG_FULL_LOG}" 2>/dev/null
            else
                echo "[WARN] dmesg 读取失败，本次无内核日志可判定" | tee -a "${LOG}"
            fi
        fi

        # ===== BEGIN 共享判定表-DMESG（须与 lhtest.sh 完全一致，改一处必须改两处）=====
        # 忽略表：平台/固件已知无害噪音，不参与报错判定（ERE 正则）
        #   后 8 条为 2026-09-30 新增：内核启动 / 正常协商类固定行 —— 短词子串误命中
        #   就出在这些行上（"preset" 含 "reset"、"SECCOMP" 含 "ECC"、
        #   "default" 含 "fault"、启动行 "MCE: CPU supports ... banks" 撞 "MCE:"）。
        #   ★ 2026-09-30 再修订：本表是「整行删除」，过宽的项会把真实报错一并删掉，故收窄：
        #     · 删掉 "systemd-udevd|udevd\[" —— 设备热插拔失败的报错常带 udevd[ 前缀，不能删
        #     · "ACPI (BIOS )?Error" → "ACPI BIOS Error \(bug\)" —— 只忽略固件表 bug，真 ACPI 错误不忽略
        #     · "hpet" → "^hpet[0-9]*:" —— 短词改行首锚定，避免误删含 hpet 的其它行
        local dmesg_ignore=(
            "floppy0: floppy_queue_rq: timeout handler died"
            "apparmor.*profile_replace.*same as current profile, skipping"
            "loop[0-9]*: detected capacity change"
            "snap.*apparmor.*STATUS.*unconfined"
            "audit: type=1400 audit.*apparmor.*STATUS"
            "ACPI BIOS Error \(bug\)"
            "Firmware Bug"
            "apparmor=\"DENIED\""
            "usb [0-9]+-[0-9.]+: reset .* device"
            "EDID block"
            "^hpet[0-9]*:"
            "MCE: CPU supports .* MCE banks"
            "MCE: CPU[0-9]+: Thermal monitoring enabled"
            "Write protecting the kernel read-only data"
            "NVRM: loading NVIDIA UNIX"
            "Calibrating delay loop"
            "systemd.*running in system mode"
            "EDAC MC: Ver:"
            "EDAC i7core: Device not available"
        )

        # 致命表：命中即判 FAIL（keys 与 reasons 必须一一对应、同步增删）
        # 注意：不能直接写 "BUG:"——grep -i 会把它当成子串，命中 dmesg 里常见的
        #   "debug:" 造成假 FAIL，故加非字母边界；"kernel BUG at" 是内核 BUG 的
        #   主要形式（"BUG:" 反而少见），必须单独列一项，不能指望 "BUG:" 覆盖。
        local dmesg_fatal_keys=(
            "Uncorrected error|Uncorrectable error"
            "Machine check"
            "Hardware Error"
            "MCE:|mce: \[Hardware|CPU[0-9]+: Machine Check"
            "Uncorrected.*Fatal"
            "PCIe Bus Error.*(Uncorrected|Fatal)"
            "buffer I/O error"
            "Kernel panic|kernel panic"
            "Oops:"
            "(^|[^A-Za-z])BUG:"
            "kernel BUG at"
            "EDAC.*\bUE\b|EDAC.*Uncorrected|EDAC.*Uncorrectable"
            "NVRM: Xid"
            "fallen off the bus"
            "GPU has fallen off"
            "EXT4-fs error"
            "XFS.*Corruption"
            "Remounting filesystem read-only"
            "md/raid.*(degrad|fail)"
            "RAID.*(degrad|fail)"
            "ata[0-9.]+.*(error|failed|hard resetting link)"
            "nvme.*(I/O Error|controller is down|RESET|timeout|Abort status|async event result)"
            "Sense Key.*Hardware Error|Medium Error"
            "SMART.*FAILURE"
            "Sense Key.*FAILURE|FAILED Result|Unhandled error code"
            "hard LOCKUP"
            "soft lockup"
            "rcu.*stall|RCU.*stall"
            "blocked for more than"
            "hung_task"
            "Out of memory: Kill|oom-kill"
            "General protection fault|page fault with interrupts disabled"
            "RIP: 0010:"
            "bad page state"
            "page allocation failure"
            "slab corruption"
            "unable to handle kernel"
            "PCIe link training failed"
            "Memory failure"
            "severity: fatal|type: fatal"
            "critical (target|medium) error"
            "JBD2.*IO error"
            "FW error in ISR|controller reset failed|IOC Fault"
            "health issue detected|health compromised|device is not ready"
            "xHCI.*not responding|assume dead"
            "Display Engine Halted|GPU lost from the bus|Double Bit ECC"
            "Delayed block allocation failed"
            "temperature above threshold|temperature is above threshold"
            "critical temperature reached|critical trip point|Thermal Trip"
            "overheating"
        )
        local dmesg_fatal_reasons=(
            "【严重】内存ECC不可纠正错误，内存颗粒硬件故障"
            "CPU机器检查异常，CPU/内存/总线硬件故障"
            "硬件级致命错误，通常为CPU或主板故障"
            "CPU机器检查异常，核心硬件故障"
            "【严重】不可纠正致命错误，硬件级故障"
            "PCIe总线错误，网卡/RAID卡/GPU等PCIe设备接触不良或损坏"
            "块设备IO错误，存储介质或链路异常"
            "【严重】内核崩溃，系统级严重故障"
            "内核严重异常，驱动或硬件故障导致"
            "内核BUG触发，通常为驱动或硬件兼容性问题"
            "内核BUG触发（kernel BUG at），驱动或硬件兼容性问题导致"
            "【严重】内存EDAC不可纠正错误(UE)，内存颗粒故障"
            "【严重】GPU Xid异常，显存/掉卡/计算错误"
            "【严重】GPU掉下总线，GPU失联或供电异常"
            "【严重】GPU掉下总线，GPU失联或供电异常"
            "文件系统EXT4错误，磁盘或存储链路故障"
            "文件系统XFS损坏，存储介质故障"
            "文件系统自动转为只读，存储严重故障"
            "RAID阵列降级/失效，硬盘故障"
            "RAID阵列降级/失效，硬盘故障"
            "SATA链路错误，硬盘或线缆故障"
            "NVMe控制器异常，SSD故障"
            "SCSI硬盘硬件错误/介质错误，硬盘故障"
            "硬盘SMART预警，硬盘即将失效"
            "硬盘命令失败/未处理错误，存储链路异常"
            "CPU硬锁定，核心hang死"
            "CPU软锁定，核心卡住"
            "RCU停滞，内核调度异常"
            "任务IO阻塞超时，存储响应异常"
            "任务长时间阻塞不调度，系统卡顿"
            "【严重】内存耗尽触发OOM"
            "CPU通用保护异常，内核或硬件故障"
            "内核异常指令指针，疑似内核崩溃"
            "内存页状态异常"
            "内存页分配失败"
            "内核内存损坏"
            "内核异常处理失败"
            "PCIe链路训练失败，设备未就绪或接触不良"
            "【严重】硬件内存错误(hwpoison)，内存颗粒故障"
            "硬件错误严重级别为 fatal，硬件故障"
            "磁盘介质严重错误，存储介质故障"
            "日志文件系统(JBD2)IO错误，存储链路异常"
            "RAID/存储控制器固件异常，控制器故障"
            "网卡/PCIe设备健康异常或未就绪"
            "USB控制器无响应，控制器挂死"
            "GPU引擎挂起/掉卡/双比特ECC，GPU故障"
            "文件系统延迟块分配失败，存储异常"
            "【严重】CPU/部件温度超过阈值，散热异常"
            "【严重】温度达临界跳闸点，散热严重异常"
            "【严重】部件过热，散热异常"
        )
        local dmesg_warn_keys=(
        #   短词一律加词边界（\b）或换成语义短语，避免子串误命中：
        #     fault -> \bfault\b          避开 default
        #     reset -> \breset\b          避开 preset
        #     ECC   -> \bECC\b           避开 SECCOMP
        #     AER   -> AER: / AER error   避开 ACPI 能力协商 "[AER LTR DPC]"
        #     NVRM  -> NVRM.*(Xid|error)  避开正常加载行 "NVRM: loading ..."
        #     read-only -> 只认文件系统转只读，避开 "kernel read-only data"
            "AER:|AER error|AER:.*[Ee]rror"
            "Corrected error|correctable error|corrected error|Recovered Error"
            "\bECC\b|ECC error"
            "\btimeout\b|timed out|tx_timeout"
            "\breset\b|resetting link|Reset adapter|reset controller|host reset|target reset"
            "\bfault\b|\bfaults\b"
            "Uncorrected"
            "EDAC.*\bCE\b|EDAC.*correctable|EDAC.*disabling"
            "throttl|throttle event"
            "link (is )?down|Link is Down|link down|Cable unplugged|lost carrier"
            "degraded"
            "CRC"
            "read-only file system|filesystem.*read-only"
            "Xid"
            "NVRM.*(Xid|error|Error)|NVRM: GPU|[Nn]vidia.*(Xid|ECC error|lost from)"
            "over-current|overcurrent|overvoltage|voltage out of range|under-voltage"
            "power limit"
            "\bcorrupt|corruption"
            "(disk|drive|device|controller|adapter|port|link|raid|volume|array).{0,20}offline"
            "PCIe Bus Error"
            "Upper Non-critical"
            "No response for cmd|not responding|still trying"
            "are faulty|device is faulty|devices are faulty"
            "I/O error"
            "SCSI error"
        )
        local dmesg_warn_reasons=(
            "PCIe高级错误报告，PCIe链路信号异常"
            "【警告】内存ECC可纠正错误，内存稳定性下降"
            "内存ECC校验错误，需关注内存硬件状态"
            "设备超时，硬件无响应或链路不稳定"
            "设备异常复位，硬件不稳定导致"
            "硬件/内存页故障"
            "存在不可纠正类事件，需结合上下文判断"
            "内存EDAC可纠正错误(CE)或EDAC已停用，内存监控失效"
            "CPU/部件降频限流，散热或供电异常"
            "网络/链路断开"
            "阵列或冗余降级"
            "CRC校验错误，链路信号质量差"
            "文件系统转为只读"
            "GPU Xid告警，显存/驱动异常"
            "NVIDIA内核模块告警"
            "过流/过压/欠压告警，供电异常"
            "功耗限制触发"
            "数据损坏"
            "设备/磁盘/链路离线，需确认是否异常"
            "PCIe总线可纠正错误"
            "传感器非临界告警（温度/电压轻度越限）"
            "链路对端无响应，网络/存储异常"
            "阵列中磁盘故障"
            "磁盘/存储 IO 错误，需结合上下文判断（可能是已恢复的）"
            "SCSI 子系统错误，需结合上下文判断"
        )
        # ===== END 共享判定表-DMESG =====

        cp "${tmp_raw}" "${tmp_filtered}"
        for ig in "${dmesg_ignore[@]}"; do
            grep -viE "${ig}" "${tmp_filtered}" > "${tmp_filtered}.tmp" 2>/dev/null || true
            mv -f "${tmp_filtered}.tmp" "${tmp_filtered}"
        done

        > "${DMESG_LOG}"
        local fatal_hit=0 warn_hit=0
        while IFS= read -r line; do
            [ -z "${line}" ] && continue
            local             reason=""
            # CPU 高温数值判定：行内含温度语义、且温度读数 > CPU_TEMP_FAIL(默认95℃) 时直接判 FAIL
            # （dmesg 里带数值的典型行：thermal_zone0: critical temperature reached (105 C)）
            # ★ 命中后不再走下面的 fatal 表（用 else 分支），否则 reason 会被 fatal 表覆盖。
            if printf '%s' "${line}" | grep -qiE 'cpu|package|core|processor|thermal|temperature|overheat' \
               && printf '%s' "${line}" \
                    | grep -oE '[0-9]{2,3} *(C|℃)|[0-9]{2,3} *degrees? *C|(temp|temperature)[=: ]+[0-9]{2,3}' \
                    | grep -oE '[0-9]+' \
                    | awk -v th="${CPU_TEMP_FAIL}" '($1+0)>th{f=1} END{exit !f}'; then
                reason="【严重】CPU/部件温度超过 ${CPU_TEMP_FAIL}℃，散热异常"
                fatal_hit=1
            else
                for i in "${!dmesg_fatal_keys[@]}"; do
                    if echo "${line}" | grep -qiE "${dmesg_fatal_keys[$i]}"; then
                        reason="${dmesg_fatal_reasons[$i]}"
                        fatal_hit=1
                        break
                    fi
                done
            fi
            if [ -n "${reason}" ]; then
                echo "${line}  # 【FAIL】${reason}" >> "${DMESG_LOG}"
                continue
            fi
            for i in "${!dmesg_warn_keys[@]}"; do
                if echo "${line}" | grep -qiE "${dmesg_warn_keys[$i]}"; then
                    reason="${dmesg_warn_reasons[$i]}"
                    warn_hit=1
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # 【WARN】${reason}" >> "${DMESG_LOG}"
            fi
        done < "${tmp_filtered}"

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

    # BMC SEL
    echo -e "\n【3.2 BMC 系统事件日志（SEL）巡检】" | tee -a "${LOG}"
    if command -v ipmitool &>/dev/null; then
        local tmp_sel_raw="/tmp/sel_filter_$$.tmp"
        ipmitool sel list > "${tmp_sel_raw}" 2>/dev/null

        # 全量留存原始 SEL，便于人工复核厂商特有的事件描述
        cp "${tmp_sel_raw}" "${SEL_RAW_LOG}" 2>/dev/null

        # ===== BEGIN 共享判定表-SEL（须与 lhtest.sh 完全一致，改一处必须改两处）=====
        # 白名单：非硬件故障的记录（仅「日志清空」「时间同步」这类语义唯一的事件）
        #   ★ 2026-09-30 修订一：原表把 "State Asserted/Deasserted"、"Presence detected/deasserted"
        #     也当白名单 —— 而 ipmitool 对「离散传感器事件」的标准描述正是 "State Asserted"，
        #     即「它翻译不出具体含义」时才这么写。含义未知的记录最不该被静默忽略。
        #   ★ 2026-09-30 修订二："Event Logging Disabled" 也移出白名单 —— 它可能是
        #     「BMC 日志被人为/误关」的信号，静默跳过会掩盖问题，改为 WARN 提示人工确认。
        #   以上 5 项全部下沉到下面的 WARN 表。
        local sel_whitelist=(
            "Log area reset"
            "Timestamp Clock Sync"
        )

        # ---- FAIL 级：只放"确定性故障"关键字，命中即判不合格 ----
        # 原表把 Correctable / Fan / Temperature / Voltage / PCIe / ECC / Timeout 等
        # "事件主题词"也放进 FAIL 表，导致一条可纠正 ECC 或风扇调速记录就整机判不合格。
        # 这些描述性词一律下沉到下面的 WARN 表。
        local sel_fatal_keys=(
            "Non-recoverable"
            "Uncorrectable"
            "Predictive Failure"
            "(^|[^a-z-])Critical"              # 匹配 Upper Critical，但不匹配 Non-critical
            "Power Fault"
            "Power Supply.*(Failure|Fault|AC Lost)"
            "Power Unit.*(Failure|Fault)"
            "AC Lost"
            "Redundancy Lost"
            "Redundancy Degraded"
            "Fan Failure"
            "Drive Fault"
            "Medium Error"
            "System Firmware Error"
            "POST Error"
            "Boot Error"
            "Machine Check"
            "IERR"
            "Thermal Trip"
            "Over Temp"
            "Bus Fatal"
            "PCIe.*Fatal"
            "Memory.*(Uncorrectable|Uncorrected)"
        )
        local sel_fatal_reasons=(
            "【严重】不可恢复硬件故障"
            "【严重】不可纠正错误，硬件故障"
            "【严重】硬盘预测性故障预警"
            "【严重】临界/严重硬件告警"
            "电源故障"
            "电源模块故障/掉电"
            "电源单元故障"
            "交流电源丢失"
            "冗余丢失，供电或散热已无备份"
            "冗余降级"
            "风扇失效，散热系统故障"
            "【严重】硬盘故障"
            "存储介质错误"
            "系统固件错误"
            "开机自检错误"
            "启动错误"
            "CPU机器检查异常"
            "【严重】CPU IERR内部错误"
            "【严重】CPU热保护跳闸"
            "过温告警，散热异常"
            "【严重】总线致命错误"
            "【严重】PCIe致命错误"
            "【严重】内存不可纠正错误"
        )

        # ---- WARN 级：需要人工关注，但不直接判不合格 ----
        # 设 SEL_STRICT=1 可把 WARN 项也计入 FAIL（部分客户要求"任何 SEL 事件即不合格"）
        local sel_warn_keys=(
            "Correctable" "Non-critical" "Degraded" "SEL Full" "Log Full"
            "Configuration Error" "Timeout" "Failure" "Fault"
            "ECC" "Voltage" "Fan" "Temperature" "PCIe" "PCI Express"
            "Watchdog" "Bus Error" "Firmware"
            "State Asserted|State Deasserted|Presence detected|Presence deasserted"
            "Event Logging Disabled"
        )
        local sel_warn_reasons=(
            "可纠正错误，硬件稳定性下降"
            "传感器非临界告警（轻度预警）"
            "阵列或冗余降级"
            "SEL日志已满，新事件将无法记录"
            "日志已满"
            "部件配置错误"
            "总线/设备超时"
            "硬件部件失效"
            "部件故障"
            "内存ECC校验告警"
            "电压异常，电源或主板供电"
            "风扇相关事件"
            "温度相关事件"
            "PCIe相关事件"
            "PCIe相关事件"
            "看门狗触发，系统hang死"
            "总线错误"
            "固件相关事件"
            "原白名单事件（状态断言/在位变化），含义未知，需人工确认"
            "BMC 事件日志功能被禁用（可能是人为关闭），需确认"
        )
        # ===== END 共享判定表-SEL =====

        > "${SEL_LOG}"
        local sel_fatal_cnt=0 sel_warn_cnt=0

        while IFS= read -r line; do
            [ -z "${line}" ] && continue
            # 白名单必须小写归一化后再比较：SEL 原文是 "Presence Detected"（大写 D），
            # 而白名单里写的是 "Presence detected"，[[ == ]] 大小写敏感 → 白名单静默失效
            local is_white=0 line_lc
            line_lc=$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')
            for w in "${sel_whitelist[@]}"; do
                if [[ "${line_lc}" == *"${w,,}"* ]]; then
                    is_white=1
                    break
                fi
            done
            if [ "${is_white}" -eq 1 ]; then
                echo "${line}  # 非硬件故障记录（日志清空/时间同步/在位状态），不计入失败" >> "${SEL_LOG}"
                continue
            fi
            local reason=""
            for i in "${!sel_fatal_keys[@]}"; do
                if echo "${line}" | grep -qiE "${sel_fatal_keys[$i]}"; then
                    reason="${sel_fatal_reasons[$i]}"
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # 【FAIL】${reason}" >> "${SEL_LOG}"
                sel_fatal_cnt=$((sel_fatal_cnt + 1))
                continue
            fi
            for i in "${!sel_warn_keys[@]}"; do
                if echo "${line}" | grep -qiE "${sel_warn_keys[$i]}"; then
                    reason="${sel_warn_reasons[$i]}"
                    break
                fi
            done
            if [ -n "${reason}" ]; then
                echo "${line}  # 【WARN】${reason}" >> "${SEL_LOG}"
                sel_warn_cnt=$((sel_warn_cnt + 1))
            fi
        done < "${tmp_sel_raw}"

        if [ "${sel_fatal_cnt}" -gt 0 ]; then
            echo "  [FAIL] 检测到 ${sel_fatal_cnt} 条 BMC 硬件故障记录（另 ${sel_warn_cnt} 条需关注），详情见 ${SEL_LOG}" | tee -a "${LOG}"
            GLOBAL_FAIL=1
        elif [ "${sel_warn_cnt}" -gt 0 ]; then
            echo "  [WARN] 检测到 ${sel_warn_cnt} 条需关注的 BMC 事件（未达故障级），详情见 ${SEL_LOG}" | tee -a "${LOG}"
            if [ "${SEL_STRICT:-0}" = "1" ]; then
                echo "  [FAIL] SEL_STRICT=1：WARN 项也计入失败" | tee -a "${LOG}"
                GLOBAL_FAIL=1
            fi
        else
            # 用 >> 而非 >：保留上面已标注的白名单记录，避免审计留痕被清空
            echo "本次测试未检测到BMC硬件关键报错" >> "${SEL_LOG}"
            echo "  [PASS] 未检测到BMC硬件级关键告警" | tee -a "${LOG}"
        fi

        rm -f "${tmp_sel_raw}"
    else
        echo "ipmitool不可用，跳过BMC SEL日志巡检" > "${SEL_LOG}"
        echo "WARN: ipmitool 不可用，跳过 BMC SEL 日志巡检" | tee -a "${LOG}"
    fi

    echo "========================================================" | tee -a "${LOG}"
}

# ===================== 硬件错误计数器：快照 / 差值 / 定位 =====================
# 为什么需要这一层：dmesg 是「文本层」—— 内核限流 + 环形缓冲滚动会让「没搜到」≠「没发生」。
#   本段读 EDAC / GPU ECC / PCIe AER 的精确计数器，压测前后各采一次算差值，
#   验收要的是「零增长」这个可量化断言，而不是「日志里没关键字」。
# 落盘：快照留在 /tmp（临时），只有差值报告写 ${TEST_DIR}/counter_diff.log。

snapshot_counters(){
    local out="$1"
    : > "${out}"

    # --- 1) 内存 EDAC 计数器（精确到 DIMM）---
    if [ -d /sys/devices/system/edac/mc ]; then
        local mc dimm dn f
        for mc in /sys/devices/system/edac/mc/mc[0-9]*; do
            [ -d "${mc}" ] || continue
            for f in ce_count ue_count; do
                [ -r "${mc}/${f}" ] && echo "MEM|$(basename "${mc}")|${f}|$(cat "${mc}/${f}" 2>/dev/null)" >> "${out}"
            done
            for dimm in "${mc}"/dimm*; do
                [ -d "${dimm}" ] || continue
                dn="$(basename "${dimm}")"
                for f in dimm_ce_count dimm_ue_count; do
                    [ -r "${dimm}/${f}" ] && echo "MEM|$(basename "${mc}")/${dn}|${f}|$(cat "${dimm}/${f}" 2>/dev/null)" >> "${out}"
                done
                # 丝印标签（rasdaemon --register-labels 写入）与物理位置，
                # 用于把 mc0/csrow2 这类内部编号翻成 DIMM_A2
                f="$(cat "${dimm}/dimm_label" 2>/dev/null)"
                [ -n "${f}" ] && echo "MEMMAP|$(basename "${mc}")/${dn}|label|${f}" >> "${out}"
                f="$(cat "${dimm}/dimm_location" 2>/dev/null)"
                [ -n "${f}" ] && echo "MEMMAP|$(basename "${mc}")/${dn}|location|${f}" >> "${out}"
            done
        done
    fi

    # --- 2) GPU ECC 计数器（volatile = 本次开机以来；消费卡不支持 ECC 时值为 N/A → 记 -1 跳过）---
    #     同时采 pci.bus_id 作槽位标识：index 只是按 BDF 排序的枚举号，不是物理位置；
    #     有了 BDF 才能对应机箱槽位，也和 check_gpu_vbios 的槽位列对得上（同一张卡不会搞混）
    if command -v nvidia-smi &>/dev/null; then
        # ★ 能力探测：--query-gpu 是「全有或全无」——只要 ecc.* 有一个字段不被当前驱动
        #   支持，整条命令就报错退出、一行都不输出。那种情况下快照里会完全没有 GPU ECC 行，
        #   后续差值对比会把「根本没采到」误报成「所有计数器零增长」。所以先探再查，
        #   探测失败就退回只查身份字段（仍记下卡在位与槽位），并写 WARN 留痕。
        local ECC_Q
        ECC_Q="index,pci.bus_id,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total"
        if ! nvidia-smi --query-gpu="${ECC_Q}" --format=csv,noheader,nounits >/dev/null 2>&1; then
            ECC_Q="index,pci.bus_id"
            echo "WARN: 当前 nvidia-smi 不支持 ecc.errors.* 字段，GPU ECC 计数器本次不采集（仅记录卡与槽位）" >> "${LOG}"
        fi
        nvidia-smi --query-gpu="${ECC_Q}" --format=csv,noheader,nounits 2>/dev/null \
            | while IFS=',' read -r gi gbid gce gue; do
            gi=$(printf '%s' "${gi}" | tr -d ' ')
            gbid=$(printf '%s' "${gbid}" | tr -d ' ')
            gce=$(printf '%s' "${gce}" | tr -d ' ')
            gue=$(printf '%s' "${gue}" | tr -d ' ')
            case "${gce}" in ''|*[!0-9]*) gce=-1 ;; esac
            case "${gue}" in ''|*[!0-9]*) gue=-1 ;; esac
            echo "GPU|gpu${gi}|ecc_ce|${gce}" >> "${out}"
            echo "GPU|gpu${gi}|ecc_ue|${gue}" >> "${out}"
            # 槽位映射单独成行（同 MEMMAP 做法），不参与差值计算；
            # 旧驱动读不到该字段时值是 [N/A]，过滤掉不记
            case "${gbid}" in ''|*[Nn]/[Aa]*) : ;; *) echo "GPUMAP|gpu${gi}|busid|${gbid}" >> "${out}" ;; esac
        done
    fi

    # --- 3) PCIe AER 计数器（每设备只取总计行，明细行不入快照以控制体积）---
    local dev bdf v
    for dev in /sys/bus/pci/devices/*/aer_dev_correctable; do
        [ -r "${dev}" ] || continue
        bdf="$(basename "$(dirname "${dev}")")"
        v=$(awk '$1=="TOTAL_ERR_COR"{print $2; exit}' "${dev}" 2>/dev/null)
        [ -n "${v}" ] && echo "AER|${bdf}|cor|${v}" >> "${out}"
    done
    for dev in /sys/bus/pci/devices/*/aer_dev_fatal; do
        [ -r "${dev}" ] || continue
        bdf="$(basename "$(dirname "${dev}")")"
        v=$(awk '$1=="TOTAL_ERR_FATAL"{print $2; exit}' "${dev}" 2>/dev/null)
        [ -n "${v}" ] && echo "AER|${bdf}|fatal|${v}" >> "${out}"
    done
    for dev in /sys/bus/pci/devices/*/aer_dev_nonfatal; do
        [ -r "${dev}" ] || continue
        bdf="$(basename "$(dirname "${dev}")")"
        v=$(awk '$1=="TOTAL_ERR_NONFATAL"{print $2; exit}' "${dev}" 2>/dev/null)
        [ -n "${v}" ] && echo "AER|${bdf}|nonfatal|${v}" >> "${out}"
    done
}

# rasdaemon：把 EDAC 的 mc0/csrow2 这类内部编号翻译成主板丝印（DIMM_A2）
ras_label_report(){
    echo -e "\n【内存错误定位（rasdaemon 丝印翻译）】" | tee -a "${LOG}"
    if ! command -v ras-mc-ctl &>/dev/null; then
        echo "  [INFO] 未安装 rasdaemon，无法自动翻译成丝印；" | tee -a "${LOG}"
        echo "         可手动比对 counter_diff.log 里的 MEMMAP 段（dimm_location）" | tee -a "${LOG}"
        return
    fi

    # 1) 尝试把主板标签库写入 dimm_label（无标签库时会报 no label file，属正常降级）
    local reg
    reg=$(ras-mc-ctl --register-labels 2>&1)
    if printf '%s' "${reg}" | grep -qiE 'no label file|not found|No such'; then
        echo "  [INFO] 本机主板无 rasdaemon 标签库（/etc/rasdaemon/labels/），改用 dimm_location 定位" | tee -a "${LOG}"
    elif [ -n "${reg}" ]; then
        printf '%s\n' "${reg}" | sed 's/^/    /' | tee -a "${LOG}"
    fi

    # 2) 内存布局：mc / csrow / channel → DIMM 丝印 的对应关系
    if ras-mc-ctl --layout >/dev/null 2>&1; then
        echo "  [内存布局]" | tee -a "${LOG}"
        ras-mc-ctl --layout 2>/dev/null | head -80 | sed 's/^/    /' | tee -a "${LOG}"
    fi

    # 3) 错误摘要（依赖 rasdaemon 服务运行；未运行则无输出）
    local smy
    smy=$(ras-mc-ctl --summary 2>/dev/null)
    if [ -n "${smy}" ]; then
        echo "  [错误摘要]" | tee -a "${LOG}"
        printf '%s\n' "${smy}" | sed 's/^/    /' | tee -a "${LOG}"
    fi
}

# 计数器差值报告：只列增量非零项，UE/Fatal 判 FAIL，CE/NonFatal/Correctable 判 WARN
counter_diff_report(){
    local before="$1" after="$2"
    local out="${TEST_DIR}/counter_diff.log"

    echo -e "\n==================== 硬件错误计数器增量（压测前后差值） ====================" | tee -a "${LOG}"

    if [ ! -s "${before}" ] && [ ! -s "${after}" ]; then
        echo "  [WARN] EDAC / GPU ECC / PCIe AER 计数器均不可用，本次无计数器证据（只能依赖 dmesg 文本巡检）" | tee -a "${LOG}"
        {
            echo "===== 硬件错误计数器增量报告 $(date '+%Y-%m-%d %H:%M:%S') ====="
            echo "SN: ${SN}   工号: ${testid}"
            echo "计数器不可用（EDAC / GPU ECC / PCIe AER 均未采集到）"
        } > "${out}"
        return 0
    fi

    # 逐项算差值：只输出增量非零项
    local diffs
    # 去重：mc 级 ce_count/ue_count 是控制器汇总，dimm 级是明细；
    #   同一错误会被父子两级各报一次 → 第一遍标记被明细覆盖的 (mc,CE/UE)，第二遍输出时跳过汇总行
    diffs=$(awk -F'|' '
        NR==FNR { if ($1!="MEMMAP" && $1!="GPUMAP") b[$1"|"$2"|"$3]=$4; next }
        { if ($1!="MEMMAP" && $1!="GPUMAP") a[$1"|"$2"|"$3]=$4 }
        END {
            for (k in b) if (!(k in a)) a[k]=b[k]
            for (k in a) {
                if (b[k]=="-1" || a[k]=="-1") continue
                bv = (k in b) ? b[k]+0 : 0
                av = (k in a) ? a[k]+0 : 0
                if (av - bv == 0) continue
                split(k, p, "[|]")
                if (p[2] ~ /\//) {
                    split(p[2], q, "/")
                    f = (p[3]=="dimm_ce_count") ? "ce" : (p[3]=="dimm_ue_count") ? "ue" : p[3]
                    cov[q[1]"|"f] = 1
                }
            }
            for (k in a) {
                if (b[k]=="-1" || a[k]=="-1") continue
                bv = (k in b) ? b[k]+0 : 0
                av = (k in a) ? a[k]+0 : 0
                d = av - bv
                if (d == 0) continue
                split(k, p, "[|]")
                if (p[2] !~ /\//) {
                    f = (p[3]=="ce_count") ? "ce" : (p[3]=="ue_count") ? "ue" : p[3]
                    if ((p[2]"|"f) in cov) continue
                }
                print k"|"bv"|"av"|"d
            }
        }' "${before}" "${after}" | sort)

    # 丝印 / 槽位映射（把 mc0/dimm2 翻成 DIMM_A2、把 gpu2 带上 PCIe BDF）
    local maps gpumaps
    maps=$(grep '^MEMMAP|' "${after}" 2>/dev/null || true)
    gpumaps=$(grep '^GPUMAP|' "${after}" 2>/dev/null || true)

    {
        echo "===== 硬件错误计数器增量报告 $(date '+%Y-%m-%d %H:%M:%S') ====="
        echo "SN: ${SN}   工号: ${testid}"
        echo "说明：volatile 计数器；快照1=压测前，快照2=压测后；只列增量非零项"
        echo ""
        echo "----- 快照1（压测前）-----"
        cat "${before}"
        echo ""
        echo "----- 快照2（压测后）-----"
        cat "${after}"
        echo ""
        echo "----- 增量（压测后 - 压测前）-----"
        if [ -n "${diffs}" ]; then
            printf '%s\n' "${diffs}"
        else
            echo "（全部计数器零增长）"
        fi
        echo ""
        echo "----- DIMM 丝印映射 -----"
        if [ -n "${maps}" ]; then
            printf '%s\n' "${maps}"
        else
            echo "（无：rasdaemon --register-labels 未写入标签，或该平台 EDAC 未暴露 dimm_label）"
        fi
        echo ""
        echo "----- GPU 槽位映射 -----"
        if [ -n "${gpumaps}" ]; then
            printf '%s\n' "${gpumaps}"
        else
            echo "（无：该驱动不支持 nvidia-smi 的 pci.bus_id 字段）"
        fi
    } > "${out}"

    if [ -z "${diffs}" ]; then
        echo "  [PASS] 所有计数器零增长（内存 EDAC / GPU ECC / PCIe AER）" | tee -a "${LOG}"
        echo "         详情：${out}" | tee -a "${LOG}"
        return 0
    fi

    # 有增量：分级判定
    #   GPU 的 item 先补上 PCIe BDF（gpu2 → gpu2[0000:5E:00.0]）——
    #   没有 BDF 时只知道「第几张卡」，对不上机箱槽位
    declare -A GPU_BDF
    if [ -n "${gpumaps}" ]; then
        local _tag _k _f _v
        while IFS='|' read -r _tag _k _f _v; do
            [ "${_tag}" = "GPUMAP" ] && GPU_BDF["${_k}"]="${_v}"
        done <<< "${gpumaps}"
    fi

    local fail_cnt=0 warn_cnt=0
    local cat item field bv av dv reason
    while IFS='|' read -r cat item field bv av dv; do
        [ -z "${cat}" ] && continue
        if [ "${cat}" = "GPU" ] && [ -n "${GPU_BDF[${item}]:-}" ]; then
            item="${item}[${GPU_BDF[${item}]}]"
        fi
        case "${cat}:${field}" in
            MEM:ue_count|MEM:dimm_ue_count)   reason="内存不可纠正错误(UE) —— 内存颗粒故障" ;;
            MEM:ce_count|MEM:dimm_ce_count)   reason="内存可纠正错误(CE) —— 内存稳定性下降" ;;
            GPU:ecc_ue)                       reason="GPU 不可纠正 ECC 错误 —— 显存故障" ;;
            GPU:ecc_ce)                       reason="GPU 可纠正 ECC 错误 —— 显存劣化" ;;
            AER:fatal)                        reason="PCIe 致命错误(AER Fatal) —— 链路故障" ;;
            AER:nonfatal)                     reason="PCIe 非致命错误(AER Non-Fatal)" ;;
            AER:cor)                          reason="PCIe 可纠正错误(AER Correctable)" ;;
            *)                                reason="硬件错误计数增长" ;;
        esac
        case "${cat}:${field}" in
            MEM:ue_count|MEM:dimm_ue_count|GPU:ecc_ue|AER:fatal)
                echo "  [FAIL] ${item} ${field}: ${bv} → ${av}（+${dv}）  ${reason}" | tee -a "${LOG}"
                fail_cnt=$((fail_cnt + 1)) ;;
            *)
                echo "  [WARN] ${item} ${field}: ${bv} → ${av}（+${dv}）  ${reason}" | tee -a "${LOG}"
                warn_cnt=$((warn_cnt + 1)) ;;
        esac
    done <<< "${diffs}"

    if [ "${fail_cnt}" -gt 0 ]; then
        GLOBAL_FAIL=1
        echo "  [FAIL] 共 ${fail_cnt} 项致命增量、${warn_cnt} 项警告增量，详情：${out}" | tee -a "${LOG}"
    else
        echo "  [WARN] 共 ${warn_cnt} 项计数器增长（未达致命级），详情：${out}" | tee -a "${LOG}"
    fi

    # 有内存增量时，调 rasdaemon 做丝印定位
    if printf '%s\n' "${diffs}" | grep -q '^MEM|'; then
        ras_label_report
    fi
    return 0
}

# ============================
# 压力老化总入口（CPU + 内存用一条 stress-ng 命令）
# ============================
stress_stage(){
    echo -e "\n==================== 阶段2：压力老化测试开始 ====================" | tee -a "${LOG}"
    local STRESS_START_TS=$(date +%s)

    : > "${STRESS_PID_FILE}"
    MONITOR_LOOP &
    MONITOR_PID=$!
    echo "后台实时温度功耗监控已启动" | tee -a "${LOG}"

    echo -e "\n【2.1 CPU + 内存联合压力测试 ${TEST_TIME}秒】" | tee -a "${LOG}"
    if command -v stress-ng &>/dev/null;then
        MEM_SIZE=$(LC_ALL=C free -m | awk -v r="${MEM_RATIO}" '/^Mem:/{print int($2*r/100)}')
        if [ -z "${MEM_SIZE}" ] || [ "${MEM_SIZE}" -lt 64 ];then
            echo "WARN: 内存过小（${MEM_SIZE:-0}MB），仅运行CPU压力测试" | tee -a "${LOG}"
            stress-ng --cpu $(nproc) --cpu-method all --timeout ${TEST_TIME} >/dev/null 2>&1 &
            CPU_PID=$!
        else
            # 内存 worker 数量固定为 1（直接压满 80%）
            VM_WORKERS=1
            VM_BYTES=${MEM_SIZE}
            [ ${VM_BYTES} -lt 64 ] && VM_BYTES=64

            stress-ng --cpu $(nproc) --cpu-method all \
                      --vm ${VM_WORKERS} --vm-bytes ${VM_BYTES}M --vm-method all \
                      --timeout ${TEST_TIME} >/dev/null 2>&1 &
            CPU_PID=$!
            echo "CPU + 内存联合压力测试已启动" | tee -a "${LOG}"
            echo "  CPU: $(nproc) 个逻辑核心" | tee -a "${LOG}"
            echo "  内存: ${MEM_SIZE}MB（约${MEM_RATIO}%总内存），${VM_WORKERS} 个 worker，每个 ${VM_BYTES}MB" | tee -a "${LOG}"
        fi
    else
        echo "WARN: stress-ng未找到，跳过CPU和内存压力测试" | tee -a "${LOG}"
    fi
    # 写入 PID 文件：监控循环是后台子进程，读不到这里的 CPU_PID，高温时要靠文件回收
    [ -n "${CPU_PID}" ] && echo "${CPU_PID}" >> "${STRESS_PID_FILE}"

    echo -e "\n【2.2 GPU双精度压力烤机】" | tee -a "${LOG}"
    GPU_PID=""
    if command -v nvidia-smi &>/dev/null && command -v gpu-burn &>/dev/null;then
        gpu-burn -d ${TEST_TIME} >> "${LOG}" 2>&1 &
        GPU_PID=$!
        echo "${GPU_PID}" >> "${STRESS_PID_FILE}"
        sleep 2
        if kill -0 "${GPU_PID}" 2>/dev/null; then
            echo "GPU双精度烤机已启动，时长 ${TEST_TIME} 秒" | tee -a "${LOG}"
        else
            echo "FAIL：GPU双精度烤机启动失败，请检查 gpu-burn 及CUDA环境" | tee -a "${LOG}"
            GLOBAL_FAIL=1
            GPU_PID=""
        fi
    else
        echo "WARN：缺少 gpu-burn 或 nvidia-smi，跳过GPU烤机" | tee -a "${LOG}"
    fi

    # 硬盘老化压测：与 CPU/GPU 同时启动（多盘并行），只判定有无报错，不看跑多快
    disk_stage_start

    local wait_pids=()
    [ -n "${CPU_PID}" ] && wait_pids+=("${CPU_PID}")
    [ -n "${GPU_PID}" ] && wait_pids+=("${GPU_PID}")

    if [ ${#wait_pids[@]} -gt 0 ]; then
        echo "所有压力项已启动，等待测试完成..." | tee -a "${LOG}"
        for pid in "${wait_pids[@]}"; do
            wait "$pid"; rc=$?
            if [ ${rc} -ne 0 ]; then
                # 高温中止是我们主动 kill 的，不是压测自身异常，不重复记 WARN
                if [ -f "${TEMP_ABORT_FILE}" ]; then
                    :
                elif [ "$pid" = "${CPU_PID}" ]; then
                    echo "WARN：CPU+内存压力测试异常退出（返回码${rc}）" | tee -a "${LOG}"
                    GLOBAL_FAIL=1
                elif [ "$pid" = "${GPU_PID}" ]; then
                    echo "WARN：GPU双精度烤机异常退出（返回码${rc}），可能存在计算错误或硬件不稳定" | tee -a "${LOG}"
                    GLOBAL_FAIL=1
                fi
            fi
        done
    fi

    # 硬盘压测单独一轮 wait：按 DISK_DEVS 顺序逐个回收，退出码写入 DISK_RC（与 DISK_DEVS 同序），
    # 供 disk_stage_finish 判定。不能混进上面的 wait_pids —— 那个循环只认 CPU/GPU 两个 PID。
    if [ "${DISK_STARTED}" = "1" ]; then
        local di drc
        for di in "${!DISK_PIDS[@]}"; do
            wait "${DISK_PIDS[$di]}"; drc=$?
            DISK_RC[$di]="${drc}"
        done
    fi

    # 高温中断判定：监控循环在超阈值时已回收烤机进程并写入原因
    if [ -f "${TEMP_ABORT_FILE}" ]; then
        echo "  [FAIL] 压力测试因高温被提前中止：$(cat "${TEMP_ABORT_FILE}" 2>/dev/null)" | tee -a "${LOG}"
        echo "         已完成时长约 $(( $(date +%s) - STRESS_START_TS )) 秒 / 计划 ${TEST_TIME} 秒" | tee -a "${LOG}"
        GLOBAL_FAIL=1
    fi

    # 监控循环里常驻 sleep，直接 kill 父进程要等前台命令结束才处理信号，
    # 用 stop_tree 先收子进程再收父进程
    stop_tree "${MONITOR_PID}"
    MONITOR_PID=""
    echo "后台实时监控已停止" | tee -a "${LOG}"

    # 硬盘压测收尾：判定有无报错 + SMART 复测（必须在所有 fio 进程已回收之后）
    disk_stage_finish

    echo -e "\n==================== 阶段2：压力老化测试结束 ====================" | tee -a "${LOG}"
}

# ====================== 主流程执行 ======================
START_TS=$(date +%s)

# 计数器快照1（压测前）—— 与压测后的快照2 做差值
COUNTER_BEFORE="/tmp/hwcounter_before_$$.log"
COUNTER_AFTER="/tmp/hwcounter_after_$$.log"
snapshot_counters "${COUNTER_BEFORE}"

stress_stage

# GPU 压测期降频核查汇总（读 throttle.csv；监控循环已在 stress_stage 末尾 stop_tree 掉）
throttle_report

# 错误日志巡检
error_log_check

# 计数器快照2（压测后）→ 差值报告
snapshot_counters "${COUNTER_AFTER}"
counter_diff_report "${COUNTER_BEFORE}" "${COUNTER_AFTER}"
rm -f "${COUNTER_BEFORE}" "${COUNTER_AFTER}"

# 检查温度告警
if [ -f "${TEMP_ALERT_FILE}" ];then
    echo -e "\n检测到温度告警记录：CPU 超过 ${CPU_TEMP_WARN}℃ / GPU 超过 ${GPU_TEMP_WARN}℃ / 硬盘超过告警阈值（机械盘 ${DISK_TEMP_WARN_HDD}℃、固态盘 ${DISK_TEMP_WARN_SSD}℃）（未达中断阈值，详见 ${MONITOR_CSV}）" | tee -a "${LOG}"
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
