--!nonstrict
-- Workspace Tabs service - the only entry that talks to Hyprland.
--
-- The plugin API has no window or workspace introspection at all, so the window
-- list has to come from the compositor directly. Two sources, and the split
-- between them is the whole point of this file:
--
--   hyprctl -j clients / -j monitors   full truth, but a subprocess per call
--   socat on .socket2.sock             a push stream, but only tells us *what*
--                                      changed, not the new state
--
-- Naively refreshing on every event would be a subprocess storm: a browser
-- emits `windowtitlev2` on every keystroke in the URL bar. So events are split
-- in two. `windowtitlev2` and `activewindowv2` carry their whole payload in the
-- line itself and are patched into the snapshot with no subprocess at all;
-- everything else marks the snapshot dirty and a 100 ms tick coalesces the
-- burst into one hyprctl pair.
--
--   noctalia.runStream(cmd, onLine)          long-lived child, one call per line
--   noctalia.state.set("tabs", snapshot)     one snapshot, one widget re-render
--   noctalia.state.watch("request", handler) focus / close / maximize from the bar

local STATE_KEY = "tabs"
local REQUEST_KEY = "request"
local SEPARATOR = "__NOCTALIA_WORKSPACE_TABS_SPLIT__"
local STREAM_REFRESH_MARKER = "__NOCTALIA_WORKSPACE_TABS_STREAM_REFRESH__"
local SNAPSHOT_ATTEMPTS = 2
local TICK_MS = 100

local snapshot = { available = false, workspace = nil, tabs = {} }
local refreshInFlight = false
local refreshPending = false
local dirty = false
local loggedSnapshotError = false

local function logOnce(message)
  if not loggedSnapshotError then
    noctalia.log(`Workspace Tabs: {message}; retaining last state`)
    loggedSnapshotError = true
  end
end

local function shellQuote(value)
  return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

-- `hyprctl -j clients` reports addresses as `0x55fd…`, while the event socket
-- reports them bare. Rather than depend on which side carries the prefix,
-- compare on the bare form everywhere.
local function bareAddress(value)
  if type(value) ~= "string" then
    return ""
  end
  return string.gsub(value, "^0[xX]", "")
end

-- Hyprland only means anything on a Hyprland session, and the event stream needs
-- socat. Without either, publish an unavailable snapshot once and stay quiet -
-- the widget hides itself rather than showing a dead icon.
local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
local available = runtimeDir ~= nil
  and signature ~= nil
  and noctalia.commandExists("hyprctl")

local function publish()
  noctalia.state.set(STATE_KEY, snapshot)
end

-- Hyprland reports the special workspace separately from activeWorkspace: when
-- one is open it is what the user actually sees, so it wins.
local function focusedWorkspaceOf(monitors)
  for _, monitor in ipairs(monitors) do
    if monitor.focused == true then
      local special = monitor.specialWorkspace
      if type(special) == "table" and type(special.name) == "string" and special.name ~= "" then
        return { id = special.id, name = special.name }, monitor.name
      end
      local active = monitor.activeWorkspace
      if type(active) == "table" then
        return { id = active.id, name = active.name }, monitor.name
      end
      return nil, monitor.name
    end
  end
  return nil, nil
end

local function buildSnapshot(clientsJson, monitorsJson)
  local clients = noctalia.json.decode(clientsJson)
  local monitors = noctalia.json.decode(monitorsJson)
  if type(clients) ~= "table" or type(monitors) ~= "table" then
    return nil, "invalid Hyprland JSON"
  end

  local workspace, outputName = focusedWorkspaceOf(monitors)
  if workspace == nil then
    return { available = true, workspace = nil, output = outputName, tabs = {} }
  end

  local tabs = {}
  for _, client in ipairs(clients) do
    local ws = client.workspace
    if
      type(ws) == "table"
      and ws.id == workspace.id
      and client.mapped == true
      and client.hidden ~= true
      and type(client.address) == "string"
    then
      local at = type(client.at) == "table" and client.at or { 0, 0 }
      table.insert(tabs, {
        address = client.address,
        class = client.class ~= "" and client.class or client.initialClass,
        title = client.title or "",
        -- focusHistoryID 0 is the focused window compositor-wide, so when focus
        -- sits on another output no tab here claims it. That is correct.
        focused = client.focusHistoryID == 0,
        fullscreen = tonumber(client.fullscreen) or 0,
        floating = client.floating == true,
        x = tonumber(at[1]) or 0,
        y = tonumber(at[2]) or 0,
      })
    end
  end

  -- Spatial order, not focus order: sorting by focusHistoryID would reshuffle
  -- the strip on every click, which is the one thing tabs must never do.
  table.sort(tabs, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.address < b.address
  end)

  return { available = true, workspace = workspace, output = outputName, tabs = tabs }
end

local function refresh()
  if not available then
    return
  end
  if refreshInFlight then
    refreshPending = true
    return
  end
  refreshInFlight = true

  local command = "attempt=1; while [ \"$attempt\" -le " .. SNAPSHOT_ATTEMPTS
    .. " ]; do clients=$(hyprctl -j clients) && monitors=$(hyprctl -j monitors)"
    .. " && { printf '%s\\n" .. SEPARATOR .. "\\n%s\\n' \"$clients\" \"$monitors\"; exit 0; };"
    .. " attempt=$((attempt + 1)); [ \"$attempt\" -le " .. SNAPSHOT_ATTEMPTS
    .. " ] && sleep 1; done; exit 1"

  local started = noctalia.runAsync(command, function(result)
    if result.exitCode ~= 0 then
      logOnce("hyprctl failed")
    else
      local markerStart, markerEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", 1, true)
      if not markerStart then
        logOnce("incomplete hyprctl snapshot")
      else
        local built, err = buildSnapshot(
          string.sub(result.stdout, 1, markerStart - 1),
          string.sub(result.stdout, markerEnd + 1)
        )
        if built == nil then
          -- Keep the last good state through a transient compositor hiccup.
          logOnce(`snapshot failed ({err})`)
        else
          loggedSnapshotError = false
          snapshot = built
          publish()
        end
      end
    end

    refreshInFlight = false
    if refreshPending then
      refreshPending = false
      refresh()
    end
  end)

  if not started then
    refreshInFlight = false
    logOnce("could not start hyprctl snapshot")
  end
