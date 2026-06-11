## alphaxiv_dl.nim — paginating crawler + throttled-parallel PDF downloader
## ---------------------------------------------------------------------------
## alphaXiv (https://www.alphaxiv.org) is a discussion layer ON TOP OF arXiv.
## Every paper id is an arXiv id, so this tool:
##   1. DISCOVERS ids via alphaXiv's JSON API (paginated feed or search)
##   2. DOWNLOADS the PDFs from arXiv's automation host (export.arxiv.org),
##      optionally across a bounded worker pool — but with a GLOBAL throttle so
##      the aggregate request rate stays polite no matter how many threads run.
##
## Build (threads + HTTPS):
##   nimble build                 # uses settings below
##   nim c -d:release -d:ssl --threads:on alphaxiv_dl.nim
##
## Compile-time configurable defaults (all optional):
##   -d:alphaApi=URL  -d:arxivHost=URL  -d:outDir=PATH  -d:userAgent=STR
##   -d:sort=Hot  -d:interval=7d  -d:pageSize=20  -d:delaySecs=3
##   -d:retries=4  -d:defaultThreads=4
##
## Compatible with Nim 1.6.x and 2.2.x. Requires OpenSSL at runtime.
## For large harvests use arXiv's bulk dataset, not this crawler:
##   https://info.arxiv.org/help/bulk_data.html

import std/[httpclient, json, os, osproc, strutils, uri, sets]

# ── compile-time configurable defaults (override with -d:key=value) ─────────
const
  alphaApi      {.strdefine.} = "https://api.alphaxiv.org"
  arxivHost     {.strdefine.} = "https://export.arxiv.org/pdf"
  arxivFallbackHost {.strdefine.} = "https://arxiv.org/pdf"
  outDir        {.strdefine.} = "./alphaxiv_pdfs"
  sort          {.strdefine.} = "Hot"
  interval      {.strdefine.} = "7d"
  userAgent     {.strdefine.} = "alphaxiv-dl.nim/1.1 (+polite crawler; contact: you@example.com)"
  pageSize      {.intdefine.} = 20
  delaySecs     {.intdefine.} = 3
  retries       {.intdefine.} = 4
  defaultThreads {.intdefine.} = 4

type
  Mode = enum mFeed, mSearch
  Config = object
    mode: Mode
    query, sort, interval, outDir, ua, curl: string
    startPage, pages, pageSize, maxDl, retries, delayMs, threads: int
    dryRun, idsOnly, verbose: bool
  Paper = object
    id, title: string
  PreHook = proc() {.gcsafe.}   ## called right before each HTTP attempt

# ── stderr logging (gcsafe so it can run inside worker threads) ─────────────
proc logRaw(s: string) =
  {.cast(gcsafe).}:
    stderr.writeLine(s); stderr.flushFile()
proc e(s: string)     = logRaw(s)
proc dim(s: string)   = logRaw("\e[2m"  & s & "\e[0m")
proc okMsg(s: string) = logRaw("\e[32m" & s & "\e[0m")
proc warn(s: string)  = logRaw("\e[33mwarning:\e[0m " & s)
proc die(s: string) {.noreturn.} = logRaw("\e[31merror:\e[0m " & s); quit 1

