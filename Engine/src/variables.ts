import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type { BlockResult, CodeBlock, ResolvedInterpreter } from '../../Vendor/Inkwell/src/runner';
import { parseRunConfig, resolveInterpreter } from '../../Vendor/Inkwell/src/runner';
import { RunStore, sha256, resolveRunSource, type RunFingerprint, type RunManifest } from '../../Vendor/Inkwell/src/run-store';
import { containedRunPath, relativeRunPath } from '../../Vendor/Inkwell/src/run-paths';
import { parseQuotedAttrs, parseRunList } from '../../Vendor/Inkwell/src/run-attributes';
import { getDocumentConfig, getInkwellProjectRoot } from '../../Vendor/Inkwell/src/config';
import { applyBlockOverrides } from '../../Vendor/Inkwell/src/document-config';
import { PYTHON_CAPTURE, PYTHON_CAPTURE_VERSION, VARIABLE_ARTIFACT } from './python-capture';

export { PYTHON_CAPTURE_VERSION };
const digest = (value: unknown) => sha256(JSON.stringify(value));
const MAX_SNAPSHOT = 2 * 1024 * 1024;
const object = (value: unknown): value is Record<string, any> => value !== null && typeof value === 'object' && !Array.isArray(value);
type SavedValue = { kind: 'none'|'int'|'float'|'str'|'bool'|'list'|'dict'; value?: any };
type CapturedVariable = { name: string; type: string; preview: string; reusable: boolean; value?: SavedValue };
type Snapshot = { schemaVersion: 1; documentIdentity: string; blockId: string; variables: CapturedVariable[]; omitted: number };
export type VariableDescription = { id: string; name: string; type: string; preview: string; reusable: boolean; reference: string; pythonReference: string };
export type VariableBlock = { id: string; index: number; startLine: number; language: string; runID?: string; fingerprint?: string; status: 'current'|'stale'|'not-run'|'failed'; variables: VariableDescription[]; message?: string };
type Context = { root: string; file: string; text: string; blocks: CodeBlock[]; identity: string };
let context: Context | undefined;

interface Fence { start: number; headerEnd: number; end: number; closeStart: number; startLine: number; endLine: number; info: string; source: string; raw: string }
/** Track the outer fence first: triple backticks inside a longer example stay literal. */
function fences(text: string): Fence[] {
  const lines = [...text.matchAll(/[^\n]*(?:\n|$)/g)].filter(item => item[0]);
  const result: Fence[] = [];
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index], opening = /^ {0,3}(`{3,}|~{3,})([^\r\n]*)\r?\n?$/.exec(line[0]);
    if (!opening || (opening[1][0] === '`' && opening[2].includes('`'))) continue;
    const close = new RegExp('^ {0,3}' + (opening[1][0] === '`' ? '`' : '~') + '{' + opening[1].length + ',}[ \\t]*\\r?\\n?$');
    let last = index + 1;
    while (last < lines.length && !close.test(lines[last][0])) last++;
    if (last === lines.length) break;
    const start = line.index!, headerEnd = start + line[0].length;
    const closeStart = lines[last].index!, end = closeStart + lines[last][0].replace(/\r?\n$/, '').length;
    result.push({ start, headerEnd, end, closeStart, startLine: index + 1, endLine: last + 1,
      info: opening[2].trim(), source: text.slice(headerEnd, closeStart).trimEnd(), raw: text.slice(start, end) });
    index = last;
  }
  return result;
}

export function normalizePythonFences(text: string): string {
  for (const fence of fences(text).reverse()) {
    if (!/^python3?$/i.test(fence.info)) continue;
    const header = text.slice(fence.start,fence.headerEnd).replace(/^([ ]{0,3}(?:`{3,}|~{3,}))[^\r\n]*/,'$1{'+fence.info.toLowerCase()+'}');
    text = text.slice(0,fence.start) + header + text.slice(fence.headerEnd);
  }
  return text;
}

