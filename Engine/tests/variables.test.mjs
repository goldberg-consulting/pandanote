import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const engine = fileURLToPath(new URL('../runtime/out/pandanote-engine.cjs',import.meta.url));
function fixture(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'pandanote-variables-')));
  t.after(() => fs.rmSync(root,{recursive:true,force:true}));
  const file = path.join(root,'Test.md');
  fs.writeFileSync(file,'# Test');
  const call = (action,text,extra={}) => {
    const result = spawnSync(process.execPath,[engine],{ input:JSON.stringify({ action,root,file,text,...extra }),encoding:'utf8',timeout:45000,
      env:{...process.env,PATH:`/opt/homebrew/bin:/usr/bin:${process.env.PATH}`} });
    assert.ifError(result.error);
    assert.ok(result.stdout,'Engine returned no data: '+result.stderr);
    return JSON.parse(result.stdout);
  };
  return {root,file,call};
}

test('plain Python captures arithmetic without changing stdout and creates durable IDs',t => {
  const {call} = fixture(t);
  const first = call('run','```python\na = 1+4/2\nb = 23\nc = a/b\nprint(c)\n```',{trusted:true});
  assert.equal(first.success,true,JSON.stringify(first));
  assert.match(first.text,/```\{python id="run-[a-f0-9-]+"\}/);
  assert.equal(first.results[0].stdout,'0.13043478260869565\n');
  const block = first.variableBlocks[0];
  assert.equal(block.status,'current',JSON.stringify(block));
  assert.deepEqual(block.variables.map(value => [value.name,value.type,value.preview]),[['a','float','3.0'],['b','int','23'],['c','float','0.13043478260869565']]);
  for (const variable of block.variables) {
    assert.match(variable.id,/^pv_[a-f0-9]{24}$/);
    assert.equal(variable.reference,'{{'+variable.id+'}}');
    assert.equal(variable.reusable,true);
  }
  const preview = call('preview',first.text+'\n\nResult: '+block.variables[2].reference);
  assert.equal(preview.variableBlocks[0].status,'current');
  assert.match(preview.html,/Result: 0\.13043478260869565/);
  assert.doesNotMatch(preview.html,/documentIdentity|schemaVersion|pandanote-variables/);
  const cached = call('run',first.text,{trusted:true});
  assert.equal(cached.results[0].cached,true);
  assert.equal(cached.variableBlocks[0].runID,block.runID);
  assert.equal(cached.variableBlocks[0].variables[2].id,block.variables[2].id);
});

test('variable IDs differ across blocks and notes and survive value changes',t => {
  const {root,call} = fixture(t);
  const source = '```{python id="first"}\na=1\n```\n\n```{python id="second"}\na=2\n```';
  const first = call('run',source,{trusted:true});
  assert.equal(first.success,true);
  const ids = first.variableBlocks.map(block => block.variables[0].id);
  assert.notEqual(ids[0],ids[1]);
  const secondFile = path.join(root,'Other.md'); fs.writeFileSync(secondFile,source);
  const other = call('run',source,{trusted:true,file:secondFile});
  assert.notEqual(other.variableBlocks[0].variables[0].id,ids[0]);
  const changed = call('run',source.replace('a=1','a=5'),{trusted:true});
  assert.equal(changed.variableBlocks[0].variables[0].id,ids[0]);
  assert.notEqual(changed.variableBlocks[0].runID,first.variableBlocks[0].runID);
  assert.equal(changed.variableBlocks[0].variables[0].preview,'5');
});

test('explicit dependencies restore typed collections, booleans and large integers in namespaces',t => {
  const {call} = fixture(t);
  const source = [
    '```{python id="analysis"}',
    'a = 3.0\nvalues = [1, 2, {"ok": True, "empty": None}]\nbig = 10**40\nname = "hello"',
    '```',
    '```{python id="use" depends-on="analysis"}',
    'data = pandanote["analysis"]\nc = data["a"] / 23\nassert data["values"][2]["ok"] is True\nassert data["values"][2]["empty"] is None\nassert data["big"] == 10**40\nprint(c)\nprint(type(data["big"]).__name__)\nprint(data["name"])',
    '```',
  ].join('\n');
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  assert.equal(result.results[1].stdout,'0.13043478260869565\nint\nhello\n');
  assert.equal(result.variableBlocks[1].status,'current',JSON.stringify(result.variableBlocks));
  const list = result.variableBlocks[0].variables.find(item => item.name === 'values');
  assert.equal(list.preview,'[1, 2, {"ok": true, "empty": null}]');
  assert.match(result.variableBlocks[1].variables.find(item => item.name === 'data').preview,/"big": 10000000000000000000000000000000000000000/);
  const preview = call('preview',source+'\n\n'+list.reference);
  assert.match(preview.html,/\[1, 2, \{&quot;ok&quot;: true, &quot;empty&quot;: null\}\]|\[1, 2, \{“ok”: true, “empty”: null\}\]/);
  const stale = call('preview',source.replace('a = 3.0','a = 4.0'));
  assert.deepEqual(stale.variableBlocks.map(block => block.status),['stale','stale']);
  const rerun = call('run',source.replace('a = 3.0','a = 4.0'),{trusted:true});
  assert.equal(rerun.success,true);
  assert.equal(rerun.results[1].cached,false);
  assert.equal(rerun.results[1].stdout.split('\n')[0],String(4/23));
});

