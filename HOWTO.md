# HOWTO — alphaxiv-dl

A task-oriented guide. For the conceptual overview see [README.md](README.md);
for the visual model see [diagrams/](diagrams/).

## 1. Install Nim + build

```bash
# Nim via choosenim (https://nim-lang.org/install.html), then:
nim c -d:release -d:ssl alphaxiv_dl.nim
```

`-d:ssl` is required (HTTPS). OpenSSL must be present at runtime. Produces the
`alphaxiv_dl` binary in the current directory. A prebuilt Linux x86-64 binary
ships in this repo if you'd rather not build.

## 2. First feed run

```bash
./alphaxiv_dl feed --pages 1 --page-size 10 -o ./pdfs
```

You'll see the discovery line, then `[n] <id> <title>` and `saved:` lines as each
PDF streams in. Files land in `./pdfs`, with a `manifest.tsv` index alongside.

## 3. Search run

```bash
./alphaxiv_dl search "chain of thought reasoning" -n 10 -o ./cot
```

`-n 10` stops after 10 downloads (counting skips of already-present files).

## 4. Preview without downloading

```bash
./alphaxiv_dl feed --pages 2 --dry-run       # ids + titles, no fetch
./alphaxiv_dl search "diffusion" --ids-only  # bare ids, one per line (pipeable)
```

## 5. Resuming / re-running

Re-running the same command **skips** files that already exist and validate as
`%PDF` (logged `skip (have): ...`, counted as `skipped`). Safe to interrupt with
Ctrl-C and resume later — the manifest is append-mode.

## 6. Being polite (please do this)

```bash
./alphaxiv_dl feed --pages 30 --delay 5 --retries 4 \
  --ua "alphaxiv-dl/1.0 (+https://github.com/danindiana/alphaxiv-dl-nim; you@example.com)"
```

- `--delay` — seconds between requests (default 3). Raise it for big crawls.
- `--retries` — attempts per PDF with exponential backoff on 429/503/short reads.
- `--ua` — **set a real contact email.** arXiv asks for it on automated access.

## 7. Reading the manifest

`<out>/manifest.tsv` is tab-separated: `arxiv_id  status  path  title`.

| status | meaning |
|--------|---------|
| `ok` | downloaded and validated `%PDF` |
| `skipped` | already present and valid (resume) |
| `missing` | HTTP 404 — withdrawn / no PDF |
| `failed` | exhausted retries (throttle / truncation / network) |

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `error: no papers discovered` on `feed` | feed `interval` schema drift (`7d` → HTTP 400) | already handled by `apiInterval`; if alphaXiv changes again, check valid values (`3/7/30/90 Days`, `All time`) |
| Looks idle, no PDFs, many `--pages` | (old behaviour) crawled all pages before downloading | fixed — discovery now streams; PDFs start on page 1 |
| `Received length doesn't match expected length` | `std/httpclient` truncated body from reused keep-alive socket | fixed — fresh `Connection: close` client per download. To confirm a server vs. client issue, compare `curl -sIL <url>` + a timed `curl` download against the tool |
| `HTTP 404 (no PDF / withdrawn)` | paper withdrawn or PDF not yet on `export.arxiv.org` | expected; very recent ids may appear after a delay |
| `HTTP 429 / 503 (throttled)` | you're going too fast | raise `--delay`; backoff already retries |
| `got non-PDF body (HTML/captcha?)` | arXiv served an interstitial | backoff retries; if persistent, slow down and set a real `--ua` |

## 9. Large-scale harvesting

Don't use this tool for bulk full-text. arXiv provides a
[bulk dataset (S3/Kaggle)](https://info.arxiv.org/help/bulk_data.html) for that.
