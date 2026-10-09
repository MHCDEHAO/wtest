#!/bin/bash
# ============================================================
# dcpower.sh —— 服务器 DC 电源循环（DC Power Cycle）测试
#               每轮记录启动报错 + 与基线做配置漂移比对
#
# ---- 一、怎么用（先看这段，其余都是细节） ----
#
#   【1】本机模式：脚本跑在被测机上，靠 systemd 服务每次重启后自动续跑
#         sudo bash dcpower.sh --local
#         · 不给 --bmc 时走本地 KVM 接口（ipmitool -I open），会提示一句
#         · 若被测机 BMC 是独立网口、-I open 用不了，补上：
#               sudo bash dcpower.sh --local --bmc 10.10.10.20 -U admin -P 'xxx'
#
#   【2】控制机模式（推荐）：脚本跑在控制机上，SSH 采集 + BMC 控电
#         sudo bash dcpower.sh --dut root@10.10.10.21 --bmc 10.10.10.20 \
#              -U admin -P 'xxx'
#         · 这条模式下 --bmc 必须给，否则直接报错退出
#         · 前提：控制机已配好到被测机的 ssh 免密登录
#
#   【3】一次都不用回车（免交互）：工号/SN/密码都放环境变量
#         export IPMI_USER=admin IPMI_PASS='xxx'
#         export TEST_ID=A12345 SERVER_SN=SN0001
#         sudo -E bash dcpower.sh --dut root@10.10.10.21 --bmc 10.10.10.20
#         · 走环境变量还有个好处：密码不会留在 shell history 里
#
#   【4】存个别名，以后只敲一个词
#         alias dcp='sudo -E bash /root/dcpower.sh --dut root@10.10.10.21 --bmc 10.10.10.20'
#         dcp -n 10
#
#   【5】其他常用场景（在【1】【2】的命令后面追加即可）
#         ... --dry-run -n 2       先演练：不断电，只把 SSH / BMC / 解析链路跑通
#         ... -n 0 -o /root/base   只抓一轮基线存起来，以后用 -b 指过去长期对比
#         ... --list               免 root 只读巡检：BMC 通不通、当前设备与链路摘要
#         ... --uninstall          清掉本机模式留下的续跑服务
#
#   ★ 真正必须给的只有 3 个：--dut（去哪采）、--bmc（去哪断电）、-n（断几次）。
#     工号与 SN 启动后会交互询问；其余参数全都有默认值，不写也能跑。
#
# ---- 二、参数一览（按「要不要给」分组） ----
#
#   【必给】
#     --dut root@IP       被测机 SSH 地址，采集从这里拿。本机模式不用给
#     --bmc IP            被测机 BMC 地址，控电走带外。控制机模式必给
#     --local             在被测机本机跑（靠 systemd 续跑）。与 --dut 互斥
#
#   【建议给】
#     -U / --bmc-user U   BMC 账号；不给则读环境变量 IPMI_USER
#     -P / --bmc-pass P   BMC 密码；不给则读环境变量 IPMI_PASS
#     --engineer ID       测试人员工号；等同环境变量 TEST_ID
#     --sn SN             服务器 SN；等同环境变量 SERVER_SN
#                         ★ 所有产物文件名都以 SN 开头，便于多台机器区分
#
#   【有默认值，通常不用给】
#     -n N                断电次数（默认 10）。轮次 = round-00(基线) + round-01..NN
#     -d S                断电保持秒数（默认 30）—— 让 PSU 电容彻底放掉
#     -w S                上电后等就绪的最长秒数（默认 420）
#     -s S                就绪后再稳定 S 秒才抓快照（默认 20，保证抓取时机一致）
#     -o DIR              输出目录（默认 ./<SN>_dcpower.log）
#     -b DIR              指定历史基线目录（默认用本轮的 round-00）
#     -I IFACE            BMC 接口（默认 lanplus；老机器可能要 -I lan）
#     --power-mode M      默认 off-on（断电 -> 等 -> 上电），另一选项 cycle
#
#   【先别管：判定调优，首次跑不需要】
#     --err-ignore RE     忽略匹配该正则的错误行（可多次），滤掉已知良性噪声
#     --err-soft          报错只记录、不判 FAIL。首次跑建议先用它摸清本机噪声底
#     --strict-pcie       GPU 当前链路速率也参与比对
#                         （默认忽略 —— GPU 空闲会自动降速，会误判）
#     --fan-tol P         风扇差值的提示线（默认 20，仅标注，不影响判定）
#
#   【模式开关】
#     --dry-run           不断电，只把采集 + 比对链路跑通
#     --list / -l         免 root 只读巡检：BMC 通不通、当前设备与链路摘要
#     --resume            本机模式重启后续跑（由 systemd 调起，不用手敲）
#     --uninstall         清理本机模式的续跑服务
#     -h / --help         打印本段帮助
#
# ---- 三、环境变量 ----
#     TEST_ID / SERVER_SN     测试人员工号 / 服务器 SN（免交互传入）
#     IPMI_USER / IPMI_PASS   BMC 账号密码（不写 -U/-P 时读这里，避免明文进 history）
#     DUT_SSH_OPTS            追加给 ssh 的参数
#                             默认 "-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
#
# ---- 四、它做什么 ----
#   循环 N 次「硬断电 -> 保持 d 秒 -> 上电 -> 等系统就绪」，每轮抓两份东西：
#     ① 报错：内核 err / 服务 err / systemctl --failed / BMC SEL 新增
#             / PCIe AER / GPU Xid / MCE
#     ② 配置：设备在位（CPU 内存 硬盘 显卡 网卡 阵列卡 电源 风扇 的数量与身份键）
#             + PCIe 链路枚举（能力 vs 当前 速率/宽度）
#             + 风扇转速（与基线、与上一轮的差值，仅记录不判定）
#   然后统一与【基线（round-00，跑测试前的原始状态）】比对，
#   给出 PASS / FAIL / Pending —— 与《服务器整机验收记录表》同一套三态口径。
#   每一轮的对比全部汇总在 <SN>_compare.txt 一个文件里。
#
#   ★ 明确不比对：固件版本、驱动版本。
#
# ---- 五、判定口径与退出码 ----
#   PASS     本轮无新增报错，设备在位与 PCIe 链路和基线完全一致
#   FAIL     有新增报错，或设备数量/身份键漂移，或 PCIe 链路相对基线退化
#            （风扇转速只记录，不参与判定）
#   Pending  这一轮没抓到数据（系统没起来 / SSH 不通 / 超时）—— 不代表机器坏，
#            但必须人工看 round-NN 目录和 BMC SEL 才能定性
#
#   退出码：0 = 全部 PASS   1 = 有 FAIL（或一轮都没抓到）   2 = 用法错误
#
# ---- 六、产物（文件名一律以 SN 开头） ----
#   <SN>_dcpower.log/                    默认输出目录（-o 可改）
#   ├── <SN>_dcpower_report.txt          总报告：逐轮判定表 + 逐轮原因 + 结论
#   ├── <SN>_compare.txt                 ★ 所有轮次与基线的对比，全在这一个文件
#   ├── <SN>_run.log                     运行过程日志
#   └── round-NN/                        每轮：raw/ 原始证据 + 4 张表 + meta/summary
#       原始证据一律保留、不自动清理 —— 验收要的是可复查的凭据。
#
# ---- 七、设计说明（想知道「为什么这么设计」再看） ----
#
#   ★ 为什么默认跑在【控制机】上，而不是被测机上：
#       DC 断电会把被测机整台断掉，脚本跑在被测机上就会把自己杀掉；
#       更麻烦的是被测机万一「起不来」，本地脚本永远等不到下一轮，现场零记录。
#       跑在控制机上，控制机全程不断电，才能把「起不来」这一轮也记下来。
#       实在没有第二台机器时用 --local（在被测机上跑，靠 systemd 服务续跑），
#       代价是被测机卡在启动阶段时测试会停在那里，要人工介入。
#
#   ★ --local 的「重启后还会运行」靠三道闸保证（任何一道不过就拒绝断电、exit 2）：
#       闸1  装完 dcpower-resume.service 必须 systemctl is-enabled --quiet 真验一次。
#            原来 enable 失败也被 `|| true` 吞掉、还无条件报「已安装」——
#            那是断电后回不来的直接原因。
#       闸2  schedule_power_off 的返回码必须可信。调度不上就报错退出，
#            绝不能让机器不断电、测试静默停住。
#       闸3  .state 先写 .state.tmp 再 mv（原子替换）；--resume 侧校验关键变量。
#            否则断电正好落在写入中间会把文件截断，重启后 source 到空值、
#            又因为没 set -e 一路跑下去，错误极难倒查。
#       另：.state 里的 RESUME_N 是续跑服务被触发的次数，事后可据此确认它真的跑过；
#           跑满 LOOPS 那一轮也会落一次 .state（DONE=1），现场看到 DONE=1 即已跑完。
#
#   ★ 风扇转速：只记录，不参与 PASS/FAIL 判定（2026-09-22 明确要求）
#       转速由 BMC 按温度闭环调速，受进风温度和调速档位跳变影响，两轮之间必然不同，
#       拿它判合格会产生大量假 FAIL。所以每轮只把差值记下来，供人工判断：
#         与【基线】比  ：相差多少 RPM / 百分之多少
#         与【上一轮】比：相差多少 RPM / 百分之多少
#       0 转、无读数同样只标注，不判 FAIL。
#       --fan-tol（默认 20）只当提示线：超过就在记录里标「<- 超 20%」方便一眼扫到，
#       不影响判定结果。
#       ★ 万一以后要改成判 FAIL，注意方向：转速【下降】才是风扇受损的信号，
#         转速【上升】通常只是机器更热 / BMC 主动加档，不该判不合格。
# ============================================================

set -u

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
if [ ! -t 1 ]; then BLUE=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; fi

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${CYAN}   $1${NC}"; }
# 按「显示宽度」补齐再输出（中英混排表格对齐用）。
# UTF-8 下按字节估算：ASCII 1 列，3 字节的汉字 2 列。
pad() {
    local s="$1" w="$2" b a n
    b=$(printf '%s' "$s" | wc -c)
    a=$(printf '%s' "$s" | tr -d '\000-\177' | wc -c)
    n=$(( b - a + a / 3 * 2 ))
    printf '%s' "$s"
    while [ "$n" -lt "$w" ]; do printf ' '; n=$((n + 1)); done
    # 分隔符：内容正好等于列宽时不至于和下一列粘连（如 "100.0%/停1" + "FAIL"）
    printf ' '
}

usage() {
    awk 'NR==1{next} !s{if($0 ~ /^# ===/){s=1} next} /^# ===/{exit} {sub(/^# ?/,"");print}' "$0"
}

