import fs from 'node:fs';
import path from 'node:path';

function replaceOnce(source, before, after, label) {
  if (source.split(before).length !== 2) throw new Error(`The Inkwell ${label} changed; review the native variable patch.`);
  return source.replace(before,after);
}

/** Keep the pinned upstream checkout intact; fail loudly if its hooks change. */
export function nativeVariablesPlugin(engineDirectory) {
  const helper = JSON.stringify(path.join(engineDirectory,'src/variables.ts'));
  const references = JSON.stringify(path.join(engineDirectory,'src/variable-references.ts'));
  return { name:'pandanote-variables',setup(build) {
    build.onLoad({filter:/[\\/]Inkwell[\\/]src[\\/](runner|run-store|inject|compiler)\.ts$/},async args => {
      let source = fs.readFileSync(args.path,'utf8');
      const name = path.basename(args.path);
      if (name === 'runner.ts') {
        source = `import { parseNativeBlocks, nativePythonArguments } from ${helper};\n` + source;
        const start = source.indexOf('export function parseCodeBlocks(markdown: string): CodeBlock[] {');
        const end = source.indexOf('/** The python binary inside a venv directory',start);
        if (start < 0 || end < 0) throw new Error('The Inkwell code block parser changed; review the native variable patch.');
        source = source.slice(0,start) + 'export function parseCodeBlocks(markdown: string): CodeBlock[] { return parseNativeBlocks(markdown); }\n\n' + source.slice(end);
        source = replaceOnce(source,'executeRunProcess(executable, [...interpreter.args, scriptPath], {',
          'executeRunProcess(executable, nativePythonArguments(block, scriptPath, outputDir, fingerprint, interpreter), {','Python invocation');
      } else if (name === 'run-store.ts') {
        source = `import { PYTHON_CAPTURE_VERSION } from ${helper};\n` + source;
        source = replaceOnce(source,'args: interpreter.args, ordinal: block.index });',
          'args: interpreter.args, ordinal: block.index, nativeVariables: PYTHON_CAPTURE_VERSION, nativeInputs: block.inputs || [] });','run fingerprint');
      } else if (name === 'compiler.ts') {
        source = replaceOnce(source,'const token = `{{${key}}}`;',
          'const token = key.includes(".") ? `{${key}}` : `{{${key}}}`;','unresolved reference spelling');
        source = replaceOnce(source,'no code block exported "${key}" (via ::inkwell or vars.json), so it will appear literally in the PDF. Run the code blocks (Cmd+Alt+R) or fix the key.',
          'the value is missing, stale, or has an unsupported numeric format, so it will appear literally in the PDF. Run Code Blocks, check the cell ID and variable name, or use a supported format such as .2f.','unresolved reference guidance');
      } else {
        source = `import { nativeCachedResults, addNativeVariables } from ${helper};\nimport { substituteNativeVariables, collectNativeReferences } from ${references};\n` + source;
        source = replaceOnce(source,'return readCurrentRunResults(markdown, sourceFile);',
          'return vscode.workspace.isTrusted ? readCurrentRunResults(markdown, sourceFile) : nativeCachedResults();','cached preview reader');
        source = replaceOnce(source,'  return vars;\n}',
          '  return addNativeVariables(vars,results);\n}','scalar binding collector');
        source = replaceOnce(source,String.raw`return literal.restore(literal.text.replace(/\{\{(\w+)\}\}/g, (_match, key) => {
    return vars.get(key) ?? ` + '`{{${key}}}`;' + '\n  }));',
          'return literal.restore(substituteNativeVariables(literal.text, vars));','reference substitution');
        source = replaceOnce(source,String.raw`const collect = (text: string) => { for (const m of text.matchAll(/\{\{(\w+)\}\}/g)) out.add(m[1]); };`,
          'const collect = (text: string) => { for (const key of collectNativeReferences(text)) out.add(key); };','unresolved references');
        const hasReferences = String.raw`const hasVarRefs = /\{\{\w+\}\}/.test(processed);`;
        if (source.split(hasReferences).length !== 3) throw new Error('The Inkwell reference detection changed; review the native variable patch.');
        source = source.replaceAll(hasReferences,'const hasVarRefs = collectNativeReferences(processed).length > 0;');
        source = replaceOnce(source,String.raw`const bindMetadata = (value: string): string => value.replace(/\{\{(\w+)\}\}/g, (match, key) => options.variables?.get(key) ?? match);`,
          'const bindMetadata = (value: string): string => substituteNativeVariables(value, options.variables || new Map());','caption references');
        source = replaceOnce(source,'function buildOutputContent(result: BlockResult, sourceFile: string, options: InjectionOptions): string | null {',
          `function buildOutputContent(result: BlockResult, sourceFile: string, options: InjectionOptions): string | null {\n  result = { ...result, artifacts:new Map([...result.artifacts].filter(([name]) => name !== 'pandanote-variables')) };`,'private snapshot artifact');
        source = replaceOnce(source,'return "```" + lang + "\\n" + source + "\\n```";', 'return literalFence(source, lang);','external code display fence');
        source = replaceOnce(source,'return "```" + lang + "\\n" + block.source + "\\n```";', 'return literalFence(block.source, lang);','inline code display fence');
      }
      return {contents:source,loader:'ts',resolveDir:path.dirname(args.path)};
    });
  }};
}