/** Native parser uses the same attributes as Inkwell, with real fence nesting. */
export function parseNativeBlocks(text: string, includePlain = false): CodeBlock[] {
  const blocks: CodeBlock[] = [];
  for (const fence of fences(text)) {
    const header = /^\{(\w+)([^\r\n]*)\}$/.exec(fence.info);
    const plain = includePlain && /^python3?$/i.test(fence.info);
    if (!header && !plain) continue;
    const lang = header?.[1] || fence.info.toLowerCase();
    if (lang.toLowerCase() === 'mermaid') continue;
    let attrs: Record<string,string> = {}, parsingError: string | undefined;
    try { attrs = parseQuotedAttrs(header?.[2].trim() || ''); } catch (error) { parsingError = String(error); }
    blocks.push({ index: blocks.length, id: attrs.id, lang, source: fence.source, raw: fence.raw,
      startLine: fence.startLine, endLine: fence.endLine, attributes: attrs, parsingError,
      inputs: attrs.inputs === undefined ? undefined : parseRunList(attrs.inputs),
      dependsOn: attrs['depends-on'] === undefined ? undefined : parseRunList(attrs['depends-on']),
      file: attrs.file, output: attrs.output, env: attrs.env, display: attrs.display as CodeBlock['display'],
      caption: attrs.caption, label: attrs.label, noCache: attrs.cache === undefined ? undefined : ['false','no'].includes(attrs.cache) });
  }
  return blocks;
}

export function configureVariables(text: string, file: string): void {
  const root = getInkwellProjectRoot(file);
  const config = getDocumentConfig(text, file);
  const blocks = parseNativeBlocks(text, true).map(block => {
    const attributes: Record<string,unknown> = { ...block.attributes };
    if (attributes.cache === 'no') attributes.cache = false;
    if (attributes.cache === 'yes') attributes.cache = true;
    const effective = applyBlockOverrides(config, attributes);
    return { ...block, id: effective.runs.id, file: effective.runs.file, output: effective.runs.output,
      display: effective.runs.display, label: effective.runs.label, caption: effective.runs.caption,
      inputs: effective.runs.inputs, dependsOn: effective.runs.dependsOn, configDiagnostics: effective.diagnostics };
  });
  context = { root, file, text, blocks, identity: digest([fs.realpathSync(root), path.relative(root, path.resolve(file)).split(path.sep).join('/')]) };
}

function variableID(identity: string, blockID: string, name: string): string { return 'pv_' + digest([identity, blockID, name]).slice(0,24); }
function validateValue(value: unknown, depth = 0, budget = { nodes: 0 }): value is SavedValue {
  if (++budget.nodes > 5000 || depth > 8 || !object(value)) return false;
  switch (value.kind) {
    case 'none': return value.value === undefined;
    case 'str': return typeof value.value === 'string' && value.value.length <= 65536;
    case 'int': return typeof value.value === 'string' && /^-?\d{1,2500}$/.test(value.value);
    case 'float': return typeof value.value === 'string' && value.value.length <= 32 && /^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/.test(value.value) && Number.isFinite(Number(value.value));
    case 'bool': return typeof value.value === 'boolean';
    case 'list': return Array.isArray(value.value) && value.value.length <= 1000 && value.value.every(item => validateValue(item,depth+1,budget));
    case 'dict': {
      if (!Array.isArray(value.value) || value.value.length > 1000) return false;
      const keys = new Set<string>();
      return value.value.every(pair => Array.isArray(pair) && pair.length === 2 && typeof pair[0] === 'string' && pair[0].length <= 1024
        && !keys.has(pair[0]) && Boolean(keys.add(pair[0])) && validateValue(pair[1],depth+1,budget));
    }
    default: return false;
  }
}

