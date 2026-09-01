# Workspace Tabs

Browser-style tabs for every window on the focused Hyprland workspace.

| Field | Value |
| --- | --- |
| ID | `awsumatt/workspace-tabs` |
| Widget | `awsumatt/workspace-tabs:tabs` |
| Service | `awsumatt/workspace-tabs:tabs-state` |
| Requires | Hyprland, `socat` |

## Behaviour

Each tab shows the application icon and the window title. The focused window's
tab is filled with the active colour.

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
| `show_controls` | select | `hover` | `hover` / `always` / `off` |
| `enable_maximize` | bool | true | |
| `enable_close` | bool | true | |
| `tab_height` | int | 0 | 0 matches the bar's capsule thickness |
| `tab_radius` | int | 8 | |
| `tab_padding` | int | 6 | |
| `tab_gap` | int | 4 | |
| `active_fill` / `active_text` | color | `primary` / `on_primary` | |
| `inactive_fill` / `inactive_text` | color | `surface_variant` / `on_surface` | |
| `hide_when_empty` | bool | true | |

## Implementation notes

The Noctalia plugin API exposes no window or workspace introspection, so all
window state comes from Hyprland directly. One `[[service]]` owns that I/O and
publishes a snapshot on the plugin state channel; the widget is pure
presentation, so N bars cost one poller.

- Snapshots come from `hyprctl -j clients` + `-j monitors`, coalesced at 10 Hz.
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