proc usage() =
  e """alphaxiv_dl — crawl alphaXiv for paper ids, download PDFs from arXiv.

USAGE
  alphaxiv_dl feed   [options]
  alphaxiv_dl search "your query" [options]

OPTIONS
  -o, --out DIR        Output directory          (default: """ & outDir & """)
  -n, --max N          Stop after N downloads     (default: unlimited)
  -t, --threads N      Parallel download workers  (default: """ & $defaultThreads & """)
      --pages N        Feed pages to crawl        (default: 1)
      --start-page N   First feed page            (default: 1)
      --page-size N    Results per feed page      (default: """ & $pageSize & """)
      --sort S         Hot|Comments|Views|Likes|GitHub|Recommended|Recent (default: """ & sort & """)
      --interval W     Feed window: 3d|7d|30d|90d|all (default: """ & interval & """)
      --delay SECS     Min spacing between reqs   (default: """ & $delaySecs & """)
      --retries N      Retries on errors          (default: """ & $retries & """)
      --dry-run        List ids/titles; download nothing
      --ids-only       Print discovered arXiv ids only (one per line)
      --ua STRING      Override User-Agent (put your contact email in it!)
  -v, --verbose
  -h, --help

The --delay is a GLOBAL minimum spacing between request starts, enforced across
all worker threads, so raising --threads speeds up I/O-bound waits without
raising the rate you hit arXiv.

EXAMPLES
  alphaxiv_dl feed --pages 3 --page-size 20 -o ./pdfs -n 25 -t 4
  alphaxiv_dl search "chain of thought reasoning" -n 10 -o ./cot
  alphaxiv_dl feed --pages 2 --dry-run
  alphaxiv_dl search "diffusion models" --ids-only"""

# ── arXiv id validation (new: 2407.12345 ; old: hep-th/9901001) ────────────
proc digitsOnly(s: string): bool = s.len > 0 and s.allCharsInSet({'0'..'9'})

proc stripVersion(s: string): string =
  let i = s.rfind('v')
  if i > 0 and i < s.high and digitsOnly(s[i+1 .. ^1]): s[0 .. i-1] else: s

proc isArxivId(raw: string): bool =
  let s = stripVersion(raw)
  if '/' notin s and '.' in s:
    let p = s.split('.')
    return p.len == 2 and p[0].len == 4 and digitsOnly(p[0]) and
           p[1].len in 4..5 and digitsOnly(p[1])
  let sl = s.find('/')
  if sl < 1 or s.rfind('/') != sl: return false
  let num = s[sl+1 .. ^1]
  if not (num.len == 7 and digitsOnly(num)): return false
  var arch = s[0 .. sl-1]
  let dot = arch.find('.')
  if dot >= 0:
    let subj = arch[dot+1 .. ^1]
    if subj.len != 2 or not subj.allCharsInSet({'A'..'Z'}): return false
    arch = arch[0 .. dot-1]
  result = arch.len > 0 and arch.allCharsInSet({'a'..'z', '-'})

proc slug(title: string): string =
  var s = newStringOfCap(title.len)
  for ch in title.toLowerAscii:
    if ch in {'a'..'z', '0'..'9'}: s.add ch
    elif s.len == 0 or s[^1] != '-': s.add '-'
  s = s.strip(chars = {'-'})
  if s.len > 80: s = s[0 .. 79].strip(chars = {'-'})
  if s.len == 0: "untitled" else: s

# ── HTTP ───────────────────────────────────────────────────────────────────
proc newClient(cfg: Config): HttpClient =
  newHttpClient(userAgent = cfg.ua, timeout = 120_000, maxRedirects = 5)

# Fresh client with keep-alive disabled, for downloading PDFs. Nim's httpclient
# can short-read large SSL bodies on a REUSED keep-alive socket, raising
# "Received length doesn't match expected length". A clean socket per attempt
# (Connection: close) avoids the poisoned-connection failure mode. Each worker
# thread builds its own here, so this is thread-safe.
proc newDlClient(cfg: Config): HttpClient =
  newHttpClient(userAgent = cfg.ua, timeout = 120_000, maxRedirects = 5,
                headers = newHttpHeaders({"Connection": "close"}))

