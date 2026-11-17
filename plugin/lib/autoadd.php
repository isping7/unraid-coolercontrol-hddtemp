#!/usr/bin/php
<?php
/* =============================================================================
 * 硬盘温度采集 · 自动纳入新盘（CLI，纯逻辑，无副作用时零写入）
 * 用法: php lib/scan.php | php lib/autoadd.php
 *  stdin : scan.php 输出的 JSON { hdd:[…], ssd:[…] }
 *  stdout: 合并后的序列号列表（每行一个，HDD 在前、SSD 在后，按槽位顺序）
 *  stderr: 一句话摘要（有变更时），供采集器写进 event.log
 *
 * 仅在 settings.cfg 的 "auto" 为真时才改动配置；否则只回显现有列表。
 * 配置写入为原子写（tmp → JSON 校验 → rename），避免采集器读到半截文件。
 * ========================================================================== */

$D   = '/boot/config/plugins/cooler-hddtemp';
$CFG = "$D/settings.cfg";

$raw = stream_get_contents(STDIN);
$scan = json_decode((string)$raw, true);
if (!is_array($scan)) {
    fwrite(STDERR, 'scan 输出解析失败');
    exit(1);
}

// 实际在位的盘：HDD 组在前、SSD 组在后，各自已是槽位顺序
$actual = [];
foreach (array_merge($scan['hdd'] ?? [], $scan['ssd'] ?? []) as $d) {
    $sn = $d['serial'] ?? '';
    if ($sn !== '' && !in_array($sn, $actual, true)) $actual[] = $sn;
}

$cfg = json_decode((string)@file_get_contents($CFG), true);
if (!is_array($cfg)) {
    fwrite(STDERR, 'settings.cfg 解析失败，跳过');
    exit(1);
}

$current = is_array($cfg['d'] ?? null) ? array_values($cfg['d']) : [];

if (!empty($cfg['auto'])) {
    $added   = array_values(array_diff($actual, $current));
    $removed = array_values(array_diff($current, $actual));

    if ($added || $removed) {
        $newCfg = $cfg;
        $newCfg['d'] = $actual;

        $tmp  = $CFG . '.tmp';
        $json = json_encode($newCfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
        $ok = false;
        if ($json !== false && @file_put_contents($tmp, $json) !== false) {
            if (is_array(json_decode((string)@file_get_contents($tmp), true))) {
                $ok = @rename($tmp, $CFG);
            }
            if (!$ok) @unlink($tmp);
        }

        if ($ok) {
            $parts = [];
            if ($added)   $parts[] = '新增 ' . count($added) . '（' . implode(',', $added) . '）';
            if ($removed) $parts[] = '移除 ' . count($removed) . '（' . implode(',', $removed) . '）';
            fwrite(STDERR, implode('，', $parts));
            $current = $actual;
        } else {
            fwrite(STDERR, '配置写入失败，本轮沿用旧列表');
        }
    }
}

foreach ($current as $sn) echo $sn, "\n";
