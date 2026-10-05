const {test}=require('node:test');
const assert=require('node:assert/strict');
const {readFileSync}=require('node:fs');
const {randomUUID}=require('node:crypto');
const {JSDOM}=require('jsdom');
const html=readFileSync('static/workspace.html','utf8'), script=readFileSync('static/workspace.js','utf8');
const clone=value=>JSON.parse(JSON.stringify(value));
const response=(body,status=200)=>({ok:status<400,status,json:async()=>clone(body)});
const flush=async()=>{for(let i=0;i<12;i++)await new Promise(resolve=>setImmediate(resolve));};
const gate=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};
function packageValue(){
  const value=JSON.parse(readFileSync('fixtures/event-workbench.json','utf8'));
  value.objects=value.objects.map(o=>({content:'',fields:{},state:'',parent_id:null,links:[],availability:'available',...o}));
  value.requirements=value.requirements.map(r=>({object_ids:[],priority:'must',conflicts_with:[],rule:null,...r,
    rule:r.rule?{fields:[],field:null,expected:null,state:null,...r.rule}:null}));return value;
}
function input(title='Task A') {return {mode:'mcp',title,workbench:packageValue(),task_type:'review',goal:'检查筹备计划的执行条件。',scope:['venue','speakers','budget','meeting'],deliverable:'列出问题、依据和下一步。',requirements:[]};}
function snapshot(id='A',body=input(),revision=1,status='waiting_model'){
  const requirements=Object.fromEntries(body.workbench.requirements.map(r=>['workbench:'+r.id,r]));
  for(const r of body.requirements)requirements['task:'+r.id]=r;
  requirements['task:delivery']={text:body.goal,source:'用户任务',acceptance:body.deliverable};
  const sources=Object.fromEntries(body.workbench.objects.map(o=>['object:'+o.id,{title:o.title,text:'对象：'+o.id+'\n'+o.content,path:o.source,sha256:'b'.repeat(64)}]));
  const checks=Object.fromEntries(Object.keys(requirements).map(id=>[id,{verdict:'unknown'}]));
  const r={id,input:clone(body),revision,status,requirements,sources,checks,conflicts:[],questions:[],answers:{},result:null,
    input_sha256:'a'.repeat(64),workbench_sha256:'b'.repeat(64),created_at:'2026-10-05T00:00:00Z',applied_workbench:null};
  if(status==='waiting_input')r.questions=[{id:'q1',text:'请补充负责人的信息。'}];
  if(status==='completed')r.result={summary:'完成了要求核对。',artifacts:[{id:'report',kind:body.task_type,title:'任务产物',content:'完整任务产物，可离线阅读。',citations:[{source_id:'object:venue',quote:'对象：venue'}]}],requirement_results:[],changes:[]};
  return r;
}
async function browser(t,{seed={},rows=[],intercept}={}){
  const dom=new JSDOM(html,{url:'http://127.0.0.1:18766/workspace',runScripts:'outside-only',pretendToBeVisual:true});
  t.after(()=>dom.window.close());const {window}=dom, {$}= { $:id=>window.document.getElementById(id)};
  const calls=[],db=new Map(rows.map(r=>[r.id,clone(r)])),commands=new Map();let poll;
  Object.defineProperty(window.crypto,'randomUUID',{value:randomUUID});window.setInterval=cb=>{poll=cb;return 1;};
  window.TextDecoder=TextDecoder;window.URL.createObjectURL=()=> 'blob:test';window.URL.revokeObjectURL=()=>{};
  window.HTMLAnchorElement.prototype.click=function(){};
  for(const [key,value] of Object.entries(seed))window.localStorage.setItem(key,value);
  window.fetch=async(url,options={})=>{
    const path=String(url).replace(/^\/api/,''),body=options.body&&JSON.parse(options.body);
    const call={path,body,key:options.headers?.['Idempotency-Key']};calls.push(call);
    const override=await intercept?.(call,{db,commands});if(override!==undefined)return override;
    if(path==='/config')return response({});
    if(path==='/workbenches/example')return response(packageValue());
    if(path==='/workbenches/engineering')return response({workbench:{...packageValue(),id:'engineering',title:'工程模板'},warnings:[]});
    if(path==='/workbenches/import')return response({workbench:JSON.parse(body.content),warnings:[]});
    if(path==='/tasks'&&!body)return response([...db.values()].map(r=>({id:r.id,title:r.input.title,status:r.status,task_type:r.input.task_type})));
    if(!body)return response(db.get(path.split('/')[2]));
    if(commands.has(call.key))return response(db.get(commands.get(call.key)));
    let r;
    if(path==='/tasks')r=snapshot('created-'+commands.size,body,1,body.mode==='scripted'?'completed':'waiting_model');
    else {r=clone(db.get(path.split('/')[2]));r.revision++;if(path.endsWith('/answers')){r.answers=body.answers;r.status='completed';r.result=snapshot(r.id,r.input,r.revision,'completed').result;}
      if(path.endsWith('/apply')){r.applied_workbench=clone(r.input.workbench);r.applied_workbench.revision++;for(const c of r.result.changes.filter(c=>body.change_ids.includes(c.id))){r.applied_workbench.objects.find(o=>o.id===c.object_id).fields[c.field]=c.value;}}}
    db.set(r.id,r);commands.set(call.key,r.id);return response(r);
  };
  window.eval(script);await flush();
  return {window,$,calls,db,poll:()=>poll(),
    click:async id=>{$(id).click();await flush();},
    select:async id=>{window.document.querySelector(`[data-task="${id}"]`).click();await flush();},
    fill:(id,value)=>{$(id).value=value;$(id).dispatchEvent(new window.Event('input',{bubbles:true}));},
    submit:async(id='task-form')=>{$(id).dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true}));await flush();},
    seed:()=>Object.fromEntries(Object.keys(window.localStorage).map(key=>[key,window.localStorage.getItem(key)])),
    title:()=>window.document.querySelector('.result-heading h2')?.textContent};
}

