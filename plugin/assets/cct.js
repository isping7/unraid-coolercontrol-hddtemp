/* =============================================================================
 * 硬盘温度采集 · 交互（无内联脚本依赖）
 * 职责：轮询刷新 / 未保存提示 / 刷新列表 / 抽屉 / 导出复制 / 语言切换
 * 数据来源：<div id="cct-data"> 的 data-* 属性（由 PHP 渲染）
 * ========================================================================== */
(function () {
  'use strict';

  var dataEl = document.getElementById('cct-data');
  if (!dataEl) return;

  var CCT = {
    i: parseInt(dataEl.dataset.i || '10', 10),
    warn: parseInt(dataEl.dataset.warn || '40', 10),
    hot: parseInt(dataEl.dataset.hot || '50', 10),
    rows: JSON.parse(dataEl.dataset.rows || '[]')
  };
  var COLOR = { ok: '#16a34a', warn: '#ea8c00', hot: '#dc2626' };
  var muted = '#94a3b8';

  function cls(t) { return t === null || t === undefined ? '' : (t >= CCT.hot ? 'hot' : (t >= CCT.warn ? 'warn' : 'ok')); }
  function colorOf(t) { var c = cls(t); return t === null || t === undefined ? muted : (COLOR[c] || muted); }
  function pct(t) { return t === null || t === undefined ? 0 : Math.max(0, Math.min(100, (t - 20) / 40 * 100)); }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /* ---------- 抽屉 ---------- */
  function drawer(on) { document.body.classList.toggle('cct-drawer', !!on); }

  /* ---------- 全选 / 反选 ---------- */
  function toggleAll(which, selectAll) {
    var box = document.getElementById(which === 'hdd' ? 'rowsHdd' : 'rowsSsd');
    if (!box) return;
    Array.prototype.forEach.call(box.querySelectorAll('input[name="disks[]"]'), function (c) {
      c.checked = selectAll ? true : !c.checked;
    });
    checkDirty();
  }

  /* ---------- 未保存提示 ---------- */
  var baseline = null;
  var submitting = false;

  function snap() {
    var disks = {};
    Array.prototype.forEach.call(document.querySelectorAll('input[name="disks[]"]'), function (c) {
      disks[c.value] = c.checked;
    });
    var hm = document.querySelector('input[name="hdd_mode"]:checked');
    var sm = document.querySelector('input[name="ssd_mode"]:checked');
    return JSON.stringify({
      i: document.getElementById('fInterval').value,
      hm: hm ? hm.value : '',
      sm: sm ? sm.value : '',
      w: document.getElementById('fWarn').value,
      h: document.getElementById('fHot').value,
      a: document.getElementById('fAuto').checked ? '1' : '0',
      d: disks
    });
  }

  function label(mode, L) { return mode === 'max' ? (L === 'en' ? 'Max' : '最大') : (L === 'en' ? 'Avg' : '平均'); }

  function diffText() {
    if (!baseline) return '';
    var a = JSON.parse(baseline), b = JSON.parse(snap()), out = [];
    var lang = document.documentElement.getAttribute('lang') || 'zh';
    var en = lang.indexOf('en') === 0;
    if (a.i !== b.i) out.push((en ? 'Interval ' : '间隔 ') + a.i + 's → ' + b.i + 's');
    if (a.hm !== b.hm) out.push('HDD ' + label(a.hm, lang) + ' → ' + label(b.hm, lang));
    if (a.sm !== b.sm) out.push('SSD ' + label(a.sm, lang) + ' → ' + label(b.sm, lang));
    if (a.w !== b.w) out.push((en ? 'Warn ' : '告警 ') + a.w + ' → ' + b.w + '°C');
    if (a.h !== b.h) out.push((en ? 'Hot ' : '高温 ') + a.h + ' → ' + b.h + '°C');
    if (a.a !== b.a) out.push(en ? 'Auto-add ' + (a.a === '1' ? 'on→off' : 'off→on') : '自动纳入 ' + (a.a === '1' ? '开→关' : '关→开'));
    var an = Object.keys(a.d).filter(function (k) { return a.d[k]; }).length;
    var bn = Object.keys(b.d).filter(function (k) { return b.d[k]; }).length;
    if (an !== bn) out.push((en ? 'Disks ' : '盘数 ') + an + ' → ' + bn);
    return out.join(en ? ', ' : '，');
  }

  function checkDirty() {
    var bar = document.getElementById('dirty');
    if (!bar) return;
    var d = diffText();
    var txt = document.getElementById('dirtyText');
    var prefix = bar.getAttribute('data-label') || '有未保存的更改';
    if (d) { txt.innerHTML = '● ' + prefix + (document.documentElement.lang.indexOf('en') === 0 ? ': ' : '：') + '<b>' + esc(d) + '</b>'; bar.classList.add('on'); }
    else { bar.classList.remove('on'); }
  }

  function resetForm() { submitting = true; location.reload(); }

  /* ---------- 轮询 ---------- */
  function setStat(id, t, dotId) {
    var el = document.getElementById(id);
    if (!el) return;
    el.innerHTML = (t === null || t === undefined ? '—' : t.toFixed(1)) + '<small>°C</small>';
    var col = colorOf(t);
    el.style.color = col;
    var dot = document.getElementById(dotId);
    if (dot) dot.style.background = col;
  }

  function applyStatus(d) {
    var hMax = null, sMax = null;
    (d.temps || []).forEach(function (t) {
      var row = document.querySelector('.row[data-sn="' + t.sn + '"]');
      if (!row) return;
      var temp = t.t < 0 ? null : t.t;
      var el = row.querySelector('.t');
      var bar = row.querySelector('.bar i');
      var c = cls(temp);
      row.className = 'row' + (c === 'hot' || c === 'warn' ? ' ' + c : '');
      if (el) { el.textContent = temp === null ? '—' : temp + '°C'; el.style.color = colorOf(temp); }
      if (bar) { bar.style.width = pct(temp) + '%'; bar.style.background = colorOf(temp); }
      if (temp !== null) {
        if (t.type === 'ssd') sMax = Math.max(sMax === null ? 0 : sMax, temp);
        else hMax = Math.max(hMax === null ? 0 : hMax, temp);
      }
    });
    setStat('vHdd', hMax, 'dotHdd');
    setStat('vSsd', sMax, 'dotSsd');
    var hh = document.getElementById('hiHdd'), hs = document.getElementById('hiSsd');
    var mLbl = document.getElementById('maxLabel');
    if (hh) hh.textContent = (mLbl ? mLbl.getAttribute('data-max') : '最高') + ' ' + (hMax === null ? '—' : hMax + '°C');
    if (hs) hs.textContent = (mLbl ? mLbl.getAttribute('data-max') : '最高') + ' ' + (sMax === null ? '—' : sMax + '°C');
    var hv = document.getElementById('vHealth');
    if (hv) {
      var bad = (d.errors || 0) > 0;
      hv.textContent = hv.getAttribute(bad ? 'data-bad' : 'data-ok') || (bad ? '异常' : '正常');
      hv.style.color = bad ? 'var(--hot)' : 'var(--ok)';
    }
  }

  function poll() {
    var x = new XMLHttpRequest();
    x.open('GET', '/plugins/cooler-hddtemp/status.json?t=' + Date.now(), true);
    x.timeout = 5000;
    x.onreadystatechange = function () {
      if (x.readyState !== 4 || x.status !== 200) return;
      try { applyStatus(JSON.parse(x.responseText)); } catch (e) { /* 半截 JSON 时跳过 */ }
    };
    x.send();
  }

  /* ---------- 刷新列表（不重启采集）---------- */
  function rowHtml(d) {
    var t = d.temp, c = cls(t);
    var tag = d.sas ? '<span class="tag sas">SAS</span>' : '<span class="tag">SATA</span>';
    return '<div class="row' + ((c === 'hot' || c === 'warn') ? ' ' + c : '') + '" data-sn="' + esc(d.serial) + '">'
      + '<input class="cb" type="checkbox" name="disks[]" value="' + esc(d.serial) + '" ' + (d.checked ? 'checked' : '') + '>'
      + '<div class="id"><div class="m">' + esc(d.model || d.dev) + '</div><div class="s">' + esc(d.serial) + '</div></div>'
      + tag
      + '<div class="tm"><span class="t" style="color:' + colorOf(t) + '">' + (t === null ? '—' : t + '°C') + '</span>'
      + '<span class="bar"><i style="width:' + pct(t) + '%;background:' + colorOf(t) + '"></i></span></div></div>';
  }

  function rescan() {
    var x = new XMLHttpRequest();
    x.open('GET', '?scan=1&t=' + Date.now(), true);
    x.timeout = 25000;
    x.onreadystatechange = function () {
      if (x.readyState !== 4 || x.status !== 200) return;
      try {
        var d = JSON.parse(x.responseText);
        var h = document.getElementById('rowsHdd'), s = document.getElementById('rowsSsd');
        if (h) h.innerHTML = (d.hdd || []).map(rowHtml).join('');
        if (s) s.innerHTML = (d.ssd || []).map(rowHtml).join('');
        var ch = document.getElementById('cntHdd'), cs = document.getElementById('cntSsd');
        var unit = document.getElementById('cntHdd') ? document.getElementById('cntHdd').getAttribute('data-unit') : '';
        if (ch) ch.textContent = (d.hdd || []).length + ' ' + (unit || '');
        if (cs) cs.textContent = (d.ssd || []).length + ' ' + (unit || '');
        checkDirty();
      } catch (e) { /* 忽略 */ }
    };
    x.send();
  }

  /* ---------- 导出 / 复制 ---------- */
  function tableRows() {
    return Array.prototype.map.call(document.querySelectorAll('.row[data-sn]'), function (r) {
      var m = r.querySelector('.m'), s = r.querySelector('.s'), t = r.querySelector('.t'), g = r.querySelector('.tag');
      return [m ? m.textContent : '', s ? s.textContent : '', t ? t.textContent.trim() : '', g ? g.textContent : ''];
    });
  }

  function exportCsv() {
    var lines = ['model,serial,temp,iface'].concat(tableRows().map(function (x) {
      return '"' + x.map(function (v) { return String(v).replace(/"/g, '""'); }).join('","') + '"';
    }));
    var blob = new Blob(['\ufeff' + lines.join('\n')], { type: 'text/csv;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'hdd-temp-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '') + '.csv';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  function copyTsv() {
    var text = tableRows().map(function (x) { return x.join('\t'); }).join('\n');
    if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text); return; }
    var ta = document.createElement('textarea');
    ta.value = text; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch (e) { /* 忽略 */ }
    ta.remove();
  }

  /* ---------- 语言切换 ---------- */
  function switchLang(lang) {
    document.cookie = 'cct_lang=' + lang + ';path=/;max-age=31536000';
    location.reload();
  }

  /* ---------- 绑定 ---------- */
  document.addEventListener('input', checkDirty);
  document.addEventListener('change', checkDirty);

  var form = document.getElementById('cctf');
  if (form) form.addEventListener('submit', function () { submitting = true; });

  window.addEventListener('beforeunload', function (e) {
    if (submitting) return;
    var bar = document.getElementById('dirty');
    if (bar && bar.classList.contains('on')) { e.preventDefault(); e.returnValue = ''; }
  });

  var iv = document.getElementById('fInterval');
  if (iv) iv.addEventListener('input', function () {
    var o = document.getElementById('oInterval'), n = document.getElementById('noteIv');
    if (o) o.textContent = iv.value + 's';
    if (n) n.textContent = iv.value;
  });

  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-act]');
    if (!t) return;
    var act = t.getAttribute('data-act');
    if (act === 'drawer') drawer(t.getAttribute('data-on') !== '0');
    else if (act === 'rescan') rescan();
    else if (act === 'reset') resetForm();
    else if (act === 'all') toggleAll(t.getAttribute('data-which'), t.getAttribute('data-sel') === '1');
    else if (act === 'export') exportCsv();
    else if (act === 'copy') copyTsv();
    else if (act === 'lang') switchLang(t.getAttribute('data-lang'));
  });

  baseline = snap();
  checkDirty();
  poll();
  setInterval(poll, Math.max(2000, CCT.i * 1000));
})();
