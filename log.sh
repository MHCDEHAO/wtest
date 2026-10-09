#!/usr/bin/env bash
#
# log.sh —— 验收日志会话控制器（含会话级内核 / SEL 日志采集）
# ---------------------------------------------------------------------------
# 作用：在本目录启动一次「记录会话」。输入 SN 与员工工号后，
#       此后在本终端执行的**任何脚本**，输出都会同时：
#         · 显示在屏幕上（原样，不丢交互）
#         · 追加写入 <SN>-test-log/<SN>.log
#       输入 `test esc` 结束记录，之后恢复正常、不再落盘。
#
# ★ 会话级日志采集（A+ 方案）
#   会话开始：留存会话前内核日志全量（dmesg → dmesg.boot.log）
#             → 启动 dmesg -W 只跟随新消息（--follow-new）
#             → 留存 BMC SEL 基线快照
#   会话结束：自动做一次「内核日志 / SEL 新增告警」巡检
#
# ★ 产物全部收在一个目录里：<SN>-test-log/（如 1-test-log/）
#     <SN>.log         终端台账（谁跑了什么、输出了什么）
#     dmesg.boot.log   会话前内核日志全量留存（会话开始前的完整历史，dmesg 原始输出）
#     dmesg.full.log   会话期间内核日志（dmesg -W --follow-new 产物，未过滤）
#     sel.raw.log      SEL 基线 + 收尾（两段，以「===== 会话开始/结束 =====」分隔）
#     report.txt       巡检结论（会话窗口 + 命中明细，与终端输出一致）
#
# ★ 判定表：内联在本脚本里
#   白名单直接内联（与 lhtest.sh 同源，**改一处必须改两处**）。
#   不依赖任何外部脚本 —— 判定表在本脚本内自持，避免运行时依赖。
#
# ★ 设计前提（A+）
#   lhtest.sh / fieldiag 放在**会话外**单独跑。本脚本负责覆盖「会话全程」的
#   内核 / SEL 证据，两者相互独立、互不冲抵。
#
# 用法：  cd 到本脚本所在目录（你的 test 文件夹），然后
#           sudo ./log.sh
#
# ★ 权限要求：必须 root（脚本启动时检查，非 root 直接拒绝执行，不创建任何文件）
#   内核日志采集（dmesg）与 BMC SEL 采集（ipmitool sel）都要求 root：
#     · Ubuntu 默认 kernel.dmesg_restrict=1，普通用户读不了内核环形缓冲
#     · /dev/ipmi0 通常只有 root 可读
#   非 root 执行只能得到空的采集文件、没有验收价值，故不降级、直接退出。
#
# ★ 依赖工具预检 + 自动安装（写法对齐 test.sh 的 check_deps_preview）
#   启动时逐项检测下列命令；**默认只检测不安装**（装完继续，不中断会话）：
#     lspci(pciutils) · findmnt/lsblk/dmesg(util-linux) · ipmitool · dmidecode
#     · smartctl(smartmontools) · nvidia-smi（不自动装，需人工装 NVIDIA 驱动）
#   前三组是本脚本自身采集 + 后续各部件脚本常用；nvidia-smi 缺失只提示、不装。
#   ★ 2026-09-30 起**默认不自动安装**（验收通常要求「不改被测系统」）。
#     需要自动装时显式开启：LOG_AUTO_INSTALL=1 sudo ./log.sh
#     安装走 DEBIAN_FRONTEND=noninteractive，并把包名记进巡检报告便于追溯。
#
# 会话内可用命令：
#   tip        显示脚本执行进度（已执行的带退出码，未执行的列出来）
#   test esc   结束记录并退出（退出时自动打印执行汇总表 + 日志巡检报告）
#
# 环境变量：
#   OUTSIDE="lhtest.sh fieldiag"  会话外单独跑的脚本，不计入 tip 的「未执行」
#                                （默认即此；设 OUTSIDE="" 可关闭该排除）
#   LOG_AUTO_INSTALL=1            开启依赖自动安装（默认关闭，只提示、不执行安装命令）
#
# 说明：  · 本脚本**不修改任何被测脚本**，只改变本终端的输出去向。
#        · 同一个 SN 重复记录时，台账 / 采集 / 报告**全部追加**、不覆盖；
#          巡检只覆盖「本次会话」新增的部分（dmesg 按起始行号切分，SEL 只取最后一段）。
#        · 同一个 SN 同一时刻只允许一个记录会话（flock 排他锁），重复运行会直接拒绝。
#        · 报告里「未采到数据」会区分三种原因：① 工具未安装 ② 无权限 / BMC 不支持
#          ③ 工具正常但会话期间确实没产生日志 —— 不再一律写成「不可用/无权限」。
#        · 即使以 root 运行也可能采不到（容器 / 本机无 BMC），报告会照上述三态说明。
# ---------------------------------------------------------------------------

set -u

# ---- 定位脚本所在目录（即 test 文件夹）----
SELF="${BASH_SOURCE[0]}"
DIR="$(cd "$(dirname "$SELF")" && pwd)"

# =====================================================================
# 前置检验：必须 root 运行
#   · dmesg 读内核环形缓冲 —— dmesg_restrict=1 时只有 root 能读
#   · ipmitool sel         读 BMC SEL    —— /dev/ipmi0 通常仅 root 可读
#   这两项是本脚本的核心采集。非 root 跑只会得到空的采集文件、没有验收价值，
#   所以直接拒绝执行（此刻还没创建任何文件，不会留残留）。
# =====================================================================
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf '错误：本脚本需要 root 权限运行，已退出（未创建任何文件）。\n' >&2
    printf '      当前用户 : %s (uid=%s)\n' "${USER:-未知}" "${EUID:-$(id -u)}" >&2
    printf '      原因     : 内核日志（dmesg）与 BMC SEL（ipmitool）采集都要求 root，\n' >&2
    printf '                 普通用户执行只能拿到空的采集文件，没有验收价值。\n' >&2
    printf '      请改用   : sudo %s\n' "$DIR/${SELF##*/}" >&2
    exit 1
fi

# =====================================================================
# 依赖工具预检 + 自动安装（写法对齐 test.sh 的 check_deps_preview）
#   · 本脚本自身需要：dmesg(util-linux) / ipmitool / dmidecode
#   · 后续部件脚本常用：lspci(pciutils) / smartctl(smartmontools) / findmnt / lsblk
#   · nvidia-smi 不自动装（要装 NVIDIA 驱动），只提示
#   默认只检测不安装（开 LOG_AUTO_INSTALL=1 才装）；装不上只提示、不退出 —— 缺工具的后果由各采集函数
#   自己按三态报出来，不该在这里把脚本打死。
#   默认即关闭；需要自动装时：LOG_AUTO_INSTALL=1 sudo ./log.sh
# =====================================================================
# ★ 2026-09-30 修订：默认改为「不自动安装」—— 验收场景通常要求「测试不得改变被测系统」，
#   开箱即装会直接违反。需要自动装时显式开启：LOG_AUTO_INSTALL=1 sudo ./log.sh
LOG_AUTO_INSTALL="${LOG_AUTO_INSTALL-0}"
# 本次会话自动安装过的包（写进巡检报告，便于事后追溯「被测机被改过什么」）
INSTALLED_PKGS=""