function snapshotFor(manifest: RunManifest, manifestPath: string, ctx: Context): Snapshot | undefined {
  const metadata = manifest.artifacts.find(item => path.basename(item.path) === VARIABLE_ARTIFACT + '.json');
  if (!metadata || metadata.bytes > MAX_SNAPSHOT) return undefined;
  const file = containedRunPath(ctx.root, path.resolve(path.dirname(manifestPath), metadata.path), false, true);
  const fd = fs.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  let bytes: Buffer;
  try {
    if (!fs.fstatSync(fd).isFile() || fs.fstatSync(fd).size !== metadata.bytes) return undefined;
    const buffer = Buffer.alloc(metadata.bytes + 1);
    let size = 0, count: number;
    while ((count = fs.readSync(fd,buffer,size,buffer.length-size,null)) > 0) { size += count; if (size > metadata.bytes) return undefined; }
    bytes = buffer.subarray(0,size);
  } finally { fs.closeSync(fd); }
  if (bytes.length !== metadata.bytes || sha256(bytes) !== metadata.sha256) return undefined;
  const value: unknown = JSON.parse(bytes.toString('utf8'));
  if (!object(value) || value.schemaVersion !== 1 || value.documentIdentity !== ctx.identity || value.blockId !== manifest.blockId
      || !Array.isArray(value.variables) || value.variables.length > 256 || !Number.isSafeInteger(value.omitted) || value.omitted < 0) return undefined;
  const names = new Set<string>();
  for (const variable of value.variables) {
    if (!object(variable) || typeof variable.name !== 'string' || variable.name.length > 256 || names.has(variable.name)
      || typeof variable.type !== 'string' || variable.type.length > 120 || typeof variable.preview !== 'string' || variable.preview.length > 500
      || typeof variable.reusable !== 'boolean' || (variable.reusable && !validateValue(variable.value))) return undefined;
    names.add(variable.name);
  }
  return value as Snapshot;
}

function resultHash(manifest: RunManifest): string { return digest([manifest.fingerprint.hash, manifest.stdout, manifest.artifacts]); }
function sourceHash(block: CodeBlock, ctx: Context): string {
  if (!block.file) return sha256(block.source);
  const file = resolveRunSource(block.file,path.dirname(ctx.file),ctx.root);
  if (fs.statSync(file).size > 16 * 1024 * 1024) throw new Error('Run to verify a source larger than 16 MiB.');
  return sha256(fs.readFileSync(file));
}

function boundedHash(file: string, budget: {bytes:number}): string {
  let fd: number | undefined;
  try {
    fd = fs.openSync(file,'r');
    const before = fs.fstatSync(fd);
    if (!before.isFile() || (budget.bytes += before.size) > 32 * 1024 * 1024) throw new Error('Run again to verify large input or environment files.');
    const hash = crypto.createHash('sha256'), buffer = Buffer.alloc(65536);
    let count: number, bytes = 0;
    while ((count = fs.readSync(fd,buffer,0,buffer.length,null)) > 0) {
      bytes += count;
      if (bytes > before.size) throw new Error('A saved input changed during verification.');
      hash.update(buffer.subarray(0,count));
    }
    const after = fs.fstatSync(fd), current = fs.statSync(file);
    if (bytes !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs || current.ino !== before.ino || current.dev !== before.dev) throw new Error('A saved input changed during verification.');
    return hash.digest('hex');
  } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return 'missing'; throw error; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}

function globPattern(pattern: string): RegExp {
  let expression = '';
  for (let index = 0; index < pattern.length; index++) {
    const c = pattern[index];
    if (c === '*' && pattern[index+1] === '*') {
      index++;
      if (pattern[index+1] === '/') {index++;expression += '(?:.*/)?';} else expression += '.*';
    } else if (c === '*') expression += '[^/]*';
    else if (c === '?') expression += '[^/]';
    else expression += c.replace(/[.+^${}()|[\]\\]/g,'\\$&');
  }
  return new RegExp('^'+expression+'$');
}

