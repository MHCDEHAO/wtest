#!/bin/bash
# ============================================================
# 硬盘指示灯点灯测试
#
# 用法：sudo bash led.sh [选项]
#   无参数            交互执行三步点灯（蓝闪 -> 橙亮 -> 全灭）
#   --dry-run         只列出待测试设备并退出，不点灯
#   --include-usb     不排除 USB / 可移动设备（默认排除）
#   -h, --help        显示帮助
#
# 依赖：ledctl（ledmon 包）、util-linux（lsblk / findmnt）
#
# 相对原始 led.sh 的修正点：
#   1. 第 3 步改用 normal=（off= 关不掉 Locate 蓝灯，原版必然判失败）
#   2. 第 2 步前先 locate_off=，避免蓝橙同亮干扰目视
#   3. 检查 ledctl 返回码，杜绝"命令失败却报通过"的假阳性
#   4. trap 清理：中断/异常退出时自动复位指示灯
#   5. 检测并处理 ledmon 守护进程抢占 LED 导致橙灯点不亮
#   6. 系统盘识别兼容 LVM / md-RAID / btrfs（遍历全部挂载点 + swap）
#   7. 设备筛选改为精确匹配 TYPE 列，排除 USB/可移动设备与空读卡器
#   8. 点灯前列出设备清单并二次确认，避免误亮生产盘故障灯
#   9. 状态码输出改为纯 ASCII，避免串口终端乱码
# ============================================================

set -u

# ---------- 参数解析 ----------
DRY_RUN=0
INCLUDE_USB=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=1 ;;
        --include-usb) INCLUDE_USB=1 ;;
        -h|--help)
            sed -n '2,23p' "$0"
            exit 0
            ;;
        *)
            echo "[FAIL] 未知参数: $arg（用 --help 查看用法）"
            exit 1
            ;;
    esac
done

# ---------- 前置检查 ----------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[FAIL] 请使用 bash 运行：sudo bash $0"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] 请使用 root 权限运行此脚本！"
    exit 1
fi

for cmd in ledctl lsblk findmnt awk sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[FAIL] 缺少命令: $cmd"
        [ "$cmd" = "ledctl" ] && echo "       安装：apt install ledmon / yum install ledmon"
        exit 1
    fi
done

# 是否支持 --listed-only（旧版 ledctl 没有该选项）
LEDCTL_X=""
if ledctl --help 2>&1 | grep -q -- '--listed-only'; then
    LEDCTL_X="--listed-only"
fi