check_deps_preview() {
    printf '============================================================\n'
    printf '  依赖工具预检 & 自动安装\n'
    # ★ 分隔线以 '-' 开头，不能写成 printf '----\n'：bash 会把 '-…' 当选项，
    #   报 "printf: --: invalid option"。必须走 %s 传参（test.sh 用的是 echo，没这坑）。
    printf '%s\n' '------------------------------------------------------------'

    local -A pkg_map
    pkg_map["lspci"]="pciutils"
    pkg_map["ipmitool"]="ipmitool"
    pkg_map["smartctl"]="smartmontools"
    pkg_map["dmidecode"]="dmidecode"
    pkg_map["dmesg"]="util-linux"
    pkg_map["findmnt"]="util-linux"
    pkg_map["lsblk"]="util-linux"

    # 不能自动装、只能人工装的（装了它等于要装 NVIDIA 驱动）
    local skip_auto=("nvidia-smi")
    local deps=("lspci" "findmnt" "lsblk" "ipmitool" "smartctl" "dmidecode" "dmesg" "nvidia-smi")
    local missing=() to_install=()
    local dep

    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 && continue
        missing+=("$dep")
        if [[ ! " ${skip_auto[*]} " =~ " ${dep} " ]]; then
            # 去重：findmnt / lsblk / dmesg 都归 util-linux，不去重会重复装三遍
            local p="${pkg_map[$dep]}"
            if [[ ! " ${to_install[*]} " =~ " ${p} " ]]; then
                to_install+=("$p")
            fi
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        printf '  [INFO] 所有核心依赖工具均已就绪\n'
        printf '============================================================\n\n'
        return 0
    fi

    printf '  [WARN] 以下工具未安装：\n'
    printf '        %s\n\n' "${missing[*]}"

    if [ "$LOG_AUTO_INSTALL" != "1" ]; then
        printf '  [INFO] 已关闭自动安装（LOG_AUTO_INSTALL=0）\n'
        if [ "${#to_install[@]}" -gt 0 ]; then
            printf '        请手动安装后重跑： sudo apt install -y %s\n' "${to_install[*]}"
        fi
        printf '============================================================\n\n'
        return 0
    fi

    local PKG_MGR=""
    if command -v apt >/dev/null 2>&1; then PKG_MGR="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum"
    fi

    if [ "${#to_install[@]}" -gt 0 ] && [ -n "$PKG_MGR" ]; then
        printf '  [INFO] 检测到包管理器：%s，正在自动安装基础依赖...\n' "$PKG_MGR"
        printf '  待安装包：%s\n' "${to_install[*]}"
        if [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
            "$PKG_MGR" install -y epel-release >/dev/null 2>&1
        fi
        # 安装输出：stdout 丢掉、stderr 留下来 —— 装不上时要能看出原因（缺源 / 网络 / 依赖冲突）
        # 注意是「先 2>&1 再 >/dev/null」：让 stderr 进捕获、stdout 丢弃
        local inst_err=""
        if [ "$PKG_MGR" = "apt" ]; then
            # DEBIAN_FRONTEND=noninteractive：避免 tzdata / grub-pc 之类弹 debconf
            # 交互把整个验收会话挂住（-y 挡不住 debconf 的问答）
            DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
            inst_err="$(DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" 2>&1 >/dev/null)"
        else
            inst_err="$("$PKG_MGR" install -y "${to_install[@]}" 2>&1 >/dev/null)"
        fi
        INSTALLED_PKGS="${to_install[*]}"

        # 装完复查：只认「命令真的能用了」，不看安装命令的退出码
        local install_fail=()
        for dep in "${!pkg_map[@]}"; do
            command -v "$dep" >/dev/null 2>&1 || install_fail+=("$dep")
        done
        if [ "${#install_fail[@]}" -gt 0 ]; then
            printf '  [WARN] 以下工具自动安装失败，对应测试项将跳过：\n'
            printf '        %s\n' "${install_fail[*]}"
            if [ -n "$inst_err" ]; then
                printf '  [原因] 安装输出（末 5 行）：\n'
                printf '%s\n' "$inst_err" | tail -5 | sed 's/^/        /'
            fi
        else
            printf '  [INFO] 所有基础依赖均已安装完成\n'
        fi
    else
        printf '  [INFO] 无可自动安装的基础依赖包，对应测试项将自动跳过\n'
    fi

    if [[ " ${missing[*]} " =~ " nvidia-smi " ]]; then
        printf '\n  [INFO] nvidia-smi 需手动安装 NVIDIA 显卡驱动，GPU 相关测试项将跳过\n'
    fi

    printf '============================================================\n\n'
    return 0
}

check_deps_preview

# ---- 尝试自动探测本机 SN（仅作默认值，回车即采用）----
# 优先 sysfs（免 root），再 dmidecode（需 root），过滤厂商占位值
_auto="$(cat /sys/class/dmi/id/product_serial 2>/dev/null)"
[ -z "$_auto" ] && _auto="$(dmidecode -s system-serial-number 2>/dev/null)"
_auto="$(printf '%s' "$_auto" | tr -d ' \r\n')"
case "$_auto" in
    ""|*"Not Specified"*|*"To be filled"*|*"Default string"*|*"System Serial Number"*|*"None"*)
        _auto=""
        ;;
esac

# ---- 交互输入 ----
if [ -n "$_auto" ]; then
    printf '请输入 SN（被测机序列号）[回车采用自动探测值 %s]：' "$_auto"
else
    printf '请输入 SN（被测机序列号）[本机探测不到，请手动输入]：'
fi
read -r SN
printf '请输入员工工号：'
read -r EMP

SN="$(printf '%s' "${SN:-}" | tr -d ' \r\n')"
EMP="$(printf '%s' "${EMP:-}" | tr -d ' \r\n')"
[ -z "$SN" ] && SN="$_auto"

if [ -z "$SN" ]; then
    printf '错误：SN 不能为空，已退出。\n' >&2
    exit 1
fi
if [ -z "$EMP" ]; then
    EMP="未填写"
fi

LOG="$DIR/${SN}-test-log/${SN}.log"