# ------------------------------------------------------------
# 测试人员工号 / 服务器 SN 输入（与 lhtest.sh 同一套范式）
#   优先读环境变量 TEST_ID / SERVER_SN，其次交互输入。
#   非交互（管道）时从 stdin 读一行：工号空则 unknown，SN 空则报错退出。
# ------------------------------------------------------------
get_testid() {
    if [ -n "${TEST_ID}" ]; then
        testid="${TEST_ID}"
        echo "使用环境变量工号: ${testid}"
        return
    fi
    if [ ! -t 0 ]; then
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

get_sn() {
    if [ -n "${SERVER_SN}" ]; then
        SN="${SERVER_SN}"
        echo "使用环境变量SN: ${SN}"
        return
    fi
    if [ ! -t 0 ]; then
        read -r SN
        if [ -z "${SN}" ]; then
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


# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------
LOOPS=10
OFF_DELAY=30
BOOT_TIMEOUT=420
SETTLE=20
OUTDIR=""
BASELINE=""
DUT=""
BMC_HOST=""
BMC_USER="${IPMI_USER:-}"
BMC_PASS="${IPMI_PASS:-}"
BMC_INTF="lanplus"
POWER_MODE="off-on"
LOCAL=0
RESUME=0
DRY_RUN=0
DO_LIST=0
DO_UNINSTALL=0
ERR_SOFT=0
STRICT_PCIE=0
FAN_TOL=20
DUT_SSH_OPTS="${DUT_SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8}"
ERR_IGNORE=()
FAN_MAX="-"; FAN_STOP=0
: "${TEST_ID:=}"
: "${SERVER_SN:=}"
SN=""
testid=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        -l|--list)      DO_LIST=1; shift ;;
        --uninstall)    DO_UNINSTALL=1; shift ;;
        -n|--loops)     LOOPS="${2:-}"; shift 2 ;;
        -d|--off-delay) OFF_DELAY="${2:-}"; shift 2 ;;
        -w|--boot-timeout) BOOT_TIMEOUT="${2:-}"; shift 2 ;;
        -s|--settle)    SETTLE="${2:-}"; shift 2 ;;
        -o|--outdir)    OUTDIR="${2:-}"; shift 2 ;;
        -b|--baseline)  BASELINE="${2:-}"; shift 2 ;;
        --sn)           SERVER_SN="${2:-}"; shift 2 ;;
        --engineer)     TEST_ID="${2:-}"; shift 2 ;;
        --dut)          DUT="${2:-}"; shift 2 ;;
        --bmc)          BMC_HOST="${2:-}"; shift 2 ;;
        -U|--bmc-user)  BMC_USER="${2:-}"; shift 2 ;;
        -P|--bmc-pass)  BMC_PASS="${2:-}"; shift 2 ;;
        -I|--bmc-intf)  BMC_INTF="${2:-}"; shift 2 ;;
        --power-mode)   POWER_MODE="${2:-}"; shift 2 ;;
        --err-ignore)   ERR_IGNORE+=("${2:-}"); shift 2 ;;
        --fan-tol)      FAN_TOL="${2:-}"; shift 2 ;;
        --local)        LOCAL=1; shift ;;
        --resume)       RESUME=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --err-soft)     ERR_SOFT=1; shift ;;
        --strict-pcie)  STRICT_PCIE=1; shift ;;
        -*)             err "未知参数 $1"; usage; exit 2 ;;
        *)              err "多余的位置参数 $1"; usage; exit 2 ;;
    esac
done

case "$POWER_MODE" in
    off-on|cycle) ;;
    *) err "--power-mode 只能是 off-on 或 cycle"; exit 2 ;;
esac
case "$LOOPS" in
    ''|*[!0-9]*) err "-n 必须是数字"; exit 2 ;;
esac
# --local 是「脚本跑在被测机本机」，--dut 是「脚本跑在控制机、SSH 过去采集」
# —— 语义互斥。同时给的话：首轮按 --dut 远程采集，断电续跑后 .state 里
# DUT 为空、改成本机采集，前后口径不一致，且很难察觉。直接拦掉。
if [ "$LOCAL" = "1" ] && [ -n "$DUT" ]; then
    err "--local 与 --dut 不能同时用"
    info "--local：脚本跑在被测机上（靠 systemd 续跑）；--dut root@IP：脚本跑在控制机上，SSH 过去采集"
    exit 1
fi

# ------------------------------------------------------------
# 目标机命令执行（远程走 ssh，本机直接跑）
# ------------------------------------------------------------
rrun() {
    if [ -n "$DUT" ]; then
        ssh $DUT_SSH_OPTS "$DUT" "$1" 2>/dev/null
    else
        bash -c "$1" 2>/dev/null
    fi
}
rhave() { rrun "command -v $1 >/dev/null 2>&1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# BMC 侧命令（远程模式在控制机上跑，本机模式在被测机上跑）
# ------------------------------------------------------------
IPMI_PW=()
ipmi() {
    if [ -n "$BMC_HOST" ]; then
        ipmitool -I "$BMC_INTF" -H "$BMC_HOST" -U "$BMC_USER" "${IPMI_PW[@]}" "$@"
    else
        ipmitool -I open "$@"
    fi
}

# ------------------------------------------------------------
# 目标机采集子脚本（由主脚本生成到 <OUTDIR>/.dump.sh）
# 所有原始证据都留档，解析全部在本地做 —— 便于事后复查
# ------------------------------------------------------------
write_dump_script() {
    cat > "$1" <<'DUMPEOF'
#!/bin/bash
# dcpower.sh 的目标机采集子脚本（主脚本生成，不要单独改）
# 用法：bash <本脚本> <输出目录>
set -u
O="${1:?需要输出目录}"
mkdir -p "$O" || exit 1
cd "$O" || exit 1

cap()   { local f="$1"; shift; "$@" > "$f" 2>&1 || true; }
capsh() { local f="$1"; shift; bash -c "$*" > "$f" 2>&1 || true; }
have()  { command -v "$1" >/dev/null 2>&1; }

# ---- 1. 整机 / 主板 / CPU / 内存 ----
have lscpu     && cap lscpu.txt lscpu
have dmidecode && cap dmidecode-processor.txt dmidecode -t processor
have dmidecode && cap dmidecode-memory.txt dmidecode -t memory
have dmidecode && cap dmidecode-system.txt dmidecode -t system
have dmidecode && cap dmidecode-baseboard.txt dmidecode -t baseboard
have dmidecode && cap dmidecode-bios.txt dmidecode -t bios

# ---- 2. PCIe 枚举（与 pcie.sh 同一套 lspci 口径）----
have lspci && cap lspci-D.txt lspci -D
have lspci && cap lspci-Dnn.txt lspci -Dnn
have lspci && cap lspci-Dvvv.txt lspci -D -vvv
have lspci && cap lspci-tv.txt lspci -tv
# sysfs 侧链路速率/宽度（lspci 读不到时的兜底）
capsh sysfs-pcie.tsv 'v(){ local x; x=$(cat "$1" 2>/dev/null); printf "%s" "${x:--}"; }; for d in /sys/bus/pci/devices/*; do [ -e "$d" ] || continue; b=${d##*/}; printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$b" "$(v $d/class)" "$(v $d/current_link_speed)" "$(v $d/current_link_width)" "$(v $d/max_link_speed)" "$(v $d/max_link_width)"; done'
# AER 计数器（掉电即清零，所以只看有没有非零）
capsh sysfs-aer.tsv 'for d in /sys/bus/pci/devices/*; do [ -e "$d" ] || continue; b=${d##*/}; c=$(cat $d/aer_dev_correctable 2>/dev/null | tr "\n" ";"); u=$(cat $d/aer_dev_uncorrectable 2>/dev/null | tr "\n" ";"); [ -z "$c$u" ] && continue; printf "%s\t%s\t%s\n" "$b" "${c:--}" "${u:--}"; done'

# ---- 3. 存储 ----
have lsblk && cap lsblk.txt lsblk -dPno NAME,SIZE,TYPE,MODEL,SERIAL,WWN,TRAN
have nvme  && cap nvme-list.txt nvme list
have nvme  && capsh nvme-smart.txt 'for n in /dev/nvme*n1; do [ -e "$n" ] || continue; echo "== $n"; nvme smart-log "$n" 2>/dev/null | grep -iE "unsafe|power_cycles|power_on_hours|critical_warning|media_errors"; done'
capsh sysfs-nvme.tsv 'v(){ local x; x=$(cat "$1" 2>/dev/null); printf "%s" "${x:--}"; }; for n in /sys/class/nvme/nvme*; do [ -d "$n" ] || continue; printf "%s\t%s\t%s\t%s\n" "${n##*/}" "$(v $n/serial)" "$(v $n/model)" "$(v $n/address)"; done'
have storcli && cap storcli-ctrl.txt storcli /cALL show
have storcli && cap storcli-pd.txt storcli /cALL/eALL/sALL show
have megacli  && cap megacli-pd.txt megacli -PDList -aALL

# ---- 4. 网络 ----
have ip && cap ip-link.txt ip -o link show
have ibstat && cap ibstat.txt ibstat
have ibv_devinfo && cap ibv-devinfo.txt ibv_devinfo
capsh sysfs-net.tsv 'v(){ local x; x=$(cat "$1" 2>/dev/null); printf "%s" "${x:--}"; }; for n in /sys/class/net/*; do [ -d "$n" ] || continue; i=${n##*/}; [ "$i" = "lo" ] && continue; d=$(readlink -f "$n/device" 2>/dev/null); [ -n "$d" ] || continue; printf "%s\t%s\t%s\t%s\n" "$i" "$(v $n/address)" "$(v $n/perm_address)" "${d##*/}"; done'
capsh sysfs-ib.tsv 'v(){ local x; x=$(cat "$1" 2>/dev/null); printf "%s" "${x:--}"; }; for n in /sys/class/infiniband/*; do [ -d "$n" ] || continue; c=${n##*/}; ng=$(v $n/node_guid); d=$(readlink -f "$n/device" 2>/dev/null); for p in "$n"/ports/*; do [ -d "$p" ] || continue; printf "%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$c" "${p##*/}" "$ng" "$(v $p/rate)" "$(v $p/state)" "$(v $p/phys_state)" "${d##*/}"; done; done'

# ---- 5. GPU ----
have nvidia-smi && capsh nvidia-smi-gpu.txt 'nvidia-smi --query-gpu=index,name,serial,uuid,pci.bus_id --format=csv'
have nvidia-smi && capsh nvidia-smi-pcie.txt 'nvidia-smi --query-gpu=index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv'
have nvidia-smi && cap nvidia-smi-topo.txt nvidia-smi topo -m
have nvidia-smi && capsh nvidia-smi-xid.txt 'nvidia-smi -q | grep -iE "Xid|Retired|Pending|Remapped Rows" | head -40'

# ---- 6. 报错与日志 ----
capsh journal-kernel.txt        'journalctl -k -b 0  -p err -o short-iso --no-pager 2>/dev/null | tail -200'
capsh journal-service.txt       'journalctl    -b 0  -p err -o short-iso --no-pager 2>/dev/null | tail -200'
capsh journal-prev-kernel.txt   'journalctl -k -b -1 -p err -o short-iso --no-pager 2>/dev/null | tail -200'
capsh journal-prev-service.txt  'journalctl    -b -1 -p err -o short-iso --no-pager 2>/dev/null | tail -200'
capsh systemctl-failed.txt      'systemctl --failed --no-legend --no-pager 2>/dev/null'
capsh dmesg-err.txt             'dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -200'
capsh dmesg-aer.txt             'dmesg 2>/dev/null | grep -iE "AER|PCIe Bus Error|Corrected error|Uncorrected" | tail -100'
capsh dmesg-mce.txt             'dmesg 2>/dev/null | grep -iE "Machine Check|mce:|Hardware Error" | tail -50'
capsh dmesg-xid.txt             'dmesg 2>/dev/null | grep -iE "NVRM.*Xid|NVRM.*error" | tail -50'
capsh journal-persist.txt       'ls -d /var/log/journal >/dev/null 2>&1 && echo "OK: /var/log/journal 存在，journal 持久化" || echo "MISSING: /var/log/journal 不存在，journal 不持久化（重启后 journalctl -b -1 读不到上一轮）"'
capsh bootinfo.txt              'date -Is; uptime; cat /proc/uptime; cat /proc/sys/kernel/random/boot_id'

exit 0
DUMPEOF
    chmod +x "$1" 2>/dev/null || true
}

# ------------------------------------------------------------
# 采集：目标机 OS 侧
# ------------------------------------------------------------
collect_raw() {
    local dest="$1"
    mkdir -p "$dest"
    if [ -n "$DUT" ]; then
        local rtmp="/tmp/dcpower-raw-$$-$RANDOM"
        ssh $DUT_SSH_OPTS "$DUT" "bash -s" "$rtmp" < "$DUMP_SH" >/dev/null 2>&1 || true
        ssh $DUT_SSH_OPTS "$DUT" "cd '$rtmp' 2>/dev/null && tar czf - . ; cd /tmp && rm -rf '$rtmp'" \
            > "$dest/.raw.tar.gz" 2>/dev/null || true
        if [ -s "$dest/.raw.tar.gz" ]; then
            tar xzf "$dest/.raw.tar.gz" -C "$dest" 2>/dev/null || true
        else
            warn "从 $DUT 拉取原始证据失败（SSH 或 tar 有问题）"
            rm -f "$dest/.raw.tar.gz"
            return 1
        fi
        rm -f "$dest/.raw.tar.gz"
    else
        bash "$DUMP_SH" "$dest" >/dev/null 2>&1 || true
    fi
    return 0
}

# ------------------------------------------------------------
# 采集：BMC 侧（走带外，和 OS 是否起来无关）
# ------------------------------------------------------------
collect_bmc() {
    local r="$1"
    mkdir -p "$r"
    ipmi sel list                     > "$r/ipmitool-sel.txt"        2>&1 || true
    ipmi sdr type "Power Supply"      > "$r/ipmitool-sdr-psu.txt"    2>&1 || true
    ipmi sdr type "Power Unit"        > "$r/ipmitool-sdr-punit.txt"  2>&1 || true
    ipmi sdr type "Fan"               > "$r/ipmitool-sdr-fan.txt"    2>&1 || true
    ipmi sdr type "Cooling Device"    > "$r/ipmitool-sdr-cooling.txt" 2>&1 || true
    ipmi sdr type "Processor"         > "$r/ipmitool-sdr-proc.txt"   2>&1 || true
    ipmi sdr type "Memory"            > "$r/ipmitool-sdr-mem.txt"    2>&1 || true
    ipmi sdr type "Drive Slot / Bay"  > "$r/ipmitool-sdr-drive.txt"  2>&1 || true
    ipmi sdr type "Slot / Connector"  > "$r/ipmitool-sdr-slot.txt"   2>&1 || true
    ipmi chassis status               > "$r/ipmitool-chassis.txt"    2>&1 || true
    ipmi chassis restart_cause        > "$r/ipmitool-restart.txt"    2>&1 || true
    ipmi fru                          > "$r/ipmitool-fru.txt"        2>&1 || true
    ipmi mc info                      > "$r/ipmitool-mc.txt"         2>&1 || true
    ipmi dcmi power reading           > "$r/ipmitool-dcmi.txt"       2>&1 || true
}

# ------------------------------------------------------------
# 解析工具
# ------------------------------------------------------------
CUR_DEV=""; CUR_MAP=""
emit_dev() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CUR_DEV"; }
emit_map() { [ -n "$2" ] && printf '%s\t%s\n' "$1" "$2" >> "$CUR_MAP"; }

# nvidia-smi 给的是 00000000:01:00.0，lspci 给的是 0000:01:00.0，统一成后者
norm_bdf() {
    awk -F: '{ d=$1; printf "%s:%s:%s\n", substr(d, length(d)-3), $2, $3 }' <<< "$1"
}
# 身份键里可能出现制表符/空值，统一清洗
clean_key() { printf '%s' "${1:-}" | tr '\t' ' ' | sed -e 's/^[ ]*//' -e 's/[ ]*$//'; }

# ---------- CPU（dmidecode 优先，lscpu 兜底） ----------
parse_cpu() {
    local r="$1" tmp
    local raw="$r/dmidecode-processor.txt"
    tmp=$(mktemp)
    if [ -s "$raw" ] && grep -q 'Processor Information' "$raw" 2>/dev/null; then
        awk '
            function flush() {
                if (sock != "" ) printf "CPU\t%s\t%s cores=%s threads=%s\n", sock, ver, core, thr
                sock=""; ver=""; core=""; thr=""
            }
            /^Processor Information/ { flush(); blk=1; next }
            /^[^ \t]/ { if (blk) { flush(); blk=0 } }
            blk {
                line=$0; sub(/^[ \t]+/, "", line)
                p=index(line, ": "); if (p==0) next
                k=substr(line,1,p-1); v=substr(line,p+2)
                if (k=="Socket Designation") sock=v
                else if (k=="Version") ver=v
                else if (k=="Core Count") core=v
                else if (k=="Thread Count") thr=v
            }
            END { flush() }
        ' "$raw" >> "$tmp"
    fi
    if [ ! -s "$tmp" ]; then
        # 兜底：lscpu 只给总数，按 Socket#1..N 造身份键
        local n model i
        n=$(awk -F: '/^Socket\(s\)/{gsub(/[ \t]/,"",$2); print $2}' "$r/lscpu.txt" 2>/dev/null)
        model=$(awk -F: '/^Model name/{sub(/^[ \t]+/,"",$2); print $2}' "$r/lscpu.txt" 2>/dev/null)
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        i=1
        while [ "$i" -le "$n" ]; do
            printf 'CPU\tSocket#%s\t%s (来源:lscpu)\n' "$i" "$(clean_key "$model")" >> "$tmp"
            i=$((i + 1))
        done
    fi
    sort -u "$tmp" >> "$CUR_DEV"
    rm -f "$tmp"
}

# ---------- 内存（身份键 = Locator，槽位稳定） ----------
parse_dimm() {
    local raw="$1/dmidecode-memory.txt"
    [ -s "$raw" ] || return 0
    awk '
        function flush() {
            if (loc != "" && sz != "" && sz !~ /No Module Installed|Not Installed|^0 /)
                printf "DIMM\t%s\t%s %s %s %s %s\n", loc, sz, typ, spd, mfr, pn
            loc=""; sz=""; typ=""; spd=""; mfr=""; pn=""; blk=0
        }
        /^Memory Device$/ { flush(); blk=1; next }
        /^[^ \t]/ { if (blk) flush() }
        blk {
            line=$0; sub(/^[ \t]+/, "", line)
            p=index(line, ": "); if (p==0) next
            k=substr(line,1,p-1); v=substr(line,p+2)
            if (k=="Size") sz=v
            else if (k=="Locator") loc=v
            else if (k=="Type") typ=v
            else if (k=="Speed") spd=v
            else if (k=="Manufacturer") mfr=v
            else if (k=="Part Number") pn=v
        }
        END { flush() }
    ' "$raw" | sort -u >> "$CUR_DEV"
}

# ---------- GPU（身份键 = serial，缺失回退 uuid） ----------
parse_gpu() {
    local r="$1"
    local raw="$r/nvidia-smi-gpu.txt"
    if [ -s "$raw" ]; then
        tail -n +2 "$raw" | awk -F', ' '
            NF>=5 {
                gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $4)
                gsub(/^[ \t]+|[ \t]+$/, "", $5); gsub(/^[ \t]+|[ \t]+$/, "", $2)
                key = ($3 != "" && $3 != "N/A") ? $3 : $4
                printf "GPU\t%s\t%s bus=%s idx=%s\n", key, $2, $5, $1
            }' | sort -u >> "$CUR_DEV"
        tail -n +2 "$raw" | awk -F', ' '
            function nb(x,   p, d) {
                p=index(x, ":"); if (p==0) return x
                d=substr(x, 1, p-1)
                return substr(d, length(d)-3) ":" substr(x, p+1)
            }
            NF>=5 {
                s=$3; gsub(/^[ \t]+|[ \t]+$/, "", s)
                u=$4; gsub(/^[ \t]+|[ \t]+$/, "", u)
                b=$5; gsub(/^[ \t]+|[ \t]+$/, "", b)
                key = (s != "" && s != "N/A") ? s : u
                printf "%s\tGPU:%s\n", nb(b), key
            }' >> "$CUR_MAP"
    fi
}

