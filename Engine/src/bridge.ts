import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import MarkdownIt from 'markdown-it';
import katex from 'katex';
import hljs from 'highlight.js';
import { configure, Uri } from './native-host';
import { compile } from '../../Vendor/Inkwell/src/compiler';
import { runAllBlocks, parseCodeBlocks, RunCancellation } from '../../Vendor/Inkwell/src/runner';
import { applyRunTextEdits, planBlockIdentities } from '../../Vendor/Inkwell/src/run-authoring';
import { prepareForPreview, collectUnresolvedVars } from '../../Vendor/Inkwell/src/inject';
import { getDocumentConfig, getInkwellProjectRoot } from '../../Vendor/Inkwell/src/config';
import { listTemplates } from '../../Vendor/Inkwell/src/templates';
import { bibliographyService } from '../../Vendor/Inkwell/src/bibliography-service';
import { planMigration, applyMigration } from '../../Vendor/Inkwell/src/scaffold-migrations';
import { splitFrontmatter } from '../../Vendor/Inkwell/src/frontmatter';
import { installSafeHtmlRendering } from '../../Vendor/Inkwell/src/html-safety';
import { buildTypographyCss } from '../../Vendor/Inkwell/src/style-model';
import { settings, editSettings } from './settings';
import { configureVariables, normalizePythonFences, variableBlocks } from './variables';

const run = promisify(execFile);
const escape = (s: string) => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!));
const md = new MarkdownIt({ html: true, linkify: true, typographer: true, highlight: (text, language) => {
  return language && hljs.getLanguage(language) ? hljs.highlight(text, { language }).value : escape(text);
}});
installSafeHtmlRendering(md);
// Math is parsed as Markdown tokens so code blocks and escaped dollars remain literal.
md.inline.ruler.before('escape', 'pandanote_math', (state: any, silent: boolean) => {
  if (state.src[state.pos] !== '$') return false;
  const display = state.src[state.pos + 1] === '$';
  const delimiter = display ? '$$' : '$';
  const start = state.pos + delimiter.length;
  const literal = () => {
    // Consume a rejected $$ together so its second dollar cannot open inline math.
    if (!silent) state.pending += delimiter;
    state.pos = start;
    return true;
  };
  if (start >= state.posMax || (!display && /\s/.test(state.src[start]))) return literal();

  let end = start;
  while (end < state.posMax) {
    if (!display && state.src[end] === '\n') return literal();
    // An escaped dollar is TeX content. Skipping backslash pairs also preserves
    // the distinction between an escaped dollar and one after an even run.
    if (!display && state.src[end] === '\\') {
      if (end + 1 >= state.posMax || state.src[end + 1] === '\n') return literal();
      end += 2;
      continue;
    }
    if (state.src.startsWith(delimiter, end)) break;
    end++;
  }
  if (end + delimiter.length > state.posMax || end === start) return literal();
  // Pandoc's inline delimiters exclude adjacent whitespace and a closing dollar
  // followed by a digit, keeping currency such as "$20 and $30" as prose.
  // Do not search past an invalid closer: that could swallow a later formula.
  if (!display && (/\s/.test(state.src[end - 1]) || /[0-9]/.test(state.src[end + 1] || ''))) return literal();
  if (!silent) { const token = state.push('pandanote_math', '', 0); token.content = state.src.slice(start, end); token.meta = { display }; }
  state.pos = end + delimiter.length; return true;
});
md.renderer.rules.pandanote_math = (tokens: any, index: number) => katex.renderToString(tokens[index].content, { displayMode: tokens[index].meta.display, output: 'mathml', throwOnError: false, trust: false });