info() { echo "[ .. ] $*"; }
ok()   { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*"; }
die()  { echo "[FAIL] $*"; exit 1; }

# ---------- 交互确认 ----------
ask_confirm() {
    local prompt="$1" ans
    if [ ! -t 0 ]; then
        echo "[FAIL] 当前不是交互终端，无法完成人工目视确认，请直接在控制台运行。"
        return 1
    fi
    read -r -N1 -p "$prompt" ans || ans=""
    echo
    case "${ans,,}" in
        y) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 收集所有物理磁盘 ----------
ALL_DISKS=$(lsblk -d -ln -o TYPE,KNAME,SIZE 2>/dev/null \
            | awk '$1=="disk" && $3!="0B" {print $2}')

if [ -z "$ALL_DISKS" ]; then
    echo "[ .. ] 系统中未发现任何物理磁盘"
    exit 0
fi

# 建立「子设备 -> 所属物理盘」映射（覆盖分区、LVM、md-RAID 等层级）
declare -A OWNERS
for d in $ALL_DISKS; do
    while read -r child; do
        [ -n "$child" ] || continue
        if [ -z "${OWNERS[$child]:-}" ]; then
            OWNERS[$child]="$d"
        else
            OWNERS[$child]="${OWNERS[$child]} $d"
        fi
    done < <(lsblk -ln -o KNAME "/dev/$d" 2>/dev/null)
done

# ---------- 识别系统盘 ----------
# 收集所有已挂载文件系统的来源 + swap 设备，逐个回溯到物理盘
SYS_SOURCES=$(
    {
        findmnt -rno SOURCE 2>/dev/null
        awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null
    } | sort -u
)

SYS_DISKS=""
for src in $SYS_SOURCES; do
    case "$src" in
        /dev/*) ;;
        *) continue ;;
    esac
    src=${src%%[*}            # 去掉 btrfs 子卷后缀，如 /dev/sda3[/@]
    [ -e "$src" ] || continue

    kname=$(lsblk -no KNAME "$src" 2>/dev/null | head -1)
    [ -n "$kname" ] || continue

    owners="${OWNERS[$kname]:-}"
    [ -n "$owners" ] || owners="$kname"   # 顶层设备本身就是一块盘

    for o in $owners; do
        case " $SYS_DISKS " in
            *" $o "*) ;;
            *) SYS_DISKS="$SYS_DISKS $o" ;;
        esac
    done
done

if [ -z "$SYS_DISKS" ]; then
    warn "无法识别系统盘，请务必人工核对下列清单"
else
    info "已识别系统盘（将被排除）：$(echo $SYS_DISKS | tr ' ' ',')"
fi

# ---------- 筛选待测试的数据盘 ----------
DISK_LIST=""
for d in $ALL_DISKS; do
    case " $SYS_DISKS " in
        *" $d "*) continue ;;
    esac

    if [ "$INCLUDE_USB" -eq 0 ]; then
        tran=$(lsblk -dno TRAN "/dev/$d" 2>/dev/null)
        removable=$(lsblk -dno RM "/dev/$d" 2>/dev/null)
        if [ "$tran" = "usb" ] || [ "$removable" = "1" ]; then
            warn "跳过 USB/可移动设备 /dev/$d（如需测试请加 --include-usb）"
            continue
        fi
    fi

    DISK_LIST="$DISK_LIST $d"
done

if [ -z "$DISK_LIST" ]; then
    echo "[ .. ] 未找到可测试的数据盘（系统盘已排除）"
    exit 0
fi

# ---------- 打印设备清单 ----------
disk_str=""
for d in $DISK_LIST; do
    disk_str="${disk_str}/dev/${d},"
done
disk_str=${disk_str%,}

echo ""
echo "==================== 待测试设备清单 ===================="
printf '%-10s %-9s %-7s %-26s %s\n' "DEVICE" "SIZE" "BUS" "MODEL" "SERIAL"
echo "--------------------------------------------------------"
for d in $DISK_LIST; do
    size=$(lsblk -dno SIZE   "/dev/$d" 2>/dev/null)
    tran=$(lsblk -dno TRAN   "/dev/$d" 2>/dev/null)
    model=$(lsblk -dno MODEL "/dev/$d" 2>/dev/null | tr -s ' ')
    serial=$(lsblk -dno SERIAL "/dev/$d" 2>/dev/null)
    printf '%-10s %-9s %-7s %-26s %s\n' \
        "/dev/$d" "${size:--}" "${tran:--}" "${model:--}" "${serial:--}"
done
echo "--------------------------------------------------------"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    info "--dry-run 模式，不执行点灯，已退出"
    exit 0
fi

# ★ 非交互终端必须在这里拦掉。本脚本每一步都靠人工目视确认，
#   而 ask_confirm 在非 TTY 下直接返回 1，会被下面的「已取消」分支
#   当成用户主动取消，最终以退出码 0 收场 —— 一个灯都没点却报成功。
#   这属用法/环境类错误，按约定退 2。
if [ ! -t 0 ]; then
    echo "[FAIL] 当前不是交互终端，本脚本需人工目视确认每一步点灯结果，请在控制台直接运行。"
    exit 2
fi

# ---------- 处理 ledmon 守护进程 ----------
LEDMON_STOPPED=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ledmon 2>/dev/null; then
    warn "ledmon 守护进程正在运行，它会抢占 LED 控制权"
    warn "除 locate 外，ledctl 设置的 pattern 可能无效（橙灯点不亮）"
    if ask_confirm "是否临时停止 ledmon 以便测试？(y/N) "; then
        systemctl stop ledmon || die "停止 ledmon 失败"
        LEDMON_STOPPED=1
        info "ledmon 已临时停止，测试结束后会自动恢复"
    else
        warn "继续测试，若第 2 步橙灯不亮请回头停止 ledmon 再试"
    fi
fi

# ---------- 清理陷阱 ----------
cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "$disk_str" ]; then
        ledctl $LEDCTL_X "normal=$disk_str" >/dev/null 2>&1 || true
    fi
    if [ "$LEDMON_STOPPED" -eq 1 ]; then
        systemctl start ledmon >/dev/null 2>&1 || true
        echo "[ .. ] ledmon 已恢复启动"
    fi
    exit "$rc"
}
trap 'printf "\n"; warn "已中断，正在复位指示灯..."; exit 130' INT TERM
trap cleanup EXIT

# ---------- 执行点灯 ----------
apply_led() {
    local pattern="$1" desc="$2"
    echo "      执行: ledctl $LEDCTL_X $pattern=$disk_str"
    if ! ledctl $LEDCTL_X "$pattern=$disk_str"; then
        echo "[FAIL] ledctl 返回非零，$desc 指令未被接受"
        echo "       排查：1) ledmon 是否仍在运行"
        echo "             2) ledctl -L 查看识别到的控制器"
        echo "             3) tail /var/log/ledctl.log"
        return 1
    fi
    return 0
}

confirm_step() {
    local name="$1" visual="$2"
    if ! ask_confirm "      请目视确认${visual}，按 y 通过，其他键终止："; then
        echo "[FAIL] ${name}未通过，已复位指示灯并终止"
        return 1
    fi
    ok "${name}通过"
    return 0
}

echo "==================== 硬盘指示灯测试 ===================="
echo "[WARN] 接下来会点亮故障橙灯，请确保已与现场运维确认，非停机窗口请勿继续"

if ! ask_confirm "上述设备清单确认无误，开始点灯测试？(y/N) "; then
    echo "[ .. ] 已取消，未执行任何点灯操作"
    exit 0
fi

echo ""
echo ">>> 第 1 步：蓝色定位灯（locate）"
if apply_led "locate" "蓝灯点亮"; then
    confirm_step "第 1 步蓝色定位灯测试" "蓝灯正在闪烁" || exit 1
else
    exit 1
fi

echo ""
echo ">>> 第 2 步：橙色故障灯（failure）"
# 先熄灭蓝灯，避免蓝橙同时亮误导目视确认
if apply_led "locate_off" "蓝灯熄灭"; then
    if apply_led "failure" "橙灯点亮"; then
        confirm_step "第 2 步橙色故障灯测试" "橙灯常亮（蓝灯应已熄灭）" || exit 1
    else
        exit 1
    fi
else
    exit 1
fi

echo ""
echo ">>> 第 3 步：熄灭全部指示灯（normal）"
if apply_led "normal" "指示灯复位"; then
    confirm_step "第 3 步灭灯测试" "所有指示灯（含蓝灯）均已熄灭" || exit 1
else
    exit 1
fi

echo ""
echo "==================== 点灯测试全部通过 ===================="
exit 0
