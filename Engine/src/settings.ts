import { isAlias, isMap, isNode, parseDocument, stringify } from 'yaml';
import { getDocumentConfig } from '../../Vendor/Inkwell/src/config';
import { parseDocumentFrontmatter, sizeToString } from '../../Vendor/Inkwell/src/document-config';
import { documentStyleControls, planDocumentStyleEdit, planFrontmatterSettingsEdit } from '../../Vendor/Inkwell/src/document-style';
import { TABLE_ATTRIBUTE_SCHEMA } from '../../Vendor/Inkwell/src/table-values';
import { TEMPLATE_FRONTMATTER } from '../../Vendor/Inkwell/src/scaffold-assets';
import { listTemplates } from '../../Vendor/Inkwell/src/templates';
import { Uri } from './native-host';

type Control = { key:string; label:string; group:string; value:string; prompt:string; kind:string; allowed?:string[]; locked?:boolean; reason?:string; source?:string };
const printable = (v:any):string => v == null ? '' : v.unit && v.value != null ? sizeToString(v) : Array.isArray(v) ? v.join('\n') : typeof v === 'object' ? JSON.stringify(v) : String(v);
const rootFields = [
  ['title','Title','Document','text','The title printed by your publication template.'],
  ['author','Author','Document','text','A name, or use YAML for a structured list of authors.'],
  ['date','Date','Document','text','A date or \\today for the compilation date.'],
  ['abstract','Abstract','Document','multiline','A short summary. Markdown and LaTeX are supported by your template.'],
  ['keywords','Keywords','Document','lines','One keyword per line.'],
  ['geometry','Page margins','LaTeX','text','For compatible templates, e.g. margin=1in or left=25mm,right=25mm.'],
  ['toc','Table of contents','LaTeX','boolean','Include a table of contents.'],
  ['lof','List of figures','LaTeX','boolean','Include a list of figures.'],
  ['lot','List of tables','LaTeX','boolean','Include a list of tables.'],
  ['numbersections','Number sections','LaTeX','boolean','Number your headings in the PDF.'],
  ['header-includes','Custom LaTeX preamble','LaTeX','multiline','Packages and commands, e.g. \\usepackage{siunitx}. Runs after Inkwell’s generated styling. Do not include \\begin{document}.'],
  ['inkwell.code-display','Code visibility','Code','choice','Choose what appears in the publication; individual blocks can override this.','output,both,code,none'],
  ['inkwell.code-bg','Code background','Code','text','A quoted hex color, e.g. #f5f5f5.'],
  ['inkwell.code-border','Code border','Code','boolean','Draw a border around code blocks.'],
  ['inkwell.code-rounded','Rounded code blocks','Code','boolean','Use rounded corners where supported by the template.'],
  ['inkwell.python-env','Python environment','Code','text','Optional environment path, relative to this document.'],
] as const;
const referenceFields = [
  ['bibliography','Bibliography files','lines','One .bib path per line, relative to this document.'],
  ['csl','Citation style','text','Path to a .csl file; leave untouched to use the template style.'],
  ['heading','Reference heading','text','For example References or Bibliography.'],
  ['scope','Reference scope','choice','One bibliography or a bibliography per section.','document,section'],
  ['links','Linked citations','boolean','Link citations to their reference entries.'],
  ['hangingIndent','Hanging indent','text','A length such as 1.5em.'],
  ['lineSpacing','Line spacing','number','A positive multiplier, for example 1.2.'],
  ['entrySpacing','Space between entries','text','A length such as 0.5em.'],
  ['pageBreak','Page break','choice','Start the bibliography on a fresh page.','auto,always,never'],
  ['nocite','Include uncited keys','lines','One citation key per line, or * to include every entry.'],
] as const;
function valueAt(object:any, key:string):any {
  if (object && Object.hasOwn(object,key)) return object[key];
  return key.split('.').reduce((value,part) => value?.[part],object);
}
export function settings(text:string, file:string) {
  const config = getDocumentConfig(text,file);
  const controls:Control[] = rootFields.map(([key,label,group,kind,prompt,allowed]) => {
    const value = key === 'inkwell.code-display' ? config.runs.display : key === 'inkwell.python-env' ? config.runs.pythonEnv : valueAt(config.metadata,key);
    const complex = value != null && typeof value === 'object' && kind !== 'lines';
    return { key,label,group,kind,prompt,allowed:allowed?.split(','), value:printable(value ?? (kind === 'boolean' ? false : '')), locked:complex, reason:complex ? 'Structured metadata: edit this value in YAML to preserve its structure.' : undefined, source:valueAt(config.documentMetadata,key) !== undefined ? 'document' : 'inherited / template' };
  });
  const templateFields = parseDocument(TEMPLATE_FRONTMATTER[config.template] || '').toJS() || {};
  for (const [key,example] of Object.entries(templateFields)) {
    if (key === 'template' || controls.some(c=>c.key===key)) continue;
    const value=valueAt(config.metadata,key), structured=example != null && typeof example==='object';
    controls.push({key,label:key.replace(/-/g,' ').replace(/^./,c=>c.toUpperCase()),group:'Template fields',kind:structured?'yaml':typeof example==='boolean'?'boolean':'text',value:value===undefined?'':structured?stringify(value):printable(value),prompt:structured?'Structured template metadata. Replace the sample values with your own details. Example:\n'+stringify(example):`Optional ${config.capabilities.name} field. Inkwell example: ${String(example)}`,source:valueAt(config.documentMetadata,key)!==undefined?'document':'inherited / template'});
  }
  const authors=controls.find(c=>c.group==='Template fields' && c.key.endsWith('-authors'));
  if(authors) Object.assign(controls.find(c=>c.key==='author')!,{locked:true,reason:`This template uses ${authors.key}. Configure its author entries in Template fields.`});
  controls.push(...documentStyleControls(config).map(c => ({ ...c, group:'Typography', kind:c.allowed ? 'choice' : 'text', allowed:c.allowed?.map(String), source:config.provenance[c.key]?.source || 'template' })));
  for (const rule of TABLE_ATTRIBUTE_SCHEMA.filter(r => !r.configKey.startsWith('typography.'))) {
    const capability = config.capabilities.options[rule.configKey];
    controls.push({ key:rule.configKey, label:rule.configKey.slice(7).replace(/[A-Z]/g,c => ' '+c.toLowerCase()).replace(/^./, c => c.toUpperCase()), group:'Tables', kind:rule.type === 'boolean' ? 'boolean' : rule.values ? 'choice' : 'text', allowed:rule.values ? [...rule.values] : undefined, value:printable(valueAt(config,rule.configKey)), locked:capability?.support !== 'supported', reason:capability?.reason, prompt:rule.type === 'size' ? `A size with units, e.g. 1pt (${rule.minimum}–${rule.maximum}pt).` : rule.type === 'color' ? 'A color such as #eeeeee, or transparent.' : rule.type === 'alignment' ? 'Column alignments, e.g. left center right.' : rule.type === 'width' ? 'auto, a percentage such as 90%, or a width such as 15cm.' : `Controls ${rule.configKey.slice(7)} in rendered tables.`, source:config.provenance[rule.configKey]?.source || 'template' });
  }
  controls.push(...referenceFields.map(([field,label,kind,prompt,allowed]) => ({ key:'references.'+field,label,group:'References',kind,prompt,allowed:allowed?.split(','),value:printable((config.references as any)[field]),source:config.provenance['references.'+field]?.source || 'template' })));
  const columns = config.capabilities.options.columns;
  controls.push({key:'columns',label:'Columns',group:'LaTeX',kind:'choice',allowed:['1','2'],value:String(config.columns),prompt:'The publication template may require a fixed number of columns.',locked:columns?.support !== 'supported',reason:columns?.reason});
  return { success:true, template:config.template, templateName:config.capabilities.name, engine:config.engine, hasFrontmatter:config.parsed.hasFrontmatter, yaml:config.parsed.rawYaml, controls, diagnostics:config.diagnostics, templateExample:TEMPLATE_FRONTMATTER[config.template] || '# This template uses the standard document fields.\n', fingerprint:config.fingerprint };
}