# ---------- NVMe（身份键 = 盘序列号） ----------
parse_nvme() {
    local r="$1"
    local raw="$r/sysfs-nvme.tsv"
    [ -s "$raw" ] || return 0
    while IFS=$'\t' read -r ctl sn model addr; do
        [ -n "${ctl:-}" ] || continue
        case "${sn:-}" in ""|-|N/A) sn="$ctl" ;; esac
        case "${model:-}" in -|N/A) model="" ;; esac
        case "${addr:-}" in -) addr="" ;; esac
        printf 'NVMe\t%s\t%s ctl=%s\n' "$(clean_key "$sn")" "$(clean_key "$model")" "$ctl" >> "$CUR_DEV"
        emit_map "$(norm_bdf "${addr:-}")" "NVME:$(clean_key "$sn")"
    done < "$raw"
    sort -u "$CUR_DEV" -o "$CUR_DEV"
}

# ---------- 块设备（身份键 = WWN 或 SERIAL） ----------
parse_block() {
    local raw="$1/lsblk.txt"
    [ -s "$raw" ] || return 0
    awk '
        function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
        {
            s=$0; delete f
            while (match(s, /[A-Z-]+="/)) {
                k=substr(s, RSTART, RLENGTH-2)
                rest=substr(s, RSTART+RLENGTH)
                q=index(rest, "\"")
                if (q==0) break
                f[k]=substr(rest, 1, q-1)
                s=substr(rest, q+1)
            }
            name=trim(f["NAME"]); if (name=="") next
            size=trim(f["SIZE"]); typ=trim(f["TYPE"]); model=trim(f["MODEL"])
            ser=trim(f["SERIAL"]); wwn=trim(f["WWN"]); tran=trim(f["TRAN"])
            if (wwn != "" && wwn != "-") key="WWN:" wwn
            else if (ser != "" && ser != "-") key="SN:" ser
            else key="DEV:" name
            printf "Block\t%s\t%s %s %s model=%s tran=%s\n", key, name, size, typ, model, tran
        }' "$raw" | sort -u >> "$CUR_DEV"
}

# ---------- 网卡 / IB 口（身份键 = 永久 MAC / node_guid:port） ----------
parse_net() {
    local r="$1" line
    local raw="$r/sysfs-net.tsv"
    if [ -s "$raw" ]; then
        while IFS=$'\t' read -r ifname mac pmac bdf; do
            [ -n "${ifname:-}" ] || continue
            case "${mac:-}"  in -) mac=""  ;; esac
            case "${pmac:-}" in -) pmac="" ;; esac
            case "${bdf:-}"  in -) bdf=""  ;; esac
            local key="$pmac"
            [ -n "$key" ] || key="$mac"
            [ -n "$key" ] || key="IF:$ifname"
            printf 'NIC\t%s\t%s mac=%s bdf=%s\n' "$(clean_key "$key")" "$ifname" "$(clean_key "$mac")" "$bdf" >> "$CUR_DEV"
            emit_map "$(norm_bdf "${bdf:-}")" "NIC:$(clean_key "$key")"
        done < "$raw"
        sort -u "$CUR_DEV" -o "$CUR_DEV"
    fi
    raw="$r/sysfs-ib.tsv"
    if [ -s "$raw" ]; then
        # 采集侧每行 6 列：CA/端口   node_guid   速率   状态   物理状态   BDF
        # 身份键用 node_guid + 端口号 —— 双口卡两个口共用 node_guid，只靠 guid 会撞键
        while IFS=$'\t' read -r capfull guid rate st phys bdf; do
            [ -n "${capfull:-}" ] || continue
            case "${guid:-}" in -|"") guid="CA:$capfull" ;; esac
            case "${bdf:-}"  in -) bdf="" ;; esac
            pnum="${capfull##*/}"
            printf 'IB\t%s/%s\t%s 速率=%s 状态=%s %s bdf=%s\n' \
                "$(clean_key "$guid")" "$pnum" "$capfull" "$rate" "$st" "$phys" "$bdf" >> "$CUR_DEV"
            emit_map "$(norm_bdf "${bdf:-}")" "IB:$(clean_key "$guid")/$pnum"
        done < "$raw"
        sort -u "$CUR_DEV" -o "$CUR_DEV"
    fi
}

# ---------- 阵列卡（storcli 优先，lspci 兜底） ----------
parse_raid() {
    local r="$1"
    local raw="$r/storcli-ctrl.txt"
    if [ -s "$raw" ] && ! grep -qiE '^CLI Version|not found|No Controller' "$raw"; then
        awk '
            /^Controller =/ { ctl=$3 }
            /^Product Name/ { sub(/^Product Name[ \t]*=[ \t]*/,""); pn=$0 }
            /^Serial Number/ { sub(/^Serial Number[ \t]*=[ \t]*/,""); sn=$0
                if (sn != "" && sn != "N/A") printf "RAID\t%s\t%s ctl=%s\n", sn, pn, ctl
                sn="" }
        ' "$raw" | sort -u >> "$CUR_DEV"
    fi
    # lspci 口径的 RAID/SAS 控制器计数在 build_counts 里补
}

