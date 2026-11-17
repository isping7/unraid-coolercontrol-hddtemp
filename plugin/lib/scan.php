#!/usr/bin/php
<?php
/* =============================================================================
 * 硬盘温度采集 · 磁盘域（CLI）
 * 用法: php scan.php            → JSON { hdd:[…], ssd:[…] }
 * 职责: smartctl 扫描 SATA/SAS、解析型号/序列号/温度、按 Unraid 槽位排序
 * 只读，不写任何文件
 * ========================================================================== */

/** 阵列槽位顺序: slot => diskId（slot 0=Parity, 1..7=Data） */
function array_slot_map(): array {
    $map = [];
    exec("/usr/local/sbin/mdcmd status 2>/dev/null | grep -E '^diskId\.[0-9]+='", $lines);
    foreach ($lines as $line) {
        if (preg_match('/^diskId\.(\d+)=(\S+)/', trim($line), $m) && $m[2] !== '') {
            $map[intval($m[1])] = $m[2];
        }
    }
    return $map;
}

/** 缓存池槽位顺序: slot => diskId（来自 /boot/config/pools/*.cfg） */
function pool_slot_map(): array {
    $map = [];
    foreach (glob('/boot/config/pools/*.cfg') as $cfg) {
        $c = @file_get_contents($cfg);
        if ($c === false) continue;
        foreach (explode("\n", $c) as $line) {
            if (preg_match('/^diskId(?:\.(\d+))?="([^"]+)"/', $line, $m)) {
                $map[$m[1] === '' ? 0 : intval($m[1])] = $m[2];
            }
        }
    }
    return $map;
}

function scan_disks(): array {
    $seen = []; $hdd = []; $ssd = [];
    exec('smartctl --scan-open 2>/dev/null', $lines);
    foreach ($lines as $line) {
        if (!preg_match('#^(/dev/\w+)\s#', $line, $m)) continue;
        $dev = $m[1];

        $r = []; exec('smartctl -i ' . escapeshellarg($dev) . ' 2>/dev/null', $r);
        $f = implode("\n", $r);

        $model = '';
        if (preg_match('/Device Model:\s+(.+)/', $f, $m)) $model = trim($m[1]);
        elseif (preg_match('/Product:\s+(.+)/', $f, $m)) $model = trim($m[1]);

        $serial = '';
        if (preg_match('/^Serial (?:Number|number):\s+(\S+)/m', $f, $m)) $serial = $m[1];
        if (!$serial || isset($seen[$serial])) continue;
        $seen[$serial] = true;

        $is_sas = (preg_match('/Transport protocol:\s+SAS/', $f) === 1);
        $is_ssd = (strpos($f, 'Solid State Device') !== false);
        // 变速盘（WD Green 等）无 Rotation Rate 字段，用 ATA Version 兜底
        $is_hdd = !$is_ssd && ($is_sas
            || preg_match('/Rotation Rate:\s+(\d+)\s*rpm/', $f)
            || preg_match('/ATA Version is:/', $f));
        if (!$is_hdd && !$is_ssd) continue;

        $temp = null;
        $r2 = []; exec('smartctl -A ' . escapeshellarg($dev) . ' 2>/dev/null', $r2);
        $f2 = implode("\n", $r2);
        if (preg_match('/Temperature_Celsius.*?-\s+(\d+)/', $f2, $m)) $temp = intval($m[1]);
        elseif (preg_match('/Current Drive Temperature:\s+(\d+)/', $f2, $m)) $temp = intval($m[1]);

        $d = ['dev' => $dev, 'model' => $model, 'serial' => $serial, 'sas' => $is_sas, 'temp' => $temp];
        if ($is_ssd) $ssd[] = $d; else $hdd[] = $d;
    }

    // 与主界面「磁盘阵列设备」一致：Parity → Disk1..7 → 缓存池 → 未分配
    $a = array_slot_map();
    $p = pool_slot_map();
    $rank = function ($serial) use ($a, $p) {
        foreach ($a as $slot => $did) {
            if ($did !== '' && strpos($did, $serial) !== false) return $slot;
        }
        foreach ($p as $slot => $did) {
            if ($did !== '' && strpos($did, $serial) !== false) return 100 + $slot;
        }
        return 900;
    };
    $cmp = function ($x, $y) use ($rank) {
        $rx = $rank($x['serial']); $ry = $rank($y['serial']);
        return $rx != $ry ? $rx - $ry : strcmp($x['serial'], $y['serial']);
    };
    usort($hdd, $cmp);
    usort($ssd, $cmp);

    return ['hdd' => $hdd, 'ssd' => $ssd];
}

header('Content-Type: application/json; charset=utf-8');
echo json_encode(scan_disks(), JSON_UNESCAPED_UNICODE);
