import fs from 'node:fs';
import path from 'node:path';

function replaceOnce(source, before, after, label) {
  if (source.split(before).length !== 2) throw new Error(`The Inkwell ${label} changed; review the native variable patch.`);
  return source.replace(before,after);
}

/** Keep the pinned upstream checkout intact; fail loudly if its hooks change. */
export function nativeVariablesPlugin(engineDirectory) {
  const helper = JSON.stringify(path.join(engineDirectory,'src/variables.ts'));
  return { name:'pandanote-variables',setup(build) {
    build.onLoad({filter:/[\\/]Inkwell[\\/]src[\\/](runner|run-store|inject)\.ts$/},async args => {
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
      } else {
        source = `import { nativeCachedResults, supplementalVariables } from ${helper};\n` + source;
        source = replaceOnce(source,'return readCurrentRunResults(markdown, sourceFile);',
          'return vscode.workspace.isTrusted ? readCurrentRunResults(markdown, sourceFile) : nativeCachedResults();','cached preview reader');
        source = replaceOnce(source,'  return vars;\n}',
          '  for (const [key,value] of supplementalVariables(results)) vars.set(key,value);\n  return vars;\n}','scalar binding collector');
        source = replaceOnce(source,'function buildOutputContent(result: BlockResult, sourceFile: string, options: InjectionOptions): string | null {',
          `function buildOutputContent(result: BlockResult, sourceFile: string, options: InjectionOptions): string | null {\n  result = { ...result, artifacts:new Map([...result.artifacts].filter(([name]) => name !== 'pandanote-variables')) };`,'private snapshot artifact');
        source = replaceOnce(source,'return "```" + lang + "\\n" + source + "\\n```";', 'return literalFence(source, lang);','external code display fence');
        source = replaceOnce(source,'return "```" + lang + "\\n" + block.source + "\\n```";', 'return literalFence(block.source, lang);','inline code display fence');
      }
      return {contents:source,loader:'ts',resolveDir:path.dirname(args.path)};
    });
  }};
}
