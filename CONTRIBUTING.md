# Contributing

Thank you for wanting to make OpenClipboard better.

## Reporting a problem

Open an [issue](https://github.com/burakgon/openclipboard-mac/issues/new/choose) and say what you
did, what you expected and what happened. The version of OpenClipboard (Settings → About) and of
macOS, and the app you were copying from or pasting into, usually decide how quickly it can be
found. A screenshot or a short recording is worth a paragraph.

Please do not paste the content of your clipboard history into an issue if it is private.

## Building

You need Xcode 27 or later. Open `OpenClipboard.xcodeproj` and run, or:

```sh
xcodebuild -project OpenClipboard.xcodeproj -scheme OpenClipboard -derivedDataPath build/DerivedData build
swift test --package-path Packages/OpenClipboardKit
```

The app is signed ad hoc unless you create `Config/Local.xcconfig` with your own signing identity;
`Config/Base.xcconfig` explains how. With your own identity, macOS remembers the Accessibility
permission across rebuilds.

Start the app with `--demo` to work on the interface with sample clips, away from your real
history and pasteboard. `OpenClipboard/Support/Demo.swift` lists the arguments that stage a scene.

A build of your own has the bundle identifier of the released app, and so it runs on the settings
and the history of an OpenClipboard you have installed. To keep the two apart, also set
`PRODUCT_BUNDLE_IDENTIFIER` in `Config/Local.xcconfig`: the build then has settings of its own
and keeps its history in a folder named after its identifier.

`scripts/test-update.sh` tries out updating without publishing anything. It makes a throwaway
copy of the built app with an update feed of its own on your Mac, opens it, and says what to
look for, from the moment the copy finds its update to the moment it runs the new version.

## Where things are

- `Packages/OpenClipboardKit` is everything that is not user interface: watching and reading the
  pasteboard, deciding what a clip is, the SQLite history, writing a clip back. It has the tests.
- `OpenClipboard` is the app: the shelf, the settings, the welcome window, the global shortcut.

Logic that can be tested belongs in the kit, with a test.

## Changes

- Keep a change about one thing, and say in the commit message what it does and why.
- Match the code around you: plain Swift, no new dependencies without a very good reason, and
  comments that explain why something is the way it is rather than what the next line does.
- The app has to stay light. If a change makes it use the processor while idle, or keep
  noticeably more memory, that needs a reason.
- Run `swift test --package-path Packages/OpenClipboardKit` before you open a pull request.
- Interface changes are easiest to review with a before and after screenshot.

## Releasing

For maintainers: set the version in `Config/Version.xcconfig`, add a section for it to
`CHANGELOG.md`, commit, push, and run `scripts/release.sh --publish`. The header of that script
describes the credentials it uses. Pushing a `v1.2.3` tag instead lets the Release workflow do the
same on GitHub, once `scripts/add-release-secrets.sh` has stored its secrets.

If a change touches updating, run `scripts/test-update.sh` before releasing it, with and without
`--ask`.