function currentInputHashes(patterns: string[],ctx: Context): Record<string,string> {
  const files = new Set<string>(), hashes: Record<string,string> = Object.create(null);
  for (const pattern of patterns) {
    relativeRunPath(pattern);
    const absolute = path.resolve(ctx.root,pattern);
    if (!/[?*]/.test(pattern)) {
      containedRunPath(ctx.root,absolute,true);
      if (!fs.existsSync(absolute)) hashes[pattern] = 'missing'; else files.add(absolute);
      continue;
    }
    const fixed = absolute.slice(0,absolute.search(/[?*]/));
    const base = path.dirname(fixed.endsWith(path.sep) ? fixed+'_' : fixed);
    containedRunPath(ctx.root,base,true);
    const matcher = globPattern(absolute.split(path.sep).join('/'));
    let entries = 0;
    const walk = (directory: string): void => {
      if (!fs.existsSync(directory)) return;
      for (const entry of fs.readdirSync(directory,{withFileTypes:true})) {
        if (++entries > 100000) throw new Error('Run again to verify a large input pattern.');
        const file = path.join(directory,entry.name), relative = path.relative(ctx.root,file).split(path.sep).join('/');
        if (relative.split('/').includes('.git') || /^\.inkwell\/(runs|outputs|compiled|mermaid|\.cache|venv)(\/|$)/.test(relative)) continue;
        containedRunPath(ctx.root,file);
        if (entry.isDirectory()) walk(file);
        else if (matcher.test(file.split(path.sep).join('/'))) files.add(file);
        if (files.size > 1000) throw new Error('Run again to verify more than 1,000 inputs.');
      }
    };
    walk(base);
    if (![...files].some(file => matcher.test(file.split(path.sep).join('/')))) hashes[pattern] = 'missing';
  }
  const budget = {bytes:0};
  for (const file of [...files].sort()) hashes[path.relative(ctx.root,file).split(path.sep).join('/')] = boundedHash(file,budget);
  return Object.fromEntries(Object.entries(hashes).sort(([a],[b]) => a.localeCompare(b)));
}

function environmentChanged(block: CodeBlock, manifest: RunManifest,ctx: Context): boolean {
  const interpreter = resolveInterpreter(block.lang.toLowerCase(),block.env,parseRunConfig(ctx.text,ctx.file),ctx.root,path.dirname(ctx.file));
  const environment = {...process.env,...interpreter.envVars};
  let executable = interpreter.cmd;
  if (!path.isAbsolute(executable)) executable = (environment.PATH || '').split(path.delimiter).map(dir => path.join(dir,executable)).find(file => {
    try {fs.accessSync(file,fs.constants.X_OK);return fs.statSync(file).isFile();} catch {return false;}
  }) || executable;
  const resolved = fs.realpathSync(executable), stat = fs.statSync(resolved);
  if (path.resolve(executable) !== manifest.fingerprint.interpreter.path || digest([resolved,stat.size,stat.mtimeMs,stat.ctimeMs]) !== manifest.fingerprint.interpreter.identity) return true;
  const allowed = new Set(['PATH','LANG','LC_ALL','LC_CTYPE','TZ','PYTHONPATH','PYTHONHOME','PYTHONHASHSEED','VIRTUAL_ENV','CONDA_PREFIX','NODE_PATH','NODE_OPTIONS','R_HOME','R_LIBS','R_LIBS_USER']);
  if (digest(Object.entries(environment).filter(([key]) => allowed.has(key)).sort(([a],[b]) => a.localeCompare(b))) !== manifest.fingerprint.environmentHash) return true;
  const budget = {bytes:0};
  for (const [file,expected] of Object.entries(manifest.fingerprint.lockfiles)) if (boundedHash(file,budget) !== expected) return true;
  // Discover newly installed distributions in known package directories using
  // filenames alone; preview must never ask Python to import sitecustomize.
  const sites = new Set(Object.keys(manifest.fingerprint.lockfiles).filter(file => /\.(?:dist|egg)-info[\/](?:METADATA|PKG-INFO)$/.test(file)).map(file => path.dirname(path.dirname(file))));
  if (interpreter.envVars.VIRTUAL_ENV) {
    const lib = path.join(interpreter.envVars.VIRTUAL_ENV,'lib');
    if (fs.existsSync(lib)) for (const version of fs.readdirSync(lib)) {
      const site = path.join(lib,version,'site-packages'); if (fs.existsSync(site)) sites.add(site);
    }
  }
  for (const site of sites) if (fs.existsSync(site)) for (const name of fs.readdirSync(site)) {
    if (!/\.(?:dist|egg)-info$/.test(name)) continue;
    const entry = path.join(site,name), metadata = fs.statSync(entry).isDirectory() ? path.join(entry,name.endsWith('.dist-info') ? 'METADATA' : 'PKG-INFO') : entry;
    if (!(metadata in manifest.fingerprint.lockfiles)) return true;
  }
  return false;
}