test('blocks do not silently share globals without depends-on',t => {
  const {call} = fixture(t);
  const result = call('run','```{python id="first"}\na=23\n```\n```{python id="second"}\nassert not pandanote\nassert not pandanote_vars\nprint(a)\n```',{trusted:true});
  assert.equal(result.success,false);
  assert.deepEqual(result.variableBlocks.map(block => block.status),['current','failed']);
  assert.match(result.results[1].stderr,/NameError/);
});

test('outer fences shield nested runnable examples and leave non-Python fences unchanged',t => {
  const {root,call} = fixture(t);
  const source = '````markdown\n```python\nopen("should-not-exist", "w").write("bad")\n```\n```{python id="nested"}\nraise Exception("bad")\n```\n````\n\n~~~python\na=23\n~~~\n\n```json\n{"a":1}\n```';
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  assert.equal(result.results.length,1);
  assert.equal(result.variableBlocks.length,1);
  assert.equal(result.variableBlocks[0].variables[0].preview,'23');
  assert.ok(!fs.existsSync(path.join(root,'should-not-exist')));
  assert.ok(result.text.startsWith(source.split('\n\n')[0]));
  assert.ok(result.text.endsWith('```json\n{"a":1}\n```'));
});

test('failed plain Python returns assigned IDs and keeps successful block snapshots',t => {
  const {call} = fixture(t);
  const result = call('run','```python\na=23\n```\n\n```python\nb=3\nraise ValueError("intentional")\n```',{trusted:true});
  assert.equal(result.success,false);
  assert.equal((result.text.match(/id="/g)||[]).length,2);
  assert.deepEqual(result.variableBlocks.map(block => block.status),['current','failed']);
  assert.equal(result.variableBlocks[1].variables.length,0);
  const preview = call('preview',result.text);
  assert.equal(preview.variableBlocks[0].status,'current');
});

test('unsupported objects, cycles and large values are inspected without calling repr',t => {
  const {root,call} = fixture(t);
  const source = '```{python id="objects"}\nclass Dangerous:\n    def __repr__(self):\n        open("repr-was-called", "w").write("bad")\n        raise Exception("repr")\nthing = Dangerous()\ncycle = []\ncycle.append(cycle)\nlarge = "x" * 100000\nimport math\nfinite = 1.5\nnot_finite = float("nan")\n```';
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  assert.ok(!fs.existsSync(path.join(root,'repr-was-called')));
  const values = result.variableBlocks[0].variables;
  assert.ok(!values.some(value => value.name === 'math'));
  for (const name of ['thing','cycle','large','not_finite']) assert.equal(values.find(value => value.name === name).reusable,false,name);
  assert.equal(values.find(value => value.name === 'thing').preview,'<Dangerous>');
  assert.equal(values.find(value => value.name === 'finite').reusable,true);
});

test('tampered snapshots cannot be inspected, injected, or reused',t => {
  const {call} = fixture(t);
  const source = '```{python id="analysis"}\na=23\n```';
  const result = call('run',source,{trusted:true});
  const reference = result.variableBlocks[0].variables[0].reference;
  const artifact = result.results[0].artifacts['pandanote-variables'];
  fs.appendFileSync(artifact,' ');
  const preview = call('preview',source+'\n\n'+reference);
  assert.equal(preview.variableBlocks[0].variables.length,0);
  assert.equal(preview.variableBlocks[0].status,'not-run');
  assert.ok(preview.html.includes(reference));
});

test('cached preview does not launch a changed interpreter or inline Python',t => {
  const {root,call} = fixture(t);
  fs.mkdirSync(path.join(root,'env','bin'),{recursive:true});
  const interpreter = path.join(root,'env','bin','python3');
  fs.writeFileSync(interpreter,'#!/bin/sh\nexec /usr/bin/python3 "$@"\n',{mode:0o755});
  const source = '```{python id="analysis" env="env"}\na=23\n```';
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  fs.writeFileSync(interpreter,'#!/bin/sh\ntouch "'+path.join(root,'interpreter-was-launched')+'"\nexit 1\n',{mode:0o755});
  const preview = call('preview',source+'\n\n`{python} open("inline-was-launched", "w").write("bad")`');
  assert.equal(preview.success,true);
  assert.ok(!fs.existsSync(path.join(root,'interpreter-was-launched')));
  assert.ok(!fs.existsSync(path.join(root,'inline-was-launched')));
  assert.equal(preview.variableBlocks[0].status,'stale');
});

test('long Python fences retain their delimiter around embedded triple-backtick lines',t => {
  const {call} = fixture(t);
  const source = '  ````python\ntext = """\n```\n"""\na=23\n  ````';
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  assert.match(result.text,/^  ````\{python id="/);
  assert.ok(result.text.endsWith('  ````'));
  assert.equal(result.variableBlocks[0].variables.find(value => value.name === 'a').preview,'23');
});

test('a failed rerun cannot revive last successful variables in preview',t => {
  const {root,call} = fixture(t);
  const source = '```{python id="analysis" cache="false"}\nfrom pathlib import Path\nif Path("fail-now").exists():\n    raise ValueError("later failure")\na=23\n```';
  const first = call('run',source,{trusted:true});
  assert.equal(first.success,true);
  const reference = first.variableBlocks[0].variables.find(value => value.name === 'a').reference;
  fs.writeFileSync(path.join(root,'fail-now'),'fail');
  const failed = call('run',source,{trusted:true});
  assert.equal(failed.success,false);
  assert.equal(failed.variableBlocks[0].status,'failed');
  const preview = call('preview',source+'\n\n'+reference);
  assert.equal(preview.variableBlocks[0].status,'failed');
  assert.equal(preview.variableBlocks[0].variables.find(value => value.name === 'a').reusable,false);
  assert.ok(preview.html.includes(reference));
});

test('new glob matches and changed declared inputs invalidate saved variables',t => {
  const {root,call} = fixture(t);
  fs.mkdirSync(path.join(root,'data'));
  fs.writeFileSync(path.join(root,'data','a.csv'),'1');
  const source = '```{python id="analysis" inputs="data/*.csv"}\na=23\n```';
  const first = call('run',source,{trusted:true});
  assert.equal(first.success,true,JSON.stringify(first));
  assert.equal(first.variableBlocks[0].status,'current');
  fs.writeFileSync(path.join(root,'data','b.csv'),'2');
  assert.equal(call('preview',source).variableBlocks[0].status,'stale');
  const refreshed = call('run',source,{trusted:true});
  assert.equal(refreshed.success,true);
  assert.equal(refreshed.results[0].cached,false);
  assert.equal(refreshed.variableBlocks[0].status,'current');
  assert.equal(call('preview',source.replace('data/*.csv','data/a.csv')).variableBlocks[0].status,'stale');
});

test('lockfile creation and changes invalidate variables without executing code',t => {
  const {root,call} = fixture(t);
  const source = '```{python id="analysis"}\na=23\n```';
  const first = call('run',source,{trusted:true});
  assert.equal(first.success,true);
  const reference = first.variableBlocks[0].variables[0].reference;
  fs.writeFileSync(path.join(root,'requirements.txt'),'# changed environment\n');
  const preview = call('preview',source+'\n\n'+reference);
  assert.equal(preview.variableBlocks[0].status,'stale');
  assert.ok(preview.html.includes(reference));
  const rerun = call('run',source,{trusted:true});
  assert.equal(rerun.success,true);
  assert.equal(rerun.variableBlocks[0].status,'current');
  fs.writeFileSync(path.join(root,'requirements.txt'),'# changed again\n');
  assert.equal(call('preview',source).variableBlocks[0].status,'stale');
});

test('typed dependency snapshots retain negative zero and support hashed Python references',t => {
  const {call} = fixture(t);
  const first = call('run','```{python id="analysis"}\na=-0.0\n```',{trusted:true});
  assert.equal(first.success,true);
  const value = first.variableBlocks[0].variables[0];
  const source = '```{python id="analysis"}\na=-0.0\n```\n```{python id="use" depends-on="analysis"}\nimport math\nprint(math.copysign(1, pandanote["analysis"]["a"]))\nprint(math.copysign(1, pandanote_vars["'+value.id+'"]))\n```';
  const result = call('run',source,{trusted:true});
  assert.equal(result.success,true,JSON.stringify(result));
  assert.equal(result.results[1].stdout,'-1.0\n-1.0\n');
  assert.match(call('preview',source+'\n\n'+value.reference).html,/-0\.0/);
});
