# Workspace Tabs

Browser-style tabs for every window on this bar's Hyprland workspace.

| Field | Value |
| --- | --- |
| ID | `awsumatt/workspace-tabs` |
| Widget | `awsumatt/workspace-tabs:tabs` |
| Service | `awsumatt/workspace-tabs:tabs-state` |
| Requires | Hyprland, `socat` |

## Behaviour

Each tab shows the application icon and the window title. The focused window's
tab is filled with the active colour.

The strip is **per monitor**. Noctalia spawns one bar instance per monitor, and
each widget instance asks the host which output its bar is on
(`barWidget.outputName()`), so every screen shows the tabs of the workspace
displayed *there* — not whichever workspace happens to be focused. A monitor
showing a special workspace shows that workspace's windows instead. Move the
pointer to another screen and neither strip changes; focus a window on another
monitor and the tab fills in on that monitor's strip only.

A strip only ever draws its own monitor. If the host hands a bar no output name
(the connector is resolved from the bar's Wayland surface at construction, and
can come back empty during a bar rebuild) nothing is drawn for that instant
rather than another screen's windows — except on a single-monitor setup, where
there is nothing to be ambiguous about. A bar whose connector matches no
Hyprland monitor behaves the same way and logs one line saying so.

Set `scope` to `focused` to go back to a single strip mirrored on every monitor,
following whichever workspace is focused.

| Gesture | Action |
| --- | --- |
| Left click | Focus the window |
| Hover | Reveal the maximize and close controls, and show a title/app tooltip |
| Click maximize | Toggle maximize on that window |
| Click close | Close that window |
| Middle click | Close the hovered window |

Hovering borrows width from the title rather than from the strip, so a tab is
the same width whether or not its controls are showing and nothing shifts under
the pointer. An idle tab spends that space on a longer title.

The tab under the pointer is tinted with `hover_fill`, so the highlight follows
the cursor from tab to tab. Noctalia also draws a hover highlight of its own
(`Bar::animateWidgetHoverHighlight` takes the whole `Widget`), and its setting is
bar-level (`[bar.<name>] hover_highlight`, also per-monitor under
`[bar.<name>.monitor.*]`), so it can only ever tint the entire strip. Turn it off
in Bar → Hover highlight if you want the per-tab tint to be the only feedback —
note that this applies to every widget on that bar, not just this one, and that
there is no per-widget switch for it.

Middle click requires the widget's `middle` gesture to be unbound, which the
manifest does by default (`[widget.actions] middle = "none"`). Every widget
otherwise ships `middle = "settings-open-widget"`, which would swallow it.

## Overflow

The strip never grows past `max_total_width`. It degrades in order:

1. Titles shrink evenly, down to `min_title_chars`.
2. Tabs drop to icons only.
3. Surplus tabs collapse into a `+N` chip that opens the window switcher.

Widths are budgeted in pixels and each title carries a `maxWidth`, so the
renderer elides exactly; `char_advance` only converts the character limits into
that budget. Raise it if titles look cramped, lower it if the strip stops short.

## Settings

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `max_total_width` | int | 600 | Pixel ceiling for the whole strip |
| `max_title_chars` | int | 24 | Hard cap on title length |
| `min_title_chars` | int | 6 | Floor before going icon-only |
| `char_advance` | double | 0.55 | Character width as a fraction of font size |
| `icon_size` | int | 16 | 0 hides icons |
| `font_size` | int | 11 | |
| `font_weight` | int | 0 | 0 uses semibold/medium by focus |
| `scope` | select | `output` | `output` = this bar's monitor, `focused` = every strip follows the focus |
| `show_controls` | select | `hover` | `hover` / `always` / `off` |
| `enable_maximize` | bool | true | |
| `enable_close` | bool | true | |
| `tab_height` | int | 0 | 0 matches the bar's capsule thickness |
| `tab_radius` | int | 8 | |
| `tab_padding` | int | 6 | |
| `tab_gap` | int | 4 | |
| `active_fill` / `active_text` | color | `primary` / `on_primary` | |
| `inactive_fill` / `inactive_text` | color | `surface_variant` / `on_surface` | |
| `hover_fill` | color | `on_surface/0.12` | Tint of the tab under the pointer; role/alpha or hex |
| `hide_when_empty` | bool | true | |

## Implementation notes

The Noctalia plugin API exposes no window or workspace introspection, so all
window state comes from Hyprland directly. One `[[service]]` owns that I/O and
publishes a per-output snapshot on the plugin state channel; the widget is pure
presentation, so N bars cost one poller.

- Snapshots come from `hyprctl -j clients` + `-j monitors`, coalesced at 10 Hz.
  Grouping them per monitor is free: a monitor's `activeWorkspace` and each
  client's `workspace` already carry the mapping, so no extra call is needed.
- A workspace is displayed on exactly one monitor, so the workspace id alone
  joins windows to strips. Special workspaces are handled per monitor and win
  over `activeWorkspace` on the monitor showing them.
- Each widget instance reads its own slice using `barWidget.outputName()` — the
  connector of the output its bar is on, and the one piece of bar introspection
  Noctalia exposes. It is per instance, unlike `noctalia.focusedOutputName()`,
  and fixed for the instance's life: the host resolves it from the bar's Wayland
  surface at construction (`widget_factory.cpp` passes an empty string when that
  lookup fails), and there is no setter. A strip that cannot be matched to a
  monitor draws nothing rather than the focused monitor's tabs.
- Only a strip that actually changed redraws. The widget folds its whole visual
  state — entry tabs, settings, hover latch, orientation — into a signature and
  drops a push that would rebuild the identical tree. Bar surface redraws cost
  tens of milliseconds, and the service publishes on every event on every
  monitor, so without this a title keystroke on one screen made all of them
  blink.
- `focusedmon`/`focusedmonv2` are patched from the event line instead of forcing
  a refresh: a monitor focus change moves no window, so it only repoints the
  fallback that a `scope = "focused"` strip reads. Clicking another monitor no
  longer re-reads the compositor.
- `windowtitlev2` and `activewindowv2` carry their whole payload in the event
  line and are patched in without spawning a subprocess. A browser emits
  `windowtitlev2` on every keystroke in the URL bar, so this matters.
- Tabs are ordered spatially, not by focus history, so clicking one never
  reorders the strip.

### Window actions

On a Lua-configured Hyprland, `hyprctl dispatch` evaluates its argument as
`return hl.dispatch(<arg>)`. `hl.dsp.*` are *builders* that return a dispatcher,
and the classic `dispatch closewindow address:0x…` string no longer parses.
Targeting a window means `window = hl.get_window("address:…")`.

That call returns nil for an address that has gone away, and a dispatcher given
`window = nil` **falls back to the active window** — so an unguarded close on a
stale tab would close whatever you were looking at. Every action is therefore
built as an expression that returns `hl.dsp.no_op()` when the lookup fails.
