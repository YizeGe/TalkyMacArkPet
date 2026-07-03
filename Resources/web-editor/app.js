// ─── MacArkPet 配置管理 Web UI ───

const API_BASE = '';
let configData = { toml: '', parsed: {} };
let profilesData = [];
let historyLog = [];
let _dirty = false;

// ─── Tab 切换 ───
document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelector('.tab.active')?.classList.remove('active');
    tab.classList.add('active');
    document.querySelectorAll('.tab-content').forEach(tc => tc.classList.remove('active'));
    document.getElementById('tab-' + tab.dataset.tab)?.classList.add('active');
  });
});

// ─── 初始化 ───
document.addEventListener('DOMContentLoaded', () => {
  checkServer();
  refreshAll();
  initEventSource();
  setTimeout(loadHistoryFromServer, 1000);
  // 兜底：5 秒无 SSE 事件时回退到轮询
  setTimeout(function() {
    if (!_sseConnected) {
      console.warn('SSE 未连接，回退到轮询');
      setInterval(pollContext, 3000);
    }
  }, 5000);
});

function checkServer() {
  fetch('/api/status')
    .then(r => r.json())
    .then(d => {
      document.getElementById('statusDot').className = 'status-dot online';
      document.getElementById('serverStatus').textContent = '运行中 :' + d.port;
    })
    .catch(() => {
      document.getElementById('statusDot').className = 'status-dot offline';
      document.getElementById('serverStatus').textContent = '离线';
    });
}

function refreshAll() {
  loadConfig();
  loadProfiles();
  loadPets();
  if (typeof fetchAvailablePets === 'function') fetchAvailablePets();
}

function markDirty() {
  if (!_dirty) {
    _dirty = true;
    document.getElementById('dirtyBadge').classList.remove('hidden');
  }
}

function markClean() {
  _dirty = false;
  document.getElementById('dirtyBadge').classList.add('hidden');
}

window.addEventListener('beforeunload', e => {
  if (_dirty) { e.preventDefault(); e.returnValue = ''; }
});

function showToast(msg, type) {
  type = type || 'success';
  var t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast ' + type;
  t.classList.remove('hidden');
  clearTimeout(t._timer);
  t._timer = setTimeout(function() { t.classList.add('hidden'); }, 3000);
}

// ═══════════════════════════════════════
//  触发规则 — entries = [{key, values}, ...]
// ═══════════════════════════════════════

function loadConfig() {
  fetch('/api/config')
    .then(r => r.json())
    .then(d => {
      configData = d;
      renderCategories(d.parsed);
      updateStats(d.parsed);
      populateBatchSelects();
    })
    .catch(e => showToast('加载配置失败: ' + e.message, 'error'));
}

function updateStats(parsed) {
  var catCount = 0, entryCount = 0, valueCount = 0;
  for (var cat in parsed) {
    if (!parsed.hasOwnProperty(cat)) continue;
    var entries = parsed[cat];
    catCount++;
    entryCount += entries.length;
    for (var i = 0; i < entries.length; i++) {
      var vals = entries[i].values || [];
      valueCount += vals.length;
    }
  }
  document.getElementById('categoryCount').textContent = catCount + ' 个分类';
  document.getElementById('siteCount').textContent = entryCount + ' 条规则 / ' + valueCount + ' 个值';
}

function populateBatchSelects() {
  var parsed = configData.parsed || {};
  var cats = Object.keys(parsed).sort();
  var selIds = ['batchClearCat','batchCopyFrom','batchCopyTo'];
  for (var s = 0; s < selIds.length; s++) {
    var sel = document.getElementById(selIds[s]);
    var cur = sel.value;
    var html;
    if (selIds[s] === 'batchClearCat') {
      html = '<option value="">— 清空分类 —</option>';
    } else if (selIds[s] === 'batchCopyFrom') {
      html = '<option value="">源分类</option>';
    } else {
      html = '<option value="">目标分类</option>';
    }
    for (var c = 0; c < cats.length; c++) {
      var selected = cats[c] === cur ? ' selected' : '';
      html += '<option value="' + cats[c] + '"' + selected + '>' + cats[c] + ' (' + parsed[cats[c]].length + '条)</option>';
    }
    sel.innerHTML = html;
  }
}

function batchClearCategory() {
  var sel = document.getElementById('batchClearCat');
  var cat = sel.value;
  if (!cat) return showToast('请先选择要清空的分类', 'error');
  if (!confirm('确定清空分类 "' + cat + '" 的所有关键词？\n此操作不可撤销。')) return;
  fetch('/api/config/clear', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ category: cat })
  })
    .then(r => r.json())
    .then(d => {
      if (d.success) { showToast('✅ 已清空 "' + cat + '"'); loadConfig(); }
      else { showToast('❌ ' + (d.error || '操作失败'), 'error'); }
    })
    .catch(e => showToast('❌ ' + e.message, 'error'));
}

function batchCopyCategory() {
  var from = document.getElementById('batchCopyFrom').value;
  var to = document.getElementById('batchCopyTo').value;
  if (!from || !to) return showToast('请选择源分类和目标分类', 'error');
  if (from === to) return showToast('源和目标不能相同', 'error');
  if (!confirm('将 "' + from + '" 的关键词复制到 "' + to + '"？')) return;
  fetch('/api/config/copy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: from, to: to })
  })
    .then(r => r.json())
    .then(d => {
      if (d.success) { showToast('✅ 已复制 ' + d.copiedCount + ' 条'); loadConfig(); }
      else { showToast('❌ ' + (d.error || '操作失败'), 'error'); }
    })
    .catch(e => showToast('❌ ' + e.message, 'error'));
}

function exportConfig() {
  fetch('/api/config/export')
    .then(r => r.json())
    .then(d => {
      if (!d.success) { showToast('❌ 导出失败', 'error'); return; }
      var blob = new Blob([d.toml], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = 'ScreenTriggers_' + new Date().toISOString().slice(0,10) + '.toml';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      showToast('✅ 配置已导出');
    })
    .catch(e => showToast('❌ ' + e.message, 'error'));
}

function importConfig(event) {
  var file = event.target.files[0];
  if (!file) return;
  var reader = new FileReader();
  reader.onload = function(e) {
    var content = e.target.result;
    if (!confirm('即将导入 "' + file.name + '"（' + content.length + ' 字符）\n当前配置将被覆盖，是否继续？')) {
      event.target.value = ''; return;
    }
    fetch('/api/config/import', {
      method: 'POST',
      body: content
    })
      .then(r => r.json())
      .then(d => {
        if (d.success) { showToast('✅ 配置已导入'); loadConfig(); }
        else { showToast('❌ ' + (d.error || '导入失败'), 'error'); }
      })
      .catch(e => showToast('❌ ' + e.message, 'error'));
    event.target.value = '';
  };
  reader.readAsText(file);
}

function renderCategories(parsed) {
  var container = document.getElementById('categoriesList');
  container.innerHTML = '';
  var searchQ = (document.getElementById('triggerSearch') ? document.getElementById('triggerSearch').value : '').trim().toLowerCase();
  var keys = Object.keys(parsed).sort();
  var anyMatch = false;

  for (var ci = 0; ci < keys.length; ci++) {
    var category = keys[ci];
    var entries = parsed[category];
    var catMatch = !searchQ || category.toLowerCase().indexOf(searchQ) >= 0;
    var filtered = entries;
    if (searchQ) {
      filtered = [];
      for (var ei = 0; ei < entries.length; ei++) {
        var e = entries[ei];
        if (e.key.toLowerCase().indexOf(searchQ) >= 0) { filtered.push(e); continue; }
        var vals = e.values || [];
        for (var vi = 0; vi < vals.length; vi++) {
          if (vals[vi].toLowerCase().indexOf(searchQ) >= 0) { filtered.push(e); break; }
        }
      }
    }
    if (searchQ && !catMatch && filtered.length === 0) continue;
    anyMatch = true;

    var card = document.createElement('div');
    card.className = 'category-card';

    var entryHtml = '';
    for (var ei2 = 0; ei2 < filtered.length; ei2++) {
      var entry = filtered[ei2];
      var keyDisp = highlightText(entry.key, searchQ);
      var valTags = '';
      var vals2 = entry.values || [];
      for (var vi2 = 0; vi2 < vals2.length; vi2++) {
        var v = vals2[vi2];
        var vDisp = highlightText(v, searchQ);
        valTags += '<span class="val-tag">' + vDisp
          + '<span class="remove-val" onclick="event.stopPropagation();deleteValue(\'' + category + '\',\'' + entry.key + '\',\'' + v.replace(/'/g,"\\'") + '\')" title="删除此值">×</span></span>';
      }
      entryHtml += '<div class="entry-row">'
        + '<div class="entry-header-row"><span class="entry-key">' + keyDisp + '</span>'
        + '<button class="entry-del-btn" onclick="event.stopPropagation();deleteKeyword(\'' + category + '\',\'' + entry.key + '\')" title="删除此规则">✕</button></div>'
        + '<div class="entry-values">' + (valTags || '<span class="empty-hint">暂无值</span>') + '</div>'
        + '<div class="add-val-row"><input type="text" class="add-val-input" placeholder="+ 添加包名或窗口标题" onkeydown="if(event.key===\'Enter\')addValue(\'' + category + '\',\'' + entry.key + '\',this)"><button class="btn btn-sm" onclick="addValue(\'' + category + '\',\'' + entry.key + '\',this.previousElementSibling)">添加</button></div>'
        + '</div>';
    }

    var catNameDisp = highlightText(category, searchQ);
    card.innerHTML = '<div class="category-header" onclick="toggleCategory(this)">'
      + '<span class="category-name">' + catNameDisp + ' <span class="category-count">' + entries.length + ' 条规则</span></span>'
      + '<span class="category-arrow">▼</span>'
      + '<button class="delete-cat-btn" onclick="event.stopPropagation();deleteCategory(\'' + category + '\')" title="删除分类">✕</button>'
      + '</div>'
      + '<div class="category-body">' + entryHtml
      + '<div class="add-entry-row"><input type="text" id="nk-' + category + '" class="add-key-input" placeholder="+ 新规则名称" onkeydown="if(event.key===\'Enter\')addKeyword(\'' + category + '\',this)"><button class="btn btn-sm" onclick="addKeyword(\'' + category + '\',document.getElementById(\'nk-' + category + '\'))">添加规则</button></div>'
      + '</div>';

    if (searchQ) card.classList.add('expanded');
    container.appendChild(card);
  }

  if (!anyMatch) {
    container.innerHTML = '<p style="color:var(--text2);text-align:center;padding:40px;">没有匹配的分类或关键词</p>';
  }
}

function highlightText(text, query) {
  if (!query) return escapeHtml(text);
  var escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  var re = new RegExp('(' + escaped + ')', 'gi');
  return escapeHtml(text).replace(re, '<mark>$1</mark>');
}

function escapeHtml(str) {
  return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function toggleCategory(header) {
  header.closest('.category-card').classList.toggle('collapsed');
}

function addCategory() {
  var input = document.getElementById('newCategoryName');
  var name = input.value.trim().toLowerCase().replace(/\s+/g, '_');
  if (!name) return showToast('请输入分类名', 'error');
  if (configData.parsed[name]) return showToast('分类已存在', 'error');
  configData.parsed[name] = [];
  input.value = '';
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
  showToast('已添加分类 "' + name + '"');
}

function deleteCategory(name) {
  if (!confirm('确定删除分类 "' + name + '"？')) return;
  delete configData.parsed[name];
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
  showToast('已删除 "' + name + '"');
}

function addKeyword(category, input) {
  var key = input.value.trim().replace(/\s+/g, '_');
  if (!key) return showToast('请输入规则名称', 'error');
  if (!configData.parsed[category]) configData.parsed[category] = [];
  var entries = configData.parsed[category];
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].key === key) return showToast('规则已存在', 'error');
  }
  entries.push({ key: key, values: [] });
  input.value = '';
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
  showToast('✅ 已添加规则 "' + key + '" → ' + category);
}

