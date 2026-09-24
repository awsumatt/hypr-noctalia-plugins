--!nonstrict
-- Workspace Tabs bar widget - the windows of the workspace this bar sits on, as
-- tabs.
--
-- Pure presentation: every window fact arrives on the "tabs" state channel from
-- service.luau, and every action leaves on the "request" channel. This entry
-- never shells out, so putting the widget on several bars costs nothing extra.
--
-- Which workspace that is, is this instance's business and nobody else's.
-- Noctalia spawns a bar instance per monitor, and barWidget.outputName() names
-- the connector that instance is on, so the same widget definition yields a
-- different strip on every screen - the service publishes one entry per output
-- and this picks its own. See currentEntry() for the rules, and for what happens
-- when the host hands this bar no output name at all.
--
-- Two other details drive most of the code below.
--
-- Width. There is no text measurement API, so a tab strip cannot know what it
-- will cost before it renders. Instead of guessing glyph advances and hoping,
-- the budget is *allocated* in pixels and each label carries `maxWidth`, which
-- makes the renderer elide precisely. An imperfect estimate then shows up as a
-- label that is shorter than it had to be - never as a strip that overflows the
-- bar.
--
-- Hover. The controls take their width *out of the title* while they are shown,
-- so a tab - and every tab after it - is the same width whether or not they are
-- visible; nothing shifts under a stationary pointer. An idle tab simply spends
-- the whole slot on a longer title. Inserting the controls on hover is safe
-- because hover is latched (see onTabHover); without that latch this is exactly
-- the structure that oscillated.
--
-- The hover *tint* is likewise per tab (hover_fill on the hovered one), because
-- Noctalia's own hover highlight is drawn around the whole widget - it can only
-- ever tint the entire strip.

local STATE_KEY = "tabs"
local REQUEST_KEY = "request"
local ELLIPSIS = "…"

-- The bar clips a widget to its thickness, so a tab is one control tall.
local ICON_GAP = 4
-- Control buttons are drawn as fixed-width boxes rather than ui.button on
-- purpose: a button sizes itself, and a control of unknown width would put the
-- one unmeasurable term back into the budget below. A box takes the width it is
-- given, which keeps the whole tab exactly predictable.
local CONTROL_BUTTON_PAD = 8

-- The snapshot the service publishes; anything else reads as "no compositor".
local function unavailable()
  return { available = false, outputs = {} }
end

local state = noctalia.state.get(STATE_KEY) or unavailable()
local iconCache = {}
local hoveredAddress = nil
local requestNonce = 0
local renderedVertical = nil

-- The connector this instance's bar reported at load. Read once on purpose: the
-- host hands a bar widget its output in the constructor and has no setter for it
-- (PluginWidget::ipcOutputName returns a member), so re-deriving it every render
-- would only ever return the same string - or, after a bar rebuild, a fresh
-- "unknown" that must not silently re-target the strip. See currentEntry().
local outputName = barWidget.outputName()
local warnedNoOutput = false
-- The signature of what is currently on the bar, so a push that does not change
-- this strip draws nothing. See renderSignature().
local renderedSignature = nil
-- The tabs currently on screen - this output's slice of the snapshot. Hover and
-- middle click read it, so it has to be the same list render() drew.
local tabs = {}

local cfg = {}
-- cfg's keys, sorted once per readConfig() so renderSignature() never has to sort
-- them on a push.
local cfgKeys = {}

-- A tab is a capsule, and it should be the same capsule as the clock or the
-- tray next to it. The bar expresses that as `capsule_thickness`, a fraction of
-- its own thickness, so the two settings together give the exact pixel height
-- the built-in capsules use. There is no API for "which *bar* am I on" -
-- barWidget.outputName() names the monitor, not the [bar.*] entry - so this
-- reads the first bar in the order: exact for a single-bar setup, and
-- overridable with the tab_height setting when it is not.
--
-- Called from readConfig, so it resolves once per config change rather than per
-- render.
local function resolveTabHeight()
  local configured = math.max(0, tonumber(noctalia.getConfig("tab_height")) or 0)
  if configured > 0 then
    return configured
  end

  local order = noctalia.getSetting("bar.order")
  local name = (type(order) == "table" and type(order[1]) == "string") and order[1] or "default"
  local thickness = tonumber(noctalia.getSetting(`bar.{name}.thickness`))
  local ratio = tonumber(noctalia.getSetting(`bar.{name}.capsule_thickness`))
  if thickness == nil then
    return 0
  end
  return thickness * (ratio or 1.0)
