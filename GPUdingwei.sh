#!/bin/bash
# ============================================================
# GPUdingwei.sh —— 单卡定位压测
#   用 gpu-burn 只压指定的那一张卡；配合 BMC 的温度读数，
#   就能确定这张卡在机箱里的物理位置（SXM 模组查不到 PCIe 槽位时用得上）。
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   bash GPUdingwei.sh -3              # 压 nvidia-smi 里的 3 号卡，默认 600 秒
#   bash GPUdingwei.sh -3 --200        # 压 3 号卡，只跑 200 秒
#   bash GPUdingwei.sh -3 -t 1800      # 同上，跑 30 分钟（-t 与 --SEC 等价）
#   bash GPUdingwei.sh -3 -m 80        # 少占点显存（默认 100 跑满；调小可降温）
#   bash GPUdingwei.sh --list          # 只看卡列表（免 root，不改任何东西）
#   bash GPUdingwei.sh -h
#
#   ★ -3 里的 3 就是 nvidia-smi 输出的第一列 index。
#   ★ 不需要 root。
#   ★ 压测固定用 -d 双精度 + -m 100% 跑满显存，温度最高，最容易暴露散热问题。
#   ★ 跑起来后，在另一个终端看 BMC 哪条 GPU 温度涨，那张卡就在那个物理位置。
#
#   【典型输出】
#     目标卡   : index 3 | 00000000:03:00.0 | NVIDIA H200
#     ...（gpu-burn 自己的输出）...
#     最高温度 : 83 ℃   峰值功耗 : 702.3 W   最高利用率 : 100 %
#     【判定】PASS —— 压测完成，gpu-burn 报 OK
#
# ---- 二、参数一览 ----
#   -N                要压的 GPU 编号（nvidia-smi 的 index），如 -3
#   --SEC             压测时长（秒），填多少跑多少：--200→200 秒、--30→30 秒（默认 600）
#   -t / --time SEC   压测时长（秒），默认 600
#   -m / --mem PCT    显存占用百分比，默认 100（跑满显存）
#   -y / --yes        跳过开始前的人工确认（批量自动化用）
#   --list            只列出所有 GPU（免 root，不压测）
#   -h / --help       打印本段帮助
#
# ---- 三、环境变量 ----
#     GPU_BURN=/path/gpu_burn   指定 gpu-burn 可执行文件路径
#     SAMPLE_INTERVAL=5         温度采样间隔（秒），默认 5
#
# ---- 四、它做什么 ----
#   1) 用 nvidia-smi 校验 -N 指定的编号存在，并取出它的 UUID
#   2) 导出 CUDA_DEVICE_ORDER=PCI_BUS_ID，让 CUDA 序号与 nvidia-smi 对齐
#   3) 用 CUDA_VISIBLE_DEVICES=<UUID> 锁定这张卡后调用 gpu-burn
#      （走 UUID 是双保险：即便序号体系有出入，也压不错卡）
#      压测参数固定 -d 双精度 + -m 100%，把显存占满、温度顶到最高
#   4) 压测期间采样这张卡的温度 / 功耗 / 利用率
#   5) 结束后汇总峰值并给出判定
#   ★ 全程不写任何日志文件，所有临时数据都留在内存里，结果只在终端输出
#
# ---- 五、判定口径与退出码 ----
#   PASS   gpu-burn 正常结束，输出里没有 FAULTY / error
#   FAIL   gpu-burn 非 0 退出，或输出里出现 FAULTY / error
#   退出码：0 = PASS；1 = FAIL；2 = 用法 / 环境错误
# ============================================================

set -u

# ---------- 颜色 ----------
if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
fi

: "${SAMPLE_INTERVAL:=5}"
: "${GPU_BURN:=}"

IDX=""
DURATION=600
MEMPCT=100
ASSUME_YES=0
LIST_ONLY=0

usage(){ sed -n '2,53p' "$0"; exit 0; }

# ---------- 参数解析 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)   usage ;;
        --list)      LIST_ONLY=1; shift ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        -t|--time)   DURATION="${2:-}"; shift 2 ;;
        -m|--mem)    MEMPCT="${2:-}";  shift 2 ;;
        --[0-9]*)
            # 形如 --200 / --1800：压测时长（秒），与 -t 等价
            if printf '%s' "$1" | grep -qE '^--[0-9]+$'; then
                DURATION="${1#--}"; shift
            else
                echo -e "${RED}[FAIL]${NC} 无法识别的参数: $1（用 -h 查看用法）"; exit 2
            fi
            ;;
        -[0-9]*)
            # 形如 -3 / -12：nvidia-smi 的 index
            if printf '%s' "$1" | grep -qE '^-[0-9]+$'; then
                IDX="${1#-}"; shift
            else
                echo -e "${RED}[FAIL]${NC} 无法识别的参数: $1（用 -h 查看用法）"; exit 2
            fi
            ;;
        *)
            echo -e "${RED}[FAIL]${NC} 未知参数: $1（用 -h 查看用法）"; exit 2 ;;
    esac
