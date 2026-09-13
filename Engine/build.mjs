import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { patchUncaptionedTables } from './patches/uncaptioned-tables.mjs';
import { nativeVariablesPlugin } from './patches/variables.mjs';
const dir = path.dirname(fileURLToPath(import.meta.url));
const modules = process.env.PANDANOTE_BUILD_MODULES || path.join(dir, 'node_modules');
const require = createRequire(path.join(modules, '../package.json'));
const esbuild = require('esbuild');
const target = path.join(dir, 'runtime');
fs.mkdirSync(path.join(target, 'out'), { recursive: true });
const vendor = path.join(dir, '../Vendor/Inkwell');
for (const name of ['templates', 'filters', 'csl', 'schemas', 'examples', 'docs', '.cursor', 'guide.md', 'LICENSE', 'requirements-latex.txt', 'package.json']) {
  if (fs.existsSync(path.join(vendor, name))) fs.cpSync(path.join(vendor, name), path.join(target, name), { recursive: true });
}
patchUncaptionedTables(target);
await esbuild.build({
  entryPoints: [path.join(dir, 'src/bridge.ts')], outfile: path.join(target, 'out/pandanote-engine.cjs'),
  bundle: true, platform: 'node', format: 'cjs', target: 'node20',
  nodePaths: [modules], alias: { vscode: path.join(dir, 'src/native-host.ts') }, plugins: [nativeVariablesPlugin(dir)]
});
// The upstream scaffold validator requires the extension asset as part of its
// versioned package contract. Keep real bytes; Pandanote never loads this file.
await esbuild.build({ entryPoints: [path.join(vendor, 'src/extension.ts')], outfile: path.join(target, 'out/extension.js'), bundle: true, external: ['vscode'], platform: 'node', format: 'cjs', target: 'node20', nodePaths: [modules] });
const katexRoot = path.join(modules, 'katex/dist');
fs.cpSync(katexRoot, path.join(target, 'katex'), { recursive: true });
fs.copyFileSync(path.join(vendor, 'LICENSE'), path.join(target, 'INKWELL-LICENSE'));
console.log('Pandanote publishing engine built.');
