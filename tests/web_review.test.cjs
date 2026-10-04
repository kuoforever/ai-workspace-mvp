const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {randomUUID} = require('node:crypto');
const {JSDOM} = require('jsdom');

const script = readFileSync(require('node:path').join(__dirname, '../static/ai-review-ui.js'), 'utf8');
const checks = ['CON-01', 'FAIL-01', 'BIZ-01'].map(id => ({id, question: id}));
const clone = value => JSON.parse(JSON.stringify(value));
const response = (body, status = 200) => ({ok: status < 400, status, json: async () => clone(body)});
const gate = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return {promise, resolve}; };
const flush = async () => { for (let i = 0; i < 3; i++) await new Promise(done => setImmediate(done)); };
function snapshot(id, revision = 1, status = 'waiting_model') {
  return {id, revision, status, input: {title: id, design: 'Query payment status before retrying.',
    check_ids: ['CON-01'], mode: 'mcp', workbench_record_id: 'manual-one'},
  sources: {input: {title: 'Design', text: 'payment status', path: 'input.txt', sha256: 'digest'}},
  questions: status === 'waiting_input' ? [{id: 'q1', text: 'How are timeouts handled?'}] : [],
  answers: {}, accepted_outputs: 0, input_sha256: 'input-digest', catalog_version: 'test', report: null};
}
function browser(t, {seed = {}, reviews = [snapshot('A'), snapshot('B')], intercept, recordID = 'manual-one'} = {}) {
  const dom = new JSDOM('<button id="ai-review-launch">AI</button>', {
    url: 'http://127.0.0.1:18765/', runScripts: 'outside-only', pretendToBeVisual: true,
  });
  t.after(() => dom.window.close());
  const window = dom.window, document = window.document, calls = [];
  const db = new Map(reviews.map(r => [r.id, clone(r)])), keys = new Map();
  let poll;
  window.setInterval = callback => { poll = callback; return 1; };
  window.Handbook = {getRecord: () => ({id: recordID, scope: checks.map(c => c.id)})};
  window.SWEAI = {openDoc() {}};
  window.HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  window.HTMLDialogElement.prototype.close = function () { this.open = false; };
  Object.defineProperty(window.crypto, 'randomUUID', {value: randomUUID});
  Object.entries(seed).forEach(([key, value]) => window.sessionStorage.setItem(key, value));
  window.fetch = async (url, options = {}) => {
    const path = String(url).replace(/^\/api/, ''), body = options.body && JSON.parse(options.body);
    const call = {path, body, key: options.headers?.['Idempotency-Key']}; calls.push(call);
    if (intercept) {
      const value = await intercept(call, {db, keys});
      if (value !== undefined) return value;
    }
    if (path === '/catalog') return response({checks});
    if (!body && path === '/reviews') return response([...db.values()].map(r => ({id: r.id,
      title: r.input.title, mode: r.input.mode, status: r.status, created_at: '2026-10-04T00:00:00Z'})));
    if (!body) return response(db.get(path.split('/')[2]));
    if (keys.has(call.key)) return response(db.get(keys.get(call.key)));
    const id = path === '/reviews' ? 'created-' + keys.size : path.split('/')[2];
    const r = path === '/reviews' ? {...snapshot(id), input: body} : {
      ...db.get(id), revision: db.get(id).revision + 1, status: 'completed', answers: body.answers,
    };
    db.set(id, r); keys.set(call.key, id); return response(r);
  };
  window.eval(script);
  const $ = id => document.getElementById(id);
  return {window, document, $, calls, db, poll: () => poll(),
    launch: async () => { $('ai-review-launch').click(); await flush(); },
    select: async id => { document.querySelector(`[data-ai-review="${id}"]`).click(); await flush(); },
    input: (id, value) => { $(id).value = value; $(id).dispatchEvent(new window.Event('input', {bubbles: true})); },
    submit: async id => { $(id).dispatchEvent(new window.Event('submit', {bubbles: true, cancelable: true})); await flush(); },
    seed: () => Object.fromEntries(Object.keys(window.sessionStorage).map(key => [key, window.sessionStorage.getItem(key)])),
    title: () => document.querySelector('.ai-result-heading h2')?.textContent,
  };
}
function fill(b) { b.input('ai-name', 'Orders'); b.input('ai-design', 'Query payment status before retrying.'); }