# ---- 产物目录（台账 + 采集 + 报告，全在这一个目录里）----
SDIR="$DIR/${SN}-test-log"
DMESG_FULL="$SDIR/dmesg.full.log"     # 内核原始全量
DMESG_BOOT="$SDIR/dmesg.boot.log"     # 会话前内核日志全量留存（-W 只跟随新消息，历史靠这份）
SEL_RAW="$SDIR/sel.raw.log"           # SEL 基线 + 收尾（分隔线隔开）
REPORT="$SDIR/report.txt"             # 结论（含命中明细）

mkdir -p "$SDIR" 2>/dev/null || { printf '错误：无法创建产物目录 %s\n' "$SDIR" >&2; exit 1; }

# ---- 并发锁：同一个 SN 同时只允许一个记录会话 ----
#   两个终端同时跑同一 SN，会让两个 tee 交错写同一台账，产物不可读。
#   用 flock 排他锁直接拒绝后到的那个。
if command -v flock >/dev/null 2>&1; then
    if exec 9>"$SDIR/.session.lock" 2>/dev/null; then
        if ! flock -n 9 2>/dev/null; then
            printf '错误：SN %s 已有会话正在记录中，已退出（未创建任何产物）。\n' "$SN" >&2
            printf '      请先结束另一个会话，或换一个 SN。\n' >&2
            exit 1
        fi
    fi
else
    printf '[提示] 未找到 flock，跳过并发保护 —— 请勿对同一 SN 并行记录。\n'
fi

# 会话外单独跑的脚本（不计入 tip / 汇总表的「未执行」统计）
OUTSIDE="${OUTSIDE-lhtest.sh fieldiag}"

# 传给「记录子 shell」（rcfile 里要用）
export ACCEPT_DIR="$DIR"
export ACCEPT_SN="$SN"
export ACCEPT_LOG="$LOG"
export OUTSIDE

# ---- 采集状态 ----
DMESG_PID=""
DMESG_BASE_N=0         # 追加前 dmesg.full.log 已有行数（采集文件是追加的，巡检只覆盖本次新增）
KMSG_CLEARED="no"      # 跟随段是否纯净（会话前历史已单独留存、不会混入）；决定巡检要不要打「可能含历史」
# 以下状态位只用于「报告里把『没采到』说清楚是哪一种」，不参与判定逻辑
DMESG_CMD="no"         # 是否找到 dmesg 命令（no = util-linux 没装 / PATH 里没有）
DMESG_OK="no"          # dmesg 是否可用（能成功读出会话前全量即视为有读取权限）
DMESG_FOLLOW="no"      # dmesg 跟随进程（-W，退化时 -w）是否成功启动
SEL_CMD="no"           # 是否找到 ipmitool 命令
SEL_BASE_OK="no"       # 会话开始时的 SEL 读取是否成功（区分「读取失败」与「本就为空」）
SEL_OK="no"            # 会话结束时的 SEL 读取是否成功（同上）

# ---- 会话窗口（只用于报告里标注本次会话的起止与时长）----
SESSION_START=""         # 会话开始时刻（墙钟，与会话头显示的是同一个值）
SESSION_START_EPOCH=""   # 会话开始时刻（epoch 秒，用来算时长）

# =====================================================================
# 判定表（内联，不依赖任何外部文件）
# 与 lhtest.sh 里的同源：**改一处必须改两处**。
# 不从外部脚本提取的原因：判定表在本脚本内自持，避免运行时依赖。
# =====================================================================

# ---- 判定阈值 ----
# CPU/部件温度判 FAIL 的阈值(℃)：内核日志里温度读数超过该值即判不合格
: "${CPU_TEMP_FAIL:=95}"

