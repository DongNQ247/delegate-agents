const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('scripts/dashboard.html', 'utf8');
const match = html.match(/\/\/ <pure>([\s\S]*?)\/\/ <\/pure>/);
assert.ok(match, 'dashboard.html must expose pure functions');
const context = { window: {} };
vm.runInNewContext(match[1] + '\nwindow.api = {reduceStatus, latestActivity, quotaLevel, ageText, parseJsonl, conversation, rootAgents, eventsFromResponse, eventFetchError, statusGroup, filterTree, sortSiblings, counts, agyPoolView, waveTag, statusLabel};', context);
const {reduceStatus, latestActivity, quotaLevel, ageText, parseJsonl, conversation, rootAgents, eventsFromResponse, eventFetchError, statusGroup, filterTree, sortSiblings, counts, agyPoolView, waveTag, statusLabel} = context.window.api;
assert.equal(eventFetchError('a.events.jsonl', '404'), '');
assert.equal(eventFetchError('quota.json', '404'), '404');
assert.equal(quotaLevel(0.69, '5h'), 'ok');
assert.equal(quotaLevel(0.70, '5h'), 'warn');
assert.equal(quotaLevel(0.85, '5h'), 'hot');
assert.equal(quotaLevel(0.89, 'week'), 'warn');
assert.equal(quotaLevel(0.90, 'week'), 'hot');
assert.equal(latestActivity([{kind:'command',text:'pytest'},{kind:'end',text:''}]), 'pytest');
assert.equal(latestActivity([]), '');
assert.equal(parseJsonl('{"a":1}\n{"b"').length, 1);
const agents = reduceStatus('{"id":"a","ts":1,"status":"running"}\n{"id":"a","ts":2,"status":"done"}\n{"id"');
assert.equal(agents.a.status, 'done');
assert.equal(agents.a.start, 1);
assert.deepEqual(Array.from(conversation([{kind:'command',text:'x'},{kind:'message',text:'y'}]), e => e.kind), ['message']);
assert.equal(ageText(30), 'just now');
assert.equal(ageText(300), '5 min ago');
assert.deepEqual(Array.from(rootAgents({
  root: {id:'root', parent:'-'},
  child: {id:'child', parent:'root'},
  orphan: {id:'orphan', parent:'missing'}
}), a => a.id), ['root', 'orphan']);
assert.deepEqual(Array.from(eventsFromResponse(null), e => e.kind), []);
assert.deepEqual(Array.from(eventsFromResponse('{"kind":"message"}'), e => e.kind), ['message']);
assert.equal(statusGroup('timeout'), 'failed');
assert.equal(statusGroup('done'), 'done');
assert.equal(statusGroup('cancelled'), 'failed');
assert.equal(statusLabel('cancelled'), 'cancelled');
assert.equal(statusLabel('timeout'), 'timeout');
assert.equal(statusLabel('failed'), '✗');
assert.equal(statusLabel('done'), '✓');
assert.equal(statusLabel('running'), '');
const filteredAgents = {
  p: {id:'p', status:'done', parent:'-'},
  c: {id:'c', status:'running', parent:'p'},
  f: {id:'f', status:'failed', parent:'p'}
};
assert.deepEqual(Array.from(filterTree(filteredAgents, 'running')).sort(), ['c', 'p']);
assert.deepEqual(Array.from(filterTree(filteredAgents, 'failed')).sort(), ['f', 'p']);
assert.deepEqual(Array.from(filterTree(filteredAgents, 'all')).sort(), ['c', 'f', 'p']);
const siblings = [
  {id:'done', status:'done', start:70, end:100},
  {id:'run10', status:'running', start:90},
  {id:'failed', status:'failed', start:0, end:1},
  {id:'run100', status:'running', start:0}
];
assert.deepEqual(Array.from(sortSiblings(siblings, 100), a => a.id), ['run100', 'run10', 'failed', 'done']);
assert.deepEqual({...counts({a:{status:'running'},b:{status:'timeout'},c:{status:'done'}})}, {running:1, done:1, failed:1, all:3});
const pool = agyPoolView({five_hour:{used:0.17, resets_at:200}, updated:100}, 150);
assert.equal(pool.five_hour.level, 'ok');
assert.equal(pool.week, null);
assert.equal(agyPoolView({five_hour:{used:0.17, resets_at:100}, updated:50}, 150), null);
console.log('ok');
assert.equal(waveTag({wave: '2'}), 'wave 2');
assert.equal(waveTag({}), '');
assert.equal(statusLabel('rotate'), 'rotate');