proc isPdf(body: string): bool = body.len >= 4 and body[0 .. 3] == "%PDF"
proc fileLen(p: string): int64 = (if fileExists(p): getFileSize(p) else: 0'i64)
proc startsPdf(p: string): bool =
  if not fileExists(p) or getFileSize(p) < 4: return false
  var f: File
  if not open(f, p): return false
  defer: f.close()
  var hdr = newString(4)
  result = f.readChars(hdr) == 4 and hdr == "%PDF"

# Trailing integer (the curl -w "%{http_code}" value) from merged stdout.
proc trailingInt(s: string): int =
  var i = s.len - 1
  while i >= 0 and s[i] in {'\n','\r',' ','\t'}: dec i
  var j = i
  while j >= 0 and s[j] in {'0'..'9'}: dec j
  if j == i: -1 else: (try: parseInt(s[j+1 .. i]) except ValueError: -1)

# HEAD via curl to learn the total size; (-1,-1) if unknown.
proc curlHead(cfg: Config, url: string): tuple[code: int, total: int64] =
  result = (-1, -1'i64)
  if cfg.curl.len == 0: return
  let (outp, _) = execCmdEx(quoteShellCommand(@[cfg.curl, "-sIL", "-A", cfg.ua,
                            "--max-time", "60", url]))
  for ln in outp.splitLines:
    let l = ln.toLowerAscii
    if l.startsWith("http/"):
      let parts = ln.splitWhitespace()
      if parts.len >= 2: result.code = (try: parseInt(parts[1]) except: result.code)
    elif l.startsWith("content-length:"):
      result.total = (try: parseInt(ln.split(':')[1].strip()).int64 except: result.total)

## Resumable single-host fetch via curl: append Range chunks into `tmp` until it
## reaches `total` (or a 416 says we already have everything). Tolerates the
## mid-stream connection drops export.arxiv.org currently throws on big PDFs.
proc curlFetch(cfg: Config, url, dest: string, pre: PreHook): string =
  let tmp = dest & ".part"
  removeFile(tmp)
  let (_, total) = curlHead(cfg, url)
  var stall = 0
  let chunk = dest & ".chunk"
  while true:
    if pre != nil: pre()                      # global throttle, per request
    let have = fileLen(tmp)
    removeFile(chunk)
    let (outp, _) = execCmdEx(quoteShellCommand(@[cfg.curl, "-sS", "-L", "-A", cfg.ua,
        "--max-time", "300", "-r", $have & "-", "-o", chunk, "-w", "%{http_code}", url]))
    let code = trailingInt(outp)
    if code == 404: removeFile(tmp); removeFile(chunk); return "missing"
    if code == 416: break                      # range past end → already complete
    let got = fileLen(chunk)
    if code == 200 and have > 0:
      moveFile(chunk, tmp)                      # server ignored Range → restart
    elif got > 0:
      let data = readFile(chunk)
      let f = open(tmp, fmAppend); f.write(data); f.close()
      removeFile(chunk)
    let now = fileLen(tmp)
    if total > 0 and now >= total: break
    if now == have: inc stall else: stall = 0
    if stall >= max(2, cfg.retries): removeFile(tmp); return "failed"
  removeFile(chunk)
  if fileLen(tmp) > 0 and startsPdf(tmp):
    moveFile(tmp, dest); return "ok"
  removeFile(tmp); return "failed"

# Nim std/httpclient fallback when curl is absent: fresh Connection: close
# client per attempt (avoids keep-alive short-reads); no resume.
proc nimFetch(cfg: Config, url, dest: string, pre: PreHook): string =
  var delay = cfg.delayMs
  for attempt in 1 .. cfg.retries:
    if pre != nil: pre()
    let dl = newDlClient(cfg)
    try:
      let resp = dl.get(url)
      let sc = resp.code.int
      if sc == 200:
        if isPdf(resp.body):
          writeFile(dest, resp.body); return "ok"
        warn(url & ": got non-PDF body (HTML/captcha?), retrying")
      elif sc == 404: return "missing"
      elif sc in [429, 503]:
        warn(url & ": HTTP " & $sc & " (throttled), backing off " & $(delay div 1000) & "s")
      else: warn(url & ": HTTP " & $sc)
    except CatchableError as ex:
      warn(url & ": " & ex.msg)
    finally: dl.close()
    sleep(delay); delay *= 2
  return "failed"

proc downloadPdf(client: HttpClient, cfg: Config, p: Paper,
                 pre: PreHook = nil): string =
  let bare = stripVersion(p.id).replace("/", "_")
  let fname = cfg.outDir / (bare & "__" & slug(p.title) & ".pdf")
  if fileExists(fname) and getFileSize(fname) > 0 and startsPdf(fname):
    dim("skip (have): " & fname); return "skipped"
  # try primary host, then fall back to arxiv.org if it truncates/fails
  for hi, host in [arxivHost, arxivFallbackHost]:
    if host.len == 0: continue
    let url = host & "/" & p.id
    let status =
      if cfg.curl.len > 0: curlFetch(cfg, url, fname, pre)
      else: nimFetch(cfg, url, fname, pre)
    case status
    of "ok": okMsg("saved: " & fname & (if hi > 0: "  (via fallback host)" else: "")); return "ok"
    of "missing": warn(p.id & ": HTTP 404 (no PDF / withdrawn)"); return "missing"
    else:
      if hi == 0: warn(p.id & ": primary host failed, trying fallback " & arxivFallbackHost)
  warn(p.id & ": giving up after all hosts")
  return "failed"

# ── discovery (sequential, paginated) ───────────────────────────────────────
# alphaXiv's feed API expects spelled-out window strings; map the friendly
# CLI shorthands (1d|7d|30d|90d|all) onto them. Pass-through if already long.
proc apiInterval(w: string): string =
  case w.toLowerAscii
  of "1d", "3d", "3 days": "3 Days"
  of "7d", "1w", "7 days": "7 Days"
  of "30d", "1m", "30 days": "30 Days"
  of "90d", "3m", "90 days": "90 Days"
  of "all", "all time": "All time"
  else: w

proc discoverFeed(client: HttpClient, cfg: Config): seq[Paper] =
  for page in cfg.startPage ..< cfg.startPage + cfg.pages:
    dim("crawling feed page " & $page & " (size " & $cfg.pageSize &
        ", sort=" & cfg.sort & ", interval=" & cfg.interval & ")")
    let url = alphaApi & "/papers/v3/feed?pageNum=" & $page &
              "&pageSize=" & $cfg.pageSize & "&sort=" & encodeUrl(cfg.sort) &
              "&interval=" & encodeUrl(apiInterval(cfg.interval))
    var node: JsonNode
    try: node = parseJson(client.getContent(url))
    except CatchableError as ex:
      warn("feed page " & $page & " failed: " & ex.msg & " (stopping)"); break
    let papers = node{"papers"}
    if papers == nil or papers.kind != JArray or papers.len == 0:
      dim("page " & $page & " empty — end of feed"); break
    for p in papers:
      result.add Paper(id: p{"universal_paper_id"}.getStr(""),
                       title: p{"title"}.getStr(""))
    sleep(cfg.delayMs)

proc discoverSearch(client: HttpClient, cfg: Config): seq[Paper] =
  dim("searching alphaXiv for: " & cfg.query)
  let url = alphaApi & "/search/v2/paper/fast?q=" & encodeUrl(cfg.query) &
            "&includePrivate=false"
  let node = parseJson(client.getContent(url))
  if node.kind != JArray: die("unexpected search response shape")
  for h in node:
    result.add Paper(id: h{"paperId"}.getStr(""), title: h{"title"}.getStr(""))

# ── manifest helper ─────────────────────────────────────────────────────────
proc manifestLine(cfg: Config, p: Paper, status: string): string =
  p.id & "\t" & status & "\t" & (cfg.outDir / stripVersion(p.id)) & "\t" & p.title

# ── sequential runner ───────────────────────────────────────────────────────
proc runSequential(cfg: Config, jobs: seq[Paper], manifest: File):
                   tuple[ok, skip, other: int] =
  let client = newClient(cfg)
  defer: client.close()
  for i, p in jobs:
    dim("[" & $(i+1) & "/" & $jobs.len & "] " & p.id & "  " &
        p.title[0 ..< min(70, p.title.len)])
    let status = downloadPdf(client, cfg, p)
    manifest.writeLine(manifestLine(cfg, p, status))
    case status
    of "ok": inc result.ok
    of "skipped": inc result.skip
    else: inc result.other
    if cfg.maxDl > 0 and result.ok + result.skip >= cfg.maxDl:
      dim("reached --max " & $cfg.maxDl & ", stopping."); break
    sleep(cfg.delayMs)

# ── parallel runner: bounded worker pool + global throttle ──────────────────
when compileOption("threads"):
  import std/[locks, atomics, monotimes, times]

  type Hub = object
    jobs: seq[Paper]
    cfg: Config
    manifest: File
    idx: Atomic[int]
    okCnt, skipCnt, otherCnt, finished: Atomic[int]
    lastReq: MonoTime
    hasLast: bool
    tlock, iolock: Lock

  ## Reserve the next evenly-spaced request slot, then sleep OUTSIDE the lock so
  ## downloads overlap while request *starts* stay >= delayMs apart globally.
  proc throttle(h: ptr Hub) {.gcsafe.} =
    acquire(h.tlock)
    let now = getMonoTime()
    let gap = initDuration(milliseconds = h.cfg.delayMs)
    var scheduled = now
    if h.hasLast and (now - h.lastReq) < gap: scheduled = h.lastReq + gap
    h.lastReq = scheduled; h.hasLast = true
    release(h.tlock)
    let waitMs = (scheduled - now).inMilliseconds
    if waitMs > 0: sleep(int(waitMs))

  proc worker(h: ptr Hub) {.thread.} =
    let client = newClient(h.cfg)
    defer: client.close()
    while true:
      if h.cfg.maxDl > 0 and
         h.okCnt.load() + h.skipCnt.load() >= h.cfg.maxDl: break
      let i = h.idx.fetchAdd(1)
      if i >= h.jobs.len: break
      let p = h.jobs[i]
      withLock h.iolock:
        dim("[" & $(i+1) & "/" & $h.jobs.len & "] " & p.id & "  " &
            p.title[0 ..< min(70, p.title.len)])
      let status = downloadPdf(client, h.cfg, p, proc() {.gcsafe.} = throttle(h))
      withLock h.iolock:
        h.manifest.writeLine(manifestLine(h.cfg, p, status))
      case status
      of "ok": discard h.okCnt.fetchAdd(1)
      of "skipped": discard h.skipCnt.fetchAdd(1)
      else: discard h.otherCnt.fetchAdd(1)

  proc runParallel(cfg: Config, jobs: seq[Paper], manifest: File):
                  tuple[ok, skip, other: int] =
    var hub = Hub(jobs: jobs, cfg: cfg, manifest: manifest)
    initLock(hub.tlock); initLock(hub.iolock)
    defer: (deinitLock(hub.tlock); deinitLock(hub.iolock))
    let n = max(1, min(cfg.threads, jobs.len))
    dim("starting " & $n & " download workers (global spacing " &
        $(cfg.delayMs div 1000) & "s)")
    var threads = newSeq[Thread[ptr Hub]](n)
    for t in 0 ..< n: createThread(threads[t], worker, addr hub)
    joinThreads(threads)
    (hub.okCnt.load(), hub.skipCnt.load(), hub.otherCnt.load())

# ── argument parsing ────────────────────────────────────────────────────────
proc parseArgs(): Config =
  result = Config(sort: sort, interval: interval, startPage: 1, pages: 1,
                  pageSize: pageSize, maxDl: 0, retries: retries,
                  delayMs: delaySecs * 1000, threads: defaultThreads,
                  outDir: outDir, ua: userAgent, curl: findExe("curl"))
  let args = commandLineParams()
  if args.len == 0: usage(); quit 1
  case args[0]
  of "feed": result.mode = mFeed
  of "search": result.mode = mSearch
  of "-h", "--help": usage(); quit 0
  else: die("unknown mode '" & args[0] & "' (expected: feed | search)")

  var i = 1
  if result.mode == mSearch:
    if i < args.len and not args[i].startsWith("-"):
      result.query = args[i]; inc i
    else: die("search requires a query string")

  proc need(name: string): string =
    if i + 1 >= args.len: die(name & " requires a value")
    inc i; args[i]
  proc needInt(name: string): int =
    try: parseInt(need(name))
    except ValueError: die(name & " expects an integer")
  proc needFloat(name: string): float =
    try: parseFloat(need(name))
    except ValueError: die(name & " expects a number")

  while i < args.len:
    case args[i]
    of "-o", "--out":     result.outDir = need(args[i])
    of "-n", "--max":     result.maxDl = needInt(args[i])
    of "-t", "--threads": result.threads = needInt(args[i])
    of "--pages":         result.pages = needInt(args[i])
    of "--start-page":    result.startPage = needInt(args[i])
    of "--page-size":     result.pageSize = needInt(args[i])
    of "--sort":          result.sort = need(args[i])
    of "--interval":      result.interval = need(args[i])
    of "--delay":         result.delayMs = int(needFloat(args[i]) * 1000)
    of "--retries":       result.retries = needInt(args[i])
    of "--ua":            result.ua = need(args[i])
    of "--dry-run":       result.dryRun = true
    of "--ids-only":      result.idsOnly = true; result.dryRun = true
    of "-v", "--verbose": result.verbose = true
    of "-h", "--help":    usage(); quit 0
    else: die("unknown option '" & args[i] & "' (try --help)")
    inc i
  if result.threads < 1: result.threads = 1

# ── main ────────────────────────────────────────────────────────────────────
proc main() =
  var cfg = parseArgs()
  when not compileOption("threads"):
    if cfg.threads > 1:
      warn("built without --threads:on; running single-threaded")
    cfg.threads = 1

  let client = newClient(cfg)
  if not cfg.idsOnly:
    dim("alphaxiv-dl — discovery via alphaXiv API, PDFs from arXiv (" &
        arxivHost & ")")
    dim("be considerate: delay=" & $(cfg.delayMs div 1000) & "s, retries=" &
        $cfg.retries & ", threads=" & $cfg.threads & ". Ctrl-C to stop.")

  var found: seq[Paper]
  try:
    found = if cfg.mode == mFeed: discoverFeed(client, cfg)
            else: discoverSearch(client, cfg)
  except CatchableError as ex:
    die("discovery failed: " & ex.msg)
  client.close()
  if found.len == 0: die("no papers discovered")

  # dedupe + keep valid arXiv ids
  var seen = initHashSet[string]()
  var jobs: seq[Paper]
  for p in found:
    if p.id.len == 0 or p.id in seen: continue
    seen.incl p.id
    if not isArxivId(p.id):
      warn("skipping non-arXiv id: '" & p.id & "'"); continue
    jobs.add p

  if cfg.idsOnly:
    for p in jobs: echo p.id
    return
  if jobs.len == 0: die("no arXiv papers to download")

  if cfg.dryRun:
    for i, p in jobs:
      dim("[" & $(i+1) & "/" & $jobs.len & "] " & p.id & "  " &
          p.title[0 ..< min(70, p.title.len)])
    okMsg("dry-run: " & $jobs.len & " papers would be downloaded")
    return

  createDir(cfg.outDir)
  let mpath = cfg.outDir / "manifest.tsv"
  let fresh = not fileExists(mpath)
  var manifest = open(mpath, fmAppend)
  if fresh: manifest.writeLine("arxiv_id\tstatus\tpath\ttitle")

  var r: tuple[ok, skip, other: int]
  when compileOption("threads"):
    r = if cfg.threads > 1: runParallel(cfg, jobs, manifest)
        else: runSequential(cfg, jobs, manifest)
  else:
    r = runSequential(cfg, jobs, manifest)
  manifest.close()

  e ""
  okMsg("done. downloaded=" & $r.ok & "  skipped=" & $r.skip &
        "  other=" & $r.other)
  dim("files in: " & cfg.outDir & "   (manifest: " & mpath & ")")

when isMainModule and not defined(alphaxivLib):
  main()
