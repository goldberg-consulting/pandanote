# Cell results in your writing

Give a Python cell a name with `id="…"`, then refer to a captured variable using
**`{cell_id.variable_name}`** in ordinary Markdown prose. Choose **Run Code Blocks**
to capture results; preview and PDF use the same saved values and formatting.

````markdown
```{python id="sessions"}
average = 25.0
```

```{python id="planning" depends-on="sessions"}
weekly_sessions = 5
weekly_minutes = pandanote["sessions"]["average"] * weekly_sessions
print(f"Five sessions would take {weekly_minutes:.0f} minutes.")
```

Five sessions would take {planning.weekly_minutes:.0f} minutes.
````

The last sentence renders as **Five sessions would take 125 minutes.** `print()`
produces the cell's ordinary output; capturing a variable does not require printing
it. `depends-on="sessions"` makes the earlier cell's values available inside Python.
Prose references do not need a separate dependency declaration.

## Rounding and number formatting

Add a colon and format before the closing brace:

- `{planning.weekly_minutes}` → `125.0` (the captured value, without formatting).
- `{planning.weekly_minutes:.0f}` → `125` (round to a whole number).
- `{planning.weekly_minutes:.2f}` → `125.00` (exactly two decimal places).
- `{planning.weekly_minutes:,.2f}` → `125.00`; a value of `12345.678` becomes
  `12,345.68` (commas between thousands).
- `{planning.weekly_minutes:+.1f}` → `+125.0` (show the positive sign).
- `{planning.weekly_minutes:.2e}` → `1.25e+02` (scientific notation).
- `{planning.weekly_minutes:.3g}` → `125` (three significant digits, trailing
  fractional zeros removed; scientific notation for very small or large values).
- `{planning.weekly_sessions:,d}` → `5` (integer formatting with grouping).

For a captured ratio of `0.256`, `{planning.ratio:.1%}` displays `25.6%`. Percentage
formatting multiplies by 100; if a variable already contains `25.6`, use
`{planning.percent:.1f}%` instead.

Change the precision to **0–12 decimal places** for `f`, `%`, and `e`, or **1–12
significant digits** for `g`. The supported grammar is `[+][,][.precision]f/e/g/%`
or `[+][,]d`. The optional pieces are written without square brackets. Formats
without an explicit precision use six places/digits; `d` is for integers only.
Separators are deterministic: decimal point and optional grouping commas.

Rounding uses the captured decimal representation, to nearest with ties to even:
`2.665` at two places becomes `2.66`, while `2.675` becomes `2.68`. This avoids
converting large integers or decimal strings through JavaScript floating point.
It is a small, Python-style formatting grammar, not execution of Python's format
function; Python's binary-float rounding can differ at exact decimal boundaries.
Formatting changes only the displayed text, never the value used by other cells.

## Using the Variables panel

**Insert Reference** inserts the readable cell/variable reference. For a number,
open its **… → Insert with Format** menu for whole numbers, decimal places,
grouping, percentages, scientific notation, or significant digits. **How to Use…**
provides copyable examples and explains how to change precision in the reference.

Use cell IDs starting with a letter, followed by letters, digits, underscores, or
hyphens, up to 64 characters. IDs must be unique within the note. Variable names
are case-sensitive and belong to their cell, so `{first.average}` and
`{second.average}` remain independent. Python Unicode variable names are supported.

## Custom text, dates, and currencies

Format a string in Python when you need custom wording, a date format, a locale,
or something outside the numeric grammar:

````markdown
```{python id="budget"}
cost = 12345.678
cost_label = f"USD {cost:,.2f}"
```

Estimated cost: {budget.cost_label}.
````

Numeric format suffixes apply to captured integers and floats, not strings,
booleans, or collections. Strings and supported collections can be inserted
without a suffix. A formatted string still comes from a named cell result.

## Literal examples, missing results, and old references

Use backticks, a fenced/indented code example, or an escaped opening brace
(`\{planning.weekly_minutes}`) to show a reference literally. Escaped underscores
such as `{planning.weekly\_minutes}` are accepted too. The preferred form does not
need the underscore escaped.

Unknown variables, duplicate IDs, stale/failed runs, and unsupported formats stay
visible as unresolved references. Preview responses report diagnostics; PDF builds
include warnings in the build output. Rerun changed cells, fix the name, or choose
a supported format. Merely opening a preview does not run Python.

Readable references resolve within their current note. Rerunning a cell updates
its values. If you rename a cell or a variable, update the references as well.
Existing `{{pv_…}}` references remain supported; the internal IDs continue to
identify captured values. These additions are in Pandanote's native Inkwell bridge;
the upstream VS Code extension needs the same feature before it can resolve this
syntax independently.
