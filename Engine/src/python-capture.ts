/** Executed only by an explicit, trusted Run. Snapshots contain data, never pickle. */
export const PYTHON_CAPTURE_VERSION = 'pandanote-variables-v1';
export const VARIABLE_ARTIFACT = 'pandanote-variables';
export const PYTHON_CAPTURE = String.raw`
import json as _json, math as _math, os as _os, runpy as _runpy, sys as _sys, types as _types

def _restore(node):
    kind, value = node['kind'], node.get('value')
    if kind == 'none': return None
    if kind == 'int': return int(value)
    if kind == 'float': return float(value)
    if kind in ('str', 'bool'): return value
    if kind == 'list': return [_restore(item) for item in value]
    if kind == 'dict': return {key: _restore(item) for key, item in value}
    raise ValueError('Unsupported saved variable')

def _encode(value, depth=0, seen=None, budget=None):
    if seen is None: seen = set()
    if budget is None: budget = [0]
    budget[0] += 1
    if budget[0] > 5000: raise ValueError('Collection exceeds capture limit')
    kind = type(value)
    if value is None: return {'kind': 'none'}
    if kind is bool: return {'kind': 'bool', 'value': value}
    if kind is int:
        if value.bit_length() > 8192: raise ValueError('Integer exceeds capture limit')
        return {'kind': 'int', 'value': str(value)}
    if kind is float:
        if not _math.isfinite(value): raise ValueError('Non-finite number')
        return {'kind': 'float', 'value': str(value)}
    if kind is str:
        if len(value) > 65536: raise ValueError('String exceeds capture limit')
        return {'kind': 'str', 'value': value}
    if kind not in (list, dict): raise ValueError('Object is available for inspection only')
    if depth >= 8 or len(value) > 1000 or id(value) in seen: raise ValueError('Collection exceeds capture limit or contains a cycle')
    seen.add(id(value))
    try:
        if kind is list: return {'kind': 'list', 'value': [_encode(item, depth + 1, seen, budget) for item in value]}
        if any(type(key) is not str or len(key) > 1024 for key in value): raise ValueError('Dictionary keys must be short strings')
        return {'kind': 'dict', 'value': [[key, _encode(item, depth + 1, seen, budget)] for key, item in value.items()]}
    finally: seen.remove(id(value))

def _describe(value):
    kind = type(value)
    if kind is str: return value[:240] + ('…' if len(value) > 240 else '')
    if value is None or kind in (bool, float): return str(value)
    if kind is int: return str(value) if value.bit_length() <= 8192 else '<large integer>'
    if kind is list: return str(len(value)) + ' items'
    if kind is dict: return str(len(value)) + ' keys'
    if kind is tuple: return str(len(value)) + ' items (tuple)'
    return '<' + type.__getattribute__(kind, '__name__')[:120] + '>'

def _main():
    script, config_file, target = _sys.argv[1:]
    with open(config_file, encoding='utf-8') as stream: config = _json.load(stream)
    namespaces = {block: {name: _restore(value) for name, value in values.items()} for block, values in config['namespaces'].items()}
    hashes = {name: _restore(value) for name, value in config['hashes'].items()}
    _sys.argv = [script]
    _sys.path.insert(0, _os.path.dirname(script))
    values = _runpy.run_path(script, init_globals={'pandanote': namespaces, 'pandanote_vars': hashes}, run_name='__main__')
    captured, total, omitted = [], 0, 0
    for name, value in values.items():
        if name.startswith('__') or name in ('pandanote', 'pandanote_vars') or isinstance(value, _types.ModuleType): continue
        if len(captured) >= 256 or len(name) > 256:
            omitted += 1
            continue
        item = {'name': name, 'type': type.__getattribute__(type(value), '__name__')[:120], 'preview': _describe(value)[:500], 'reusable': False}
        try:
            encoded = _encode(value)
            size = len(_json.dumps(encoded, ensure_ascii=True))
            if size > 262144 or total + size > 1048576: raise ValueError('Snapshot size limit')
            item['value'], item['reusable'] = encoded, True
            total += size
        except (ValueError, OverflowError, RecursionError): pass
        captured.append(item)
    snapshot = {'schemaVersion': 1, 'documentIdentity': config['documentIdentity'], 'blockId': config['blockId'], 'variables': captured, 'omitted': omitted}
    with open(target, 'x', encoding='utf-8') as stream: _json.dump(snapshot, stream, ensure_ascii=True, allow_nan=False)

_main()
`;