function deleteKeyword(category, key) {
  if (!configData.parsed[category]) return;
  configData.parsed[category] = configData.parsed[category].filter(function(e) { return e.key !== key; });
  if (configData.parsed[category].length === 0) delete configData.parsed[category];
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
  showToast('已删除 ' + category + ': ' + key);
}

function addValue(category, key, input) {
  var val = input.value.trim();
  if (!val) return;
  var entries = configData.parsed[category];
  if (!entries) return showToast('分类不存在', 'error');
  var entry = null;
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].key === key) { entry = entries[i]; break; }
  }
  if (!entry) return showToast('规则不存在', 'error');
  if (!entry.values) entry.values = [];
  for (var j = 0; j < entry.values.length; j++) {
    if (entry.values[j] === val) return showToast('值已存在', 'error');
  }
  entry.values.push(val);
  input.value = '';
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
  showToast('✅ 已添加值 → ' + key + ': ' + val);
}

function deleteValue(category, key, value) {
  var entries = configData.parsed[category];
  if (!entries) return;
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].key === key && entries[i].values) {
      entries[i].values = entries[i].values.filter(function(v) { return v !== value; });
      break;
    }
  }
  markDirty();
  renderCategories(configData.parsed);
  updateStats(configData.parsed);
}

function onTriggerSearch() {
  renderCategories(configData.parsed);
}

