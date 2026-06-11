# alphaxiv-dl — parallel fork (v1.1)

A fork of the parent [`alphaxiv_dl.nim`](../alphaxiv_dl.nim) that adds a
**bounded worker pool with a global throttle** and **compile-time tunables**,
then was hardened during build/test/debug on 2026-06-11.

## What this fork adds over the parent

- **Throttled-parallel downloads** (`-t N`): N worker threads, but a *global*
  minimum spacing between request **starts** (`--delay`) enforced across all
  threads — so more workers speed up I/O waits without raising the rate you hit
  arXiv. (`runParallel` + `throttle()` using a `MonoTime` lock.)
- **Compile-time defaults** via `{.strdefine.}` / `{.intdefine.}`
  (`-d:delaySecs=5 -d:defaultThreads=8 -d:arxivHost=…`), an `alphaxiv_dl.nimble`
  package, and `config.nims` (auto `-d:ssl --threads:on --mm:orc`).
- **Sequential path** preserved (`-t 1` or built `--threads:off`).

## Fixes applied during debug (this session)

1. **Feed `interval` HTTP 400 regression** — the fork shipped without the
   parent's `apiInterval` mapping, so `feed` died with "no papers discovered".
   Re-added the `7d → "7 Days"` mapping.
2. **Resumable, host-failover downloads** — `export.arxiv.org` currently
   **drops the connection mid-stream** on large PDFs (verified: even `curl`
   truncates at random 1–10 MB points; `arxiv.org` serves them whole). The fix:
   - download via **`curl`** when present (Range-resume: append `bytes=N-` chunks
     into a `.part` file until `Content-Length` is reached, tolerating drops),
     falling back to **Nim `std/httpclient`** (fresh `Connection: close` client
     per attempt) when curl is absent;
   - keep `export.arxiv.org` as the **default** (arXiv's automation host) and
     **auto-fall-back to `arxiv.org`** after repeated truncation.
   - Net result: 21 MB / 28 MB PDFs that previously failed all retries now
     complete; re-runs correctly skip; temp files are cleaned up.

> Root-cause note: the "Received length doesn't match expected length" errors
> here were **server-side truncation on export.arxiv.org**, not the parent's
> keep-alive client bug. The tell: `curl` *also* failed (the parent's curl test
> succeeded). Always compare `curl` against the program to tell client bugs from
> server behaviour.

## Build & run

```bash
nimble build                                  # or:
nim c -d:release -d:ssl --threads:on --mm:orc -o:alphaxiv_dl alphaxiv_dl.nim

./alphaxiv_dl feed --pages 3 --page-size 20 -o ./pdfs -n 25 -t 4
./alphaxiv_dl search "chain of thought reasoning" -n 10 -o ./cot -t 4
```

`nimble smoke` builds both threaded (`alphaxiv_dl`) and single-threaded
(`alphaxiv_dl_st`) variants. Needs OpenSSL at runtime; `curl` strongly
recommended for large-PDF reliability.