function readSmallJSON(file: string,ctx: Context): any {
  containedRunPath(ctx.root,file,false,true);
  const fd = fs.openSync(file,fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const size = fs.fstatSync(fd).size;
    if (size > 1024 * 1024) throw new Error('Run metadata exceeds the inspection limit.');
    const bytes = Buffer.alloc(size+1), count = fs.readSync(fd,bytes,0,bytes.length,0);
    if (count !== size) throw new Error('Run metadata changed.');
    return JSON.parse(bytes.subarray(0,size).toString('utf8'));
  } finally {fs.closeSync(fd);}
}

function lastFailure(block: CodeBlock,ctx: Context): string | undefined {
  const id = block.id || block.label;
  if (!id || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(id)) return undefined;
  try {
    const store = new RunStore(ctx.root,ctx.file);
    const latest = readSmallJSON(path.join(store.directory,id,'latest-attempt.json'),ctx);
    const document = readSmallJSON(path.join(store.directory,'document.json'),ctx);
    if (latest.generation !== document.generation || !/^[a-f0-9-]{36}$/.test(latest.runId)) return undefined;
    const attempt = readSmallJSON(path.join(store.directory,id,'history',latest.runId,'run.json'),ctx);
    if (attempt.schemaVersion !== 1 || attempt.runId !== latest.runId || attempt.blockId !== id || attempt.generation !== document.generation
      || !['failed','cancelled'].includes(attempt.status) || attempt.fingerprint?.sourceHash !== sourceHash(block,ctx)) return undefined;
    return typeof attempt.process?.error === 'string' ? attempt.process.error.slice(0,500) : 'The most recent run failed. Run again to update these values.';
  } catch {return undefined;}
}

