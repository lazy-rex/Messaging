// Test the real Lua plugin against a controlled hub. This does not test SQLite or hub recovery.
import { connectControl } from '../../LazyRex/lib/rex-client.mjs';
import { labSocket, until, discoverHub } from '../../LazyRex/lab/lab.mjs';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const socket = await labSocket();
const control = await connectControl(socket), hub = await connectControl(socket);
const records = new Map(), operations = new Map(), notices = new Map();
let declaredTabs = [];
let sourceSession='session:local';
const openSessions=new Map([['session:local','Local'],['session:elsewhere','Elsewhere'],['session:other','Other']]);
const ensuredSessions=new Map();
let ensureCalls=0;
const navigated=[];
let homeRedirects = {};
let identityAliases = {};
let unnamedIdentities = false;
const rosterEntries = () => [
 ...['alice','bob','user','charlie'].map(id => ({id,name:({alice:'Alice',bob:'Bob',user:'User',charlie:'Charlie'})[id],session_id:id==='alice'?'session:local':'session:other',joined:true,...(identityAliases[id] ? {alias_of:identityAliases[id]} : {})})),
 ...Object.entries(identityAliases).map(([old,id]) => ({id,name:unnamedIdentities === 'id' ? id : unnamedIdentities === 'whitespace' ? '  ' : unnamedIdentities === 'invalid' ? {} : unnamedIdentities ? '' : old+' tab',kind:id.split(':')[0],state:'current',joined:true,aliases:[old]}))
];
let revision = 0n, actor = 'alice', pluginId, child, injection, batchCalls = 0;
const copy = value => structuredClone(value);
const part = s => `${Buffer.byteLength(s)}:${s}`;
const boxKey = name => 'mailbox/' + part(name);
const record = key => copy(records.get(key) ?? {rev:'0'});
const write = (key, value) => records.set(key, {value:copy(value), rev:String(++revision)});
function batch(args) {
  if (!Array.isArray(args.ops) && Object.keys(args.ops).length===0) args.ops=[];
  batchCalls++;
  if (injection) injection(args);
  const saved = args.op && operations.get(args.op.key);
  if (saved) return saved.fingerprint === args.op.fingerprint
    ? {op_exists:copy(saved)} : {conflict:{kind:'operation',key:args.op.key}};
  for (const op of args.ops) {
    if (op.key && op.if_rev !== undefined && op.if_rev !== record(op.key).rev) {
      return {conflict:{kind:'revision',key:op.key,rev:record(op.key).rev}};
    }
  }
  const keys=args.ops.filter(op=>op.key).map(op=>op.key);
  assert.equal(new Set(keys).size,keys.length,'batch writes each key at most once');
  const revs = {};
  for (const op of args.ops) {
    if (op.notify) {
      const prior = notices.get(op.notify.agent) ?? {rev:0};
      notices.set(op.notify.agent, {pending:op.notify.pending,rev:prior.rev + 1});
    } else {
      if (op.delete) records.delete(op.key); else write(op.key, op.value);
      revs[op.key] = record(op.key).rev;
    }
  }
  if (args.op) {
    const saved=copy(args.op);
    for (const [field,key] of Object.entries(saved.result_revs ?? {})) saved.result[field]=revs[key];
    operations.set(args.op.key,saved);
  }
  return {revs};
}
try {
  console.log('Rex', JSON.stringify(await control.call('server.version')));
  const names = ['register','identify','agents','store.get','store.scan','store.batch','store.op','agents.resolve','ui.tabs','ui.describe','session.list','session.ensure','navigate.agent'];
  await hub.call('client.keymap', {actions:names.map(name => ({name:`hub.${name}`,kind:'client',title:name}))});
  const label = `store-test-${process.pid}`;
  await hub.call('client.set_label', {label});
  const hubId = (await control.call('client.list')).clients.find(c => c.info?.label === label).client_id;
  await hub.call('client.set_label',{label:'lazyrex-hub'});
  assert.equal(await discoverHub(control),hubId);
  const duplicate=await connectControl(socket);
  try {
    await duplicate.call('client.set_label',{label:'lazyrex-hub'});
    await assert.rejects(discoverHub(control),/2 connected candidates/);
  } finally { duplicate.close(); }
  await until(async()=> {
    try {return await discoverHub(control)===hubId;} catch {return false;}
  },'lost hub candidate is excluded');

  hub.events.on('event', async frame => {
    if (frame.payload?.type !== 'client_perform_requested') return;
    const ev = frame.payload.payload;
    try {
      assert.equal(ev.requester.principal.pid, child.pid);
      let result;
      if (ev.action === 'hub.register') {
        assert.equal(ev.args.instance_id,'plugin-test');
        assert.deepEqual(ev.args.exports,process.env.BASELINE ? ['messaging.send','messaging.read','messaging.ack'] : ['messaging.send','messaging.read','messaging.ack','messaging.thread_list','messaging.thread_create','messaging.history','messaging.thread_archive']);
        assert.equal(ev.args.actions,undefined);
        pluginId = ev.requester.client_id;
        result = {namespace:'messaging',generation:'1'};
      } else {
        assert.equal(ev.requester.client_id,pluginId);
        if (ev.action === 'hub.identify') {
          assert.equal(ev.args.pid,process.pid);
          result = actor ? {found:true,agent:identityAliases[actor] || actor,block_id:`mock-${actor}`,session_id:sourceSession} : {found:false};
        } else if (ev.action === 'hub.session.list') {
          result={sessions:[...openSessions].map(([session_id,label])=>({session_id,label}))};
        } else if (ev.action === 'hub.session.ensure') {
          ensureCalls++;
          const saved=ensuredSessions.get(ev.args.key);
          if(saved && saved.name!==ev.args.name) throw Error('Session key has different content');
          if(!saved) {
            const session_id='session:new-'+ensuredSessions.size;
            ensuredSessions.set(ev.args.key,{name:ev.args.name,session_id});
            openSessions.set(session_id,ev.args.name);
          }
          result={session_id:ensuredSessions.get(ev.args.key).session_id};
        } else if (ev.action === 'hub.agents') {
          result = {agents:rosterEntries().map(a=>({...a,activity:a.joined?(a.id==='alice'?'working':'idle'):undefined}))};
        } else if (ev.action === 'hub.navigate.agent') {
          navigated.push(ev.args.agent); result={agent:ev.args.agent,status:'navigating'};
        } else if (ev.action === 'hub.agents.resolve') {
          const matches=rosterEntries().filter(a=>a.id===ev.args.to || a.name===ev.args.to);
          if(matches.length!==1) throw Error('Unknown recipient');
          result={id:identityAliases[matches[0].id] || matches[0].id};
        } else if (ev.action === 'hub.store.scan') {
          const all=[...records.entries()].filter(([key])=>(!ev.args.after || key>ev.args.after) && (!ev.args.prefix || key.startsWith(ev.args.prefix))).sort(([a],[b])=>a<b?-1:a>b?1:0);
          const page=all.slice(0,2);
          result={records:Object.fromEntries(page.map(([key,r])=>[key,copy(r)])),...(all.length>2?{next:page.at(-1)[0]}:{})};
        } else if (ev.action === 'hub.ui.describe') {
          assert.equal(ev.args.plugin,'messaging');
          result={default_session_id:'session:messages',home_redirects:homeRedirects};
        } else if (ev.action === 'hub.ui.tabs') {
          declaredTabs=copy(ev.args.tabs);result={tabs:declaredTabs.length};
        } else if (ev.action === 'hub.store.get') {
          result = {records:Object.fromEntries(ev.args.keys.map(key => [key,record(key)]))};
        } else if (ev.action === 'hub.store.op') {
          const saved = operations.get(ev.args.key);
          result = saved ? {found:true,...copy(saved)} : {found:false};
        } else if (ev.action === 'hub.store.batch') result = batch(ev.args);
        else throw new Error('Unknown hub action');
      }
      await hub.call('client.reply',{call_id:ev.call_id,result});
    } catch (error) {
      console.error('Mock hub failure:',ev.action,error);
      await hub.call('client.reply',{call_id:ev.call_id,error:{code:'internal',message:error.message}});
    }
  });
  child = spawn(process.env.REX_BIN || 'rex', ['-S',`unix://${socket}`,'--autostart=false','do',
    process.env.MESSAGING_PLUGIN || fileURLToPath(new URL('../../Messaging/messaging.lua',import.meta.url)),'--all',`hub_client_id=${hubId}`,'instance_id=plugin-test'],
    {env:{...process.env,REX_SERVER:`unix://${socket}`,REX_SESSION:'',REX_BLOCK:'',REX_CLIENT:''}});
  child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
  child.on('error', error => { throw error; });
  await until(async () => {
    if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Plugin exited ${child.exitCode}`);
    return (await control.call('client.list')).clients.some(c => c.client_id === pluginId && c.info?.label === 'lazyrex-plugin:messaging');
  }, 'plugin registration');
  const call = async (action,args={}) => (await control.call('client.perform',{
    client_id:pluginId,action:`messaging.${action}`,args,timeout_ms:10000
  })).result;
  const view = async (action,args={}) => (await hub.call('client.perform', {
    client_id:pluginId,action:`view.${action}`,args,timeout_ms:10000
  })).result;
  const send = (key,body='hello',to='bob') => call('send',{key,body,to});
  await assert.rejects(call('send',{to:'bob',body:'missing key'}),error=>error.rex?.code==='bad_request' && /key/.test(error.message));
  const metadata=await control.call('client.inspect',{client_id:pluginId});
  const sendAction=metadata.actions.find(action=>action.name==='messaging.send');
  assert.deepEqual(sendAction.args.required,['to','body','key']);
  assert.equal(sendAction.args.properties.reply_to.type,'string');
  assert.match(sendAction.description,/reply_to/);
  assert(!declaredTabs.some(t=>['thread/alice','thread/bob','thread/charlie'].includes(t.key)),'roster membership does not open empty direct tabs');
  assert(declaredTabs.some(t=>t.key==='thread/team'),'member groups keep their tabs');
  await view('open',{route:'/thread/alice',user:'user'});
  assert(declaredTabs.some(t=>t.key==='thread/alice'),'an explicit roster open declares the empty direct thread');
  const afterOpen=batchCalls;
  await view('open',{route:'/thread/alice',user:'user'});
  assert.equal(batchCalls,afterOpen,'open retries do not write again');
  await assert.rejects(view('open',{route:'/thread/charlie',user:'alice'}),/Only the user/);
  await assert.rejects(control.call('client.perform',{client_id:pluginId,action:'view.open',args:{route:'/thread/charlie',user:'user'},timeout_ms:10000}),/Only the hub/);
  actor='user';
  await call('thread_create',{key:'empty-user-direct',members:['bob']});
  assert(declaredTabs.some(t=>t.key==='thread/bob'),'New Thread declares an empty direct thread');
  await call('thread_archive',{key:'hide-empty-direct',thread:'alice'});
  await view('open',{route:'/thread/alice',user:'user'});
  assert(!declaredTabs.some(t=>t.key==='thread/alice'),'opening does not undo archive');
  await call('thread_archive',{key:'restore-empty-direct',thread:'alice',archived:false});
  assert(declaredTabs.some(t=>t.key==='thread/alice'),'restore keeps explicit open intent');
  assert(!declaredTabs.some(t=>t.key==='thread/charlie'),'unopened direct threads stay absent');
  actor='alice';
  const first = await send('a/:é','quote " slash \\ nul \0 snow 雪');
  assert.equal(first.id,'send/'+part('alice')+part('a/:é'));
  const original = record('message/'+first.id);
  const beforeReplay = batchCalls;
  assert.deepEqual(await send('a/:é','quote " slash \\ nul \0 snow 雪'),first);
  assert.equal(batchCalls,beforeReplay,'saved operation does not notify again');
  await assert.rejects(send('a/:é','different'),/different content/);
  actor='bob';
  const incoming = await call('read');
  assert.equal(incoming.messages[0].from,'alice');
  assert.deepEqual(await call('read'),incoming);
  const second = await send('a/:é','reply','alice');
  assert.notEqual(first.id,second.id,'keys are scoped by logical sender');
  await assert.rejects(call('ack',{ids:[first.id,'missing']}),/Unknown message/);
  assert.deepEqual(await call('read'),incoming,'invalid batch acknowledges nothing');
  await call('ack',{ids:[first.id,first.id]});
  const afterAck = batchCalls;
  await call('ack',{ids:[first.id]});
  await call('ack',{ids:[]});
  assert.equal(batchCalls,afterAck,'repeated and empty ack do not write');
  assert.equal(notices.get('bob').pending,false);
  actor='alice';
  await assert.rejects(call('ack',{ids:[first.id]}),/Unknown message/);
  await assert.rejects(send('bad-recipient','hello','nobody'),/Unknown recipient/);
  actor=null;
  await assert.rejects(call('read'),/does not recognize/);
  actor='alice';
  // Force one mailbox conflict after the plugin reads it. Its retry must preserve the new entry.
  const extraId='injected-message';
  write('message/'+extraId,{id:extraId,from:'alice',to:'bob',body:'concurrent',at:'2026-01-01T00:00:00Z'});
  injection = () => { injection=null; write(boxKey('bob'),{ids:{[extraId]:true}}); };
  const third=await send('conflict-once');
  assert.deepEqual(Object.keys(record(boxKey('bob')).value.ids).sort(),[extraId,third.id].sort());
  // A concurrent new send invalidates the ack revision. The retry must not clear its notice.
  actor='bob';
  const raceId='arrived-during-ack';
  injection = () => {
    injection=null;
    write('message/'+raceId,{id:raceId,from:'alice',to:'bob',body:'race',at:'2026-01-01T00:00:01Z'});
    const ids=record(boxKey('bob')).value.ids;
    ids[raceId]=true; write(boxKey('bob'),{ids});
    notices.set('bob',{pending:true,rev:99});
  };
  await call('ack',{ids:[extraId,third.id]});
  assert.deepEqual(Object.keys(record(boxKey('bob')).value.ids),[raceId]);
  assert.equal(notices.get('bob').pending,true);
  assert.deepEqual(record('message/'+first.id),original,'retries and ack preserve message data');
  actor='alice';
  const beforeConflict=batchCalls;
  injection = () => write(boxKey('bob'),record(boxKey('bob')).value);
  await assert.rejects(send('conflict-always'),/retry with the same send key/);
  injection=null;
  assert.equal(batchCalls-beforeConflict,4,'retry budget is bounded');
  assert.equal(operations.has('send/'+part('alice')+part('conflict-always')),false);
  // Simulate another accepted invocation saving the same operation before this batch arrives.
  injection = args => { injection=null; batch(copy(args)); };
  const replay=await send('committed-before-batch');
  assert.equal(replay.id,'send/'+part('alice')+part('committed-before-batch'));
  // A reply acknowledges only its original message in the same transaction.
  actor='alice';
  const question=await send('reply-question');
  actor='bob';
  const replyArgs={to:'alice',body:'answer',key:'reply-answer',reply_to:question.id};
  const reply=await call('send',replyArgs);
  assert.equal(record(boxKey('bob')).value.ids[question.id],undefined);
  assert.equal(record(boxKey('alice')).value.ids[reply.id],true);
  assert.equal(record('message/'+reply.id).value.reply_to,question.id);
  const afterReply=batchCalls;
  assert.deepEqual(await call('send',replyArgs),reply);
  assert.equal(batchCalls,afterReply,'reply replay changes neither mailbox nor notice');
  await assert.rejects(call('send',{...replyArgs,reply_to:first.id}),/different content/);
  const beforeInvalid=batchCalls;
  await assert.rejects(call('send',{...replyArgs,key:'foreign-reply',reply_to:second.id}),/reply_to must name/);
  await assert.rejects(call('send',{...replyArgs,key:'missing-reply',reply_to:'missing'}),/reply_to must name/);
  await assert.rejects(call('send',{...replyArgs,to:'bob',key:'wrong-recipient'}),/reply_to must name/);
  assert.equal(batchCalls,beforeInvalid,'invalid replies do not write');

  // An ack between the sender mailbox read and reply commit forces a safe retry.
  actor='alice';
  const racedQuestion=await send('reply-race-question');
  actor='bob';
  const beforeRace=batchCalls;
  injection=()=> {
    injection=null;
    const ids=record(boxKey('bob')).value.ids;
    delete ids[racedQuestion.id]; write(boxKey('bob'),{ids});
  };
  await call('send',{to:'alice',body:'raced answer',key:'reply-race',reply_to:racedQuestion.id});
  assert.equal(batchCalls-beforeRace,2,'reply retries after a concurrent ack');
  assert.equal(record(boxKey('bob')).value.ids[racedQuestion.id],undefined);

  // A new message during reply acknowledgement must keep the sender notice pending.
  actor='alice';
  const lastQuestion=await send('last-question');
  actor='bob';
  const bobIds=Object.keys(record(boxKey('bob')).value.ids).filter(id=>id!==lastQuestion.id);
  await call('ack',{ids:bobIds});
  injection=()=> {
    injection=null;
    const id='arrived-during-reply';
    write('message/'+id,{id,from:'alice',to:'bob',body:'new',at:'2026-01-01T00:00:02Z'});
    const ids=record(boxKey('bob')).value.ids; ids[id]=true; write(boxKey('bob'),{ids});
    notices.set('bob',{pending:true,rev:100});
  };
  await call('send',{to:'alice',body:'answer with race',key:'reply-arrival',reply_to:lastQuestion.id});
  assert.deepEqual(Object.keys(record(boxKey('bob')).value.ids),['arrived-during-reply']);
  assert.equal(notices.get('bob').pending,true);
  await call('send',{to:'alice',body:'last answer',key:'reply-last',reply_to:'arrived-during-reply'});
  assert.deepEqual(record(boxKey('bob')).value.ids,{});
  assert.equal(notices.get('bob').pending,false,'reply clears notice when the mailbox becomes empty');

  const self=await send('self-question','note','bob');
  const selfReply=await call('send',{to:'bob',body:'self answer',key:'self-reply',reply_to:self.id});
  assert.deepEqual(Object.keys(record(boxKey('bob')).value.ids),[selfReply.id]);
  assert.equal(notices.get('bob').pending,true,'self-reply leaves its new message pending');
  const list = async (include_archived=false) => (await call('thread_list',{include_archived})).threads;
  actor='alice';
  const createArgs={key:'group/:one',title:'Review',members:['bob','user']};
  const created=await call('thread_create',createArgs);
  assert.equal(created.group,true);
  assert.deepEqual(created.members,['alice','bob','user']);
  assert.equal((await list()).find(t=>t.id===created.id).title,'Review');
  assert(declaredTabs.some(t=>t.key===`thread/${created.id}`));
  const afterCreate=batchCalls;
  assert.deepEqual(await call('thread_create',{...createArgs,members:['user','bob','alice']}),created);
  assert.equal(batchCalls,afterCreate,'create replay does not write');
  await assert.rejects(call('thread_create',{...createArgs,title:'Other'}),/different content/);
  const other=await call('thread_create',{...createArgs,key:'groupone'});
  assert.notEqual(other.id,created.id,'punctuation in operation keys is not discarded');
  await assert.rejects(call('thread_create',{key:'missing',members:['unknown']}),/known participant|Unknown recipient/);
  injection=()=> {
    injection=null;
    const groups=record('groups').value.groups;
    groups['g-concurrent']={name:'Concurrent',members:['alice','bob']};
    write('groups',{groups});
  };
  const racedGroup=await call('thread_create',{key:'create-race',title:'Raced',members:['bob']});
  assert(record('groups').value.groups['g-concurrent']);
  assert(record('groups').value.groups[racedGroup.id]);
  const direct=await call('thread_create',{key:'direct',members:['bob']});
  assert.equal(direct.id,'bob');assert.equal(direct.group,false);
  assert.deepEqual(await call('thread_create',{key:'direct',members:['bob']}),direct);
  actor='charlie';
  assert(!(await list()).some(t=>t.id===created.id));
  await assert.rejects(call('thread_archive',{thread:created.id,key:'foreign'}),/Unknown thread/);
  await assert.rejects(call('read',{thread:created.id}),/member/);
  await assert.rejects(call('send',{to:created.id,key:'foreign',body:'no'}),/member/);
  actor='alice';
  const info=await call('send',{to:created.id,key:'fyi',body:'Review complete',reply_expected:false});
  assert.equal(record('message/'+info.id).value.reply_expected,false);
  await assert.rejects(call('send',{to:created.id,key:'fyi',body:'Review complete'}),/different content/);
  actor='user';
  const filtered=await call('read',{thread:created.id});
  assert.equal(filtered.messages.length,1);assert.equal(filtered.messages[0].reply_expected,false);
  assert.equal((await list()).find(t=>t.id===created.id).unread,1);
  assert.equal(declaredTabs.find(t=>t.key===`thread/${created.id}`).title,'Review (1)');
  const rendered=(await view('render',{route:`/thread/${created.id}`,user:'user'})).tree;
  assert.deepEqual(declaredTabs.find(t=>t.key===`thread/${created.id}`).status,{state:'done',msg:'1 unread'});
  assert.equal(rendered.status,undefined,'tab declaration owns thread status');
  assert.equal(rendered.nodes.find(n=>n.id==='thread_menu').action.name,'open');
  assert.deepEqual(await view('action',{route:`/thread/${created.id}`,user:'user',node_id:'thread_menu',action:'open',operation_key:'open-menu'}),{form:'/forms/thread-menu'});
  assert.equal(rendered.nodes.find(n=>n.type==='history').messages[0].fyi,true);
  assert.deepEqual((await call('read',{thread:created.id,since:filtered.next_cursor})).messages,{});
  assert.equal((await call('read',{thread:created.id})).messages.length,1,'cursor does not acknowledge');
  const draftKey='draft/'+part('user')+part(created.id);
  write(draftKey,{text:'keep this draft'});
  const draftBefore=record(draftKey);
  const archiveArgs={thread:created.id,key:'archive-1'};
  injection=()=> {
    injection=null;
    write('thread-archive/'+part('user'),{ids:{team:true}});
  };
  await call('thread_archive',archiveArgs);
  assert((await list(true)).find(t=>t.id==='team').archived,'archive retry preserves other archived threads');
  assert(!(await list()).some(t=>t.id===created.id));
  assert((await list(true)).find(t=>t.id===created.id).archived);
  assert(!declaredTabs.some(t=>t.key===`thread/${created.id}`),'archive omits the tab');
  assert.deepEqual(record(draftKey),draftBefore,'archive preserves draft');
  assert.equal((await call('read',{thread:created.id})).messages.length,1,'archive preserves unread delivery');
  const archiveHome=(await view('render',{route:'/panels/threads',user:'user'})).tree;
  assert(archiveHome.nodes.find(n=>n.id==='archived_threads').items.some(t=>t.id===created.id));
  actor='bob';assert(!(await list()).find(t=>t.id===created.id).archived,'archive is per participant');
  actor='alice';
  const newInfo=await call('send',{to:created.id,key:'later',body:'Another note'});
  actor='user';
  assert(!declaredTabs.some(t=>t.key===`thread/${created.id}`),'new mail does not undo archive');
  const afterCursor=await call('read',{thread:created.id,since:filtered.next_cursor});
  assert.deepEqual(afterCursor.messages.map(m=>m.id),[newInfo.id]);
  await call('ack',{ids:[info.id,newInfo.id]});
  const restore=await view('action',{route:'/panels/threads',user:'user',node_id:'archived_threads',action:'restore',input:{item_id:created.id},operation_key:'restore-ui'});
  assert.equal(restore.navigate,`thread/${created.id}`);
  assert.equal(declaredTabs.find(t=>t.key===`thread/${created.id}`).title,'Review');
  assert.equal(declaredTabs.find(t=>t.key===`thread/${created.id}`).status,undefined,'acknowledgment clears declared status');
  await call('thread_archive',archiveArgs);
  assert(declaredTabs.some(t=>t.key===`thread/${created.id}`),'old archive retry does not undo a newer restore');
  const archivedUI=await view('action',{route:'/forms/thread-menu',context:{session_id:'session:local',source_view_id:'view:test',source_route:`/thread/${created.id}`},user:'user',node_id:'thread_menu',action:'archive',operation_key:'archive-ui'});
  assert.deepEqual(archivedUI.panel,{command:'threads'});assert(!declaredTabs.some(t=>t.key===`thread/${created.id}`));
  await call('thread_archive',{thread:created.id,key:'restore-again',archived:false});
  // Revisions beyond exact floating-point range must still order arrivals correctly.
  revision=9007199254740992n;
  actor='alice';await send('large-rev-1','one','user');
  actor='user';const large=await call('read',{thread:'alice'});
  actor='alice';const last=await send('large-rev-2','two','user');
  actor='user';
  assert.deepEqual((await call('read',{thread:'alice',since:large.next_cursor})).messages.map(m=>m.id),[last.id]);
  await assert.rejects(call('read',{since:'1e3'}),/since|revision/);
  // Migration preserves old results and rewrites mutable ownership before any new dispatch.
  actor='alice';
  const retryArgs={to:'bob',body:'legacy migration message',key:'migration-retry'};
  const retryResult=await call('send',retryArgs);
  const historical=record('message/'+retryResult.id);
  const legacyGroupArgs={key:'migration-group',title:'Migration group',members:['bob','user']};
  const legacyGroup=await call('thread_create',legacyGroupArgs);
  actor='user';
  await call('thread_archive',{thread:'alice',key:'migration-archive'});
  const oldDraft='draft/'+part('user')+part('alice');
  write(oldDraft,{text:'keep the legacy draft'});
  const aliceID='claude:conversation-a', bobID='codex:conversation-b';
  const canonicalMessage='canonical-before-migration';
  write('message/'+canonicalMessage,{id:canonicalMessage,from:'user',to:bobID,body:'existing canonical mail',at:'2026-10-17T00:00:00Z'});
  write(boxKey(bobID),{ids:{[canonicalMessage]:true}});
  write('thread-meta/'+part('alice')+part('bob'),{home_session:'session:first-alias-home'});
  write('thread-meta/'+part(aliceID)+part(bobID),{home_session:'session:later-alias-home'});
  identityAliases={alice:aliceID,bob:bobID};
  let migrationAttempts=0;
  injection=args=> {
    if(!args.op?.key.startsWith('identity-migrate/')) return;
    migrationAttempts++; injection=null;
    const late='raced-legacy-mail';
    write('message/'+late,{id:late,from:'user',to:'bob',body:'arrived during scan',at:'2026-10-17T00:00:01Z'});
    write(boxKey('bob'),{ids:{...record(boxKey('bob')).value.ids,[late]:true}});
  };
  actor='bob';
  const migrated=await call('read');
  assert.equal(migrationAttempts,1);
  assert.equal(record('thread-meta/'+part(aliceID)+part(bobID)).value.home_session,'session:first-alias-home');
  assert.equal(record('thread-meta/'+part('alice')+part('bob')).rev,'0');
  assert(migrated.messages.some(m=>m.id===retryResult.id && m.from===aliceID && m.to===bobID));
  assert(migrated.messages.some(m=>m.id===canonicalMessage));
  assert(migrated.messages.some(m=>m.id==='raced-legacy-mail'));
  assert.equal(record(boxKey('bob')).rev,'0');
  assert.equal(record(boxKey('alice')).rev,'0');
  assert.deepEqual(record('message/'+retryResult.id),historical,'historical messages and their cursors stay unchanged');
  assert.deepEqual(record('groups').value.groups[legacyGroup.id].members,[aliceID,bobID,'user']);
  assert.equal(record(oldDraft).rev,'0');
  assert.equal(record('draft/'+part('user')+part(aliceID)).value.text,'keep the legacy draft');
  assert.equal(record('thread-open/'+part('user')+part(aliceID)).value.opened,true,'identity migration keeps explicit open intent');
  assert.equal(record('thread-archive/'+part('user')).value.ids[aliceID],true);
  assert.equal(notices.get('bob').pending,false);
  assert.equal(notices.get(bobID).pending,true);
  await call('ack',{ids:[retryResult.id]});
  assert(!(await call('read')).messages.some(m=>m.id===retryResult.id));
  actor='alice';
  const beforeRetry=batchCalls;
  assert.deepEqual(await call('send',retryArgs),retryResult,'old send key returns its original result');
  assert.equal(batchCalls,beforeRetry,'retry does not write or notify again');
  assert.deepEqual(await call('thread_create',legacyGroupArgs),legacyGroup,'old group operation returns its original result');
  await assert.rejects(call('send',{...retryArgs,body:'changed'}),/different content/);
  const fresh=await call('send',{to:'bob tab',body:'canonical new message',key:'new-identity-send'});
  assert.equal(record('message/'+fresh.id).value.from,aliceID);
  assert.equal(record('message/'+fresh.id).value.to,bobID);
  actor='user';
  assert((await list(true)).some(t=>t.id===aliceID && t.archived));
  const oldHistory=(await view('render',{route:'/thread/alice',user:'user'})).tree;
  assert(oldHistory.nodes.find(n=>n.id==='history').messages.length>0);
  assert.equal(oldHistory.nodes.find(n=>n.id==='composer').text,'keep the legacy draft');
  const context={session_id:'session:local',window_id:'window:local',source_view_id:'view:thread',source_route:'/thread/'+aliceID};
  const newForm=(await view('render',{route:'/forms/new-thread',user:'user',context})).tree;
  assert.deepEqual(newForm.status,{state:'blocked',kind:'question',msg:'Waiting for input'});
  const fields=newForm.nodes.find(n=>n.id==='new_thread').fields;
  assert.equal(fields.find(f=>f.id==='session_id').value,context.session_id);
  assert(fields.find(f=>f.id==='session_id').options.some(o=>o.value==='@new'));
  assert(fields.some(f=>f.id==='other_sessions' && f.kind==='boolean'));
  assert(fields.some(f=>f.id==='member_'+bobID && f.visible_when?.field==='other_sessions'));
  assert.equal(newForm.nodes.find(n=>n.id==='cancel').action.name,'$cancel');
  assert.deepEqual(await view('seen',{route:'/forms/new-thread',user:'user',context}),{acked:0});
  await assert.rejects(view('render',{route:'/forms/new-thread',user:'user'}),/no source session/);
  const menuTree=(await view('render',{route:'/forms/thread-menu',user:'user',context})).tree;
  assert.equal(menuTree.nodes.find(n=>n.id==='thread_menu').type,'list');
  // The menu is a thread overview: a summary, the agents, then the thread actions. Ctrl+O closes it.
  assert.equal(menuTree.menu,true);
  assert.match(menuTree.nodes.find(n=>n.id==='summary').text,/^1 agent · \d+ messages?/);
  const agentRows=menuTree.nodes.find(n=>n.id==='agents').items;
  assert.deepEqual(agentRows.map(i=>i.id),[aliceID]);
  assert(agentRows[0].action.enabled && agentRows[0].status && agentRows[0].icon,'an agent row opens its tab');
  assert(!menuTree.nodes.find(n=>n.id==='thread_menu').items.some(i=>i.id==='older'),'no older item when all history shows');
  assert.equal(menuTree.nodes.at(-1).action.label,'Close');
  assert.deepEqual(await view('action',{route:'/forms/thread-menu',user:'user',context,node_id:'agents',action:'agent',input:{item_id:aliceID},operation_key:'go-alice'}),{close_form:true});
  assert.deepEqual(navigated,[aliceID]);
  await assert.rejects(view('action',{route:'/forms/thread-menu',user:'user',context,node_id:'agents',action:'agent',input:{item_id:bobID},operation_key:'go-bob'}),/not in this thread/);
  assert.equal((await view('render',{route:'/forms/thread-rename',user:'user',context})).tree.menu,true);
  assert.equal(menuTree.status.state,'blocked');
  const menuResult=await view('action',{route:'/forms/thread-menu',user:'user',context,node_id:'thread_menu',action:'rename',input:{item_id:'rename'},operation_key:'open-rename'});
  assert.deepEqual(menuResult,{form:'/forms/thread-rename'});
  const renameForm=(await view('render',{route:'/forms/thread-rename',user:'user',context})).tree;
  assert(renameForm.nodes.some(n=>n.id==='rename_thread'));
  const renamedForm=await view('action',{route:'/forms/thread-rename',user:'user',context,node_id:'rename_thread',action:'submit',input:{values:{title:'From form'}},operation_key:'rename-form'});
  assert.deepEqual(renamedForm,{close_form:true});
  assert.equal((await view('render',{route:'/thread/'+aliceID,user:'user'})).tree.title,'From form');
  await assert.rejects(view('render',{route:'/forms/thread-rename',user:'user',context:{...context,source_route:'/'}}),/Not a thread route/);
  // Tab titles persist independently of the participant name and unread count.
  const route='/thread/'+aliceID;
  const renamed=await view('rename',{route,user:'user',title:'  Release notes  '});
  assert.equal(renamed.title,'Release notes');
  assert.equal((await view('render',{route,user:'user'})).tree.title,'Release notes');
  await view('action',{route:'/forms/thread-rename',user:'user',context,node_id:'rename_thread',action:'submit',input:{values:{title:'From form'}},operation_key:'rename-form'});
  assert.equal((await view('render',{route,user:'user'})).tree.title,'Release notes','an old form retry does not undo a later tab rename');
  await assert.rejects(view('action',{route:'/forms/thread-rename',user:'user',context,node_id:'rename_thread',action:'submit',input:{values:{title:'Other'}},operation_key:'rename-form'}),/different content/);
  assert.equal((await list(true)).find(t=>t.id===aliceID).title,'Release notes');
  assert.equal(record('thread-title/'+part('user')+part(aliceID)).value.title,'Release notes');
  await view('rename',{route,user:'user',title:'Release notes'});
  await assert.rejects(view('rename',{route,user:'user',title:'  '}),/must not be empty/);
  await assert.rejects(view('rename',{route:'/panels/threads',user:'user',title:'Inbox'}),/Not a thread route/);
  await assert.rejects(control.call('client.perform',{client_id:pluginId,action:'view.rename',args:{route,user:'user',title:'Wrong caller'}}),/Only the hub/);
  unnamedIdentities=true;
  const unnamed=(await view('render',{route:'/thread/'+bobID,user:'user'})).tree;
  assert.equal(unnamed.title,'codex:conversa');
  const home=(await view('render',{route:'/panels/threads',user:'user'})).tree;
  assert.equal(home.nodes.find(n=>n.id==='new_thread').fields.find(f=>f.id==='member_'+bobID).label,'codex:conversa');
  assert.equal((await view('render',{route,user:'user'})).tree.title,'Release notes');
  for (const mode of [true,'id','invalid','whitespace']) {
    unnamedIdentities=mode;
    assert.equal((await view('render',{route:'/thread/'+bobID,user:'user'})).tree.title,'codex:conversa');
    await hub.call('client.perform',{client_id:pluginId,action:'hub.changed',args:{what:'agents'}});
    assert(declaredTabs.every(t=>typeof t.title==='string' && t.title.trim().length>0));
    assert(declaredTabs.some(t=>t.key==='thread/'+bobID && t.title.startsWith('codex:conversa')));
  }
  unnamedIdentities=false;
  // Two nonempty drafts must not silently overwrite each other during alias migration.
  const charlieID='claude:conversation-c';
  write('draft/'+part('user')+part('charlie'),{text:'old draft'});
  write('draft/'+part('user')+part(charlieID),{text:'new draft'});
  write('thread-title/'+part('user')+part('charlie'),{title:'Legacy title'});
  write('thread-title/'+part('user')+part(charlieID),{title:'Latest title'});
  identityAliases.charlie=charlieID;
  await assert.rejects(call('read'),/Two drafts have different text/);
  assert.equal(record('draft/'+part('user')+part('charlie')).value.text,'old draft');
  assert.equal(record('draft/'+part('user')+part(charlieID)).value.text,'new draft');
  records.delete('draft/'+part('user')+part(charlieID));
  await call('read');
  assert.equal(record('draft/'+part('user')+part(charlieID)).value.text,'old draft');
  assert.equal(record('thread-title/'+part('user')+part(charlieID)).value.title,'Latest title');
  assert.equal(record('thread-title/'+part('user')+part('charlie')).rev,'0');
  // Membership changes preserve delivered mail and expose paginated history without unread backfill.
  actor='user';
  const editable=await call('thread_create',{members:[aliceID,bobID],title:'Membership review',key:'editable-members'});
  actor='alice';
  const oldMail=await call('send',{to:editable.id,body:'Before membership changed',key:'before-members'});
  const legacyRecord=records.get('message/'+oldMail.id);
  delete legacyRecord.value.recipients; // Existing messages predate immutable recipient snapshots.
  const oldMessageRevision=legacyRecord.rev;
  actor='user';
  const memberContext={session_id:'session:local',window_id:'window:local',source_view_id:'view:members',source_route:'/thread/'+editable.id};
  const editArgs={route:'/forms/thread-members',user:'user',context:memberContext,node_id:'thread_members',action:'submit',input:{values:{['member_'+aliceID]:true,['member_'+charlieID]:true}},operation_key:'change-members'};
  const memberForm=(await view('render',{route:editArgs.route,user:'user',context:memberContext})).tree;
  assert(memberForm.nodes.find(n=>n.id==='thread_members').fields.find(f=>f.id==='member_'+bobID).value);
  injection=args=>{
    if(!args.op?.key.startsWith('members/')) return;
    injection=null;
    const groups=record('groups').value;
    groups.groups['g-concurrent-members']={name:'Concurrent group',members:['user',bobID]};
    write('groups',groups);
  };
  assert.deepEqual(await view('action',editArgs),{close_form:true});
  assert(record('groups').value.groups['g-concurrent-members'],'membership retry preserves an unrelated group');
  assert.equal(record('message/'+oldMail.id).rev,oldMessageRevision,'membership never rewrites old messages or cursors');
  assert.deepEqual(await view('action',editArgs),{close_form:true},'membership retry has one result');
  await assert.rejects(view('action',{...editArgs,input:{values:{['member_'+bobID]:true}}}),/different content/);
  actor='bob';
  assert((await call('read',{thread:editable.id})).messages.some(m=>m.id===oldMail.id),'removed member keeps delivered mail');
  await assert.rejects(call('history',{thread:editable.id}),/Only a current member can read/);
  await call('ack',{ids:[oldMail.id]});
  actor='charlie';
  const welcome=(await call('read',{thread:editable.id})).messages;
  assert.equal(welcome.length,1,'new member gets one new notice, not unread backfill');
  assert.match(welcome[0].body,/messaging.history/);
  assert((await call('history',{thread:editable.id})).messages.some(m=>m.id===oldMail.id),'new member can read old history');
  actor='alice';
  const pageMessages=[];
  for(let i=0;i<24;i++) pageMessages.push(await call('send',{to:editable.id,body:'History page '+i,key:'page-'+i}));
  actor='charlie';
  const newest=await call('history',{thread:editable.id});
  assert.equal(newest.messages.length,20);
  assert.equal(newest.messages[0].id,pageMessages.at(-1).id);
  actor='alice';
  const arrivedBetweenPages=await call('send',{to:editable.id,body:'Between pages',key:'between-pages'});
  actor='charlie';
  const older=await call('history',{thread:editable.id,before:newest.next_before});
  assert(!older.messages.some(m=>m.id===arrivedBetweenPages.id),'older cursor excludes later arrivals');
  assert(older.messages.some(m=>m.id===oldMail.id));
  assert(!older.next_before);
  assert.equal(new Set([...newest.messages,...older.messages].map(m=>m.id)).size,26);
  assert.equal((await call('read',{thread:editable.id})).messages.length,26,'history does not acknowledge mail');
  await assert.rejects(call('history',{thread:editable.id,limit:51}));
  // A send whose membership snapshot becomes stale must use the updated recipients on retry.
  actor='alice';
  injection=args=>{
    if(!args.ops.some(op=>op.key?.startsWith('message/send/') && op.value?.body==='Membership race')) return;
    injection=null;
    const groups=record('groups').value;
    groups.groups[editable.id].members=['user',aliceID,bobID];
    write('groups',groups);
  };
  const raced=await call('send',{to:editable.id,body:'Membership race',key:'membership-race'});
  assert(record(boxKey(bobID)).value.ids[raced.id]);
  assert(!record(boxKey(charlieID)).value.ids[raced.id]);
  actor='user';
  const directResult=await view('action',{...editArgs,context:{...memberContext,source_route:'/thread/'+aliceID},operation_key:'expand-direct',input:{values:{['member_'+aliceID]:true,['member_'+bobID]:true}}});
  assert(directResult.navigate.startsWith('thread/g-'),'adding to a direct thread creates a group');
  assert((await view('render',{route:'/thread/'+aliceID,user:'user'})).tree.nodes.find(n=>n.id==='history').messages.length>0,'direct history remains intact');
  await assert.rejects(view('render',{route:'/forms/thread-members',user:'user',context:{...memberContext,source_route:'/thread/team'}}),/dynamic membership/);
  const oldCreate={id:bobID,title:'bob tab',members:['user',bobID].sort(),group:false};
  const legacyKey='thread-create/'+part('user')+part('old-create-no-home');
  operations.set(legacyKey,{key:legacyKey,fingerprint:'thread-create-v1/'+part('')+oldCreate.members.map(part).join(''),result:oldCreate});
  records.delete('thread-meta/'+['user',bobID].sort().map(part).join(''));
  await view('action',{route:'/forms/new-thread',user:'user',context,node_id:'new_thread',action:'submit',operation_key:'old-create-no-home',input:{values:{['member_'+bobID]:true}}});
  assert.equal(declaredTabs.find(t=>t.key==='thread/'+oldCreate.id).session_id,undefined,'old operation replay does not add a home');
  // Thread homes remain stable across creation retries and other sessions.
  const createHome={route:'/forms/new-thread',user:'user',context,node_id:'new_thread',action:'submit',operation_key:'home-direct',input:{values:{['member_'+aliceID]:true}}};
  const homeResult=await view('action',createHome);
  assert.equal(homeResult.navigate,'thread/'+aliceID);
  const homeTab=()=>declaredTabs.find(t=>t.key==='thread/'+aliceID);
  assert.equal(homeTab().session_id,context.session_id);
  const originalToken=homeTab().revision;
  assert.equal(typeof originalToken,'string');
  assert.deepEqual(await view('action',createHome),homeResult);
  await view('action',{...createHome,operation_key:'home-direct-again',context:{...context,session_id:'session:elsewhere'}});
  assert.equal(homeTab().session_id,context.session_id,'existing direct thread keeps its first home');
  assert.deepEqual(await view('action',{...createHome,context:{...context,session_id:'session:elsewhere'}}),homeResult,'a default-session replay preserves its original result');
  await view('rename',{route:'/thread/'+aliceID,user:'user',title:'Homed thread'});
  await view('seen',{route:'/thread/'+aliceID,user:'user'});
  assert.equal(homeTab().revision,originalToken,'rename and acknowledgment do not change the message token');
  actor='alice';
  const homeMail=await call('send',{to:'user',body:'Reopen this thread',key:'home-reopen'});
  assert.equal(homeTab().revision,homeMail.id,'a new message changes the reopen token');
  actor='user';
  await call('thread_archive',{thread:'team',key:'restore-team-for-order',archived:false});
  const sessionItems=async(session)=>Object.values((await view('render',{route:'/panels/threads',user:'user',context:{...context,session_id:session}})).tree.nodes.find(n=>n.id==='threads').items || {});
  const indexOf = (items,id) => items.findIndex(i=>i.id===id);
  const localItems=await sessionItems(context.session_id);
  assert(indexOf(localItems,aliceID)>=0 && indexOf(localItems,aliceID)<indexOf(localItems,'team'),'current-session threads appear before default-session threads');
  assert((await sessionItems('session:elsewhere')).some(i=>i.id===aliceID),'the global panel keeps threads from other sessions');
  const defaultItems=await sessionItems('session:messages');
  assert(indexOf(defaultItems,'team')<indexOf(defaultItems,aliceID),'unhomed threads come first in the default session');
  homeRedirects={[context.session_id]:'session:replacement'};
  const redirected=await sessionItems('session:replacement');
  assert(indexOf(redirected,aliceID)<indexOf(redirected,'team'),'redirected threads come first in the replacement session');
  assert.equal(homeTab().session_id,context.session_id,'the stored home stays unchanged');
  homeRedirects={};
  const expandedTab=declaredTabs.find(t=>t.key===directResult.navigate);
  assert.equal(expandedTab.session_id,memberContext.session_id,'direct expansion gives the new group the form session');
  assert.equal(expandedTab.revision,'','an empty group has a stable empty token');
  assert.deepEqual(await view('action',{route:'/panels/threads',user:'user',context,node_id:'threads',action:'open',input:{item_id:aliceID},operation_key:'open-listed'}),homeResult);
  // A concurrent first home wins without losing the creation operation.
  const raceCreate={...createHome,operation_key:'home-race',input:{values:{['member_'+charlieID]:true}}};
  injection=args=>{
    const op=args.ops.find(op=>op.key?.startsWith('thread-meta/') && op.value?.home_session===context.session_id);
    if(!op) return;
    injection=null;
    write(op.key,{home_session:'session:winner'});
  };
  await view('action',raceCreate);
  assert.equal(declaredTabs.find(t=>t.key==='thread/'+charlieID).session_id,'session:winner');
  // Session choice uses exact IDs and preserves the original default on operation replay.
  sourceSession='session:elsewhere';
  const agentHomeArgs={members:[aliceID,bobID],title:'Agent session default',key:'agent-home-default'};
  const agentHome=await call('thread_create',agentHomeArgs);
  const declared=id=>declaredTabs.find(t=>t.key==='thread/'+id);
  assert.equal(declared(agentHome.id).session_id,'session:elsewhere');
  sourceSession='session:local';
  assert.deepEqual(await call('thread_create',agentHomeArgs),agentHome);
  assert.equal(declared(agentHome.id).session_id,'session:elsewhere');
  await assert.rejects(call('thread_create',{...agentHomeArgs,session_id:'session:local'}),/different content/);
  await assert.rejects(call('thread_create',{members:[aliceID],title:'Closed target',key:'closed-target',session_id:'session:closed'}),/closed/);
  const explicit=await call('thread_create',{members:[aliceID],title:'Explicit target',key:'explicit-target',session_id:'session:other'});
  assert.equal(declared(explicit.id).session_id,'session:other');
  const namedArgs={members:[aliceID],title:'Named target',key:'named-target',new_session:'New workspace'};
  const named=await call('thread_create',namedArgs);
  const namedSession=declared(named.id).session_id;
  assert.equal(openSessions.get(namedSession),'New workspace');
  const ensuredCount=ensuredSessions.size, ensureBefore=ensureCalls;
  assert.deepEqual(await call('thread_create',namedArgs),named);
  assert.equal(ensureCalls,ensureBefore,'saved creation does not call session.ensure again');
  await call('thread_create',{members:[aliceID],key:'existing-direct-new-choice',new_session:'Unused workspace'});
  assert.equal(ensuredSessions.size,ensuredCount,'existing direct thread creates no unused session');
  assert.equal(homeTab().session_id,context.session_id);
  const namedUI=await view('action',{...createHome,operation_key:'ui-new-session',input:{values:{title:'UI session',session_id:'@new',session_name:'UI workspace',['member_'+aliceID]:true}}});
  assert.equal(openSessions.get(declaredTabs.find(t=>t.key===namedUI.navigate).session_id),'UI workspace');
  await assert.rejects(view('action',{...createHome,operation_key:'ui-no-name',input:{values:{session_id:'@new',['member_'+aliceID]:true}}}),/name/);
  const menuContext={...context,source_route:'/thread/'+aliceID};
  assert.deepEqual(await view('action',{route:'/forms/thread-menu',context:menuContext,user:'user',node_id:'thread_menu',action:'move',operation_key:'menu-move'}),{form:'/forms/thread-move'});
  const moveForm=(await view('render',{route:'/forms/thread-move',context:menuContext,user:'user'})).tree;
  assert.equal(moveForm.nodes.find(n=>n.id==='move_thread').fields.find(f=>f.id==='session_id').value,context.session_id);
  const draftBeforeMove=record('draft/'+part('user')+part(aliceID));
  const tokenBeforeMove=homeTab().revision;
  const move={route:'/forms/thread-move',context:menuContext,user:'user',node_id:'move_thread',action:'submit',operation_key:'move-existing',input:{values:{session_id:'session:elsewhere'}}};
  assert.deepEqual(await view('action',move),{navigate:'thread/'+aliceID});
  assert.equal(homeTab().session_id,'session:elsewhere');
  assert.equal(homeTab().revision,tokenBeforeMove,'a move does not change the message token');
  assert.deepEqual(record('draft/'+part('user')+part(aliceID)),draftBeforeMove,'a move preserves the saved draft');
  await view('action',{...move,operation_key:'move-new',input:{values:{session_id:'@new',session_name:'Moved workspace'}}});
  const movedHome=homeTab().session_id;
  assert.equal(openSessions.get(movedHome),'Moved workspace');
  await view('action',move);
  assert.equal(homeTab().session_id,movedHome,'an old move replay does not undo a later move');
  await assert.rejects(view('action',{...move,input:{values:{session_id:'session:other'}}}),/different content/);
  await assert.rejects(view('action',{...move,operation_key:'move-closed',input:{values:{session_id:'session:closed'}}}),/closed/);
  assert.equal(homeTab().session_id,movedHome);
  sourceSession=undefined;
  await assert.rejects(call('thread_create',{members:[aliceID],title:'No source',key:'no-source'}),/source session/);
  sourceSession='session:local';
  const interruptedArgs={members:[aliceID],title:'Interrupted session creation',new_session:'Resumed workspace',key:'interrupted-new-session'};
  const sessionsBeforeFailure=ensuredSessions.size;
  injection=args=>{
    if(args.op?.key?.endsWith(part('interrupted-new-session'))) { injection=null; throw Error('Injected failure after session creation'); }
  };
  await assert.rejects(call('thread_create',interruptedArgs),/Injected failure/);
  assert.equal(ensuredSessions.size,sessionsBeforeFailure+1);
  const resumed=await call('thread_create',interruptedArgs);
  assert.equal(ensuredSessions.size,sessionsBeforeFailure+1,'retry reuses the session created before the failed thread write');
  assert.equal(openSessions.get(declared(resumed.id).session_id),'Resumed workspace');
  // The human can observe agent-only threads without changing agent access or unread mail.
  actor='alice';
  const observedGroup=await call('thread_create',{key:'observer-group',title:'Agent discussion',members:[bobID]});
  const observedOld=await call('send',{to:observedGroup.id,key:'observer-old',body:'Before the user joined'});
  assert(!declaredTabs.some(t=>t.key==='thread/'+observedGroup.id),'an observed group is not opened automatically');
  actor='user';
  const observerList=await list();
  assert(observerList.some(t=>t.id===observedGroup.id && t.observer && t.unread===0));
  const observedDirect='d-'+Buffer.from([aliceID,bobID].sort().map(part).join('')).toString('hex');
  assert(observerList.some(t=>t.id===observedDirect && t.readonly && t.unread===0));
  assert(!declaredTabs.some(t=>t.key==='thread/'+observedDirect),'observed directs require an explicit open');
  const panel=(await view('render',{route:'/panels/threads',user:'user',context})).tree;
  assert(panel.nodes.find(n=>n.id==='observed_threads').items.some(i=>i.id===observedGroup.id));
  assert(!panel.nodes.find(n=>n.id==='threads').items.some(i=>i.id===observedGroup.id));
  await view('action',{route:'/panels/threads',user:'user',node_id:'observed_threads',action:'open',input:{item_id:observedDirect},operation_key:'open-observed-direct'});
  const observedTab=declaredTabs.find(t=>t.key==='thread/'+observedDirect);
  assert(observedTab && observedTab.status===undefined && observedTab.revision==='','observed tabs have no unread status or reopen token');
  const observedTree=(await view('render',{route:'/thread/'+observedDirect,user:'user'})).tree;
  assert(!observedTree.nodes.some(n=>n.id==='composer'));
  assert.match(observedTree.nodes.find(n=>n.id==='observer_notice').text,/read-only/);
  assert(observedTree.nodes.find(n=>n.id==='history').messages.length>0);
  await assert.rejects(view('draft.save',{route:'/thread/'+observedDirect,user:'user',text:'No',base_revision:'0',operation_key:'readonly-draft'}),/read-only/);
  await assert.rejects(view('send',{route:'/thread/'+observedDirect,user:'user',text:'No',draft_revision:'0',operation_key:'readonly-send'}),/read-only/);
  const userBoxBeforeObserve=copy(record(boxKey('user')));
  assert.deepEqual(await view('seen',{route:'/thread/'+observedGroup.id,user:'user'}),{acked:0});
  assert.deepEqual(await view('seen',{route:'/thread/'+observedDirect,user:'user'}),{acked:0});
  assert.deepEqual(record(boxKey('user')),userBoxBeforeObserve,'observation does not acknowledge or deliver mail');
  actor='charlie';
  assert(!(await list()).some(t=>t.id===observedGroup.id || t.id===observedDirect),'agents do not get observer threads');
  await assert.rejects(call('history',{thread:observedGroup.id}),/Only a current member/);
  await assert.rejects(view('render',{route:'/thread/'+observedDirect,user:charlieID}),/Unknown/);
  actor='user';
  const joinRoute='/thread/'+observedGroup.id;
  await view('open',{route:joinRoute,user:'user'});
  assert(declaredTabs.some(t=>t.key==='thread/'+observedGroup.id && t.status===undefined));
  const joinTree=(await view('render',{route:joinRoute,user:'user'})).tree;
  assert.match(joinTree.nodes.find(n=>n.id==='observer_notice').text,/first message/);
  const savedJoin=await view('draft.save',{route:joinRoute,user:'user',text:'Joining the discussion',base_revision:'0',operation_key:'join-draft'});
  const joinArgs={route:joinRoute,user:'user',text:'Joining the discussion',draft_revision:savedJoin.draft_revision,operation_key:'join-group'};
  await assert.rejects(view('send',{...joinArgs,draft_revision:'0',operation_key:'bad-join'}),/draft differs/);
  assert(!record('groups').value.groups[observedGroup.id].members.includes('user'),'a refused send does not join');
  // A legacy message has no inline delivery snapshot. Joining must preserve its old audience.
  const legacyObserved=copy(record('message/'+observedOld.id).value); delete legacyObserved.recipients;
  write('message/'+observedOld.id,legacyObserved);
  let joinRaced=false;
  injection=args=>{
    if(args.op?.key!=='send/'+part('user')+part('join-group')) return;
    injection=null; joinRaced=true;
    assert(!record('groups').value.groups[observedGroup.id].members.includes('user'));
    assert.equal(record('message/'+args.op.key).rev,'0','join and message are not partially committed');
    const groups=copy(record('groups').value); groups.groups[observedGroup.id].name='Agent discussion after concurrent rename';
    write('groups',groups);
  };
  const joined=await view('send',joinArgs);
  assert(joinRaced,'the first join retried a group revision conflict');
  assert.deepEqual(await view('send',joinArgs),joined,'joining and sending are idempotent');
  assert.equal(record('groups').value.groups[observedGroup.id].members.filter(id=>id==='user').length,1);
  assert.deepEqual(record(boxKey('user')),userBoxBeforeObserve,'joining does not backfill unread history');
  assert.deepEqual(record('delivery/'+part(observedOld.id)).value.ids,[bobID],'legacy history keeps its original recipients');
  assert(!(await list()).find(t=>t.id===observedGroup.id).observer);
  assert(!(await view('render',{route:joinRoute,user:'user'})).tree.nodes.some(n=>n.id==='observer_notice'));
  actor='bob';
  assert((await call('read',{thread:observedGroup.id})).messages.some(m=>m.id===joined.message_id));
  await call('send',{to:observedGroup.id,key:'observer-future',body:'Welcome'});
  actor='user';
  assert.equal((await call('read',{thread:observedGroup.id})).messages.length,1,'only future messages become unread');
  assert.equal((await list()).find(t=>t.id===observedGroup.id).unread,1);
  // Older messages expand the visible history once per action key.
  actor='alice';
  for(let i=0;i<205;i++) await call('send',{to:bobID,key:'observer-page-'+i,body:'Older message '+i});
  actor='user';
  const historyBefore=(await view('render',{route:'/thread/'+observedDirect,user:'user'})).tree.nodes.find(n=>n.id==='history');
  // A view tree holds the newest messages within one Rex control message (64 KiB). The transcript
  // pane fetches the older pages with view.history and prints the whole thread.
  assert(historyBefore.has_more && historyBefore.messages.length>0 && !('load_action' in historyBefore));
  assert(JSON.stringify(historyBefore).length<45000,'the tail fits in one control message');
  const fullIDs=[...historyBefore.messages.map(m=>m.id)];
  for(let before=fullIDs[0], more=true; more;) {
    const page=await view('history',{route:'/thread/'+observedDirect,user:'user',before});
    assert(JSON.stringify(page).length<60000,'a page fits in one control message');
    assert(page.messages.length>0);
    fullIDs.unshift(...page.messages.map(m=>m.id)); before=page.messages[0].id; more=page.has_more;
  }
  assert.equal(new Set(fullIDs).size,fullIDs.length,'pages do not overlap');
  assert(fullIDs.length>=205,'pages reach the first message');
  await assert.rejects(view('history',{route:'/thread/'+observedDirect,user:'user',before:'no-such-id'}),/Unknown history cursor/);
  // A long message arrives whole; only a message larger than a page (not sendable through Lua) is cut.
  actor='alice';
  await call('send',{to:bobID,key:'observer-huge',body:'y'.repeat(15000)});
  actor='user';
  const hugeTail=(await view('render',{route:'/thread/'+observedDirect,user:'user'})).tree.nodes.find(n=>n.id==='history');
  assert.equal(hugeTail.messages.at(-1).text.length,15000);
  assert(JSON.stringify(hugeTail).length<60000);
  const olderContext={session_id:'session:local',source_view_id:'view:test',source_route:'/thread/'+observedDirect};
  const olderTree=(await view('render',{route:'/forms/thread-menu',user:'user',context:olderContext})).tree;
  assert(!olderTree.nodes.find(n=>n.id==='thread_menu').items.some(i=>i.id==='older'),'the overview has no older item');
  assert.doesNotMatch(olderTree.nodes.find(n=>n.id==='summary').text,/showing/);
  assert.deepEqual(olderTree.nodes.find(n=>n.id==='agents').items.map(i=>i.id).length,2,'an observed direct lists both agents');
  await assert.rejects(view('action',{route:'/thread/'+observedDirect,user:'user',node_id:'history',action:'load',operation_key:'observer-load-1'}));
  console.log('PASS user observation, read-only directs, atomic group join, unread isolation, and full history');
  console.log('PASS session defaults, explicit and new sessions, replay, menu moves, and draft/token preservation');
  console.log('PASS thread homes, concurrent first home, session list, stable message tokens, and form navigation');
  console.log('PASS membership delivery snapshots, replay, history pages, unread isolation, send race, and direct expansion');
  console.log('PASS trusted thread rename, title persistence, alias migration, and short identity display');
  // Only the registered hub may assert a forwarded PID. Direct calls retain their real caller.
  const forwardedArgs={action:'messaging.read',args:{},requester_pid:process.pid};
  await assert.rejects(control.call('client.perform',{client_id:pluginId,action:'hub.forward',args:forwardedArgs}),/Only the hub/);
  const forwarded=(await hub.call('client.perform',{client_id:pluginId,action:'hub.forward',args:forwardedArgs})).result;
  assert.deepEqual(forwarded,await call('read'));
  await assert.rejects(hub.call('client.perform',{client_id:pluginId,action:'hub.forward',args:{...forwardedArgs,action:'view.render'}}),/not exported/);
  await assert.rejects(hub.call('client.perform',{client_id:pluginId,action:'hub.forward',args:{...forwardedArgs,requester_pid:0}}),/positive requester/);
  console.log('PASS identity migration, paged scan, conflict rescan, merged unread mail, old retries, historical cursors, groups, archives, and drafts');
  console.log('PASS thread creation/replay, membership, archive/restore isolation, UI tabs, unread status, FYI, and revision cursors');
  console.log('PASS native schemas, named exports, reply acknowledgement, refusal, replay, self-reply, and reply races');
  console.log('PASS plugin identity, durable contract, replay, conflicts, Unicode, ack isolation, and injected mailbox races');
} finally {
  if (child && child.exitCode === null && child.signalCode === null) { const exited=once(child,'exit'); child.kill('SIGTERM'); await exited; }
  hub.close(); control.close();
}