function saveConfig() {
  var lines = [];
  var now = new Date();
  lines.push('# MacArkPet ScreenTriggers');
  lines.push('# 自动保存于 ' + now.toLocaleString());
  lines.push('');

  var cats = Object.keys(configData.parsed).sort();
  for (var ci = 0; ci < cats.length; ci++) {
    var cat = cats[ci];
    var entries = configData.parsed[cat];
    lines.push('[website_categories.' + cat + ']');
    for (var ei = 0; ei < entries.length; ei++) {
      var entry = entries[ei];
      var vals = entry.values || [];
      if (vals.length === 0) {
        lines.push(entry.key + ' = []');
      } else {
        var valStrs = [];
        for (var vi = 0; vi < vals.length; vi++) {
          valStrs.push('"' + vals[vi].replace(/"/g, '\\"') + '"');
        }
        lines.push(entry.key + ' = [' + valStrs.join(', ') + ']');
      }
    }
    lines.push('');
  }

  var toml = lines.join('\n');

  fetch('/api/config', {
    method: 'PUT',
    body: toml
  })
    .then(r => r.json())
    .then(d => {
      if (d.success) {
        markClean();
        showToast('✅ 配置已保存');
        loadConfig();
      } else {
        showToast('❌ 保存失败: ' + (d.error || '未知错误'), 'error');
      }
    })
    .catch(e => showToast('❌ 保存失败: ' + e.message, 'error'));
}

function resetConfig() {
  if (!confirm('重置为默认配置？自定义修改将丢失。')) return;
  showToast('请重启应用以重置配置', 'error');
}

// ═══════════════════════════════════════
//  角色设定
// ═══════════════════════════════════════

function loadProfiles() {
  fetch('/api/profiles/detail')
    .then(r => r.json())
    .then(data => {
      profilesData = data;
      updateProfileFilterOptions(data);
      filterProfiles();
    })
    .catch(e => console.error('加载角色失败:', e));
}

function updateProfileFilterOptions(profiles) {
  var factions = new Set();
  var classes = new Set();
  var races = new Set();
  for (var i = 0; i < profiles.length; i++) {
    var p = profiles[i];
    if (p.faction) factions.add(p.faction);
    if (p.classLabel) classes.add(p.classLabel);
    if (p.race) {
      var main = p.race.split(/\/|\s+/)[0];
      races.add(main);
    }
  }
  setOptions('filterFaction', Array.from(factions).sort(), '全部阵营');
  setOptions('filterClass', Array.from(classes).sort(), '全部职业');
  setOptions('filterRace', Array.from(races).sort(), '全部种族');
}

function setOptions(id, items, placeholder) {
  var sel = document.getElementById(id);
  var html = '<option value="">' + placeholder + '</option>';
  for (var i = 0; i < items.length; i++) {
    html += '<option value="' + items[i] + '">' + items[i] + '</option>';
  }
  sel.innerHTML = html;
}

function renderProfiles(profiles) {
  var container = document.getElementById('profilesList');
  container.innerHTML = '';
  var sitLabels = {
    interact: '日常互动', rest: '休息时', sleep: '睡眠',
    special: '特殊', affection_interact: '亲密·互动',
    affection_rest: '亲密·休息', affection_sleep: '亲密·睡眠',
    affection_special: '亲密·特殊', feed: '喂食',
    welcome: '欢迎', farewell: '告别', greeting: '问候'
  };

  for (var i = 0; i < profiles.length; i++) {
    var p = profiles[i];
    var card = document.createElement('div');
    card.className = 'profile-card';

    var situationKeys = p.dialogues ? Object.keys(p.dialogues) : [];
    var sigLines = p.signatureLines ? p.signatureLines.map(function(l) { return '<span class="sig-line">"' + l + '"</span>'; }).join('') : '';
    var sitBadges = situationKeys.map(function(sk) { return '<span class="sit-badge" onclick="event.stopPropagation();previewDialogues(\'' + p.id + '\',\'' + sk + '\',this)">' + (sitLabels[sk] || sk) + '</span>'; }).join('');
    var birthdayHtml = p.birthday ? '<span>🎂 ' + p.birthday + '</span>' : '';
    var heightHtml = p.height ? '<span>📏 ' + p.height + '</span>' : '';

    card.innerHTML = '<div class="p-header" onclick="toggleProfile(this)">'
      + '<div class="p-name-row"><span class="p-name">' + p.name + '</span><span class="p-id-code">' + p.id + '</span></div>'
      + '<div class="p-subtitle">' + (p.subtitle || '') + '</div>'
      + '<div class="p-tags">'
      + (p.faction ? '<span class="p-tag faction">🏳️ ' + p.faction + '</span>' : '')
      + (p.classLabel ? '<span class="p-tag class">⚔️ ' + p.classLabel + '</span>' : '')
      + (p.race ? '<span class="p-tag race">🧬 ' + p.race.split('/')[0] + '</span>' : '')
      + (p.origin ? '<span class="p-tag origin">📍 ' + p.origin + '</span>' : '')
      + '</div><div class="p-personality">' + (p.personality || '') + '</div>'
      + '<div class="p-expand-hint">点击展开 ▼</div></div>'
      + '<div class="p-detail">'
      + '<div class="p-detail-section"><div class="p-detail-label">💬 语言风格</div><div class="p-detail-text">' + (p.speechStyle || '暂无') + '</div></div>'
      + '<div class="p-detail-section"><div class="p-detail-label">💙 对博士的态度</div><div class="p-detail-text">' + (p.attitudeTowardsDoctor || '暂无') + '</div></div>'
      + '<div class="p-detail-section"><div class="p-detail-label">📖 背景故事</div><div class="p-detail-text text-small">' + (p.backgroundSummary || '暂无') + '</div></div>'
      + (sigLines ? '<div class="p-detail-section"><div class="p-detail-label">⭐ 经典台词</div><div class="p-signature-lines">' + sigLines + '</div></div>' : '')
      + (situationKeys.length > 0 ? '<div class="p-detail-section"><div class="p-detail-label">🎭 台词情境 (' + situationKeys.length + ')</div><div class="p-situation-badges">' + sitBadges + '</div><div class="p-dialogue-preview" id="dp-' + p.id + '"></div></div>' : '')
      + (birthdayHtml || heightHtml ? '<div class="p-status-row">' + birthdayHtml + heightHtml + '</div>' : '')
      + '<div class="p-edit-row">'
      + '<button class="btn btn-sm" onclick="event.stopPropagation();editCharacter(\'' + p.id + '\')">✏️ 编辑角色设定</button>'
      + '<button class="btn btn-sm" style="background: linear-gradient(135deg, #6e8efb, #a777e3); color: white; border: none; font-weight: 600;" onclick="event.stopPropagation();refineCharacterWithAI(\'' + p.name + '\')">✨ AI 深度润色</button>'
      + '<button class="btn btn-sm" onclick="event.stopPropagation();editDialogues(\'' + p.id + '\')">🎭 编辑台词</button>'
      + '<button class="btn btn-sm btn-danger" onclick="event.stopPropagation();deleteCharacter(\'' + p.id + '\')">🗑 删除</button>'
      + '</div>'
      + '</div>';
    container.appendChild(card);
  }
}

function toggleProfile(header) {
  header.closest('.profile-card').classList.toggle('expanded');
}

function previewDialogues(charId, situation, badgeEl) {
  var preview = document.getElementById('dp-' + charId);
  if (!preview) return;
  var profile = null;
  for (var i = 0; i < profilesData.length; i++) {
    if (profilesData[i].id === charId) { profile = profilesData[i]; break; }
  }
  if (!profile || !profile.dialogues) return;
  var entries = profile.dialogues[situation];
  if (!entries || entries.length === 0) { preview.innerHTML = '<p class="empty-hint">暂无台词</p>'; return; }

  if (preview.dataset.activeSit === situation) {
    preview.innerHTML = ''; delete preview.dataset.activeSit; badgeEl.classList.remove('active'); return;
  }
  preview.dataset.activeSit = situation;
  var actives = document.querySelectorAll('.sit-badge.active');
  for (var ai = 0; ai < actives.length; ai++) actives[ai].classList.remove('active');
  badgeEl.classList.add('active');

  var sitLabels = {
    interact: '日常互动', rest: '休息时', sleep: '睡眠',
    special: '特殊', affection_interact: '亲密·互动',
    affection_rest: '亲密·休息', affection_sleep: '亲密·睡眠',
    affection_special: '亲密·特殊', feed: '喂食',
    welcome: '欢迎', farewell: '告别', greeting: '问候'
  };
  var html = '';
  for (var ei = 0; ei < entries.length; ei++) {
    var entry = entries[ei];
    var lines = (entry.lines || []).map(function(l) { return '<div class="dialogue-line">"' + l + '"</div>'; }).join('');
    html += '<div class="dialogue-group"><div class="dialogue-header">'
      + '<span class="dialogue-sit">' + (sitLabels[situation] || situation) + '</span>'
      + (entry.minAffection > 0 ? '<span class="affection-badge">💕 好感≥' + entry.minAffection + '</span>' : '<span class="affection-badge default">🙂 默认</span>')
      + '<span class="cooldown-badge">冷却 ' + (entry.cooldown || 0) + 's</span></div>'
      + '<div class="dialogue-lines">' + lines + '</div></div>';
  }
  preview.innerHTML = html;
}

function filterProfiles() {
  var q = document.getElementById('profileSearch').value.toLowerCase();
  var fFaction = document.getElementById('filterFaction').value;
  var fClass = document.getElementById('filterClass').value;
  var fRace = document.getElementById('filterRace').value;
  var filtered = [];
  for (var i = 0; i < profilesData.length; i++) {
    var p = profilesData[i];
    if (q && p.name.toLowerCase().indexOf(q) < 0 && p.id.toLowerCase().indexOf(q) < 0 && (p.subtitle||'').toLowerCase().indexOf(q) < 0) continue;
    if (fFaction && p.faction !== fFaction) continue;
    if (fClass && p.classLabel !== fClass) continue;
    if (fRace) { var mainRace = (p.race||'').split(/\/|\s+/)[0]; if (mainRace !== fRace) continue; }
    filtered.push(p);
  }
  document.getElementById('profileCount').textContent = filtered.length + ' / ' + profilesData.length + ' 个角色';
  renderProfiles(filtered);
}

// ═══════════════════════════════════════
//  实时监控
// ═══════════════════════════════════════

var SITUATION_META = {
  coding:         { label: '编码',       emoji: '💻', color: '#4f8cff' },
  developing:     { label: '开发',       emoji: '🛠️', color: '#4f8cff' },
  watching_video: { label: '看视频',     emoji: '🎬', color: '#f87171' },
  social:         { label: '社交',       emoji: '💬', color: '#fbbf24' },
  chatting:       { label: '聊天',       emoji: '💭', color: '#fbbf24' },
  reading_news:   { label: '读新闻',     emoji: '📰', color: '#34d399' },
  shopping:       { label: '购物',       emoji: '🛒', color: '#f472b6' },
  gaming:         { label: '游戏',       emoji: '🎮', color: '#a78bfa' },
  working:        { label: '工作',       emoji: '📊', color: '#34d399' },
  email:          { label: '邮件',       emoji: '📧', color: '#34d399' },
  designing:      { label: '设计',       emoji: '🎨', color: '#f472b6' },
  writing:        { label: '写作',       emoji: '✍️', color: '#34d399' },
  ai_chat:        { label: 'AI聊天',    emoji: '🤖', color: '#60a5fa' },
  studying:       { label: '学习',       emoji: '📚', color: '#4f8cff' },
  browsing:       { label: '浏览',       emoji: '🌐', color: '#9294a0' },
  deep_night:     { label: '深夜',       emoji: '🌙', color: '#818cf8' },
  idle_long:      { label: '长时间闲置', emoji: '💤', color: '#9294a0' }
};

var PHASE_META = {
  morning:   { label: '☀️ 早晨' },
  afternoon: { label: '🌤️ 下午' },
  evening:   { label: '🌆 傍晚' },
  night:     { label: '🌃 夜晚' },
  deep_night: { label: '🌙 深夜' }
};

var _sseConnected = false;

// ── SSE 实时推送 ──
function initEventSource() {
  if (window.EventSource) {
    var source = new EventSource('/api/context/stream');
    source.onmessage = function(e) {
      _sseConnected = true;
      try {
        var d = JSON.parse(e.data);
        updateContextUI(d);
        addHistory(d);
        addTimelineEntry(d);
      } catch(err) {}
    };
    source.onerror = function() {
      _sseConnected = false;
      console.warn('SSE 连接断开，将在 3 秒后重试...');
    };
  } else {
    // 不支持 EventSource 的浏览器回退到轮询
    setInterval(pollContext, 3000);
  }
}

function updateContextUI(d) {
  if (!d || !d.available) {
    document.getElementById('monApp').textContent = '—';
    document.getElementById('monTitle').textContent = '等待检测...';
    return;
  }
  var sit = SITUATION_META[d.category] || { label: d.category || 'unknown', emoji: '❓', color: '#9294a0' };
  document.getElementById('monAppIcon').textContent = sit.emoji;
  document.getElementById('monApp').textContent = d.appName;
  document.getElementById('monTitle').textContent = d.windowTitle || '(无标题)';
  var catBadge = document.getElementById('monCategory');
  catBadge.textContent = sit.label;
  catBadge.style.background = sit.color + '22';
  catBadge.style.color = sit.color;
  catBadge.style.borderColor = sit.color + '44';
  var phase = PHASE_META[d.dayPhase] || { label: d.dayPhase || '—' };
  document.getElementById('monPhase').textContent = phase.label;
  document.getElementById('monDeepNight').textContent = d.isDeepNight ? '🌙 是' : '☀️ 否';
  document.getElementById('monIdle').textContent = d.isIdleLong ? '💤 是' : '✅ 否';
  document.getElementById('monSummary').textContent = d.summary || '';
}

var activityTimeline = [];

// 轮询兜底（仅在 SSE 不可用时触发）
function pollContext() {
  fetch('/api/context')
    .then(r => r.json())
    .then(function(d) {
      updateContextUI(d);
      addHistory(d);
      addTimelineEntry(d);
    })
    .catch(function() {});
}

function addTimelineEntry(ctx) {
  var now = new Date();
  var timeStr = now.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  activityTimeline.push({ time: timeStr, category: ctx.category || 'unknown', appName: ctx.appName || '-', ts: now.getTime() });
  if (activityTimeline.length > 30) activityTimeline.shift();
  renderTimeline();
}

function renderTimeline() {
  var container = document.getElementById('activityTimeline');
  if (activityTimeline.length === 0) { container.innerHTML = '<div class="timeline-empty">等待数据...</div>'; return; }
  var bars = '';
  var shownCats = {};
  for (var i = 0; i < activityTimeline.length; i++) {
    var e = activityTimeline[i];
    var sit = SITUATION_META[e.category] || { label: e.category, color: '#9294a0' };
    shownCats[e.category] = true;
    bars += '<div class="tl-bar" style="background:' + sit.color + '" title="' + e.time + ' ' + sit.label + ' — ' + e.appName + '"><span class="tl-bar-label">' + e.appName.slice(0, 3) + '</span></div>';
  }
  var catKeys = Object.keys(shownCats);
  var legend = '';
  for (var ci = 0; ci < catKeys.length; ci++) {
    var sit = SITUATION_META[catKeys[ci]] || { label: catKeys[ci], color: '#9294a0' };
    legend += '<span class="tl-legend-item"><span class="tl-dot" style="background:' + sit.color + '"></span>' + sit.label + '</span>';
  }
  container.innerHTML = '<div class="timeline-bars">' + bars + '</div>' + '<div class="tl-legend">' + legend + '</div>';
}

// ═══════════════════════════════════════
//  历史记录
// ═══════════════════════════════════════

function addHistory(ctx) {
  var now = new Date();
  var time = now.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  var item = { time: time };
  for (var k in ctx) { if (ctx.hasOwnProperty(k)) item[k] = ctx[k]; }
  historyLog.unshift(item);
  if (historyLog.length > 200) historyLog.pop();
  renderHistory();
  updateHistoryFilter();
  fetch('/api/history', { method: 'POST', body: JSON.stringify(historyLog.slice(0, 200)) }).catch(function(){});
}

function loadHistoryFromServer() {
  fetch('/api/history')
    .then(r => r.json())
    .then(function(d) {
      if (d.success && Array.isArray(d.history) && d.history.length > 0) {
        historyLog = d.history;
        renderHistory();
        updateHistoryFilter();
      }
    })
    .catch(function(){});
}

function renderHistory() {
  var filterEl = document.getElementById('historyFilter');
  var filter = filterEl ? filterEl.value : '';
  var container = document.getElementById('historyLog');
  var filtered = filter ? historyLog.filter(function(e) { return e.category === filter; }) : historyLog;
  if (filtered.length === 0) { container.innerHTML = '<p class="placeholder">暂无记录</p>'; return; }

  var html = '';
  for (var i = 0; i < filtered.length; i++) {
    var e = filtered[i];
    var sit = SITUATION_META[e.category] || { label: e.category || '-', emoji: '❓', color: '#9294a0' };
    var isLatest = i === 0 && !filter;
    html += '<div class="history-entry' + (isLatest ? ' latest' : '') + '">'
      + '<div class="h-timeline-marker"><div class="h-dot" style="background:' + sit.color + '"></div>'
      + (i < filtered.length - 1 ? '<div class="h-line"></div>' : '') + '</div>'
      + '<div class="h-content"><div class="h-row1"><span class="h-time">' + e.time + '</span>'
      + '<span class="h-cat" style="color:' + sit.color + ';background:' + sit.color + '15;border:1px solid ' + sit.color + '33;">' + sit.emoji + ' ' + sit.label + '</span></div>'
      + '<div class="h-row2"><span class="h-app">' + (e.appName || '-') + '</span>'
      + (e.windowTitle ? '<span class="h-title">' + e.windowTitle + '</span>' : '') + '</div></div></div>';
  }
  container.innerHTML = html;
  container.scrollTop = 0;
}

function filterHistory() { renderHistory(); }

function clearHistory() { historyLog = []; renderHistory(); }

function updateHistoryFilter() {
  var sel = document.getElementById('historyFilter');
  var cats = {};
  for (var i = 0; i < historyLog.length; i++) cats[historyLog[i].category] = true;
  var currentVal = sel.value;
  var html = '<option value="">全部情境</option>';
  var sorted = Object.keys(cats).sort();
  for (var ci = 0; ci < sorted.length; ci++) {
    var sit = SITUATION_META[sorted[ci]] || { label: sorted[ci] };
    html += '<option value="' + sorted[ci] + '"' + (sorted[ci] === currentVal ? ' selected' : '') + '>' + sit.label + '</option>';
  }
  sel.innerHTML = html;
}

function sendTestTrigger() {
  var situation = document.getElementById('testSituation').value;
  var character = document.getElementById('testCharacter').value;
  fetch('/api/test/trigger', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ situation: situation, character: character })
  })
    .then(r => r.json().catch(function(){ return {success:false}; }))
    .then(function(d) {
      if (d.success) { showToast('✅ 已触发 ' + situation + ' → ' + (character || '随机角色')); }
      else { simulateTest(situation, character); }
    })
    .catch(function() { simulateTest(situation, character); });
}

