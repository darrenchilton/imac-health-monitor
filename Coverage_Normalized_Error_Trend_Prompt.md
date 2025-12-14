# Coverage-Normalized Error Trend Chart Prompt

## Purpose
Generate a coverage-normalized daily error trend chart that corrects for changes in instrumentation over time and overlays events from SYSTEM_NOTES.

---

## Inputs
1. CSV containing:
   - `Timestamp` (MM/DD/YYYY h:mmam/pm)
   - `Error Count` (numeric)
   - multiple `error_*_1h` columns

2. `SYSTEM_NOTES.md` containing version history, incidents, and modifications with dated entries.

---

## Metric Definition (Coverage-normalized, regularized)

1. Parse `Timestamp` using explicit format:
   `%m/%d/%Y %I:%M%p`

2. Exclude the current partial day if specified
   (e.g. ignore `2025-12-14`).

3. Identify **error streams**:
   All columns matching `error_*_1h`.

4. For each error stream, compute:
   `first_seen(stream)` = first date where the stream value > 0.

5. For each day `d`, compute coverage:
   ```
   coverage(d) = active_streams(d) / total_streams
   ```
   where `active_streams(d)` are streams with `first_seen ≤ d`.

6. Compute daily average error count:
   ```
   daily_avg(d) = mean(Error Count on day d)
   ```

7. Compute coverage-normalized daily average:
   ```
   cn_avg(d) = daily_avg(d) / coverage(d)
   ```

8. Regularize scale:
   ```
   cn_norm(d) = cn_avg(d) / 100000
   ```
   Meaning: **100,000 errors = 1.0**

9. Compute a visual-only smoothed series:
   - 3-day centered rolling mean of `cn_norm(d)`

---

## Chart Requirements

- X-axis: Day
- Y-axis label:
  **Coverage-Normalized Daily Average Error Count (100k = 1)**

- Plot:
  - Solid line: `cn_norm(d)`
  - Dashed line: smoothed `cn_norm(d)`

---

## SYSTEM_NOTES Overlay (Events)

Parse `SYSTEM_NOTES.md` and extract dated events from:

- `## vX.Y.Z (YYYY-MM-DD) — Title`
  → Category: Version

- `## YYYY-MM-DD — Title`
  → Category: Incident / Modification

- `*YYYY-MM-DD: Title*` (optional)
  → Category: Note

---

## Overlay Rendering Rules

For each event date that falls within the chart’s date range:

- Draw a vertical dashed marker at that date
- Place a single-letter label (A, B, C…) at the top of the marker
- Assign letters in chronological order across ALL events
- Color-code markers by category

---

## Legend Formatting (Important)

Use **two separate legends**:

### Legend 1 — Series (top-left)
- Daily Avg (Coverage-normalized, 100k = 1)
- Smoothed (3-day)

### Legend 2 — Events (top-right or outside plot)
Group entries by category:
- **Versions**
- **Incidents / Modifications**
- **Notes** (only if few; otherwise output as table only)

Legend entries format:
```
A: Short title
```

---

## Output Requirements

- Display the chart
- Save the chart as a downloadable PNG
- Print a table with columns:
  `[Letter, Date, Category, Title]`

- Clearly state in output:
  - Coverage-normalized
  - Regularized: 100k errors = 1.0
  - Ignored partial date (if applicable)

---

## Constraints

- Do NOT fabricate missing errors
- Do NOT assume early low values indicate better health
- Correct only for observability, not behavior

If anything is ambiguous, ask before proceeding.
