#!/bin/bash
# ==============================================================================
# CoolerControl HDD/SSD 温度采集器 v1.1
# 通过 smartctl 读取磁盘温度，输出毫摄氏度文件供 CoolerControl File 传感器使用
# 支持 SATA / SAS 硬盘 | 环形日志 | 采集统计
# ==============================================================================

# ── 路径常量 ────────────────────────────────────────────────────────────────
CFG="/boot/config/plugins/cooler-hddtemp/settings.cfg"
OUT_HDD="/mnt/user/appdata/coolercontrol/hdd_temp"
OUT_SSD="/mnt/user/appdata/coolercontrol/ssd_temp"
STATUS="/usr/local/emhttp/plugins/cooler-hddtemp/status.json"
D="/boot/config/plugins/cooler-hddtemp"
LOG_FILE="$D/event.log"
LOG_MAX_LINES=500
LOG_ROTATE_AT=1000     # 高水位: 累积到 1000 行才轮转回 500 行（原逻辑满 500 行后每轮整份重写，U 盘 551MB/天）
LOG_MAX_KB=128

# ── 环形日志函数 ────────────────────────────────────────────────────────────
# 写入 event.log，自动轮转: 超过 LOG_MAX_LINES 或 LOG_MAX_KB 则截断后半
log() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%F %T')
    local entry="[$ts] [$level] $msg"

    # 追加
    echo "$entry" >> "$LOG_FILE"

    # 轮转检查: 行数超限 → 截断保留最后 LOG_MAX_LINES 行
    local lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$LOG_ROTATE_AT" ]; then
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi

    # 轮转检查: 大小超限
    local sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt $((LOG_MAX_KB * 1024)) ]; then
        tail -c $((LOG_MAX_KB * 1024)) "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# ── find_dev：根据序列号查找设备路径 ─────────────────────────────────────────
# 策略: 1) /dev/disk/by-id/ (SATA 适用)
#       2) 遍历 /dev/sd? 用 smartctl 匹配序列号 (SAS fallback)
find_dev() {
    local sn="$1"

    # 第1步: 尝试 by-id 符号链接 (仅 SATA 盘存在)
    for id in /dev/disk/by-id/*; do
        if echo "$id" | grep -qi "$sn" 2>/dev/null; then
            local dev=$(readlink -f "$id" 2>/dev/null)
            [ -n "$dev" ] && [ -b "$dev" ] && { echo "$dev"; return 0; }
        fi
    done

    # 第2步: 遍历所有 /dev/sd? 匹配序列号 (SAS HBA 连接的盘)
    for d in /dev/sd?; do
        [ ! -b "$d" ] && continue
        local s=$(smartctl -i "$d" 2>/dev/null | grep -i "^Serial" | awk '{print $NF}')
        if [ "$s" = "$sn" ]; then echo "$d"; return 0; fi
    done
    return 1
}

# ── get_info：获取单个磁盘的温度和类型 ───────────────────────────────────────
# 输出格式: <温度(°C)>|<类型>
#   类型: hdd / ssd / sas
#   失败时返回: 0|hdd (温度 0 会被调用方过滤掉)
get_info() {
    local dev=$(find_dev "$1")
    [ -z "$dev" ] && { echo "0|hdd"; return; }

    local info=$(smartctl -iA "$dev" 2>/dev/null)

    # 提取温度
    local t=$(echo "$info" \
        | grep -i 'Temperature_Celsius' \
        | sed 's/.*- *\([0-9]*\).*/\1/' \
        | grep -E '^[0-9]+$' \
        | head -1)
    [ -z "$t" ] && t=$(echo "$info" | grep -i 'Current Drive Temperature' | grep -o '[0-9]\+' | head -1)
    t=${t:-0}

    # 判断磁盘类型
    local typ="hdd"
    echo "$info" | grep -q "Solid State Device" && typ="ssd"
    echo "$info" | grep -q "Transport protocol:.*SAS" && typ="sas"

    echo "${t}|${typ}"
}

# ── 启动日志 ──
log "INFO" "采集器启动 (PID=$$)"