# ===== BEGIN 共享判定表-DMESG（须与 lhtest.sh 完全一致，改一处必须改两处）=====
# 忽略表：平台/固件已知无害噪音，不参与报错判定（ERE 正则）
#   后 8 条为 2026-09-30 新增：内核启动 / 正常协商类固定行 —— 短词子串误命中
#   就出在这些行上（"preset" 含 "reset"、"SECCOMP" 含 "ECC"、
#   "default" 含 "fault"、启动行 "MCE: CPU supports ... banks" 撞 "MCE:"）。
#   ★ 2026-09-30 再修订：本表是「整行删除」，过宽的项会把真实报错一并删掉，故收窄：
#     · 删掉 "systemd-udevd|udevd\[" —— 设备热插拔失败的报错常带 udevd[ 前缀，不能删
#     · "ACPI (BIOS )?Error" → "ACPI BIOS Error \(bug\)" —— 只忽略固件表 bug，真 ACPI 错误不忽略
#     · "hpet" → "^hpet[0-9]*:" —— 短词改行首锚定，避免误删含 hpet 的其它行
dmesg_ignore=(
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
dmesg_fatal_keys=(
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
dmesg_fatal_reasons=(
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
dmesg_warn_keys=(
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
dmesg_warn_reasons=(
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

# ===== BEGIN 共享判定表-SEL（须与 lhtest.sh 完全一致，改一处必须改两处）=====
# 白名单：非硬件故障的记录（仅「日志清空」「时间同步」这类语义唯一的事件）
#   ★ 2026-09-30 修订一：原表把 "State Asserted/Deasserted"、"Presence detected/deasserted"
#     也当白名单 —— 而 ipmitool 对「离散传感器事件」的标准描述正是 "State Asserted"，
#     即「它翻译不出具体含义」时才这么写。含义未知的记录最不该被静默忽略。
#   ★ 2026-09-30 修订二："Event Logging Disabled" 也移出白名单 —— 它可能是
#     「BMC 日志被人为/误关」的信号，静默跳过会掩盖问题，改为 WARN 提示人工确认。
#   以上 5 项全部下沉到下面的 WARN 表。
sel_whitelist=(
    "Log area reset"
    "Timestamp Clock Sync"
)

# ---- FAIL 级：只放"确定性故障"关键字，命中即判不合格 ----
# 原表把 Correctable / Fan / Temperature / Voltage / PCIe / ECC / Timeout 等
# "事件主题词"也放进 FAIL 表，导致一条可纠正 ECC 或风扇调速记录就整机判不合格。
# 这些描述性词一律下沉到下面的 WARN 表。
sel_fatal_keys=(
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
sel_fatal_reasons=(
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
sel_warn_keys=(
    "Correctable" "Non-critical" "Degraded" "SEL Full" "Log Full"
    "Configuration Error" "Timeout" "Failure" "Fault"
    "ECC" "Voltage" "Fan" "Temperature" "PCIe" "PCI Express"
    "Watchdog" "Bus Error" "Firmware"
    "State Asserted|State Deasserted|Presence detected|Presence deasserted"
    "Event Logging Disabled"
)
sel_warn_reasons=(
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

# =====================================================================
# 安全行数统计（文件不存在时返回 0，避免 "< file" 重定向报错）
# =====================================================================
__count_lines() {
    if [ -f "$1" ]; then
        wc -l < "$1" | tr -d ' '
    else
        printf '0'
    fi
}

# =====================================================================
# BMC SEL 快照（elist 带时间戳；部分 BMC 不支持则退回 list）
# =====================================================================
# 返回码：0 = 读取成功且有内容；2 = 读取成功但确无内容；1 = 读取失败 / 无 ipmitool
__sel_append() {
    # 往 sel.raw.log 追加一段快照（elist 带时间戳；部分 BMC 不支持则退回 list）
    local tag="$1" before after rc_elist=0 rc_list=0
    printf '\n===== %s %s =====\n' "$tag" "$(date '+%F %T')" >> "$SEL_RAW"
    command -v ipmitool >/dev/null 2>&1 || return 1
    before="$(__count_lines "$SEL_RAW")"
    ipmitool sel elist >> "$SEL_RAW" 2>/dev/null || rc_elist=$?
    after="$(__count_lines "$SEL_RAW")"
    if [ "$after" -le "$before" ]; then
        ipmitool sel list >> "$SEL_RAW" 2>/dev/null || rc_list=$?
    fi
    after="$(__count_lines "$SEL_RAW")"
    # 有内容产出 —— 读取成功
    [ "$after" -gt "$before" ] && return 0
    # 没内容产出：两条命令都非 0 = 读取失败；否则视为「读取成功，确为空」
    if [ "$rc_elist" -ne 0 ] && [ "$rc_list" -ne 0 ]; then
        return 1
    fi
    return 2
}

# =====================================================================
# 采集启动
# =====================================================================
__start_capture() {
    # ★ 采集文件一律「追加」，与台账 <SN>.log 保持一致 —— 同一 SN 重复记录不覆盖。
    #   先确保文件存在（工具不可用时后续巡检也不会因文件缺失报错），
    #   再记下追加前的行数，巡检只覆盖「本次会话」新增的部分。
    [ -f "$DMESG_FULL" ] || : > "$DMESG_FULL"
    [ -f "$SEL_RAW" ]    || : > "$SEL_RAW"
    DMESG_BASE_N="$(__count_lines "$DMESG_FULL")"

    # ---- 1) 内核日志：先留存全量 → 再只跟随新消息 ----
    #   ★ 2026-09-30 修订（原方案 = dmesg -C 清空 + dmesg -w 跟随，有两个硬伤）：
    #     · dmesg -C 会把会话前的内核日志**永久清掉** —— 开机自检、启动期 AER/ECC
    #       报错全丢，验收若要求保留完整内核日志就站不住；
    #     · -C 与 -w 之间存在竞态窗口，窗口内的消息会漏。
    #   改为：先 dmesg 全量留存到 dmesg.boot.log，再用 dmesg -W（--follow-new）
    #   只跟随新消息 —— 启动日志保住了，不用清空缓冲，也没有竞态。
    if command -v dmesg >/dev/null 2>&1; then
        DMESG_CMD="yes"
        # 1a) 全量留存会话前的历史
        if dmesg > "$DMESG_BOOT" 2>/dev/null; then
            DMESG_OK="yes"
            KMSG_CLEARED="yes"      # 语义：跟随段是纯净的（历史已单独留存，不会混进来）
            printf '[采集] 会话前内核日志已留存 -> %s（%s 行）\n' "$DMESG_BOOT" "$(__count_lines "$DMESG_BOOT")"
        else
            DMESG_OK="no"
            KMSG_CLEARED="no"
            printf '[采集][WARN] dmesg 读取失败（即便 root 也无权限：容器 / capability 受限？）。\n'
            printf '             本次无内核日志可用，巡检结论需人工甄别。\n'
        fi
        # 1b) 只跟随新消息：dmesg -W（--follow-new，util-linux 2.30+）
        dmesg -W >> "$DMESG_FULL" 2>/dev/null &
        DMESG_PID=$!
        sleep 0.2                                   # 给进程一点启动时间，便于下面验活
        if [ -n "$DMESG_PID" ] && kill -0 "$DMESG_PID" 2>/dev/null; then
            DMESG_FOLLOW="yes"
            printf '[采集] 内核日志全程跟随已启动（dmesg -W --follow-new，PID %s）-> %s\n' "$DMESG_PID" "$DMESG_FULL"
        else
            # -W 不被支持 → 退化为 -w（会把缓冲里的历史一起打出来，报告里会标注）
            dmesg -w >> "$DMESG_FULL" 2>/dev/null &
            DMESG_PID=$!
            sleep 0.2
            if [ -n "$DMESG_PID" ] && kill -0 "$DMESG_PID" 2>/dev/null; then
                DMESG_FOLLOW="yes"
                KMSG_CLEARED="no"
                printf '[采集][注意] 本机 dmesg 不支持 -W，已退化为 -w —— 跟随段可能含会话前历史。\n'
                printf '           如需纯净段，请升级 util-linux 到 2.30+。\n'
            else
                DMESG_FOLLOW="no"
                DMESG_PID=""
                printf '[采集][WARN] dmesg 跟随进程启动失败或已退出，本次无内核日志。\n'
            fi
        fi
    else
        DMESG_CMD="no"
        printf '[采集][WARN] 未找到 dmesg，跳过内核日志采集。\n'
    fi

    # ---- 2) BMC SEL 基线快照 ----
    if command -v ipmitool >/dev/null 2>&1; then
        SEL_CMD="yes"
        __sel_append "会话开始"
        case "$?" in
            0|2) SEL_BASE_OK="yes" ;;   # 读到内容 或 读取成功确为空，都算「读到了」
            *)   SEL_BASE_OK="no"  ;;   # 读取失败（无权限 / BMC 不支持）
        esac
        case "$SEL_BASE_OK" in
            yes) printf '[采集] BMC SEL 基线已留存 -> %s\n' "$SEL_RAW" ;;
            *)   printf '[采集][WARN] BMC SEL 基线读取失败（无权限 / BMC 不支持），本次无法对比新增。\n' ;;
        esac
    else
        SEL_CMD="no"
        printf '[采集][WARN] 未找到 ipmitool，跳过 SEL 采集。\n'
    fi
}

# =====================================================================
# 采集停止
# =====================================================================
__stop_capture() {
    if [ -n "$DMESG_PID" ]; then
        kill "$DMESG_PID" 2>/dev/null
        wait "$DMESG_PID" 2>/dev/null
        DMESG_PID=""
        printf '[采集] 内核日志跟随已停止（%s 行）\n' "$(__count_lines "$DMESG_FULL")"
    fi
    if command -v ipmitool >/dev/null 2>&1; then
        __sel_append "会话结束"
        case "$?" in
            0|2) SEL_OK="yes" ;;        # 读到内容 或 读取成功确为空
            *)   SEL_OK="no"  ;;        # 读取失败
        esac
        case "$SEL_OK" in
            yes) printf '[采集] BMC SEL 收尾快照已留存（文件累计 %s 行）\n' "$(__count_lines "$SEL_RAW")" ;;
            *)   printf '[采集][WARN] BMC SEL 收尾读取失败，本次新增告警无法判定。\n' ;;
        esac
    fi
}