function currentRecords(ctx: Context): Map<string, { block: CodeBlock; manifest: RunManifest; snapshot?: Snapshot; stale?: string; result: BlockResult }> {
  const store = new RunStore(ctx.root,ctx.file);
  const records = new Map<string, { block: CodeBlock; manifest: RunManifest; snapshot?: Snapshot; stale?: string; result: BlockResult }>();
  const duplicateIDs = new Set(ctx.blocks.filter((block,index,all) => (block.id || block.label) && all.findIndex(other => (other.id || other.label) === (block.id || block.label)) !== index).map(block => block.id || block.label!));
  for (const block of ctx.blocks) {
    const id = block.id || block.label;
    if (!id || duplicateIDs.has(id)) continue;
    try {
      const details = store.currentDetails(id);
      if (!details) continue;
      const { manifest } = details;
      const result = store.resultForManifest(block,manifest,manifest.fingerprint);
      if (!result) continue;
      let stale: string | undefined;
      if (block.parsingError || block.configDiagnostics?.some(d => d.severity === 'error')) stale = 'Fix the code block settings and run again.';
      else if (sourceHash(block,ctx) !== manifest.fingerprint.sourceHash) stale = 'Code changed. Run again to update these values.';
      else if (block.file && resolveRunSource(block.file,path.dirname(ctx.file),ctx.root) !== manifest.fingerprint.sourcePath) stale = 'Source file changed. Run again.';
      // Reconstruct the non-executing part of the native cache key. This catches
      // changed block options/order without probing a project-selected interpreter.
      const { hash: ignored, ...values } = manifest.fingerprint;
      const originalArgs = manifest.argv.slice(0,-1);
      if (!stale && digest({ ...values, language:block.lang, env:block.env, output:block.output, args:originalArgs, ordinal:block.index,
        nativeVariables:PYTHON_CAPTURE_VERSION,nativeInputs:block.inputs || [] }) !== manifest.fingerprint.hash) stale = 'Run settings changed. Run again.';
      try {
        if (!stale && digest(currentInputHashes(block.inputs || [],ctx)) !== digest(manifest.fingerprint.inputs)) stale = 'An input changed. Run again.';
        if (!stale && environmentChanged(block,manifest,ctx)) stale = 'The environment changed. Run again.';
      } catch (error) {stale = error instanceof Error ? error.message : 'Run again to verify the saved inputs and environment.';}
      stale ||= lastFailure(block,ctx);
      const snapshot = /^python3?$/i.test(block.lang) ? snapshotFor(manifest,details.path,ctx) : undefined;
      if (/^python3?$/i.test(block.lang) && !snapshot) stale = 'Run again to capture variables.';
      records.set(id,{block,manifest,snapshot,stale,result});
    } catch { /* Unverified or unreadable history is never presented as current. */ }
  }
  const visiting = new Set<string>();
  const check = (id: string): void => {
    const record = records.get(id); if (!record || record.stale) return;
    if (visiting.has(id)) { record.stale = 'Code dependencies contain a cycle.'; return; }
    visiting.add(id);
    const dependencies = record.block.dependsOn || [];
    if (dependencies.length !== Object.keys(record.manifest.fingerprint.upstream).length) record.stale = 'Dependencies changed. Run again.';
    for (const dependency of dependencies) {
      check(dependency);
      const upstream = records.get(dependency);
      if (!upstream || upstream.stale || resultHash(upstream.manifest) !== record.manifest.fingerprint.upstream[dependency]) record.stale = 'A dependency changed. Run again.';
    }
    visiting.delete(id);
  };
  for (const id of records.keys()) check(id);
  return records;
}

export function variableBlocks(runResults: BlockResult[] = []): VariableBlock[] {
  if (!context) return [];
  const ctx = context, records = currentRecords(ctx);
  return ctx.blocks.filter(block => /^python3?$/i.test(block.lang)).map(block => {
    const id = block.id || block.label || `unrun-${block.startLine}`;
    const record = records.get(id);
    const failed = runResults.find(result => result.block.index === block.index && result.exitCode !== 0);
    const savedFailure = lastFailure(block,ctx);
    const status = failed || savedFailure ? 'failed' : record ? record.stale ? 'stale' : 'current' : 'not-run';
    return { id,index:block.index,startLine:block.startLine,language:block.lang,runID:record?.manifest.runId,
      fingerprint:record?.manifest.fingerprint.hash,status,
      variables: (record?.snapshot?.variables || []).map(variable => {
        const id = variableID(ctx.identity,block.id || block.label!,variable.name);
        const collection = variable.reusable && variable.value && ['list','dict'].includes(variable.value.kind) ? renderSavedValue(variable.value) : undefined;
        const preview = collection === undefined ? variable.preview : collection.length > 500 ? collection.slice(0,499)+'…' : collection;
        return { id,name:variable.name,type:variable.type,preview,reusable:variable.reusable && status === 'current',
          reference:'{{'+id+'}}',pythonReference:`pandanote[${JSON.stringify(block.id || block.label)}][${JSON.stringify(variable.name)}]` };
      }),
      message:failed ? failed.stderr.slice(0,1000) : savedFailure || record?.stale || (record?.snapshot?.omitted ? `${record.snapshot.omitted} variables omitted by the capture limit.` : record ? undefined : 'Run this block to capture its variables.') };
  });
}