// ═══════════════════════════════════════
//  桌宠管理
// ═══════════════════════════════════════

var _petPollTimer = null;

function loadPets() {
  fetch('/api/pets?t=' + new Date().getTime())
    .then(r => r.json())
    .then(function(pets) { renderPets(pets); loadSettings(); fetchAvailablePets(); })
    .catch(function(){});
}

function renderPets(pets) {
  var container = document.getElementById('petListContainer');
  var hint = document.getElementById('petEmptyHint');
  var countLabel = document.getElementById('petCountLabel');
  countLabel.textContent = pets.length + ' 个';
  if (pets.length === 0) { hint.style.display = 'block'; container.innerHTML = ''; container.appendChild(hint); return; }
  hint.style.display = 'none';

  var moodLabels = { idle: '☀️ 悠闲', happy: '😊 开心', resting: '😴 休息', sleepy: '💤 困了', special: '✨ 特殊', attacking: '⚔️ 战斗', victory: '🏆 胜利' };
  var moodIcons = { idle: '☀️', happy: '😊', resting: '😴', sleepy: '💤', special: '✨', attacking: '⚔️', victory: '🏆' };
  var html = '';
  for (var i = 0; i < pets.length; i++) {
    var p = pets[i];
    var moodCn = moodLabels[p.mood] || p.mood;
    var w1 = Math.max(0, Math.min(100, p.affection));
    var w2 = Math.max(0, Math.min(100, p.stamina));
    var w3 = Math.max(0, Math.min(100, p.moodLevel));
    var c1 = w1 >= 70 ? '#ec4899' : (w1 >= 30 ? '#f59e0b' : '#6b7280');
    var c2 = w2 > 50 ? '#6366f1' : (w2 > 20 ? '#f59e0b' : '#ef4444');
    var c3 = w3 >= 70 ? '#10b981' : (w3 >= 30 ? '#f59e0b' : '#ef4444');
    html += '<div class="pet-card">'
      + '<div class="pet-top"><span class="pet-name">' + p.name + '</span><span class="pet-id">' + (p.characterId||'') + '</span>'
      + '<span class="pet-mood">' + moodCn + '</span>'
      + (p.isSpeaking ? '<span class="pet-speaking">💬</span>' : '') + '</div>'
      + '<div class="pet-bars">'
      + '<div class="pet-bar-row"><span class="pet-bar-label">❤️ 好感度</span><span class="pet-bar-val">' + p.affection + ' / 100</span></div>'
      + '<div class="pet-bar-track"><div class="pet-bar-inner" style="width:' + w1 + '%;background:' + c1 + '"></div></div>'
      + '<div class="pet-bar-row"><span class="pet-bar-label">⚡ 精力</span><span class="pet-bar-val">' + Math.floor(p.stamina) + ' / 100</span></div>'
      + '<div class="pet-bar-track"><div class="pet-bar-inner" style="width:' + w2 + '%;background:' + c2 + '"></div></div>'
      + '<div class="pet-bar-row"><span class="pet-bar-label">✨ 心情</span><span class="pet-bar-val">' + Math.floor(p.moodLevel) + ' / 100</span></div>'
      + '<div class="pet-bar-track"><div class="pet-bar-inner" style="width:' + w3 + '%;background:' + c3 + '"></div></div>'
      + '<div class="pet-streak">🔥 连续签到 <strong>' + p.dailyStreak + '</strong> 天</div>'
      + '<div class="pet-streak">💰 金币余额 <strong>' + (p.coins || 0) + '</strong></div></div>'
      + '<div class="pet-actions">'
      + '<button class="btn btn-sm" onclick="petCommand(' + p.id + ",'poke'" + ')">👆 互动</button>'
      + '<button class="btn btn-sm btn-primary" onclick="petCommand(' + p.id + ",'buy_food'" + ')">🛒 买食物(30币)</button>'
      + '<button class="btn btn-sm" onclick="petCommand(' + p.id + ",'rest'" + ')">😴 休息</button>'
      + '<button class="btn btn-sm" onclick="petCommand(' + p.id + ",'special'" + ')">✨ 特殊</button>'
      + '<button class="btn btn-sm btn-danger" onclick="petCommand(' + p.id + ",'close'" + ')">✕ 关闭</button>'
      + '</div>'
      + (p.dialogueText ? '<div class="pet-dialogue">💬 ' + p.dialogueText + '</div>' : '')
      + '</div>';
  }
  container.innerHTML = html;
}

function petCommand(id, command) {
  fetch('/api/pets/command', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: id, command: command })
  })
    .then(r => r.json())
    .then(function(d) {
      if (d.success) { showToast('✅ 命令已发送'); loadPets(); }
      else { showToast('❌ ' + (d.error || '命令失败'), 'error'); }
    })
    .catch(function() { showToast('❌ 发送失败', 'error'); });
}

function loadSettings() {
  fetch('/api/settings')
    .then(r => r.json())
    .then(function(s) {
      document.getElementById('setVoice').checked = s.isVoiceEnabled;
      document.getElementById('setClickThrough').checked = s.isClickThrough;
      document.getElementById('setOnTop').checked = s.isAlwaysOnTop;
    })
    .catch(function(){});
}

function updateSettings() {
  var body = JSON.stringify({
    isVoiceEnabled: document.getElementById('setVoice').checked,
    isClickThrough: document.getElementById('setClickThrough').checked,
    isAlwaysOnTop: document.getElementById('setOnTop').checked
  });
  fetch('/api/settings', { method: 'PUT', body: body })
    .then(r => r.json())
    .then(function(d) { if (d.success) showToast('⚙️ 设置已更新'); })
    .catch(function(){});
}

// ── P5: 启动桌宠 ──
function fetchAvailablePets() {
  fetch('/api/pets/available')
    .then(function(r) { return r.json(); })
    .then(function(list) {
      var sel = document.getElementById('launchPetSelect');
      var cur = sel.value;
      var html = '<option value="">— 选择已安装角色 —</option>';
      for (var i = 0; i < list.length; i++) {
        var selected = list[i].id === cur ? ' selected' : '';
        var icon = list[i].hasSpine ? '🦴' : '📷';
        html += '<option value="' + list[i].id + '"' + selected + '>' + icon + ' ' + list[i].title + '</option>';
      }
      sel.innerHTML = html;
    })
    .catch(function(){});
}

function refreshAvailablePets() {
  fetchAvailablePets();
  showToast('🔄 角色列表已刷新');
}

function launchSelectedPet() {
  var sel = document.getElementById('launchPetSelect');
  var modelId = sel.value;
  if (!modelId) { showToast('请选择要启动的角色', 'error'); return; }
  var btn = document.getElementById('launchPetBtn');
  var status = document.getElementById('launchStatus');
  btn.disabled = true; status.textContent = '⏳ 启动中...';
  fetch('/api/pets/launch', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ modelId: modelId })
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      btn.disabled = false;
      if (d.success) {
        status.textContent = '✅ 已启动';
        showToast('✅ 桌宠已启动');
        setTimeout(function() { loadPets(); }, 1000);
      } else {
        status.textContent = '❌ ' + (d.error || '启动失败');
        showToast('❌ ' + (d.error || '启动失败'), 'error');
      }
    })
    .catch(function() {
      btn.disabled = false;
      status.textContent = '❌ 请求失败';
      showToast('❌ 请求失败', 'error');
    });
}