# =====================================================================
# 会话级巡检（读 dmesg -W 产物 + SEL 基线/收尾对比）
# 注意：与各测试脚本自身的巡检相互独立，结论仅供参考。
# =====================================================================
__inspect() {
    local tmp="$SDIR/.report.tmp"
    local dl=0 dl_new=0 k_fatal=0 k_warn=0 s_fatal=0 s_warn=0 s_new=0
    local s_base_n=0 s_final_n=0
    local line reason i ig filt
    local hits_k="$SDIR/.hits.k" hits_s="$SDIR/.hits.s"
    local bf="$SDIR/.sel.base" ff="$SDIR/.sel.final" snew="$SDIR/.sel.new"

    # ---------- 3.1 内核日志 ----------
    : > "$hits_k"
    dl="$(__count_lines "$DMESG_FULL")"
    dl_new=$(( dl - ${DMESG_BASE_N:-0} ))
    [ "$dl_new" -lt 0 ] && dl_new=0

    if [ "${#dmesg_ignore[@]}" -gt 0 ] && [ "$dl_new" -gt 0 ]; then
        filt="$SDIR/.dmesg.filt"
        # 采集文件是追加的：只取本次会话新增的行，避免把历史会话的记录重复巡检
        tail -n "+$(( ${DMESG_BASE_N:-0} + 1 ))" "$DMESG_FULL" > "$filt" 2>/dev/null
        for ig in "${dmesg_ignore[@]}"; do
            grep -viE "$ig" "$filt" > "$filt.t" 2>/dev/null || true
            mv -f "$filt.t" "$filt"
        done
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            reason=""
            # CPU 高温数值判定：行内含温度语义、且温度读数 > CPU_TEMP_FAIL(默认95℃) 时直接判 FAIL
            # （dmesg 里带数值的典型行：thermal_zone0: critical temperature reached (105 C)）
            # ★ 命中后不再走下面的 fatal 表（用 else 分支），否则 reason 会被 fatal 表覆盖，
            #   报告里显示的就不是「温度超限」这条理由了。
            if printf '%s' "$line" | grep -qiE 'cpu|package|core|processor|thermal|temperature|overheat' \
               && printf '%s' "$line" \
                    | grep -oE '[0-9]{2,3} *(C|℃)|[0-9]{2,3} *degrees? *C|(temp|temperature)[=: ]+[0-9]{2,3}' \
                    | grep -oE '[0-9]+' \
                    | awk -v th="${CPU_TEMP_FAIL}" '($1+0)>th{f=1} END{exit !f}'; then
                reason="【严重】CPU/部件温度超过 ${CPU_TEMP_FAIL}℃，散热异常"
                k_fatal=1
            else
                for i in "${!dmesg_fatal_keys[@]}"; do
                    if printf '%s' "$line" | grep -qiE "${dmesg_fatal_keys[$i]}"; then
                        reason="${dmesg_fatal_reasons[$i]}"
                        k_fatal=1
                        break
                    fi
                done
            fi
            if [ -n "$reason" ]; then
                printf '%s  # 【FAIL】%s\n' "$line" "$reason" >> "$hits_k"
                continue
            fi
            for i in "${!dmesg_warn_keys[@]}"; do
                if printf '%s' "$line" | grep -qiE "${dmesg_warn_keys[$i]}"; then
                    reason="${dmesg_warn_reasons[$i]}"
                    k_warn=1
                    break
                fi
            done
            if [ -n "$reason" ]; then
                printf '%s  # 【WARN】%s\n' "$line" "$reason" >> "$hits_k"
            fi
        done < "$filt"
        rm -f "$filt" "$filt.t"
    fi

    # ---------- 3.2 BMC SEL（从 sel.raw.log 切出基线与收尾，只报新增）----------
    : > "$hits_s"
    # sel.raw.log 里两段以「===== 会话开始/结束 <时间> =====」分隔。
    # 文件是追加的（同一 SN 可能记录多次），只取**最后一次**会话的段：
    #   遇「会话开始/结束」就重置缓冲，END 时输出的即最后一段。
    awk '/^===== 会话开始/{buf=""; f=1; next} /^===== 会话结束/{f=0} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$SEL_RAW" > "$bf" 2>/dev/null
    awk '/^===== 会话结束/{buf=""; f=1; next} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$SEL_RAW" > "$ff" 2>/dev/null
    # 计数时排除空行：sel.raw.log 两段之间会带一个空行，直接 wc -l 会多算一条
    s_base_n="$(sed '/^[[:space:]]*$/d' "$bf" 2>/dev/null | wc -l | tr -d ' ')"
    s_final_n="$(sed '/^[[:space:]]*$/d' "$ff" 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$s_final_n" -gt 0 ]; then
        local bn="$SDIR/.sel.b.n" fn="$SDIR/.sel.f.n"
        # 去掉行首序号后比对，避免 SEL 重建后序号变化被误判为「全部新增」
        # LC_ALL=C：comm 对输入排序有强要求（实测未排序会报 "not in sorted order" 并
        # 静默输出空），且它按字节序比较 —— 必须让 sort 与 comm 用同一套排序规则。
        sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*|//' "$bf" 2>/dev/null | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$bn"
        sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*|//' "$ff" 2>/dev/null | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$fn"
        LC_ALL=C comm -13 "$bn" "$fn" > "$snew" 2>/dev/null || true
        rm -f "$bn" "$fn"
        s_new="$(__count_lines "$snew")"

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local is_white=0 line_lc
            line_lc="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
            for w in "${sel_whitelist[@]}"; do
                if [[ "$line_lc" == *"${w,,}"* ]]; then
                    is_white=1
                    break
                fi
            done
            if [ "$is_white" -eq 1 ]; then
                printf '%s  # 非硬件故障记录（日志清空/时间同步/在位状态），不计入失败\n' "$line" >> "$hits_s"
                continue
            fi
            reason=""
            for i in "${!sel_fatal_keys[@]}"; do
                if printf '%s' "$line" | grep -qiE "${sel_fatal_keys[$i]}"; then
                    reason="${sel_fatal_reasons[$i]}"
                    break
                fi
            done
            if [ -n "$reason" ]; then
                printf '%s  # 【FAIL】%s\n' "$line" "$reason" >> "$hits_s"
                s_fatal=$((s_fatal + 1))
                continue
            fi
            for i in "${!sel_warn_keys[@]}"; do
                if printf '%s' "$line" | grep -qiE "${sel_warn_keys[$i]}"; then
                    reason="${sel_warn_reasons[$i]}"
                    break
                fi
            done
            if [ -n "$reason" ]; then
                printf '%s  # 【WARN】%s\n' "$line" "$reason" >> "$hits_s"
                s_warn=$((s_warn + 1))
            fi
        done < "$snew"
    fi

    # ---------- 会话窗口与时长（报告用；纯展示，不参与判定）----------
    local sess_end sess_dur now_s d h m
    sess_end="$(date '+%F %T')"
    now_s="$(date '+%s')"
    if [ -n "$SESSION_START_EPOCH" ]; then
        d=$(( now_s - SESSION_START_EPOCH ))
        [ "$d" -lt 0 ] && d=0
        if [ "$d" -lt 60 ]; then
            sess_dur="${d} 秒"
        elif [ "$d" -lt 3600 ]; then
            sess_dur="$((d / 60)) 分 $((d % 60)) 秒"
        else
            h=$(( d / 3600 )); m=$(( (d % 3600) / 60 ))
            sess_dur="${h} 小时 ${m} 分"
        fi
    else
        sess_dur="未知"
    fi

    # ---------- 生成报告（命中明细直接内嵌，不再另开 hits 文件）----------
    {
        printf '%s\n' '==================== 会话级日志巡检 ===================='
        printf 'SN       : %s\n' "$SN"
        printf '会话窗口 : %s → %s（%s）\n' "${SESSION_START:-未记录}" "$sess_end" "$sess_dur"
        printf '巡检时刻 : %s\n' "$(date '+%F %T')"
        printf '产物目录 : %s\n' "$SDIR"
        printf '判定表   : 内联（与 lhtest.sh 同源，改一处必须改两处）\n'
        if [ -n "${INSTALLED_PKGS:-}" ]; then
            printf '自动安装 : %s（本次会话改动过被测机，请确认是否符合验收要求）\n' "$INSTALLED_PKGS"
        else
            printf '自动安装 : 无（本次会话未改动被测机）\n'
        fi
        printf '%s\n' '--------------------------------------------------------'
        printf '【3.1 内核日志巡检】\n'
        printf '  本次新增 : %s 行（文件累计 %s 行） -> %s\n' "$dl_new" "$dl" "$DMESG_FULL"
        printf '  会话前   : %s（%s 行）\n' "$DMESG_BOOT" "$(__count_lines "$DMESG_BOOT")"
        if [ "$dl_new" -gt 0 ] && [ "$KMSG_CLEARED" != "yes" ]; then
            printf '  [注意] 跟随段可能含会话前的历史记录（dmesg 读取失败，或不支持 -W 已退化为 -w）。\n'
        fi
        if [ "$dl_new" -eq 0 ]; then
            if [ "$DMESG_CMD" != "yes" ]; then
                printf '  [无数据] 未找到 dmesg 命令（util-linux 未安装，或 PATH 里没有）。\n'
            elif [ "$DMESG_OK" != "yes" ]; then
                printf '  [无数据] dmesg 读取被拒 —— 以 root 仍无权限（容器 / capability 受限？）。\n'
            elif [ "$DMESG_FOLLOW" != "yes" ]; then
                printf '  [无数据] dmesg 跟随进程（-W，退化时 -w）未启动成功（本次无内核日志）。\n'
            else
                printf '  [无数据] 会话期间内核未产生新日志（会话前历史已单独留存，全程只跟随新消息）。\n'
            fi
        elif [ "$k_fatal" -eq 1 ]; then
            printf '  [FAIL] 检测到内核硬件级关键报错，命中如下：\n'
            sed 's/^/    /' "$hits_k"
        elif [ "$k_warn" -eq 1 ]; then
            printf '  [WARN] 检测到软性/可恢复告警（不判失败），命中如下：\n'
            sed 's/^/    /' "$hits_k"
        else
            printf '  [PASS] 未检测到内核硬件级关键报错\n'
        fi
        printf '%s\n' '--------------------------------------------------------'
        printf '【3.2 BMC SEL 巡检】\n'
        printf '  基线 %s 条 -> 收尾 %s 条，新增 %s 条\n' "$s_base_n" "$s_final_n" "$s_new"
        printf '  原始快照 : %s\n' "$SEL_RAW"
        if [ "$s_base_n" -eq 0 ] && [ "$s_final_n" -gt 0 ]; then
            if [ "$SEL_BASE_OK" != "yes" ]; then
                printf '  [注意] 基线为空（会话开始时 SEL 读取失败），上表「新增」实为全量。\n'
            else
                printf '  [注意] 基线为空（会话开始时 SEL 本就无记录），上表「新增」实为全量。\n'
            fi
        fi
        if [ "$s_final_n" -eq 0 ]; then
            if [ "$SEL_CMD" != "yes" ]; then
                printf '  [无数据] 未找到 ipmitool 命令（未安装 IPMI 工具）。\n'
            elif [ "$SEL_OK" != "yes" ]; then
                printf '  [无数据] SEL 读取失败 —— 无权限 / BMC 不支持 IPMI（虚拟机通常无 BMC，属正常）。\n'
            else
                printf '  [无数据] 会话期间 BMC SEL 无记录（读取成功，确为空）。\n'
            fi
        elif [ "$s_fatal" -gt 0 ]; then
            printf '  [FAIL] 本次新增 %s 条 BMC 硬件故障记录（另 %s 条需关注），命中如下：\n' "$s_fatal" "$s_warn"
            sed 's/^/    /' "$hits_s"
        elif [ "$s_warn" -gt 0 ]; then
            printf '  [WARN] 本次新增 %s 条需关注的 BMC 事件（未达故障级），命中如下：\n' "$s_warn"
            sed 's/^/    /' "$hits_s"
        else
            printf '  [PASS] 本次会话未新增 BMC 硬件关键告警\n'
        fi
        printf '%s\n' '--------------------------------------------------------'
        printf '注 1：本巡检覆盖「整个会话期间」，与各测试脚本自身的巡检相互独立。\n'
        printf '注 2：最终判定以各测试脚本自身的巡检结果为准，本报告仅供参考。\n'
        printf '%s\n' '========================================================'
    } > "$tmp" 2>&1

    cat "$tmp"
    # 报告同样「追加」，与台账 / 采集保持一致；用会话分隔行区分多次记录
    {
        printf '\n\n########## 会话报告 %s ##########\n' "$(date '+%F %T')"
        cat "$tmp"
    } >> "$REPORT" 2>/dev/null
    rm -f "$tmp" "$hits_k" "$hits_s" "$bf" "$ff" "$snew"
}

