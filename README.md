# HiMarkDown

Native macOS SwiftUI app for editing Markdown with an **HTML** (TipTap) mode and a **Markdown** source mode, outline navigation, find/replace, manual save, Save As Markdown/HTML, and Finder document association.

## Requirements

- macOS 13+
- **Xcode** (open `HiMarkDown.xcodeproj` — Command Line Tools alone are not enough to build the app bundle)

## Build the web editor bundle

The TipTap bundle is committed under `HiMarkDown/Web/editor.js`. To rebuild after changing `WebEditor/`:

```bash
cd WebEditor && npm install && npm run build
```

## Run

1. Open `HiMarkDown.xcodeproj` in Xcode.
2. Select the **HiMarkDown** scheme and **Run** (⌘R).

## Tests / fixtures

- Manual fixtures live in [`fixtures/sample.md`](fixtures/sample.md).
- Supported Markdown subset is documented in [`docs/SUPPORTED_MARKDOWN.md`](docs/SUPPORTED_MARKDOWN.md).
- Add XCTest targets in Xcode later if you want CI; this repo ships the app target only.

## Sandboxing

The app uses the App Sandbox with **User Selected File** read/write. Open and Save use the system panels and security-scoped URLs.
# HiMarkDown
