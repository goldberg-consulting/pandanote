import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const engine = fileURLToPath(new URL('../runtime/out/pandanote-engine.cjs', import.meta.url));
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pandanote-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const file = path.join(root, 'Test.md'); fs.writeFileSync(file, '# Test');
  const call = (action, text = '# Test', extra = {}) => {
    const run = spawnSync(process.execPath, [engine], { input: JSON.stringify({ action, root, file, text, ...extra }), encoding: 'utf8', timeout: 45000, env: { ...process.env, PATH: `/opt/homebrew/bin:${process.env.PATH}` } });
    assert.ifError(run.error); return JSON.parse(run.stdout);
  };
  return { root, file, call };
}
test('preview renders GFM and math while disabling scripts and remote images', t => {
  const { call } = fixture(t);
  const result = call('preview', '# Heading\n\n~~deleted~~ and $x^2$.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n<script>alert(1)</script>\n![tracking](https://example.com/pixel.png)');
  assert.equal(result.success, true);
  assert.match(result.html, /<table>/); assert.match(result.html, /<math/); assert.match(result.html, /<s>deleted<\/s>/);
  assert.doesNotMatch(result.html, /<script|src="https:/);
  assert.match(result.html, /script-src 'none'/);
});
test('preview preserves currency in prose, emphasis, and tables alongside real math', t => {
  const { call } = fixture(t);
  const result = call('preview', [
    'Prices are $20 and $30, with a range of $20–$30.',
    '**$20** plus **$30**.',
    '| Item | Price |\n|---|---|\n| Sample | $20 plus $30 |',
    'The formula is $x^2$, and prices remain $20 and $30.',
    '$$ x^2 + y^2 $$',
  ].join('\n\n'));
  assert.equal(result.success, true);
  assert.match(result.html, /Prices are \$20 and \$30, with a range of \$20–\$30\./);
  assert.match(result.html, /<strong>\$20<\/strong> plus <strong>\$30<\/strong>/);
  assert.match(result.html, /<td>\$20 plus \$30<\/td>/);
  assert.match(result.html, /and prices remain \$20 and \$30\./);
  assert.equal((result.html.match(/<math\b/g) || []).length, 2);
  assert.match(result.html, /<math[^>]*display="block"/);
});
test('preview rejects invalid inline delimiters without swallowing later math', t => {
  const { call } = fixture(t);
  for (const source of ['$ 2 + 3$', '$x $', '$x$20', '$$x$', '$$unclosed']) {
    const result = call('preview', source);
    assert.equal(result.success, true);
    assert.doesNotMatch(result.html, /<math\b/, source);
    assert.ok(result.html.includes(source), source);
  }
  const result = call('preview', '$20 and $30; then $x^2$.\n\n$$unclosed $y^2$.');
  assert.match(result.html, /\$20 and \$30; then /);
  assert.match(result.html, /\$\$unclosed /);
  assert.equal((result.html.match(/<math\b/g) || []).length, 2);
});
test('preview keeps inline math within a single line across soft and hard breaks', t => {
  const { call } = fixture(t);
  for (const source of ['$x\ny$', '$x\\\ny$']) {
    const result = call('preview', source);
    assert.equal(result.success, true);
    assert.doesNotMatch(result.html, /<math\b/, source);
    assert.match(result.html, /\$x/);
    assert.match(result.html, /y\$/);
  }
});
test('preview respects escaped dollars and backslash parity', t => {
  const { call } = fixture(t);
  for (const source of [String.raw`\$20 and \$30`, String.raw`\$x$`, String.raw`\\\$x$`]) {
    const result = call('preview', source);
    assert.equal(result.success, true);
    assert.doesNotMatch(result.html, /<math\b/, source);
  }
  for (const source of [String.raw`\\$x$`, String.raw`$x\$y$`, String.raw`$x\\$`, String.raw`$x\\\$y$`]) {
    const result = call('preview', source);
    assert.equal(result.success, true);
    assert.equal((result.html.match(/<math\b/g) || []).length, 1, source);
    assert.doesNotMatch(result.html, /class="katex-error"/, source);
  }
});
test('preview leaves math and currency inside code literal', t => {
  const { call } = fixture(t);
  const result = call('preview', '`$20 and $30; $x^2$; $$y$$`\n\n```text\n$20 and $30\n$x^2$\n$$y$$\n```');
  assert.equal(result.success, true);
  assert.doesNotMatch(result.html, /<math\b/);
  assert.match(result.html, /<code>\$20 and \$30; \$x\^2\$; \$\$y\$\$<\/code>/);
  assert.match(result.html, /\$20 and \$30\n\$x\^2\$\n\$\$y\$\$/);
});
test('preview never evaluates inline Python from an opened document', t => {
  const { root, call } = fixture(t);
  const marker = path.join(root, 'SHOULD_NOT_EXIST');
  const source = '`{python} __import__("pathlib").Path(' + JSON.stringify(marker) + ').write_text("unsafe")`';
  assert.equal(call('preview', source).success, true);
  assert.equal(fs.existsSync(marker), false);
  assert.equal(call('run', source).success, false);
});
test('setup is repeatable and preserves user-owned files', t => {
  const { root, call } = fixture(t);
  assert.equal(call('setup').success, true);
  const refs = path.join(root, '.inkwell/references/refs.bib');
  fs.writeFileSync(refs, '@book{mine,title={My book},year={2026}}');
  assert.equal(call('setup').success, true);
  assert.match(fs.readFileSync(refs, 'utf8'), /My book/);
  assert.ok(call('templates').templates.length >= 7);
});
test('execution uses Inkwell stable identities and invalidates changed source', t => {
  const { call } = fixture(t);
  call('setup');
  const source = '```{node id="test-run" display="both"}\nconsole.log("original");\n```';
  const first = call('run', source, { trusted: true });
  assert.equal(first.success, true); assert.match(first.results[0].stdout, /original/);
  const cached = call('run', source, { trusted: true });
  assert.equal(cached.results[0].cached, true);
  const changed = call('run', source.replace('original', 'changed'), { trusted: true });
  assert.match(changed.results[0].stdout, /changed/); assert.equal(changed.results[0].cached, false);
});
test('symlinked documents outside the chosen vault are rejected', t => {
  const { root, call } = fixture(t);
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'pandanote-outside-'));
  t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
  fs.writeFileSync(path.join(outside, 'Private.md'), 'Private');
  const alias = path.join(root, 'Alias.md'); fs.symlinkSync(path.join(outside, 'Private.md'), alias);
  assert.equal(call('preview', 'Private', { file: alias }).success, false);
});
test('starter preamble makes settings explicit without replacing the note body', t => {
  const {call} = fixture(t);
  const body = '\uFEFF# 🐼 A paper\r\n\r\nKeep this body exactly.\r\n';
  const result = call('edit-settings',body,{starter:true});
  assert.equal(result.success,true,result.message);
  assert.equal(result.template,'default'); assert.equal(result.engine,'xelatex');
  assert.match(result.yaml,/fontsize: 11pt/); assert.match(result.yaml,/code-display: output/);
  assert.ok(result.text.endsWith(body.slice(1))); assert.ok(result.text.startsWith('\uFEFF---\r\n'));
  assert.equal(call('edit-settings',result.text,{starter:true}).text,result.text);
});
test('controls use Inkwell alias precedence and preserve comments, custom metadata, and body bytes', t => {
  const {call} = fixture(t);
  const source='---\ntitle: Original # keep title comment\ncustom: {mine: true}\nfontsize: 10pt\ninkwell.typography.body-size: 11pt # strongest spelling\n---\n\n# 🐼 Body\n\n```python\nprint(1)\n```\n';
  const result=call('edit-settings',source,{changes:[{key:'typography.bodySize',value:'12pt'},{key:'title',value:'Revised title'},{key:'references.bibliography',value:'library.bib\nsecond.bib'},{key:'tables.stripe',value:'true'}]});
  assert.equal(result.success,true,result.message);
  assert.equal(result.controls.find(c=>c.key==='typography.bodySize').value,'12pt');
  assert.equal(result.controls.find(c=>c.key==='references.bibliography').value,'library.bib\nsecond.bib');
  assert.equal(result.controls.find(c=>c.key==='tables.stripe').value,'true');
  assert.match(result.text,/# strongest spelling/);assert.match(result.text,/# keep title comment/);assert.match(result.text,/mine: true/);
  assert.equal(result.text.slice(result.text.indexOf('\n---\n')+5),source.slice(source.indexOf('\n---\n')+5));
});
test('template selection changes the actual resolver and locked controls reject edits', t => {
  const {call}=fixture(t);
  const result=call('edit-settings','# Paper',{template:'rho'});
  assert.equal(result.success,true,result.message);assert.equal(result.template,'rho');
  const font=result.controls.find(c=>c.key==='typography.bodyFont');
  assert.equal(font.locked,true);assert.ok(font.reason);
  const invalid=call('edit-settings',result.text,{changes:[{key:font.key,value:'Helvetica'}]});
  assert.equal(invalid.success,false);
  assert.equal(call('edit-settings','# Paper',{template:'missing-template'}).success,false);
});
test('malformed YAML and invalid typed values are never returned as applicable edits', t => {
  const {call}=fixture(t);
  assert.equal(call('edit-settings','---\ntitle: [broken\n---\nBody',{changes:[{key:'title',value:'new'}]}).success,false);
  assert.equal(call('edit-settings','# Body',{yaml:'title: [broken'}).success,false);
  assert.equal(call('edit-settings','# Body',{changes:[{key:'typography.bodySize',value:'400pt'}]}).success,false);
  assert.equal(call('edit-settings','# Body',{changes:[{key:'tables.ruleThickness',value:'-4pt'}]}).success,false);
});
test('raw preamble preserves custom LaTeX and live preview follows resolved typography', t => {
  const {call}=fixture(t);
  const result=call('edit-settings','# Body\n',{yaml:'title: Test\nfontsize: 12pt\nmainfont: Georgia\nheader-includes: |\n  \\newcommand{\\panda}{Panda}\n'});
  assert.equal(result.success,true,result.message);assert.ok(result.text.endsWith('# Body\n'));
  assert.match(result.yaml,/\\newcommand\{\\panda\}/);
  const preview=call('preview',result.text);
  assert.match(preview.html,/--inkwell-body-font:"Georgia"/);
  assert.match(preview.html,/--inkwell-body-size:11\.955168pt/);
});
test('journal author fields use their real structured metadata without adding fictional names', t => {
  const {call}=fixture(t);
  const result=call('edit-settings','# Paper',{template:'rmxaa'});
  assert.equal(result.success,true,result.message);
  assert.equal(result.controls.find(c=>c.key==='author').locked,true);
  const authors=result.controls.find(c=>c.key==='rmxaa-authors');
  assert.equal(authors.kind,'yaml');assert.equal(authors.value,'');
  const edited=call('edit-settings',result.text,{changes:[{key:'rmxaa-authors',value:'- name: A Real Author\n  affiliations: 1\n'}]});
  assert.equal(edited.success,true,edited.message);assert.match(edited.yaml,/A Real Author/);
  assert.doesNotMatch(edited.yaml,/Author One|author@university/);
});
