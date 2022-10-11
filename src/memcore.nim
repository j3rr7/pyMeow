import 
  os, strformat, sequtils,
  strutils, nimpy

pyExportModule("pyMeow")

when defined(windows):
  import winim
elif defined(linux):
  import 
    posix, strscans, tables

  proc process_vm_readv(
    pid: int, 
    localIov: ptr IOVec, 
    liovcnt: culong, 
    remoteIov: ptr IOVec, 
    riovcnt: culong, 
    flags: culong
  ): cint {.importc, header: "<sys/uio.h>", discardable.}

  proc process_vm_writev(
      pid: int, 
      localIov: ptr IOVec, 
      liovcnt: culong, 
      remoteIov: ptr IOVec, 
      riovcnt: culong, 
      flags: culong
  ): cint {.importc, header: "<sys/uio.h>", discardable.}

type
  Process* = object
    name: string
    pid: int
    debug: bool
    when defined(windows):
      handle: HANDLE

  Module = object
    name: string
    base: ByteAddress
    `end`: ByteAddress
    size: int

proc checkRoot =
  when defined(linux):
    if getuid() != 0:
      raise newException(IOError, "Root access required!")

proc getErrorStr: string =
  when defined(linux):
    fmt"[Error: {errno} - {strerror(errno)}]"
  elif defined(windows):
    var 
      errCode = osLastError()
      errMsg = osErrorMsg(errCode)
    stripLineEnd(errMsg)
    fmt"[Error: {errCode} - {errMsg}]"

proc memoryErr(m: string, address: ByteAddress) {.inline.} =
  raise newException(
    AccessViolationDefect,
    fmt"{m} failed [Address: 0x{address.toHex()}] {getErrorStr()}"
  )

iterator enumProcesses: Process {.exportpy: "enum_processes".} =
  var p: Process

  when defined(linux):
    checkRoot()
    let allFiles = toSeq(walkDir("/proc", relative = true))
    for pid in mapIt(filterIt(allFiles, isDigit(it.path[0])), parseInt(it.path)):
        p.pid = pid
        p.name = readFile(fmt"/proc/{pid}/comm").strip()
        yield p
  
  elif defined(windows):
    var 
      pe: PROCESSENTRY32
      hResult: WINBOOL

    let hSnapShot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    defer: CloseHandle(hSnapShot)
    pe.dwSize = sizeof(PROCESSENTRY32).DWORD

    hResult = Process32First(hSnapShot, pe.addr)
    while hResult:
      p.name = nullTerminated($$pe.szExeFile)
      p.pid = pe.th32ProcessID
      yield p
      hResult = Process32Next(hSnapShot, pe.addr)

proc pidExists(pid: int): bool {.exportpy: "pid_exists".} =
  pid in mapIt(toSeq(enumProcesses()), it.pid)

proc getProcessId(procName: string): int {.exportpy: "get_process_id".} =
  checkRoot()
  for process in enumProcesses():
    if process.name in procName:
      return process.pid
  raise newException(Exception, fmt"Process '{procName}' not found")

proc getProcessName(pid: int): string {.exportpy: "get_process_name".} =
  checkRoot()
  for process in enumProcesses():
    if process.pid == pid:
      return process.name
  raise newException(Exception, fmt"Process '{pid}' not found")

proc openProcess(pid: int = 0, processName: string = "", debug: bool = false): Process {.exportpy: "open_process".} =
  var sPid: int

  if pid == 0 and processName == "":
    raise newException(Exception, "Process ID or Process Name required")
  elif processName != "":
    for p in enumProcesses():
      if processName in p.name:
        sPid = p.pid
        break
    if sPid == 0:
      raise newException(Exception, fmt"Process '{processName}' not found")
  elif pid != 0:
    if not pidExists(pid):
      raise newException(Exception, fmt"Process ID '{pid} does not exist")
    sPid = pid

  checkRoot()
  result.debug = debug
  result.pid = sPid
  result.name = getProcessName(sPid)

  when defined(windows):
    result.handle = OpenProcess(PROCESS_ALL_ACCESS, FALSE, sPid.DWORD)
    if result.handle == FALSE:
      raise newException(Exception, fmt"Unable to open Process [Pid: {pid}] {getErrorStr()}")