# ---------- PSU / 风扇 / IPMI 层面在位（带外，独立于 OS） ----------
parse_ipmi() {
    local r="$1" f
    # PSU：Power Supply 传感器报 "Presence detected" 才算在位
    f="$r/ipmitool-sdr-psu.txt"
    if [ -s "$f" ]; then
        awk -F'|' '
            NF>=5 {
                n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n); sub(/[ \t]*Status$/,"",n)
                s=$3; gsub(/^[ \t]+|[ \t]+$/, "", s)
                v=$5; gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (n=="" || n ~ /^Error|Unable/) next
                if (v ~ /Presence detected/) printf "PSU\t%s\t%s %s\n", n, s, v
            }' "$f" | sort -u >> "$CUR_DEV"
    fi
    # 风扇转速：单独落 fans.tsv
    f="$r/ipmitool-sdr-fan.txt"
    if [ -s "$f" ]; then
        awk -F'|' '
            NF>=5 {
                n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n)
                s=$3; gsub(/^[ \t]+|[ \t]+$/, "", s)
                v=$5; gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (n=="" || n ~ /^Error|Unable/) next
                rpm=""; if (match(v, /[0-9]+/)) rpm=substr(v, RSTART, RLENGTH)
                printf "%s\t%s\t%s\n", n, s, rpm
            }' "$f" | sort -u > "$2"
        # 风扇身份键进 devices.tsv，数量才算得出来
        awk -F'\t' '{ printf "Fan\t%s\t状态=%s\n", $1, $2 }' "$2" | sort -u >> "$CUR_DEV"
    fi
    # CPU / 内存 / 硬盘槽位 —— 带外看到的在位情况，和 OS 侧互为交叉验证
    local pair
    for pair in "ipmitool-sdr-proc.txt:CPU-IPMI" "ipmitool-sdr-mem.txt:DIMM-IPMI" "ipmitool-sdr-drive.txt:Drive-IPMI"; do
        f="$r/${pair%%:*}"
        [ -s "$f" ] || continue
        awk -F'|' -v cat="${pair##*:}" '
            NF>=5 {
                n=$1; gsub(/^[ \t]+|[ \t]+$/, "", n)
                v=$5; gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (n=="" || n ~ /^Error|Unable/) next
                if (v ~ /Presence detected|Drive Present|Present/) printf "%s\t%s\t%s\n", cat, n, v
            }' "$f" | sort -u >> "$CUR_DEV"
    done
}

# ------------------------------------------------------------
# PCIe 链路枚举（口径与 pcie.sh 一致：LnkCap / LnkSta）
# ------------------------------------------------------------
parse_pcie() {
    local d="$1"
    local r="$d/raw" out="$d/pcie.tsv"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "身份键" "当前速率" "当前宽度" "最大速率" "最大宽度" "BDF" "类别码" "AER非零" > "$out"

    local dvv="$r/lspci-Dvvv.txt" dnn="$r/lspci-Dnn.txt"
    [ -s "$dvv" ] || { warn "lspci -Dvvv 没抓到，PCIe 链路枚举为空"; return 0; }

    # 一次 awk 扫完全部设备：LnkCap / LnkSta（非缩进行 = 设备头，比 -A 40 更可靠）
    local linkf="$d/.pcielink"
    # 口径与 pcie.sh 完全一致（Speed [0-9.]+GT/s 与 Width x[0-9]+），
    # 但抽取放在 awk 里做 —— 原始行首带 TAB，直接输出整行会让 read 分列错位。
    awk '
        function spd(x,   r) { if (match(x, /Speed [0-9.]+GT\/s/)) return substr(x, RSTART+6, RLENGTH-6); return "" }
        function wid(x,   r) { if (match(x, /Width x[0-9]+/))     return substr(x, RSTART+6, RLENGTH-6);  return "" }
        /^[^ \t]/ { bdf=$1; next }
        bdf != "" && /LnkCap:/ { if (!(bdf in cap)) cap[bdf]=$0 }
        bdf != "" && /LnkSta:/ { if (!(bdf in sta)) sta[bdf]=$0 }
        END {
            for (b in cap) printf "%s\t%s\t%s\t%s\t%s\n", b, spd(cap[b]), wid(cap[b]), spd(sta[b]), wid(sta[b])
            for (b in sta) if (!(b in cap)) printf "%s\t%s\t%s\t%s\t%s\n", b, "", "", spd(sta[b]), wid(sta[b])
        }
    ' "$dvv" > "$linkf"

    # 类别码 / vendor:device（lspci -Dnn 口径）
    local clsf="$d/.pcicls"
    if [ -s "$dnn" ]; then
        awk '
            {
                bdf=$1
                rest=$0; sub(/^[^ \t]+[ \t]+/, "", rest)
                cls=""
                if (match(rest, /\[[0-9a-fA-F]+\]/)) cls=substr(rest, RSTART+1, RLENGTH-2)
                dev=""; s=rest
                while (match(s, /\[[0-9a-fA-F]+:[0-9a-fA-F]+\]/)) {
                    dev=substr(s, RSTART+1, RLENGTH-2)
                    s=substr(s, RSTART+RLENGTH)
                }
                printf "%s\t%s\t%s\n", bdf, cls, dev
            }' "$dnn" > "$clsf"
    else
        : > "$clsf"
    fi

    # AER 非零计数（掉电即清零，所以只关心有没有非零）
    local aerf="$d/.pcieaer"
    : > "$aerf"
    if [ -s "$r/sysfs-aer.tsv" ]; then
        while IFS=$'\t' read -r b c u; do
            [ -n "${b:-}" ] || continue
            local n
            n=$(printf '%s%s' "${c:-}" "${u:-}" | grep -oE '[1-9][0-9]*' | wc -l)
            [ "$n" -gt 0 ] && printf '%s\t%s\n' "$b" "有非零" >> "$aerf"
        done < "$r/sysfs-aer.tsv"
    fi

    while IFS=$'\t' read -r bdf cap_speed cap_width sta_speed sta_width; do
        [ -n "${bdf:-}" ] || continue
        local cls dev ident aer
        cap_speed=${cap_speed:-未知}; cap_width=${cap_width:-未知}
        sta_speed=${sta_speed:-未知}; sta_width=${sta_width:-未知}

        cls=$(awk -F'\t' -v b="$bdf" '$1==b{print $2}' "$clsf" 2>/dev/null | head -n1)
        dev=$(awk -F'\t' -v b="$bdf" '$1==b{print $3}' "$clsf" 2>/dev/null | head -n1)
        cls=${cls:-未知}; dev=${dev:-未知}

        # 身份键优先用序列号/GUID/MAC（BDF 会漂移，只作参考列）
        ident=$(awk -F'\t' -v b="$bdf" '$1==b{print $2}' "$CUR_MAP" 2>/dev/null | head -n1)
        [ -n "$ident" ] || ident="PCI:$cls:$dev"

        aer=$(awk -F'\t' -v b="$bdf" '$1==b{print $2}' "$aerf" 2>/dev/null | head -n1)
        aer=${aer:-无}

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ident" "$sta_speed" "$sta_width" "$cap_speed" "$cap_width" "$bdf" "$cls" "$aer" >> "$out"
    done < "$linkf"

    # 按身份键排序，保证两轮之间的行序一致（比对时还会再排一次）
    { head -n1 "$out"; tail -n +2 "$out" | sort -t$'\t' -k1,1 -k6,6; } > "$out.tmp" && mv "$out.tmp" "$out"
    rm -f "$linkf" "$clsf" "$aerf"
}

# ------------------------------------------------------------
# 计数表：数量是「在位」最直接的判据
# ------------------------------------------------------------
build_counts() {
    local d="$1"
    local tmp="$d/.counts.tmp"
    : > "$tmp"
    tail -n +2 "$d/devices.tsv" | cut -f1 | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}' >> "$tmp"

    # lspci 口径的 PCIe 设备计数（按类别码分组）
    local dnn="$d/raw/lspci-Dnn.txt"
    if [ -s "$dnn" ]; then
        awk '
            {
                rest=$0; sub(/^[^ \t]+[ \t]+/, "", rest)
                if (match(rest, /\[[0-9a-fA-F]+\]/)) {
                    c=substr(rest, RSTART+1, RLENGTH-2)
                    n[c]++
                }
            }
            END {
                lbl["0300"]="PCIE-VGA";   lbl["0302"]="PCIE-GPU"
                lbl["0200"]="PCIE-ETH";   lbl["0207"]="PCIE-IB"
                lbl["0104"]="PCIE-RAID";  lbl["0107"]="PCIE-SAS"
                lbl["0108"]="PCIE-NVME";  lbl["0604"]="PCIE-BRIDGE"
                lbl["0c04"]="PCIE-IB2"
                tot=0
                for (c in n) { tot+=n[c]; if (c in lbl) printf "%s\t%s\n", lbl[c], n[c] }
                printf "PCIE-TOTAL\t%s\n", tot
            }' "$dnn" >> "$tmp"
    fi
    { printf '%s\t%s\n' "类别" "数量"; sort -t$'\t' -k1,1 "$tmp"; } > "$d/counts.tsv"
    rm -f "$tmp"
}

# ------------------------------------------------------------
# 报错提取
# ------------------------------------------------------------
filter_err() {
    local re=""
    if [ "${#ERR_IGNORE[@]}" -gt 0 ]; then
        re=$(printf '%s|' "${ERR_IGNORE[@]}"); re="${re%|}"
    fi
    if [ -n "$re" ]; then
        grep -vE '^[[:space:]]*$|^-- No entries --$' | grep -vE "$re" || true
    else
        grep -vE '^[[:space:]]*$|^-- No entries --$' || true
    fi
}
count_err() {
    local f="$1" v=0
    if [ -s "$f" ]; then v=$(filter_err < "$f" | wc -l); fi
    printf '%s' "${v:-0}"
}

# 本轮 SEL 里「参照里没有」的条目（SEL 是追加式的，整行可比）
sel_new() {
    local cur="$1" ref="$2"
    [ -s "$cur" ] || { echo 0; return 0; }
    grep -qiE 'Unable|Error|not supported|No SEL' "$cur" && { echo 0; return 0; }
    if [ -s "$ref" ]; then
        grep -Fxv -f "$ref" "$cur" | grep -vE '^[[:space:]]*$' | wc -l
    else
        grep -vcE '^[[:space:]]*$' "$cur"
    fi
}

# NVMe 非正常掉电计数（每做一次真 DC 应该 +1）
# ------------------------------------------------------------
# 比对
# ------------------------------------------------------------
diff_devices() {
    local a="$1" b="$2" out="$3" tag="$4" drift=0
    local x
    {
        echo "【一】设备在位与配置（数量 + 身份键）"
        echo
        echo "  1) 各类别数量"
        x=$(diff <(tail -n +2 "$b/counts.tsv") <(tail -n +2 "$a/counts.tsv") 2>&1) || true
        if [ -z "$x" ]; then
            echo "     全部一致"
        else
            drift=1
            echo "     有变化（- 基线 / + 本轮）："
            printf '%s\n' "$x" | sed 's/^/       /'
        fi
        echo
        echo "  2) 设备身份键与明细"
        x=$(diff <(tail -n +2 "$b/devices.tsv") <(tail -n +2 "$a/devices.tsv") 2>&1) || true
        if [ -z "$x" ]; then
            echo "     全部一致"
        else
            drift=1
            echo "     有变化（- 基线 / + 本轮）："
            printf '%s\n' "$x" | sed 's/^/       /'
        fi
        echo
    } >> "$out"
    return "$drift"
}

