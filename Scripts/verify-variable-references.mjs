// Real toolchain check: readable/formatted cell references agree in preview and PDF.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const engine = fileURLToPath(new URL('../Engine/runtime/out/pandanote-engine.cjs',import.meta.url));
const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(),'pandanote-reference-publication-')));
const file = path.join(root,'References.md');
const text = [
  '---\ntitle: Cell reference verification\ntemplate: default\n---',
  '```{python id="sessions" display="none"}\naverage = 25.0\n```',
  '```{python id="planning" depends-on="sessions" display="none"}',
  'weekly_sessions = 5\nweekly_minutes = pandanote["sessions"]["average"] * weekly_sessions\nratio = 0.256\nbig = 9007199254740993', '```',
  'Five sessions would take {planning.weekly_minutes:.0f} minutes.',
  'Precise: {planning.weekly_minutes:.2f}. Ratio: {planning.ratio:.1%}.',
  'Exact integer: {planning.big:,d}. Scientific: {planning.weekly_minutes:.2e}.',
  'Inline Python still works: `{python} 2 + 3`.',
  'Literal example: `{planning.weekly_minutes:.0f}`.',
  'Missing: {planning.missing}. Invalid: {planning.weekly_minutes:.99f}.',
].join('\n\n');
fs.writeFileSync(file,text);
const env = {...process.env,PATH:`/opt/homebrew/bin:${os.homedir()}/Library/TinyTeX/bin/universal-darwin:/Library/TeX/texbin:${process.env.PATH}`};
const call = (action, trusted = false) => {
  const run = spawnSync(process.execPath,[engine],{input:JSON.stringify({action,root,file,text,trusted}),encoding:'utf8',env,timeout:120000,maxBuffer:8*1024*1024});
  assert.ifError(run.error);
  assert.equal(run.status,0,run.stderr);
  const result = JSON.parse(run.stdout);
  fs.writeFileSync(path.join(root,action+'.json'),JSON.stringify(result,null,2));
  assert.equal(result.success,true,JSON.stringify(result));
  return result;
};
call('run',true);
const preview = call('preview');
assert.match(preview.html,/Five sessions would take 125 minutes/);
assert.match(preview.html,/Precise: 125\.00\. Ratio: 25\.6%/);
assert.match(preview.html,/Exact integer: 9,007,199,254,740,993\. Scientific: 1\.25e\+02/);
const result = call('compile',true);
let extracted = spawnSync('pdftotext',[result.pdfPath,'-'],{encoding:'utf8',env,timeout:15000});
if (extracted.error?.code === 'ENOENT') {
  const helper = path.join(root,'extract.swift');
  fs.writeFileSync(helper,'import PDFKit\nimport Foundation\nguard let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments.last!)), let text = document.string else { exit(1) }\nprint(text)\n');
  extracted = spawnSync('swift',['-module-cache-path',path.join(os.tmpdir(),'pandanote-pdfkit-module-cache'),helper,result.pdfPath],{encoding:'utf8',env,timeout:120000});
}
assert.ifError(extracted.error); assert.equal(extracted.status,0,extracted.stderr);
const body = extracted.stdout.replace(/\s+/g,' ');
for (const expected of ['Five sessions would take 125 minutes.','Precise: 125.00. Ratio: 25.6%.','9,007,199,254,740,993','1.25e+02','Inline Python still works: 5.','{planning.weekly_minutes:.0f}']) assert.ok(body.includes(expected),expected+' missing from PDF: '+body);
assert.ok(result.errors?.some(error => error.message.includes('{planning.missing}')));
assert.ok(result.errors?.some(error => error.message.includes('{planning.weekly_minutes:.99f}')));
console.log('Readable references, numeric formatting, exact integers, legacy inline Python, literal examples, and unresolved-reference warnings verified in a real PDF.');
console.log('Verification artifacts: '+root);
