#!/bin/bash
# ============================================================
# 独立 FIO 磁盘顺序读写压力测试脚本（带跑前确认）
# 功能：自动挑选「能安全测试」的数据盘（排除系统盘 / 软驱 / 内存盘 / USB盘 / 远端盘；
#       逻辑卷与阵列取上层设备而不是成员盘），进行 128k 顺序写/读测试
#       支持通过命令行参数指定要测试的磁盘（例如：sudo bash fio.sh sda sdb nvme0n1）
# 警告：会覆盖待测试磁盘上的数据！请确保已备份！
# 用法：sudo bash fio.sh [运行时长(秒)] [磁盘列表...]
#       若不指定时长，默认 240 秒（可通过环境变量 FIO_RUN_TIME 覆盖）
#       若不指定磁盘列表，则自动测试所有非系统盘
# 示例：
#   sudo bash fio.sh 300          # 每个测试跑 300 秒，自动选盘
#   sudo bash fio.sh sda sdb      # 默认时长，只测试 sda 和 sdb
#   sudo bash fio.sh 180 nvme0n1  # 跑 180 秒，只测试 nvme0n1
#   sudo FIO_RUN_TIME=1800 bash fio.sh
# 输出：只输出到终端，不写日志文件、不留存 fio 原始输出（fio 结果在内存里解析）
# 返回码：0=全部通过，1=存在失败，2=未得出判定结论（Pending：没有可测的盘）
#
# ------------------------------------------------------------
# 修订记录（2026-09-11）：
#   1. 【主因】带宽正则只认 MB/s，而 fio 用的是 IEC 单位 MiB/s -> 永远显示"未知"。
#      改为 [KMGT]?i?B/s，并改为按键名取值（不再依赖 awk 字段位置）。
#   2. 【主因】IOPS 取的是 group 行的 $3，实际拿到的是括号里的 MB/s 数值。
#      group 汇总行里根本没有 IOPS，改从 per-job 行 "write: IOPS=..., BW=..." 取。
#   3. fio 退出码未检查：ioengine 不可用/参数错误时只显示"未知"，静默漏过。
#      现在非 0 退出码直接判定失败并打印 fio 输出尾部。
#   4. 测量结果没有写进日志文件（run_fio_test 里只有 echo，没有 tee）-> 已修。
#   5. 去掉 bash4 专有语法（${var^^} / readarray），兼容 bash 3.x 与 sh 调用。
#   6. libaio 不可用时自动回退 psync（并提示 IOPS 不可比）。
#   7. 补：目标盘有分区处于挂载状态时给出醒目警告。
#
# 修订记录（2026-09-22）：
#   8. 【主因】自动选盘只按 lsblk 的 TYPE=disk 过滤，实机上两头出错：
#      误纳入——fd0 软驱（TYPE 同样是 disk，虚拟机里已实测被选中并跑完）、zram 内存盘、
#              USB 装机启动盘、iSCSI / nbd / FC 远端盘；
#      漏测——  md* 软阵列、dm-* LVM/加密卷、multipath（TYPE 都不是 disk），
#              反倒把它们的成员盘选进来，一测就把阵列写坏。
#      现改为按类型分别收集物理盘与逻辑卷，逐条过滤（名字黑名单 / 总线类型 /
#      容量下限 / 系统盘与挂载保护链 / 是否被上层卷覆盖），并打印每块盘的排除原因。
#      新增环境变量 FIO_MIN_SIZE_GB（默认 1），低于该容量的设备一律不测。
# ============================================================

# -------- 配置 --------
: "${FIO_RUN_TIME:=240}"

# 自动选盘时的最小容量下限（GiB）：小于该值的设备一律不测。
# 这是兜底——软驱、SD 卡、各种虚拟小设备都靠它挡在门外。
: "${FIO_MIN_SIZE_GB:=1}"

