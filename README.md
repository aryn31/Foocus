# ScreenFocus

A tiny macOS menu-bar app: **when your mouse moves onto another display, the frontmost window on that display gets focus automatically.** No more clicking a window just to start typing on the other screen.

- Focuses the exact topmost window on the screen you move into, not just its app (two Chrome windows on two screens work correctly)
- Only reacts when the cursor *crosses* displays; moving around within one screen never changes focus
- Ignores drags, so moving a window between screens behaves normally
- Menu bar toggles for **Enabled** and **Launch at Login**
- No Dock icon, no dependencies, one Swift file

## Requirements

- macOS 13 (Ventura) or later
- Xcode Command Line Tools: `xcode-select --install`

## Build & install

```bash
git clone https://github.com/<your-username>/ScreenFocus.git
cd ScreenFocus
./build.sh
mv ScreenFocus.app /Applications/
open /Applications/ScreenFocus.app
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). Enable ScreenFocus, then quit and reopen it. The permission is needed to raise other apps' windows.

> **Rebuilding:** the app is ad-hoc signed, so each rebuild looks like a new app to macOS. After rebuilding, remove the old ScreenFocus entry from the Accessibility list (− button) and approve the new one.

## How it works

1. A lightweight timer checks which display the cursor is on (20×/sec), with App Nap disabled so it keeps running in the background.
2. When the display under the cursor changes, `CGWindowListCopyWindowInfo` (front-to-back order) finds the topmost normal window whose centre lies on that display.
3. The Accessibility API matches that window by position and size, marks it main, raises it, and makes its app frontmost.

## Alternative: Hammerspoon script

If you already use [Hammerspoon](https://www.hammerspoon.org/), [`extras/hammerspoon/focus_follows_screen.lua`](extras/hammerspoon/focus_follows_screen.lua) does the same thing. Copy it to `~/.hammerspoon/`, add `FFS = require("focus_follows_screen")` to `init.lua`, and reload. Toggle with Ctrl+Alt+Cmd+F.

## License

[MIT](LICENSE)