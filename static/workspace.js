(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const clone = value => JSON.parse(JSON.stringify(value));
  const stable = value => JSON.stringify(value, (_, item) => item && typeof item === 'object' && !Array.isArray(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
  const states = {waiting_model:'等待助手', waiting_input:'等待补充', completed:'已完成', running:'保存中', failed:'失败', interrupted:'已中断'};
  const verdicts = {met:'满足', unmet:'不满足', unknown:'缺少证据', conflict:'要求冲突', not_applicable:'本次不适用'};
  const kinds = {review:'评审', summarize:'总结', compare:'对比', organize:'整理', draft:'补写', plan:'计划'};
  const keys = {draft:'ai-workbench-draft-v1', pending:'ai-workbench-command-v1', last:'ai-workbench-last-task-v1', answers:'ai-workbench-answers-v1', view:'ai-workbench-view-v1'};
  let workbench = null, scope = new Set(), warnings = [], current = null, target = null;
  let epoch = 0, historyEpoch = 0, importEpoch = 0, posting = false, polling = false, pending = null, startupError = '', answers = {};
  const invalidFields = new Set();
  const snapshots = new Map();
  function error(message='') { $('error').textContent = message; $('error').hidden = !message; }
  function save(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); }
    catch { throw new Error('本机保存失败。输入仍在页面中，请下载工作台备份后重试。'); }
  }
  function read(key) { return JSON.parse(localStorage.getItem(key) || 'null'); }
  function available() { return !posting && !pending && !startupError; }
  function controls() {
    $('task-form').querySelectorAll('input,textarea,select,button').forEach(el => { el.disabled = !available(); });
    $('submit').disabled = !available() || !workbench;
    $('task-detail').querySelectorAll('[data-answer],#answer-submit,[data-change],#apply-changes').forEach(el => { el.disabled = !available(); });
    $('pending').hidden = !pending; $('retry').disabled = posting || !!startupError;
    $('new-task').disabled = !!startupError;
  }
  function draft() {
    return {version:1, workbench, scope:[...scope], warnings, title:$('task-title').value,
      task_type:$('task-type').value, goal:$('goal').value, deliverable:$('deliverable').value,
      mode:$('mode').value, task_requirements:$('task-requirements').value};
  }
  function persistDraft() { save(keys.draft, draft()); $('save-state').textContent = '输入已保存在本机'; }
  function edited() { ++importEpoch; if (workbench) { workbench.revision++; $('workbench-version').textContent = '版本 ' + workbench.revision; } persistDraft(); }
  function sourceCard(citation, task) {
    const s = task.sources[citation.source_id];
    if (!s) return '<p class="notice">来源快照暂时缺失，请刷新后核对。</p>';
    return `<details class="citation"><summary>${esc(s.title)} · 查看依据</summary><blockquote>${esc(citation.quote)}</blockquote><p class="source-path">${esc(s.path)}</p><details><summary>本次原文快照</summary><pre>${esc(s.text)}</pre><p class="source-path">SHA-256 ${esc(s.sha256)}</p></details></details>`;
  }
  function validatePackage(value) {
    if (!value || value.format !== 'ai-workbench' || value.schema_version !== 1 || typeof value.id !== 'string' ||
        typeof value.title !== 'string' || !Number.isInteger(value.revision) || value.revision < 0 ||
        !Array.isArray(value.structure) || !Array.isArray(value.objects) || !value.objects.length ||
        !Array.isArray(value.requirements) || !value.requirements.length ||
        value.objects.some(o => !o || typeof o.id !== 'string' || typeof o.kind !== 'string' || !o.fields) ||
        value.requirements.some(r => !r || typeof r.id !== 'string' || typeof r.text !== 'string' || !Array.isArray(r.object_ids))) {
      throw new Error('工作台数据不完整；已保留原输入，请重新导入有效的工作台。');
    }
    return value;
  }
  function validateTask(task) {
    if (!task || typeof task.id !== 'string' || !Number.isInteger(task.revision) || task.revision < 1 ||
        !Object.hasOwn(states, task.status) || !task.input || !Object.hasOwn(kinds, task.input.task_type) ||
        typeof task.input.title !== 'string' || !task.requirements || !task.sources || !task.checks ||
        !Array.isArray(task.questions) || !task.answers || !Array.isArray(task.conflicts) ||
        (task.result && (!Array.isArray(task.result.artifacts) || !Array.isArray(task.result.requirement_results) || !Array.isArray(task.result.changes)))) {
      throw new Error('任务响应不完整，原请求与输入已保留，请刷新或重试。');
    }
    validatePackage(task.input.workbench);
    return task;
  }
  function remember(task) {
    validateTask(task);
    if (!snapshots.has(task.id) || task.revision > snapshots.get(task.id).revision) snapshots.set(task.id, task);
    return snapshots.get(task.id);
  }
  async function api(path, options={}) {
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
    try {
      let response;
      try { response = await fetch('/api' + path, {...options, signal:controller.signal}); }
      catch { $('connection').textContent = '连接中断'; throw new Error('暂时无法连接工作台。未确认的提交已保留，可重试原提交。'); }
      let body;
      try { body = await response.json(); } catch { throw new Error('工作台响应无法读取，请刷新或重试原提交。'); }
      if (!response.ok) {
        const failure = new Error(typeof body?.detail === 'string' ? body.detail : '输入未通过校验，请核对工作台要求、范围和必填内容。');
        failure.status = response.status; throw failure;
      }
      $('connection').textContent = '工作台已连接'; return body;
    } finally { clearTimeout(timeout); }
  }
  function renderWorkbench() {
    $('empty-workbench').hidden = !!workbench; $('workbench').hidden = !workbench;
    if (!workbench) return controls();
    $('workbench-title').value = workbench.title; $('workbench-version').textContent = '版本 ' + workbench.revision;
    $('counts').innerHTML = `<span><b>${workbench.objects.length}</b>条内容</span><span><b>${workbench.requirements.length}</b>项要求</span><span><b>${scope.size}</b>条待处理</span>`;
    $('import-warnings').textContent = warnings.join('\n'); $('import-warnings').hidden = !warnings.length;
    const specs = new Map(workbench.structure.map(s => [s.kind, s]));
    $('objects').innerHTML = workbench.objects.map(obj => {
      const spec = specs.get(obj.kind) || {label:obj.kind, fields:{}, states:[]};
      return `<details class="object-card" data-object-card="${esc(obj.id)}"><summary><input type="checkbox" data-scope="${esc(obj.id)}" aria-label="处理 ${esc(obj.title)}" ${scope.has(obj.id)?'checked':''}><span>${esc(obj.title)}</span><span class="object-state">${esc(obj.state || spec.label)}</span></summary><label>条目名称<input data-object="${esc(obj.id)}" data-property="title" value="${esc(obj.title)}" required></label><label>内容<textarea data-object="${esc(obj.id)}" data-property="content" rows="3">${esc(obj.content)}</textarea></label><div class="object-fields">${Object.entries(spec.fields).map(([name,label]) => `<label>${esc(label)}<input data-object="${esc(obj.id)}" data-field="${esc(name)}" data-json="${typeof obj.fields[name] !== 'string' && obj.fields[name] != null}" value="${esc(obj.fields[name] != null && typeof obj.fields[name] !== 'string' ? JSON.stringify(obj.fields[name]) : obj.fields[name] ?? '')}"></label>`).join('')}${spec.states.length ? `<label>当前状态<select data-object="${esc(obj.id)}" data-property="state"><option value="">未记录</option>${spec.states.map(s => `<option ${s===obj.state?'selected':''}>${esc(s)}</option>`).join('')}</select></label>` : `<label>当前状态<input data-object="${esc(obj.id)}" data-property="state" value="${esc(obj.state)}"></label>`}</div><p class="source-path">来源：${esc(obj.source)}${obj.availability==='metadata_only'?' · 仅元信息，原内容尚未读取':''}</p></details>`;
    }).join('');
    $('requirements').innerHTML = workbench.requirements.map(r => `<details class="requirement-card"><summary class="requirement-heading"><strong>${esc(r.text || '新要求 · 点击填写')}</strong><small>${r.priority==='must'?'必须':'建议'}${r.rule?' · 字段规则':''}</small></summary><div class="requirement-heading"><small>${esc(r.id)}</small><button type="button" data-remove-requirement="${esc(r.id)}">移除</button></div><label>要求<textarea data-requirement="${esc(r.id)}" data-property="text" minlength="4" required rows="2">${esc(r.text)}</textarea></label><label>验收方式<textarea data-requirement="${esc(r.id)}" data-property="acceptance" minlength="4" required rows="2">${esc(r.acceptance)}</textarea></label><div class="requirement-meta"><label>要求来源<input data-requirement="${esc(r.id)}" data-property="source" required value="${esc(r.source)}"></label><label>优先级<select data-requirement="${esc(r.id)}" data-property="priority"><option value="must" ${r.priority==='must'?'selected':''}>必须满足</option><option value="should" ${r.priority==='should'?'selected':''}>建议满足</option></select></label></div><label>适用条目（可多选，留空表示整个工作台）<select multiple data-requirement="${esc(r.id)}" data-property="object_ids">${workbench.objects.map(o=>`<option value="${esc(o.id)}" ${r.object_ids.includes(o.id)?'selected':''}>${esc(o.title)}</option>`).join('')}</select></label><details class="editor-section"><summary>字段规则与已知冲突</summary><label>字段校验规则（JSON，可留空）<textarea data-requirement="${esc(r.id)}" data-property="rule" rows="3" spellcheck="false">${r.rule?esc(JSON.stringify(r.rule,null,2)):''}</textarea></label><label>与哪些要求冲突（编号，以逗号分隔）<input data-requirement="${esc(r.id)}" data-property="conflicts_with" value="${esc(r.conflicts_with.join(', '))}"></label></details></details>`).join('');
    $('package-json').value = JSON.stringify(workbench, null, 2); controls();
  }
  function adopt(value, notices=[]) {
    validatePackage(value);
    const old = {workbench, scope, warnings};
    workbench = clone(value); scope = new Set(workbench.objects.filter(o => o.kind !== 'reference').map(o => o.id)); warnings = notices;
    try { persistDraft(); } catch (e) { workbench=old.workbench; scope=old.scope; warnings=old.warnings; throw e; }
    ++importEpoch; invalidFields.clear();
    renderWorkbench();
  }
  async function importContent(filename, content) {
    if (!available()) return;
    const token=++importEpoch;
    const response = await api('/workbenches/import', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({filename, content})});
    if(token!==importEpoch || !available())return;
    adopt(response.workbench, response.warnings); error(); return response;
  }
  async function history() {
    const version = ++historyEpoch, rows = await api('/tasks');
    if (version !== historyEpoch) return;
    $('history').innerHTML = rows.length ? rows.map(row => {
      const r = snapshots.get(row.id) || row;
      return `<button type="button" class="history-item ${target===r.id?'active':''}" data-task="${esc(r.id)}"><strong>${esc(r.input?.title || r.title)}</strong><small>${esc(kinds[r.input?.task_type || r.task_type])} · ${esc(states[r.status])}</small></button>`;
    }).join('') : '<p class="muted">还没有任务。<br>带入一份工作台即可开始。</p>';
  }
  function show(task) {
    task = remember(task);
    if (current?.id === task.id && current.revision === task.revision && target === task.id) return;
    const focus = document.activeElement?.dataset.answer;
    const selection = focus ? [document.activeElement.selectionStart, document.activeElement.selectionEnd] : null;
    current = task; target = task.id; $('composer').hidden = true; $('task-detail').hidden = false;
    let html = `<div class="card"><div class="result-heading"><div><p class="eyebrow">${esc(kinds[task.input.task_type])} · ${esc(task.input.workbench.title)}</p><h2>${esc(task.input.title)}</h2></div><span class="badge ${esc(task.status)}">${esc(states[task.status])}</span></div><p class="task-goal">${esc(task.input.goal)}<br>交付要求：${esc(task.input.deliverable)}</p>`;
    if (task.input.mode === 'scripted') html += '<div class="notice">离线演示：字段规则已检查，语义任务尚未由模型完成。</div>';
    if (task.error) html += `<p class="notice error">${esc(task.error)}</p>`;
    if (task.conflicts.length) html += `<div class="notice error"><strong>有 ${task.conflicts.length} 组要求冲突，需要明确处理</strong>${task.conflicts.map(c => `<p>${c.requirement_ids.map(id=>esc(task.requirements[id].text)).join('<br>')}<br>${esc(c.reason)}</p>`).join('')}</div>`;
    if (task.status === 'waiting_model') html += `<div class="wait"><h3>工作台已就绪，等待助手接手</h3><p>把下面的指令发送给已连接工作台的桌面助手：</p><p class="instruction" id="instruction">处理 AI Workspace 中的任务 ${esc(task.id)}，按其目标和所有要求提交带原文引用的结果；信息不足时先提问。</p><button type="button" id="copy-instruction">复制指令</button></div>`;
    if (task.status === 'waiting_input') html += `<form id="answer-form"><h3>补充几个事实</h3>${task.questions.map(q => `<label>${esc(q.text)}<textarea data-answer="${esc(q.id)}" required maxlength="2000">${esc(answers[task.id]?.[q.id] || '')}</textarea></label>`).join('')}<button type="submit" id="answer-submit" class="primary">保存回答并继续 →</button></form>`;
    if (task.result) {
      html += `<p>${esc(task.result.summary)}</p>${task.result.artifacts.map(a => `<article class="artifact"><h3>${esc(a.title)}</h3><pre>${esc(a.content)}</pre>${a.citations.map(c => sourceCard(c,task)).join('')}</article>`).join('')}<h3>每项要求的回应</h3>`;
      html += task.result.requirement_results.map(r => `<article class="result-item"><div class="row"><h3>${esc(task.requirements[r.requirement_id]?.text || r.requirement_id)}</h3><span class="badge ${esc(r.verdict)}">${esc(verdicts[r.verdict])}</span></div><p>${esc(r.explanation)}</p>${r.recommendation?`<p class="muted">下一步：${esc(r.recommendation)}</p>`:''}${r.citations.map(c=>sourceCard(c,task)).join('')}</article>`).join('');
      if (task.result.changes.length) html += `<h3 style="margin-top:24px">选择要应用的修改</h3><p class="muted">选中的修改会生成工作台的新版本，原始快照可继续核对。</p>${task.result.changes.map(c=>`<article class="change"><label><input type="checkbox" data-change="${esc(c.id)}">${esc(task.input.workbench.objects.find(o=>o.id===c.object_id)?.title || c.object_id)} · ${esc(c.field || c.target)}</label><pre>${esc(typeof c.value==='string'?c.value:JSON.stringify(c.value))}</pre><p class="muted">${esc(c.reason)}</p>${c.citations.map(v=>sourceCard(v,task)).join('')}</article>`).join('')}${task.applied_workbench?'<p class="notice success">已生成新工作台版本，可下载或继续处理。</p>':'<button type="button" id="apply-changes">应用选中修改，生成新版本</button>'}`;
    } else html += `<details class="editor-section" open><summary>已登记的要求与字段检查</summary>${Object.entries(task.requirements).map(([id,r])=>`<article class="result-item"><div class="row"><h3>${esc(r.text)}</h3><span class="badge ${esc(task.checks[id].verdict)}">${esc(verdicts[task.checks[id].verdict])}</span></div><p class="muted">验收：${esc(r.acceptance)}<br>来源：${esc(r.source)}</p></article>`).join('')}</details>`;
    html += `<div class="exports"><button type="button" data-export="markdown">导出报告</button><button type="button" data-export="json">导出完整记录</button><button type="button" data-export="workbench">下载工作台</button><button type="button" id="continue-task">在此工作台上继续</button></div><details class="editor-section"><summary>输入版本与完整快照</summary><p class="source-path">工作台 ${esc(task.input.workbench.id)} · 版本 ${task.input.workbench.revision}<br>任务版本 ${task.revision}<br>输入 SHA-256 ${esc(task.input_sha256)}</p><pre class="source-path">${esc(JSON.stringify(task.input.workbench, null, 2))}</pre></details></div>`;
    $('task-detail').innerHTML = html; controls();
    document.querySelectorAll('[data-task]').forEach(el => el.classList.toggle('active', el.dataset.task===target));
    if (focus) { const element = [...$('task-detail').querySelectorAll('[data-answer]')].find(el=>el.dataset.answer===focus); if (element) {element.focus();element.setSelectionRange(...selection);} }
    try { save(keys.view, task.id); } catch (e) { error(e.message); }
  }
  async function select(id) {
    const version = ++epoch; target=id; current=null; $('composer').hidden=true; $('task-detail').hidden=false;
    $('task-detail').innerHTML = '<p role="status">正在读取任务…</p>';
    try {
      const task = validateTask(await api('/tasks/' + encodeURIComponent(id)));
      if (version!==epoch || target!==id) return;
      if (task.id!==id) throw new Error('响应与所选任务不一致，请刷新核对。');
      const latest=remember(task); save(keys.last, latest); show(latest);
    } catch (e) { if(version===epoch && target===id) error(e.message); }
  }
  function fresh() {
    ++epoch; target=null; current=null; $('composer').hidden=false; $('task-detail').hidden=true;
    try { save(keys.view, 'draft'); } catch (e) { error(e.message); }
    document.querySelectorAll('[data-task]').forEach(el=>el.classList.remove('active')); controls();
  }
  async function send(command) {
    if (posting || startupError) return;
    const version=epoch, selected=target; posting=true; error(); controls();
    try {
      save(keys.pending, command); pending=command; controls();
      const task = validateTask(await api(command.path, {method:'POST', headers:{'Content-Type':'application/json','Idempotency-Key':command.key},body:JSON.stringify(command.body)}));
      if (command.kind==='create' && stable(task.input)!==stable(command.body)) throw new Error('任务响应与原始输入不一致，原提交已保留。');
      if (command.kind!=='create' && task.id!==command.task_id) throw new Error('响应属于其他任务，原提交已保留。');
      const latest=remember(task); save(keys.last, latest);
      if (command.kind==='answer') {const next=clone(answers); delete next[task.id];save(keys.answers,next);answers=next;}
      if (command.kind==='apply' && task.applied_workbench && workbench && stable(workbench)===stable(task.input.workbench)) adopt(task.applied_workbench);
      localStorage.removeItem(keys.pending); pending=null;
      if (version===epoch && selected===target) show(task);
      history().catch(e=>error(e.message));
    } catch (e) {
      if (e.status>=400 && e.status<500) {try {localStorage.removeItem(keys.pending);pending=null;} catch {e=new Error('拒绝回执尚未保存，请保留原请求并重试。');}}
      if (version===epoch) error(e.message);
    } finally {posting=false;controls();}
  }
  function download(value, name, type='application/json') {
    const url=URL.createObjectURL(new Blob([value],{type})), link=document.createElement('a');
    link.href=url;link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  function localMarkdown(task) {
    const lines=[`# ${task.input.title}`, '', `目标：${task.input.goal}`, `交付要求：${task.input.deliverable}`, '', `工作台版本：${task.input.workbench.revision}`, `输入 SHA-256：${task.input_sha256}`];
    if(task.input.mode==='scripted') lines.push('', '离线演示；语义任务尚未由模型完成。');
    for(const [id,r] of Object.entries(task.requirements)) lines.push('', `## ${r.text}`, `来源：${r.source}`, `验收：${r.acceptance}`, task.result?.requirement_results.find(item=>item.requirement_id===id)?.explanation || '待处理');
    if(task.result) for(const item of [...task.result.artifacts,...task.result.requirement_results,...task.result.changes]) {
      if(item.content)lines.push('', `## ${item.title}`,item.content);
      if(item.object_id)lines.push('', `修改建议：${item.object_id} / ${item.field || item.target} → ${JSON.stringify(item.value)}`,item.reason);
      if(item.verdict)lines.push(`结论：${verdicts[item.verdict]}`,item.recommendation);
      for(const c of item.citations){const s=task.sources[c.source_id];lines.push('',`来源：${s?.title || c.source_id} · ${s?.path || ''}`,`> ${c.quote.replace(/\n/g,'\n> ')}`);}
    }
    for(const q of task.questions)lines.push('',q.text,task.answers[q.id] || '待回答');
    return lines.join('\n');
  }
  $('task-form').addEventListener('submit',async event=>{
    event.preventDefault();if(!available()||!workbench)return;
    try {
      if(!scope.size)throw new Error('请至少选择一条处理内容。');
      if(invalidFields.size)throw new Error('条目字段还有未保存的无效数据，请先修正。');persistDraft();
      const extra=$('task-requirements').value.split('\n').map(s=>s.trim()).filter(Boolean).map((text,index)=>({id:'extra-'+(index+1),text,object_ids:[],priority:'must',source:'用户本次任务',acceptance:text,conflicts_with:[],rule:null}));
      const body={mode:$('mode').value,title:$('task-title').value.trim(),workbench:clone(workbench),task_type:$('task-type').value,goal:$('goal').value,scope:[...scope],deliverable:$('deliverable').value,requirements:extra};
      await send({version:1,key:crypto.randomUUID(),kind:'create',path:'/tasks',body});
    } catch(e){error(e.message);}
  });
  $('task-detail').addEventListener('submit',async event=>{
    if(event.target.id!=='answer-form')return;event.preventDefault();if(!available()||!current)return;
    const values=Object.fromEntries([...event.target.querySelectorAll('[data-answer]')].map(el=>[el.dataset.answer,el.value]));
    try {answers[current.id]=values;save(keys.answers,answers);await send({version:1,key:crypto.randomUUID(),kind:'answer',task_id:current.id,path:'/tasks/'+encodeURIComponent(current.id)+'/answers',body:{revision:current.revision,answers:values}});}catch(e){error(e.message);}
  });
  $('task-detail').addEventListener('input',event=>{if(event.target.dataset.answer && available() && current){answers[current.id]={...answers[current.id],[event.target.dataset.answer]:event.target.value};try{save(keys.answers,answers);}catch(e){error(e.message);}}});
  $('task-detail').addEventListener('click',async event=>{
    const button=event.target.closest('button');if(!button||!current)return;
    try {
      if(button.id==='copy-instruction'){await navigator.clipboard.writeText($('instruction').textContent);button.textContent='已复制';}
      if(button.dataset.export){const type=button.dataset.export;download(type==='markdown'?localMarkdown(current):JSON.stringify(type==='workbench'?current.applied_workbench || current.input.workbench:current,null,2),'task-'+current.id+(type==='markdown'?'.md':'.json'),type==='markdown'?'text/markdown':'application/json');}
      if(button.id==='continue-task' && available()){adopt(current.applied_workbench || current.input.workbench);fresh();}
      if(button.id==='apply-changes' && available()){
        const selected=[...$('task-detail').querySelectorAll('[data-change]:checked')].map(el=>el.dataset.change);
        if(!selected.length)throw new Error('请先选中要应用的修改。');
        if(workbench && stable(workbench)!==stable(current.input.workbench))throw new Error('当前工作台已变化。请核对输入版本，或在此结果的工作台上继续处理。');
        await send({version:1,key:crypto.randomUUID(),kind:'apply',task_id:current.id,path:'/tasks/'+encodeURIComponent(current.id)+'/apply',body:{revision:current.revision,workbench_sha256:current.workbench_sha256,change_ids:selected}});
      }
    }catch(e){error(e.message);}
  });
  $('history').addEventListener('click',event=>{const button=event.target.closest('[data-task]');if(button)select(button.dataset.task);});
  $('new-task').onclick=fresh;$('refresh').onclick=()=>{history().catch(e=>error(e.message));if(target)select(target);};
  $('retry').onclick=()=>{if(pending)send(pending);};
  $('example').onclick=async()=>{try{if(!available())return;const token=++importEpoch;const value=await api('/workbenches/example');if(token!==importEpoch||!available())return;adopt(value);$('task-title').value='筹备计划 · 执行条件核对';$('goal').value='找出筹备任务缺失的信息、阻塞项和要求冲突。';$('deliverable').value='逐条列出要求满足情况，给出对应依据和建议下一步。';persistDraft();error();}catch(e){error(e.message);}};
  $('engineering').onclick=async()=>{try{if(!available())return;const token=++importEpoch;const value=await api('/workbenches/engineering');if(token!==importEpoch||!available())return;adopt(value.workbench,value.warnings);error();}catch(e){error(e.message);}};
  $('import').onclick=()=>{if(available())$('file').click();};
  $('file').onchange=async()=>{const file=$('file').files?.[0];if(!file)return;try{if(file.size>12*1024*1024)throw new Error('文件超过 12 MiB，请缩小工作台或移除大附件。');const bytes=await file.arrayBuffer();const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);await importContent(file.name,text);}catch(e){error(e.message);}finally{$('file').value='';}};
  $('create-workbench').onclick=()=>{if(!available())return;try{adopt({format:'ai-workbench',schema_version:1,id:crypto.randomUUID(),title:'我的工作台',revision:0,structure:[{kind:'note',label:'工作记录',fields:{},states:[]}],objects:[{id:'context',kind:'note',title:'工作背景',content:'',fields:{},state:'',parent_id:null,links:[],source:'用户填写',availability:'available'}],requirements:[{id:'evidence',text:'所有事实结论需要提供可定位的依据。',acceptance:'结果中的事实结论均能定位到原文，缺少证据时明确说明。',object_ids:[],source:'工作台初始模板，可编辑',priority:'must',conflicts_with:[],rule:null}],provenance:{}});}catch(e){error(e.message);}};
  $('workbench-title').oninput=()=>{if(available()&&workbench){workbench.title=$('workbench-title').value;try{edited();}catch(e){error(e.message);}}};
  function editObject(event){
    if(!available()||!workbench)return;const el=event.target;
    try {
      if(el.dataset.scope){el.checked?scope.add(el.dataset.scope):scope.delete(el.dataset.scope);persistDraft();$('counts').lastElementChild.innerHTML=`<b>${scope.size}</b>条待处理`;}
      if(el.dataset.object){const obj=workbench.objects.find(o=>o.id===el.dataset.object),field=el.dataset.field || el.dataset.property;const value=el.dataset.field&&el.dataset.json==='true'&&el.value?JSON.parse(el.value):el.value;invalidFields.delete(el.dataset.object+':'+field);const container=el.dataset.field?obj.fields:obj;if(stable(container[field])!==stable(value)){container[field]=value;edited();$('package-json').value=JSON.stringify(workbench,null,2);}}
    }catch(e){if(el.dataset.object)invalidFields.add(el.dataset.object+':'+(el.dataset.field || el.dataset.property));error('条目保存失败：'+e.message);}
  }
  $('objects').addEventListener('input',editObject);$('objects').addEventListener('change',editObject);
  function editRequirement(event){const el=event.target;if(available()&&workbench&&el.dataset.requirement){const key='requirement:'+el.dataset.requirement+':'+el.dataset.property;try{const r=workbench.requirements.find(r=>r.id===el.dataset.requirement);let value=el.value;if(el.dataset.property==='object_ids')value=[...el.selectedOptions].map(o=>o.value);if(el.dataset.property==='rule')value=el.value.trim()?JSON.parse(el.value):null;if(el.dataset.property==='conflicts_with')value=el.value.split(',').map(s=>s.trim()).filter(Boolean);invalidFields.delete(key);if(stable(r[el.dataset.property])!==stable(value)){r[el.dataset.property]=value;edited();$('package-json').value=JSON.stringify(workbench,null,2);}if(el.dataset.property==='text')el.closest('.requirement-card').querySelector('summary strong').textContent=value || '新要求 · 点击填写';}catch(e){invalidFields.add(key);error('要求保存失败：'+e.message);}}}
  $('requirements').addEventListener('input',editRequirement);$('requirements').addEventListener('change',editRequirement);
  $('requirements').addEventListener('click',event=>{const button=event.target.closest('[data-remove-requirement]');if(!button||!available())return;try{if(workbench.requirements.length===1)throw new Error('工作台至少需要一条要求。');workbench.requirements=workbench.requirements.filter(r=>r.id!==button.dataset.removeRequirement);edited();renderWorkbench();}catch(e){error(e.message);}});
  $('add-requirement').onclick=()=>{if(!available()||!workbench)return;try{workbench.requirements.push({id:'R-'+crypto.randomUUID().slice(0,8),text:'',acceptance:'',source:'用户填写',priority:'must',object_ids:[],conflicts_with:[],rule:null});edited();renderWorkbench();$('requirements').lastElementChild.open=true;}catch(e){error(e.message);}};
  $('add-object').onclick=()=>{if(!available()||!workbench)return;try{let spec=workbench.structure.find(s=>s.kind==='note');if(!spec){spec={kind:'note',label:'工作记录',fields:{},states:[]};workbench.structure.push(spec);}const id='note-'+crypto.randomUUID().slice(0,8);workbench.objects.push({id,kind:'note',title:'新工作记录',content:'',fields:{},state:'',parent_id:null,links:[],source:'用户填写',availability:'available'});scope.add(id);edited();renderWorkbench();$('objects').lastElementChild.open=true;}catch(e){error(e.message);}};
  $('select-all').onclick=()=>{if(available()&&workbench){scope=new Set(workbench.objects.map(o=>o.id));try{persistDraft();renderWorkbench();}catch(e){error(e.message);}}};
  $('select-records').onclick=()=>{if(available()&&workbench){scope=new Set(workbench.objects.filter(o=>o.kind!=='reference').map(o=>o.id));try{persistDraft();renderWorkbench();}catch(e){error(e.message);}}};
  $('apply-json').onclick=async()=>{try{await importContent('工作台.json',$('package-json').value);}catch(e){error(e.message);}};
  $('download-workbench').onclick=()=>{if(workbench)download(JSON.stringify(workbench,null,2),workbench.id+'.json');};
  for(const id of ['task-title','goal','deliverable','task-requirements','task-type','mode'])$(id).addEventListener('input',()=>{try{persistDraft();modeNote();}catch(e){error(e.message);}});
  function modeNote(){$('mode-note').textContent=$('mode').value==='scripted'?'固定程序展示流程，执行声明的字段检查；语义任务尚未由模型完成。':'提交后，请连接工作台的桌面助手接手。信息不足时可补充回答。';}
  async function startup(){
    try{
      pending=read(keys.pending);
      if(pending && (pending.version!==1 || !pending.body || typeof pending.key!=='string' || !pending.key || !['create','answer','apply'].includes(pending.kind) || pending.path!==(pending.kind==='create'?'/tasks':'/tasks/'+encodeURIComponent(pending.task_id)+'/'+(pending.kind==='answer'?'answers':'apply'))))throw new Error('原请求记录无法读取');
      const saved=read(keys.draft);
      if(saved){if(saved.version!==1 || !Array.isArray(saved.scope))throw new Error('输入记录无法读取');if(saved.workbench)validatePackage(saved.workbench);workbench=saved.workbench;scope=new Set(saved.scope);warnings=saved.warnings || [];for(const [id,field] of [['task-title','title'],['task-type','task_type'],['goal','goal'],['deliverable','deliverable'],['mode','mode'],['task-requirements','task_requirements']]){if(typeof saved[field]!=='string')throw new Error('输入字段无法读取');$(id).value=saved[field];}}
      answers=read(keys.answers) || {};if(typeof answers!=='object'||Array.isArray(answers))throw new Error('回答记录无法读取');
      const last=read(keys.last), view=read(keys.view);if(last){remember(last);if(view===last.id)show(last);}
    }catch{startupError='本机保存记录无法读取，新的提交已暂停。请保留浏览器数据后排查。';error(startupError);}
    renderWorkbench();modeNote();controls();
    if(!startupError){
      try{const transfer=sessionStorage.getItem('ai-workbench-transfer');if(transfer&&!pending){await importContent('当前工作台.json',transfer);sessionStorage.removeItem('ai-workbench-transfer');fresh();}}catch(e){error(e.message);}
      try{await api('/config');await history();if(target)await select(target);}catch(e){error(e.message);}
    }
  }
  setInterval(async()=>{
    if(posting||polling||!current||!['waiting_model','running'].includes(current.status)||document.hidden)return;
    polling=true;const id=current.id, version=epoch;
    try{const task=validateTask(await api('/tasks/'+encodeURIComponent(id)));if(version===epoch&&target===id){if(task.id!==id)throw new Error('刷新结果与当前任务不一致');const previous=current.revision;remember(task);if(task.revision>previous){save(keys.last,task);show(task);await history();}}}catch(e){if(version===epoch)error(e.message);}finally{polling=false;}
  },2500);
  startup();
})();