end

local function readConfig()
  cfg.maxTotalWidth = math.max(80, tonumber(noctalia.getConfig("max_total_width")) or 600)
  cfg.maxTitleChars = math.max(1, tonumber(noctalia.getConfig("max_title_chars")) or 24)
  cfg.minTitleChars = math.max(1, tonumber(noctalia.getConfig("min_title_chars")) or 6)
  cfg.charAdvance = math.max(0.3, tonumber(noctalia.getConfig("char_advance")) or 0.55)
  cfg.iconSize = math.max(0, tonumber(noctalia.getConfig("icon_size")) or 16)
  cfg.fontSize = math.max(6, tonumber(noctalia.getConfig("font_size")) or 11)
  cfg.fontWeight = tonumber(noctalia.getConfig("font_weight")) or 0
  cfg.scope = noctalia.getConfig("scope") or "output"
  cfg.showControls = noctalia.getConfig("show_controls") or "hover"
  cfg.enableMaximize = noctalia.getConfig("enable_maximize") == true
  cfg.enableClose = noctalia.getConfig("enable_close") == true
  -- tab_height is not stored: resolveTabHeight() reads it directly, and only the
  -- resolved pixel height is used from here on.
  cfg.tabRadius = math.max(0, tonumber(noctalia.getConfig("tab_radius")) or 8)
  cfg.tabPadding = math.max(0, tonumber(noctalia.getConfig("tab_padding")) or 6)
  cfg.tabGap = math.max(0, tonumber(noctalia.getConfig("tab_gap")) or 4)
  cfg.activeFill = noctalia.getConfig("active_fill") or "primary"
  cfg.activeText = noctalia.getConfig("active_text") or "on_primary"
  cfg.hoverFill = noctalia.getConfig("hover_fill") or "on_surface/0.12"
  cfg.inactiveFill = noctalia.getConfig("inactive_fill") or "surface_variant"
  cfg.inactiveText = noctalia.getConfig("inactive_text") or "on_surface"
  cfg.hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true

  if cfg.minTitleChars > cfg.maxTitleChars then
    cfg.minTitleChars = cfg.maxTitleChars
  end

  cfg.resolvedHeight = resolveTabHeight()

  -- The sorted key list lives with the config: it is what renderSignature()
  -- walks, and rebuilding it per push would be per-push garbage for no reason.
  cfgKeys = {}
  for key in pairs(cfg) do
    table.insert(cfgKeys, key)
  end
  table.sort(cfgKeys)
end

readConfig()

-- ── Helpers ─────────────────────────────────────────────────────────────────

local function charWidth()
  return cfg.fontSize * cfg.charAdvance
end

local function controlCount()
  if cfg.showControls == "off" then
    return 0
  end
  local count = 0
  if cfg.enableMaximize then
    count += 1
  end
  if cfg.enableClose then
    count += 1
  end
  return count
end

local function controlButtonWidth()
  return cfg.fontSize + CONTROL_BUTTON_PAD
end

local function controlSlotWidth()
  return controlCount() * controlButtonWidth()
end

-- Truncate to a character cap while keeping the visible length at `chars`, so
-- the ellipsis does not silently widen the tab.
local function clampChars(text, chars)
  if chars <= 0 or text == "" then
    return ""
  end
  local length = utf8.len(text)
  if length == nil or length <= chars then
    return text
  end
  local cut = utf8.offset(text, chars)
  if cut == nil then
    return text
  end
  return string.sub(text, 1, cut - 1) .. ELLIPSIS
end

local function iconPathFor(class)
  if cfg.iconSize <= 0 or type(class) ~= "string" or class == "" then
    return nil
  end
  local cached = iconCache[class]
  if cached ~= nil then
    return cached or nil
  end
  local resolved = noctalia.appIconPath(class, cfg.iconSize)
  -- Cache the miss too: a class that resolves to nothing will keep resolving to
  -- nothing, and this runs on every render.
  iconCache[class] = resolved or false
  return resolved
end

local function request(action, address)
  requestNonce += 1
  noctalia.state.set(REQUEST_KEY, {
    action = action,
    address = address,
    nonce = requestNonce,
  })
