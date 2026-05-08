import std/[os, random, strutils, tables]
# Use the vendored curly with cancel API support — keeps Curly type
# consistent across the http stack so the cancel-in-flight call site
# in providers/http.nim works on the same object instance.
import curly_with_cancel as curly, webby/httpheaders
import ../logger

proc curlyPostWithRetry*(c: Curly, url, body: string, headers: HttpHeaders, timeout: int = 30, maxRetries: int = 9): tuple[code: int, body: string] =
  ## POST request with exponential backoff retry on transient network errors.
  ## Default 9 retries with 1/2/4/8/16/32/64/128s exponential backoff (+jitter)
  ## — total worst-case ~4.25min. Tuned for CN→US transit, where flaps can
  ## last tens of seconds; the long tail catches sustained outages without
  ## prematurely consuming a fallback-chain entry.
  randomize()
  for attempt in 1..maxRetries:
    try:
      let resp = c.post(url, headers = headers, body = body, timeout = timeout)
      return (resp.code, resp.body)
    except Exception as e:
      let msg = e.msg
      # Match the common transport-layer failures we want to retry.
      # `peer` / `receiving data` catches CURLE_RECV_ERROR ("Failure
      # when receiving data from the peer"), the dominant CN→US
      # transit hiccup; `Recv failure`, `transfer closed`, `HTTP/2`
      # cover the other variants curl reports for the same class of
      # problem. `EOF` catches early-close from the server side.
      # Keep the original SSL/timeout/connection/reset/refused/
      # resolve set so previously-retried errors still retry.
      let isRetryable =
        msg.contains("SSL") or msg.contains("timeout") or
        msg.contains("connection") or msg.contains("reset") or
        msg.contains("refused") or msg.contains("resolve") or
        msg.contains("peer") or msg.contains("receiving data") or
        msg.contains("Recv failure") or msg.contains("transfer closed") or
        msg.contains("HTTP/2") or msg.contains("EOF")

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
