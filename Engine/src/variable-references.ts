/** Formatting reads captured data only; it never evaluates Python or expressions. */
export type SavedValue = { kind: 'none'|'int'|'float'|'str'|'bool'|'list'|'dict'; value?: any };

const namedValues = new WeakMap<Map<string,string>, Map<string,SavedValue>>();
export function registerNamedVariables(legacy: Map<string,string>, named: Map<string,SavedValue>): void {
  // Keep dotted names out of the legacy map, which also seeds inline Python globals.
  namedValues.set(legacy, named);
}

export function namedReference(block: string, variable: string): string | undefined {
  return /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(block)
    && /^[_\p{ID_Start}][\p{ID_Continue}]*$/u.test(variable) && variable.length <= 256
    ? `{${block}.${variable}}` : undefined;
}

/** JSON text for collections preserves integer precision without executing values. */
export function renderSavedValue(value: SavedValue, nested = false): string {
  switch (value.kind) {
    case 'none': return 'null';
    case 'str': return nested ? JSON.stringify(value.value) : value.value;
    case 'int': return value.value;
    case 'float': case 'bool': return String(value.value);
    case 'list': return '[' + value.value.map((item: SavedValue) => renderSavedValue(item,true)).join(', ') + ']';
    case 'dict': return '{' + value.value.map(([key,item]: [string,SavedValue]) => JSON.stringify(key) + ': ' + renderSavedValue(item,true)).join(', ') + '}';
  }
}

type Decimal = { negative: boolean; coefficient: bigint; exponent: number };
function decimal(value: SavedValue): Decimal | undefined {
  if (!['int','float'].includes(value.kind) || typeof value.value !== 'string') return undefined;
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/i.exec(value.value);
  if (!match || value.value.length > 2600) return undefined;
  const exponent = Number(match[4] || 0) - (match[3]?.length || 0);
  if (!Number.isSafeInteger(exponent) || Math.abs(exponent) > 3000) return undefined;
  return { negative: match[1] === '-', coefficient: BigInt(match[2] + (match[3] || '')), exponent };
}

/** Round the saved decimal representation to nearest, ties to even. No Number coercion. */
function rounded(value: Decimal, places: number): bigint {
  const shift = value.exponent + places;
  if (shift >= 0) return value.coefficient * 10n ** BigInt(shift);
  const divisor = 10n ** BigInt(-shift), quotient = value.coefficient / divisor;
  const remainder = value.coefficient % divisor;
  return quotient + (remainder * 2n > divisor || (remainder * 2n === divisor && quotient % 2n === 1n) ? 1n : 0n);
}
function fixed(value: Decimal, places: number): string {
  const digits = rounded(value,places).toString().padStart(places + 1,'0');
  return places ? digits.slice(0,-places) + '.' + digits.slice(-places) : digits;
}
function scientific(value: Decimal, places: number): { mantissa: string; order: number } {
  let order = value.coefficient === 0n ? 0 : value.coefficient.toString().length - 1 + value.exponent;
  let digits = rounded(value, places - order).toString().padStart(places + 1,'0');
  if (digits.length > places + 1) { order++; digits = digits.slice(0,-1); }
  return { mantissa: places ? digits[0] + '.' + digits.slice(1) : digits, order };
}
const exponentText = (order: number) => 'e' + (order < 0 ? '-' : '+') + String(Math.abs(order)).padStart(2,'0');
const trimFraction = (text: string) => text.includes('.') ? text.replace(/0+$/,'').replace(/\.$/,'') : text;

/** A deliberately bounded format grammar: [+][,][.precision]f/e/g/% or [+][,]d. */
export function formatSavedValue(value: SavedValue, spec: string): string | undefined {
  const format = /^(\+?)(,?)(?:\.(\d{1,2}))?([feg%d])$/.exec(spec), number = decimal(value);
  if (!format || !number) return undefined;
  const [,sign,group,precision,style] = format;
  const places = precision === undefined ? (style === 'd' ? 0 : 6) : Number(precision);
  if (places > 12 || (style === 'g' && places === 0) || (style === 'd' && (value.kind !== 'int' || precision !== undefined))) return undefined;
  let text: string;
  if (style === 'f' || style === 'd') text = fixed(number,places);
  else if (style === '%') text = fixed({...number, exponent:number.exponent + 2},places) + '%';
  else {
    const result = scientific(number,style === 'g' ? places - 1 : places);
    text = style === 'g'
      ? result.order < -4 || result.order >= places
        ? trimFraction(result.mantissa) + exponentText(result.order)
        : trimFraction(fixed(number,Math.max(0,places - result.order - 1)))
      : result.mantissa + exponentText(result.order);
  }
  if (group) text = text.replace(/^\d+/, integer => integer.replace(/\B(?=(\d{3})+(?!\d))/g,','));
  return (number.negative ? '-' : sign) + text;
}

function references(): RegExp {
  // Escaped underscores from Markdown editors are accepted; escaped opening braces are literal.
  return /\{\{(\w+)\}\}|(?<!\{)\{([A-Za-z](?:[A-Za-z0-9_-]|\\_){0,126})\.((?:[_\p{ID_Start}]|\\_)(?:[\p{ID_Continue}]|\\_){0,510})(?::([^{}\r\n]{0,80}))?\}(?!\})/gu;
}
function escaped(text: string, index: number): boolean {
  let slashes = 0;
  while (index > 0 && text[--index] === '\\') slashes++;
  return slashes % 2 === 1;
}
export function collectNativeReferences(text: string): string[] {
  return [...text.matchAll(references())].filter(match => !escaped(text,match.index!))
    .map(match => match[1] || match[2] + '.' + match[3] + (match[4] === undefined ? '' : ':' + match[4]));
}
export function substituteNativeVariables(text: string, legacy: Map<string,string>): string {
  const named = namedValues.get(legacy);
  // One pass prevents a variable's data from becoming another reference.
  return text.replace(references(), (match,old,block,name,spec,index) => {
    if (escaped(text,index)) return match;
    if (old) return legacy.get(old) ?? match;
    block = block.replace(/\\_/g,'_'); name = name.replace(/\\_/g,'_');
    if (!namedReference(block,name)) return match;
    const value = named?.get(block + '.' + name);
    if (!value) return match;
    return spec === undefined ? renderSavedValue(value) : formatSavedValue(value,spec) ?? match;
  });
}