diff_pcie() {
    local a="$1" b="$2" out="$3" tag="$4" drift=0
    local ka kb x
    # GPU 空闲会自动降速（Gen1/Gen4 随机跳），默认把它的「当前速率/宽度」抹平再比
    norm_pcie() {
        local f="$1"
        tail -n +2 "$f" | awk -F'\t' -v strict="$STRICT_PCIE" '
            {
                cur_s=$2; cur_w=$3
                if (strict != "1" && $1 ~ /^GPU:/) { cur_s="-"; cur_w="-" }
                printf "%s\t%s\t%s\t%s\t%s\n", $1, cur_s, cur_w, $4, $5
            }' | sort
    }
    ka=$(norm_pcie "$a/pcie.tsv")
    kb=$(norm_pcie "$b/pcie.tsv")

    {
        echo "【二】PCIe 链路枚举"
        [ "$STRICT_PCIE" != "1" ] && echo "  说明：GPU 的当前速率/宽度已忽略（空闲自动降速属正常，严格比对加 --strict-pcie）"
        echo
        echo "  1) 身份键 + 当前/最大 速率宽度"
        x=$(diff <(printf '%s\n' "$kb") <(printf '%s\n' "$ka") 2>&1) || true
        if [ -z "$x" ]; then
            echo "     全部一致"
        else
            drift=1
            echo "     有变化（- 基线 / + 本轮）："
            printf '%s\n' "$x" | sed 's/^/       /'
        fi
        echo
        echo "  2) 链路未跑满能力（仅提示，不判 FAIL —— 可能是插在低代槽位或设备本身能力如此）"
        tail -n +2 "$a/pcie.tsv" | awk -F'\t' '
            $2 != "未知" && $4 != "未知" && ($2 != $4 || $3 != $5) {
                printf "       %s  %s 当前 %s %s / 能力 %s %s\n", $6, $1, $2, $3, $4, $5
            }' | head -40
        echo "       （以上为空即全部跑满能力）"
        echo
        echo "  3) AER 非零（掉电会清零，非零说明本轮运行期间出过 PCIe 错误）"
        tail -n +2 "$a/pcie.tsv" | awk -F'\t' '$8 != "无" { printf "       %s  %s\n", $6, $1 }'
        echo "       （以上为空即无 AER）"
        echo
    } >> "$out"
    return "$drift"
}

diff_fans() {
    local a="$1" b="$2" out="$3" tag="$4" prev="${5:-}"
    local tbl="$a/.fanstbl" prevf=""
    [ -n "$prev" ] && [ -s "$prev/fans.tsv" ] && prevf="$prev/fans.tsv"
    [ "$b" = "$a" ] && prevf=""

    : > "$tbl"
    # 本轮的前一轮是不是就是基线？（round-01 时 prev 与 base 都指向 round-00）
    local pbase=0
    [ -n "$prevf" ] && [ "$prevf" = "$b/fans.tsv" ] && pbase=1
    if [ -s "$a/fans.tsv" ]; then
        awk -F'\t' -v basef="$b/fans.tsv" -v prevf="$prevf" -v tol="$FAN_TOL" -v pbase="$pbase" '
            BEGIN {
                while ((getline ln < basef) > 0) { split(ln, p, "\t"); if (p[1] != "") bref[p[1]]=p[3] }
                # ★ 必须 close(basef)：gawk 按文件名缓存输入流，当 prevf 与 basef 是同一个
                #   文件时，第二段 getline 会命中已到 EOF 的同一句柄、直接返回 0，
                #   于是「与上一轮」整列变空。close 之后重开即可。
                close(basef)
                if (prevf != "") while ((getline ln < prevf) > 0) { split(ln, p, "\t"); if (p[1] != "") pref[p[1]]=p[3] }
                if (pbase == 1) close(prevf)
            }
            function fmt(cur, ref, isbase,   o, d, ad, t) {
                if (ref == "") return "无参照数据"
                o = ref + 0
                if (cur == "") return "无读数"
                if (cur + 0 == 0) return "停转（参照 " ref "）"
                if (o == 0) return "由停转恢复（0 -> " cur "）"
                d = (cur - o) / o * 100
                t = sprintf("%+.0f RPM (%+.1f%%)", cur - o, d)
                if (isbase == 1) {
                    ad = (d < 0) ? -d : d
                    if (ad > tol) t = t "  <- 超 " tol "%"
                }
                return t
            }
            {
                n=$1; c=$3
                if (n == "") next
                bs = (n in bref) ? bref[n] : ""
                ps = (n in pref) ? pref[n] : ""
                bv = ""
                if (bs != "" && c != "" && (c + 0) > 0 && (bs + 0) > 0) {
                    bv = sprintf("%.1f", (c - bs) / (bs + 0) * 100)
                }
                printf "%s\t%s\t%s\t%s\t%s\n", n, (c == "" ? "-" : c), \
                       fmt(c, bs, 1), (prevf == "" ? "（本轮无上一轮可比）" : fmt(c, ps, 0)), bv
            }
        ' "$a/fans.tsv" > "$tbl"
    fi

    FAN_MAX=$(awk -F'\t' 'BEGIN{m=-1} $5!=""{v=$5+0; if(v<0)v=-v; if(v>m){m=v; nm=$1}} END{if(m<0) print "-"; else printf "%.1f%%", m}' "$tbl" 2>/dev/null)
    FAN_STOP=$(awk -F'\t' '$2=="0"{n++} END{print n+0}' "$tbl" 2>/dev/null)
    [ -n "$FAN_MAX" ] || FAN_MAX="-"
    [ -n "$FAN_STOP" ] || FAN_STOP=0

    {
        echo "【三】风扇转速（仅记录，不参与 PASS/FAIL 判定）"
        echo "  说明：转速由 BMC 按温度闭环调速，随进风温度与调速档位变，两轮之间必然不同，"
        echo "        所以这里不判定，只把差值记下来：与【基线】比、与【上一轮】比。"
        echo "        0 转 / 无读数同样只标注。超过 ${FAN_TOL}% 的标 \"<- 超 ${FAN_TOL}%\" 只是方便一眼扫到。"
        echo
        if [ ! -s "$tbl" ]; then
            echo "  （未取到风扇传感器）"
            echo
        else
            if [ "$pbase" = "1" ]; then
                echo "  注：本轮的前一轮就是基线（round-01），所以「与基线」「与上一轮」两列数值相同。"
                echo
            fi
            echo "  1) 逐风扇差值"
            printf '     %s%s%s%s\n' "$(pad 名称 20)" "$(pad 本轮RPM 12)" "$(pad 与基线 32)" "与上一轮"
            while IFS=$'\t' read -r fn fc fb fp _bv; do
                printf '     %s%s%s%s\n' "$(pad "$fn" 20)" "$(pad "$fc" 12)" "$(pad "$fb" 32)" "$fp"
            done < "$tbl"
            echo
            echo "  2) 小结"
            echo "     相对基线的最大波动：${FAN_MAX}"
            echo "     停转 / 无读数的风扇：${FAN_STOP} 个"
            echo "     以上仅记录，不影响本轮判定。"
            echo
        fi
    } >> "$out"

    return 0
}

# ------------------------------------------------------------
# 断电 / 上电
# ------------------------------------------------------------
power_off_now() {
    case "$POWER_MODE" in
        off-on) ipmi chassis power off ;;
        cycle)  ipmi chassis power cycle ;;
    esac
}
power_on_now() { ipmi chassis power on; }

power_status() { ipmi chassis power status 2>/dev/null | tr -d '\r' | head -n1; }

# 本机模式：脚本先退出，交给 systemd 稍后断电（否则脚本把自己断电了）
# ★ 闸 2：返回码必须可信 —— 调度不上就不能让调用方报「已安排断电」，
#         否则机器根本不断电，测试静默停在那儿，现场还以为是机器的问题。
schedule_power_off() {
    local delay=6 cmd pid
    # ★ 接口怎么选，必须和上面 ipmi() 完全一致：
    #   BMC_HOST 为空 = 本机模式，走 ipmitool -I open；否则走 lanplus + -H/-U。
    #   原写法无条件拼 `-I $BMC_INTF -H $BMC_HOST -U $BMC_USER`，--local 下这两个变量
    #   都是空的 → 拼出 `ipmitool -I lanplus -H  -U  chassis power off` → 必然失败。
    #   而且它跑在「延迟触发的 transient unit」里，脚本那时早已 exit 0，
    #   现场只能看到「提示已安排断电、然后什么都没发生」，极难倒查（2026-09-28 实际踩到）。
    if [ -n "$BMC_HOST" ]; then
        cmd="ipmitool -I $BMC_INTF -H $BMC_HOST -U $BMC_USER"
        [ -n "$PWFILE" ] && cmd="$cmd -f $PWFILE"
    else
        cmd="ipmitool -I open"
    fi
    cmd="$cmd chassis power off"
    if command -v systemd-run >/dev/null 2>&1; then
        if systemd-run --on-active="${delay}s" --unit="dcpower-off-$$" /bin/sh -c "$cmd" >/dev/null 2>&1; then
            return 0
        fi
        warn "systemd-run 调度失败，回退到 setsid 延迟断电"
    fi
    setsid /bin/sh -c "sleep $delay; $cmd" >/dev/null 2>&1 &
    pid=$!
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    err "setsid 延迟断电进程没能起来（setid 缺失或无法 fork）"
    return 1
}

# ------------------------------------------------------------
# 等待就绪：不能只看 ping，要等到 systemd 真的起来
# ------------------------------------------------------------
wait_ready() {
    local t0 el st b1 b2
    t0=$(date +%s)
    while :; do
        if rrun "echo READY" 2>/dev/null | grep -q READY; then break; fi
        el=$(( $(date +%s) - t0 ))
        if [ "$el" -ge "$BOOT_TIMEOUT" ]; then echo "-1"; return 1; fi
        [ $((el % 30)) -lt 5 ] && info "等待 $([ -n "$DUT" ] && echo "$DUT" || echo 本机) SSH 可达… ${el}s"
        sleep 5
    done
    while :; do
        st=$(rrun "systemctl is-system-running 2>/dev/null || true" | tr -d '\r')
        case "$st" in
            running|degraded|maintenance) break ;;
        esac
        el=$(( $(date +%s) - t0 ))
        if [ "$el" -ge "$BOOT_TIMEOUT" ]; then echo "-1"; return 1; fi
        sleep 5
    done
    # boot_id 必须稳定，否则是在重启循环里，抓到的快照没意义
    b1=$(rrun "cat /proc/sys/kernel/random/boot_id 2>/dev/null" | tr -d '\r')
    sleep 5
    b2=$(rrun "cat /proc/sys/kernel/random/boot_id 2>/dev/null" | tr -d '\r')
    if [ -n "$b1" ] && [ "$b1" != "$b2" ]; then
        warn "系统在重启循环中（boot_id 变了），本轮按 Pending 处理"
        echo "-1"; return 1
    fi
    sleep "$SETTLE"
    echo "$(( $(date +%s) - t0 ))"
    return 0
}

# 往回找最近一轮「真的抓到过数据」的轮次 —— 风扇要跟【上一轮】比，
# 而上一轮如果是 Pending（没起来），就得再往前找，否则差值全是假的。
last_ref() {
    local n="$1" d
    while [ "$n" -ge 0 ]; do
        d="$OUTDIR/round-$(printf '%02d' "$n")"
        if [ -s "$d/devices.tsv" ] && [ "$(wc -l < "$d/devices.tsv")" -gt 1 ]; then
            printf '%s' "$d"; return 0
        fi
        n=$((n - 1))
    done
    return 1
}

# ------------------------------------------------------------
# 单轮：采集 -> 解析 -> 比对 -> 出判定
# ------------------------------------------------------------
# 基线目录：优先用 -b/--baseline 指定的外部基线，否则用本轮抓的 round-00。
# 只与基线比 —— 上一轮如果是 Pending（没起来），拿它当参照会把后面几轮全带崩。
baseline_dir() {
    if [ -n "$BASELINE" ] && [ -s "$BASELINE/devices.tsv" ] && [ "$(wc -l < "$BASELINE/devices.tsv")" -gt 1 ]; then
        printf '%s' "$BASELINE"; return 0
    fi
    local d="$OUTDIR/round-00"
    if [ -s "$d/devices.tsv" ] && [ "$(wc -l < "$d/devices.tsv")" -gt 1 ]; then
        printf '%s' "$d"; return 0
    fi
    return 1
}

