# Package

version       = "1.2.0"
author        = "danindiana"
description   = "Paginating crawler + throttled-parallel, resumable PDF downloader for alphaXiv / arXiv"
license       = "MIT"
srcDir        = "."
bin           = @["alphaxiv_dl"]

# Dependencies

requires "nim >= 1.6.0"   # uses only the standard library

# Tasks
#   nimble build            -> optimized binary (flags come from config.nims)
#   nimble run -- feed ...   -> build & run
#
# Compile-time tunables (override defaults baked into the binary), e.g.:
#   nim c -d:release -d:ssl --threads:on \
#         -d:delaySecs=5 -d:defaultThreads=8 -d:arxivHost=https://arxiv.org/pdf \
#         alphaxiv_dl.nim

task smoke, "build both threaded and single-threaded variants":
  exec "nim c -d:release -d:ssl --threads:on  --mm:orc -o:alphaxiv_dl    alphaxiv_dl.nim"
  exec "nim c -d:release -d:ssl --threads:off          -o:alphaxiv_dl_st alphaxiv_dl.nim"
  echo "built: alphaxiv_dl (parallel) and alphaxiv_dl_st (single-threaded)"