# 解析第一个参数：如果是数字，则视为运行时长；否则视为磁盘名
if [ -n "$1" ] && [ "$1" -gt 0 ] 2>/dev/null; then
    FIO_RUN_TIME="$1"
    shift   # 移除时长参数，剩余的都是磁盘名
fi

# 此时 $@ 是剩余的参数，可能是磁盘列表，也可能是空

# ============================================================
# 验收标准（与《基础测试》《服务器整机验收标准作业程序（SOP）》
#           《服务器整机验收现场执行版》三份文件保持一致）
#
# 口径：一票否决线 = 该盘型标准区间下限 × 55%
#       区间下限与一票否决线之间是 WARN 灰区——未达推荐值但尚未触线，
#       写入报告、人工确认后可放行。
# 三级判定：
#   PASS —— 实测落在合格区间内，且无 I/O Error、无致命日志
#   WARN —— 未达区间下限，但尚未触及一票否决线
#   FAIL —— 触及一票否决线，或出现硬件级报错
# 数据来源：fio；单位 MB/s（fio 上报 MiB/s，换算 MB/s 需 ×1.048576）
#
# ------------------------------------------------------------
# 表 1　128K 顺序读写（本脚本默认执行）
# ------------------------------------------------------------
#   盘型              顺序读            顺序写            一票否决线
#   PCIe 4.0 NVMe     3,500 ~ 7,000     2,500 ~ 6,500     读 / 写 < 1,900 MB/s
#   PCIe 3.0 NVMe     1,800 ~ 3,400     1,200 ~ 3,000     读 / 写 < 1,000 MB/s
#   SATA / SAS SSD    300 ~ 550         300 ~ 550         读 / 写 < 165 MB/s
#   SAS 机械盘 15K    120 ~ 260         120 ~ 260         读 / 写 < 65 MB/s
#
# ------------------------------------------------------------
# 表 2　4K 随机 IOPS（iodepth=32，numjobs=1）
# ------------------------------------------------------------
#   盘型              随机读              随机写              一票否决线
#   PCIe 4.0 NVMe     400,000 ~ 1,500,000 300,000 ~ 1,300,000 读 < 220,000 / 写 < 165,000
#   PCIe 3.0 NVMe     200,000 ~ 550,000   150,000 ~ 500,000   读 < 110,000 / 写 < 82,000
#   SATA SSD          50,000 ~ 100,000    20,000 ~ 80,000     读 < 27,000 / 写 < 11,000
#   SAS 机械盘 15K    100 ~ 250           100 ~ 250           读 / 写 < 55
#
# ------------------------------------------------------------
# 表 3　128K 随机 IOPS（QD1，单线程延迟表现）
# ------------------------------------------------------------
#   盘型              随机读            随机写            一票否决线
#   PCIe 4.0 NVMe     20,000 ~ 45,000   15,000 ~ 40,000   读 < 11,000 / 写 < 8,000
#   PCIe 3.0 NVMe     12,000 ~ 28,000   10,000 ~ 22,000   读 < 6,600 / 写 < 5,500
#   SATA SSD          2,000 ~ 4,000     2,000 ~ 3,800     读 < 1,100 / 写 < 1,100
#   SAS 机械盘 15K    100 ~ 220         100 ~ 220         读 / 写 < 55
#
# 注：本脚本默认只执行表 1；表 2 / 表 3 供修改脚本参数时参考。
# 同批盘带宽离散度应 ≤ 30%，超出说明个别盘异常，需单独复测。
# 最终判断仍应结合磁盘官方 Datasheet 与实测环境。
# ============================================================

# -------- 颜色 --------
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# -------- 全局标记 --------
GLOBAL_FAIL=0
# 各盘各项的测试结果，供结尾汇总（不落盘，只在内存里）
declare -A FIO_BW FIO_IOPS