run_round() {
    local idx="$1"
    local d="$OUTDIR/round-$idx"
    mkdir -p "$d/raw"

    CUR_DEV="$d/.dev.tmp"; CUR_MAP="$d/.bdfmap"
    : > "$CUR_DEV"; : > "$CUR_MAP"

    info "采集原始证据（OS 侧 + BMC 侧）…"
    collect_raw "$d/raw"
    collect_bmc "$d/raw"

    info "解析设备在位与 PCIe 链路…"
    parse_cpu      "$d/raw"
    parse_dimm     "$d/raw"
    parse_gpu      "$d/raw"
    parse_nvme     "$d/raw"
    parse_block    "$d/raw"
    parse_net      "$d/raw"
    parse_raid     "$d/raw"
    parse_ipmi     "$d/raw" "$d/fans.tsv"
    { printf '%s\t%s\t%s\n' "类别" "身份键" "明细"; sort -u "$CUR_DEV"; } > "$d/devices.tsv"
    rm -f "$CUR_DEV"
    sort -u "$CUR_MAP" -o "$CUR_MAP"
    parse_pcie     "$d"
    build_counts   "$d"
    rm -f "$CUR_MAP"

    # ---- 报错统计 ----
    local kerr serr failed selnew
    kerr=$(count_err "$d/raw/journal-kernel.txt")
    serr=$(count_err "$d/raw/journal-service.txt")
    failed=$(grep -vE '^[[:space:]]*$' "$d/raw/systemctl-failed.txt" 2>/dev/null | wc -l)

    local base=""
    base=$(baseline_dir || true)
    if [ -n "$base" ] && [ "$base" != "$d" ]; then
        selnew=$(sel_new "$d/raw/ipmitool-sel.txt" "$base/raw/ipmitool-sel.txt")
    else
        selnew=0
    fi

    local aer_n xid_n mce_n
    aer_n=$(tail -n +2 "$d/pcie.tsv" | awk -F'\t' '$8 != "无"' | wc -l)
    xid_n=$(grep -vE '^[[:space:]]*$' "$d/raw/dmesg-xid.txt" 2>/dev/null | wc -l)
    mce_n=$(grep -vE '^[[:space:]]*$' "$d/raw/dmesg-mce.txt" 2>/dev/null | wc -l)

    # ---- 与基线比对：三部分全部汇总进 $d/.cmp 一个片段 ----
    # 风扇另外跟【上一轮】比一次，但只记录不判 FAIL
    local devdrift=0 pciedrift=0 cmp="$d/.cmp" nprev="" idxn
    idxn=$((10#$idx))
    if [ "$idxn" -gt 0 ]; then nprev=$(last_ref $((idxn - 1)) || true); fi
    FAN_MAX="-"; FAN_STOP=0
    : > "$cmp"
    if [ -n "$base" ] && [ "$base" != "$d" ]; then
        {
            echo "################################################################"
            echo "round-$idx  与基线对比"
            echo "基线目录：$base"
            echo "抓取时间：$(date -Is)"
            echo "################################################################"
            echo
        } >> "$cmp"
        diff_devices "$d" "$base" "$cmp" "基线" || devdrift=1
        diff_pcie    "$d" "$base" "$cmp" "基线" || pciedrift=1
        diff_fans    "$d" "$base" "$cmp" "基线" "$nprev"
        {
            echo "【本轮漂移小结】"
            echo "  设备在位：$([ "$devdrift" = "1" ] && echo "有漂移" || echo "无漂移")"
            echo "  PCIe链路：$([ "$pciedrift" = "1" ] && echo "有漂移" || echo "无漂移")"
            echo "  风扇转速：仅记录（相对基线最大波动 ${FAN_MAX}，停转/无读数 ${FAN_STOP} 个），不参与判定"
            echo
        } >> "$cmp"
    else
        {
            echo "################################################################"
            echo "round-$idx  （本轮即基线，无对比对象）"
            echo "抓取时间：$(date -Is)"
            echo "################################################################"
            echo
            echo "【一】设备在位与配置：本轮即基线，不做对比"
            echo "【二】PCIe 链路枚举：本轮即基线，不做对比"
            echo "【三】风扇转速：本轮即基线，不做对比"
            echo
        } >> "$cmp"
    fi

    # ---- 判定 ----
    local verdict="PASS" reason=""
    if [ "$kerr" -gt 0 ]; then
        if [ "$ERR_SOFT" = "1" ]; then reason="$reason 内核err ${kerr}行(软);"; else verdict="FAIL"; reason="$reason 内核err ${kerr}行;"; fi
    fi
    if [ "$serr" -gt 0 ]; then
        if [ "$ERR_SOFT" = "1" ]; then reason="$reason 服务err ${serr}行(软);"; else verdict="FAIL"; reason="$reason 服务err ${serr}行;"; fi
    fi
    if [ "$failed" -gt 0 ]; then
        if [ "$ERR_SOFT" = "1" ]; then reason="$reason failed单元 ${failed}个(软);"; else verdict="FAIL"; reason="$reason failed单元 ${failed}个;"; fi
    fi
    if [ "$selnew" -gt 0 ]; then verdict="FAIL"; reason="$reason SEL新增 ${selnew}条;"; fi
    if [ "$xid_n" -gt 0 ]; then verdict="FAIL"; reason="$reason GPU Xid/err ${xid_n}行;"; fi
    if [ "$mce_n" -gt 0 ]; then verdict="FAIL"; reason="$reason MCE/HW Error ${mce_n}行;"; fi
    if [ "$devdrift" = "1" ]; then verdict="FAIL"; reason="$reason 设备在位漂移;"; fi
    if [ "$pciedrift" = "1" ]; then verdict="FAIL"; reason="$reason PCIe链路漂移;"; fi
    if [ "$aer_n" -gt 0 ]; then reason="$reason AER非零 ${aer_n}项;"; fi

    if [ ! -s "$d/devices.tsv" ] || [ "$(wc -l < "$d/devices.tsv")" -le 1 ]; then
        verdict="Pending"; reason="$reason 没抓到任何设备数据;"
    fi

    # ---- meta / summary ----
    {
        echo "round=$idx"
        echo "snapshot_at=$(date -Is)"
        echo "boot_id=$(rrun 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r')"
        echo "uptime=$(rrun 'cat /proc/uptime 2>/dev/null' | tr -d '\r')"
        echo "restart_cause=$( [ -f "$d/raw/ipmitool-restart.txt" ] && tr -d '\r' < "$d/raw/ipmitool-restart.txt" | tail -n1 )"
        echo "chassis=$( [ -f "$d/raw/ipmitool-chassis.txt" ] && tr -d '\r' < "$d/raw/ipmitool-chassis.txt" | grep -i 'Power is' | head -n1 )"
        echo "baseline=${base:-无}"
        echo "journal_persist=$(head -n1 "$d/raw/journal-persist.txt" 2>/dev/null)"
    } > "$d/meta.txt"

    cat > "$d/summary.env" <<EOF
R_ROUND="$idx"
R_TIME="$(date -Is)"
R_OFF="${ROUND_OFF:-0}"
R_READY="${ROUND_READY:--}"
R_KERR="$kerr"
R_SERR="$serr"
R_FAILED="$failed"
R_SELNEW="$selnew"
R_DEVDRIFT="$devdrift"
R_PCIEDRIFT="$pciedrift"
R_FANSUM="$( [ -s "$d/fans.tsv" ] && { printf '%s' "$FAN_MAX"; [ "${FAN_STOP:-0}" -gt 0 ] && printf '/停%s' "$FAN_STOP"; } || printf -- '-' )"
R_AER="$aer_n"
R_VERDICT="$verdict"
R_REASON="$(printf '%s' "$reason" | sed 's/^ //; s/"/'"'"'/g')"
EOF

    case "$verdict" in
        PASS)    ok   "round-$idx 判定 PASS${reason:+（提示：$reason）}" ;;
        FAIL)    err  "round-$idx 判定 FAIL：$reason" ;;
        Pending) warn "round-$idx 判定 Pending：$reason" ;;
    esac
    [ "$verdict" = "FAIL" ] && return 1
    [ "$verdict" = "Pending" ] && return 2
    return 0
}

# ------------------------------------------------------------
# 本机模式的续跑服务
# ------------------------------------------------------------
# ★ 闸 1：任何一步失败都要 return 非 0 让调用方知道，
#         绝不能再「吞掉错误 + 无条件报已安装」——那是断电后回不来的直接原因。
install_resume_unit() {
    local unit=/etc/systemd/system/dcpower-resume.service
    local tmp="${unit}.tmp.$$"
    # 注意：只留 After=network-online.target。
    #   原来还写了 After=multi-user.target，但本 unit 本身就是
    #   WantedBy=multi-user.target 的成员 —— 自己排在自己所属的 target 之后，
    #   属自引用顺序，systemd 会报 ordering 告警甚至丢弃该 job。
    #   WantedBy=multi-user.target 已经保证它在 multi-user 阶段被拉起。
    if ! cat > "$tmp" <<UNITEOF
[Unit]
Description=dcpower.sh 续跑（DC 电源循环测试，重启后自动继续）
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'bash "$SELF" --resume --outdir "$OUTDIR"'
TimeoutStartSec=0
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNITEOF
    then
        rm -f "$tmp"
        err "写 unit 临时文件失败：$tmp（/etc 只读？磁盘满？）"
        return 1
    fi
    mv -f "$tmp" "$unit" 2>/dev/null || { rm -f "$tmp"; err "安装 unit 文件失败：$unit"; return 1; }

    systemctl daemon-reload >/dev/null 2>&1 || { err "systemctl daemon-reload 失败"; return 1; }
    systemctl enable dcpower-resume.service >/dev/null 2>&1 || { err "systemctl enable 失败"; return 1; }
    # ★ 真验一次：不验就等于没装
    if ! systemctl is-enabled --quiet dcpower-resume.service 2>/dev/null; then
        err "服务 enable 之后 is-enabled 检查未通过 —— 开机不会自动续跑"
        return 1
    fi
    return 0
}

uninstall_resume_unit() {
    systemctl disable --now dcpower-resume.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/dcpower-resume.service
    systemctl daemon-reload 2>/dev/null || true
}

