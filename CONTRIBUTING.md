# Contributing to Vesalius

Thanks for helping. Small, focused pull requests are easiest to review. If you are unsure where to start, look for issues labeled `good first issue`.

## Build and test

You need a Mac with Apple silicon on macOS 15 or later, and Xcode 26.

```bash
(cd VesaliusKit && swift test)
xcodebuild test -project Vesalius.xcodeproj -scheme Vesalius -destination 'platform=macOS'
(cd vscode-extension && npm ci && npm test)
```

To build and install the command line tool from source:

```bash
scripts/install-cli.sh
```

Run the tests for the part you changed before opening a pull request. The UI tests need automation mode enabled once: `sudo automationmodetool enable-automationmode-without-authentication`.

## Opening a pull request

1. Fork the repository and create a branch for your change.
2. Keep the change focused on one thing, and add or update tests where the change needs them.
3. Run the tests above and note the result in the pull request description.
4. Open the pull request against `main`, describe what changed and why, and link any related issue.

## Code style

Match the style of the file you are changing, and add doc comments for new public API, as the surrounding code does.
