# Applied to every `nim c` / `nimble build` in this directory.
# HTTPS requires the ssl define; the worker pool requires threads.
--define:ssl
--threads:on
--mm:orc
when defined(release):
  --opt:speed
