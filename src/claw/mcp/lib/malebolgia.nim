# (c) 2023 Andreas Rumpf
# Enhanced for NimClaw by Antigravity
import std / [atomics, locks, tasks, times, isolation]
from std / os import sleep
export isolation

type
  Master* = object ## Masters can spawn new tasks inside an `awaitAll` block.
    c: Cond
    L: Lock
    error: string
    runningTasks: int
    stopToken: Atomic[bool]
    shouldEndAt: Time
    usesTimeout, activeProducer: bool

  TaskVar*[T] = ref object
    ready: Atomic[bool]
    when T isnot void:
      val: T

proc `=destroy`(m: Master) {.inline.} =
  # Use a pointer to the sink value to call deinit procs that expect 'var'.
  # This avoids the =copy conflict in Nim 2.0.
  let p = addr m
  deinitCond(p.c)
  deinitLock(p.L)

proc `=copy`(dest: var Master; src: Master) {.error.}
proc `=sink`(dest: var Master; src: Master) {.error.}

proc initMaster*(m: var Master; timeout = default(Duration); activeProducer = false) =
  ## Initialize a Master in-place. Useful when Master is a field in a ref object.
  m.c = default(Cond)
  m.L = default(Lock)
  initCond(m.c)
  initLock(m.L)
  m.error = ""
  m.runningTasks = 0
  store(m.stopToken, false, moRelaxed)
  if timeout != default(Duration):
    m.usesTimeout = true
    m.shouldEndAt = getTime() + timeout
  else:
    m.usesTimeout = false
  m.activeProducer = activeProducer

proc createMaster*(timeout = default(Duration); activeProducer = false): Master =
  ## Set `activeProducer` to true to prevent the master thread from
  ## running a task directly.
  ## But beware! This can introduce deadlocks for recursive loads!
  initMaster(result, timeout, activeProducer)

proc cancel*(m: var Master) =
  ## Try to stop all running tasks immediately.
  ## This cannot fail but it might take longer than desired.
  store(m.stopToken, true, moRelaxed)

proc cancelled*(m: var Master): bool {.inline.} =
  m.stopToken.load(moRelaxed)

proc taskCreated(m: var Master) {.inline.} =
  acquire(m.L)
  inc m.runningTasks
  release(m.L)

proc taskCompleted(m: var Master) {.inline.} =
  acquire(m.L)
  dec m.runningTasks
  if m.runningTasks == 0:
    signal(m.c)
  release(m.L)

proc stillHaveTime*(m: Master): bool {.inline.} =
  not m.usesTimeout or getTime() < m.shouldEndAt

proc waitForCompletions*(m: var Master) =
  var timeoutErr = false
  if not m.usesTimeout:
    acquire(m.L)
    while m.runningTasks > 0:
      wait(m.c, m.L)
  else:
    while true:
      acquire(m.L)
      let success = m.runningTasks == 0
      release(m.L)
      if success: break
      if getTime() > m.shouldEndAt:
        timeoutErr = true
        break
      sleep(10) # XXX maybe make more precise
  acquire(m.L)
  let err = move(m.error)
  release(m.L)
  if err.len > 0:
    raise newException(ValueError, err)
  elif timeoutErr:
    m.cancel()
    raise newException(ValueError, "'awaitAll' timeout")

# thread pool independent of the 'master':

const
  FixedChanSize* {.intdefine.} = 1024 ## must be a power of two!
  FixedChanMask = FixedChanSize - 1

  ThreadPoolSize* {.intdefine.} = 8 # Increased for NimClaw

type
  PoolTask = object ## a task for the thread pool
    m: ptr Master   ## who is waiting for us
    t: Task         ## what to do
    result: pointer ## where to store the potential result
    readyFlag: ptr Atomic[bool] # Enhanced: Individual task completion flag

  FixedChan = object ## channel of a fixed size
    spaceAvailable, dataAvailable: Cond
    L: Lock
    head, tail, count: int
    data: array[FixedChanSize, PoolTask]

var
  thr: array[ThreadPoolSize-1, Thread[void]] # -1 because the main thread counts too
  chan: FixedChan
  globalStopToken: Atomic[bool]
  busyThreads: Atomic[int]

proc send(item: sink PoolTask) =
  # see deques.addLast:
  acquire(chan.L)
  while chan.count >= FixedChanSize:
    wait(chan.spaceAvailable, chan.L)
  if chan.count < FixedChanSize:
    inc chan.count
    chan.data[chan.tail] = item
    chan.tail = (chan.tail + 1) and FixedChanMask
    signal(chan.dataAvailable)
    release(chan.L)
  else:
    release(chan.L)
    quit "logic bug: queue not empty after signal!"

proc worker() {.thread.} =
  var item: PoolTask
  while not globalStopToken.load(moRelaxed):
    acquire(chan.L)
    while chan.count == 0:
      wait(chan.dataAvailable, chan.L)
    if chan.count > 0:
      # see deques.popFirst:
      dec chan.count
      item = move chan.data[chan.head]
      chan.head = (chan.head + 1) and FixedChanMask
      signal(chan.spaceAvailable)
    release(chan.L)

    if not item.m.stopToken.load(moRelaxed):
      try:
        atomicInc busyThreads
        item.t.invoke(item.result)
      except:
        acquire(item.m.L)
        if item.m.error.len == 0:
          let e = getCurrentException()
          item.m.error = "SPAWN FAILURE: [" & $e.name & "] " & e.msg & "\n" & getStackTrace(e)
        release(item.m.L)
      finally:
        atomicDec busyThreads
        if item.readyFlag != nil:
          store(item.readyFlag[], true, moRelease)
    # but mark it as completed either way!
    taskCompleted item.m[]