proc closeProcess(process: Process) {.exportpy: "close_process".} =
  when defined(windows):
    CloseHandle(process.handle)

iterator enumModules(process: Process): Module {.exportpy: "enum_modules"} =
  when defined(linux):
    checkRoot()
    var modTable: Table[string, Module]
    for l in lines(fmt"/proc/{process.pid}/maps"):
      let s = l.split("/")
      if s.len > 1:
        var 
          pageStart, pageEnd: ByteAddress
          modName = s[^1]
        discard scanf(l, "$h-$h", pageStart, pageEnd)
        if modName notin modTable:
          modTable[modName] = Module(name: modName)
          modTable[modName].base = pageStart
          modTable[modName].size = pageEnd - modTable[modName].base
        else:
          modTable[modName].size = pageEnd - modTable[modName].base
    
    for name, module in modTable:
      modTable[name].`end` = module.base + module.size
      yield modTable[name]

  elif defined(windows):
    template yieldModule =
      module.name = nullTerminated($$mEntry.szModule)
      module.base = cast[ByteAddress](mEntry.modBaseAddr)
      module.size = mEntry.modBaseSize
      module.`end` = module.base + module.size
      yield module

    var
      hSnapShot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, process.pid.DWORD)
      mEntry = MODULEENTRY32(dwSize: sizeof(MODULEENTRY32).cint)
      module: Module

    defer: CloseHandle(hSnapShot)
    if Module32First(hSnapShot, mEntry.addr) == TRUE:
      yieldModule()
      while Module32Next(hSnapShot, mEntry.addr) != FALSE:
        yieldModule()

proc getModule(process: Process, moduleName: string): Module {.exportpy: "get_module".} =
  checkRoot()
  for module in enumModules(process):
    if moduleName == module.name:
      return module
  raise newException(Exception, fmt"Module '{moduleName}' not found")

proc read*(process: Process, address: ByteAddress, t: typedesc): t =
  when defined(linux):
    var
      ioSrc, ioDst: IOVec
      size = sizeof(t).uint

    ioDst.iov_base = result.addr
    ioDst.iov_len = size
    ioSrc.iov_base = cast[pointer](address)
    ioSrc.iov_len = size
    if process_vm_readv(process.pid, ioDst.addr, 1, ioSrc.addr, 1, 0) == -1:
      memoryErr("Read", address)
  elif defined(windows):
    if ReadProcessMemory(
      process.handle, cast[pointer](address), result.addr, sizeof(t), nil
    ) == FALSE:
      memoryErr("Read", address)

  if process.debug:
    echo "[R] [", type(result), "] 0x", address.toHex(), " -> ", result

proc write*(process: Process, address: ByteAddress, data: auto) =
  when defined(linux):
    var
      ioSrc, ioDst: IOVec
      size = sizeof(data).uint
      d = data

    ioSrc.iov_base = d.addr
    ioSrc.iov_len = size
    ioDst.iov_base = cast[pointer](address)
    ioDst.iov_len = size
    if process_vm_writev(process.pid, ioSrc.addr, 1, ioDst.addr, 1, 0) == -1:
      memoryErr("Write", address)
  elif defined(windows):
    if WriteProcessMemory(
      process.handle, cast[pointer](address), data.unsafeAddr, sizeof(data), nil
    ) == FALSE:
      memoryErr("Write", address)

  if process.debug:
    echo "[W] [", type(data), "] 0x", address.toHex(), " -> ", data

