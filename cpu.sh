#!/bin/bash
# ============================================================
# cpu.sh —— CPU 在位检测（型号 / 物理颗数 / 逻辑核数 / 可用线程数）
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   bash cpu.sh                # 一条命令，直接出结果（不需要 root）
#   bash cpu.sh --help         # 打印这段帮助
#
#   ★ 没有必填参数。
#   ★ 只能在 Linux 上运行（非 Linux 会被平台守卫直接拦下，exit 2）。
#
#   【输出】
#     ==================== CPU 在位检测 ====================
#     CPU 型号      : 12th Gen Intel(R) Core(TM) i5-12400
#     物理 CPU 颗数 : 2
#     逻辑 CPU 数量 : 2
#     可用线程数    : 2
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
#   物理颗数三路依次兜底：
#     1) /proc/cpuinfo 的 physical id 去重计数
#     2) /sys/devices/system/cpu/cpu*/topology/physical_package_id 去重计数
#     3) lscpu 的 Socket(s) 字段
#   逻辑核数取 /proc/cpuinfo 的 processor 行数；
#   可用线程数取 nproc；型号取 /proc/cpuinfo 第一条 model name。
#
# ---- 五、这几个数怎么读（重要） ----
#   ★ 本脚本只报数，不做判定、也不返回失败码（按用户要求精简）。
#   ★ 「可用线程数(nproc)」< 「逻辑 CPU 数量」→ 本进程被 taskset / cgroup 限制；
#     两者相等即正常。
#   ★ 虚拟机里「物理 CPU 颗数」是【虚拟 socket 数】，不是真物理颗数。
#     实测：2 vCPU 的 VMware guest 报 2（2 socket × 1 核），physical id 是 0 和 2。
#   ★ 不显示 `nproc --all`：它读的是 possible / configured CPU 数（含 offline），
#     不是真实核数。VMware 的虚拟 ACPI 为支持 CPU 热添加声明了 128 个 possible CPU，
#     实测同一台 2 vCPU 的 guest 上 `nproc --all` 返回 128，而真实核数只有 2。
#     拿它算并发会严重高估，故不显示（判断"被限制"看上面那条即可）。
#
# ---- 六、产物 ----
#   无。本脚本不写文件、不建目录（按你要求不落盘），全部直接打屏。
#   要留存：bash cpu.sh | tee cpu_$(date +%m%d_%H%M).txt
#
# ---- 七、设计说明（想知道「为什么这么写」再看） ----
#   ★ 为什么颗数要三路兜底：
#     部分平台/虚拟机的 /proc/cpuinfo 不输出 physical id（拿不到就退到
#     sysfs），个别老内核连 sysfs 也没有（再退到 lscpu）。只认一路会在
#     这些平台上误报"未识别到 CPU"——那是解析失败，不是 CPU 不在位。
#   ★ 为什么型号用 cut -f2- 而不是 -f2：型号里带冒号时不会被截断。
# ============================================================

set -u

RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then RED=''; CYAN=''; NC=''; fi
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

# ---------- 前置检查 ----------
# 平台守卫：本脚本读 /proc/cpuinfo 与 sysfs，在非 Linux（Windows / MSYS）上
# 一律读不到 —— 不拦就会把"平台不对"当成"机器没有 CPU"，必须先拦掉（§3.24）。
_os="$(uname -s 2>/dev/null || echo unknown)"
case "${_os}" in
    Linux) : ;;
    *) err "本脚本只能在 Linux 上运行（当前 uname -s = ${_os}）"
       info "请在 Ubuntu 22.04 被测机上执行：bash cpu.sh"
       exit 2 ;;
esac

if [ ! -r /proc/cpuinfo ]; then
    err "读不到 /proc/cpuinfo，无法解析 CPU 信息"
    exit 2
fi

# ---------- 1) 物理颗数：三路依次兜底 ----------
CPU_PHYSICAL=""

# 路 1：/proc/cpuinfo 的 physical id
if grep -q '^physical id' /proc/cpuinfo 2>/dev/null; then
    CPU_PHYSICAL=$(grep '^physical id' /proc/cpuinfo | awk '{print $NF}' | sort -u | wc -l)
fi

# 路 2：sysfs physical_package_id
if [ -z "${CPU_PHYSICAL}" ] || [ "${CPU_PHYSICAL}" -eq 0 ]; then
    if compgen -G "/sys/devices/system/cpu/cpu*/topology/physical_package_id" >/dev/null 2>&1; then
        CPU_PHYSICAL=$(cat /sys/devices/system/cpu/cpu*/topology/physical_package_id 2>/dev/null | sort -u | wc -l)
    fi
fi

# 路 3：lscpu Socket(s)
if [ -z "${CPU_PHYSICAL}" ] || [ "${CPU_PHYSICAL}" -eq 0 ]; then
    if command -v lscpu >/dev/null 2>&1; then
        CPU_PHYSICAL=$(LC_ALL=C lscpu 2>/dev/null \
                       | awk -F: '/^Socket\(s\):/{gsub(/[^0-9]/,"",$2); print $2; exit}')
        [ -z "${CPU_PHYSICAL}" ] && CPU_PHYSICAL=0
    fi
fi
[ -z "${CPU_PHYSICAL}" ] && CPU_PHYSICAL=0

# ---------- 2) 逻辑核数 ----------
CPU_LOGICAL=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ -z "${CPU_LOGICAL}" ] && CPU_LOGICAL=0

# ---------- 3) 型号 ----------
# 用 cut -f2- 而不是 -f2：型号里带冒号时（少见）不会被截断
CPU_MODEL=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null \
            | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# ---------- 4) 可用线程数 ----------
# 只用 nproc（本进程可用）；不用 nproc --all —— 它读的是 possible CPU 数（含 offline），
# 虚拟机上会虚高（详见头部第五节）。
CPU_NPROC=""
if command -v nproc >/dev/null 2>&1; then
    CPU_NPROC=$(nproc 2>/dev/null)
fi

# ---------- 输出 ----------
echo "==================== CPU 在位检测 ===================="
echo "CPU 型号      : ${CPU_MODEL:-未读取到}"
echo "物理 CPU 颗数 : ${CPU_PHYSICAL}"
echo "逻辑 CPU 数量 : ${CPU_LOGICAL}"
echo "可用线程数    : ${CPU_NPROC:-未读取到}"