end

-- ── Which slice of the snapshot is ours ─────────────────────────────────────
--
-- barWidget.outputName() is the connector of the output this instance's bar is
-- on - per instance, unlike noctalia.focusedOutputName(). That is the whole
-- feature: three monitors, three bar instances, three different strips.
--
-- The name is not always there. The host derives it from the Wayland output of
-- the bar's surface at construction (PluginWidget takes a connector string and
-- widget_factory passes the empty string when it cannot resolve the wl_output),
-- so an instance can be born nameless - typically during a bar rebuild, and the
-- shell rebuilds bars on monitor focus changes. A nameless strip must not borrow
-- the focused monitor's tabs: that is a different screen's windows drawn as if
-- they were yours, which is exactly the flicker to avoid. So the rules are:
--
--   named, present in the snapshot   -> its own entry
--   named, absent from the snapshot  -> nothing (that monitor is not in the
--                                       compositor's list; borrowing would lie)
--   nameless, exactly one monitor    -> that one entry (no ambiguity to resolve)
--   nameless, several monitors       -> nothing, and say so once in the log
--
-- `scope = "focused"` overrides all of it and is the pre-1.1 behaviour: every
-- strip mirrors whichever workspace is focused.
local function entryFor(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local outputs = state.outputs
  if type(outputs) ~= "table" then
    return nil
  end
  return outputs[name]
end

-- The only entry, or nil when there is more than one and the answer would be a
-- guess.
local function soleEntry()
  local outputs = state.outputs
  if type(outputs) ~= "table" then
    return nil
  end
  local sole = nil
  for _, output in pairs(outputs) do
    if sole ~= nil then
      return nil
    end
    sole = output
  end
  return sole
end

-- A strip that cannot be matched to a monitor is worth one line in the log: the
-- alternative is a bar that is silently empty with no hint why.
local function noteUnmatchedOutput()
  if warnedNoOutput then
    return
  end
  warnedNoOutput = true
  noctalia.log(
    "Workspace Tabs: could not match this bar to a Hyprland monitor; showing nothing rather than another monitor's windows"
  )
end

local function currentEntry()
  if type(state) ~= "table" or state.available ~= true then
    return nil
  end
  if cfg.scope == "focused" then
    return entryFor(state.focusedOutput)
  end

  local own = entryFor(outputName)
  if own ~= nil then
    return own
  end

  if type(outputName) == "string" and outputName ~= "" then
    -- Named but nowhere in the snapshot: a monitor the compositor does not list
    -- (yet). Nothing is right to draw, so draw nothing; the next push fixes it.
    noteUnmatchedOutput()
    return nil
  end

  local sole = soleEntry()
  if sole == nil then
    noteUnmatchedOutput()
  end
  return sole
end

-- ── Width budget ────────────────────────────────────────────────────────────

-- Everything in a tab except the label. Children are laid out with ICON_GAP
-- between them, so the gaps are part of the cost and are counted here rather
-- than being quietly absorbed - that omission is exactly what made the first
-- version overflow its budget.
local function tabFixedWidth(withLabel)
  local parts = 0
  local width = cfg.tabPadding * 2

  if cfg.iconSize > 0 then
    width += cfg.iconSize
    parts += 1
  end
  if withLabel then
    -- The label slot carries the controls inside itself, so nothing extra is
    -- added here; the reserve is subtracted from the label at render time.
    parts += 1
  elseif controlSlotWidth() > 0 and cfg.iconSize <= 0 then
    -- Degenerate case: no icon and no label leaves only the controls.
    width += controlSlotWidth()
    parts += 1
  end

  if parts > 1 then
    width += (parts - 1) * ICON_GAP
  end
  return width
end

-- Space the controls need *inside* the label slot, gap included. Controls only
-- hide behind a title, so an icon-only tab reserves nothing and simply has no
-- controls.
local function controlReserve()
  local slot = controlSlotWidth()
  if slot == 0 then
    return 0
  end
  return slot + ICON_GAP
end

local function overflowChipWidth(count)
  local text = `+{count}`
  return cfg.tabPadding * 2 + (utf8.len(text) or 2) * charWidth()
end

-- Returns the render plan: how many tabs to draw, how many pixels each label
-- may take, and whether an overflow chip is needed. Takes the list as an
-- argument rather than reading the module's `tabs`, so it stays a pure function
-- of (list, config).
local function planLayout(list)
  local count = #list
  local plan = { visible = count, labelWidth = 0, overflow = 0 }
  if count == 0 then
    return plan
  end

  local gaps = (count - 1) * cfg.tabGap
  local fixed = tabFixedWidth(true) * count + gaps
  local budget = cfg.maxTotalWidth - fixed

  -- No reservation: an idle tab spends its entire label slot on the title. The
  -- controls borrow that space only while they are showing, so hiding them
  -- buys title width instead of leaving a permanent gap.
  local minLabel = cfg.minTitleChars * charWidth()
  local maxLabel = cfg.maxTitleChars * charWidth()

  -- 1. Labels at their natural cap.
  if budget >= maxLabel * count then
    plan.labelWidth = maxLabel
    return plan
  end

  -- 2. Shrink labels evenly, down to the floor.
  local perLabel = budget / count
  if perLabel >= minLabel then
    plan.labelWidth = perLabel
    return plan
  end

  -- 3. Labels do not fit at all: icon-only tabs.
  local iconTab = tabFixedWidth(false)
  if cfg.iconSize > 0 and iconTab * count + gaps <= cfg.maxTotalWidth then
    plan.labelWidth = 0
    return plan
  end

  -- 4. Still over: drop the tail into a `+N` chip. Search downward for the
  --    largest number of tabs that fits alongside the chip it implies.
  for visible = count - 1, 1, -1 do
    local hidden = count - visible
    local total = iconTab * visible
      + visible * cfg.tabGap
      + overflowChipWidth(hidden)
    if total <= cfg.maxTotalWidth then
      plan.visible = visible
      plan.labelWidth = 0
      plan.overflow = hidden
      return plan
    end
  end

  -- Even one tab plus the chip is too wide; show the chip alone.
  plan.visible = 0
  plan.labelWidth = 0
  plan.overflow = count
  return plan
end

-- ── Rendering ───────────────────────────────────────────────────────────────

-- Hover identity, and why the controls used to flicker.
--
-- Revealing the controls inserts new nodes under the pointer, and those nodes
-- are hover targets in their own right. Sliding from a tab's title onto its
-- close button therefore reported a *leave* for the tab, which un-revealed the
-- controls, which put plain title back under the pointer, which re-revealed
-- them - forever. The fix is not to ignore leaves (that only made the controls
-- stick, since the widget-level onHover callback never fires here) but to make
-- the whole tab answer to one identity: each control row carries the tab's own
-- address with a `#suffix`, stripped below, so moving anywhere *within* a tab
-- reads as staying on it. Leaves can then be honoured immediately, and only a
-- real exit from the strip produces one.
local function baseAddress(key)
  if type(key) ~= "string" then
    return nil
  end
  local base = string.match(key, "^(.-)#")
  return base or key
end

function onTabHover(hoverState, key)
  local entered = hoverState == true or hoverState == "true"
  local address = baseAddress(key)
  if address == nil or address == "" then
    return
  end

  if not entered then
    if hoveredAddress == address then
      hoveredAddress = nil
      barWidget.clearTooltip()
      render(renderedVertical)
    end
    return
  end

  if hoveredAddress == address then
    return -- already latched here: no state change, so no re-render
  end

  hoveredAddress = address
  for _, tab in ipairs(tabs) do
    if tab.address == address then
      barWidget.setTooltip({
        { key = noctalia.tr("tooltip.title"), value = tab.title ~= "" and tab.title or noctalia.tr("tooltip.untitled") },
        { key = noctalia.tr("tooltip.app"), value = tab.class or "" },
      })
      break
    end
  end
  render(renderedVertical)
end

-- Whether the controls are *painted*. They are always laid out - see below -
-- so this only ever changes colour, never geometry.
local function controlsPainted(tab, vertical)
  if vertical or controlCount() == 0 then
    return false
  end
  return cfg.showControls == "always" or hoveredAddress == tab.address
end

-- Only ever built when the controls are actually showing. The tree changing
-- shape on hover is safe now only because hover is latched (see onTabHover) -
-- without that latch this is precisely the structure that oscillated.
local function controlSlot(tab)
  local glyphColor = tab.focused and cfg.activeText or cfg.inactiveText

  -- ui.row, not ui.box: in Noctalia a box is a leaf - it takes no children and
  -- has no align/justify - so a box wrapping a glyph silently drops the glyph.
  local function controlBox(glyph, action)
    return ui.row({
      -- Reports hover as the tab itself, so sliding onto a button does not read
      -- as leaving the tab. The suffix keeps sibling keys distinct.
      key = `{tab.address}#{action}`,
      onHover = "onTabHover",
      width = controlButtonWidth(),
      align = "center",
      justify = "center",
      onClick = function()
        request(action, tab.address)
      end,
    }, {
      ui.glyph({ name = glyph, size = cfg.fontSize, color = glyphColor }),
    })
  end

  local buttons = {}
  if cfg.enableMaximize then
    table.insert(buttons, controlBox(tab.fullscreen ~= 0 and "minimize" or "maximize", "maximize"))
  end
  if cfg.enableClose then
    table.insert(buttons, controlBox("x", "close"))
  end
  return ui.row({ key = "ctl", gap = 0, align = "center", width = controlSlotWidth() }, buttons)
end

local function tabNode(tab, plan, vertical)
  local focused = tab.focused == true
  local children = {}

  local iconPath = iconPathFor(tab.class)
  if cfg.iconSize > 0 then
    if iconPath ~= nil then
      table.insert(children, ui.image({
        path = iconPath,
        width = cfg.iconSize,
        height = cfg.iconSize,
        fit = "contain",
      }))
    else
      table.insert(children, ui.glyph({
        name = "app-window",
        size = cfg.iconSize,
        color = focused and cfg.activeText or cfg.inactiveText,
      }))
    end
  end

  if plan.labelWidth > 0 and not vertical then
    local title = tab.title ~= "" and tab.title or (tab.class or "")
    -- Controls occupy space only while shown, and they take it from the title
    -- rather than from the strip: the label slot is a fixed width either way,
    -- so the tab - and every tab after it - stays put. Idle tabs spend that
    -- space on the title instead.
    local showControls = controlsPainted(tab, vertical)

    local textWidth = plan.labelWidth
    if showControls then
      textWidth = math.max(0, textWidth - controlReserve())
    end

    local weight = cfg.fontWeight > 0 and cfg.fontWeight or (focused and "semibold" or "medium")
    local slotChildren = {
      ui.label({
        key = "title",
        text = clampChars(title, cfg.maxTitleChars),
        -- The renderer elides at this width, so the pixel budget above is a
        -- guarantee rather than an estimate.
        maxWidth = textWidth,
        maxLines = 1,
        fontSize = cfg.fontSize,
        fontWeight = weight,
        color = focused and cfg.activeText or cfg.inactiveText,
      }),
    }
    if showControls then
      table.insert(slotChildren, controlSlot(tab))
    end

    table.insert(children, ui.row({
      key = "body",
      width = plan.labelWidth,
      gap = ICON_GAP,
      align = "center",
      -- Pins the controls to the right edge, so a short title does not drag
      -- them into the middle of the tab.
      justify = "space_between",
    }, slotChildren))
  end

  local container = vertical and ui.column or ui.row
  local props = {
    key = tab.address,
    gap = ICON_GAP,
    align = "center",
    justify = "center",
    -- The hover tint is per tab, not per strip. Noctalia's own hover highlight
    -- is drawn by the bar around the whole widget (Bar::animateWidgetHoverHighlight
    -- takes the Widget), and it is a bar-level setting, so it can only ever tint
    -- the entire strip. Painting the hovered tab here is what makes the feedback
    -- follow the pointer from tab to tab; turn the bar's highlight off if you
    -- would rather not have both.
    fill = focused and cfg.activeFill
      or (hoveredAddress == tab.address and cfg.hoverFill or cfg.inactiveFill),
    radius = cfg.tabRadius,
    onClick = function()
      request("focus", tab.address)
    end,
    onHover = "onTabHover",
  }
  if cfg.resolvedHeight > 0 then
    props.height = cfg.resolvedHeight
  end
  if vertical then
    props.paddingV = cfg.tabPadding
  else
    props.paddingH = cfg.tabPadding
  end

  return container(props, children)
end

local function overflowNode(count, vertical)
  local container = vertical and ui.column or ui.row
  return container({
    key = "__overflow__",
    align = "center",
    justify = "center",
    fill = cfg.inactiveFill,
    radius = cfg.tabRadius,
    height = cfg.resolvedHeight > 0 and cfg.resolvedHeight or nil,
    paddingH = vertical and nil or cfg.tabPadding,
    paddingV = vertical and cfg.tabPadding or nil,
    onClick = function()
      noctalia.runAsync({ "noctalia", "msg", "window-switcher" })
    end,
  }, {
    ui.label({
      text = `+{count}`,
      fontSize = cfg.fontSize,
      fontWeight = cfg.fontWeight > 0 and cfg.fontWeight or "semibold",
      color = cfg.inactiveText,
    }),
  })
end

-- Everything the tree below is built from, folded into one string.
--
-- Why bother: a bar surface redraw costs tens of milliseconds on a busy session,
-- and the service publishes on every event on every monitor - a title keystroke
-- in a browser, a window closing on another screen, a focus change. Rendering
-- when none of *this* strip's content changed is what made every bar on the desk
-- visibly blink along with the one that actually changed. The digest covers the
-- entry's tabs, the config, the hover latch and the bar's orientation, so a push
-- that would build the identical tree is dropped before it reaches the host.
--
-- The config half walks cfgKeys (sorted in readConfig) rather than cfg itself,
-- so a new setting cannot be forgotten here and no sort happens per push.
local function renderSignature(entry, vertical)
  if entry == nil or (cfg.hideWhenEmpty and #(entry.tabs or {}) == 0) then
    return "hidden"
  end

  local parts = { vertical and "vertical" or "horizontal", tostring(hoveredAddress) }
  for _, key in ipairs(cfgKeys) do
    table.insert(parts, `{key}={cfg[key]}`)
  end
  for _, tab in ipairs(entry.tabs) do
    -- The fields tabNode() reads. Keep in step with it.
    table.insert(parts, `{tab.address}|{tab.title}|{tab.class}|{tab.focused}|{tab.fullscreen}`)
  end
  return table.concat(parts, "\n")
end

function render(vertical)
  if vertical == nil then
    vertical = barWidget.isVertical()
  end
  renderedVertical = vertical

  local entry = currentEntry()
  tabs = (entry ~= nil and entry.tabs) or {}

  local signature = renderSignature(entry, vertical)
  if signature == renderedSignature then
    return
  end
  renderedSignature = signature

  if entry == nil or (#tabs == 0 and cfg.hideWhenEmpty) then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local plan = planLayout(tabs)
  local children = {}
  for index, tab in ipairs(tabs) do
    if index > plan.visible then
      break
    end
    table.insert(children, tabNode(tab, plan, vertical))
  end
  if plan.overflow > 0 then
    table.insert(children, overflowNode(plan.overflow, vertical))
  end

  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = cfg.tabGap, align = "center" }, children))
end

-- ── Host callbacks ──────────────────────────────────────────────────────────

function update()
  local vertical = barWidget.isVertical()
  if vertical ~= renderedVertical then
    render(vertical)
  end
end

-- The only thing that unlatches hover. Per-tab leaves are ignored (see
-- onTabHover), so this is what returns the strip to its resting state once the
-- pointer is off the widget entirely.
--
-- The normalisation matters: the pointer state arrives as the string "false"
-- as often as the boolean, and `not "false"` is false in Lua, so a plain
-- truthiness test silently never unlatches - which is exactly how the controls
-- ended up sticky.
function onHover(entered)
  local isInside = entered == true or entered == "true"
  if not isInside and hoveredAddress ~= nil then
    hoveredAddress = nil
    barWidget.clearTooltip()
    render(renderedVertical)
  end
end

-- The ui tree has no per-node middle click, only onClick/onRightClick. Closing
-- the *hovered* tab from the widget-level callback is what makes middle-click
-- close work at all - hence `middle = "none"` in plugin.toml, without which
-- this never fires.
function onMiddleClick()
  if hoveredAddress ~= nil and cfg.enableClose then
    request("close", hoveredAddress)
  end
end

function onConfigChanged()
  readConfig()
  iconCache = {}
  render(renderedVertical)
end

noctalia.state.watch(STATE_KEY, function(value)
  state = type(value) == "table" and value or unavailable()
  render(renderedVertical)
end)

render(barWidget.isVertical())
