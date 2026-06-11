# Diagrams — alphaxiv-dl

Graphviz diagram set explaining the tool from several angles. Each has a `.dot`
source plus rendered `.png` (raster) and `.svg` (vector). GitHub-dark theme,
colour-coded: **blue**=entry/actor, **green**=good/output, **amber**=caution/decision,
**red**=failure, **purple**=meta/network.

Rebuild any (or all) diagrams:

```bash
for f in diagrams/*.dot; do
  dot -Tpng "$f" -o "${f%.dot}.png"
  dot -Tsvg "$f" -o "${f%.dot}.svg"
done
```

| # | Diagram | What it explains |
|---|---------|------------------|
| 01 | [System Architecture](01_system_architecture.png) ([svg](01_system_architecture.svg)) | The two layers — alphaXiv discovery API + arXiv PDF host — and the CLI pipeline between them |
| 02 | [Data-flow Lifecycle](02_data_flow_lifecycle.png) ([svg](02_data_flow_lifecycle.svg)) | Per-paper path: dedup → validate → download → %PDF check → backoff/retry → manifest |
| 03 | [Network Topology](03_network_topology.png) ([svg](03_network_topology.svg)) | Host → HTTPS → api.alphaxiv.org (JSON) & export.arxiv.org (PDF); politeness + per-download fresh socket |
| 04 | [Human / Operator Visibility](04_human_user_visibility.png) ([svg](04_human_user_visibility.svg)) | Control inputs (flags, Ctrl-C) vs. visible outputs (log, manifest, files, summary) |
| 05 | [Future Directions](05_future_directions.png) ([svg](05_future_directions.svg)) | Roadmap: Range resume, stream-to-disk, bounded concurrency, config, cross-run dedupe, bulk path |
