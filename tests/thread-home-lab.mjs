// Lab: message threads in their home session, end to end through the palette, the real messaging
// plugin and the real renderer (Codex's acceptance list for hometabs.go + messaging homes).
// Lab only: /tmp/rexlab-pal with the hub on int.json (plugins lazyrex and messaging, palette_lua
// set, server started with LAB_CONFIG=init.lua) and /tmp/rexlab-pal/fake-agent.sh.
// Two phases, with a hub restart between them:
//   node thread-home-lab.mjs 1   then restart the hub, then   node thread-home-lab.mjs 2
// Phase 1: a New Thread from session A opens and focuses the thread in A; the same direct thread
// from session B goes back to A; Threads… in A lists it and B omits it; Threads… in the default
// Messages session lists unhomed threads; a user close. Phase 2: the closed thread stays closed
// across the restart with the same revision; a real message reopens it without focus; after
// another close, Threads… Open reopens it; a form from the thread menu keeps the thread's draft.
import {connectControl} from '../../LazyRex/lib/rex-client.mjs';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const LAB = process.env.PALETTE_LAB || '/tmp/rexlab-pal', SOCK = `unix://${LAB}/rex.sock`, STATE = `${LAB}/thread-home.json`;
const phase = process.argv[2];
assert(phase === '1' || phase === '2', 'usage: thread-home-lab.mjs 1|2');
const c = await connectControl(`${LAB}/rex.sock`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const waitFor = async (what, f, ms = 15000) => { for (let t = 0; t < ms; t += 150) { const v = await f(); if (v) return v; await sleep(150); } assert.fail(`timed out: ${what}`); };
const hubId = (await c.call('client.list')).clients.filter(x => x.info?.label === 'lazyrex-hub' && x.connection_state === 'connected').at(-1).client_id;
const hub = async (action, args = {}) => (await c.call('client.perform', {client_id: hubId, action, args, timeout_ms: 10000})).result;
const rex = (...a) => execFileSync('env', ['-u', 'REX_SESSION', '-u', 'REX_BLOCK', 'rex', '-S', SOCK, '--autostart=false', ...a], {encoding: 'utf8'});
const screen = (s, b) => { try { return rex('capture', '-s', s, '-b', b).replace(/\s+/g, ''); } catch { return ''; } };
// checkboxes lists the labels of the visible checkboxes of a form, top to bottom.
const checkboxes = (s, b) => rex('capture', '-s', s, '-b', b).split('\n').filter(l => l.includes('▏▕')).map(l => l.split('▏▕')[1].trim());
// focused returns the label of the focused checkbox: the renderer draws it bold in the accent color
// (the dark palette: the lab has no app to report a theme).
const focused = (s, b) => (rex('capture', '-s', s, '-b', b, '--format', 'html').match(/color: rgb\(165, 180, 252\);font-weight: bold;">([^<]*)</) || [])[1]?.trim() ?? '';
// focusTo presses Tab until the focused control's label includes text. The form scrolls to the
// focused control, so this also finds controls below the visible rows.
const focusTo = (s, b, text) => {
  const seen = [];
  for (let i = 0; i < 60; i++) { const x = focused(s, b); seen.push(x); if (x.includes(text)) return; press(s, b, 'tab'); }
  assert.fail(`no control ${text}; focus went ${seen.join(' > ')}\n${rex('capture', '-s', s, '-b', b)}`);
};
// submit checks the agent whose label includes text, then presses Tab past the last checkbox to the
// Create button and presses Enter.
const submit = (s, b, text) => {
  focusTo(s, b, text); press(s, b, 'space');
  for (let i = 0; i < 60 && focused(s, b); i++) press(s, b, 'tab');
  press(s, b, 'enter');
};
const press = (s, b, ...keys) => { for (const k of keys) { rex('send-key', '-s', s, '-b', b, k); execFileSync('sleep', ['0.15']); } };
const describe = () => hub('hub.ui.describe', {plugin: 'messaging'});
const threadView = async tab => (await describe()).views.find(v => v.tab === tab && v.status === 'open' && v.block_id);
const active = async s => (await c.call('session.view', {session_id: s})).active_window_id;
const shell = label => ({block: {flavor: 'com.superlogical.terminal.shell', label, options: {command: ['/bin/sleep', '3600'], login: false}}});
const formBlocks = async s => (await c.call('session.view', {session_id: s})).windows.flatMap(w => w.layers.flatMap(l => l.blocks)).filter(b => b.label.startsWith('lazyrex-form:'));
const formBlock = async s => (await formBlocks(s))[0];
// palette runs a palette command in session s on block b, as the app would, and returns the form pane.
const palette = async (cmd, s, b) => {
  await c.call('session.attach', {session_id: s, event_scope: 'session'});
  const old = new Set((await formBlocks(s)).map(x => x.block_id)); // forms left open by earlier runs
  await c.call('client.action', {action: `lazyrex_messaging_${cmd}`, origin: 'palette', session_id: s, block_id: b});
  const f = await waitFor(`${cmd} form in ${s}`, async () => (await formBlocks(s)).find(x => !old.has(x.block_id)));
  await waitFor(`${cmd} form rendered`, () => screen(s, f.block_id).includes('Ctrl+Qquit')); // the footer: long lists hide Cancel
  return f.block_id;
};

if (phase === '1') {
  // Session A: a shell and the fake agent Alpha. Session B: a shell only.
  const R = Date.now().toString(36), alpha = 'alpha' + R, NAME = 'Alpha-' + R; // a name unique to this run
  const A = (await c.call('session.create', {label: 'home-a-' + R, initial_windows: [{window_label: 'shell', layout: shell('shell')}]})).session_id;
  const B = (await c.call('session.create', {label: 'home-b-' + R, initial_windows: [{window_label: 'shell', layout: shell('shell')}]})).session_id;
  for (const s of [A, B]) await c.call('session.attach', {session_id: s, event_scope: 'session'});
  const w = await c.call('session.new_window', {session_id: A, window_label: NAME, focus: false,
    layout: {block: {flavor: 'com.superlogical.terminal.shell', label: alpha, options: {command: [`${LAB}/fake-agent.sh`, alpha]}}}});
  await waitFor('agent ready', () => fs.existsSync(`${LAB}/out/ready-${alpha}`));
  fs.writeFileSync(`${LAB}/out/fifo-${alpha}`, `rex -S ${SOCK} --autostart=false -C ${hubId} do hub.identity.report --args '{"kind":"claude","conversation_id":"${alpha}","source":"startup","block":"${w.block_ids[0]}"}' > ${LAB}/out/rep-${alpha} 2>&1\n`);
  await waitFor('identity reported', () => fs.existsSync(`${LAB}/out/rep-${alpha}`) && fs.readFileSync(`${LAB}/out/rep-${alpha}`, 'utf8').includes('current'));
  const agent = `claude:${alpha}`, tab = `thread/${agent}`;
  const shellOf = async s => (await c.call('session.view', {session_id: s})).windows.find(x => x.label === 'shell').focused_block_id;

  // 1. New Thread from A with Alpha: the thread opens in A and has focus.
  let f = await palette('new_thread', A, await shellOf(A));
  await waitFor('Alpha listed in A', () => checkboxes(A, f).some(l => l.includes(R)));
  console.log('A checkboxes:', checkboxes(A, f));
  submit(A, f, R);
  const v1 = await waitFor('thread view in A', async () => { const v = await threadView(tab); return v?.session_id === A && v; });
  await waitFor('thread focused in A', async () => (await active(A)) === v1.window_id);

  // 2. The same direct thread from B: no view in B; the thread in A shows.
  await c.call('session.focus_window', {session_id: A, window_id: w.window_id}); // A shows another tab
  assert.equal(await active(A), w.window_id);
  f = await palette('new_thread', B, await shellOf(B));
  assert(!checkboxes(B, f).some(l => l.includes(R)), 'an agent of another session is hidden first');
  await waitFor('B form controls', () => checkboxes(B, f).length === 1);
  press(B, f, 'tab', 'space'); // show agents in other sessions
  await waitFor('agents of other sessions shown', () => checkboxes(B, f).length > 1);
  submit(B, f, R);
  await waitFor('B form closed', async () => !(await formBlock(B)));
  const v2 = await threadView(tab);
  assert.equal(v2?.session_id, A, 'the thread stays in A');
  assert.equal(v2.view_id, v1.view_id, 'the same view');
  assert(!(await describe()).views.some(v => v.tab === tab && v.status === 'open' && v.session_id === B), 'no thread view in B');
  await waitFor('the thread shows in A', async () => (await active(A)) === v1.window_id);

  // 3. Threads… in A lists the thread; in B it does not.
  f = await palette('threads', A, await shellOf(A));
  await waitFor('Threads… in A lists Alpha', () => screen(A, f).includes(R));
  press(A, f, 'ctrl+q');
  f = await palette('threads', B, await shellOf(B));
  await sleep(500);
  assert(!screen(B, f).includes(R), 'Threads… in B omits the thread: ' + screen(B, f));
  press(B, f, 'ctrl+q');

  // 4. Threads… in the default Messages session lists unhomed threads (the team group), not A's.
  const d = await describe(), home = d.views.find(v => v.tab === 'home' && v.status === 'open' && v.block_id);
  assert(home, 'the Messages tab is open');
  f = await palette('threads', d.default_session_id, home.block_id);
  await waitFor('unhomed thread listed', () => /unread/.test(screen(d.default_session_id, f)));
  assert(!screen(d.default_session_id, f).includes(R), 'A\'s thread is not in the default session');
  press(d.default_session_id, f, 'ctrl+q');

  // 5. The user closes the thread tab.
  const v = await threadView(tab);
  await c.call('block.close', {session_id: A, block_id: v.block_id});
  await waitFor('closed', async () => !(await threadView(tab)));
  fs.writeFileSync(STATE, JSON.stringify({A, B, alpha, agent, tab, R}));
  console.log('PASS: phase 1. Restart the hub, then run phase 2.');
} else {
  const {A, B, alpha, agent, tab, R} = JSON.parse(fs.readFileSync(STATE, 'utf8'));
  for (const s of [A, B]) await c.call('session.attach', {session_id: s, event_scope: 'session'});
  // 6. After the restart, the same revision keeps the thread closed.
  await sleep(3000);
  assert.equal(await threadView(tab), undefined, 'closed across the restart');
  // 7. A real message from Alpha reopens it in A, without focus.
  const before = await active(A);
  fs.writeFileSync(`${LAB}/out/fifo-${alpha}`, `rex -S ${SOCK} --autostart=false -C lazyrex do messaging.send --args '{"to":"user","body":"reopen please","key":"reopen-${Date.now()}"}' > ${LAB}/out/send-${alpha} 2>&1\n`);
  const v = await waitFor('reopened by a message', async () => { const x = await threadView(tab); return x?.session_id === A && x; }, 20000);
  await sleep(1000);
  assert.notEqual(await active(A), v.window_id, 'a reopen does not take focus');
  assert.equal(await active(A), before, 'the active tab did not change');
  // 8. Close again; Threads… Open reopens it and shows it.
  await c.call('block.close', {session_id: A, block_id: v.block_id});
  await waitFor('closed again', async () => !(await threadView(tab)));
  const shellBlock = (await c.call('session.view', {session_id: A})).windows.find(x => x.label === 'shell').focused_block_id;
  const f = await palette('threads', A, shellBlock);
  await waitFor('listed', () => screen(A, f).includes(R));
  press(A, f, 'enter');
  const v3 = await waitFor('Open reopens', async () => { const x = await threadView(tab); return x?.session_id === A && x; });
  await waitFor('Open shows it', async () => (await active(A)) === v3.window_id);
  // 9. A form from the thread menu keeps the thread's unsent draft (Codex: source draft check).
  const DRAFT = 'draft' + R;
  await waitFor('thread rendered', () => screen(A, v3.block_id).includes('Ctrl+Qquit'));
  press(A, v3.block_id, 'tab'); // from the thread menu button to the composer
  await sleep(500); // keys right after the Tab were lost in the lab
  press(A, v3.block_id, ...DRAFT);
  await waitFor('draft typed', () => screen(A, v3.block_id).includes(DRAFT));
  const before9 = new Set((await formBlocks(A)).map(x => x.block_id));
  press(A, v3.block_id, 'f2');
  await waitFor('thread menu', () => /Rename/.test(screen(A, v3.block_id)));
  press(A, v3.block_id, 'enter'); // the first menu item: Rename
  const fr = await waitFor('rename form', async () => (await formBlocks(A)).find(x => !before9.has(x.block_id)));
  await waitFor('rename form rendered', () => screen(A, fr.block_id).includes('Savetitle'));
  press(A, fr.block_id, 'ctrl+q');
  await waitFor('rename form gone', async () => !(await formBlocks(A)).some(x => x.block_id === fr.block_id));
  assert(screen(A, v3.block_id).includes(DRAFT), 'the draft survives the form: ' + screen(A, v3.block_id));

  for (const s of [A, B]) await c.call('session.destroy', {session_id: s}).catch(() => {});
  console.log('PASS: phase 2');
}
c.close();
