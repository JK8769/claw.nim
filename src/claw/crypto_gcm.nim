import nimcrypto/rijndael
import nimcrypto/bcmode
import std/[sequtils]

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0..<s.len:
    result[i] = byte(s[i].ord)

proc toString*(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0..<b.len:
    result[i] = char(b[i])

proc aes128GcmDecryptNmobile*(blob: openArray[byte], key: openArray[byte], nonceSize: int): seq[byte] =
  if key.len != 16:
    raise newException(ValueError, "AES-128-GCM key must be 16 bytes")
  if nonceSize <= 0:
    raise newException(ValueError, "nonceSize must be > 0")
  if blob.len < nonceSize + 16:
    raise newException(ValueError, "blob too short")

  let nonce = blob[0 ..< nonceSize]
  let ctTag = blob[nonceSize ..< blob.len]
  let tag = ctTag[(ctTag.len - 16) ..< ctTag.len]
  let ct = ctTag[0 ..< (ctTag.len - 16)]

  var ctx: GCM[aes128]
  ctx.init(key, nonce, @[])
  result = newSeq[byte](ct.len)
  ctx.decrypt(ct, result)

  let computed = ctx.getTag()
  ctx.clear()
  if computed.toSeq != tag.toSeq:
    raise newException(ValueError, "GCM auth failed")