# ── 主循环 ───────────────────────────────────────────────────────────────────
while true; do
    T0=$(date +%s)

    # ---- 读取配置 ----
    CFG_DATA=$(perl -e '
use JSON; open F,"<","'"$CFG"'"; local $/; my $c=decode_json(<F>); close F;
print "IV=".($c->{i}//30)."\n";
print "HM=".($c->{hm}//"avg")."\n";
print "SM=".($c->{sm}//"avg")."\n";
print "HOT=".($c->{hot}//50)."\n";
print "AUTO=".($c->{auto}?1:0)."\n";
for my $s (@{$c->{d}//$c->{disks}//[]}){print "$s\n";}
' 2>/dev/null)

    IV=$(echo "$CFG_DATA" | grep "^IV=" | cut -d= -f2); IV=${IV:-30}
    HM=$(echo "$CFG_DATA" | grep "^HM=" | cut -d= -f2); HM=${HM:-avg}
    SM=$(echo "$CFG_DATA" | grep "^SM=" | cut -d= -f2); SM=${SM:-avg}
    HOT=$(echo "$CFG_DATA" | grep "^HOT=" | cut -d= -f2); HOT=${HOT:-50}
    AUTO=$(echo "$CFG_DATA" | grep "^AUTO=" | cut -d= -f2); AUTO=${AUTO:-0}
    SERIALS=$(echo "$CFG_DATA" | grep -v "^IV=\|^HM=\|^SM=\|^HOT=\|^AUTO=")

    # ---- 自动纳入新盘（auto=1，最多每 60 秒探测一次）----
    if [ "$AUTO" = "1" ]; then
        DISC_F=/tmp/cooler-hddtemp-discover
        NOW=$(date +%s)
        LAST=$(cat "$DISC_F" 2>/dev/null || echo 0)
        if [ $((NOW - LAST)) -ge 60 ]; then
            MERGED=$(php "$D/lib/scan.php" 2>/dev/null | php "$D/lib/autoadd.php" 2>/tmp/cooler-hddtemp-auto.err)
            echo "$NOW" > "$DISC_F"
            [ -n "$MERGED" ] && SERIALS="$MERGED"
            AUTO_MSG=$(cat /tmp/cooler-hddtemp-auto.err 2>/dev/null)
            [ -n "$AUTO_MSG" ] && log "INFO" "自动纳入: $AUTO_MSG"
        fi
    fi

    # ---- 采集温度 ----
    SUM_HDD=0; CNT_HDD=0; MAX_HDD=0
    SUM_SSD=0; CNT_SSD=0; MAX_SSD=0
    DISK_OK=0; DISK_ERR=0
    TEMP_LIST=""          # 每盘温度列表 (JSON: [{"sn":"...","t":40,"type":"hdd"},...])

    for sn in $SERIALS; do
        [ -z "$sn" ] && continue
        INFO=$(get_info "$sn")
        T=$(echo "$INFO" | cut -d'|' -f1)
        TYPE=$(echo "$INFO" | cut -d'|' -f2)

        if [ "$T" -le 0 ] 2>/dev/null; then
            DISK_ERR=$((DISK_ERR + 1))
            [ -n "$TEMP_LIST" ] && TEMP_LIST="$TEMP_LIST,"
            TEMP_LIST="${TEMP_LIST}{\"sn\":\"$sn\",\"t\":-1,\"type\":\"$TYPE\"}"
            continue
        fi

        DISK_OK=$((DISK_OK + 1))
        [ -n "$TEMP_LIST" ] && TEMP_LIST="$TEMP_LIST,"
        TEMP_LIST="${TEMP_LIST}{\"sn\":\"$sn\",\"t\":$T,\"type\":\"$TYPE\"}"

        # 单盘温度告警阈值
        [ "$T" -ge "$HOT" ] && log "WARN" "高温: $sn = ${T}°C ($TYPE, 阈值 ${HOT}°C)"

        if [ "$TYPE" = "ssd" ]; then
            SUM_SSD=$((SUM_SSD + T))
            CNT_SSD=$((CNT_SSD + 1))
            [ "$T" -gt "$MAX_SSD" ] && MAX_SSD=$T
        else
            SUM_HDD=$((SUM_HDD + T))
            CNT_HDD=$((CNT_HDD + 1))
            [ "$T" -gt "$MAX_HDD" ] && MAX_HDD=$T
        fi
    done

    # 记录扫描失败
    [ "$DISK_ERR" -gt 0 ] && log "ERROR" "扫描失败: ${DISK_ERR}/$((DISK_ERR + DISK_OK)) 盘"

    # ---- 计算并输出 (毫摄氏度) ----
    HDD_VAL=-1; SSD_VAL=-1

    if [ "$CNT_HDD" -gt 0 ]; then
        if [ "$HM" = "max" ]; then
            HDD_VAL=$((MAX_HDD * 1000))
        else
            HDD_VAL=$((SUM_HDD * 1000 / CNT_HDD))
        fi
        echo "$HDD_VAL" > "$OUT_HDD"
    fi

    if [ "$CNT_SSD" -gt 0 ]; then
        if [ "$SM" = "max" ]; then
            SSD_VAL=$((MAX_SSD * 1000))
        else
            SSD_VAL=$((SUM_SSD * 1000 / CNT_SSD))
        fi
        echo "$SSD_VAL" > "$OUT_SSD"
    fi

    # ---- 写入状态 JSON (printf 构建, 避免 perl 的 shell 转义问题) ----
    ELAPSED=$(($(date +%s) - T0))
    printf '{"hdd":%d,"ssd":%d,"time":"%s","elapsed":%d,"disks":%d,"errors":%d,"temps":[%s]}\n' \
        "$HDD_VAL" "$SSD_VAL" "$(date +%H:%M:%S)" "$ELAPSED" "$DISK_OK" "$DISK_ERR" "$TEMP_LIST" \
        > "$STATUS"

    # 记录 INFO
    HDD_TXT="n/a"; [ "$HDD_VAL" -ge 0 ] && HDD_TXT=$((HDD_VAL / 1000))
    SSD_TXT="n/a"; [ "$SSD_VAL" -ge 0 ] && SSD_TXT=$((SSD_VAL / 1000))
    log "INFO" "轮次: ${DISK_OK}盘, HDD=${HDD_TXT}°C, SSD=${SSD_TXT}°C, 耗时${ELAPSED}s"

    # ---- 动态间隔 ----
    SLEEP=$((IV - ELAPSED))
    [ "$SLEEP" -lt 2 ] && SLEEP=2
    sleep "$SLEEP"
done
