(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const labels = {waiting_model:'等待助手评审', waiting_input:'等待补充', completed:'已完成', running:'保存中', failed:'失败', interrupted:'已中断'};
  const verdicts = {supported:'有材料支持', risk:'存在风险', unknown:'信息不足', not_applicable:'不适用'};
  let catalog = [], chosen = new Set(), current = null, showingDraft = true, posting = false, polling = false;
  let lastCreate = null, lastAnswer = null, restored = false;
  const modal = document.createElement('dialog');
  modal.id = 'ai-review-dialog'; modal.dataset.aiAddon = ''; modal.setAttribute('aria-labelledby', 'ai-title');
  modal.innerHTML = `
    <header class="ai-header"><div><div class="ai-eyebrow">AI WORKSPACE <span>/</span> SWE</div><h2 id="ai-title">从设计到有依据的评审</h2><p>选择检查范围，让助手审阅，保留每一次判断的来源。</p></div><button id="ai-close" aria-label="关闭 AI 评审">关闭</button></header>
    <div class="ai-layout"><aside class="ai-history"><div class="ai-row"><strong>评审记录</strong><button id="ai-new" class="text-button">＋ 新建</button></div><p class="ai-small">保存在本机，刷新后可继续。</p><div id="ai-history-list"></div><div class="ai-history-note">人工检查仍由你确认。<br>AI 记录单独保存与导出。</div></aside>
    <section class="ai-content"><div id="ai-error" role="alert" hidden></div>
      <form id="ai-form"><div class="ai-section-heading"><div><span class="ai-step">01</span><strong>描述你的设计</strong></div><button id="ai-example" type="button" class="text-button">填入示例</button></div>
        <label for="ai-name">评审名称</label><input id="ai-name" required maxlength="120" placeholder="例如：订单创建接口评审">
        <label for="ai-design">设计材料 <span id="ai-count">0 / 8000</span></label><textarea id="ai-design" required minlength="10" maxlength="8000" placeholder="粘贴需求、实现方案和约束。写清楚状态变化、失败处理、已有验证和仍不确定的地方。"></textarea>
        <div class="ai-section-heading"><div><span class="ai-step">02</span><strong>选择检查范围</strong></div><span id="ai-selected-count" class="ai-small"></span></div>
        <div id="ai-selected" class="ai-chips"></div><details class="ai-check-picker"><summary>调整检查项</summary><label class="sr-only" for="ai-filter">搜索检查项</label><input id="ai-filter" type="search" placeholder="输入编号或关键词，如：CON-01、幂等"><div id="ai-check-list"></div></details>
        <div class="ai-section-heading"><div><span class="ai-step">03</span><strong>选择评审方式</strong></div></div>
        <label class="sr-only" for="ai-mode">评审方式</label><select id="ai-mode"><option value="mcp">MCP · 由连接的 AI 助手评审</option><option value="scripted">离线演示 · 固定模拟结果</option></select><p id="ai-mode-note" class="ai-small">提交后，在已连接工作台 MCP 的助手中说“处理待评审设计”。</p>
        <div class="ai-submit-row"><span class="ai-small">仅发送本次设计与选中知识片段。</span><button id="ai-submit" class="primary" type="submit">提交给 AI 助手 →</button></div>
      </form><div id="ai-result" hidden></div>
    </section></div>`;
  document.body.append(modal);
  function error(message) { $('ai-error').textContent = message || ''; $('ai-error').hidden = !message; }
  async function api(path, options = {}) {
    let response;
    try { response = await fetch('/api' + path, options); }
    catch { throw new Error('未能连接本机服务。请启动服务后打开 http://127.0.0.1:8765。'); }
    const body = await response.json();
    if (!response.ok) throw new Error(typeof body.detail === 'string' ? body.detail : '输入不符合要求，请检查材料长度与字段。');
    return body;
  }
  function keyFor(body, previous) {
    const signature = JSON.stringify(body);
    return previous?.signature === signature ? previous : {signature, key:crypto.randomUUID()};
  }
  function post(path, body, key) {
    return api(path, {method:'POST', headers:{'Content-Type':'application/json','Idempotency-Key':key}, body:JSON.stringify(body)});
  }
  function updateChecks() {
    $('ai-selected-count').textContent = `${chosen.size} / 8 项`;
    $('ai-selected').innerHTML = [...chosen].map(id => `<button type="button" class="ai-chip" data-ai-remove="${esc(id)}" title="移除 ${esc(id)}">${esc(id)} <span>×</span></button>`).join('');
    const query = $('ai-filter').value.trim().toLowerCase();
    $('ai-check-list').innerHTML = catalog.filter(c => (c.id+' '+c.question).toLowerCase().includes(query)).map(c =>
      `<label class="ai-check"><input type="checkbox" data-ai-check="${esc(c.id)}" ${chosen.has(c.id)?'checked':''} ${chosen.size>=8&&!chosen.has(c.id)?'disabled':''}><span><b>${esc(c.id)}</b> ${esc(c.question)}</span></label>`).join('');
  }
  function modeNote() {
    const demo = $('ai-mode').value === 'scripted';
    $('ai-mode-note').textContent = demo ? '不调用模型。用固定模拟结果验证提交、问答、保存与导出。' : '提交后，在已连接工作台 MCP 的助手中说“处理待评审设计”。';
    $('ai-submit').textContent = demo ? '运行离线演示 →' : '提交给 AI 助手 →';
  }
  function storeDraft() {
    $('ai-count').textContent = `${$('ai-design').value.length} / 8000`;
    try { sessionStorage.setItem('swe-ai-draft', JSON.stringify({title:$('ai-name').value, design:$('ai-design').value})); } catch { /* Optional draft convenience. */ }
  }
  async function history() {
    const rows = await api('/reviews');
    $('ai-history-list').innerHTML = rows.length ? rows.map(r => `<button class="ai-history-item ${current?.id===r.id&&!showingDraft?'active':''}" data-ai-review="${esc(r.id)}"><strong>${esc(r.title)}</strong><span>${esc(labels[r.status])} <i>· ${r.mode==='scripted'?'模拟':'MCP'}</i></span><small>${new Date(r.created_at).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})}</small></button>`).join('') : '<p class="ai-empty">还没有评审记录。<br>从右侧的一份设计开始。</p>';
    return rows;
  }
  function sourceCard(c, r) {
    const s = r.sources[c.source_id];
    return `<details class="ai-citation"><summary>${esc(c.source_id)} · ${esc(s.title)}</summary><blockquote>${esc(c.quote)}</blockquote><p class="ai-small">${esc(s.path)}${s.line_start?` · L${s.line_start}–${s.line_end}`:''}</p><code class="ai-hash">SHA-256 ${esc(s.sha256)}</code>${s.doc_id?`<button type="button" data-ai-doc="${esc(s.doc_id)}" class="text-button">在工作台打开全文 ↗</button>`:''}<details><summary>查看本次来源快照</summary><pre>${esc(s.text)}</pre></details></details>`;
  }
  function display(r) {
    current = r; showingDraft = false;
    try { sessionStorage.setItem('swe-ai-view', r.id); } catch { /* History also remains on server. */ }
    $('ai-form').hidden = true; $('ai-result').hidden = false;
    const differentRecord = window.Handbook.getRecord().id !== r.input.workbench_record_id;
    let content = `<div class="ai-result-heading"><div><div class="ai-eyebrow">${r.input.mode==='scripted'?'SCRIPTED DEMO':'MCP REVIEW'} · ${esc(r.id.slice(0,8))}</div><h2>${esc(r.input.title)}</h2></div><span class="ai-status ${esc(r.status)}">${esc(labels[r.status])}</span></div>`;
    if (differentRecord) content += '<div class="ai-notice">正在查看另一份记录的评审快照，结果不会写入当前人工记录。</div>';
    if (r.input.mode==='scripted') content += '<div class="ai-notice">离线模拟 · 固定程序生成结果，未经模型评审。</div>';
    content += `<div class="ai-metrics"><div><b>${r.input.check_ids.length}</b><span>检查项</span></div><div><b>${r.accepted_outputs}</b><span>已接收输出</span></div><div><b>—</b><span>宿主 token 未知</span></div><div><b>未执行</b><span>代码与实验</span></div></div>`;
    if (r.status==='waiting_model') content += `<div class="ai-wait"><span class="ai-orbit">✧</span><h3>材料已就绪，等待助手</h3><p>在连接此 MCP 的 Codex 中发送：</p><code>评审工作台中的 ${esc(r.id)}，完成后提交结果。</code><p class="ai-small">页面会自动更新。MCP 传递材料与结果，模型由助手提供。</p></div>`;
    if (r.status==='waiting_input') content += `<form id="ai-answer-form"><h3>补充几个事实</h3><p class="ai-small">只澄清一次。不确定的内容可以直接填写“暂不确定”。</p>${r.questions.map(q=>`<label for="answer-${esc(q.id)}">${esc(q.text)}</label><textarea id="answer-${esc(q.id)}" data-ai-answer="${esc(q.id)}" required maxlength="2000"></textarea>`).join('')}<button class="primary" id="ai-answer-submit">保存回答并继续 →</button></form>`;
    if (r.error) content += `<div class="ai-notice ai-failure">${esc(r.error)}</div>`;
    if (r.report) content += `<p class="ai-summary">${esc(r.report.summary)}</p>${r.report.findings.map(f=>`<article class="ai-finding"><div class="ai-row"><h3>${esc(f.check_id)}</h3><span class="ai-verdict ${esc(f.verdict)}">${esc(verdicts[f.verdict])}</span></div><p>${esc(f.explanation)}</p><div class="ai-recommendation"><strong>下一步</strong><p>${esc(f.recommendation)}</p></div>${f.citations.map(c=>sourceCard(c,r)).join('')}</article>`).join('')}<p class="ai-small">引用片段与来源摘要已通过程序校验；是否支持结论仍需人工判断。</p>`;
    content += `<details class="ai-snapshot"><summary>设计快照与评审记录</summary><pre>${esc(r.input.design)}</pre>${r.questions.map(q=>`<p><strong>${esc(q.text)}</strong><br>${esc(r.answers[q.id]||'待回答')}</p>`).join('')}<p class="ai-small">检查项：${esc(r.input.check_ids.join('、'))}<br>知识版本：${esc(r.catalog_version)} · 评审版本：${r.revision}</p><code class="ai-hash">输入 SHA-256 ${esc(r.input_sha256)}</code></details><div class="ai-exports"><a href="/api/reviews/${r.id}/export?format=markdown" download>导出 Markdown ↗</a><a href="/api/reviews/${r.id}/export?format=json" download>导出 JSON ↗</a></div>`;
    $('ai-result').innerHTML = content;
    $('ai-answer-form')?.addEventListener('submit', answer);
  }
  async function select(id) { error(''); display(await api('/reviews/'+encodeURIComponent(id))); await history(); }
  function fresh() { showingDraft = true; current = null; lastCreate = null; lastAnswer = null; try{sessionStorage.setItem('swe-ai-view','draft');}catch{} $('ai-form').hidden = false; $('ai-result').hidden = true; error(''); history().catch(e=>error(e.message)); }
  async function create(event) {
    event.preventDefault(); if(posting) return;
    if(!chosen.size) return error('请至少选择一个检查项。');
    posting = true; $('ai-submit').disabled = true; error('');
    const body = {mode:$('ai-mode').value, workbench_record_id:window.Handbook.getRecord().id,
      title:$('ai-name').value.trim(), design:$('ai-design').value, check_ids:[...chosen]};
    lastCreate = keyFor(body,lastCreate);
    try { const r = await post('/reviews', body, lastCreate.key); display(r); await history(); }
    catch(e) { error(e.message); }
    finally { posting=false; $('ai-submit').disabled=false; }
  }
  async function answer(event) {
    event.preventDefault(); if(posting||!current) return;
    posting=true; const button=$('ai-answer-submit'); button.disabled=true; error('');
    const rid=current.id, answers=Object.create(null);
    modal.querySelectorAll('[data-ai-answer]').forEach(el=>{answers[el.dataset.aiAnswer]=el.value;});
    const body={revision:current.revision,answers};
    lastAnswer=keyFor({rid,...body},lastAnswer);
    try { const r=await post('/reviews/'+rid+'/answers',body,lastAnswer.key); if(current?.id===rid&&!showingDraft) display(r); await history(); }
    catch(e) {error(e.message);}
    finally {posting=false;button.disabled=false;}
  }
  modal.addEventListener('click', event=>{
    const button=event.target.closest('button'); if(!button) return;
    if(button.dataset.aiReview) select(button.dataset.aiReview).catch(e=>error(e.message));
    if(button.dataset.aiRemove) {chosen.delete(button.dataset.aiRemove);updateChecks();}
    if(button.dataset.aiDoc) {modal.close();window.SWEAI.openDoc(button.dataset.aiDoc);}
  });
  modal.addEventListener('change',event=>{
    const id=event.target.dataset.aiCheck;
    if(id) {if(event.target.checked&&chosen.size<8) chosen.add(id);else chosen.delete(id);updateChecks();}
  });
  $('ai-form').addEventListener('submit',create);
  $('ai-close').onclick=()=>modal.close(); $('ai-new').onclick=fresh;
  $('ai-filter').oninput=updateChecks; $('ai-mode').onchange=modeNote;
  $('ai-design').oninput=storeDraft; $('ai-name').oninput=storeDraft;
  $('ai-example').onclick=()=>{
    $('ai-name').value='订单创建接口 · 重试与恢复';
    $('ai-design').value='客户端调用 POST /orders 创建订单，以 user_id + request_id 作为幂等键，数据库建立唯一约束。\n首次请求在同一事务中写入幂等记录和订单，提交后返回 order_id。重复请求返回首次结果。\n目前幂等记录保留 24 小时；相同键但请求金额不同的情况尚未处理。\n支付服务超时后，客户端会自动重试；没有实现支付结果查询或定时对账。\n计划用重复提交、并发请求和支付超时三组测试验证，目前尚未执行。';
    chosen=new Set(['CON-01','FAIL-01'].filter(id=>catalog.some(c=>c.id===id))); updateChecks();storeDraft();
  };
  $('ai-review-launch').onclick=async()=>{
    modal.showModal();
    try {
      if(!catalog.length){const data=await api('/catalog');catalog=data.checks;const scope=window.Handbook.getRecord().scope;chosen=new Set(scope.filter(id=>catalog.some(c=>c.id===id)).slice(0,8));updateChecks();}
      const rows=await history();
      if(!restored){restored=true;let last;try{last=sessionStorage.getItem('swe-ai-view');}catch{} if(last&&last!=='draft'&&rows.some(r=>r.id===last)) await select(last);}
    }catch(e){error(e.message);}
  };
  try {const draft=JSON.parse(sessionStorage.getItem('swe-ai-draft')||'null');if(draft){$('ai-name').value=draft.title;$('ai-design').value=draft.design;}}catch{}
  storeDraft();modeNote();
  setInterval(async()=>{
    if(!modal.open||showingDraft||!current||polling||posting||!['waiting_model','waiting_input','running'].includes(current.status)) return;
    polling=true;const id=current.id;
    try {const r=await api('/reviews/'+id);if(current?.id===id&&!showingDraft&&r.revision!==current.revision){display(r);await history();}}
    catch(e){error(e.message);}finally{polling=false;}
  },2500);
  if(new URLSearchParams(location.search).has('ai')) $('ai-review-launch').click();
})();
