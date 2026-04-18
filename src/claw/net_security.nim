import std/[strutils, uri, net, options]

type
  NetSecurityError* = object of CatchableError

proc extractHost*(url: string): string =
  ## Extract the hostname from an HTTP(S) URL, stripping port, path, query, fragment.
  try:
    let u = parseUri(url)
    if not (u.scheme.toLowerAscii() == "http" or u.scheme.toLowerAscii() == "https"):
      return ""
    
    var host = u.hostname
    
    # We must enforce strict bracket matching because parseUri strips brackets silently
    let schemeEnd = url.find("://")
    if schemeEnd == -1: return ""
    
    let authStart = schemeEnd + 3
    var authEnd = url.find('/', authStart)
    if authEnd == -1: authEnd = url.find('?', authStart)
    if authEnd == -1: authEnd = url.find('#', authStart)
    if authEnd == -1: authEnd = url.len
    if authEnd < authStart: return ""
    
    let authority = url[authStart ..< authEnd]
    let atIdx = authority.find('@')
    let hostPort = if atIdx != -1: authority[atIdx + 1 .. ^1] else: authority
    
    if hostPort.startsWith("["):
      let closeIdx = hostPort.find(']')
      if closeIdx == -1: return ""
      if closeIdx != hostPort.len - 1 and hostPort[closeIdx+1] != ':': return ""
      host = hostPort[0 .. closeIdx]
    else:
      if host == "":
        let lastColon = hostPort.rfind(':')
        if lastColon != -1: host = hostPort[0 ..< lastColon]
        else: host = hostPort
           
    if host.len == 0: return ""
    if host.contains('%'): return ""
      
    return host
  except:
    return ""

proc parseIpv4*(s: string): Option[array[4, uint8]] =
  ## Parse a dotted-decimal IPv4 address string into 4 octets.
  let parts = s.split('.')
  if parts.len != 4: return none(array[4, uint8])
  
  var octets: array[4, uint8]
  for i, part in parts:
    try:
      let val = part.parseInt()
      if val < 0 or val > 255: return none(array[4, uint8])
      octets[i] = uint8(val)
    except ValueError:
      return none(array[4, uint8])
  
  return some(octets)

proc parseIpv4IntegerAlias*(s: string): Option[array[4, uint8]] =
  ## Parse single-integer IPv4 aliases into octets.
  if s.len == 0 or s.contains('.') or s.contains(':'): return none(array[4, uint8])
  
  var value: uint32
  try:
    if s.startsWith("0x") or s.startsWith("0X"):
      if s.len <= 2: return none(array[4, uint8])
      value = parseHexInt(s[2..^1]).uint32
    else:
      # verify all digits
      for c in s:
        if c < '0' or c > '9': return none(array[4, uint8])
      value = s.parseBiggestUInt().uint32
  except:
    return none(array[4, uint8])

  var octets: array[4, uint8]
  octets[0] = uint8(value shr 24)
  octets[1] = uint8((value shr 16) and 0xFF)
  octets[2] = uint8((value shr 8) and 0xFF)
  octets[3] = uint8(value and 0xFF)
  return some(octets)

proc parseIpv6Groups*(s: string, segs: var array[8, uint16], startIdx: int): int =
  var idx = startIdx
  let parts = s.split(':')
  for part in parts:
    if part.len == 0: continue
    if idx >= 8: return -1
    try:
      segs[idx] = parseHexInt(part).uint16
      inc idx
    except ValueError:
      return -1
  return idx - startIdx