test('complete workbench, requirements, scope and task goals are submitted',async t=>{
  const b=await browser(t);await b.click('example');b.fill('task-requirements','建议按紧急程度排序。');b.fill('mode','scripted');await b.submit();
  const call=b.calls.find(c=>c.path==='/tasks'&&c.body);assert.equal(call.body.workbench.requirements.length,5);
  assert.deepEqual(call.body.scope,['venue','speakers','budget','meeting']);assert.equal(call.body.requirements.length,1);
  assert.equal(call.body.workbench.objects[1].fields.owner,'');assert.match(b.$('task-detail').textContent,/完整任务产物/);
});

test('editing object fields and requirements survives reload without leaving the field',async t=>{
  const b=await browser(t);await b.click('example');
  const el=b.window.document.querySelector('[data-object="speakers"][data-field="owner"]');el.value='陈';el.dispatchEvent(new b.window.Event('input',{bubbles:true}));
  const req=b.window.document.querySelector('[data-requirement="owners"][data-property="acceptance"]');req.value='负责人和日期都要明确记录。';req.dispatchEvent(new b.window.Event('input',{bubbles:true}));
  const reloaded=await browser(t,{seed:b.seed()});await reloaded.submit();const body=reloaded.calls.find(c=>c.path==='/tasks'&&c.body).body;
  assert.equal(body.workbench.objects[1].fields.owner,'陈');assert.equal(body.workbench.requirements[0].acceptance,'负责人和日期都要明确记录。');assert.ok(body.workbench.revision>1);
});

test('a late import choice cannot replace the newer workbench',async t=>{
  const held=gate(),b=await browser(t,{intercept:c=>c.path==='/workbenches/example'?held.promise:undefined});
  b.$('example').click();await flush();await b.click('engineering');held.resolve(response(packageValue()));await flush();
  assert.equal(b.$('workbench-title').value,'工程模板');
});

test('response loss retains the original snapshot and request across reload',async t=>{
  let original;const b=await browser(t,{intercept:c=>{if(c.path==='/tasks'&&c.body){original=c;throw new Error('lost response');}}});
  await b.click('example');await b.submit();assert.equal(b.$('submit').disabled,true);
  const reloaded=await browser(t,{seed:b.seed()});assert.equal(reloaded.$('task-title').disabled,true);await reloaded.click('retry');
  assert.deepEqual(reloaded.calls.find(c=>c.path==='/tasks'&&c.body),original);assert.equal(reloaded.window.localStorage.getItem('ai-workbench-command-v1'),null);
});

test('failure to save the original command prevents its submission',async t=>{
  const b=await browser(t);await b.click('example');const write=b.window.Storage.prototype.setItem;
  b.window.Storage.prototype.setItem=function(key,value){if(key==='ai-workbench-command-v1')throw new Error('full');return write.call(this,key,value);};
  await b.submit();assert.equal(b.calls.filter(c=>c.path==='/tasks'&&c.body).length,0);assert.equal(b.$('workbench-title').value,'社区分享会筹备');
});

