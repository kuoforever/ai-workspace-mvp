(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const labels = {waiting_model:'等待助手评审', waiting_input:'等待补充', completed:'已完成', running:'保存中', failed:'失败', interrupted:'已中断'};
  const verdicts = {supported:'有材料支持', risk:'存在风险', unknown:'信息不足', not_applicable:'不适用'};
  let catalog = [], chosen = new Set(), current = null, showingDraft = true, posting = false, polling = false;
  let restored = false, viewEpoch = 0, targetId = null, historyEpoch = 0, checksReady = false;
  let pendingCommand = null, startupError = null, savedDraft = null;
  let draftRecordId = window.Handbook.getRecord().id, answerDrafts = Object.create(null);
  const snapshots = new Map();
  const modal = document.createElement('dialog');
  modal.id = 'ai-review-dialog'; modal.dataset.aiAddon = ''; modal.setAttribute('aria-labelledby', 'ai-title');
  modal.innerHTML = `
    <header class="ai-header"><div><div class="ai-eyebrow">AI WORKSPACE <span>/</span> SWE</div><h2 id="ai-title">从设计到有依据的评审</h2><p>选择检查范围，让助手审阅，保留每一次判断的来源。</p></div><button id="ai-close" aria-label="关闭 AI 评审">关闭</button></header>
    <div class="ai-layout"><aside class="ai-history"><div class="ai-row"><strong>评审记录</strong><button id="ai-new" class="text-button">＋ 新建</button></div><p class="ai-small">保存在本机，刷新后可继续。</p><div id="ai-history-list"></div><div class="ai-history-note">人工检查仍由你确认。<br>AI 记录单独保存与导出。</div></aside>
    <section class="ai-content"><div id="ai-error" role="alert" hidden></div><div id="ai-pending" class="ai-notice" hidden><p>上次提交结果尚未确认。输入已保留，重试会沿用原提交。</p><button id="ai-retry" type="button">重试原提交</button></div><div id="ai-state" class="sr-only" role="status" aria-live="polite"></div>
      <form id="ai-form"><div class="ai-section-heading"><div><span class="ai-step">01</span><strong>描述你的设计</strong></div><button id="ai-example" type="button" class="text-button">填入示例</button></div>
        <label for="ai-name">评审名称</label><input id="ai-name" required placeholder="例如：订单创建接口评审">
        <label for="ai-design">设计材料 <span id="ai-count">0 / 8000</span></label><textarea id="ai-design" required aria-describedby="ai-count" placeholder="粘贴需求、实现方案和约束。写清楚状态变化、失败处理、已有验证和仍不确定的地方。"></textarea><p id="ai-draft-record" class="ai-small" hidden>这份草稿来自另一份人工记录；提交仍会沿用原关联。</p>
        <div class="ai-section-heading"><div><span class="ai-step">02</span><strong>选择检查范围</strong></div><span id="ai-selected-count" class="ai-small"></span></div>
        <div id="ai-selected" class="ai-chips"></div><details class="ai-check-picker"><summary>调整检查项</summary><label class="sr-only" for="ai-filter">搜索检查项</label><input id="ai-filter" type="search" placeholder="输入编号或关键词，如：CON-01、幂等"><div id="ai-check-list"></div></details>
        <div class="ai-section-heading"><div><span class="ai-step">03</span><strong>选择评审方式</strong></div></div>
        <label class="sr-only" for="ai-mode">评审方式</label><select id="ai-mode"><option value="mcp">MCP · 由连接的 AI 助手评审</option><option value="scripted">离线演示 · 固定模拟结果</option></select><p id="ai-mode-note" class="ai-small">提交后，在已连接工作台 MCP 的助手中说“处理待评审设计”。</p>
        <div class="ai-submit-row"><span class="ai-small">仅发送本次设计与选中知识片段。</span><button id="ai-submit" class="primary" type="submit">提交给 AI 助手 →</button></div>
      </form><div id="ai-result" hidden></div>
    </section></div>`;
  document.body.append(modal);
  function error(message) { $('ai-error').textContent = message || ''; $('ai-error').hidden = !message; }
  const scalarCount = value => [...value].length;
  function readStored(name) { return JSON.parse(sessionStorage.getItem(name) || 'null'); }
  function persist(name, value) {
    try { sessionStorage.setItem(name, JSON.stringify(value)); }
    catch { throw new Error('本页输入未能保存。请检查浏览器存储后重试；尚未发送新的提交。'); }
  }
  function clearCommand() {
    try { sessionStorage.removeItem('swe-ai-command'); }
    catch { throw new Error('原提交的确认记录未能保存，请重试原提交。'); }
    pendingCommand = null;
  }
  function editable() { return !posting && !pendingCommand && !startupError; }
  function controls() {
    const locked = !editable();
    ['ai-name','ai-design','ai-mode','ai-example','ai-submit'].forEach(id => { $(id).disabled = locked; });
    modal.querySelectorAll('[data-ai-answer],#ai-answer-submit,[data-ai-remove]').forEach(el => { el.disabled = locked; });
    modal.querySelectorAll('[data-ai-check]').forEach(el => { el.disabled = locked || (chosen.size >= 8 && !chosen.has(el.dataset.aiCheck)); });
    $('ai-pending').hidden = !pendingCommand;
    $('ai-retry').disabled = posting || !!startupError;
  }
  function validateSnapshot(r) {
    const object = value => value && typeof value === 'object' && !Array.isArray(value);
    if (!object(r) || typeof r.id !== 'string' || !r.id || !Number.isInteger(r.revision) || r.revision < 1 ||
        !Object.hasOwn(labels, r.status) || !object(r.input) || typeof r.input.title !== 'string' ||
        typeof r.input.design !== 'string' || !Array.isArray(r.input.check_ids) ||
        !r.input.check_ids.every(id => typeof id === 'string') || !['mcp','scripted'].includes(r.input.mode) ||
        !object(r.sources) || !object(r.answers) || !Array.isArray(r.questions) ||
        !r.questions.every(q => object(q) && typeof q.id === 'string' && typeof q.text === 'string') ||
        (r.report != null && (!object(r.report) || typeof r.report.summary !== 'string' || !Array.isArray(r.report.findings)))) {
      throw new Error('评审响应不完整，已保留原输入和提交，请刷新或重试。');
    }
    return r;
  }
  function remember(r) {
    validateSnapshot(r);
    const previous = snapshots.get(r.id);
    if (!previous || r.revision > previous.revision) snapshots.set(r.id, r);
    return snapshots.get(r.id);
  }
  async function api(path, options = {}) {
    const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
    try {
      let response;
      try { response = await fetch('/api' + path, {...options, signal:controller.signal}); }
      catch { throw new Error('未能取得工作台响应。请检查本机服务；未确认的提交可用原请求重试。'); }
      let body;
      try { body = await response.json(); } catch { body = null; }
      if (!response.ok) {
        const failure = new Error(typeof body?.detail === 'string' ? body.detail : `工作台返回 HTTP ${response.status}，输入已保留。`);
        failure.status = response.status;
        throw failure;
      }
      if (body === null) throw new Error('工作台响应不完整，输入与原提交已保留。');
      return body;
    } finally { clearTimeout(timeout); }
  }
  function updateChecks() {
    $('ai-selected-count').textContent = `${chosen.size} / 8 项`;
    $('ai-selected').innerHTML = [...chosen].map(id => `<button type="button" class="ai-chip" data-ai-remove="${esc(id)}" aria-label="移除 ${esc(id)}">${esc(id)} <span>×</span></button>`).join('');
    const query = $('ai-filter').value.trim().toLowerCase();
    $('ai-check-list').innerHTML = catalog.filter(c => (c.id+' '+c.question).toLowerCase().includes(query)).map(c =>
      `<label class="ai-check"><input type="checkbox" data-ai-check="${esc(c.id)}" ${chosen.has(c.id)?'checked':''} ${chosen.size>=8&&!chosen.has(c.id)?'disabled':''}><span><b>${esc(c.id)}</b> ${esc(c.question)}</span></label>`).join('');
    controls();
  }
  function modeNote() {
    const demo = $('ai-mode').value === 'scripted';
    $('ai-mode-note').textContent = demo ? '不调用模型。用固定模拟结果验证提交、问答、保存与导出。' : '提交后，在已连接工作台 MCP 的助手中说“处理待评审设计”。';
    $('ai-submit').textContent = demo ? '运行离线演示 →' : '提交给 AI 助手 →';
  }
  function storeDraft() {
    $('ai-count').textContent = `${scalarCount($('ai-design').value)} / 8000`;
    $('ai-draft-record').hidden = draftRecordId === window.Handbook.getRecord().id;
    if (checksReady && !startupError) persist('swe-ai-draft', {version:1, title:$('ai-name').value,
      design:$('ai-design').value, check_ids:[...chosen], mode:$('ai-mode').value, workbench_record_id:draftRecordId});
  }
  function storeAnswers() { persist('swe-ai-answers', {version:1, reviews:answerDrafts}); }
  function saveEdit(work) { try { work(); } catch(e) { error(e.message); } }
  function active(epoch, id) { return epoch === viewEpoch && targetId === id && !showingDraft; }
  function markActive() {
    modal.querySelectorAll('[data-ai-review]').forEach(el => el.classList.toggle('active', !showingDraft && el.dataset.aiReview === targetId));
  }
  async function history() {
    const epoch = ++historyEpoch;
    const rows = await api('/reviews');
    if (epoch !== historyEpoch) return rows;
    $('ai-history-list').innerHTML = rows.length ? rows.map(row => {
      const latest = snapshots.get(row.id), r = latest ? {...row, status:latest.status, title:latest.input.title, mode:latest.input.mode} : row;
      return `<button class="ai-history-item" data-ai-review="${esc(r.id)}"><strong>${esc(r.title)}</strong><span>${esc(labels[r.status] || r.status)} <i>· ${r.mode==='scripted'?'模拟':'MCP'}</i></span><small>${new Date(r.created_at).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'})}</small></button>`;
    }).join('') : '<p class="ai-empty">还没有评审记录。<br>从右侧的一份设计开始。</p>';
    markActive();
    return rows;
  }
  function sourceCard(c, r) {
    const s = r.sources[c?.source_id];
    if (!s || !['title','text','path','sha256'].every(key => typeof s[key] === 'string')) {
      return `<details class="ai-citation"><summary>${esc(c?.source_id)} · 来源快照缺失</summary><blockquote>${esc(c?.quote)}</blockquote><p class="ai-small">这条引用暂时无法核对，请刷新或查看导出记录。其他结论仍可阅读。</p></details>`;
    }
    return `<details class="ai-citation"><summary>${esc(c.source_id)} · ${esc(s.title)}</summary><blockquote>${esc(c.quote)}</blockquote><p class="ai-small">${esc(s.path)}${s.line_start?` · L${esc(s.line_start)}–${esc(s.line_end)}`:''}</p><code class="ai-hash">SHA-256 ${esc(s.sha256)}</code>${s.doc_id?`<button type="button" data-ai-doc="${esc(s.doc_id)}" class="text-button">在工作台打开全文 ↗</button>`:''}<details><summary>查看本次来源快照</summary><pre>${esc(s.text)}</pre></details></details>`;
  }
  function findingCard(f, r) {
    try {
      if (!f || !['check_id','explanation','recommendation','verdict'].every(key => typeof f[key] === 'string') || !Array.isArray(f.citations)) throw new Error();
      return `<article class="ai-finding"><div class="ai-row"><h3>${esc(f.check_id)}</h3><span class="ai-verdict ${esc(f.verdict)}">${esc(verdicts[f.verdict] || '未知结论')}</span></div><p>${esc(f.explanation)}</p><div class="ai-recommendation"><strong>下一步</strong><p>${esc(f.recommendation)}</p></div>${f.citations.map(c=>sourceCard(c,r)).join('')}</article>`;
    } catch { return '<article class="ai-finding"><p>这条结论暂时无法显示，请刷新或查看导出记录。其他结论仍可阅读。</p></article>'; }
  }
  function display(r) {
    r = remember(r);
    if (current?.id === r.id && current.revision === r.revision && !showingDraft) return;
    const focused = document.activeElement, answerId = current?.id === r.id ? focused?.dataset.aiAnswer : null;
    const selection = answerId ? [focused.selectionStart, focused.selectionEnd] : null;
    const scroll = modal.querySelector('.ai-content').scrollTop;
    const differentRecord = window.Handbook.getRecord().id !== r.input.workbench_record_id;
    let content = `<div class="ai-result-heading"><div><div class="ai-eyebrow">${r.input.mode==='scripted'?'SCRIPTED DEMO':'MCP REVIEW'} · ${esc(r.id.slice(0,8))}</div><h2 tabindex="-1">${esc(r.input.title)}</h2></div><span class="ai-status ${esc(r.status)}">${esc(labels[r.status])}</span></div>`;
    if (differentRecord) content += '<div class="ai-notice">正在查看另一份记录的评审快照，结果不会写入当前人工记录。</div>';
    if (r.input.mode==='scripted') content += '<div class="ai-notice">离线模拟 · 固定程序生成结果，未经模型评审。</div>';
    content += `<div class="ai-metrics"><div><b>${r.input.check_ids.length}</b><span>检查项</span></div><div><b>${esc(r.accepted_outputs)}</b><span>已接收输出</span></div><div><b>—</b><span>宿主 token 未知</span></div><div><b>未执行</b><span>代码与实验</span></div></div>`;
    if (r.status==='waiting_model') content += `<div class="ai-wait"><span class="ai-orbit">✧</span><h3>材料已就绪，等待助手</h3><p>在连接此 MCP 的 Codex 中发送：</p><code>评审工作台中的 ${esc(r.id)}，完成后提交结果。</code><p class="ai-small">页面会自动更新。MCP 传递材料与结果，模型由助手提供。</p></div>`;
    if (r.status==='waiting_input') content += `<form id="ai-answer-form"><h3>补充几个事实</h3><p class="ai-small">只澄清一次，每项最多 2000 字符。不确定的内容可以直接填写“暂不确定”。</p>${r.questions.map(q=>`<label for="answer-${esc(q.id)}">${esc(q.text)}</label><textarea id="answer-${esc(q.id)}" data-ai-answer="${esc(q.id)}" required>${esc(answerDrafts[r.id]?.[q.id] ?? '')}</textarea>`).join('')}<button class="primary" id="ai-answer-submit">保存回答并继续 →</button></form>`;
    if (r.error) content += `<div class="ai-notice ai-failure">${esc(r.error)}</div>`;
    if (r.report) content += `<p class="ai-summary">${esc(r.report.summary)}</p>${r.report.findings.map(f=>findingCard(f,r)).join('')}<p class="ai-small">引用片段与来源摘要已通过程序校验；是否支持结论仍需人工判断。</p>`;
    content += `<details class="ai-snapshot"><summary>设计快照与评审记录</summary><pre>${esc(r.input.design)}</pre>${r.questions.map(q=>`<p><strong>${esc(q.text)}</strong><br>${esc(r.answers[q.id]||'待回答')}</p>`).join('')}<p class="ai-small">检查项：${esc(r.input.check_ids.join('、'))}<br>知识版本：${esc(r.catalog_version)} · 评审版本：${r.revision}</p><code class="ai-hash">输入 SHA-256 ${esc(r.input_sha256)}</code></details><div class="ai-exports"><a href="/api/reviews/${encodeURIComponent(r.id)}/export?format=markdown" download>导出 Markdown ↗</a><a href="/api/reviews/${encodeURIComponent(r.id)}/export?format=json" download>导出 JSON ↗</a></div>`;
    $('ai-result').innerHTML = content;
    current = r; targetId = r.id; showingDraft = false;
    try { sessionStorage.setItem('swe-ai-view', r.id); } catch { /* The server retains the accepted review. */ }
    $('ai-form').hidden = true; $('ai-result').hidden = false;
    $('ai-answer-form')?.addEventListener('submit', answer);
    controls(); markActive();
    $('ai-state').textContent = `${r.input.title}：${labels[r.status]}`;
    if (answerId) {
      const next = [...modal.querySelectorAll('[data-ai-answer]')].find(el => el.dataset.aiAnswer === answerId);
      if (next) { next.focus({preventScroll:true}); next.setSelectionRange(...selection); }
      else modal.querySelector('.ai-result-heading h2').focus({preventScroll:true});
      modal.querySelector('.ai-content').scrollTop = scroll;
    }
  }
  async function select(id) {
    const epoch = ++viewEpoch;
    targetId = id; current = null; showingDraft = false; error(startupError);
    $('ai-form').hidden = true; $('ai-result').hidden = false;
    $('ai-result').innerHTML = '<p role="status">正在读取评审…</p>'; markActive();
    try {
      const r = await api('/reviews/'+encodeURIComponent(id));
      if (!active(epoch,id)) return;
      if (r?.id !== id) throw new Error('响应中的评审与所选记录不一致，请刷新核对。');
      display(r); await history();
    } catch(e) { if (active(epoch,id)) error(e.message); }
  }
  function fresh() {
    ++viewEpoch; targetId = null; showingDraft = true; current = null;
    try { sessionStorage.setItem('swe-ai-view','draft'); } catch {}
    $('ai-form').hidden = false; $('ai-result').hidden = true; error(startupError); controls(); markActive();
    history().catch(e=>error(e.message));
  }
  async function send(command) {
    if (posting || startupError) return;
    const epoch = viewEpoch, origin = targetId;
    posting = true; error(''); controls();
    try {
      persist('swe-ai-command', command); pendingCommand = command; controls();
      const r = validateSnapshot(await api(command.path, {method:'POST', headers:{'Content-Type':'application/json',
        'Idempotency-Key':command.key}, body:JSON.stringify(command.body)}));
      if (command.kind === 'answer' && (r.id !== command.reviewId || r.revision < command.body.revision)) throw new Error('回答响应与原评审不一致，原提交已保留。');
      if (command.kind === 'create' && ['title','design','mode','workbench_record_id'].some(key => r.input[key] !== command.body[key])) throw new Error('创建响应与原设计不一致，原提交已保留。');
      remember(r);
      persist('swe-ai-receipt', {key:command.key, id:r.id, revision:r.revision});
      if (command.kind === 'answer') {
        const next = {...answerDrafts}; delete next[command.reviewId];
        persist('swe-ai-answers', {version:1, reviews:next});
        answerDrafts = Object.assign(Object.create(null), next);
      }
      clearCommand();
      if (epoch === viewEpoch && targetId === origin) display(r);
      history().catch(e=>{ if (epoch === viewEpoch) error(e.message); });
    } catch(e) {
      if (e.status >= 400 && e.status < 500) {
        try { clearCommand(); } catch(storageFailure) { e = storageFailure; }
      }
      if (epoch === viewEpoch) error(e.message);
    } finally { posting = false; controls(); }
  }
  async function create(event) {
    event.preventDefault(); if(!editable()) return;
    if(!chosen.size) return error('请至少选择一个检查项。');
    if (!checksReady || [...chosen].some(id=>!catalog.some(c=>c.id===id))) return error('保存的检查项已不可用，请调整范围后再提交。');
    if (scalarCount($('ai-name').value.trim()) < 1 || scalarCount($('ai-name').value.trim()) > 120 ||
        scalarCount($('ai-design').value) < 10 || scalarCount($('ai-design').value) > 8000) return error('请填写 1–120 字符的名称和 10–8000 字符的设计。');
    try { storeDraft(); } catch(e) { return error(e.message); }
    const body = {mode:$('ai-mode').value, workbench_record_id:draftRecordId,
      title:$('ai-name').value.trim(), design:$('ai-design').value, check_ids:[...chosen]};
    await send({version:1, key:crypto.randomUUID(), path:'/reviews', body, kind:'create'});
  }
  async function answer(event) {
    event.preventDefault(); if(!editable()||!current) return;
    const rid=current.id, answers=Object.create(null);
    modal.querySelectorAll('[data-ai-answer]').forEach(el=>{answers[el.dataset.aiAnswer]=el.value;});
    const body={revision:current.revision,answers};
    if (!Object.keys(answers).length || Object.values(answers).some(value=>!value.trim() || scalarCount(value)>2000)) return error('请回答每个问题，每项最多 2000 字符。');
    answerDrafts[rid] = answers;
    try { storeAnswers(); } catch(e) { return error(e.message); }
    await send({version:1, key:crypto.randomUUID(), path:'/reviews/'+encodeURIComponent(rid)+'/answers',
      body, kind:'answer', reviewId:rid});
  }
  modal.addEventListener('click', event=>{
    const button=event.target.closest('button'); if(!button) return;
    if(button.dataset.aiReview) select(button.dataset.aiReview).catch(e=>error(e.message));
    if(button.dataset.aiRemove && editable()) {chosen.delete(button.dataset.aiRemove);updateChecks();saveEdit(storeDraft);}
    if(button.dataset.aiDoc) {modal.close();window.SWEAI.openDoc(button.dataset.aiDoc);}
  });
  modal.addEventListener('change',event=>{
    const id=event.target.dataset.aiCheck;
    if(id && editable()) {if(event.target.checked&&chosen.size<8) chosen.add(id);else chosen.delete(id);updateChecks();saveEdit(storeDraft);}
  });
  modal.addEventListener('input',event=>{
    const id = event.target.dataset.aiAnswer;
    if (id && current && editable()) {
      answerDrafts[current.id] = {...answerDrafts[current.id], [id]:event.target.value};
      saveEdit(storeAnswers);
    }
  });
  $('ai-form').addEventListener('submit',create);
  $('ai-close').onclick=()=>modal.close(); $('ai-new').onclick=fresh;
  $('ai-retry').onclick=()=>{ if(pendingCommand) send(pendingCommand); };
  $('ai-filter').oninput=updateChecks; $('ai-mode').onchange=()=>{modeNote();saveEdit(storeDraft);};
  $('ai-design').oninput=()=>saveEdit(storeDraft); $('ai-name').oninput=()=>saveEdit(storeDraft);
  $('ai-example').onclick=()=>{
    if (!editable()) return;
    $('ai-name').value='订单创建接口 · 重试与恢复';
    $('ai-design').value='客户端调用 POST /orders 创建订单，以 user_id + request_id 作为幂等键，数据库建立唯一约束。\n首次请求在同一事务中写入幂等记录和订单，提交后返回 order_id。重复请求返回首次结果。\n目前幂等记录保留 24 小时；相同键但请求金额不同的情况尚未处理。\n支付服务超时后，客户端会自动重试；没有实现支付结果查询或定时对账。\n计划用重复提交、并发请求和支付超时三组测试验证，目前尚未执行。';
    chosen=new Set(['CON-01','FAIL-01'].filter(id=>catalog.some(c=>c.id===id))); updateChecks();saveEdit(storeDraft);
  };
  $('ai-review-launch').onclick=async()=>{
    if(!modal.open) modal.showModal();
    const epoch = viewEpoch, shouldRestore = !restored; restored = true;
    try {
      if(!checksReady){const data=await api('/catalog');catalog=data.checks;const scope=savedDraft?.check_ids ?? window.Handbook.getRecord().scope;chosen=new Set(scope.slice(0,8));checksReady=true;updateChecks();saveEdit(storeDraft);}
      const rows=await history();
      if(shouldRestore && epoch===viewEpoch){let last;try{last=sessionStorage.getItem('swe-ai-view');}catch{} if(last&&last!=='draft'&&rows.some(r=>r.id===last)) await select(last);}
    }catch(e){error(e.message);}
  };
  try {
    pendingCommand = readStored('swe-ai-command');
    if (pendingCommand && (pendingCommand.version!==1 || typeof pendingCommand.key!=='string' || !pendingCommand.key ||
        !pendingCommand.body || (pendingCommand.kind==='create' ? pendingCommand.path!=='/reviews' :
          pendingCommand.kind!=='answer' || !pendingCommand.reviewId || pendingCommand.path!=='/reviews/'+encodeURIComponent(pendingCommand.reviewId)+'/answers'))) throw new Error();
    savedDraft = readStored('swe-ai-draft');
    if (savedDraft) {
      if (typeof savedDraft.title!=='string' || typeof savedDraft.design!=='string' ||
          (savedDraft.check_ids!=null && (!Array.isArray(savedDraft.check_ids) || !savedDraft.check_ids.every(id=>typeof id==='string'))) ||
          (savedDraft.mode!=null && !['mcp','scripted'].includes(savedDraft.mode))) throw new Error();
      $('ai-name').value=savedDraft.title; $('ai-design').value=savedDraft.design;
      if(savedDraft.mode) $('ai-mode').value=savedDraft.mode;
      if(typeof savedDraft.workbench_record_id==='string') draftRecordId=savedDraft.workbench_record_id;
    }
    const answers = readStored('swe-ai-answers');
    if (answers) {
      if (answers.version!==1 || !answers.reviews || typeof answers.reviews!=='object' || Array.isArray(answers.reviews) ||
          Object.values(answers.reviews).some(values=>!values || typeof values!=='object' || Array.isArray(values) || Object.values(values).some(value=>typeof value!=='string'))) throw new Error();
      answerDrafts = Object.assign(Object.create(null), answers.reviews);
    }
  } catch { startupError = '本页保存记录无法读取，新的提交已暂停。请保留浏览器数据后排查，避免重复提交。'; error(startupError); }
  storeDraft();modeNote();controls();
  setInterval(async()=>{
    if(!modal.open||showingDraft||!current||polling||posting||!['waiting_model','waiting_input','running'].includes(current.status)) return;
    polling=true;const id=current.id, epoch=viewEpoch;
    try {const r=await api('/reviews/'+encodeURIComponent(id));if(active(epoch,id)){if(r?.id!==id) throw new Error('响应中的评审与所选记录不一致，请刷新核对。');validateSnapshot(r);if(r.revision>current.revision){display(r);await history();}}}
    catch(e){if(active(epoch,id)) error(e.message);}finally{polling=false;}
  },2500);
  if(new URLSearchParams(location.search).has('ai')) $('ai-review-launch').click();
})();