async function handle(request: any): Promise<any> {
  if (!request || typeof request.action !== 'string') throw new Error('Missing action.');
  const root = path.resolve(request.root || process.cwd());
  const file = path.resolve(request.file || path.join(root, 'Untitled.md'));
  if (file !== root && !file.startsWith(root + path.sep)) throw new Error('Document must be inside the selected vault.');
  if (fs.existsSync(file)) {
    const realFile = fs.realpathSync(file), realRoot = fs.realpathSync(root);
    if (!realFile.startsWith(realRoot + path.sep)) throw new Error('Document resolves outside the selected vault.');
  }
  const text = typeof request.text === 'string' ? request.text : '';
  const explicitExecution = request.action === 'run' || request.action === 'compile';
  configure(root, explicitExecution && request.trusted === true);
  const document = { uri: Uri.file(file), languageId: file.endsWith('.tex') ? 'latex' : 'markdown', version: 1, isUntitled: false, getText: () => text } as any;
  switch (request.action) {
    case 'settings': return settings(text,file);
    case 'edit-settings': return editSettings(text,file,request);
    case 'preview': {
      // Preview is always untrusted: it may show cached results, never execute Python.
      configureVariables(text,file);
      const prepared = prepareForPreview(text, file);
      const body = splitFrontmatter(prepared)?.body || prepared;
      const config = getDocumentConfig(text, file);
      let rendered = md.render(body.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, label) => `[${label || target}](pandanote-note:${encodeURIComponent(target)})`));
      rendered = rendered.replace(/<li>\[([ xX])\]/g, (_, checked) => `<li class="task">${checked === ' ' ? '☐' : '☑'}`);
      rendered = rendered.replace(/<img\s+src="([^"]+)"[^>]*>/g, (tag, src) => {
        try {
          const decoded = decodeURIComponent(src.replace(/&amp;/g, '&'));
          if (/^[a-z][a-z0-9+.-]*:/i.test(decoded)) return '<em>Remote image omitted</em>';
          const image = fs.realpathSync(path.resolve(path.dirname(file), decoded));
          const boundary = fs.realpathSync(root);
          if (!image.startsWith(boundary + path.sep)) return '<em>Image outside vault</em>';
          const ext = path.extname(image).slice(1).toLowerCase();
          const mime: Record<string,string> = { png:'image/png', jpg:'image/jpeg', jpeg:'image/jpeg', gif:'image/gif', webp:'image/webp' };
          if (!mime[ext] || fs.statSync(image).size > 8 * 1024 * 1024) return '<em>Open attachment in Finder</em>';
          return tag.replace(src, `data:${mime[ext]};base64,${fs.readFileSync(image).toString('base64')}`);
        } catch { return '<em>Image unavailable</em>'; }
      });
      const referenceDiagnostics = collectUnresolvedVars(prepared).map(key => ({severity:'warning',
        message:`Unresolved reference ${key}: run the cell, check its ID and variable name, and use a supported numeric format such as .2f.`}));
      return { success: true, html: page(rendered, buildTypographyCss(config)), blocks: parseCodeBlocks(text), variableBlocks:variableBlocks(), diagnostics: [...config.diagnostics,...referenceDiagnostics], template:config.capabilities.name, engine:config.engine };
    }
    case 'compile': {
      if (!request.trusted) throw new Error('Choose Build PDF to authorize compilation and document expressions.');
      configureVariables(text,file);
      const result = await compile(document);
      const config = getDocumentConfig(text,file);
      return { ...result, template:config.capabilities.name, engine:config.engine };
    }
    case 'run': {
      if (!request.trusted) throw new Error('Choose Run Code to authorize this document’s scripts.');
      const normalized = normalizePythonFences(text);
      const prepared = applyRunTextEdits(normalized, planBlockIdentities(normalized, () => `run-${crypto.randomUUID().slice(0, 12)}`));
      configureVariables(prepared,file);
      const cancellation = new RunCancellation();
      process.on('SIGTERM', () => cancellation.cancel());
      const results = await runAllBlocks(prepared, file, cancellation, progress => process.stderr.write(JSON.stringify(progress) + '\n'), request.indices);
      return { success: results.every(r => r.exitCode === 0), text: prepared, variableBlocks:variableBlocks(results), results: results.map(r => ({ ...r, artifacts: Object.fromEntries(r.artifacts) })), message: `${results.length} code blocks processed.` };
    }
    case 'templates': return { success: true, templates: [...listTemplates(document.uri)].filter(([id]) => id !== 'inkwell').map(([id,t]) => ({ id, name: t.manifest.name, description: t.manifest.description || '', engine: t.manifest.engine || 'xelatex' })) };
    case 'references': return { success: true, references: await bibliographyService.resolve(getDocumentConfig(text, file), file, getInkwellProjectRoot(file)) };
    case 'setup': {
      const result = applyMigration(planMigration(root, path.resolve(__dirname, '..')), { resolveConflicts: 'keep-user-files' });
      return { ...result, message: result.success ? 'Inkwell workspace ready.' : 'Setup needs attention. See diagnostics.' };
    }
    case 'tools': {
      const names = ['pandoc', 'pandoc-crossref', 'xelatex', 'pdflatex', 'lualatex', 'python3', 'Rscript', 'node', 'mmdc'];
      const tools = await Promise.all(names.map(async name => {
        try { const result = await run('/usr/bin/which', [name]); return { name, path: result.stdout.trim(), available: true }; }
        catch { return { name, path: '', available: false }; }
      }));
      return { success: true, tools };
    }
    default: throw new Error(`Unknown action: ${request.action}`);
  }
}