done

# ---------- 参数合法性 ----------
if ! printf '%s' "$DURATION" | grep -qE '^[0-9]+$' || [ "$DURATION" -eq 0 ]; then
    echo -e "${RED}[FAIL]${NC} 压测时长必须是大于 0 的正整数（秒），收到: ${DURATION}（用 -t 600 或 --600）"; exit 2
fi
if ! printf '%s' "$MEMPCT" | grep -qE '^[0-9]+$' || [ "$MEMPCT" -lt 1 ] || [ "$MEMPCT" -gt 100 ]; then
    echo -e "${RED}[FAIL]${NC} -m 显存百分比必须在 1~100 之间，收到: ${MEMPCT}"; exit 2
fi

# ---------- 依赖：nvidia-smi ----------
if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} 未找到 nvidia-smi，无法定位 GPU"; exit 2
fi
if ! nvidia-smi &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} nvidia-smi 无法正常执行（驱动异常或显卡掉线？）"; exit 2
fi

# ---------- --list：免 root 只读 ----------
if [ "$LIST_ONLY" -eq 1 ]; then
    echo -e "${BLUE}当前 GPU 列表（index 就是 -N 要用的编号）:${NC}"
    nvidia-smi --query-gpu=index,pci.bus_id,name,serial,uuid --format=csv
    exit 0
fi

# ---------- 依赖：gpu-burn ----------
BURN_BIN="${GPU_BURN}"
if [ -z "$BURN_BIN" ]; then
    BURN_BIN=$(command -v gpu_burn 2>/dev/null || command -v gpu-burn 2>/dev/null || true)
fi
if [ -z "$BURN_BIN" ] || [ ! -x "$BURN_BIN" ]; then
    echo -e "${RED}[FAIL]${NC} 未找到 gpu-burn 可执行文件"
    echo "  安装方式二选一："
    echo "    sudo snap install gpu-burn"
    echo "    git clone https://github.com/wilicc/gpu-burn && cd gpu-burn && make"
    echo "  已装但在别处：GPU_BURN=/path/to/gpu_burn bash $0 -3"
    exit 2
fi

# ---------- 必须指定编号 ----------
if [ -z "$IDX" ]; then
    echo -e "${RED}[FAIL]${NC} 请用 -N 指定要压的 GPU 编号，例如：bash $0 -3"
    echo "  不知道编号就先跑：bash $0 --list"
    exit 2
fi

# ---------- 校验编号存在，并取出该卡身份 ----------
GPU_INFO=$(nvidia-smi -i "$IDX" --query-gpu=index,pci.bus_id,name,serial,uuid --format=csv,noheader 2>/dev/null)
if [ -z "$GPU_INFO" ]; then
    echo -e "${RED}[FAIL]${NC} nvidia-smi 里没有编号 ${IDX} 的卡"
    echo "  当前可用编号："
    nvidia-smi --query-gpu=index,name --format=csv,noheader | sed 's/^/    /'
    exit 2
fi

pick(){ printf '%s\n' "$GPU_INFO" | awk -F',' -v n="$1" '{v=$n; gsub(/^[ \t]+|[ \t]+$/,"",v); print v}'; }
BDF=$(pick 2); GNAME=$(pick 3); GSN=$(pick 4); UUID=$(pick 5)

# UUID 是锁定单卡的关键，取不到就不压，绝不冒险
if [ -z "$UUID" ] || [ "$UUID" = "[N/A]" ]; then
    echo -e "${RED}[FAIL]${NC} 取不到该卡 UUID，为安全起见不执行压测"
    echo "  （UUID 用来锁定单卡；拿不到就无法保证压对卡）"
    exit 2
fi

# ---------- 打印目标并确认 ----------
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  单卡定位压测${NC}"
echo -e "${BLUE}============================================================${NC}"
echo "  目标卡   : index ${IDX}"
echo "  总线地址 : ${BDF}"
echo "  型号     : ${GNAME}"
echo "  序列号   : ${GSN}"
echo "  UUID     : ${UUID}"
echo "  压测时长 : ${DURATION} 秒"
echo "  显存占用 : ${MEMPCT}%"
echo ""

if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} 当前非交互环境，请加 -y 跳过确认"; exit 2
    fi
    printf "  确认对这张卡压测？[y/N] "
    read -r ans
    case "${ans:-}" in
        y|Y|yes|YES) ;;
        *) echo "  已取消，未做任何压测。"; exit 0 ;;
    esac
fi

# ---------- 压测（不落任何日志文件） ----------
export CUDA_DEVICE_ORDER=PCI_BUS_ID

BURN_PID=""
BURN_OUT=""     # gpu-burn 的全部输出，留在内存
SAMPLES=""      # 采样到的 "温度,功耗,利用率"，留在内存

