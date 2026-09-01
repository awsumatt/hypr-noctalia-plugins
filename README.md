# Hyprland Noctalia Plugins

#### _Noctalia v5 plugins for Hyprland_

## **Workspace Tabs** (`awsumatt/workspace-tabs`)

Browser-style tabs for every window on the focused workspace. Application icon
plus title, click to focus, middle-click or the hover-revealed close button to
close, and a maximize toggle.

### Installation

Add this repository as a plugin source in Noctalia:

```bash
noctalia msg plugins source add hypr-plugins git https://github.com/awsumatt/hypr-noctalia-plugins.git
```

Then enable the plugin from the Noctalia plugin manager and add the **Workspace
Tabs** widget to a bar.

### Requirements

- Hyprland
- `socat` (for the compositor event stream)
