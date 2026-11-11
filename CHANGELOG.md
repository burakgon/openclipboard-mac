# Changelog

Notable changes to OpenClipboard, newest first. Versions follow [semantic versioning](https://semver.org).

## 1.0.5

- **Updates install themselves.** A new version is now downloaded in the background and installed the next time OpenClipboard quits. Until then the shelf shows a "Restart to Update" button, the menu bar icon carries a dot and the settings say that an update is ready: one click restarts the app into the new version, in about a second, with your history as it was. To be asked first, as before, turn off "Download and install them automatically" in Settings → About; the shelf then shows "Update Available" when there is one.
- **The "Allow Pasting…" button is readable.** Its white text on orange was hard to make out, and on the glass of the shelf the orange took on the colors behind it. Warnings now have dark text on a color of their own, and "Paused" is written in the color of the shelf's other text.
- Text on the accent color, such as the quick paste numbers, turns dark when the accent color chosen in System Settings is a light one: yellow, orange or green.
- A copy of the app built with a bundle identifier of its own keeps its history in a folder of its own, apart from the one of the released app.

## 1.0.4

- **The shelf stays where you scroll it.** After scrolling with the trackpad or the mouse wheel, the row slid back to the selected clip as soon as it came to rest. Now nothing moves it until you choose a clip.
- After scrolling by hand, the arrow keys continue from the clips on screen instead of jumping back to the selected one.
- The shelf always opens at the newest clip, also when it was closed while scrolled somewhere else.

## 1.0.3

- **Formatted text from an app in dark mode is readable in the preview.** Such text is copied with its color, white, and was shown on a white page: only an emoji gave away that anything was there. The page now follows the text: light text gets a dark page, dark text a white one, and text that names no color is shown in the system's color.

## 1.0.2

- **Choosing a clip no longer copies it without a word when it was meant to be pasted.** Until macOS has been allowed to let OpenClipboard paste, the shelf now asks the moment you choose a clip: allow pasting, or keep to copying. Before, it copied and showed a small note, which looked as if double-clicking and Return did nothing.
- The shelf shows an orange "Allow Pasting…" button for as long as the permission is missing, and tells you when it has arrived.
- In the welcome window, going on without the permission is now a deliberate "Skip for Now", not what the Return key does.
- A clip chosen while one of OpenClipboard's own windows is in front is pasted into the app you came from, instead of going nowhere.
- The settings and the welcome window always open in front of other windows.

## 1.0.1

- If macOS is set to keep apps from reading what other apps copy (Privacy & Security → Paste from Other Apps), OpenClipboard now says so and leads to the setting, instead of quietly recording nothing.
- Opening OpenClipboard straight from its disk image now asks you to move it to Applications first, so that it can update itself and open at login.

## 1.0.0

The first release.

- **A shelf for everything you copy.** Press ⇧⌘V in any app and your clipboard history slides up from the bottom of the screen, on Liquid Glass.
- **Previews you can recognize.** Text, code, links, images, files and colors each get a card that shows what they are. Press Space to see one large.
- **Paste with one key.** Arrow to a clip and press Return, or hold ⌘ and press 1 to 9. ⇧Return pastes without formatting.
- **Search by typing.** Just start typing. Search ignores case and accents, and marks what it found.
- **Pin what you keep needing.** Pinned clips stay until you unpin them. Everything else is cleaned up after a month, or the time you choose.
- **Everything is kept as it was copied.** Formatted text, pictures and an app's own formats are stored and pasted back in full.
- **Private.** The history never leaves your Mac. Passwords from password managers are skipped, and you can exclude any app.
- **Light.** About 25 MB of memory, and no measurable CPU while you are not using it.