test('late A cannot override the later selection B', async t => {
  const hold = gate();
  const b = browser(t, {intercept: call => call.path === '/reviews/A' ? hold.promise : undefined});
  await b.launch(); await b.select('A'); await b.select('B'); assert.equal(b.title(), 'B');
  hold.resolve(response(snapshot('A'))); await flush(); assert.equal(b.title(), 'B');
});
test('late selection cannot replace the new draft', async t => {
  const hold = gate(); const b = browser(t, {intercept: call => call.path === '/reviews/A' ? hold.promise : undefined});
  await b.launch(); await b.select('A'); b.$('ai-new').click();
  hold.resolve(response(snapshot('A'))); await flush(); assert.equal(b.$('ai-form').hidden, false);
});
test('a late create response cannot replace a selected existing review', async t => {
  const hold = gate(); let submitted;
  const b = browser(t, {intercept: call => { if (call.body) { submitted = call.body; return hold.promise; } }});
  await b.launch(); fill(b); await b.submit('ai-form'); await b.select('B');
  hold.resolve(response({...snapshot('created'), input: submitted})); await flush();
  assert.equal(b.title(), 'B');
  assert.equal(b.window.sessionStorage.getItem('swe-ai-command'), null);
});
test('A to B to A uses the most recent navigation even with the same ID', async t => {
  const hold = gate(); let reads = 0;
  const b = browser(t, {intercept: call => {
    if (call.path === '/reviews/A') return ++reads === 1 ? hold.promise : response(snapshot('A', 2, 'completed'));
  }});
  await b.launch(); await b.select('A'); await b.select('B'); await b.select('A');
  hold.resolve(response(snapshot('A', 1))); await flush();
  assert.equal(b.document.querySelector('.ai-status').textContent, '已完成');
  assert.match(b.$('ai-result').textContent, /评审版本：2/);
});
test('a late poll cannot roll back a completed answer', async t => {
  const hold = gate(); let reads = 0;
  const b = browser(t, {reviews: [snapshot('A', 1, 'waiting_input')], intercept: call => {
    if (call.path === '/reviews/A' && !call.body && ++reads === 2) return hold.promise;
  }});
  await b.launch(); await b.select('A'); const polling = b.poll(); await flush();
  b.input('answer-q1', 'Query the payment status.'); await b.submit('ai-answer-form');
  assert.equal(b.document.querySelector('.ai-status').textContent, '已完成');
  hold.resolve(response(snapshot('A', 1, 'waiting_input'))); await polling; await flush();
  assert.equal(b.document.querySelector('.ai-status').textContent, '已完成');
  assert.equal(b.$('ai-answer-form'), null);
});
test('answer drafts survive navigation, same-version polling and reload', async t => {
  const reviews = [snapshot('A', 1, 'waiting_input')], b = browser(t, {reviews});
  await b.launch(); await b.select('A'); b.input('answer-q1', 'My latest unsent answer.');
  b.$('answer-q1').focus(); await b.poll(); assert.equal(b.document.activeElement.id, 'answer-q1');
  b.$('ai-new').click(); await b.select('A'); assert.equal(b.$('answer-q1').value, 'My latest unsent answer.');
  const reloaded = browser(t, {reviews, seed: b.seed()}); await reloaded.launch();
  assert.equal(reloaded.$('answer-q1').value, 'My latest unsent answer.');
});
test('the complete composer and its record association survive reload', async t => {
  const b = browser(t); await b.launch(); b.$('ai-example').click();
  b.$('ai-mode').value = 'scripted'; b.$('ai-mode').dispatchEvent(new b.window.Event('change', {bubbles: true}));
  const reloaded = browser(t, {seed: b.seed(), recordID: 'manual-two'}); await reloaded.launch();
  assert.equal(reloaded.$('ai-mode').value, 'scripted');
  assert.deepEqual([...reloaded.document.querySelectorAll('[data-ai-remove]')].map(el => el.dataset.aiRemove), ['CON-01', 'FAIL-01']);
  await reloaded.submit('ai-form'); const call = reloaded.calls.find(c => c.body);
  assert.equal(call.body.workbench_record_id, 'manual-one');
});
test('an unknown create result survives reload and retries the exact original command', async t => {
  let original;
  const b = browser(t, {intercept: call => {
    if (call.body) { original = call; throw new TypeError('lost response'); }
  }});
  await b.launch(); fill(b); await b.submit('ai-form');
  const reloaded = browser(t, {seed: b.seed(), reviews: [snapshot('accepted')]}); await reloaded.launch();
  assert.equal(reloaded.$('ai-name').disabled, true);
  reloaded.$('ai-retry').click(); await flush();
  const retry = reloaded.calls.find(c => c.body);
  assert.deepEqual(retry, original);
  assert.equal(reloaded.window.sessionStorage.getItem('swe-ai-command'), null);
});
test('a confirmed 422 clears only the command and keeps editable input', async t => {
  const b = browser(t, {intercept: call => call.body ? response({detail: 'invalid input'}, 422) : undefined});
  await b.launch(); fill(b); await b.submit('ai-form');
  assert.equal(b.$('ai-name').value, 'Orders'); assert.equal(b.$('ai-name').disabled, false);
  assert.equal(b.window.sessionStorage.getItem('swe-ai-command'), null);
});
test('an unknown answer result survives reload with the original revision and answers', async t => {
  const reviews = [snapshot('A', 1, 'waiting_input')]; let original;
  const b = browser(t, {reviews, intercept: call => { if (call.body) { original = call; throw new TypeError('lost answer response'); } }});
  await b.launch(); await b.select('A'); b.input('answer-q1', 'The original answer.'); await b.submit('ai-answer-form');
  const reloaded = browser(t, {reviews, seed: b.seed()}); await reloaded.launch();
  assert.equal(reloaded.$('answer-q1').value, 'The original answer.');
  assert.equal(reloaded.$('answer-q1').disabled, true);
  reloaded.$('ai-retry').click(); await flush();
  assert.deepEqual(reloaded.calls.find(c => c.body), original);
  assert.equal(reloaded.document.querySelector('.ai-status').textContent, '已完成');
});
test('a stale saved check stays visible and prevents submission until corrected', async t => {
  const seed = {'swe-ai-draft': JSON.stringify({version:1,title:'Keep my scope',design:'Query payment status before retrying.',
    check_ids:['OLD-01'],mode:'mcp',workbench_record_id:'manual-one'})};
  const b = browser(t, {seed}); await b.launch(); await b.submit('ai-form');
  assert.equal(b.calls.filter(c => c.body).length, 0);
  assert.match(b.$('ai-selected').textContent, /OLD-01/);
  assert.match(b.$('ai-error').textContent, /不可用/);
});
test('failure to persist a command prevents its POST', async t => {
  const b = browser(t); await b.launch(); fill(b);
  const save = b.window.Storage.prototype.setItem;
  b.window.Storage.prototype.setItem = function(key, value) {
    if (key === 'swe-ai-command') throw new Error('storage full'); return save.call(this, key, value);
  };
  await b.submit('ai-form'); assert.equal(b.calls.filter(c => c.body).length, 0);
  assert.equal(b.$('ai-name').value, 'Orders'); assert.equal(b.$('ai-error').hidden, false);
});
test('a corrupt pending command blocks new writes instead of silently forgetting it', async t => {
  const b = browser(t, {seed: {'swe-ai-command': '{broken'}}); await b.launch(); fill(b);
  await b.submit('ai-form'); assert.equal(b.calls.filter(c => c.body).length, 0);
  assert.equal(b.$('ai-error').hidden, false);
  assert.equal(b.window.sessionStorage.getItem('swe-ai-command'), '{broken');
});
test('one missing citation source leaves the rest of the report readable', async t => {
  const r = snapshot('A', 3, 'completed'); r.report = {summary: 'Report remains readable', findings: [
    {check_id: 'CON-01', verdict: 'risk', explanation: 'First finding', recommendation: 'Query first',
      citations: [{source_id: 'missing', quote: 'payment status'}]},
    {check_id: 'FAIL-01', verdict: 'supported', explanation: 'Second finding', recommendation: 'Keep checking',
      citations: [{source_id: 'input', quote: 'payment status'}]},
  ]};
  const b = browser(t, {reviews: [r]}); await b.launch(); await b.select('A');
  assert.equal(b.title(), 'A'); assert.match(b.$('ai-result').textContent, /Report remains readable/);
  assert.match(b.$('ai-result').textContent, /Second finding/);
  assert.match(b.$('ai-result').textContent, /来源.*缺失/);
});