// 持续轮询桌宠状态，如果当前在桌宠 Tab 就刷新
setInterval(function() {
  var petTab = document.querySelector('.tab[data-tab="pets"]');
  if (petTab && petTab.classList.contains('active')) {
    loadPets();
  }
}, 3000);

// Tab 切换时立即加载
setTimeout(function() {
  document.querySelectorAll('.tab').forEach(function(tab) {
    tab.addEventListener('click', function() {
      if (tab.dataset.tab === 'pets') {
        loadPets();
      }
    });
  });
}, 100);

function simulateTest(situation, character) {
  var sit = SITUATION_META[situation] || { label: situation, emoji: '❓' };
  var fake = {
    available: true, appName: '🧪 手动测试',
    windowTitle: sit.emoji + ' ' + sit.label, category: situation,
    dayPhase: 'night', isDeepNight: situation === 'deep_night',
    isIdleLong: situation === 'idle_long',
    summary: '手动触发情境「' + sit.label + '」' + (character !== 'random' ? '，角色: ' + character : '')
  };
  addHistory(fake);
  showToast('🧪 已模拟触发 ' + sit.label);
}

// ═══════════════════════════════════════
//  角色设定编辑
// ═══════════════════════════════════════

var _editCharId = null;

function editCharacter(charId) {
  _editCharId = charId;
  var profile = null;
  for (var i = 0; i < profilesData.length; i++) {
    if (profilesData[i].id === charId) { profile = profilesData[i]; break; }
  }
  if (!profile) { showToast('❌ 找不到角色数据', 'error'); return; }
  document.getElementById('editModalTitle').textContent = '✏️ 编辑设定 — ' + profile.name;
  document.getElementById('editModalBody').innerHTML = buildEditForm(profile);
  document.getElementById('profileEditModal').style.display = 'flex';
}

function buildEditForm(profile) {
  return '<div class="edit-form">'
    + '<div class="edit-field"><label>角色 ID</label><div class="char-id-label">' + profile.id + '</div></div>'
    + '<div class="edit-field"><label>角色名</label><input type="text" id="edit-name" value="' + escapeHtml(profile.name) + '"></div>'
    + '<div class="edit-field"><label>副标题</label><input type="text" id="edit-subtitle" value="' + escapeHtml(profile.subtitle||'') + '"></div>'
    + '<div class="edit-field"><label>种族</label><input type="text" id="edit-race" value="' + escapeHtml(profile.race||'') + '"></div>'
    + '<div class="edit-field"><label>出身地</label><input type="text" id="edit-origin" value="' + escapeHtml(profile.origin||'') + '"></div>'
    + '<div class="edit-field"><label>职业</label><input type="text" id="edit-classLabel" value="' + escapeHtml(profile.classLabel||'') + '"></div>'
    + '<div class="edit-field"><label>阵营</label><input type="text" id="edit-faction" value="' + escapeHtml(profile.faction||'') + '"></div>'
    + '<div class="edit-field"><label>生日</label><input type="text" id="edit-birthday" value="' + escapeHtml(profile.birthday||'') + '"></div>'
    + '<div class="edit-field"><label>身高</label><input type="text" id="edit-height" value="' + escapeHtml(profile.height||'') + '"></div>'
    + '<div class="edit-field"><label>性格描述</label><textarea id="edit-personality" rows="3">' + escapeHtml(profile.personality||'') + '</textarea></div>'
    + '<div class="edit-field"><label>语言风格</label><textarea id="edit-speechStyle" rows="2">' + escapeHtml(profile.speechStyle||'') + '</textarea></div>'
    + '<div class="edit-field"><label>对博士的态度</label><textarea id="edit-attitude" rows="3">' + escapeHtml(profile.attitudeTowardsDoctor||'') + '</textarea></div>'
    + '<div class="edit-field"><label>背景故事</label><textarea id="edit-background" rows="4">' + escapeHtml(profile.backgroundSummary||'') + '</textarea></div>'
    + '</div>';
}

function closeProfileEdit() {
  document.getElementById('profileEditModal').style.display = 'none';
  _editCharId = null;
}

function saveProfileEdit() {
  if (!_editCharId) return;
  var getVal = function(id) {
    var el = document.getElementById(id);
    return el ? el.value.trim() : '';
  };
  var fields = {
    name: getVal('edit-name'),
    subtitle: getVal('edit-subtitle'),
    race: getVal('edit-race'),
    origin: getVal('edit-origin'),
    classLabel: getVal('edit-classLabel'),
    faction: getVal('edit-faction'),
    birthday: getVal('edit-birthday'),
    height: getVal('edit-height'),
    personality: getVal('edit-personality'),
    speechStyle: getVal('edit-speechStyle'),
    attitudeTowardsDoctor: getVal('edit-attitude'),
    backgroundSummary: getVal('edit-background')
  };
  fetch('/api/profiles/save', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ characterId: _editCharId, fields: fields })
  })
    .then(r => r.json())
    .then(function(d) {
      if (d.success) { showToast('✅ 角色设定已保存'); closeProfileEdit(); refreshAll(); }
      else { showToast('❌ ' + (d.error || '保存失败'), 'error'); }
    })
    .catch(function(e) { showToast('❌ ' + e.message, 'error'); });
}

// ═══════════════════════════════════════
// 角色 CRUD：删除 / 新建 / 台词编辑
// ═══════════════════════════════════════

// ── 删除角色 ──
function deleteCharacter(charId) {
  var name = '';
  for (var i = 0; i < profilesData.length; i++) {
    if (profilesData[i].id === charId) { name = profilesData[i].name; break; }
  }
  if (!confirm('确定删除角色「' + name + '」？\n\n此操作将同时删除该角色的所有台词数据，不可撤销！')) return;
  
  fetch('/api/profiles/delete', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ characterId: charId })
  })
    .then(r => r.json())
    .then(function(d) {
      if (d.success) { showToast('🗑️ 已删除「' + name + '」'); loadProfiles(); }
      else { showToast('❌ ' + (d.error || '删除失败'), 'error'); }
    })
    .catch(function(e) { showToast('❌ ' + e.message, 'error'); });
}

// ── 新建角色弹窗 ──
function showNewCharForm() {
  document.getElementById('editModalTitle').textContent = '➕ 新建角色';
  document.getElementById('editModalBody').innerHTML = buildNewCharForm();
  document.getElementById('profileEditModal').style.display = 'flex';
  // 切换保存按钮行为
  document.getElementById('saveProfileBtn').onclick = saveNewCharacter;
}

function buildNewCharForm() {
  return '<div class="edit-form">'
    + '<div class="edit-field"><label>角色 ID *</label><input type="text" id="new-charId" placeholder="如: amiyma, texas, skadi" class="input-mono"></div>'
    + '<div class="edit-field"><label>角色名 *</label><input type="text" id="new-name" placeholder="如: 阿米娅、德克萨斯"></div>'
    + '<div class="edit-field"><label>副标题</label><input type="text" id="new-subtitle" placeholder="如: 罗德岛CEO"></div>'
    + '<div class="edit-field"><label>种族</label><input type="text" id="new-race"></div>'
    + '<div class="edit-field"><label>出身地</label><input type="text" id="new-origin"></div>'
    + '<div class="edit-field"><label>职业</label><input type="text" id="new-classLabel"></div>'
    + '<div class="edit-field"><label>阵营</label><input type="text" id="new-faction"></div>'
    + '<div class="edit-field"><label>性格描述</label><textarea id="new-personality" rows="2"></textarea></div>'
    + '<div class="edit-field"><label>语言风格</label><textarea id="new-speechStyle" rows="2"></textarea></div>'
    + '<div class="edit-field"><label>对博士的态度</label><textarea id="new-attitude" rows="2"></textarea></div>'
    + '<div class="edit-field"><label>背景故事</label><textarea id="new-background" rows="3"></textarea></div>'
    + '</div>'
    + '<p style="color:var(--text2);font-size:12px;margin-top:8px">* 必填项。ID 建议用英文，如 amiyma / texas。保存后可在编辑中继续补充细节。</p>';
}

