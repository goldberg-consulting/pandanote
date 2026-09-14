# Calculations you can reuse

Choose **Run Code Blocks…**, then open the **Variables** tab. The first block
creates `a`, `b`, and `c`. The second reads `c` from the first block without
depending on a shared global variable name.

```{python id="arithmetic"}
a = 1 + 4 / 2
b = 23
c = a / b
print(c)
```

```{python id="percentage" depends-on="arithmetic"}
ratio = pandanote["arithmetic"]["c"]
percent = ratio * 100
print(percent)
```

Choose **Insert Reference** beside `c` in the Variables tab, or write the readable
reference directly as shown below. Its value appears in the preview and PDF and
updates when the cell is rerun.

The calculated ratio is:

{arithmetic.c:.4f}

As a percentage: {arithmetic.c:.2%}. With three significant digits: {arithmetic.c:.3g}.

References use the cell ID and variable name. Change the number after the dot to
control precision. Backticks keep an example literal: `{arithmetic.c:.4f}`.

Ordinary Python fences also work. Pandanote adds a block ID on the first run.

```python
labels = ["a", "b", "c"]
settings = {"precision": 4, "enabled": True}
```