# -------- 函数：输出到终端 --------
# 说明：原先会同步写一份 ./fio_test_<时间戳>.log，且把 fio 原始输出存进 ./fio_raw/，
#       按使用要求已全部移除——现在只输出到终端，全程不落任何文件。
#       fio 结果改为在内存里解析（见 run_fio_test），汇总数据存在 FIO_BW / FIO_IOPS 关联数组里。
log() {
    echo -e "$*"
    return 0
}

# -------- 函数：原样透传管道内容 --------
# 回显 fio 原始行时用这个，不做转义解释，避免输出里的反斜杠被吃掉
log_pipe() {
    cat
}

# -------- 检查 root 权限 --------
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：此脚本需要 root 权限运行！${NC}"
    exit 1
fi

# -------- 依赖检查 --------
MISSING_DEPS=""
command -v fio >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS fio"
command -v findmnt >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS findmnt"
command -v lsblk >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS lsblk"
command -v smartctl >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS smartctl"
command -v swapon >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS swapon"
if [ -n "${MISSING_DEPS}" ]; then
    echo -e "${RED}错误：缺少必要工具：${MISSING_DEPS}${NC}"
    echo "请安装后重试，例如：apt install fio smartmontools util-linux"
    exit 1
fi

# -------- lsblk 列能力探测 --------
# TRAN（传输总线）用于识别 USB 装机盘 / iSCSI / FC 远端盘，util-linux 2.27+ 才有；
# RO（只读）2.28+ 才有。老系统上探测失败就退回最小列集，不因缺列直接挂掉。
LSBLK_FMT="-dn -P -o NAME,TYPE,SIZE"
if lsblk -dn -P -o NAME,TYPE,TRAN,SIZE,RO >/dev/null 2>&1; then
    LSBLK_FMT="-dn -P -o NAME,TYPE,TRAN,SIZE,RO"
fi

# -------- ioengine 探测：libaio 优先，缺失则回退 psync --------
FIO_ENGINE="libaio"
FIO_DEPTH=32
if ! fio --enghelp 2>/dev/null | grep -q "libaio"; then
    FIO_ENGINE="psync"
    FIO_DEPTH=1
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

# -------- 函数：查找系统盘（排除） --------
get_root_disk() {
    local root_source=$(findmnt -n -o SOURCE / 2>/dev/null | tr -d '[]')
    [ -z "${root_source}" ] && return 1

    local dev_name="${root_source#/dev/}"
    local parent=""
    local guard=0

    # 逐级上溯到物理盘；guard 防止异常环境下自引用导致死循环
    while [ ${guard} -lt 16 ]; do
        parent=$(lsblk -no pkname "/dev/${dev_name}" 2>/dev/null | head -n1)
        [ -z "${parent}" ] && break
        [ "${parent}" = "${dev_name}" ] && break      # 自引用
        dev_name="${parent}"
        guard=$((guard + 1))
    done

    echo "${dev_name}"
}

# ============================================================
# 自动选盘：只挑「真正能安全测试的数据盘」
# ------------------------------------------------------------
# 老写法 `lsblk -d -o NAME,TYPE | grep disk` 只认 TYPE=disk，会两头出错：
#   误纳入：fd0 软驱（TYPE 也是 disk）、zram0 内存盘、USB 装机启动盘、
#           iSCSI / nbd / FC 远端盘；
#   漏测：  md* 软阵列、dm-* LVM/加密卷、multipath —— 这些 TYPE 都不是 disk，
#           而它们的成员盘反倒会被选中，一测就把阵列写坏了。
# 现在改为：按 TYPE 分「物理盘 / 逻辑卷」两类收集，逐条过滤，并打印排除原因。
# ============================================================

# 明显不是数据盘的设备名（软驱 / 光驱 / 回环 / 内存盘 / 网络块设备）
is_name_blacklisted() {
    case "$1" in
        fd*|sr*|loop*|ram*|zram*|nbd*|rbd*) return 0 ;;
        *) return 1 ;;
    esac
}