test('late creation and reads preserve the current task selection',async t=>{
  const held=gate();let body;const b=await browser(t,{rows:[snapshot('A'),snapshot('B',input('Task B'))],intercept:c=>{if(c.path==='/tasks'&&c.body){body=c.body;return held.promise;}}});
  await b.click('example');await b.submit();await b.select('B');held.resolve(response(snapshot('created',body)));await flush();
  assert.equal(b.title(),'Task B');assert.equal(b.window.localStorage.getItem('ai-workbench-command-v1'),null);
});

test('late A cannot override the newer selection B',async t=>{
  const held=gate(),b=await browser(t,{rows:[snapshot('A'),snapshot('B',input('Task B'))],intercept:c=>c.path==='/tasks/A'?held.promise:undefined});
  await b.select('A');await b.select('B');held.resolve(response(snapshot('A')));await flush();assert.equal(b.title(),'Task B');
});

test('answer drafts and exact answer retries survive reload',async t=>{
  const rows=[snapshot('A',input(),1,'waiting_input')];let original;
  const b=await browser(t,{rows,intercept:c=>{if(c.path==='/tasks/A/answers'){original=c;throw new Error('lost');}}});await b.select('A');
  const el=b.window.document.querySelector('[data-answer="q1"]');el.value='负责人是陈，交付物尚未收齐。';el.dispatchEvent(new b.window.Event('input',{bubbles:true}));await b.submit('answer-form');
  const reloaded=await browser(t,{rows,seed:b.seed()});assert.equal(reloaded.window.document.querySelector('[data-answer="q1"]').value,'负责人是陈，交付物尚未收齐。');
  await reloaded.click('retry');assert.deepEqual(reloaded.calls.find(c=>c.path==='/tasks/A/answers'),original);
});

test('offline reload keeps the last report and citation snapshots readable',async t=>{
  const r=snapshot('A',input(),3,'completed');const b=await browser(t,{rows:[r]});await b.select('A');
  const reloaded=await browser(t,{seed:b.seed(),intercept:()=>{throw new Error('offline');}});
  assert.equal(reloaded.title(),'Task A');assert.match(reloaded.$('task-detail').textContent,/完整任务产物/);assert.match(reloaded.$('task-detail').textContent,/对象：venue/);
});

test('selected changes create a new snapshot without changing the original task input',async t=>{
  const r=snapshot('A',input(),3,'completed');r.result.changes=[{id:'repair',object_id:'speakers',target:'field',field:'owner',value:'陈',reason:'补充明确负责人。',citations:[{source_id:'object:speakers',quote:'对象：speakers'}]}];
  const b=await browser(t,{rows:[r]});await b.select('A');await b.click('continue-task');await b.select('A');
  b.window.document.querySelector('[data-change="repair"]').checked=true;await b.click('apply-changes');
  assert.equal(b.db.get('A').input.workbench.objects[1].fields.owner,'');assert.equal(b.db.get('A').applied_workbench.objects[1].fields.owner,'陈');
  assert.match(b.$('task-detail').textContent,/已生成新工作台版本/);
});

test('unparseable edited fields prevent submitting an older field value',async t=>{
  const b=await browser(t);await b.click('example');const el=b.window.document.querySelector('[data-object="budget"][data-field="limit"]');
  el.value='invalid number';el.dispatchEvent(new b.window.Event('input',{bubbles:true}));await b.submit();
  assert.equal(b.calls.filter(c=>c.path==='/tasks'&&c.body).length,0);assert.match(b.$('error').textContent,/无效数据/);
});

test('corrupt saved commands pause new submissions and remain recoverable',async t=>{
  const b=await browser(t,{seed:{'ai-workbench-command-v1':'{broken'}});assert.equal(b.$('submit').disabled,true);
  assert.equal(b.window.localStorage.getItem('ai-workbench-command-v1'),'{broken');assert.match(b.$('error').textContent,/无法读取/);
});

test('source content is shown as text and never interpreted as executable markup',async t=>{
  const r=snapshot('A',input(),3,'completed');r.result.artifacts[0].content='<img src=x onerror="window.injected=true">';
  const b=await browser(t,{rows:[r]});await b.select('A');assert.equal(b.$('task-detail').querySelector('img'),null);assert.equal(b.window.injected,undefined);
});