function saveNewCharacter() {
  var charId = document.getElementById('new-charId').value.trim();
  var name = document.getElementById('new-name').value.trim();
  if (!charId || !name) { showToast('❌ 角色 ID 和角色名不能为空', 'error'); return; }
  
  var payload = {
    characterId: charId, name: name,
    subtitle: document.getElementById('new-subtitle').value.trim(),
    race: document.getElementById('new-race').value.trim(),
    origin: document.getElementById('new-origin').value.trim(),
    classLabel: document.getElementById('new-classLabel').value.trim(),
    faction: document.getElementById('new-faction').value.trim(),
    personality: document.getElementById('new-personality').value.trim(),
    speechStyle: document.getElementById('new-speechStyle').value.trim(),
    attitudeTowardsDoctor: document.getElementById('new-attitude').value.trim(),
    backgroundSummary: document.getElementById('new-background').value.trim()
  };
  
  fetch('/api/profiles/create', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
    .then(r => r.json())
    .then(function(d) {
      if (d.success) {
        showToast('✅ 已创建角色「' + name + '」');
        closeProfileEdit();
        loadProfiles();
      } else {
        showToast('❌ ' + (d.error || '创建失败'), 'error');
      }
    })
    .catch(function(e) { showToast('❌ ' + e.message, 'error'); });
}

// ── 台词编辑弹窗 ──
var _dialogCharId = null;
var _dialogData = {};

function editDialogues(charId) {
  _dialogCharId = charId;
  var profile = null;
  for (var i = 0; i < profilesData.length; i++) {
    if (profilesData[i].id === charId) { profile = profilesData[i]; break; }
  }
  var name = profile ? profile.name : charId;
  
  document.getElementById('dialogModalTitle').textContent = '🎭 台词编辑 — ' + name + ' (' + charId + ')';
  
  // 从 profilesData 获取现有台词
  _dialogData = (profile && profile.dialogues) ? JSON.parse(JSON.stringify(profile.dialogues)) : {};
  
  renderDialogueEditor();
  document.getElementById('dialogueEditModal').style.display = 'flex';
}

var SITUATION_OPTIONS = [
  'interact', 'rest', 'sleep', 'special', 'feed',
  'welcome', 'farewell', 'greeting',
  'affection_interact', 'affection_rest', 'affection_sleep', 'affection_special',
  'watching_video', 'gaming', 'social', 'chatting', 'working',
  'reading_news', 'shopping', 'ai_chat', 'studying', 'deep_night', 'idle_long',
  'coding', 'app_game', 'app_work', 'app_social', 'app_coding'
];

var SITUATION_LABELS = {
  interact: '日常互动', rest: '休息', sleep: '睡眠',
  special: '特殊动作', feed: '喂食',
  welcome: '欢迎', farewell: '告别', greeting: '问候',
  affection_interact: '亲密·互动', affection_rest: '亲密·休息',
  affection_sleep: '亲密·睡眠', affection_special: '亲密·特殊',
  watching_video: '看视频', gaming: '游戏', social: '社交',
  chatting: '聊天', working: '工作',
  reading_news: '看新闻', shopping: '购物', ai_chat: 'AI聊天',
  studying: '学习', deep_night: '深夜', idle_long: '长时间空闲',
  coding: '写代码', app_game: '打开游戏', app_work: '打开办公软件',
  app_social: '打开社交', app_coding: '打开开发工具'
};

function renderDialogueEditor() {
  var container = document.getElementById('dialogEditorBody');
  var situationNames = Object.keys(_dialogData);
  
  // 动态合并所有可用角色，构建 CP (遇见) 选项
  var extendedOptions = SITUATION_OPTIONS.slice();
  var extendedLabels = Object.assign({}, SITUATION_LABELS);
  var cpOptions = [];
  if (typeof profilesData !== 'undefined') {
    profilesData.forEach(function(p) {
      if (p.id && p.id !== _dialogCharId) {
        var cpSit = 'cp_' + p.id;
        cpOptions.push({sit: cpSit, name: p.name, label: '遇见：' + p.name + ' (' + p.id + ')'});
        extendedLabels[cpSit] = '遇见：' + p.name + ' (' + p.id + ')';
      }
    });
  }

  var html = '';
  
  // 情境选择器（添加新情境）
  var available = extendedOptions.filter(function(s) { return situationNames.indexOf(s) < 0; });
  var availableCp = cpOptions.filter(function(o) { return situationNames.indexOf(o.sit) < 0; });

  html += '<div class="dialog-add-sit-bar" style="display:flex; gap:10px; flex-wrap:wrap;">'
       + '<div style="display:flex; gap:4px;"><select id="newSitSelect">';
  if (available.length === 0) {
    html += '<option value="">— 所有常规情境已添加 —</option>';
  } else {
    html += '<option value="">+ 添加常规情境...</option>';
    available.forEach(function(s) {
      html += '<option value="' + s + '">' + (extendedLabels[s] || s) + '</option>';
    });
  }
  html += '</select><button class="btn btn-sm" onclick="addNewSituation()">➕ 添加</button></div>';

  html += '<div style="display:flex; gap:4px;">';
  if (availableCp.length === 0) {
    html += '<input type="text" id="newCPSitInput" class="dg-min-aff" style="width:160px;" placeholder="所有角色均已添加" disabled>';
  } else {
    html += '<input type="text" id="newCPSitInput" list="cpDataList" class="dg-min-aff" style="width:160px;" placeholder="搜索干员名字...">';
    html += '<datalist id="cpDataList">';
    availableCp.forEach(function(o) {
      html += '<option value="' + escapeHtml(o.name) + '">' + escapeHtml(o.label) + '</option>';
    });
    html += '</datalist>';
  }
  html += '<button class="btn btn-sm" onclick="addCPSituation()">➕ 添加彩蛋互动</button></div>'
       + '</div>'
       + '<div class="dialog-help" style="margin-bottom:10px;font-size:12px;color:#6b7280;">💡 互动小贴士：如果你想让桌宠与其他干员串门聊天，可以在上方“添加彩蛋互动”选择角色！之后会解锁专属的多回合剧本编辑器，你可以自由安排“我方”和“对方”的台词。</div>';
  
  // 每个情境的台词编辑区块
  situationNames.forEach(function(sit) {
    var entries = _dialogData[sit] || [];
    var label = extendedLabels[sit] || SITUATION_LABELS[sit] || sit;
    html += '<div class="dg-edit-section">';
    html += '<div class="dg-edit-header">'
         + '<span class="dg-edit-sit-label">' + label + '</span>'
         + '<span class="dg-edit-sit-key">(' + sit + ')</span>'
         + '<button class="btn btn-sm btn-danger" onclick="deleteSituation(\'' + sit + '\')" title="删除此情境所有台词">🗑 删除</button>'
         + '</div>';
    
    entries.forEach(function(entry, ei) {
      html += '<div class="dg-entry">';
      html += '<div class="dg-entry-meta">'
           + '<label>好感门槛: <input type="number" class="dg-min-aff" value="' + (entry.minAffection || 0) + '" min="0" max="100" onchange="updateEntryMeta(\'' + sit + '\',' + ei + ',this.value,' + (entry.cooldown || 30) + ')"></label>'
           + '<label>冷却(s): <input type="number" class="dg-cooldown" value="' + (entry.cooldown || 30) + '" min="0" onchange="updateEntryMeta(\'' + sit + '\',' + ei + ',' + (entry.minAffection || 0) + ',this.value)"></label>'
           + '<button class="btn btn-sm btn-danger" onclick="deleteEntry(\'' + sit + '\',' + ei + ')">× 删除该组</button>'
           + '</div>';
      var lines = entry.lines || [];
      lines.forEach(function(line, li) {
        if (sit.startsWith('cp_')) {
          html += renderCPLineEditor(sit, ei, li, line);
        } else {
          html += '<div class="dg-line-row" style="flex-wrap:wrap">'
               + '<textarea class="dg-line-text" data-sit="' + sit + '" data-entry="' + ei + '" data-line="' + li + '" oninput="updateDialogueLine(this)">' + escapeHtml(line) + '</textarea>'
               + '<button class="btn btn-sm btn-danger" onclick="deleteLine(\'' + sit + '\',' + ei + ',' + li + ')">×</button>'
               + '</div>';
        }
      });
      if (sit.startsWith('cp_')) {
        html += '<button class="btn btn-sm" onclick="addLine(\'' + sit + '\',' + ei + ')">+ 添加多回合剧本</button>';
      } else {
        html += '<button class="btn btn-sm" onclick="addLine(\'' + sit + '\',' + ei + ')">+ 添加台词</button>';
      }
      html += '</div>';
    });
    
    html += '<button class="btn btn-sm btn-secondary" onclick="addEntry(\'' + sit + '\')">+ 添加台词组</button>';
    html += '<hr class="dg-sep"></div>';
  });
  
  container.innerHTML = html;
  updateDialogStats();
}

function updateDialogStats() {
  var total = 0;
  Object.keys(_dialogData).forEach(function(sit) {
    (_dialogData[sit] || []).forEach(function(e) {
      total += (e.lines || []).length;
    });
  });
  document.getElementById('dialogStats').textContent = Object.keys(_dialogData).length + ' 个情境 / ' + total + ' 条台词';
}

function addNewSituation() {
  var sel = document.getElementById('newSitSelect');
  var sit = sel.value;
  var text = sel.options[sel.selectedIndex].text;
  if (!sit) return;
  if (_dialogData[sit]) { showToast('该情境已存在', 'error'); return; }
  _dialogData[sit] = [];
  renderDialogueEditor();
  showToast('✅ 已添加情境: ' + text);
}

function deleteSituation(sit) {
  if (!confirm('删除情境「' + sit + '」的所有台词？')) return;
  delete _dialogData[sit];
  renderDialogueEditor();
}

function addEntry(sit) {
  if (!_dialogData[sit]) _dialogData[sit] = [];
  _dialogData[sit].push({ lines: [''], minAffection: 0, cooldown: 30 });
  renderDialogueEditor();
}

function deleteEntry(sit, ei) {
  if (!confirm('删除这组台词？')) return;
  _dialogData[sit].splice(ei, 1);
  renderDialogueEditor();
}

function addLine(sit, ei) {
  if (_dialogData[sit] && _dialogData[sit][ei]) {
    _dialogData[sit][ei].lines.push('');
    renderDialogueEditor();
  }
}

function addCPSituation() {
  var val = (document.getElementById('newCPSitInput').value || '').trim();
  if (!val) return;
  var p = null;
  for (var i = 0; i < profilesData.length; i++) {
    if (profilesData[i].name === val) { p = profilesData[i]; break; }
  }
  if (!p) { showToast('未找到干员: ' + val, 'error'); return; }
  
  var sit = 'cp_' + p.id;
  if (_dialogData[sit]) { showToast('该互动角色已添加', 'error'); return; }
  _dialogData[sit] = [];
  renderDialogueEditor();
  showToast('✅ 已添加: 遇见：' + p.name);
}

function parseCPLine(lineStr) {
    var parts = lineStr.split('|');
    var turns = [];
    parts.forEach(function(p, idx) {
        p = p.trim();
        if (!p) return;
        var speaker = '我方';
        var text = p;
        var colonIdx = p.indexOf(':');
        if (colonIdx > 0) {
            speaker = p.substring(0, colonIdx).trim();
            text = p.substring(colonIdx + 1).trim();
        } else {
            if (idx > 0) speaker = '我方'; 
        }
        turns.push({ speaker: speaker, text: text });
    });
    if (turns.length === 0) turns.push({ speaker: '我方', text: '' });
    return turns;
}

function renderCPLineEditor(sit, ei, li, lineStr) {
    var turns = parseCPLine(lineStr);
    var html = '<div class="dg-line-row cp-builder-row" style="flex-direction: column; align-items: stretch; background: rgba(0,0,0,0.05); padding: 8px; border-radius: 6px; margin-bottom: 8px;">';
    
    html += '<div style="display: flex; justify-content: space-between; margin-bottom: 8px;">'
          + '<strong>🎭 多回合剧本</strong>'
          + '<button class="btn btn-sm btn-danger" onclick="deleteLine(\'' + sit + '\',' + ei + ',' + li + ')">× 删除该剧本</button>'
          + '</div>';

    turns.forEach(function(turn, ti) {
        var isOther = (turn.speaker.toLowerCase() === 'other' || turn.speaker === '对方' || turn.speaker === 'ta');
        var speakerSel = '<select class="cp-turn-speaker" onchange="updateCPLine(\'' + sit + '\',' + ei + ',' + li + ', this)">'
                       + '<option value="我方" ' + (!isOther ? 'selected' : '') + '>我方</option>'
                       + '<option value="对方" ' + (isOther ? 'selected' : '') + '>对方</option>'
                       + '</select>';
        html += '<div class="cp-turn-row" style="display: flex; gap: 8px; margin-bottom: 4px;">'
             + speakerSel
             + '<input type="text" class="cp-turn-text" style="flex: 1;" value="' + escapeHtml(turn.text) + '" oninput="updateCPLine(\'' + sit + '\',' + ei + ',' + li + ', this)">'
             + '<button class="btn btn-sm btn-danger" onclick="removeCPTurn(\'' + sit + '\',' + ei + ',' + li + ',' + ti + ')" title="删除此回合">×</button>'
             + '</div>';
    });

    html += '<div style="margin-top: 4px;">'
          + '<button class="btn btn-sm" onclick="addCPTurn(\'' + sit + '\',' + ei + ',' + li + ')">+ 增加一个回合</button>'
          + '</div>';

    html += '</div>';
    return html;
}

function updateCPLine(sit, ei, li, el) {
    var builderRow = el.closest('.cp-builder-row');
    var turnRows = builderRow.querySelectorAll('.cp-turn-row');
    var parts = [];
    turnRows.forEach(function(row) {
        var speaker = row.querySelector('.cp-turn-speaker').value;
        var text = row.querySelector('.cp-turn-text').value.trim();
        if (text) {
            parts.push(speaker + ': ' + text);
        }
    });
    var newLine = parts.join(' | ');
    if (_dialogData[sit] && _dialogData[sit][ei]) {
        _dialogData[sit][ei].lines[li] = newLine;
        markDirty();
    }
}

function addCPTurn(sit, ei, li) {
    if (_dialogData[sit] && _dialogData[sit][ei]) {
        var lineStr = _dialogData[sit][ei].lines[li] || "";
        if (lineStr) lineStr += " | 对方: ";
        else lineStr = "我方: ";
        _dialogData[sit][ei].lines[li] = lineStr;
        markDirty();
        renderDialogueEditor();
    }
}

function removeCPTurn(sit, ei, li, ti) {
    if (_dialogData[sit] && _dialogData[sit][ei]) {
        var turns = parseCPLine(_dialogData[sit][ei].lines[li]);
        turns.splice(ti, 1);
        var parts = turns.map(function(t) { return t.speaker + ': ' + t.text; });
        _dialogData[sit][ei].lines[li] = parts.join(' | ');
        markDirty();
        renderDialogueEditor();
    }
}

function deleteLine(sit, ei, li) {
  if (_dialogData[sit] && _dialogData[sit][ei]) {
    _dialogData[sit][ei].lines.splice(li, 1);
    renderDialogueEditor();
  }
}

function updateEntryMeta(sit, ei, minAffection, cooldown) {
  if (_dialogData[sit] && _dialogData[sit][ei]) {
    _dialogData[sit][ei].minAffection = parseInt(minAffection) || 0;
    _dialogData[sit][ei].cooldown = parseInt(cooldown) || 30;
  }
}

function saveDialogues() {
  if (!_dialogCharId) return;
  var sitCount = Object.keys(_dialogData).length;
  var lineCount = 0;
  Object.keys(_dialogData).forEach(function(sit) {
    (_dialogData[sit] || []).forEach(function(e) {
      lineCount += (e.lines || []).length;
    });
  });
  
  fetch('/api/profiles/save-dialogues', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ characterId: _dialogCharId, dialogues: _dialogData })
  })
    .then(r => r.json())
    .then(function(d) {
      if (d.success) {
        showToast('✅ 台词已保存 (' + sitCount + ' 情境, ' + lineCount + ' 条台词)');
        closeDialogueEdit();
        loadProfiles();
      } else {
        showToast('❌ ' + (d.error || '保存失败'), 'error');
      }
    })
    .catch(function(e) { showToast('❌ ' + e.message, 'error'); });
}