# ---- 退出清理（含 Ctrl-C 中断时兜底 kill 采集进程）----
__cleanup() {
    if [ -n "${DMESG_PID:-}" ]; then
        kill "$DMESG_PID" 2>/dev/null
    fi
    rm -f "$RC" 2>/dev/null
    rm -f "$SDIR"/.dmesg.filt* "$SDIR"/.hits.k "$SDIR"/.hits.s "$SDIR"/.sel.* "$SDIR"/.report.tmp 2>/dev/null
    rm -f "${FIFO:-}" 2>/dev/null
}

# ---- 生成临时 rcfile：给「记录子 shell」注入 tip / 命令回显 / 退出命令 ----
RC="$(mktemp)" || { printf '错误：无法创建临时文件。\n' >&2; exit 1; }
trap '__cleanup' EXIT
cat > "$RC" <<'RCEOF'
# 载入你原有的 shell 环境（别名 / PATH / 提示符等）
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"

# =====================================================================
# 以下由 log.sh 注入
# =====================================================================

# ---- 关闭历史过滤（★ 2026-09-30 新增）----
# Ubuntu 默认 HISTCONTROL=ignoreboth（= ignorespace:ignoredups），会让「以空格开头的命令」
# 和「与上一条完全重复的命令」不进 history。而 __echo_cmd 是靠 history 行号取命令原文的，
# 只要有一条没进历史，行号就不动 —— 上一条被重复回显、真命令漏记、还会误报「跳变」。
# 这里只在本记录会话（子进程）内清空过滤规则，退出即恢复，不影响你平时终端的习惯。
# ★ 必须写在 source ~/.bashrc 之后，否则会被 .bashrc 里的设置覆盖回去。
HISTCONTROL=""
HISTIGNORE=""