proc setup() =
  initCond(chan.dataAvailable)
  initCond(chan.spaceAvailable)
  initLock(chan.L)
  for i in 0..high(thr):
    createThread[void](thr[i], worker)

proc panicStop*() =
  ## Stops all threads.
  globalStopToken.store(true, moRelaxed)
  joinThreads(thr)
  deinitCond(chan.dataAvailable)
  deinitCond(chan.spaceAvailable)
  deinitLock(chan.L)

proc shouldSend(master: var Master): bool {.inline.} =
  master.activeProducer or busyThreads.load(moRelaxed) < ThreadPoolSize-1

template spawnImplRes[T](master: var Master; fn: typed; res: T) =
  if stillHaveTime(master):
    if shouldSend(master):
      taskCreated master
      send PoolTask(m: addr(master), t: toTask(fn), result: addr res, readyFlag: nil)
    else:
      res = fn

template spawnImplNoRes(master: var Master; fn: typed) =
  if stillHaveTime(master):
    if shouldSend(master):
      taskCreated master
      send PoolTask(m: addr(master), t: toTask(fn), result: nil, readyFlag: nil)
    else:
      fn

import std / macros

macro spawn*(a: Master; b: untyped) =
  if b.kind in nnkCallKinds and b.len == 3 and b[0].eqIdent("->"):
    result = newCall(bindSym"spawnImplRes", a, b[1], b[2])
  else:
    result = newCall(bindSym"spawnImplNoRes", a, b)

macro checkBody(body: untyped): untyped =
  const DeclarativeNodes = {nnkTypeSection, nnkFormalParams, nnkGenericParams,
    nnkMacroDef, nnkTemplateDef, nnkConstSection, nnkConstDef, nnkIncludeStmt,
    nnkImportStmt, nnkExportStmt, nnkPragma, nnkCommentStmt, nnkTypeOfExpr,
    nnkMixinStmt, nnkBindStmt}

  const BranchingNodes = {nnkIfStmt, nnkCaseStmt}

  proc isSpawn(n: NimNode): bool =
    n.eqIdent("spawn") or (n.kind == nnkDotExpr and n[1].eqIdent("spawn"))

  proc check(n: NimNode; exprs: var seq[NimNode]; withinLoop: bool) =
    if n.kind in nnkCallKinds and isSpawn(n[0]):
      let b = n[^1]
      for i in 1 ..< n.len:
        check n[i], exprs, withinLoop
      if b.kind in nnkCallKinds and b.len == 3 and b[0].eqIdent("->"):
        let dest = b[2]
        exprs.add dest
        if withinLoop and dest.kind in {nnkSym, nnkIdent}:
          error("re-use of expression '" & $dest & "' before 'awaitAll' completed", dest)
    elif n.kind in DeclarativeNodes:
      discard "declarative nodes are not interesting"
    else:
      let withinLoopB = withinLoop or n.kind in {nnkWhileStmt, nnkForStmt}
      if n.kind in BranchingNodes:
        let preExprs = exprs[0..^1]
        for child in items(n):
          var branchExprs = preExprs
          check child, branchExprs, withinLoopB
          exprs.add branchExprs[preExprs.len..^1]
      else:
        for child in items(n):
          check child, exprs, withinLoopB
    for i in 0..<exprs.len:
      if exprs[i] == n and n.kind in {nnkSym, nnkIdent}:
        error("re-use of expression '" & repr(n) & "' before 'awaitAll' completed", n)

  var exprs: seq[NimNode] = @[]
  check body, exprs, false
  result = body

template awaitAll*(master: var Master; body: untyped) =
  try:
    checkBody body
  finally:
    waitForCompletions(master)

# --- Enhanced Master Handles ---

type
  MasterHandle* = object
    x: ptr Master

proc getHandle*(m: var Master): MasterHandle {.inline.} =
  result = MasterHandle(x: addr(m))

proc cancelled*(m: MasterHandle): bool {.inline.} =
  cancelled(m.x[])

proc cancel*(m: MasterHandle) {.inline.} =
  cancel(m.x[])

template spawn*(m: MasterHandle; b: untyped) =
  spawn(m.x[], b)

# --- TaskVar & Individual Spawn Enhancement ---

proc isReady*[T](fv: TaskVar[T]): bool {.inline.} =
  load(fv.ready, moAcquire)

proc sync*[T](fv: TaskVar[T]): T =
  while not fv.isReady:
    cpuRelax()
  result = fv.val

template spawn*[T](master: var Master; fn: T): TaskVar[T] =
  block:
    var res = TaskVar[T]()
    if stillHaveTime(master):
      if shouldSend(master):
        taskCreated master
        when T isnot void:
          send PoolTask(m: addr(master), t: toTask(fn), result: addr res.val, readyFlag: addr res.ready)
        else:
          send PoolTask(m: addr(master), t: toTask(fn), result: nil, readyFlag: addr res.ready)
      else:
        when T isnot void:
          res.val = fn
          store(res.ready, true, moRelease)
        else:
          fn
          store(res.ready, true, moRelease)
    res

template spawn*[T](m: MasterHandle; fn: T): TaskVar[T] =
  spawn(m.x[], fn)

when not defined(maleSkipSetup):
  setup()