function closeDialogueEdit() {
  document.getElementById('dialogueEditModal').style.display = 'none';
  _dialogCharId = null;
  _dialogData = {};
}

// ── 在 profile card 中添加编辑台词和删除按钮 ──
// 修改 renderProfiles 中的编辑行

// ═══════════════════════════════════════
// Phase 4: 智能体 — 自动生成角色数据
// ═══════════════════════════════════════

var _agentData = null;

// Tab 切换（智能体内）
document.addEventListener('click', function(e) {
  var tab = e.target.closest('.agent-tab');
  if (!tab) return;
  document.querySelectorAll('.agent-tab').forEach(function(t) { t.classList.remove('active'); });
  tab.classList.add('active');
  document.querySelectorAll('.agent-tab-content').forEach(function(tc) { tc.classList.remove('active'); });
  var target = document.getElementById('agent-tab-' + tab.dataset.agentTab);
  if (target) target.classList.add('active');
});

function setAgentStatus(msg, type) {
  var el = document.getElementById('agentStatus');
  el.textContent = msg;
  el.className = 'agent-status' + (type ? ' ' + type : '');
}

function runAgent() {
  var name = document.getElementById('agentName').value.trim();
  if (!name) { showToast('请输入角色名', 'error'); return; }

  var btn = document.getElementById('agentRunBtn');
  var resultDiv = document.getElementById('agentResult');
  var saveBtn = document.getElementById('agentSaveBtn');
  btn.disabled = true; btn.textContent = '⏳ 生成中...';
  resultDiv.style.display = 'none';
  saveBtn.disabled = true;
  setAgentStatus('🔍 正在爬取 prts.wiki 数据...', 'info');

  _agentData = null;

  var useAI = document.getElementById('agentAI') ? document.getElementById('agentAI').checked : false;
  if (useAI) {
    setAgentStatus('🤖 正在爬取 prts.wiki + AI 润色（DeepSeek）...', 'info');
  } else {
    setAgentStatus('🔍 正在爬取 prts.wiki（无 AI）...', 'info');
  }
  
  fetch('/api/agent/generate', {
    method: 'POST',
    body: JSON.stringify({ name: name, use_ai: useAI })
  })
  .then(function(r) { return r.text(); })
  .then(function(text) {
    try {
      var d = JSON.parse(text);
      btn.disabled = false; btn.textContent = '🚀 生成';
      if (d.success === false || d.error) {
        setAgentStatus('❌ ' + (d.error || '生成失败（返回为空）'), 'error');
        return;
      }
      _agentData = d;
      
      if (typeof profilesData !== 'undefined' && _agentData.profile && _agentData.profile.id) {
          var existing = null;
          for (var i = 0; i < profilesData.length; i++) {
              if (profilesData[i].id === _agentData.profile.id) {
                  existing = profilesData[i];
                  break;
              }
          }
          if (existing && existing.dialogues && _agentData.dialogues) {
              for (var k in existing.dialogues) {
                  if (k.startsWith('cp_') || k.startsWith('app_') || !_agentData.dialogues[k]) {
                      _agentData.dialogues[k] = existing.dialogues[k];
                  }
              }
          }
      }

      var aiUsed = document.getElementById('agentAI') ? document.getElementById('agentAI').checked : false;
      setAgentStatus(aiUsed ? '✅ AI 润色完成！请审核数据后保存' : '✅ 生成完成！请审核数据后保存', 'success');
      renderAgentPreview(d);
      resultDiv.style.display = 'block';
      saveBtn.disabled = false;
    } catch (e) {
      btn.disabled = false; btn.textContent = '🚀 生成';
      setAgentStatus('❌ 解析失败: ' + text.substring(0, 100) + '... Error: ' + e.message, 'error');
    }
  })
  .catch(function(e) {
    btn.disabled = false; btn.textContent = '🚀 生成';
    setAgentStatus('❌ 请求失败: ' + e.message, 'error');
  });
}