proc parseIpv6*(s: string): Option[array[8, uint16]] =
  ## Parse an IPv6 address string into 8 segments.
  if s.len == 0: return none(array[8, uint16])
  var segs: array[8, uint16]
  
  let dcPos = s.find("::")
  if dcPos != -1:
    let before = s[0 ..< dcPos]
    let after = s[dcPos + 2 .. ^1]
    
    var segCount = 0
    if before.len > 0:
      segCount = parseIpv6Groups(before, segs, 0)
      if segCount == -1: return none(array[8, uint16])
      
    if after.len > 0:
      if after.contains('.'):
        let lastColon = after.rfind(':')
        if lastColon != -1:
          let groupsPart = after[0 ..< lastColon]
          let ipv4Part = after[lastColon + 1 .. ^1]
          
          var tailSegs: array[8, uint16]
          let tailCount = parseIpv6Groups(groupsPart, tailSegs, 0)
          if tailCount == -1: return none(array[8, uint16])
          
          let ipv4Opt = parseIpv4(ipv4Part)
          if ipv4Opt.isNone: return none(array[8, uint16])
          let ipv4 = ipv4Opt.get()
          
          let total = segCount + tailCount + 2
          if total > 8: return none(array[8, uint16])
          let gap = 8 - total
          
          for i in 0 ..< tailCount:
            segs[segCount + gap + i] = tailSegs[i]
            
          segs[6] = (uint16(ipv4[0]) shl 8) or uint16(ipv4[1])
          segs[7] = (uint16(ipv4[2]) shl 8) or uint16(ipv4[3])
        else:
          let ipv4Opt = parseIpv4(after)
          if ipv4Opt.isNone: return none(array[8, uint16])
          let ipv4 = ipv4Opt.get()
          segs[6] = (uint16(ipv4[0]) shl 8) or uint16(ipv4[1])
          segs[7] = (uint16(ipv4[2]) shl 8) or uint16(ipv4[3])
      else:
        var tailSegs: array[8, uint16]
        let tailCount = parseIpv6Groups(after, tailSegs, 0)
        if tailCount == -1: return none(array[8, uint16])
        if segCount + tailCount > 8: return none(array[8, uint16])
        let gap = 8 - segCount - tailCount
        for i in 0 ..< tailCount:
          segs[segCount + gap + i] = tailSegs[i]
  else:
    if s.contains('.'):
      let lastColon = s.rfind(':')
      if lastColon != -1:
        let groupsPart = s[0 ..< lastColon]
        let ipv4Part = s[lastColon + 1 .. ^1]
        let segCount = parseIpv6Groups(groupsPart, segs, 0)
        if segCount != 6: return none(array[8, uint16])
        let ipv4Opt = parseIpv4(ipv4Part)
        if ipv4Opt.isNone: return none(array[8, uint16])
        let ipv4 = ipv4Opt.get()
        segs[6] = (uint16(ipv4[0]) shl 8) or uint16(ipv4[1])
        segs[7] = (uint16(ipv4[2]) shl 8) or uint16(ipv4[3])
      else:
        return none(array[8, uint16])
    else:
      let segCount = parseIpv6Groups(s, segs, 0)
      if segCount != 8: return none(array[8, uint16])

  return some(segs)

proc isNonGlobalV4*(octets: array[4, uint8]): bool =
  let a = octets[0]
  let b = octets[1]
  let c = octets[2]
  if a == 127: return true
  if a == 10: return true
  if a == 172 and b >= 16 and b <= 31: return true
  if a == 192 and b == 168: return true
  if a == 0: return true
  if a == 169 and b == 254: return true
  if a >= 224: return true
  if a == 100 and b >= 64 and b <= 127: return true
  if a == 192 and b == 0 and c == 2: return true
  if a == 198 and b == 51 and c == 100: return true
  if a == 203 and b == 0 and c == 113: return true
  if a == 198 and (b == 18 or b == 19): return true
  if a == 192 and b == 0 and c == 0: return true
  return false

proc isNonGlobalV6*(segs: array[8, uint16]): bool =
  if segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
     segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 1: return true
  if segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
     segs[4] == 0 and segs[5] == 0 and segs[6] == 0 and segs[7] == 0: return true
  if (segs[0] and 0xff00) == 0xff00: return true
  if (segs[0] and 0xfe00) == 0xfc00: return true
  if (segs[0] and 0xffc0) == 0xfe80: return true
  if segs[0] == 0x2001 and segs[1] == 0x0db8: return true
  if segs[0] == 0 and segs[1] == 0 and segs[2] == 0 and segs[3] == 0 and
     segs[4] == 0 and segs[5] == 0xffff:
    let ipv4 = [uint8(segs[6] shr 8), uint8(segs[6] and 0xff), uint8(segs[7] shr 8), uint8(segs[7] and 0xff)]
    return isNonGlobalV4(ipv4)
  return false

proc isLocalHost*(host: string): bool =
  ## SSRF: check if host is localhost or a private/reserved IP.
  var bare = host
  if bare.startsWith("[") and bare.endsWith("]"):
    bare = bare[1 .. ^2]
    
  var unscoped = bare
  let pct = bare.find('%')
  if pct != -1:
    unscoped = bare[0 ..< pct]
    
  if unscoped.len == 0: return true
  if unscoped.toLowerAscii() == "localhost": return true
  if unscoped.toLowerAscii().endsWith(".localhost"): return true
  if unscoped.toLowerAscii().endsWith(".local"): return true
  
  let ipv4Opt = parseIpv4(unscoped)
  if ipv4Opt.isSome: return isNonGlobalV4(ipv4Opt.get())
  
  let ipv4IntOpt = parseIpv4IntegerAlias(unscoped)
  if ipv4IntOpt.isSome: return isNonGlobalV4(ipv4IntOpt.get())
  
  let ipv6Opt = parseIpv6(unscoped)
  if ipv6Opt.isSome: return isNonGlobalV6(ipv6Opt.get())
  
  return false
