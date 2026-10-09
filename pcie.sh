#!/bin/bash
# ============================================================
# 独立 PCIe 检测脚本
# 功能：按设备类型分组显示 PCIe 链路状态，仅提示不终止
# 用法：sudo bash pcie_check.sh
# 输出：终端彩色打印，临时文件自动清理
# ============================================================

# ---------- 前置权限校验 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "【错误】请使用 root 权限运行此脚本！"
    exit 1
fi

# ---------- 原样复制 sl 函数（无任何改动） ----------
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
            # ★ 必须先判「读不到」：LnkCap / LnkSta 缺任一项时两者都会被填成「未知」，
            #   直接落到 else 会把「读不到」误报成「不匹配」（假阳性）。
            local speed_note width_note
            if [ "${cap_speed}" = "未知" ] || [ "${sta_speed}" = "未知" ];then
                speed_note="未读到速率"
            elif [ "${cap_speed}" = "${sta_speed}" ];then
                speed_note="正常"
            else
                speed_note="警告：速率不匹配"
            fi
            if [ "${cap_width}" = "未知" ] || [ "${sta_width}" = "未知" ];then
                width_note="未读到宽度"
            elif [ "${cap_width}" = "${sta_width}" ];then
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

# ---------- 执行 ----------
# 设置 m=1（每行显示一个设备，与原脚本中的调用方式一致）
m=1
sl