proc writeArray*[T](process: Process, address: ByteAddress, data: openArray[T]): int {.discardable.} =
  when defined(linux):
    var
      ioSrc, ioDst: IOVec
      size = (sizeof(T) * data.len).uint

    ioSrc.iov_base = data.unsafeAddr
    ioSrc.iov_len = size
    ioDst.iov_base = cast[pointer](address)
    ioDst.iov_len = size
    if process_vm_writev(process.pid, ioSrc.addr, 1, ioDst.addr, 1, 0) == -1:
      memoryErr("WriteArray", address)
  elif defined(windows):
    if WriteProcessMemory(
      process.handle, cast[pointer](address), data.unsafeAddr, sizeof(T) * data.len, nil
    ) == FALSE:
      memoryErr("WriteArray", address)
  
  if process.debug:
    echo "[W] [", type(data), "] 0x", address.toHex(), " -> ", data

proc readSeq*(process: Process, address: ByteAddress, size: int, t: typedesc = byte): seq[t] =
  result = newSeq[t](size)
  when defined(linux):
    var 
      ioSrc, ioDst: IOVec
      bsize = (size * sizeof(t)).uint

    ioDst.iov_base = result[0].addr
    ioDst.iov_len = bsize
    ioSrc.iov_base = cast[pointer](address)
    ioSrc.iov_len = bsize
    if process_vm_readv(process.pid, ioDst.addr, 1, ioSrc.addr, 1, 0) == -1:
      memoryErr("readSeq", address)
  elif defined(windows):
    if ReadProcessMemory(
      process.handle, cast[pointer](address), result[0].addr, size * sizeof(t), nil
    ) == FALSE:
      memoryErr("readSeq", address)

  if process.debug:
    echo "[R] [", type(result), "] 0x", address.toHex(), " -> ", result

proc aob(pattern: string, byteBuffer: seq[byte], single: bool): seq[ByteAddress] =
  const
    wildCard = "??"
    wildCardByte = 200.byte # Not safe

  proc patternToBytes(pattern: string): seq[byte] =
    var patt = pattern.replace(" ", "")
    try:
      for i in countup(0, patt.len-1, 2):
        let hex = patt[i..i+1]
        if hex == wildCard:
          result.add(wildCardByte)
        else:
          result.add(parseHexInt(hex).byte)
    except:
      raise newException(Exception, "Invalid pattern")

  let bytePattern = patternToBytes(pattern)
  var byteHits: int
  for i, b in byteBuffer:
    let p = bytePattern[byteHits]
    if p == wildCardByte or p == b:
      inc byteHits
    else:
      byteHits = 0
    if byteHits == bytePattern.len:
      result.add(i+1 - bytePattern.len)
      byteHits = 0
      if single:
        return

proc aobScanModule(process: Process, moduleName, pattern: string, relative: bool = false, single: bool = true): seq[ByteAddress] {.exportpy: "aob_scan_module".} =
  let 
    module = getModule(process, moduleName)
    # TODO: Reading a whole module is a bad idea. Read pages instead.
    byteBuffer = process.readSeq(module.base, module.size)
  
  result = aob(pattern, byteBuffer, single)
  if result.len != 0:
    if not relative:
      for i, a in result:
        result[i] += module.base

proc aobScanRange(process: Process, pattern: string, rangeStart, rangeEnd: ByteAddress, relative: bool = false, single: bool = true): seq[ByteAddress] {.exportpy: "aob_scan_range".} =
  if rangeStart >= rangeEnd:
    raise newException(Exception, "Invalid range (rangeStart > rangeEnd)")

  let byteBuffer = process.readSeq(rangeStart, rangeEnd - rangeStart)
  
  result = aob(pattern, byteBuffer, single)
  if result.len != 0:
    if not relative:
      for i, a in result:
        result[i] += rangeStart

#[ Windows only! ]#
when defined(windows):
  proc pageProtection(a: Process, address: ByteAddress, newProtection: int32 = 0x40): int32 {.exportpy: "page_protection".} =
    var mbi = MEMORY_BASIC_INFORMATION()
    discard VirtualQueryEx(a.handle, cast[LPCVOID](address), mbi.addr, sizeof(mbi).SIZE_T)
    discard VirtualProtectEx(a.handle, cast[LPCVOID](address), mbi.RegionSize, newProtection, result.addr)

