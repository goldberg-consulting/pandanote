import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const root=path.resolve('build/PublicationVerification');
fs.mkdirSync(root,{recursive:true});
const engine=path.resolve('Engine/runtime/out/pandanote-engine.cjs');
const env={...process.env,PATH:`/opt/homebrew/bin:${process.env.HOME}/Library/TinyTeX/bin/universal-darwin:/Library/TeX/texbin:${process.env.PATH}`};
for (const template of ['default','rho','rmxaa']) {
  const file=path.join(root,template+'.md');
  let text=`# Results\n\nThis document uses the selected Inkwell template.\\panda{}\n\nThe equation is $E=mc^2$.\n\n| Group | Value |\n|---|---:|\n| A | 12 |\n| B | 24 |\n\n| Test | Outcome |\n|---|---|\n| Caption | Verified |\n\n: A table with a caption.\n`;
  fs.writeFileSync(file,text);
  const call=(action,extra={})=>{
    const run=spawnSync(process.execPath,[engine],{input:JSON.stringify({action,root,file,text,...extra}),encoding:'utf8',env,timeout:120000,maxBuffer:8*1024*1024});
    assert.ifError(run.error);
    const result=JSON.parse(run.stdout);
    fs.writeFileSync(path.join(root,template+'-'+action+'.json'),JSON.stringify(result,null,2));
    return result;
  };
  const changes=[{key:'title',value:'Pandanote publication verification'},{key:'header-includes',value:'\\newcommand{\\panda}{ The custom preamble is active.}'}];
  if(template==='default') changes.push({key:'typography.bodySize',value:'12pt'},{key:'typography.headingColor',value:'#234567'},{key:'tables.stripe',value:'true'});
  const settings=call('edit-settings',{template,changes});
  assert.equal(settings.success,true,settings.message);assert.equal(settings.template,template);
  text=settings.text;fs.writeFileSync(file,text);
  const result=call('compile',{trusted:true});
  console.log(JSON.stringify({template,engine:result.engine,success:result.success,message:result.message,errors:result.errors?.filter(e=>e.severity==='error'),pdf:result.pdfPath,log:result.logPath}));
  assert.equal(result.success,true,result.message);
  assert.equal(result.engine,template==='default'?'xelatex':'pdflatex');
  assert.ok(fs.readFileSync(result.pdfPath).subarray(0,5).equals(Buffer.from('%PDF-')));
  const tex=fs.readFileSync(path.join(path.dirname(result.logPath),template+'.tex'),'utf8');
  assert.match(tex,/\\newcommand\{\\panda\}/);
  if(template==='default') assert.match(tex,/234567/);
  fs.writeFileSync(path.join(root,template+'.tex'),tex);
}