# 走这些总线的盘一律不自动测：USB 是可插拔设备（机箱上常插着装机 U 盘），
# iscsi / fc 是远端 LUN，写进去毁的是存储侧的数据
is_remote_or_removable() {
    case "$1" in
        usb|iscsi|fc) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 lsblk -P 的单行键值对里取值：pval 'NAME="sda" TYPE="disk"' NAME -> sda
# 纯 bash 实现，不走管道——设备多时省掉几百个进程；只用于取
# NAME / TYPE / TRAN / SIZE / RO 这些值里不含空格的键。
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

# 该设备之下是否还有逻辑卷 / 阵列 / 多路径（有的话说明它被上层卷覆盖，不该单独测）
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

# ---------- 自动选盘主函数 ----------
# 输出：DISK_ARRAY（可测设备名）、SKIPPED_REPORT（被排除设备与原因，格式 "名字|原因"）
DISK_ARRAY=()
SKIPPED_REPORT=()
collect_auto_disks() {
    local min_bytes line name dtype tran size ro
    local -a phys logic bad_phys

    DISK_ARRAY=()
    SKIPPED_REPORT=()
    phys=(); logic=(); bad_phys=()
    min_bytes=$(( FIO_MIN_SIZE_GB * 1024 * 1024 * 1024 ))

    build_protected

    # 保护集为空说明 findmnt / swapon 一个在用设备都没读到——此时自动选盘不可信，
    # 宁可拒绝执行，也不能把系统盘当数据盘写掉。
    if [ ${#PROTECTED[@]} -eq 0 ]; then
        echo -e "${RED}FAIL：未能构建受保护设备集（findmnt / swapon 读取失败），拒绝自动选盘。${NC}"
        echo -e "${YELLOW}      如确需测试，请显式指定盘名：./fio.sh ${FIO_RUN_TIME} <盘名>${NC}"
        DISK_ARRAY=()
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

    DISK_ARRAY=("${phys[@]}" "${logic[@]}")
    return 0
}

# -------- 函数：从 fio 文本输出中按键名取值 --------
# 用法：fio_field <文件> <write|read> <bw|iops>
#   per-job 行：  write: IOPS=40.0k, BW=156MiB/s (164MB/s)(18.3GiB/120001msec)
#   group  行：   WRITE: bw=156MiB/s (164MB/s), 156MiB/s-156MiB/s (...)
#   注意 group 行里没有 IOPS，所以 IOPS 只能从 per-job 行取。
# 从 stdin 读取 fio 输出并解析字段（原先是传文件路径，现改为内存解析，不落盘）
fio_field() {
    awk -v want="$1" -v key="$2" '
        {
            line = tolower($0)
            # 只认形如 "  write: IOPS=..." / "  write: BW=..." / "  WRITE: bw=..." 的结果行
            if (line !~ ("^[ \t]*" want ":") ) next
            if (line ~ /^[ \t]*(bw|iops)[ \t]*\(/) next     # 排除 "bw ( KiB/s): min=..." 统计行
            if (key == "bw") {
                if (match($0, /[Bb][Ww]=[0-9][0-9.]*[KMGT]?i?B\/s/)) {
                    s = substr($0, RSTART, RLENGTH)
                    sub(/^[Bb][Ww]=/, "", s)
                    print s; exit
                }
            } else {
                if (match($0, /[Ii][Oo][Pp][Ss]=[0-9][0-9.]*[kKmM]?/)) {
                    s = substr($0, RSTART, RLENGTH)
                    sub(/[Ii][Oo][Pp][Ss]=/, "", s)
                    print s; exit
                }
            }
        }'
}

# -------- 函数：由带宽估算 IOPS（bs=128k 时的兜底，128KiB=131072B）--------
iops_from_bw() {
    awk -v s="$1" 'BEGIN{
        if (s == "") exit
        if (!match(s, /^[0-9][0-9.]*/)) exit
        v = substr(s, RSTART, RLENGTH) + 0
        u = substr(s, RLENGTH + 1)
        m = 1
        if      (u ~ /^Ki/) m = 1024
        else if (u ~ /^Mi/) m = 1048576
        else if (u ~ /^Gi/) m = 1073741824
        else if (u ~ /^Ti/) m = 1099511627776
        else if (u ~ /^K/)  m = 1000
        else if (u ~ /^M/)  m = 1000000
        else if (u ~ /^G/)  m = 1000000000
        else if (u ~ /^T/)  m = 1000000000000
        printf "%.0f", v * m / 131072
    }'
}

# -------- 函数：执行 FIO 顺序写/读测试（串行执行，一块一块跑） --------
run_fio_test() {
    local test_type="$1"
    shift
    local disks=("$@")

    if [ ${#disks[@]} -eq 0 ]; then
        return 0
    fi

    log "\n--- 128k 顺序 ${test_type} 测试 (${FIO_RUN_TIME}s) ---"

    local fail=0

    for d in "${disks[@]}"; do
        log "\n  >>> 正在测试 /dev/${d} ..."

        # fio 输出留在内存里解析，不写任何文件；stderr 一并并入，便于失败时定位
        local fio_out rc
        fio_out=$(fio --name=${test_type}_${d} \
            --filename=/dev/${d} \
            --direct=1 \
            --iodepth=${FIO_DEPTH} \
            --thread \
            --rw=${test_type} \
            --ioengine=${FIO_ENGINE} \
            --bs=128k \
            --size=100% \
            --runtime=${FIO_RUN_TIME} \
            --time_based \
            --group_reporting 2>&1)
        rc=$?

        # --- fio 本身执行失败：必须报出来，不能只显示“未知” ---
        if [ "$rc" -ne 0 ] || [ -z "$fio_out" ]; then
            log "  ${RED}[FAIL] /dev/${d} ${test_type} fio 退出码 ${rc}${NC}"
            if [ -n "$fio_out" ]; then
                log "         fio 输出尾部："
                printf '%s\n' "$fio_out" | tail -n 8 | sed 's/^/         | /' | log_pipe
            fi
            fail=1
            continue
        fi

        # --- 取值（从内存里的 fio 输出解析）---
        local bw iops
        bw=$(printf '%s\n' "$fio_out" | fio_field "$test_type" bw)
        iops=$(printf '%s\n' "$fio_out" | fio_field "$test_type" iops)
        if [ -z "$iops" ] && [ -n "$bw" ]; then
            iops=$(iops_from_bw "$bw")
            [ -n "$iops" ] && iops="${iops}（由带宽换算）"
        fi

        log "  /dev/${d} | ${test_type}带宽: ${bw:-未知} | 平均IOPS: ${iops:-未知}"

        # --- 解析失败时自曝现场，方便定位，而不是干巴巴一个“未知” ---
        if [ -z "$bw" ]; then
            log "  ${YELLOW}[WARN] 未能从 fio 输出解析出带宽，输出尾部：${NC}"
            printf '%s\n' "$fio_out" | tail -n 8 | sed 's/^/         | /' | log_pipe
            fail=1
        fi

        if printf '%s\n' "$fio_out" | grep -qiE "err=[1-9]|io error|I/O error|failed"; then
            log "  ${YELLOW}[WARN] /dev/${d} ${test_type}测试出现错误${NC}"
            fail=1
        fi

        # 存进关联数组，供最后的结果汇总使用（原先是回头再去读 fio_raw 文件）
        FIO_BW["${d}_${test_type}"]="$bw"
        FIO_IOPS["${d}_${test_type}"]="$iops"
    done

    if [ "$fail" -eq 0 ]; then
        log "\n128k 顺序 ${test_type} 测试全部完成"
    else
        log "\n${YELLOW}WARN：顺序 ${test_type} 测试存在异常${NC}"
        GLOBAL_FAIL=1
    fi
}

# ==================== 主流程 ====================

# 1. 确定要测试的磁盘列表
DISK_ARRAY=()
if [ $# -gt 0 ]; then
    # 用户指定了磁盘列表（$@ 是剩余的所有参数）
    for arg in "$@"; do
        if [ -e "/dev/$arg" ]; then
            DISK_ARRAY+=("$arg")
        else
            echo -e "${RED}错误：磁盘 /dev/$arg 不存在${NC}" >&2
            exit 1
        fi
    done
    if [ ${#DISK_ARRAY[@]} -eq 0 ]; then
        echo -e "${RED}错误：未指定任何有效的磁盘${NC}" >&2
        exit 1
    fi
    echo -e "${BLUE}使用用户指定的磁盘列表：${DISK_ARRAY[*]}${NC}"
else
    # 自动识别：只挑真正能安全测的数据盘（判定逻辑见 collect_auto_disks）
    SYS_DISK=$(get_root_disk)
    if [ -z "${SYS_DISK}" ]; then
        echo -e "${RED}FAIL：无法识别系统盘，为安全起见终止测试。${NC}"
        exit 1
    fi

    collect_auto_disks || exit 1

    # 把「为什么某块盘没被选中」打出来——实机上这比结果本身还重要
    if [ ${#SKIPPED_REPORT[@]} -gt 0 ]; then
        echo -e "${YELLOW}以下设备已被自动跳过（共 ${#SKIPPED_REPORT[@]} 项）：${NC}"
        for item in "${SKIPPED_REPORT[@]}"; do
            echo -e "  ${YELLOW}✗${NC} /dev/${item%%|*}  —— ${item#*|}"
        done
        echo ""
    fi

    if [ ${#DISK_ARRAY[@]} -eq 0 ]; then
        # ★ 一块盘都没测 ≠ 通过。之前这里 exit 0，自动化按退出码读会当成 PASS。
        echo -e "${YELLOW}⏳ 【判定】Pending —— 没有找到可自动测试的数据盘（都被排除或仅剩系统盘），本次未测任何盘${NC}"
        echo -e "${YELLOW}      确认某块盘可以安全覆盖后，可显式指定：./fio.sh ${FIO_RUN_TIME} <盘名>${NC}"
        exit 2
    fi
    echo -e "${BLUE}自动识别到数据盘：${DISK_ARRAY[*]}（已排除系统盘 /dev/${SYS_DISK}）${NC}"
fi

# ============================================================
# 🔴 跑前提示 + 二次确认
# ============================================================
echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}  ⚠️ 警告：以下磁盘将进行 FIO 顺序写/读压力测试${NC}"
echo -e "${RED}  测试会覆盖磁盘上的数据！请确认已做好数据备份！${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
echo -e "${YELLOW}待测试磁盘列表：${NC}"
for d in "${DISK_ARRAY[@]}"; do
    DEV="/dev/${d}"
    CAP=$(lsblk "$DEV" -dn -o SIZE 2>/dev/null | tr -d ' ')
    MODEL=$(lsblk "$DEV" -dn -o MODEL 2>/dev/null | sed 's/^[ ]*//;s/[ ]*$//')
    SERIAL=$(lsblk "$DEV" -dn -o SERIAL 2>/dev/null | sed 's/^[ ]*//;s/[ ]*$//')
    echo -e "  ${BLUE}→ ${DEV}${NC}  | 容量: ${CAP:-未知} | 型号: ${MODEL:-未知} | 序列号: ${SERIAL:-未知}"

    # 该盘上的分区若正被挂载，数据一定会丢，必须醒目提示
    MOUNTED=$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | grep -v '^$' | tr '\n' ' ')
    if [ -n "${MOUNTED}" ]; then
        echo -e "     ${RED}⚠️  该盘上有分区处于挂载状态：${MOUNTED}${NC}"
        echo -e "     ${RED}    压测会直接销毁这些分区上的数据，请先卸载！${NC}"
    fi
done

# 如果用户指定了磁盘，但其中包含系统盘，给出额外警告
if [ $# -gt 0 ]; then
    SYS_DISK=$(get_root_disk)
    for d in "${DISK_ARRAY[@]}"; do
        if [ "$d" = "$SYS_DISK" ]; then
            echo -e "${RED}⚠️  注意：您指定的磁盘 /dev/${d} 是当前系统盘！${NC}"
            break
        fi
    done
fi

echo ""
echo -e "${RED}测试时长：写 ${FIO_RUN_TIME} 秒 + 读 ${FIO_RUN_TIME} 秒${NC}"
echo -e "${BLUE}ioengine：${FIO_ENGINE} / iodepth=${FIO_DEPTH}${NC}"
[ "${FIO_ENGINE}" != "libaio" ] && \
    echo -e "${YELLOW}提示：libaio 不可用，已回退 psync（iodepth=1），IOPS 数值与 libaio 深队列不可直接比较。${NC}"
echo ""

read -p "确认要执行 FIO 压力测试吗？(输入 yes 或 y 继续，其他则退出): " confirm
if [ "$confirm" != "yes" ] && [ "$confirm" != "y" ]; then
    echo -e "${YELLOW}用户取消测试，退出。${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}已确认，开始测试...${NC}"
echo ""

# 说明：原先会在 ./fio_raw/ 下留存 fio 原始输出、并写 ./fio_test_<时间戳>.log，
#       按使用要求已全部移除——fio 输出改为在内存里解析，只把结果打到终端，不落任何文件。
log "测试时间: $(date)"
log "测试时长: 写 ${FIO_RUN_TIME}s / 读 ${FIO_RUN_TIME}s"
log "测试磁盘: ${DISK_ARRAY[*]}"
log "ioengine: ${FIO_ENGINE} / iodepth=${FIO_DEPTH}"
log "========================================"

# 3. 运行 FIO 写测试
run_fio_test "write" "${DISK_ARRAY[@]}"

# 4. 运行 FIO 读测试
run_fio_test "read" "${DISK_ARRAY[@]}"

# 5. SMART 健康复查
log "\n--- FIO压测后 SMART 健康复查 ---"
for d in "${DISK_ARRAY[@]}"; do
    DEV="/dev/${d}"
    case "$(smart_health "${DEV}")" in
        PASSED)
            log "  ${DEV} SMART健康复查: PASSED（自检通过）" ;;
        FAILED)
            log "  ${RED}[FAIL]${NC} ${DEV} SMART健康复查: FAILED（压测后自检不通过，需排查/更换）"
            GLOBAL_FAIL=1 ;;
        UNSUPPORTED)
            log "  ${YELLOW}[WARN]${NC} ${DEV} SMART健康复查: 不支持/不可读（被RAID卡屏蔽或设备无SMART，非硬盘故障，请人工确认）" ;;
        *)
            log "  ${YELLOW}[WARN]${NC} ${DEV} SMART健康复查: 未知（smartctl 执行异常，请人工确认）" ;;
    esac
done

# 6. 结果汇总（方便直接贴报告）
log ""
log "--- 结果汇总 ---"
for d in "${DISK_ARRAY[@]}"; do
    for t in write read; do
        k="${d}_${t}"
        if [ -n "${FIO_BW[$k]:-}" ] || [ -n "${FIO_IOPS[$k]:-}" ]; then
            log "  /dev/${d}  ${t}  带宽=${FIO_BW[$k]:-未知}  IOPS=${FIO_IOPS[$k]:-未知}"
        fi
    done
done

# 7. 最终结果
log ""
if [ ${GLOBAL_FAIL} -eq 0 ]; then
    log "${GREEN}✅ 所有磁盘 FIO 测试通过。${NC}"
    exit 0
else
    log "${RED}❌ FIO 测试存在失败或警告，请查看日志。${NC}"
    exit 1
fi