# ---- 已执行脚本登记（本次会话，内存态）：脚本名 -> 退出码 ----
declare -A __EXECUTED=()

__mark_executed() {
    local cmd="$1" rc="${2:-}"
    local w="${cmd%% *}" rest="" guard=0       # 取命令的第一个词
    # 循环剥离常见前缀，直到第一个词不是前缀为止。
    # 只剥一层会漏掉 "sudo bash ./smart.sh" 这类多层包装，导致 tip 误报「未执行」。
    while [ "$guard" -lt 8 ]; do
        case "$w" in
            sudo|bash|sh|env|command|nohup|time|nice|setsid)
                rest="${cmd#* }"
                [ "$rest" = "$cmd" ] && break  # 已无更多参数，防死循环
                cmd="$rest"; w="${cmd%% *}"
                guard=$((guard + 1))
                ;;
            *) break ;;
        esac
    done
    case "$w" in
        *.sh) __EXECUTED["${w##*/}"]="$rc" ;;  # 只认「第一个词就是脚本」的调用
    esac
}

# ---- 扫描本目录：把脚本分成「已执行 / 未执行」两组 ----
# 结果写入全局 __DONE / __PEND / __TOTAL
# OUTSIDE 里列出的脚本（会话外单独跑）不参与统计，避免 tip 误报「未执行」
__scan() {
    __DONE=(); __PEND=(); __TOTAL=0
    local f b
    for f in "$ACCEPT_DIR"/*.sh; do
        [ -e "$f" ] || continue
        b="${f##*/}"
        [ "$b" = "log.sh" ] && continue        # 控制器自己不算
        case " ${OUTSIDE:-} " in
            *" $b "*) continue ;;              # 会话外单独跑的脚本，不计入
        esac
        __TOTAL=$((__TOTAL + 1))
        if [ -n "${__EXECUTED[$b]+x}" ]; then
            __DONE+=("$b")
        else
            __PEND+=("$b")
        fi
    done
}

# ---- tip：显示执行进度（已执行的带退出码）----
tip() {
    local b rc
    __scan
    printf '\n===== 脚本执行进度 =====\n'
    printf '已执行 %d / %d\n' "${#__DONE[@]}" "$__TOTAL"
    for b in "${__DONE[@]}"; do
        rc="${__EXECUTED[$b]}"
        if [ "$rc" = "0" ]; then
            printf '  ✓ %-24s rc=%s\n' "$b" "$rc"
        else
            printf '  ✗ %-24s rc=%s\n' "$b" "$rc"
        fi
    done
    if [ "${#__PEND[@]}" -eq 0 ]; then
        printf '全部脚本都已执行过 ✓\n'
    else
        printf '尚未执行（%d 个）：\n' "${#__PEND[@]}"
        printf '  · %s\n' "${__PEND[@]}"
    fi
    if [ -n "${OUTSIDE:-}" ]; then
        printf '（会话外单独跑，不计入：%s）\n' "$OUTSIDE"
    fi
    printf '========================\n\n'
}

# ---- 会话结束时的执行汇总表（由 EXIT trap 触发）----
__summary() {
    local b rc
    __scan
    printf '\n===== 本次会话执行汇总 =====\n'
    printf 'SN   : %s\n' "${ACCEPT_SN:-}"
    printf '日志 : %s\n' "${ACCEPT_LOG:-}"
    printf '%s\n' '--------------------------------------------------'
    printf '执行 %d / %d\n' "${#__DONE[@]}" "$__TOTAL"
    if [ "${#__DONE[@]}" -gt 0 ]; then
        for b in "${__DONE[@]}"; do
            rc="${__EXECUTED[$b]}"
            if [ "$rc" = "0" ]; then
                printf '  ✓ %-24s rc=%s\n' "$b" "$rc"
            else
                printf '  ✗ %-24s rc=%s\n' "$b" "$rc"
            fi
        done
    else
        printf '  （本次未执行任何脚本）\n'
    fi
    if [ "${#__PEND[@]}" -gt 0 ]; then
        printf '%s\n' '--------------------------------------------------'
        printf '未执行（%d 个）：\n' "${#__PEND[@]}"
        printf '  · %s\n' "${__PEND[@]}"
    fi
    if [ -n "${OUTSIDE:-}" ]; then
        printf '%s\n' '--------------------------------------------------'
        printf '会话外单独跑（不计入上表）：%s\n' "$OUTSIDE"
    fi
    printf '%s\n' '--------------------------------------------------'
    printf '注：rc 仅供记录，部分脚本（如 smart.sh / pcie.sh）由人工看输出判定，勿以 rc 为准。\n'
    printf '==================================================\n'
}

