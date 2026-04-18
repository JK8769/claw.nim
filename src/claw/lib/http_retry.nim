import std/[os, random, strutils, tables]
import curly, webby/httpheaders
import ../logger

proc curlyPostWithRetry*(c: Curly, url, body: string, headers: HttpHeaders, timeout: int = 30, maxRetries: int = 5): tuple[code: int, body: string] =
  ## POST request with exponential backoff retry on transient network errors.
  randomize()
  for attempt in 1..maxRetries:
    try:
      let resp = c.post(url, headers = headers, body = body, timeout = timeout)
      return (resp.code, resp.body)
    except Exception as e:
      let msg = e.msg
      let isRetryable = msg.contains("SSL") or msg.contains("timeout") or
                        msg.contains("connection") or msg.contains("reset") or
                        msg.contains("refused") or msg.contains("resolve")

      if attempt < maxRetries and isRetryable:
        let sleepDelay = (1 shl (attempt - 1)) * 1000 + rand(1000)
        warnCF("http_retry", "Request failed, retrying", {
          "attempt": $attempt,
          "delay_ms": $sleepDelay,
          "error": msg
        }.toTable)
        os.sleep(sleepDelay)
        continue
      return (-1, msg)
  return (-1, "Max retries reached")