# ------------------------------------------------------------
# .state —— 本机模式续跑用的状态文件
# ★ 闸 3：先写 .state.tmp 再 mv（同目录同分区，mv 是原子替换）。
#         直接 `cat > .state` 的话，断电恰好落在写入中间会把文件截断，
#         重启后 source 到半截内容、变量为空；脚本又没 set -e，
#         会带着空 SN / 空参数一路跑下去，错误极难倒查。
# ------------------------------------------------------------
write_state() {
    local round="$1" tmp="$OUTDIR/.state.tmp"
    if ! cat > "$tmp" <<EOF
ROUND=$round
TOTAL=$LOOPS
SN="$SN"
TESTID="$testid"
BMC_HOST="$BMC_HOST"
BMC_USER="$BMC_USER"
BMC_INTF="$BMC_INTF"
PWFILE="$PWFILE"
SELF="$SELF"
DUT=""
OFF_DELAY=$OFF_DELAY
BOOT_TIMEOUT=$BOOT_TIMEOUT
SETTLE=$SETTLE
POWER_MODE="$POWER_MODE"
ERR_SOFT=$ERR_SOFT
STRICT_PCIE=$STRICT_PCIE
FAN_TOL=$FAN_TOL
DRY_RUN=$DRY_RUN
RESUME_N=${RESUME_N:-0}
# DONE=1 表示「已跑满」，收尾时落盘；续跑侧据此短路，避免重复断电
DONE=${DONE:-0}
# 起始时刻必须跨重启保留：最终报告是由最后一次续跑写出的
# 用 ${RUN_START:-} 兜底 —— 本函数可能被「只抽函数、不含主流程初始化」的方式调用
RUN_START="${RUN_START:-}"
STATE_AT="$(date -Is)"
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$OUTDIR/.state" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# ------------------------------------------------------------
# 汇总报告
# ------------------------------------------------------------
write_report() {
    local out="$OUTDIR/${SN}_dcpower_report.txt" f
    [ -n "$SN" ] || out="$OUTDIR/dcpower_report.txt"
    {
        echo "================================================================"
        echo "DC 电源循环（DC Power Cycle）测试报告"
        echo "测试人员工号：${testid:-unknown}"
        echo "SN：${SN:-未填}"
        echo "开始：${RUN_START:-?}    结束：$(date -Is)"
        echo "断电次数：$LOOPS   断电保持：${OFF_DELAY}s   等待上限：${BOOT_TIMEOUT}s   稳定期：${SETTLE}s"
        if [ "${RESUME_N:-0}" -gt 0 ]; then
            echo "重启续跑：${RESUME_N} 次（本机模式）"
        fi
        echo "对比口径：设备在位（数量+身份键）、PCIe 链路枚举（均判 PASS/FAIL）；风扇转速仅记录差值不判定"
        echo "================================================================"
        echo
        tbl_row() {
            pad "$1" 7;  pad "$2" 21; pad "$3" 10; pad "$4" 10
            pad "$5" 9;  pad "$6" 9;  pad "$7" 8;  pad "$8" 10
            pad "$9" 10; pad "${10}" 10; pad "${11}" 12
            printf '%s\n' "${12}"
        }
        tbl_row "轮次" "抓取时间" "断电保持" "就绪耗时" "内核err" "服务err" "failed" "SEL新增" "设备漂移" "PCIe漂移" "风扇波动" "判定"
        for f in "$OUTDIR"/round-*; do
            [ -d "$f" ] || continue
            [ -s "$f/summary.env" ] || continue
            ( set -u; . "$f/summary.env"
              tbl_row "$R_ROUND" "${R_TIME:0:19}" "${R_OFF}s" "${R_READY}s" \
                      "$R_KERR" "$R_SERR" "$R_FAILED" "$R_SELNEW" \
                      "$R_DEVDRIFT" "$R_PCIEDRIFT" "${R_FANSUM:--}" "$R_VERDICT" )
        done
        echo
        echo "----------------------------------------------------------------"
        echo "逐轮原因"
        for f in "$OUTDIR"/round-*; do
            [ -d "$f" ] || continue
            [ -s "$f/summary.env" ] || continue
            ( set -u; . "$f/summary.env"
              [ -n "${R_REASON:-}" ] && printf 'round-%s  %-8s %s\n' "$R_ROUND" "$R_VERDICT" "$R_REASON" )
        done
        echo
        echo "----------------------------------------------------------------"
        local p=0 fa=0 pe=0
        for f in "$OUTDIR"/round-*; do
            [ -d "$f" ] || continue
            [ -s "$f/summary.env" ] || continue
            local v
            v=$( . "$f/summary.env" >/dev/null 2>&1; printf '%s' "$R_VERDICT" )
            case "$v" in
                PASS) p=$((p+1)) ;;
                FAIL) fa=$((fa+1)) ;;
                *)    pe=$((pe+1)) ;;
            esac
        done
        echo "结论：PASS $p / FAIL $fa / Pending $pe"
        echo "对比明细：$OUTDIR/${SN}_compare.txt"
        echo "证据目录：$OUTDIR/round-NN/（raw/ 是原始输出）"
    } > "$out"
    write_compare
    info "报告已写入 $out"
}

# ------------------------------------------------------------
# 与基线的对比汇总：所有轮次装进一个文件（幂等重建，随时可看）
# ------------------------------------------------------------
write_compare() {
    local out="$OUTDIR/${SN}_compare.txt" f
    [ -n "$SN" ] || out="$OUTDIR/compare.txt"
    {
        echo "================================================================"
        echo "DC 电源循环测试 —— 与基线对比汇总"
        echo "测试人员工号：${testid:-unknown}"
        echo "SN：${SN:-未填}"
        echo "基线目录：$(baseline_dir 2>/dev/null || echo '（本轮 round-00）')"
        echo "开始：${RUN_START:-?}    结束：$(date -Is)"
        echo "对比口径：设备在位（数量+身份键）、PCIe 链路枚举（均判 PASS/FAIL）；风扇转速仅记录差值不判定"
        echo "================================================================"
        echo
        cmp_row() {
            pad "$1" 10; pad "$2" 9; pad "$3" 12; pad "$4" 12
            printf '%s\n' "$5"
        }
        cmp_row "轮次" "判定" "设备在位" "PCIe链路" "风扇最大波动"
        for f in "$OUTDIR"/round-*; do
            [ -d "$f" ] || continue
            [ -s "$f/summary.env" ] || continue
            ( set -u; . "$f/summary.env"
              dd="无漂移"; [ "$R_DEVDRIFT" = "1" ] && dd="有漂移"
              pd="无漂移"; [ "$R_PCIEDRIFT" = "1" ] && pd="有漂移"
              cmp_row "round-$R_ROUND" "$R_VERDICT" "$dd" "$pd" "${R_FANSUM:--}" )
        done
        echo
        for f in "$OUTDIR"/round-*; do
            [ -d "$f" ] || continue
            [ -s "$f/.cmp" ] || continue
            cat "$f/.cmp"
        done
    } > "$out"
    info "对比汇总已写入 $out"
}

# ============================================================
# 主流程
# ============================================================
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
PWFILE=""; LOGGING=0; KEEP_PW=0; RUN_START=""

cleanup() {
    [ -n "$PWFILE" ] && [ -f "$PWFILE" ] && [ "$KEEP_PW" != "1" ] && rm -f "$PWFILE"
    [ "$LOGGING" = "1" ] && sleep 0.3
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' INT TERM

# ---------- --uninstall ----------
if [ "$DO_UNINSTALL" = "1" ]; then
    if [ "$(id -u 2>/dev/null)" != "0" ]; then err "需要 root：sudo bash $0 --uninstall"; exit 1; fi
    uninstall_resume_unit
    ok "已卸载 dcpower-resume.service"
    exit 0
fi

# ---------- --resume（本机模式，重启后由 systemd 调起） ----------
if [ "$RESUME" = "1" ]; then
    if [ -z "$OUTDIR" ] || [ ! -s "$OUTDIR/.state" ]; then
        err "--resume 需要 --outdir 指向一个已存在且带 .state 的目录"
        exit 2
    fi
    # shellcheck disable=SC1091
    . "$OUTDIR/.state"
    # ★ 闸 3：source 完必须校验关键变量。断电截断过的 .state 会静默读出空值，
    #   而脚本没 set -e，后面会带着空 SN / 空参数一路跑下去，错误很难倒查。
    _bad=""
    [ -n "${TOTAL:-}" ]        || _bad="TOTAL"
    [ -n "${SN:-}" ]           || _bad="${_bad:-SN}"
    [ -n "${TESTID:-}" ]       || _bad="${_bad:-TESTID}"
    [ -n "${OFF_DELAY:-}" ]    || _bad="${_bad:-OFF_DELAY}"
    [ -n "${BOOT_TIMEOUT:-}" ] || _bad="${_bad:-BOOT_TIMEOUT}"
    [ -n "${SETTLE:-}" ]       || _bad="${_bad:-SETTLE}"
    if [ -z "${SELF:-}" ] || [ ! -f "${SELF:-}" ]; then _bad="${_bad:-SELF}"; fi
    if [ -n "$_bad" ]; then
        err ".state 不完整（$_bad 为空或缺失）—— 多半是断电时正写到一半"
        err "文件：$OUTDIR/.state"
        err "处理：修好它，或删掉整个输出目录重跑一轮基线"
        err "查看服务日志：journalctl -u dcpower-resume.service -n 50"
        exit 2
    fi
    case "${ROUND:-0}" in
        ''|*[!0-9]*) err ".state 里的 ROUND 非法：'${ROUND:-}'"; exit 2 ;;
    esac
    # 上一轮已跑满（收尾落了 DONE=1），服务本不该再被调起；
    # 真被调起说明有人手动 start、或卸载没干净 —— 直接退出，别重复断电。
    if [ "${DONE:-0}" = "1" ]; then
        ok "上一轮已跑满（.state 里 DONE=1），无需续跑"
        exit 0
    fi
    # 起始时刻跨重启保留（老版本 .state 里没有这一项，兜个底）
    [ -n "${RUN_START:-}" ] || RUN_START="$(date -Is)"
    RESUME_N=$(( ${RESUME_N:-0} + 1 ))   # 打卡：续跑服务被触发的次数
    LOCAL=1; KEEP_PW=1
    LOOPS="${TOTAL:-$LOOPS}"
    testid="${TESTID:-unknown}"
    DUMP_SH="$OUTDIR/.dump.sh"
    [ -n "$PWFILE" ] && [ -f "$PWFILE" ] && IPMI_PW=(-f "$PWFILE")
    exec >> "$OUTDIR/${SN:-dcpower}_run.log" 2>&1
    LOGGING=0
    ROUND=$((ROUND + 1))
    CUR_ROUND="$ROUND"
