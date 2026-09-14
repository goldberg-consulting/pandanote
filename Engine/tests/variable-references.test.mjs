import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { transformSync } from 'esbuild';

const source = fs.readFileSync(new URL('../src/variable-references.ts',import.meta.url),'utf8');
const { code } = transformSync(source,{loader:'ts',format:'esm',target:'node20'});
const { formatSavedValue, registerNamedVariables, substituteNativeVariables, collectNativeReferences } = await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));

test('number formats preserve exact captured decimals and integers', () => {
  for (const [value,spec,expected,kind='float'] of [
    ['125.0','.0f','125'], ['125.0','.2f','125.00'], ['12345.678',',.2f','12,345.68'],
    ['0.256','.1%','25.6%'], ['125.0','.2e','1.25e+02'], ['125.678','.3g','126'],
    ['2.675','.2f','2.68'], ['2.665','.2f','2.66'], ['-2.675','.2f','-2.68'],
    ['2.5','.0f','2'], ['3.5','.0f','4'], ['0.0','+.2f','+0.00'], ['-0.0','+.2f','-0.00'],
    ['999.9','.3g','1e+03'], ['9.999','.3g','10'], ['0.00009999','.3g','0.0001'],
    ['1e-300','.2e','1.00e-300'], ['1e+300','.2e','1.00e+300'],
    ['0.000001','.0%','0%'], ['1.23456789','.6f','1.234568'],
    ['9007199254740993',',d','9,007,199,254,740,993','int'],
    ['9007199254740993',',.2f','9,007,199,254,740,993.00','int'],
    ['12345.0','+,.1f','+12,345.0'], ['12345.0','.1g','1e+04'],
  ]) assert.equal(formatSavedValue({kind,value},spec),expected,`${value}:${spec}`);
});

test('invalid formats and nonnumeric data remain unsupported rather than guessed', () => {
  for (const spec of ['.13f','.99f','.0g','.2d','04d','bad','.__class__','.__import__("os")','',',', '.-1f']) {
    assert.equal(formatSavedValue({kind:'float',value:'125.0'},spec),undefined,spec);
  }
  for (const value of [{kind:'str',value:'125'}, {kind:'bool',value:true}, {kind:'none'}, {kind:'float',value:'nan'}, {kind:'int',value:'1e9999999'}]) {
    assert.equal(formatSavedValue(value,'.2f'),undefined);
  }
});

test('bindings are one-pass, document-scoped, and preserve escaping and legacy references', () => {
  const vars = new Map([['pv_old','legacy']]);
  registerNamedVariables(vars,new Map([
    ['planning.weekly_minutes',{kind:'float',value:'125.0'}],
    ['planning.π',{kind:'float',value:'3.14159'}],
    ['planning.text',{kind:'str',value:'{planning.weekly_minutes}'}],
  ]));
  const text = String.raw`{planning.weekly_minutes} {planning.weekly\_minutes:.2f} {planning.π:.2f} {{pv_old}} \{planning.weekly_minutes} \\{planning.weekly_minutes:.0f} {planning.text} {{planning.weekly_minutes}}`;
  assert.equal(substituteNativeVariables(text,vars),String.raw`125.0 125.00 3.14 legacy \{planning.weekly_minutes} \\125 {planning.weekly_minutes} {{planning.weekly_minutes}}`);
  assert.equal(substituteNativeVariables('{planning.weekly_minutes}',new Map()),'{planning.weekly_minutes}');
  assert.deepEqual(collectNativeReferences(String.raw`{missing.value:.99f} \{escaped.value} {{pv_old}}`),['missing.value:.99f','pv_old']);
  assert.equal(vars.has('planning.weekly_minutes'),false,'Dotted bindings must not become Python assignment targets');
});
