--!nonstrict
-- Workspace Tabs bar widget - the windows of the focused workspace, as tabs.
--
-- Pure presentation: every window fact arrives on the "tabs" state channel from
-- service.luau, and every action leaves on the "request" channel. This entry
-- never shells out, so putting the widget on several bars costs nothing extra.
--
-- Two details drive most of the code below.
--
-- Width. There is no text measurement API, so a tab strip cannot know what it
-- will cost before it renders. Instead of guessing glyph advances and hoping,
-- the budget is *allocated* in pixels and each label carries `maxWidth`, which
-- makes the renderer elide precisely. An imperfect estimate then shows up as a
-- label that is shorter than it had to be - never as a strip that overflows the
-- bar.
--
-- Hover. Revealing controls by inserting them on hover would change the strip's
-- width, re-lay-out the row, and can slide a different tab under a stationary
-- cursor - which flips the hover, which re-lays-out again. So the control slot
-- is always in the layout at a fixed width and only its *contents* change: an
-- inert ui.spacer when idle, buttons when shown. Same width either way, no
-- reflow, and no invisible click targets.

local STATE_KEY = "tabs"
local REQUEST_KEY = "request"
local ELLIPSIS = "…"

-- The bar clips a widget to its thickness, so a tab is one control tall.
local ICON_GAP = 4
local CONTROL_BUTTON_PAD = 10

local state = noctalia.state.get(STATE_KEY) or { available = false, tabs = {} }
local iconCache = {}
local hoveredAddress = nil
local requestNonce = 0
local renderedVertical = nil

local cfg = {}

local function readConfig()
  cfg.maxTotalWidth = math.max(80, tonumber(noctalia.getConfig("max_total_width")) or 600)
  cfg.maxTitleChars = math.max(1, tonumber(noctalia.getConfig("max_title_chars")) or 24)
  cfg.minTitleChars = math.max(1, tonumber(noctalia.getConfig("min_title_chars")) or 6)
  cfg.charAdvance = math.max(0.3, tonumber(noctalia.getConfig("char_advance")) or 0.55)
  cfg.iconSize = math.max(0, tonumber(noctalia.getConfig("icon_size")) or 16)
  cfg.fontSize = math.max(6, tonumber(noctalia.getConfig("font_size")) or 11)
  cfg.showControls = noctalia.getConfig("show_controls") or "hover"
  cfg.enableMaximize = noctalia.getConfig("enable_maximize") == true
  cfg.enableClose = noctalia.getConfig("enable_close") == true
  cfg.tabRadius = math.max(0, tonumber(noctalia.getConfig("tab_radius")) or 8)
  cfg.tabPadding = math.max(0, tonumber(noctalia.getConfig("tab_padding")) or 6)
  cfg.tabGap = math.max(0, tonumber(noctalia.getConfig("tab_gap")) or 4)
  cfg.activeFill = noctalia.getConfig("active_fill") or "primary"
  cfg.activeText = noctalia.getConfig("active_text") or "on_primary"
  cfg.inactiveFill = noctalia.getConfig("inactive_fill") or "surface_variant"
  cfg.inactiveText = noctalia.getConfig("inactive_text") or "on_surface"
  cfg.hideWhenEmpty = noctalia.getConfig("hide_when_empty") == true

  if cfg.minTitleChars > cfg.maxTitleChars then
    cfg.minTitleChars = cfg.maxTitleChars
  end
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
  local count = controlCount()
  if count == 0 then
    return 0
  end
  return count * controlButtonWidth() + ICON_GAP
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

-- ── Width budget ────────────────────────────────────────────────────────────
--
-- Fixed cost of one tab, i.e. everything that is not the label.

local function tabFixedWidth(withIcon)
  local width = cfg.tabPadding * 2 + controlSlotWidth()
  if withIcon and cfg.iconSize > 0 then
    width += cfg.iconSize
  end
  return width
end

local function overflowChipWidth(count)
  local text = `+{count}`
  return cfg.tabPadding * 2 + (utf8.len(text) or 2) * charWidth()
end