cleanup(){
    if [ -n "$BURN_PID" ]; then kill "$BURN_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

# 采一次样，累加进内存（不写文件）
sample_once(){
    local line t p u
    line=$(nvidia-smi -i "$IDX" --query-gpu=temperature.gpu,power.draw,utilization.gpu \
               --format=csv,noheader,nounits 2>/dev/null) || return 0
    [ -n "$line" ] || return 0
    IFS=',' read -r t p u <<<"$line"
    t=$(printf '%s' "$t" | tr -d ' ')
    p=$(printf '%s' "$p" | tr -d ' ')
    u=$(printf '%s' "$u" | tr -d ' ')
    case "$t" in ''|*[!0-9.]*) return 0 ;; esac   # 读不到就跳过
    SAMPLES="${SAMPLES}${t},${p:-0},${u:-0}"$'\n'
}

echo ""
echo -e "${YELLOW}>>> 开始压测 ${DURATION} 秒。另开终端看 BMC 温度，即可定位物理位置 <<<${NC}"
echo -e "${YELLOW}>>> 想确认压对了卡，另开终端跑：nvidia-smi --query-gpu=index,utilization.gpu,power.draw --format=csv${NC}"
echo ""

# 用协程把 gpu-burn 的输出接到主 shell：
#   读到行 -> 打印并留在内存；读超时 -> 正好采一次样。
# 这样采样在主线里做，变量能保留，也不需要任何临时文件。
coproc BURN { CUDA_VISIBLE_DEVICES="$UUID" "$BURN_BIN" -d -m "${MEMPCT}%" "$DURATION" 2>&1; }
# 协程启动后 BURN_PID 由 bash 自动填好，直接用

sample_once
LAST_SAMPLE=$(date +%s)

while :; do
    if IFS= read -r -t "$SAMPLE_INTERVAL" line <&"${BURN[0]}"; then
        printf '%s\n' "$line"
        BURN_OUT="${BURN_OUT}${line}"$'\n'
    else
        rc=$?
        [ "$rc" -le 128 ] && break          # 非超时 = EOF，gpu-burn 已结束
    fi
    now=$(date +%s)
    if [ $((now - LAST_SAMPLE)) -ge "$SAMPLE_INTERVAL" ]; then
        sample_once
        LAST_SAMPLE=$now
    fi
done

wait "$BURN_PID" 2>/dev/null; BURN_RC=$?
BURN_PID=""

# ---------- 汇总 ----------
echo ""
echo -e "${BLUE}============================================================${NC}"
echo "  压测期间该卡状态（采样间隔 ${SAMPLE_INTERVAL}s）"
echo -e "${BLUE}============================================================${NC}"

# 显存占用：从 gpu-burn 自己的初始化行里取，用来证明"跑满"
# 形如：Initialized device 0 with 143771 MB of memory (141234 MB available, using 141234 MB of it)
MEM_LINE=$(printf '%s\n' "$BURN_OUT" | grep -m1 'MB of it' || true)
if [ -n "$MEM_LINE" ]; then
    m_used=$(printf '%s' "$MEM_LINE" | sed -n 's/.*using \([0-9][0-9]*\) MB of it.*/\1/p')
    m_avail=$(printf '%s' "$MEM_LINE" | sed -n 's/.*(\([0-9][0-9]*\) MB available.*/\1/p')
    m_total=$(printf '%s' "$MEM_LINE" | sed -n 's/.*with \([0-9][0-9]*\) MB of memory.*/\1/p')
    if [ -n "$m_used" ] && [ -n "$m_total" ]; then
        echo "  显存占用 : ${m_used} MB / ${m_total} MB（可用 ${m_avail:-?} MB，占总量 $(awk -v u="$m_used" -v t="$m_total" 'BEGIN{ if (t>0) printf "%.1f", u*100/t; else printf "?" }')%）"
    fi
fi

if [ -n "$SAMPLES" ]; then
    printf '%s' "$SAMPLES" | awk -F',' '
        { t=$1+0; p=$2+0; u=$3+0;
          if (t>maxt) maxt=t;
          if (p>maxp) maxp=p;
          if (u>maxu) maxu=u;
          n++ }
        END {
            if (n>0)
                printf "  最高温度 : %d ℃\n  峰值功耗 : %.1f W\n  最高利用率 : %d %%\n  采样次数 : %d\n",
                       maxt, maxp, maxu, n
            else
                printf "  未采到有效读数\n"
        }'
else
    echo -e "  ${YELLOW}[WARN]${NC} 没采到数据（卡可能中途掉了）"
fi

# ---------- 判定 ----------
echo ""
if [ "$BURN_RC" -eq 0 ] && ! printf '%s' "$BURN_OUT" | grep -qiE 'faulty|error|fail'; then
    echo -e "${GREEN}【判定】PASS${NC} —— 压测完成，gpu-burn 报 OK"
    exit 0
else
    echo -e "${RED}【判定】FAIL${NC} —— gpu-burn 退出码 ${BURN_RC}，或输出含异常关键字"
    echo "  输出末尾："
    printf '%s' "$BURN_OUT" | tail -n 5 | sed 's/^/    /'
    exit 1
fi
