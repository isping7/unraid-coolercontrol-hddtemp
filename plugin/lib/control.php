#!/usr/bin/php
<?php
/* =============================================================================
 * 硬盘温度采集 · 进程域（CLI）
 * 用法: php control.php status|start|stop  → JSON
 * 职责: 采集器进程的启停与存活判定（PID 文件 + /proc/<pid>/cmdline 双重校验）
 * ========================================================================== */

const CCT_PID = '/tmp/cooler-hddtemp.pid';
const CCT_COL = '/boot/config/plugins/cooler-hddtemp/scripts/collector.sh';

/** 存活判定：PID 文件 → /proc 命令行长什么样 → kill -0 */
function cct_running(): array {
    if (!file_exists(CCT_PID)) return ['running' => false, 'pid' => 0];
    $p = intval(trim(file_get_contents(CCT_PID)));
    if ($p <= 0) return ['running' => false, 'pid' => 0];
    $cmd = @file_get_contents("/proc/$p/cmdline");
    if ($cmd === false || strpos($cmd, 'cooler-hddtemp') === false) return ['running' => false, 'pid' => $p];
    exec("kill -0 $p 2>/dev/null", $o, $c);
    return ['running' => $c === 0, 'pid' => $p];
}

function cct_stop(): array {
    $st = cct_running();
    if ($st['running'] && $st['pid'] > 0) {
        exec('kill ' . $st['pid'] . ' 2>/dev/null');
        usleep(300000);
        exec('kill -9 ' . $st['pid'] . ' 2>/dev/null');
    }
    // 兜底：清掉可能残留的实例
    exec("pkill -f 'cooler-hddtemp/scripts/collector.sh' 2>/dev/null");
    @unlink(CCT_PID);
    return ['running' => false, 'pid' => 0, 'action' => 'stop'];
}

function cct_start(): array {
    $st = cct_running();
    if ($st['running']) return $st + ['action' => 'start', 'already' => true];
    $o = [];
    exec('nohup bash ' . escapeshellarg(CCT_COL) . ' > /dev/null 2>&1 & echo $!', $o);
    $p = intval(trim(implode('', $o)));
    if ($p > 0) @file_put_contents(CCT_PID, $p);
    return ['running' => $p > 0, 'pid' => $p, 'action' => 'start'];
}

$cmd = $argv[1] ?? 'status';
$out = match ($cmd) {
    'start' => cct_start(),
    'stop'  => cct_stop(),
    default => cct_running() + ['action' => 'status'],
};

header('Content-Type: application/json; charset=utf-8');
echo json_encode($out, JSON_UNESCAPED_UNICODE);
