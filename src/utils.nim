import 
  colors, nimpy, 
  nimraylib_now/raylib as rl

pyExportModule("pyMeow")

when defined(linux):
  import 
    osproc, strscans, x11/xlib
elif defined(windows):
  import winim

proc newColor(r, g, b, a: uint8): rl.Color {.exportpy: "new_color".} =
  rl.Color(r: r, g: g, b: b, a: a)

proc newColorHex(hexValue: uint): rl.Color {.exportpy: "new_color_hex".} =
  rl.getColor(hexValue.cuint)

proc getColor(colorName: string): rl.Color {.exportpy: "get_color".} =
  try:
    let c = parseColor(colorName).extractRGB()
    rl.Color(
      r: c.r.uint8,
      g: c.g.uint8,
      b: c.b.uint8,
      a: 255,
    )
  except ValueError:
    rl.Color(
      r: 0,
      g: 0,
      b: 0,
      a: 255,
    )

proc fadeColor(color: rl.Color, alpha: float): rl.Color {.exportpy: "fade_color".} =
  rl.fade(color, alpha)

proc measureText(text: string, fontSize: cint): int {.exportpy: "measure_text".} =
  rl.measureText(text, fontSize)

proc runTime: float64 {.exportpy: "run_time".} =
  rl.getTime()

proc worldToScreen(matrix: array[0..15, float], pos: Vector3, algo: int = 0): Vector2 {.exportpy: "world_to_screen".} =
  var
    clip: Vector3
    ndc: Vector2

  if algo == 0:
    clip.z = pos.x * matrix[3] + pos.y * matrix[7] + pos.z * matrix[11] + matrix[15]
    clip.x = pos.x * matrix[0] + pos.y * matrix[4] + pos.z * matrix[8] + matrix[12]
    clip.y = pos.x * matrix[1] + pos.y * matrix[5] + pos.z * matrix[9] + matrix[13]
  elif algo == 1:
    clip.z = pos.x * matrix[12] + pos.y * matrix[13] + pos.z * matrix[14] + matrix[15]
    clip.x = pos.x * matrix[0] + pos.y * matrix[1] + pos.z * matrix[2] + matrix[3]
    clip.y = pos.x * matrix[4] + pos.y * matrix[5] + pos.z * matrix[6] + matrix[7]
  
  if clip.z < 0.2:
    raise newException(Exception, "2D Position out of bounds")

  ndc.x = clip.x / clip.z
  ndc.y = clip.y / clip.z
  result.x = (getScreenWidth() / 2 * ndc.x) + (ndc.x + getScreenWidth() / 2)
  result.y = -(getScreenHeight() / 2 * ndc.y) + (ndc.y + getScreenHeight() / 2)

proc checkCollisionPointRec(pointX, pointY: float, rec: rl.Rectangle): bool {.exportpy: "check_collision_point_rec".} =
  rl.checkCollisionPointRec(Vector2(x: pointX, y: pointY), rec)

proc checkCollisionRecs(rec1, rec2: rl.Rectangle): bool {.exportpy: "check_collision_recs".} =
  rl.checkCollisionRecs(rec1, rec2)

proc checkCollisionCircleRec(posX, posY, radius: float, rec: rl.Rectangle): bool {.exportpy: "check_collision_circle_rec".} =
  rl.checkCollisionCircleRec(Vector2(x: posX, y: posY), radius, rec)

proc checkCollisionLines(startPos1X, endPos1X, startPos1Y, endPos1Y, startPos2X, startPos2Y, endPos2X, endPos2Y: float): Vector2 {.exportpy: "check_collision_lines".} =
  discard rl.checkCollisionLines(
    Vector2(x: startPos1X, y: startPos1Y),
    Vector2(x: endPos1X, y: endPos1Y),
    Vector2(x: startPos2X, y: startPos2Y),
    Vector2(x: endPos2X, y: endPos2Y),
    result.addr
  )

proc checkCollisionCircles(pos1X, pos1Y, radius1, pos2X, pos2Y, radius2: float): bool {.exportpy: "check_collision_circles".} =
  rl.checkCollisionCircles(
    Vector2(x: pos1X, y: pos1Y),
    radius1,
    Vector2(x: pos2X, y: pos2Y),
    radius2
  )

proc getDisplayResolution*: (int, int) {.exportpy: "get_display_resolution".} =
  when defined(linux):
    let
      disp = XOpenDisplay(nil)
      scrn = XScreenOfDisplay(disp, 0)
    defer: discard XCloseDisplay(disp)
    (WidthOfScreen(scrn).int, HeightOfScreen(scrn).int)
  elif defined(windows):
    (GetSystemMetrics(SM_CXSCREEN).int, GetSystemMetrics(SM_CYSCREEN).int)

proc compareColorPCT*(color1, color2: rl.Color): float {.exportpy: "compare_color_pct".} =
  let
    r = abs(color1.r.int - color2.r.int).float / 255
    g = abs(color1.g.int - color2.g.int).float / 255
    b = abs(color1.b.int - color2.b.int).float / 255
  result = 100 - ((r + g + b) / 3 * 100)

proc getMonitorCount: int {.exportpy: "get_monitor_count".} =
  rl.getMonitorCount()

proc getMonitorName(monitor: cint = 0): string {.exportpy: "get_monitor_name".} =
  $rl.getMonitorName(monitor)

proc getMonitorRefreshRate(monitor: cint = 0): int {.exportpy: "get_monitor_refresh_rate".} =
  rl.getMonitorRefreshRate(monitor)

proc getWindowTitle(processId: int): string {.exportpy: "get_window_title".} =
  when defined(windows):
    var winHandle = GetWindow(GetTopWindow(0), GW_HWNDNEXT)
    while winHandle != FALSE:
      if IsWindowVisible(winHandle):
        var winProcessId: DWORD
        GetWindowThreadProcessId(winHandle, winProcessId.addr)
        if winProcessId == processId:
          let winLength = GetWindowTextLength(winHandle)
          var winTitle = newWString(winLength)
          GetWindowText(winHandle, winTitle, winLength + 1)
          return nullTerminated($$winTitle)
      winHandle = GetNextWindow(winHandle, GW_HWNDNEXT)
  elif defined(linux):
    let
      p = startProcess("wmctrl", "", ["-l", "-p"], options={poUsePath, poStdErrToStdOut})
      (lines, exitCode) = p.readLines()
    
    if exitCode == 0:
      for l in lines:
        let (r, _, _, pid, _, title) = l.scanTuple("$h $s$i $s$i $s$+ $s$+")
        if r and pid != 0:
          if pid == processId:
            return title
      raise newException(Exception, "No Window found. PID: " & $processId)
    else:
      raise newException(Exception, "wmctrl failed (installed 'wmctrl'?)")