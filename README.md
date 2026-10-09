# Window overview

Mission Control for [Omarchy](https://omarchy.org/): live thumbnails of every
open window on one screen. Click one to jump to it.

`Super+Tab` opens it on the focused monitor with every window, grouped by
workspace. Pressing `Super+Tab` again (or `Tab`) switches to just the
workspace you are on and back. Windows on the current workspace zoom out from
where they are. Typing filters on title, app and workspace.

| Key | Does |
|---|---|
| `Super+Tab`, `Tab` | All workspaces ⇄ this workspace |
| arrows, mouse hover | Select |
| `Enter`, click | Go to the window, wherever it is |
| `Shift+Enter`, Shift+click | Bring it to this workspace, then focus it |
| `Delete`, middle click | Close the window |
| type | Filter |
| `Esc`, click outside | Clear the filter, then close |

## Snapshots

Hyprland only captures windows that are drawn or sit on a hidden workspace. A
window scrolled off-screen on a visible workspace (scrolling layout) has no
live picture, so the plugin's service keeps the last snapshot of each window:
it captures a window whenever it gets focus, every 30 s while it keeps focus,
and whenever the overview shows it live. Snapshots copy only the window itself
and stay in memory; a window that has not been on screen since the shell
started shows its app icon.

## Install

```bash
omarchy plugin add https://github.com/dbarke/omarchy-overview --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`. Use `summon`, not `toggle`,
so pressing the key again switches mode instead of closing. Super+Tab is
Omarchy's "next workspace" by default, so unbind it first:

```lua
hl.unbind("SUPER + TAB")
o.bind("SUPER + TAB", "Window overview", "omarchy-shell shell summon dbarke.overview")
```

Optionally, a three-finger swipe up/down in `~/.config/hypr/input.lua`:

```lua
hl.gesture({ fingers = 3, direction = "up", action = function()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell summon dbarke.overview"))
end })
hl.gesture({ fingers = 3, direction = "down", action = function()
  hl.dispatch(hl.dsp.exec_cmd("omarchy-shell shell hide dbarke.overview"))
end })
```

After installing, restart the shell once so its snapshot service loads.

## License

MIT