-- Returns the render plan: how many tabs to draw, how many pixels each label
-- may take, and whether an overflow chip is needed.
local function planLayout(tabs)
  local count = #tabs
  local plan = { visible = count, labelWidth = 0, overflow = 0 }
  if count == 0 then
    return plan
  end

  local gaps = (count - 1) * cfg.tabGap
  local fixed = tabFixedWidth(true) * count + gaps
  local budget = cfg.maxTotalWidth - fixed

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
  if cfg.iconSize > 0 then
    local iconOnly = tabFixedWidth(true) * count + gaps
    if iconOnly <= cfg.maxTotalWidth then
      plan.labelWidth = 0
      return plan
    end
  end

  -- 4. Still over: drop the tail into a `+N` chip. Search downward for the
  --    largest number of tabs that fits alongside the chip it implies.
  local iconTab = tabFixedWidth(cfg.iconSize > 0)
  for visible = count - 1, 1, -1 do
    local hidden = count - visible
    local total = iconTab * visible
      + (visible) * cfg.tabGap
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

function onTabHover(hoverState, key)
  local entered = hoverState == true or hoverState == "true"
  if entered then
    hoveredAddress = key
    for _, tab in ipairs(state.tabs or {}) do
      if tab.address == key then
        barWidget.setTooltip({
          { key = noctalia.tr("tooltip.title"), value = tab.title ~= "" and tab.title or noctalia.tr("tooltip.untitled") },
          { key = noctalia.tr("tooltip.app"), value = tab.class or "" },
        })
        break
      end
    end
  elseif hoveredAddress == key then
    hoveredAddress = nil
    barWidget.clearTooltip()
  end
  render(renderedVertical)
end

local function controlSlot(tab, vertical)
  local count = controlCount()
  if count == 0 or vertical then
    return nil
  end

  local shown = cfg.showControls == "always" or hoveredAddress == tab.address
  if not shown then
    -- Reserve the exact same width, but with nothing interactive in it.
    return ui.spacer({ width = controlSlotWidth() })
  end

  local buttons = {}
  if cfg.enableMaximize then
    table.insert(buttons, ui.button({
      glyph = tab.fullscreen ~= 0 and "minimize" or "maximize",
      glyphSize = cfg.fontSize,
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        request("maximize", tab.address)
      end,
    }))
  end
  if cfg.enableClose then
    table.insert(buttons, ui.button({
      glyph = "x",
      glyphSize = cfg.fontSize,
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        request("close", tab.address)
      end,
    }))
  end
  return ui.row({ gap = 0, align = "center", minWidth = controlSlotWidth() }, buttons)
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
    table.insert(children, ui.label({
      text = clampChars(title, cfg.maxTitleChars),
      -- The renderer elides at this width, so the pixel budget above is a
      -- guarantee rather than an estimate.
      maxWidth = plan.labelWidth,
      maxLines = 1,
      fontSize = cfg.fontSize,
      fontWeight = focused and "semibold" or "medium",
      color = focused and cfg.activeText or cfg.inactiveText,
    }))
  end

  local slot = controlSlot(tab, vertical)
  if slot ~= nil then
    table.insert(children, slot)
  end

  local container = vertical and ui.column or ui.row
  local props = {
    key = tab.address,
    gap = ICON_GAP,
    align = "center",
    justify = "center",
    fill = focused and cfg.activeFill or cfg.inactiveFill,
    radius = cfg.tabRadius,
    onClick = function()
      request("focus", tab.address)
    end,
    onHover = "onTabHover",
  }
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
    paddingH = vertical and nil or cfg.tabPadding,
    paddingV = vertical and cfg.tabPadding or nil,
    onClick = function()
      noctalia.runAsync({ "noctalia", "msg", "window-switcher" })
    end,
  }, {
    ui.label({
      text = `+{count}`,
      fontSize = cfg.fontSize,
      fontWeight = "semibold",
      color = cfg.inactiveText,
    }),
  })
end

function render(vertical)
  if vertical == nil then
    vertical = barWidget.isVertical()
  end
  renderedVertical = vertical

  local tabs = state.tabs or {}

  if state.available ~= true then
    barWidget.setVisible(false)
    return
  end
  if #tabs == 0 and cfg.hideWhenEmpty then
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

-- The widget-level hover leave is the reliable one: if the pointer exits the
-- strip between two tabs, a per-tab leave can be missed.
function onHover(entered)
  if not entered and hoveredAddress ~= nil then
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
  state = type(value) == "table" and value or { available = false, tabs = {} }
  render(renderedVertical)
end)

render(barWidget.isVertical())