else
    # ---------- 正常启动 ----------
    # --list 是只读巡检：跳过 root / BMC / 依赖 / 输出目录的全部校验，它自己管自己
    if [ "$DO_LIST" != "1" ]; then

    if [ "$(id -u 2>/dev/null)" != "0" ]; then
        err "需要 root 权限（sudo bash $0）—— 控电和抓硬件清单都要 root"
        info "只想看现状：bash $0 --list（免 root）"
        exit 1
    fi
    if [ -z "$BMC_HOST" ] && [ "$LOCAL" != "1" ]; then
        err "控制机模式必须给 --bmc <BMC地址>"
        exit 2
    fi
    if [ -z "$BMC_HOST" ] && [ "$LOCAL" = "1" ]; then
        info "未给 --bmc，本机模式将走本地 KVM 接口（ipmitool -I open）"
    fi

    # 依赖检查
    for c in ipmitool awk sed grep sort diff tar; do
        command -v "$c" >/dev/null 2>&1 || { err "缺少命令：$c"; info "安装：apt install ipmitool gawk coreutils"; exit 1; }
    done
    if [ -z "$DUT" ] && ! command -v dmidecode >/dev/null 2>&1; then
        warn "本机没装 dmidecode，CPU/内存的详细信息会缺失（apt install dmidecode）"
    fi
    if [ -n "$DUT" ] && ! command -v ssh >/dev/null 2>&1; then
        err "控制机缺少 ssh"; exit 1
    fi

    # 测试人员工号 / 服务器 SN（与 lhtest.sh 同一套输入范式）
    echo -e "${BLUE}==================== 测试信息录入 ====================${NC}"
    get_testid
    get_sn
    SN="$(printf '%s' "$SN" | tr -d '[:space:]' | tr '/' '_')"
    [ -n "$SN" ] || { err "SN 不能为空"; exit 1; }
    echo

    [ -n "$OUTDIR" ] || OUTDIR="./${SN}_dcpower.log"
    mkdir -p "$OUTDIR" || { err "建不了输出目录 $OUTDIR"; exit 1; }
    OUTDIR="$(readlink -f "$OUTDIR")"
    RUN_START="$(date -Is)"

    exec > >(tee -a "$OUTDIR/${SN}_run.log") 2>&1
    LOGGING=1

    if [ -n "$BMC_PASS" ]; then
        PWFILE="$OUTDIR/.ipmi.pass"
        ( umask 077; printf '%s' "$BMC_PASS" > "$PWFILE" )
        IPMI_PW=(-f "$PWFILE")
    fi
    [ "$LOCAL" = "1" ] && KEEP_PW=1

    # --dry-run 不断电，本机模式也就没有「续跑」可言，统一走进程内循环
    [ "$DRY_RUN" = "1" ] && LOCAL=0

    DUMP_SH="$OUTDIR/.dump.sh"
    write_dump_script "$DUMP_SH"

    echo -e "${BLUE}==================== dcpower.sh ====================${NC}"
    echo "  测试人员工号: $testid"
    echo "  SN          : $SN"
    echo "  被测机      : ${DUT:-本机（--local 模式）}"
    echo "  断电次数    : $LOOPS    断电保持: ${OFF_DELAY}s    等待上限: ${BOOT_TIMEOUT}s    稳定期: ${SETTLE}s"
    echo "  输出目录    : $OUTDIR"
    echo "  模式        : $([ "$LOCAL" = "1" ] && echo 本机续跑 || echo 控制机远程)$([ "$DRY_RUN" = "1" ] && echo "（演练，不断电）")"
    echo

    # BMC 连通性
    if [ "$DRY_RUN" != "1" ]; then
        # ★ 正向确认，不用黑名单。`ipmitool mc info` 成功时必然带这些字段；
        #   而黑名单只认 Error|Unable|Invalid|timeout —— 本机 -I open 在没有 IPMI 设备时
        #   吐的是「Could not open device at /dev/ipmi0 …: 没有那个文件或目录」，
        #   一个关键字都不命中 → 直接把错误原文塞进 ✅ 括号里报「BMC 连通」（假绿）。
        local_mc=$(ipmi mc info 2>&1 | head -n6)
        if ! printf '%s' "$local_mc" | grep -qiE 'Device ID|Manufacturer Name|Product ID|Firmware Revision'; then
            err "BMC 连不上或认证失败（mc info 没取到任何有效字段）："
            printf '%s\n' "$local_mc" | sed 's/^/    /'
            if [ -z "$BMC_HOST" ]; then
                info "当前是本机模式，走的是 ipmitool -I open —— 需要本机存在 /dev/ipmi0。"
                info "若本机没有 IPMI 设备（虚拟机 / BMC 是独立网口），改用："
                info "  · 只验采集与比对链路：bash $0 --local --dry-run"
                info "  · 真要控电：bash $0 --local --bmc <BMC地址> -U <用户> -P <密码>"
            else
                info "检查：--bmc / -U / -P / -I；也可先跑 ipmitool -I lanplus -H <bmc> -U <user> -P <pass> mc info"
            fi
            exit 1
        fi
        ok "BMC 连通（$(printf '%s' "$local_mc" | head -n1 | tr -d '\r')）"
        st=$(power_status)
        # ★ 读不到就明说「不可得」，不打印一个空的「当前电源状态：」——
        #   空白行看起来像「电源状态正常」，是另一种假绿。
        if [ -n "$st" ]; then
            info "当前电源状态：$st"
        else
            warn "当前电源状态：读不到（ipmitool 无输出）—— 本项不可得，不填默认值"
        fi
    fi

    # 本机模式：先落地 .state + 装续跑服务
    if [ "$LOCAL" = "1" ]; then
        RESUME_N=0
        # ★ 闸 3：原子写状态文件
        if ! write_state 0; then
            err "写 $OUTDIR/.state 失败 —— 拒绝继续（续跑全靠它）"
            exit 2
        fi
        # ★ 闸 1：装不上就绝不允许断电，否则重启后回不来
        if ! install_resume_unit; then
            err "续跑服务安装失败 —— 拒绝继续。若强行断电，重启后不会自动接着跑。"
            uninstall_resume_unit >/dev/null 2>&1 || true
            exit 2
        fi
        ok "已安装续跑服务 dcpower-resume.service（已 enable，测完自动卸载）"
    fi
    CUR_ROUND=0
    fi   # end of [ "$DO_LIST" != "1" ]
fi

# ---------- --list：只读巡检 ----------
if [ "$DO_LIST" = "1" ]; then
    TMPD=$(mktemp -d)
    TMPLIST="$TMPD"
    DUMP_SH="$TMPD/dump.sh"
    write_dump_script "$DUMP_SH"
    mkdir -p "$TMPD/round-00/raw"
    CUR_DEV="$TMPD/round-00/.dev.tmp"; CUR_MAP="$TMPD/round-00/.bdfmap"
    : > "$CUR_DEV"; : > "$CUR_MAP"
    echo -e "${BLUE}==================== 只读巡检 ====================${NC}"
    echo "  被测机：${DUT:-本机}"
    if [ -n "$BMC_HOST" ]; then
        s=$(ipmi chassis status 2>&1 | tr -d '\r' | grep -i 'Power is' | head -n1)
        [ -n "$s" ] && info "BMC 电源状态：$s" || warn "BMC 未响应（$(printf '%s' "$s" | head -n1)）"
    fi
    collect_raw "$TMPD/round-00/raw"
    collect_bmc "$TMPD/round-00/raw"
    parse_cpu "$TMPD/round-00/raw"; parse_dimm "$TMPD/round-00/raw"
    parse_gpu "$TMPD/round-00/raw"; parse_nvme "$TMPD/round-00/raw"
    parse_block "$TMPD/round-00/raw"; parse_net "$TMPD/round-00/raw"
    parse_raid "$TMPD/round-00/raw"; parse_ipmi "$TMPD/round-00/raw" "$TMPD/round-00/fans.tsv"
    { printf '%s\t%s\t%s\n' "类别" "身份键" "明细"; sort -u "$CUR_DEV"; } > "$TMPD/round-00/devices.tsv"
    sort -u "$CUR_MAP" -o "$CUR_MAP"
    parse_pcie "$TMPD/round-00"
    build_counts "$TMPD/round-00"
    echo
    echo -e "${CYAN}  设备在位计数：${NC}"
    tail -n +2 "$TMPD/round-00/counts.tsv" | awk -F'\t' '{ printf "    %-14s %s\n", $1, $2 }'
    echo
    echo -e "${CYAN}  PCIe 链路未跑满能力的设备：${NC}"
    tail -n +2 "$TMPD/round-00/pcie.tsv" | awk -F'\t' '
        $2!="未知" && $4!="未知" && ($2!=$4 || $3!=$5) { printf "    %-9s %-40s 当前 %s %s / 能力 %s %s\n", $6, $1, $2, $3, $4, $5 }' | head -30
    echo
    info "本模式只读，没有断电、没有改任何东西"
    rm -rf "$TMPLIST"
    exit 0
fi

# ---------- 主循环 ----------
PASS_N=0; FAIL_N=0; PEND_N=0
count_rc() { case "$1" in 0) PASS_N=$((PASS_N + 1));; 1) FAIL_N=$((FAIL_N + 1));; *) PEND_N=$((PEND_N + 1));; esac; }

# round-00：跑测试前的原始状态，作为基线
if [ "$CUR_ROUND" -eq 0 ]; then
    echo -e "${BLUE}==================== round-00 基线（跑测试前的原始状态） ====================${NC}"
    wait_ready >/dev/null 2>&1 || true
    ROUND_OFF=0; ROUND_READY="-"
    run_round "00"; count_rc $?
    if [ "$LOOPS" -eq 0 ]; then write_report; exit 0; fi
    if [ "$LOCAL" = "1" ]; then
        info "调度第 1 次断电（${OFF_DELAY}s 保持）…"
        # ★ 闸 2：没真安排上就不许报成功
        if ! schedule_power_off; then
            err "断电调度失败 —— 请手动断电；重启后 dcpower-resume.service 会接着跑"
            exit 2
        fi
        ok "已安排断电；重启后由 dcpower-resume.service 自动续跑"
        exit 0
    fi
else
    # ---------- 本机模式：重启后由 systemd 调起，从上一轮接着走 ----------
    RIDX=$(printf '%02d' "$CUR_ROUND")
    echo -e "${BLUE}==================== round-$RIDX （重启后续跑） ====================${NC}"
    ROUND_OFF="$OFF_DELAY"
    ready=$(wait_ready)
    if [ "$ready" = "-1" ]; then
        warn "系统在 ${BOOT_TIMEOUT}s 内没就绪 —— 本轮按 Pending 记录，请查 BMC SEL 与 SOL 画面"
        ROUND_READY="-1"
    else
        ROUND_READY="$ready"
        ok "系统就绪，耗时 ${ready}s"
    fi
    run_round "$RIDX"; count_rc $?

    if [ "$CUR_ROUND" -ge "$LOOPS" ]; then
        # ★ 收尾也要落一次状态：否则 .state 停在倒数第二轮（现场看到会以为还要续跑），
        #   且 RESUME_N 会少记一次 —— 它正是用来事后确认续跑服务跑过几次的。
        DONE=1
        write_state "$LOOPS" || warn "收尾时写 $OUTDIR/.state 失败（不影响本次报告）"
        write_report
        uninstall_resume_unit
        [ -n "$PWFILE" ] && rm -f "$PWFILE"
        KEEP_PW=0
        echo
        info "PASS=$PASS_N  FAIL=$FAIL_N  Pending=$PEND_N"
        ok "全部 $LOOPS 次 DC 完成"
        [ "$FAIL_N" -gt 0 ] && exit 1
        exit 0
    fi
    # ★ 闸 3：原子更新 .state（原先的 sed -i 也是原地改，同样怕断电截断）
    if ! write_state "$CUR_ROUND"; then
        err "更新 $OUTDIR/.state 失败 —— 拒绝断电，否则重启后进度会丢"
        exit 2
    fi
    echo
    info "调度第 $((CUR_ROUND + 1)) 次断电（${OFF_DELAY}s 保持）…"
    # ★ 闸 2：没真安排上就不许报成功
    if ! schedule_power_off; then
        err "断电调度失败 —— 请手动断电；重启后 dcpower-resume.service 会接着跑"
        exit 2
    fi
    exit 0
fi

# ---------- 控制机模式（或 --dry-run）的循环：脚本全程不断电，一轮一轮推 ----------
i=1
while [ "$i" -le "$LOOPS" ]; do
    ridx=$(printf '%02d' "$i")
    echo
    echo -e "${BLUE}==================== round-$ridx ====================${NC}"

    if [ "$DRY_RUN" = "1" ]; then
        info "[DRY-RUN] 跳过断电，直接抓快照"
        ROUND_OFF=0; ROUND_READY="-"
        run_round "$ridx"; count_rc $?
        i=$((i + 1))
        continue
    fi

    info "断电中（$POWER_MODE）…"
    t_off=$(date +%s)
    power_off_now >/dev/null 2>&1 || warn "BMC 断电命令返回非零，继续观察"
    sleep 4
    st=$(power_status)
    printf '%s' "$st" | grep -qi 'is off' || warn "BMC 未报告已断电：$st"
    info "保持断电 ${OFF_DELAY}s —— 让 PSU 电容放净，这正是 DC 与 reboot 的本质区别"
    sleep "$OFF_DELAY"
    t_on=$(date +%s)
    info "上电…"
    power_on_now >/dev/null 2>&1 || warn "BMC 上电命令返回非零"
    ready=$(wait_ready)
    ROUND_OFF=$(( t_on - t_off ))

    if [ "$ready" = "-1" ]; then
        warn "系统在 ${BOOT_TIMEOUT}s 内没就绪 —— 本轮按 Pending，请查 BMC SEL 与 SOL 画面"
        ROUND_READY="-1"
        run_round "$ridx"; count_rc $?
        info "再发一次上电，尽量把后续轮次救回来…"
        power_on_now >/dev/null 2>&1 || true
        sleep 20
    else
        ROUND_READY="$ready"
        ok "系统就绪，耗时 ${ready}s"
        run_round "$ridx"; count_rc $?
    fi
    i=$((i + 1))
done

write_report

echo
echo -e "${BLUE}==================== 汇总 ====================${NC}"
info "PASS=$PASS_N  FAIL=$FAIL_N  Pending=$PEND_N"
info "判定口径：PASS = 无新增报错且与基线一致；FAIL = 有报错或漂移；Pending = 本轮没抓到数据"
info "★ 原始证据全部保留在 $OUTDIR/round-NN/，验收时可逐条复查"
echo

if [ "$FAIL_N" -gt 0 ]; then
    err "存在 FAIL 轮次，测试不通过"
    exit 1
fi
ok "全部轮次 PASS"
exit 0
