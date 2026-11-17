#!/bin/bash
# =============================================================================
# 硬盘温度采集 · 自检 / 协同回归
#   用法:  bash selftest.sh          # 只读检查（~5 秒，不改任何状态）
#          bash selftest.sh --full   # 含破坏性用例（注入温度/停采/删文件/重启容器）
#          bash selftest.sh --full --yes   # 非交互环境必须加 --yes
#   退出码: 0 全过；非 0 = 失败用例数；2 = 环境缺失
# =============================================================================
set -u

D=/boot/config/plugins/cooler-hddtemp
R=/usr/local/emhttp/plugins/cooler-hddtemp
OW=/mnt/user/appdata/coolercontrol
CFG="$D/settings.cfg"
LOG="$D/event.log"
PIDF=/tmp/cooler-hddtemp.pid
SCAN="$D/lib/scan.php"
CTL="$D/lib/control.php"
STATUS_RAM="$R/status.json"

MODE=quick
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --full) MODE=full ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done

PASS=0; FAIL=0
if [ -t 1 ]; then
  C_G=$'\033[32m'; C_RD=$'\033[31m'; C_YL=$'\033[33m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
  C_G=; C_RD=; C_YL=; C_B=; C_N=
fi
ok()  { printf "  ${C_G}PASS${C_N}  %s\n" "$1"; PASS=$((PASS+1)); }
bad() { printf "  ${C_RD}FAIL${C_N}  %s\n" "$1"; FAIL=$((FAIL+1)); }
eq()  { [ "${2:-}" = "${3:-}" ] && ok "$1 (${2:-})" || bad "$1（期望 ${3:-} 实际 ${2:-}）"; }
info(){ printf "  ${C_YL}----${C_N}  %s\n" "$1"; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖: $c"; exit 2; }; done; }
need php smartctl awk sed grep stat

# ---- 定位 hwmon（nct6687）与风扇通道 ----
HW=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = "nct6687" ] && echo "$h"; done | head -1)
[ -z "$HW" ] && { echo "未找到 nct6687 hwmon 设备"; exit 2; }
PWM_HDD="$HW/pwm6"; PWM_SSD="$HW/pwm5"; FAN_HDD="$HW/fan6_input"; FAN_SSD="$HW/fan5_input"

# ---- 备份与恢复 ----------------------------------------------------------
BK=$(mktemp -d /tmp/cct-selftest.XXXXXX)
cp -f "$CFG" "$BK/settings.cfg" 2>/dev/null
cp -f "$OW/hdd_temp" "$BK/hdd_temp" 2>/dev/null
cp -f "$OW/ssd_temp" "$BK/ssd_temp" 2>/dev/null
FULL_STARTED=0
PL="$BK/page.php"
tail -n +6 "$R/cooler-hddtemp.page" > "$PL" 2>/dev/null

restore_all() {
  # 恢复配置与温度文件
  [ -s "$BK/settings.cfg" ] && cp -f "$BK/settings.cfg" "$CFG"
  [ -s "$BK/hdd_temp" ] && cp -f "$BK/hdd_temp" "$OW/hdd_temp"
  [ -s "$BK/ssd_temp" ] && cp -f "$BK/ssd_temp" "$OW/ssd_temp"
  # 确保采集器在跑（FULL 模式可能停过）
  if [ "$FULL_STARTED" = "1" ]; then
    php "$CTL" status 2>/dev/null | grep -q '"running":true' || php "$CTL" start >/dev/null 2>&1
  fi
  rm -rf "$BK"
}
trap restore_all EXIT INT TERM

