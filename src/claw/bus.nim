import std/[asyncdispatch, asyncfutures, tables, locks, deques]
import bus_types

type
  MessageBus* = ref object
    inboundQueue: Deque[InboundMessage]
    outboundQueue: Deque[OutboundMessage]
    inboundLock: Lock
    outboundLock: Lock
    handlers: Table[string, MessageHandler]

proc newMessageBus*(): MessageBus =
  var bus = MessageBus()
  bus.inboundQueue = initDeque[InboundMessage]()
  bus.outboundQueue = initDeque[OutboundMessage]()
  initLock(bus.inboundLock)
  initLock(bus.outboundLock)
  bus.handlers = initTable[string, MessageHandler]()
  return bus

proc publishInbound*(bus: MessageBus, msg: InboundMessage) =
  acquire(bus.inboundLock)
  bus.inboundQueue.addLast(msg)
  release(bus.inboundLock)

proc consumeInbound*(bus: MessageBus): Future[InboundMessage] {.async.} =
  var backoff = 1
  while true:
    acquire(bus.inboundLock)
    if bus.inboundQueue.len > 0:
      let msg = bus.inboundQueue.popFirst()
      release(bus.inboundLock)
      return msg
    release(bus.inboundLock)
    await sleepAsync(backoff)
    backoff = min(backoff * 2, 100)

proc publishOutbound*(bus: MessageBus, msg: OutboundMessage) =
  acquire(bus.outboundLock)
  bus.outboundQueue.addLast(msg)
  release(bus.outboundLock)

proc subscribeOutbound*(bus: MessageBus): Future[OutboundMessage] {.async.} =
  var backoff = 1
  while true:
    acquire(bus.outboundLock)
    if bus.outboundQueue.len > 0:
      let msg = bus.outboundQueue.popFirst()
      release(bus.outboundLock)
      return msg
    release(bus.outboundLock)
    await sleepAsync(backoff)
    backoff = min(backoff * 2, 100)

proc registerHandler*(bus: MessageBus, channel: string, handler: MessageHandler) =
  # Handlers are usually static at startup
  bus.handlers[channel] = handler

proc getHandler*(bus: MessageBus, channel: string): (MessageHandler, bool) =
  if bus.handlers.hasKey(channel):
    return (bus.handlers[channel], true)
  else:
    return (nil, false)

proc tryConsumeInbound*(bus: MessageBus): (InboundMessage, bool) =
  ## Non-blocking, non-async consume. Returns (msg, true) if a message was available.
  acquire(bus.inboundLock)
  if bus.inboundQueue.len > 0:
    let msg = bus.inboundQueue.popFirst()
    release(bus.inboundLock)
    return (msg, true)
  release(bus.inboundLock)

proc close*(bus: MessageBus) =
  deinitLock(bus.inboundLock)
  deinitLock(bus.outboundLock)
