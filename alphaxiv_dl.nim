## alphaxiv_dl.nim — paginating crawler + PDF downloader for alphaXiv / arXiv
## ---------------------------------------------------------------------------
## alphaXiv (https://www.alphaxiv.org) is a discussion layer ON TOP OF arXiv.
## It does not host original PDFs — every paper id is an arXiv id. This tool:
##
##   1. DISCOVERS paper ids via alphaXiv's JSON API (paginated feed or search)
##   2. DOWNLOADS the PDFs from arXiv's automation host (export.arxiv.org)
##
## It is deliberately polite: one client, rate-limited, exponential backoff on
## 429/503, descriptive User-Agent, resumes/skips existing files, and validates
## that what it got is actually a PDF.
##
## Please respect alphaXiv's and arXiv's Terms of Use. For LARGE-scale full-text
## harvesting arXiv asks you to use its bulk dataset (S3/Kaggle) instead — see
## https://info.arxiv.org/help/bulk_data.html . This tool is for modest use.
##
## Build (HTTPS needs the ssl define):
##   nim c -d:release -d:ssl alphaxiv_dl.nim
## Compatible with Nim 1.6.x and 2.2.x. Requires OpenSSL at runtime.

import std/[httpclient, json, os, strutils, uri, sets]

const
  AlphaApi     = "https://api.alphaxiv.org"
  ArxivPdfHost = "https://export.arxiv.org/pdf"
  Version      = "alphaxiv-dl.nim/1.0"

type
  Mode = enum mFeed, mSearch
  Config = object
    mode: Mode
    query: string
    sort: string
    interval: string
    startPage, pages, pageSize, maxDl, retries: int
    delayMs: int
    outDir: string
    ua: string
    dryRun, idsOnly, verbose: bool
  Paper = object
    id, title: string

# ── tiny stderr logging (colour) ───────────────────────────────────────────
proc e(s: string) = stderr.writeLine s
proc dim(s: string)  = e("\e[2m"  & s & "\e[0m")
proc okMsg(s: string) = e("\e[32m" & s & "\e[0m")
proc warn(s: string) = e("\e[33mwarning:\e[0m " & s)
proc die(s: string) {.noreturn.} = e("\e[31merror:\e[0m " & s); quit 1

proc usage() =
  e """alphaxiv_dl — crawl alphaXiv for paper ids, download PDFs from arXiv.

USAGE
  alphaxiv_dl feed   [options]
  alphaxiv_dl search "your query" [options]

OPTIONS
  -o, --out DIR        Output directory          (default: ./alphaxiv_pdfs)
  -n, --max N          Stop after N downloads     (default: unlimited)
      --pages N        Feed pages to crawl        (default: 1)
      --start-page N   First feed page            (default: 1)
      --page-size N    Results per feed page      (default: 20)
      --sort S         Feed sort: Hot|Comments|Views|Likes|GitHub|Recommended|Recent (default: Hot)
      --interval W     Feed window: 3d|7d|30d|90d|all (default: 7d)
      --delay SECS     Delay between requests     (default: 3)
      --retries N      Retries on errors          (default: 4)
      --dry-run        List ids/titles; download nothing
      --ids-only       Print discovered arXiv ids only (one per line)
      --ua STRING      Override User-Agent (put your contact email in it!)
  -v, --verbose
  -h, --help

EXAMPLES
  alphaxiv_dl feed --pages 3 --page-size 20 -o ./pdfs -n 25
  alphaxiv_dl search "chain of thought reasoning" -n 10 -o ./cot
  alphaxiv_dl feed --pages 2 --dry-run
  alphaxiv_dl search "diffusion models" --ids-only"""

# ── arXiv id validation (new: 2407.12345 ; old: hep-th/9901001) ────────────
proc digitsOnly(s: string): bool =
  s.len > 0 and s.allCharsInSet({'0'..'9'})

proc stripVersion(s: string): string =
  let i = s.rfind('v')
  if i > 0 and i < s.high and digitsOnly(s[i+1 .. ^1]): s[0 .. i-1] else: s