/** No interpreter probes. Readers still require the full stored provenance chain. */
export function nativeCachedResults(): BlockResult[] {
  if (!context) return [];
  return [...currentRecords(context).values()].filter(record => !record.stale).map(record => record.result);
}

export function supplementalVariables(results: BlockResult[]): Map<string,string> {
  const values = new Map<string,string>();
  if (!context) return values;
  const records = currentRecords(context);
  const permitted = new Set(results.filter(result => result.exitCode === 0 && result.cacheStatus !== 'miss').map(result => result.blockId || result.block.id || result.block.label));
  for (const [blockID,record] of records) {
    if (record.stale || !permitted.has(blockID)) continue;
    for (const variable of record.snapshot?.variables || []) {
      if (!variable.reusable || !variable.value) continue;
      const value = renderSavedValue(variable.value);
      values.set(variableID(context.identity,blockID,variable.name),value);
    }
  }
  return values;
}

/** JSON text for collections preserves integer precision without executing values. */
function renderSavedValue(value: SavedValue, nested = false): string {
  switch (value.kind) {
    case 'none': return 'null';
    case 'str': return nested ? JSON.stringify(value.value) : value.value;
    case 'int': return value.value;
    case 'float': case 'bool': return String(value.value);
    case 'list': return '[' + value.value.map((item: SavedValue) => renderSavedValue(item,true)).join(', ') + ']';
    case 'dict': return '{' + value.value.map(([key,item]: [string,SavedValue]) => JSON.stringify(key) + ': ' + renderSavedValue(item,true)).join(', ') + '}';
  }
}

/** Called from the native bundle's guarded runner patch, immediately before execution. */
export function nativePythonArguments(block: CodeBlock, script: string, outputDir: string, fingerprint: RunFingerprint, interpreter: ResolvedInterpreter): string[] {
  if (!/^python3?$/i.test(block.lang)) return [...interpreter.args,script];
  if (!context) throw new Error('The variable capture context is missing.');
  const ctx = context, blockId = block.id || block.label;
  if (!blockId) throw new Error('Python blocks need a saved identity before execution.');
  const store = new RunStore(ctx.root,ctx.file);
  const namespaces: Record<string,Record<string,SavedValue>> = Object.create(null), hashes: Record<string,SavedValue> = Object.create(null);
  for (const dependency of block.dependsOn || []) {
    const details = store.currentDetails(dependency);
    if (!details || resultHash(details.manifest) !== fingerprint.upstream[dependency]) throw new Error(`Saved dependency changed: ${dependency}. Run again.`);
    const snapshot = snapshotFor(details.manifest,details.path,ctx);
    namespaces[dependency] = Object.create(null);
    for (const variable of snapshot?.variables || []) if (variable.reusable && variable.value) {
      namespaces[dependency][variable.name] = variable.value;
      hashes[variableID(ctx.identity,dependency,variable.name)] = variable.value;
    }
  }
  const directory = path.dirname(outputDir);
  const wrapper = containedRunPath(ctx.root,path.join(directory,'pandanote-capture.py'),true,true);
  const configuration = containedRunPath(ctx.root,path.join(directory,'pandanote-inputs.json'),true,true);
  const target = containedRunPath(ctx.root,path.join(outputDir,VARIABLE_ARTIFACT+'.json'),true,true);
  fs.writeFileSync(wrapper,PYTHON_CAPTURE,{encoding:'utf8',flag:'wx'});
  fs.writeFileSync(configuration,JSON.stringify({documentIdentity:ctx.identity,blockId,namespaces,hashes}),{encoding:'utf8',flag:'wx'});
  return [...interpreter.args,wrapper,script,configuration,target];
}