# ---- 命令回显：每条命令执行后，把「时间 + 退出码 + 命令」写进日志 ----
# 全记录模式下 stdout 已接到 tee，所以这里的 printf 会自动落盘 + 上屏。
# ★ 2026-09-30 修订：原判据 [ "$no" -ne $(( __LAST_HISTNO + 1 )) ] 把「行号没变」和
#   「行号真跳变」混成了一种情况。而 PROMPT_COMMAND 是「显示提示符之前」跑的 —— 空回车
#   （什么都不执行、也不进 history）同样会触发一次，此时 history 1 返回的还是上一条，
#   于是既重复回显了上一条命令、又误报「309→309 跳变」，还会用 rc=0 覆盖上一条命令的
#   真实退出码（汇总表里 ✗ 被刷成 ✓）。现拆成三段：① 首次只记基线；② 行号没变静默返回；
#   ③ 只有真跳变（> +1）才告警。
__echo_cmd() {
    local rc=$?
    local raw no c
    raw="$(HISTTIMEFORMAT= history 1)"
    raw="${raw#"${raw%%[![:space:]]*}"}"      # 去掉前导空白
    no="${raw%%[[:space:]]*}"                 # 第一段 = history 行号
    case "$no" in ''|*[!0-9]*) no=0 ;; esac   # 非数字（history 为空 / 格式异常）置 0
    c="${raw#*[[:space:]]}"                   # 余下 = 命令原文
    c="${c#"${c%%[![:space:]]*}"}"            # 去掉前导空白

    # ① 首次触发（会话刚起来，还没有任何用户输入）：此时 history 里只有 ~/.bash_history
    #    带进来的旧命令，不是本次会话执行的 —— 只记基线，不回显、不登记。
    if [ -z "${__ECHO_READY:-}" ]; then
        __ECHO_READY=1
        __LAST_HISTNO="$no"
        return 0
    fi
    [ -n "$c" ] || return 0                   # 空命令不回显

    # ② 行号没变 = 这次回车没有产生新的历史条目（空回车；或 HISTCONTROL 过滤掉的行）。
    #    此时 history 1 返回的还是上一条，既不能重复回显、更不能报「跳变」，
    #    也不能拿它去覆盖上一条命令已经登记好的退出码。
    if [ "$no" -gt 0 ] && [ "$no" -eq "${__LAST_HISTNO:-0}" ]; then
        return 0
    fi

    __mark_executed "$c" "$rc"                # 顺手登记「这个脚本跑过了 + 它的退出码」
    # ③ 行号跳了不止 1，才说明中间确有命令没进历史，回显的命令可能错位
    #    （理论上已由上面的 HISTCONTROL="" 堵住，这里留作兜底）
    if [ "$no" -gt 0 ] && [ "$no" -gt $(( ${__LAST_HISTNO:-0} + 1 )) ]; then
        printf '\n[%s] rc=%d $ %s  # 历史序号 %s→%s 跳变，其间可能有未入历史的命令\n' \
               "$(date '+%T')" "$rc" "$c" "${__LAST_HISTNO:-0}" "$no"
    else
        printf '\n[%s] rc=%d $ %s\n' "$(date '+%T')" "$rc" "$c"
    fi
    __LAST_HISTNO="$no"
}
# ★ 追加，不覆盖用户原有的 PROMPT_COMMAND
#   bash 5.1+ 允许 PROMPT_COMMAND 是「数组」，字符串拼接会把数组压平、改变行为，
#   故先判断类型：是数组就按数组追加，否则按字符串追加。
if declare -p PROMPT_COMMAND 2>/dev/null | grep -q 'declare -a'; then
    PROMPT_COMMAND=(__echo_cmd "${PROMPT_COMMAND[@]}")
else
    PROMPT_COMMAND="__echo_cmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi

# ---- 结束记录：输入  test esc ----
# （test 是 bash 内建命令，这里用同名函数接管；非 esc 参数照常走内建 test）
test() {
    if [ "${1:-}" = "esc" ]; then
        printf '\n[记录已结束]\n'
        exit 0                          # 汇总表由下面的 EXIT trap 打
    fi
    builtin test "$@"
}

# 退出记录子 shell 时（test esc / exit / Ctrl-D 都算）自动打汇总表
trap '__summary' EXIT

# ---- 提示符加标记，一眼看出「正在记录」----
PS1='[验收记录] \u@\h:\w\$ '
RCEOF

# ---- 记下会话开始时刻（会话头与巡检报告共用同一个值）----
SESSION_START="$(date '+%F %T')"
SESSION_START_EPOCH="$(date '+%s')"

# ---- 打印会话头（同时上屏 + 落盘）----
{
    printf '%s\n' "============================================================"
    printf '验收会话开始 : %s\n' "$SESSION_START"
    printf 'SN           : %s\n' "$SN"
    printf '员工工号     : %s\n' "$EMP"
    printf '主机名       : %s\n' "$(hostname)"
    printf '产物目录     : %s\n' "$SDIR"
    printf '台账文件     : %s\n' "$LOG"
    printf '%s\n' "============================================================"
} | tee -a "$LOG"

printf '\n记录中 —— 此后本终端所有输出都会写入：\n  %s\n' "$LOG"
printf '结束记录：输入  test esc        查看进度：输入  tip\n\n'

# ---- 把本进程的输出接管到 tee，再启动记录子 shell ----
# 用「命名管道 + 显式 tee」而不是 "exec > >(tee ...)"：
#   进程替换拿不到 tee 的 PID，脚本退出时无法确认 tee 已把缓冲写完，尾部若干行可能丢。
#   FIFO 方式可以精确 wait，保证台账完整。
FIFO="$SDIR/.log.fifo"
TEE_PID=""
rm -f "$FIFO" 2>/dev/null
if mkfifo "$FIFO" 2>/dev/null; then
    tee -a "$LOG" < "$FIFO" &
    TEE_PID=$!
    exec 3<>"$FIFO"                    # 读写打开，避免 FIFO 的 open 阻塞
    exec >&3 2>&1
    exec 3>&-
else
    exec > >(tee -a "$LOG") 2>&1       # 退化：无 mkfifo 时仍可用，只是尾部不保证
fi

# ---- 启动会话级采集（内核日志 + SEL 基线）----
__start_capture

bash --rcfile "$RC" -i
RC_RC=$?

# ---- 停止采集并做会话级巡检 ----
__stop_capture
__inspect

# ---- 收尾（此时仍在记录，下面的内容也会进日志；临时文件由 trap 清理）----
printf '\n[记录已停止] %s\n' "$(date '+%F %T')"
printf '产物目录：%s\n' "$SDIR"
printf '  · 台账   : %s\n' "$LOG"
printf '  · 采集   : dmesg.full.log / sel.raw.log\n'
printf '  · 结论   : report.txt\n'

# 关闭 stdout/stderr 让 tee 收到 EOF，再等它写完，保证台账尾部不丢
exec 1>&- 2>&-
if [ -n "${TEE_PID:-}" ]; then
    wait "$TEE_PID" 2>/dev/null
fi
rm -f "$FIFO" 2>/dev/null
exit "$RC_RC"