function renderAgentPreview(data) {
  var profile = data.profile || data;
  if (!_agentData) _agentData = data;

  // ── Profile 编辑表单 ──
  var fields = [
    { label: '角色名', key: 'name' },
    { label: '头衔', key: 'subtitle' },
    { label: '种族', key: 'race' },
    { label: '出身地', key: 'origin' },
    { label: '职业', key: 'classLabel' },
    { label: '阵营', key: 'faction' },
    { label: '生日', key: 'birthday' },
    { label: '身高', key: 'height' },
    { label: '感染者', key: 'infected', fmt: function(v) { return v ? '是' : '否'; } },
  ];
  var textFields = [
    { label: '性格', key: 'personality' },
    { label: '语言风格', key: 'speechStyle' },
    { label: '对博士态度', key: 'attitudeTowardsDoctor' },
    { label: '背景', key: 'backgroundSummary' },
  ];

  var html = '<div class="agent-edit-form">';
  fields.forEach(function(f) {
    var val = profile[f.key];
    if (f.fmt) val = f.fmt(val);
    html += '<div class="aef-row">'
         + '<label>' + f.label + '</label>'
         + '<input class="aef-input" data-key="' + f.key + '" value="' + escAttr(String(val || '')) + '" oninput="editAgentField(this)" />'
         + '</div>';
  });
  textFields.forEach(function(f) {
    var val = profile[f.key] || '';
    html += '<div class="aef-row aef-row-text">'
         + '<label>' + f.label + '</label>'
         + '<textarea class="aef-textarea" data-key="' + f.key + '" oninput="editAgentField(this)">' + escHtml(val) + '</textarea>'
         + '</div>';
  });

  // signatureLines
  var sigs = profile.signatureLines || [];
  html += '<div class="aef-row aef-row-text">'
       + '<label>经典台词</label>'
       + '<div class="aef-list" id="aefSigList">';
  sigs.forEach(function(s, i) {
    html += '<div class="aef-list-row">'
         + '<textarea class="aef-textarea" data-list="signatureLines" data-index="' + i + '" oninput="editAgentListItem(this)">' + escHtml(s) + '</textarea>'
         + '<button class="aef-del" onclick="removeAgentListItem(\'signatureLines\',' + i + ')">×</button></div>';
  });
  html += '</div><button class="btn btn-sm" onclick="addAgentListItem(\'signatureLines\')">+ 添加</button></div>';

  // screenAttitude
  var sa = profile.screenAttitude || {};
  var saKeys = Object.keys(sa);
  html += '<div class="aef-row aef-row-text">'
       + '<label>屏幕态度</label>'
       + '<div class="aef-list" id="aefSaList">';
  saKeys.forEach(function(k) {
    html += '<div class="aef-list-row">'
         + '<span class="aef-key">' + k + '</span>'
         + '<textarea class="aef-textarea" data-key="screenAttitude" data-sa-key="' + k + '" oninput="editAgentSa(this)">' + escHtml(sa[k] || '') + '</textarea>'
         + '</div>';
  });
  html += '</div></div>';
  html += '</div>';
  document.getElementById('agentProfileView').innerHTML = html;

  // ── Dialogues 编辑 ──
  var dialogues = data.dialogues || {};
  var dKeys = Object.keys(dialogues);
  var dhtml = '<div class="agent-edit-form">';
  dKeys.forEach(function(k) {
    var entries = dialogues[k] || [];
    dhtml += '<div class="dg-section"><h4 class="dg-cat">' + k + '</h4>';
    entries.forEach(function(e, ei) {
      var lines = e.lines || [];
      lines.forEach(function(l, li) {
        dhtml += '<div class="aef-list-row">'
             + '<textarea class="aef-textarea" data-dg-key="' + k + '" data-dg-entry="' + ei + '" data-dg-line="' + li + '" oninput="editAgentDg(this)">' + escHtml(l) + '</textarea>'
             + '</div>';
      });
    });
    dhtml += '</div>';
  });
  dhtml += '</div>';
  document.getElementById('agentDialoguesView').innerHTML = dhtml;

  // ── 原始 JSON tab（只读） ──
  document.getElementById('agentRawView').textContent = JSON.stringify(_agentData, null, 2);
}

// ── 编辑操作 ──
function editAgentField(el) {
  var key = el.dataset.key;
  var profile = (_agentData.profile || _agentData);
  profile[key] = el.value;
  refreshAgentRaw();
}

function editAgentListItem(el) {
  var list = el.dataset.list;
  var idx = parseInt(el.dataset.index);
  var profile = (_agentData.profile || _agentData);
  if (profile[list] && profile[list][idx] !== undefined) {
    profile[list][idx] = el.value;
    refreshAgentRaw();
  }
}

function removeAgentListItem(list, idx) {
  var profile = (_agentData.profile || _agentData);
  if (profile[list]) {
    profile[list].splice(idx, 1);
    renderAgentPreview(_agentData);
  }
}

function addAgentListItem(list) {
  var profile = (_agentData.profile || _agentData);
  if (!profile[list]) profile[list] = [];
  profile[list].push('');
  renderAgentPreview(_agentData);
}

function editAgentSa(el) {
  var saKey = el.dataset.saKey;
  var profile = (_agentData.profile || _agentData);
  if (profile.screenAttitude) {
    profile.screenAttitude[saKey] = el.value;
    refreshAgentRaw();
  }
}

function updateDialogueLine(el) {
  var sit = el.getAttribute('data-sit');
  var ei = parseInt(el.getAttribute('data-entry'), 10);
  var li = parseInt(el.getAttribute('data-line'), 10);
  if (_dialogData[sit] && _dialogData[sit][ei]) {
    _dialogData[sit][ei].lines[li] = el.value;
  }
}

function insertTextAtCursor(btn, text) {
  var row = btn.parentElement.parentElement;
  var ta = row.querySelector('textarea.dg-line-text');
  if (!ta) return;
  var start = ta.selectionStart;
  var end = ta.selectionEnd;
  var val = ta.value;
  ta.value = val.substring(0, start) + text + val.substring(end);
  ta.selectionStart = ta.selectionEnd = start + text.length;
  ta.focus();
  updateDialogueLine(ta);
}

function editAgentDg(el) {
  var k = el.dataset.dgKey;
  var ei = parseInt(el.dataset.dgEntry);
  var li = parseInt(el.dataset.dgLine);
  var dg = _agentData.dialogues || {};
  if (dg[k] && dg[k][ei] && dg[k][ei].lines && dg[k][ei].lines[li] !== undefined) {
    dg[k][ei].lines[li] = el.value;
    refreshAgentRaw();
  }
}

function refreshAgentRaw() {
  document.getElementById('agentRawView').textContent = JSON.stringify(_agentData, null, 2);
}

function saveAgentProfile() {
  if (!_agentData) return;
  var btn = document.getElementById('agentSaveBtn');
  var status = document.getElementById('agentSaveStatus');
  btn.disabled = true;
  status.textContent = '⏳ 保存中...';

  fetch('/api/agent/save', {
    method: 'POST',
    body: JSON.stringify({
      profile: _agentData.profile || _agentData,
      dialogues: _agentData.dialogues || {}
    })
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    btn.disabled = false;
    if (d.success) {
      status.textContent = '✅ 已保存！';
      showToast('✅ 角色数据已保存到角色库');
      // 刷新全局数据
      if (typeof refreshAll === 'function') refreshAll();
    } else {
      status.textContent = '❌ ' + (d.error || '保存失败');
    }
  })
  .catch(function(e) {
    btn.disabled = false;
    status.textContent = '❌ ' + e.message;
  });
}

// ── AI 配置 ──
var _aiConfigData = null;

function toggleAI() {
  var cb = document.getElementById('agentAI');
  if (cb && cb.checked) {
    // 检查是否有配置
    loadAIConfig(function(configured) {
      if (!configured) {
        document.getElementById('aiConfigBar').style.display = 'block';
        renderAIConfigForm();
      }
    });
  }
}

function loadAIConfig(callback) {
  callback = callback || function(){};
  fetch('/api/ai-config')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      _aiConfigData = d;
      callback(d.configured);
    })
    .catch(function() { callback(false); });
}

function showAIConfig() {
  var bar = document.getElementById('aiConfigBar');
  if (bar.style.display === 'block') {
    bar.style.display = 'none';
  } else {
    bar.style.display = 'block';
    loadAIConfig(function() {
      renderAIConfigForm();
    });
  }
}

function renderAIConfigForm() {
  var d = _aiConfigData || {};
  var html = '<div class="ai-config-inner">'
    + '<span class="ai-config-label">🤖 AI API 配置</span>'
    + '<div class="ai-config-fields">'
    + '<input type="password" id="aiApiKey" placeholder="API Key" value="" class="ai-input-sm">'
    + '<input type="text" id="aiApiBase" placeholder="API Base URL" value="' + escAttr(d.api_base || 'https://api.deepseek.com/v4') + '" class="ai-input-sm">'
    + '<input type="text" id="aiModel" placeholder="Model" value="' + escAttr(d.model || 'deepseek-v4') + '" class="ai-input-sm">'
    + '</div>'
    + '<div class="ai-config-actions">'
    + '<button class="btn btn-sm" onclick="saveAIConfig()">💾 保存</button>'
    + '<span class="ai-config-status">' + (d.configured ? '✅ 已配置: ' + (d.api_key_masked || '') : '❌ 未配置') + '</span>'
    + '</div>'
    + '</div>';
  document.getElementById('aiConfigBar').innerHTML = html;
}

function saveAIConfig() {
  var payload = {
    api_key: document.getElementById('aiApiKey').value.trim(),
    api_base: document.getElementById('aiApiBase').value.trim(),
    model: document.getElementById('aiModel').value.trim()
  };
  if (!payload.api_key) { showToast('请输入 API Key', 'error'); return; }
  
  fetch('/api/ai-config', {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (d.success) {
        showToast('✅ AI 配置已保存');
        loadAIConfig(function() { renderAIConfigForm(); });
      } else {
        showToast('❌ ' + (d.error || '保存失败'), 'error');
      }
    })
    .catch(function(e) { showToast('❌ ' + e.message, 'error'); });
}

// 初始化时加载 AI 配置
setTimeout(function() { loadAIConfig(); }, 500);

function clearAgentResult() {
  _agentData = null;
  document.getElementById('agentResult').style.display = 'none';
  document.getElementById('agentName').value = '';
  document.getElementById('agentSaveBtn').disabled = true;
  document.getElementById('agentSaveStatus').textContent = '';
  setAgentStatus('', '');
}

function escHtml(s) {
  var d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}

function escAttr(s) {
  return String(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function refineCharacterWithAI(name) {
  if (!confirm('确定要消耗 API 额度，对干员「' + name + '」进行 AI 深度润色吗？')) {
    return;
  }
  
  // Reuse the agent panel logic
  document.getElementById('agentName').value = name;
  var aiCheckbox = document.getElementById('agentAI');
  if (aiCheckbox) aiCheckbox.checked = true;
  
  // Scroll to top and expand agent section
  var agentSection = document.getElementById('agentSection');
  if (agentSection) agentSection.open = true;
  window.scrollTo({ top: 0, behavior: 'smooth' });
  
  runAgent();
}