proc isArxivId(raw: string): bool =
  let s = stripVersion(raw)
  # new style: NNNN.NNNN or NNNN.NNNNN
  if '/' notin s and '.' in s:
    let p = s.split('.')
    return p.len == 2 and p[0].len == 4 and digitsOnly(p[0]) and
           p[1].len in 4..5 and digitsOnly(p[1])
  # old style: archive(.SUBJ)/NNNNNNN
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
# (Connection: close) avoids the poisoned-connection failure mode.
proc newDlClient(cfg: Config): HttpClient =
  result = newHttpClient(userAgent = cfg.ua, timeout = 120_000, maxRedirects = 5,
                         headers = newHttpHeaders({"Connection": "close"}))

proc getJson(client: HttpClient, url: string): JsonNode =
  parseJson(client.getContent(url))

# ── discovery ───────────────────────────────────────────────────────────────
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

# Discovery yields papers lazily so the caller can download each one as soon
# as it is found (streaming), instead of crawling every page up front. The
# per-page request delay only applies to feed crawling; downloads add their
# own delay. Breaking out of the consuming loop (e.g. on --max) stops crawling.
iterator discoverFeed(client: HttpClient, cfg: Config): Paper =
  for page in cfg.startPage ..< cfg.startPage + cfg.pages:
    dim("crawling feed page " & $page & " (size " & $cfg.pageSize &
        ", sort=" & cfg.sort & ", interval=" & cfg.interval & ")")
    let url = AlphaApi & "/papers/v3/feed?pageNum=" & $page &
              "&pageSize=" & $cfg.pageSize &
              "&sort=" & encodeUrl(cfg.sort) &
              "&interval=" & encodeUrl(apiInterval(cfg.interval))
    var node: JsonNode
    try:
      node = getJson(client, url)
    except CatchableError as ex:
      warn("feed page " & $page & " failed: " & ex.msg & " (stopping)")
      break
    let papers = node{"papers"}
    if papers == nil or papers.kind != JArray or papers.len == 0:
      dim("page " & $page & " empty — end of feed"); break
    for p in papers:
      yield Paper(id: p{"universal_paper_id"}.getStr(""),
                  title: p{"title"}.getStr(""))
    if page + 1 < cfg.startPage + cfg.pages: sleep(cfg.delayMs)

iterator discoverSearch(client: HttpClient, cfg: Config): Paper =
  dim("searching alphaXiv for: " & cfg.query)
  let url = AlphaApi & "/search/v2/paper/fast?q=" & encodeUrl(cfg.query) &
            "&includePrivate=false"
  let node = getJson(client, url)
  if node.kind != JArray: die("unexpected search response shape")
  for h in node:
    yield Paper(id: h{"paperId"}.getStr(""),
                title: h{"title"}.getStr(""))

# ── download one PDF, with backoff + %PDF validation ───────────────────────
proc isPdf(body: string): bool =
  body.len >= 4 and body[0 .. 3] == "%PDF"

proc downloadPdf(client: HttpClient, cfg: Config, p: Paper): string =
  let bare = stripVersion(p.id).replace("/", "_")
  let fname = cfg.outDir / (bare & "__" & slug(p.title) & ".pdf")
  if fileExists(fname) and getFileSize(fname) > 0:
    if isPdf(readFile(fname)):
      dim("skip (have): " & fname); return "skipped"
  let url = ArxivPdfHost & "/" & p.id
  var delay = cfg.delayMs
  for attempt in 1 .. cfg.retries:
    # fresh connection each attempt — see newDlClient
    let dl = newDlClient(cfg)
    try:
      let resp = dl.get(url)
      let sc = resp.code.int
      if sc == 200:
        let body = resp.body
        if isPdf(body):
          writeFile(fname, body); okMsg("saved: " & fname); return "ok"
        else:
          warn(p.id & ": got non-PDF body (HTML/captcha?), retrying")
      elif sc == 404:
        warn(p.id & ": HTTP 404 (no PDF / withdrawn)"); return "missing"
      elif sc in [429, 503]:
        warn(p.id & ": HTTP " & $sc & " (throttled), backing off " &
             $(delay div 1000) & "s")
      else:
        warn(p.id & ": HTTP " & $sc)
    except CatchableError as ex:
      warn(p.id & ": " & ex.msg)
    finally:
      dl.close()
    sleep(delay); delay *= 2
  warn(p.id & ": giving up after " & $cfg.retries & " attempts")
  return "failed"