end

-- ── Fast paths: patch the snapshot from the event line, no subprocess ────────

local function patchTitle(address, title)
  for _, tab in ipairs(snapshot.tabs) do
    if bareAddress(tab.address) == address then
      if tab.title ~= title then
        tab.title = title
        publish()
      end
      return true
    end
  end
  return false
end

local function patchFocus(address)
  local changed = false
  local matched = false
  for _, tab in ipairs(snapshot.tabs) do
    local isFocused = address ~= "" and bareAddress(tab.address) == address
    if isFocused then
      matched = true
    end
    if tab.focused ~= isFocused then
      tab.focused = isFocused
      changed = true
    end
  end
  if changed then
    publish()
  end
  -- Focus landing on a window we do not track means the workspace changed under
  -- us; that needs a real snapshot.
  return matched or address == ""
end

-- Events that change *which* windows exist or where they live. Everything here
-- costs one debounced hyprctl pair.
local refreshEvents = {
  openwindow = true,
  closewindow = true,
  movewindow = true,
  movewindowv2 = true,
  workspace = true,
  workspacev2 = true,
  createworkspace = true,
  createworkspacev2 = true,
  destroyworkspace = true,
  destroyworkspacev2 = true,
  moveworkspace = true,
  moveworkspacev2 = true,
  renameworkspace = true,
  activespecial = true,
  activespecialv2 = true,
  focusedmon = true,
  focusedmonv2 = true,
  monitoradded = true,
  monitoraddedv2 = true,
  monitorremoved = true,
  monitorremovedv2 = true,
  fullscreen = true,
  changefloatingmode = true,
  urgent = true,
}

local function onLine(line)
  if line == STREAM_REFRESH_MARKER then
    dirty = true
    return
  end

  local event, payload = string.match(line, "^([%a%d_]+)>>(.*)$")
  if event == nil then
    return
  end

  -- `windowtitlev2>>ADDRESS,title` - the payload is the whole update. Browsers
  -- emit this per keystroke, so routing it through hyprctl would be pure waste.
  if event == "windowtitlev2" then
    local address, title = string.match(payload, "^([^,]*),(.*)$")
    if address ~= nil and address ~= "" then
      if not patchTitle(bareAddress(address), title) then
        dirty = true
      end
    end
    return
  end

  -- `activewindowv2>>ADDRESS` (empty when focus is dropped).
  if event == "activewindowv2" then
    if not patchFocus(bareAddress(payload)) then
      dirty = true
    end
    return
  end

  if refreshEvents[event] then
    dirty = true
  end
end

local function startEventStream()
  if not available then
    return
  end
  if not noctalia.commandExists("socat") then
    noctalia.log("Workspace Tabs: socat is unavailable; falling back to polling only")
    return
  end

  local socket = `{runtimeDir}/hypr/{signature}/.socket2.sock`
  -- One helper that survives a compositor restart: wait for the socket, announce
  -- a resync, then hold the stream. Noctalia kills the whole command on unload.
  local command = "while true; do while [ ! -S " .. shellQuote(socket)
    .. " ]; do sleep 5; done; printf '" .. STREAM_REFRESH_MARKER
    .. "\\n'; socat -u UNIX-CONNECT:" .. shellQuote(socket)
    .. " - 2>&1; sleep 5; done"

  if not noctalia.runStream(command, onLine) then
    noctalia.log("Workspace Tabs: could not start the socat event stream")
  end
end

-- ── Actions requested by the bar widget ─────────────────────────────────────

local function dispatch(argv, failureKey)
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.notifyError(noctalia.tr(failureKey), noctalia.string.trim(result.stderr))
    end
    -- Success needs no refresh: the compositor announces the change on the
    -- stream by itself.
  end)
end

local function handleRequest(request)
  if type(request) ~= "table" or type(request.address) ~= "string" then
    return
  end
  local target = `address:{request.address}`

  if request.action == "focus" then
    dispatch({ "hyprctl", "dispatch", "focuswindow", target }, "notify.focus_failed")
  elseif request.action == "close" then
    dispatch({ "hyprctl", "dispatch", "closewindow", target }, "notify.close_failed")
  elseif request.action == "maximize" then
    -- Window dispatchers act on the active window, so the toggle has to focus
    -- first. --batch keeps that atomic. `fullscreen 1` is Hyprland's maximize,
    -- and it toggles off when the window is already in that state.
    dispatch({
      "hyprctl",
      "--batch",
      `dispatch focuswindow {target} ; dispatch fullscreen 1`,
    }, "notify.maximize_failed")
  end
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

function update()
  -- The debounce. Bursts (opening a workspace, closing a window with children)
  -- collapse into a single hyprctl pair at 10 Hz instead of one per event.
  if dirty and not refreshInFlight then
    dirty = false
    refresh()
  end
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

noctalia.setUpdateInterval(TICK_MS)

if available then
  refresh()
  startEventStream()
else
  noctalia.log("Workspace Tabs: not a Hyprland session; the widget stays hidden")
  publish()
end