function page(content: string, typography: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; script-src 'none'"><meta name="color-scheme" content="light dark"><style>
  :root{color-scheme:light dark;--ink:#283631;--muted:#6e7c74;--line:#e0e5df;--paper:#fcfcf8;--accent:#40785c} @media(prefers-color-scheme:dark){:root{--ink:#dce4de;--muted:#92a296;--line:#34433a;--paper:#1b2420;--accent:#9bc9aa}}
  *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.78 Georgia,serif;padding:42px 40px 180px;overflow-wrap:break-word}article{max-width:780px;margin:auto}h1,h2,h3,h4{font-family:-apple-system,sans-serif;line-height:1.3;letter-spacing:-.025em}h1{font-size:34px;margin:0 0 28px}h2{font-size:23px;margin-top:40px;padding-bottom:9px;border-bottom:1px solid var(--line)}h3{font-size:18px;margin-top:28px}a{color:var(--accent)}p{margin:16px 0}pre{overflow:auto;background:color-mix(in srgb,var(--muted) 9%,var(--paper));padding:18px;border:1px solid var(--line);border-radius:8px;line-height:1.6}code{font:12px/1.65 ui-monospace,Menlo,monospace}blockquote{border-left:3px solid var(--accent);margin:24px 0;padding:2px 20px;color:var(--muted)}table{border-collapse:collapse;width:100%;font:13px/1.6 -apple-system,sans-serif;margin:24px 0}th,td{text-align:left;padding:10px;border-bottom:1px solid var(--line)}th{background:color-mix(in srgb,var(--accent) 6%,var(--paper))}img{max-width:100%;height:auto;border-radius:5px}hr{border:0;border-top:1px solid var(--line);margin:30px 0}math[display=block]{margin:25px 0}.hljs-keyword,.hljs-built_in{color:#9571ad}.hljs-string{color:#538568}.hljs-number{color:#ac7850}.hljs-comment{color:var(--muted)}
  article{${typography}font-family:var(--inkwell-body-font);font-size:var(--inkwell-body-size);line-height:var(--inkwell-line-spacing)}article h1,article h2,article h3,article h4{font-family:var(--inkwell-heading-font);font-weight:var(--inkwell-heading-weight);color:var(--inkwell-heading-color)}article h1{font-size:var(--inkwell-heading-1-size)}article h2{font-size:var(--inkwell-heading-2-size)}article h3{font-size:var(--inkwell-heading-3-size)}article code{font-family:var(--inkwell-mono-font);font-size:var(--inkwell-code-size)}article table{font-family:var(--inkwell-body-font);font-size:var(--inkwell-table-size)}
  </style></head><body><article>${content}</article></body></html>`;
}

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; if (input.length > 16 * 1024 * 1024) process.exit(2); });
process.stdin.on('end', () => { void handle(JSON.parse(input)).then(result => { process.stdout.write(JSON.stringify(result)); process.exitCode = result.success === false ? 1 : 0; }, error => { process.stdout.write(JSON.stringify({ success:false, message:String(error) })); process.exitCode=1; }); });