function replaceYaml(text:string, raw:string, file:string):string {
  const parsed = parseDocumentFrontmatter(text,file);
  if (parsed.hasFrontmatter && !parsed.bodyOffset) throw new Error('Close the existing frontmatter with --- before using document settings.');
  const yaml = parseDocument(raw,{uniqueKeys:true});
  if (yaml.errors.length || (yaml.contents !== null && !isMap(yaml.contents))) throw new Error('Settings must be a valid YAML mapping. '+yaml.errors.map(e=>e.message).join(' '));
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  raw = raw.replace(/\r?\n/g,eol);
  if (raw && !raw.endsWith(eol)) raw += eol;
  if (parsed.hasFrontmatter) {
    const start = text.match(/^\uFEFF?---[ \t]*\r?\n/)![0].length;
    return text.slice(0,start)+raw+text.slice(start+parsed.rawYaml.length);
  }
  const bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  return bom+'---'+eol+raw+'---'+eol+text.slice(bom.length);
}

function editRoot(text:string,key:string,value:any,file:string):string {
  const parsed = parseDocumentFrontmatter(text,file);
  const yaml = parseDocument(parsed.rawYaml,{keepSourceTokens:true,uniqueKeys:true});
  if (parsed.diagnostics.some(d=>d.severity==='error') || yaml.errors.length) throw new Error('Repair the YAML in the text view before changing individual controls.');
  const parts = yaml.has(key) ? [key] : key.split('.');
  // A form must never accidentally change other values sharing a YAML anchor.
  for (let i=0;i<=parts.length;i++) {
    const node = i ? yaml.getIn(parts.slice(0,i),true) : yaml.contents;
    if (isAlias(node) || (isNode(node) && 'anchor' in node && node.anchor)) throw new Error('This setting uses a YAML anchor. Edit it in the YAML view.');
  }
  yaml.setIn(parts,value);
  return replaceYaml(text,yaml.toString({lineWidth:0}),file);
}
export function editSettings(text:string,file:string,request:any) {
  let after = text;
  if (typeof request.yaml === 'string') after = replaceYaml(text,request.yaml,file);
  else {
    if (request.template !== undefined) {
      if (typeof request.template !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(request.template)) throw new Error('Choose a publication template.');
      after = editRoot(after,'template',request.template,file);
      if (getDocumentConfig(after,file).template !== request.template) throw new Error('That template is overridden by another setting. Edit the template in YAML.');
    }
    if (request.starter) {
      const config = getDocumentConfig(after,file);
      const defaults:Record<string,any> = {title:'Untitled',author:'',date:'\\today','link-citations':true,'inkwell.code-display':'output','inkwell.code-bg':'#f5f5f5','inkwell.code-border':true,'inkwell.code-rounded':true};
      // Use the actual template and inherited bibliography; do not invent authors or sources.
      defaults.template = config.template;
      if (config.references.bibliography.length) defaults.bibliography = config.references.bibliography;
      if (config.template === 'default') Object.assign(defaults,{geometry:'margin=1in',fontsize:'11pt',linestretch:1.4,'inkwell.tables':'booktabs'});
      for (const [key,value] of Object.entries(defaults)) if (valueAt(getDocumentConfig(after,file).documentMetadata,key) === undefined) after = editRoot(after,key,value,file);
    }
    for (const change of request.changes || []) {
      const config = getDocumentConfig(after,file);
      const control = settings(after,file).controls.find(c=>c.key===change.key);
      if (!control || control.locked) throw new Error(control?.reason || 'This setting is locked or unknown.');
      if (typeof change.value !== 'string') throw new Error('Setting values must be text.');
      let value:any = change.value;
      if (control.allowed && !control.allowed.includes(value)) throw new Error(`Choose one of: ${control.allowed.join(', ')}.`);
      if (control.kind==='boolean') { if (!['true','false'].includes(value)) throw new Error('Choose true or false.'); value=value==='true'; }
      if (control.kind==='lines') value=value.split(/\r?\n/).map((s:string)=>s.trim()).filter(Boolean);
      if (control.kind==='yaml') {
        const yaml=parseDocument(value,{uniqueKeys:true});
        if(yaml.errors.length) throw new Error(`Invalid YAML for ${control.label}: ${yaml.errors.map(e=>e.message).join(' ')}`);
        value=yaml.toJS({maxAliasCount:30});
        const sample=parseDocument(TEMPLATE_FRONTMATTER[config.template] || '').toJS()?.[change.key];
        if(Array.isArray(sample) && !Array.isArray(value)) throw new Error(`${control.label} expects a YAML list. Follow the example below the field.`);
      }
      if (control.kind==='number' || change.key==='columns') { value=Number(value); if (!Number.isFinite(value) || value<=0) throw new Error('Enter a positive number.'); }
      if (change.key.startsWith('typography.')) after=planDocumentStyleEdit(after,[{key:change.key,value}],config).after;
      else if (/^(tables|references)\./.test(change.key)) after=planFrontmatterSettingsEdit(after,[{key:change.key,value}],file).after;
      else after=editRoot(after,change.key,value,file);
      const resolved=getDocumentConfig(after,file);
      const issue=resolved.diagnostics.find(d=>d.key===change.key && (d.severity==='error' || d.code==='template-capability'));
      if (issue) throw new Error(issue.message);
    }
  }
  const result=settings(after,file);
  if (!listTemplates(Uri.file(file) as any).has(result.template)) throw new Error(`Template ${result.template} is not installed in this workspace.`);
  const errors=result.diagnostics.filter(d=>d.severity==='error');
  if (errors.length) throw new Error(errors.map(d=>d.message).join('\n'));
  return {...result,text:after};
}