# ── argument parsing ────────────────────────────────────────────────────────
proc parseArgs(): Config =
  result = Config(sort: "Hot", interval: "7d", startPage: 1, pages: 1,
                  pageSize: 20, maxDl: 0, retries: 4, delayMs: 3000,
                  outDir: "./alphaxiv_pdfs",
                  ua: Version & " (+polite crawler; contact: you@example.com)")
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
    else:
      die("search requires a query string")

  proc need(name: string): string =
    if i + 1 >= args.len: die(name & " requires a value")
    inc i; args[i]

  while i < args.len:
    case args[i]
    of "-o", "--out":     result.outDir = need(args[i])
    of "-n", "--max":     result.maxDl = parseInt(need(args[i]))
    of "--pages":         result.pages = parseInt(need(args[i]))
    of "--start-page":    result.startPage = parseInt(need(args[i]))
    of "--page-size":     result.pageSize = parseInt(need(args[i]))
    of "--sort":          result.sort = need(args[i])
    of "--interval":      result.interval = need(args[i])
    of "--delay":         result.delayMs = int(parseFloat(need(args[i])) * 1000)
    of "--retries":       result.retries = parseInt(need(args[i]))
    of "--ua":            result.ua = need(args[i])
    of "--dry-run":       result.dryRun = true
    of "--ids-only":      result.idsOnly = true; result.dryRun = true
    of "-v", "--verbose": result.verbose = true
    of "-h", "--help":    usage(); quit 0
    else: die("unknown option '" & args[i] & "' (try --help)")
    inc i

# ── main ────────────────────────────────────────────────────────────────────
proc main() =
  let cfg = parseArgs()
  let client = newClient(cfg)
  defer: client.close()

  if not cfg.idsOnly:
    dim("alphaxiv-dl — discovery via alphaXiv API, PDFs from arXiv (" &
        ArxivPdfHost & ")")
    dim("be considerate: delay=" & $(cfg.delayMs div 1000) & "s, retries=" &
        $cfg.retries & ". Ctrl-C to stop.")

  var manifest: File
  if not cfg.idsOnly:
    createDir(cfg.outDir)
    let mpath = cfg.outDir / "manifest.tsv"
    let fresh = not fileExists(mpath)
    manifest = open(mpath, fmAppend)
    if fresh: manifest.writeLine("arxiv_id\tstatus\tpath\ttitle")

  var seen = initHashSet[string]()
  var nOk, nSkip, nOther, nSeen, nFound = 0
  var stop = false

  # handle one discovered paper: dedup, validate, download. Returns false when
  # the caller should stop crawling (e.g. --max reached).
  proc handle(p: Paper): bool =
    if p.id.len == 0 or p.id in seen: return true
    seen.incl p.id
    inc nFound
    if not isArxivId(p.id):
      warn("skipping non-arXiv id: '" & p.id & "'"); return true
    if cfg.idsOnly:
      echo p.id; return true

    inc nSeen
    dim("[" & $nSeen & "] " & p.id & "  " & p.title[0 ..< min(70, p.title.len)])
    if cfg.dryRun: return true

    let status = downloadPdf(client, cfg, p)
    manifest.writeLine(p.id & "\t" & status & "\t" &
                       (cfg.outDir / stripVersion(p.id)) & "\t" & p.title)
    case status
    of "ok": inc nOk
    of "skipped": inc nSkip
    else: inc nOther

    if cfg.maxDl > 0 and nOk + nSkip >= cfg.maxDl:
      dim("reached --max " & $cfg.maxDl & ", stopping."); return false
    sleep(cfg.delayMs)
    return true

  try:
    if cfg.mode == mFeed:
      for p in discoverFeed(client, cfg):
        if not handle(p): stop = true
        if stop: break
    else:
      for p in discoverSearch(client, cfg):
        if not handle(p): stop = true
        if stop: break
  except CatchableError as ex:
    die("discovery failed: " & ex.msg)
  if nFound == 0: die("no papers discovered")

  if not cfg.idsOnly:
    manifest.close()
    e ""
    okMsg("done. downloaded=" & $nOk & "  skipped=" & $nSkip &
          "  other=" & $nOther)
    if not cfg.dryRun:
      dim("files in: " & cfg.outDir & "   (manifest: " &
          (cfg.outDir / "manifest.tsv") & ")")

when isMainModule and not defined(alphaxivLib):
  main()
