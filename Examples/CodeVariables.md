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

Place the cursor below, then choose **Insert Reference** beside `c` in the Variables
tab. Its value appears in the preview and PDF. The inserted reference stays the
same when the value changes on a later run.

The calculated ratio is:

Ordinary Python fences also work. Pandanote adds a block ID on the first run.

```python
labels = ["a", "b", "c"]
settings = {"precision": 4, "enabled": True}
```
