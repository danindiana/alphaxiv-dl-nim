# alphaxiv_dl.nim — test / debug session

**Date:** 2026-06-11 13:03:44
**Machine:** worlock
**Source:** `/home/jeb/Downloads/alphaxiv_dl.nim` (alphaXiv crawler + arXiv PDF downloader, Nim)

## Goal
Compile, test, and debug `alphaxiv_dl.nim` — a polite paginating crawler that
discovers paper ids via the alphaXiv JSON API and downloads PDFs from
`export.arxiv.org`.

## Environment
- Nim 2.2.0, OpenSSL at runtime
- Build: `nim c -d:release -d:ssl alphaxiv_dl.nim` — compiles clean (no warnings)

## Bug found: feed `interval` schema drift
The alphaXiv feed API (`/papers/v3/feed`) changed its `interval` query
parameter. The script sent shorthand (`1d|7d|30d|all`); the API now rejects
these with **HTTP 400** and demands spelled-out windows:

```
"3 Days" | "7 Days" | "30 Days" | "90 Days" | "All time"
```

Symptom: every `feed` run died with
`warning: feed page 1 failed: 400 Bad Request (stopping)` →
`error: no papers discovered`. (search mode was unaffected.)

Also confirmed the valid `sort` options changed to:
`Hot | Comments | Views | Likes | GitHub | Recommended | Recent`
(old usage text said `Hot|New|Top`).

## Fix
- Added `proc apiInterval(w)` mapping CLI shorthands → API strings
  (`7d`→`7 Days`, `all`→`All time`, etc.; long forms pass through).
- Wrapped the interval in the feed URL with `apiInterval(cfg.interval)`.
- Updated `--sort` / `--interval` help text to the current valid values.

`universal_paper_id` (the arXiv id field) is unchanged and still correct.

## Verification (all live, passing)
| Test | Result |
|------|--------|
| `--help` / no-args exit codes | 0 / 1 ✓ |
| unknown mode | clean error, exit 1 ✓ |
| `feed --ids-only` | 5 arXiv ids returned ✓ |
| `search "chain of thought" --dry-run` | 5 titled hits ✓ |
| `search "attention is all you need" -n 1` | 2.2 MB PDF, `%PDF` valid, manifest written ✓ |
| rerun same | correctly **skipped** (resume path) ✓ |
| `feed -n 1` | downloaded valid 9-page PDF ✓ |

## Enhancement: streaming downloads (interleave discovery + download)
**Report:** with `--pages 30 --page-size 20`, "not downloading any PDFs" —
actually it *looked* idle because the original design ran in two strict phases:
it crawled **all** `--pages` into a `seq[Paper]` first (≈3s/page delay → ~90s of
"crawling feed page N…") before the download loop even started.

**Fix:** converted `discoverFeed`/`discoverSearch` from `proc … : seq[Paper]`
into `iterator … : Paper` that **yield** page-by-page. `main()` now downloads
each paper the instant it's discovered. Per-paper handling factored into a
`handle(p): bool` closure (dedup → validate → download → manifest); returning
`false` (e.g. `--max` reached) breaks the consuming loop, which also stops the
iterator from fetching further pages (no over-crawl). Per-page sleep skipped on
the final page.

**Verified:** `feed --pages 30 --page-size 20 -n 4` saves the first PDF while
still on page 1; stops cleanly at `--max`; all files valid PDFs.

## Bug: "Received length doesn't match expected length" on large PDFs
**Symptom:** big PDFs (e.g. `2606.11289`, 27 MB) raised this repeatedly —
`Wanted 27883555 got: 9437184` / `13631488` — retried, never completed.

**This is NOT a compile-time type error** — it's a runtime exception from Nim's
`std/httpclient`: the body read came up short of the `Content-Length` header
(truncated stream), so httpclient raises and the retry loop catches it.

**Debugging method that isolated it:**
1. `curl -sIL` → real `Content-Length: 27883555`; a timed full `curl` pulled all
   27 MB in **0.33s** with no error → server, network, 120s timeout all fine.
2. `got:` values were exact 1 MB multiples and **varied** across retries
   (9 MB → 13 MB) → connection/buffering race, not deterministic corruption.
3. → fault is client-side. Root cause: a single shared `HttpClient` was reused
   for the whole run; Nim's httpclient reuses the keep-alive TLS socket, and on
   large SSL bodies a reused socket can short-read and raise. Retrying on the
   same poisoned client keeps failing.

**Fix:** added `newDlClient(cfg)` — a fresh client with `Connection: close`
headers — and `downloadPdf` now builds one **per attempt** (clean socket every
time), with `finally: dl.close()` to avoid leaks. Discovery still uses the
shared JSON client.

**Verified:** `2606.11289` now downloads in a **single attempt**, exactly
27883555 bytes, valid PDF, zero retries.

**General rule for this error class in Nim:** suspect (a) reused keep-alive
client, (b) too-short timeout on a slow body, or (c) a truncating server — the
curl-vs-program comparison tells you which. For very large files,
`client.downloadFile(url, path)` streams to disk and sidesteps body buffering.

## Outcome
Three issues resolved end-to-end: feed `interval` schema drift (400),
non-streaming two-phase crawl, and keep-alive short-read on large PDFs. Fixed
`alphaxiv_dl.nim` + rebuilt binary copied back to `/home/jeb/Downloads/`. Test
PDF artifacts cleaned up.