# ---- 工具函数 ------------------------------------------------------------
curve_pwm() { # $1=温度(°C) $2=hdd|ssd  → 期望 pwm
  php -r '
    function duty($p,$t){ if($t<=$p[0][0])return $p[0][1];
      for($i=1;$i<count($p);$i++){ if($t<=$p[$i][0]){ [$x0,$y0]=$p[$i-1]; [$x1,$y1]=$p[$i];
        return $y0+($t-$x0)*($y1-$y0)/($x1-$x0);} } return end($p)[1]; }
    $h=[[0,0],[30,20],[45,50],[55,100],[100,100]];
    $s=[[0,0],[33.5,0],[38.7,30],[50,100],[100,100]];
    $p = $argv[2]==="ssd" ? $s : $h;
    printf("%d", round(duty($p,(float)$argv[1])/100*255));
  ' "$1" "$2"
}
file_mc() { tr -d ' \n' < "$1" 2>/dev/null; }
cfg_get() { php -r '$c=json_decode(file_get_contents($argv[1]),true); $k=$argv[2];
  $v=$c[$k]??null; if(is_array($v)) printf("%d",count($v)); else printf("%s", is_bool($v)?($v?"1":"0"):(string)$v);' "$CFG" "$1"; }
agg_value() { # $1=hdd|ssd  → 期望毫摄氏度（按当前口径）
  php -r '
    $j=json_decode(file_get_contents($argv[1]),true);
    $c=json_decode(file_get_contents($argv[2]),true);
    $sel=array_flip($c["d"]??[]); $mode=$argv[3]==="ssd"?($c["sm"]??"avg"):($c["hm"]??"avg");
    $v=[];
    foreach(($j["temps"]??[]) as $t){ if(!isset($sel[$t["sn"]])) continue;
      $g = ($t["type"]==="ssd")?"ssd":"hdd"; if($g!==$argv[3]) continue; $v[]=$t["t"]; }
    if(!$v){ echo "NA"; exit; }
    echo (int)round(($mode==="max"?max($v):array_sum($v)/count($v))*1000);
  ' "$STATUS_RAM" "$CFG" "$1"
}

# ==========================================================================
echo "${C_B}硬盘温度采集 · 自检（$( [ "$MODE" = full ] && echo "full" || echo "quick" )）${C_N}"
echo "  时间: $(date '+%F %T')   设备: $HW"
echo

# ---------------------------------------------------------------- A 契约层
info "A. 静态契约"
CFG_OK=$(php -r '
  $c=json_decode(@file_get_contents($argv[1]),true);
  $need=["i","d","hm","sm","warn","hot"];
  $miss=array_diff($need,array_keys(is_array($c)?$c:[]));
  echo (is_array($c) && !$miss && is_array($c["d"]) && in_array($c["hm"],["avg","max"],true) && in_array($c["sm"],["avg","max"],true)) ? "ok":"bad";' "$CFG")
eq "A1 settings.cfg 结构（i/d/hm/sm/warn/hot）" "$CFG_OK" "ok"

for f in hdd_temp ssd_temp; do
  V=$(file_mc "$OW/$f")
  if echo "$V" | grep -qE '^[0-9]+$' && [ "${V:-0}" -ge 0 ] && [ "${V:-0}" -le 120000 ]; then
    ok "A2 $f 格式/范围合法 ($V)"
  else
    bad "A2 $f 非法值 [$V]"
  fi
done

SJ_OK=$(php -r '
  $j=json_decode(@file_get_contents($argv[1]),true); $c=json_decode(@file_get_contents($argv[2]),true);
  echo (is_array($j) && isset($j["temps"]) && is_array($j["temps"]) && (int)($j["disks"]??-1)===count($c["d"]??[]) && (int)($j["errors"]??1)===0)?"ok":"bad";' "$STATUS_RAM" "$CFG")
eq "A3 status.json 盘数/错误数" "$SJ_OK" "ok"

C_OK=1
for f in hdd_temp ssd_temp; do
  H=$(file_mc "$OW/$f"); C=$(docker exec CoolerControl cat "/etc/coolercontrol/$f" 2>/dev/null | tr -d ' \n')
  [ "$H" = "$C" ] || C_OK=0
done
[ "$C_OK" = "1" ] && ok "A4 容器内温度文件与宿主一致" || bad "A4 容器内温度与宿主不一致"

# ---------------------------------------------------------------- B 数值层
info "B. 数值一致性"
for g in hdd ssd; do
  EXP=$(agg_value "$g")
  ACT=$(file_mc "$OW/${g}_temp")
  if [ "$EXP" = "NA" ] || ! echo "$ACT" | grep -qE '^[0-9]+$'; then bad "B1 $g 无选中盘数据（EXP=$EXP ACT=$ACT）"
  elif [ $(( ACT - EXP )) -le 500 ] && [ $(( EXP - ACT )) -le 500 ]; then
    ok "B1 $g 聚合值 = 当前口径（期望 $EXP 实际 $ACT，单位毫摄氏度）"
  else
    bad "B1 $g 聚合值不符（期望 $EXP 实际 $ACT）"
  fi
done

# ---------------------------------------------------------------- C 控制层
info "C. 控制链路（静态反算）"
TH=$(awk "BEGIN{printf \"%.2f\", $(file_mc "$OW/hdd_temp")/1000}")
TS=$(awk "BEGIN{printf \"%.2f\", $(file_mc "$OW/ssd_temp")/1000}")
EH=$(curve_pwm "$TH" hdd); ES=$(curve_pwm "$TS" ssd)
AH=$(cat "$PWM_HDD" 2>/dev/null); AS=$(cat "$PWM_SSD" 2>/dev/null)
dh=$(( AH - EH )); [ $dh -lt 0 ] && dh=$(( -dh ))
ds=$(( AS - ES )); [ $ds -lt 0 ] && ds=$(( -ds ))
[ "$dh" -le 3 ] && ok "C1 HDD ${TH}°C → 期望 pwm $EH，实际 $AH" || bad "C1 HDD PWM 偏差过大（期望 $EH 实际 $AH）"
[ "$ds" -le 3 ] && ok "C1 SSD ${TS}°C → 期望 pwm $ES，实际 $AS" || bad "C1 SSD PWM 偏差过大（期望 $ES 实际 $AS）"

# ---------------------------------------------------------------- G 页面/运维
info "G. 页面注册与运维"
REG=$(php -r '
  $e=$argv[1];
  $p=explode("\n---\n", file_get_contents($e));
  if(count($p)!==2){ echo "split_fail"; exit; }
  $i=@parse_ini_string($p[0]);
  if(!$i || ($i["Menu"]??"")==="" || ($i["Icon"]??"")===""){ echo "header_fail"; exit; }
  echo "ok";' "$R/cooler-hddtemp.page")
eq "G1 .page 注册（\\n---\\n 切分 + Menu/Icon）" "$REG" "ok"
CR=$(grep -c $'\r' "$R/cooler-hddtemp.page" 2>/dev/null || true)
eq "G2 页面行尾为 LF（CR 计数）" "${CR:-0}" "0"

REND=$(php "$R/cooler-hddtemp.page" 2>/dev/null)
RN=$(echo "$REND" | grep -o 'data-sn=' | wc -l)
[ "$RN" -gt 0 ] && ok "G3 页面渲染出 $RN 块盘" || bad "G3 页面渲染无盘数据"
echo "$REND" | grep -q '#stop' && bad "G4 页面仍含已移除的停止按钮" || ok "G4 页面无 #stop 残留"

AJ=$(php -r '$_GET["scan"]="1"; $_SERVER["REQUEST_METHOD"]="GET"; include $argv[1];' "$PL" 2>/dev/null | php -r '
  $j=json_decode(stream_get_contents(STDIN),true);
  echo (is_array($j)&&count($j["hdd"]??[])===8&&count($j["ssd"]??[])===8)?"8+8":"bad";')
eq "G5 AJAX ?scan=1 返回 8+8" "$AJ" "8+8"

grep -q 'hddtemp/assets' /boot/config/go && ok "G6 go 含 assets 恢复" || bad "G6 go 缺少 assets 恢复"

RUNP=$(php "$CTL" status 2>/dev/null)
echo "$RUNP" | grep -q '"running":true' && ok "G7 采集器运行中" || bad "G7 采集器未运行"
INST=$(for p in $(pgrep -f 'cooler-hddtemp/scripts/collector.sh' 2>/dev/null); do
      [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "1" ] && echo x; done | wc -l)
eq "G8 采集器单实例（PPID=1）" "${INST:-0}" "1"
PIDS=$(for p in $(pgrep -f 'cooler-hddtemp/scripts/collector.sh' 2>/dev/null); do
      [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "1" ] && echo "$p"; done | head -1)
PF=$(cat "$PIDF" 2>/dev/null || echo "")
eq "G9 PID 文件与实际进程一致" "${PF:-none}" "${PIDS:-none}"

# ================================================================ FULL 模式
if [ "$MODE" = "full" ]; then
  if [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    echo
    echo "${C_YL}即将执行破坏性用例：停采集器、注入温度、删除温度文件、重启容器。${C_N}"
    echo "期间风扇会短时升到 100%（fail-safe），约需 2 分钟。"
    read -r -p "继续？[y/N] " ans
    [ "${ans:-n}" = "y" ] || { echo "已取消"; exit 0; }
  fi
  FULL_STARTED=1

  info "D. 注入跟随（先停采集器，避免覆盖）"
  php "$CTL" stop >/dev/null 2>&1; sleep 2
  for pair in "30000 34000" "45000 39000" "55000 50000"; do
    set -- $pair
    echo "$1" > "$OW/hdd_temp"; echo "$2" > "$OW/ssd_temp"
    sleep 2
    e6=$(curve_pwm "$(awk "BEGIN{print $1/1000}")" hdd); e5=$(curve_pwm "$(awk "BEGIN{print $2/1000}")" ssd)
    a6=$(cat "$PWM_HDD"); a5=$(cat "$PWM_SSD")
    d6=$(( a6 - e6 )); [ $d6 -lt 0 ] && d6=$(( -d6 ))
    d5=$(( a5 - e5 )); [ $d5 -lt 0 ] && d5=$(( -d5 ))
    [ "$d6" -le 3 ] && [ "$d5" -le 3 ] \
      && ok "D1 注入 $(($1/1000))/$(($2/1000))°C → pwm $a6/$a5（期望 $e6/$e5）" \
      || bad "D1 注入 $(($1/1000))/$(($2/1000))°C → pwm $a6/$a5（期望 $e6/$e5）"
    [ $((a6)) -ge 200 ] && [ -n "$(cat "$FAN_HDD" 2>/dev/null)" ] && ok "D2 高 PWM 下 fan6=$(cat "$FAN_HDD")rpm 有读数"
  done

  info "E. 停采不触发 fail-safe（15 秒）"
  echo "$(file_mc "$BK/hdd_temp")" > "$OW/hdd_temp"; echo "$(file_mc "$BK/ssd_temp")" > "$OW/ssd_temp"
  sleep 3
  P0=$(cat "$PWM_HDD")
  sleep 15
  P1=$(cat "$PWM_HDD")
  [ "$P0" = "$P1" ] && ok "E1 停采 15 秒 pwm 保持 $P0（未 fail-safe）" || bad "E1 停采后 pwm 由 $P0 变为 $P1"

  info "F. 异常文件 → fail-safe（每个约 15 秒）"
  failsafe_case() {
    local name="$1" act="$2"
    rm -f "$OW/hdd_temp"; eval "$act"
    local hit=0
    for i in $(seq 1 6); do
      sleep 3
      [ "$(cat "$PWM_HDD")" -ge 200 ] && { hit=$((i*3)); break; }
    done
    [ "$hit" -gt 0 ] && ok "F1 $name → ${hit} 秒内 fail-safe（pwm $(cat "$PWM_HDD")）" || bad "F1 $name 未触发 fail-safe"
    cp -f "$BK/hdd_temp" "$OW/hdd_temp"; sleep 4
    [ "$(cat "$PWM_HDD")" -lt 200 ] && ok "F2 $name 恢复文件后回落（pwm $(cat "$PWM_HDD")）" || bad "F2 $name 恢复后未回落"
  }
  failsafe_case "删除文件" ":"
  failsafe_case "超范围 200000" "echo 200000 > '$OW/hdd_temp'"
  failsafe_case "非数字 abc" "echo abc > '$OW/hdd_temp'"

  info "H. 模式热切换（不重启）"
  php "$CTL" start >/dev/null 2>&1; sleep 5
  P_BEFORE=$(cat "$PIDF" 2>/dev/null || echo "")
  for mode in avg max; do
    php -r '
      $c=json_decode(file_get_contents($argv[1]),true);
      $_SERVER["REQUEST_METHOD"]="POST";
      $_POST=["#apply"=>"1","interval"=>strval($c["i"]),"disks"=>$c["d"],
        "hdd_mode"=>$argv[2],"ssd_mode"=>$argv[2],"warn"=>strval($c["warn"]??40),"hot"=>strval($c["hot"]??50)];
      ob_start(); include $argv[3]; ob_end_clean();' "$CFG" "$mode" "$PL" 2>/dev/null
    sleep 7
    V=$(file_mc "$OW/hdd_temp"); E=$(agg_value hdd)
    [ "$V" = "$E" ] && ok "H1 切到 $mode 后 hdd_temp=$V 与口径一致" || bad "H1 切到 $mode 后 hdd_temp=$V 与期望 $E 不符"
  done
  P_AFTER=$(cat "$PIDF" 2>/dev/null || echo "")
  eq "H2 切换未重启采集器" "$P_AFTER" "$P_BEFORE"

  info "I. 容器重启后接管"
  docker restart CoolerControl >/dev/null 2>&1; sleep 18
  docker logs --since 40s CoolerControl 2>&1 | grep -q 'Successfully applied:: nct6687 | hdd (fan6)' \
    && ok "I1 容器重启后重新应用 hdd 曲线" || bad "I1 容器重启后未看到应用日志"
  [ "$(cat "$PWM_HDD")" -gt 40 ] && ok "I2 重启后 pwm6=$(cat "$PWM_HDD") 已回到控制值" || bad "I2 重启后 pwm6 未恢复"
fi

# ==========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  printf "${C_G}${C_B}全部通过${C_N}：PASS=%d FAIL=0\n" "$PASS"
  exit 0
else
  printf "${C_RD}${C_B}存在失败${C_N}：PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
  exit "$FAIL"
fi
