const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('dashboard.html', 'utf8');
const match = html.match(/\/\/ <pure>([\s\S]*?)\/\/ <\/pure>/);
assert.ok(match, 'dashboard.html must expose pure functions');
const context = { window: {} };
vm.runInNewContext(match[1] + '\nwindow.api = {reduceStatus, latestActivity, quotaLevel, ageText, parseJsonl, conversation, rootAgents, eventsFromResponse, eventFetchError};', context);
const {reduceStatus, latestActivity, quotaLevel, ageText, parseJsonl, conversation, rootAgents, eventsFromResponse, eventFetchError} = context.window.api;
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
console.log('ok');
