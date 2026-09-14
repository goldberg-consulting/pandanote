---
title: Session analysis
author: Pandanote
template: default
---

# Session analysis

These fictional observations illustrate reusable calculations, not research findings.
Choose **Run Code Blocks…** and open **Variables** to inspect the results.

## Summarize the observations

```{python id="sessions" display="both"}
minutes = [20, 25, 30, 25]
sessions = len(minutes)
total = sum(minutes)
average = total / sessions
print(f"{sessions} sessions, {total} minutes, mean {average:.1f} minutes")
```

## Reuse a result

```{python id="planning" depends-on="sessions" display="both"}
weekly_sessions = 5
weekly_minutes = pandanote["sessions"]["average"] * weekly_sessions
print(f"Five sessions would take {weekly_minutes:.0f} minutes.")
```

Use the cell ID and variable name in prose, with an optional numeric format:

The mean session length is {sessions.average:.1f} minutes.

Five sessions would take {planning.weekly_minutes:.0f} minutes.

Return to [[Field notes]].

#research #analysis
