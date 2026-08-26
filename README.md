# FixSthenoUIWindows

RootHide Theos package project for the Stheno / SquidExtender window investigation.

## Important status

Version `0.0.3` contains the previously prepared **read-only runtime diagnostic
probe**. It is not yet a device-validated UI behavior fix. The source deliberately
observes window, Scene, clipping, host-view and touch-routing state without changing
`windowLevel`, frames, bounds, Scene ownership, layer order, key-window state or hit
results. A successful GitHub Actions build proves compilation and package structure;
it does not prove that the Stheno menu is fixed on the iPhone.

## Package metadata

```text
Name:        FixSthenoUIWindows
Package:     com.tsangbaby.fixsthenouiwindows
Version:     0.0.1
Maintainer:  Tsangbaby
Description: Fix-Stheno-UIWindows
Scheme:      RootHide
```

## Injection boundary

The filter is intentionally limited to:

- `com.apple.springboard`
- `com.apple.UIKit`

No ordinary third-party app is included in the filter.

## Diagnostic output

When loaded on the target device, the probe writes bounded, privacy-safe files:

```text
/var/mobile/Documents/SthenoSquidExtenderWindowDiagnostic-SpringBoard.plist
/var/mobile/Documents/SthenoSquidExtenderWindowDiagnostic-UIKit.plist
```

The files contain fixed phase names, class names, geometry and state flags only.
They do not collect text, clipboard data, URLs, account identifiers, passwords,
request identifiers or credentials.

## GitHub Actions build

The workflow is:

```text
.github/workflows/build-roothide.yml
```

It runs on GitHub-hosted `macos-14`, installs `roothide/theos` and its SDK, builds
with `THEOS_PACKAGE_SCHEME=roothide`, checks the Debian metadata and package paths,
and uploads:

```text
FixSthenoUIWindows-roothide.deb
SOURCE_COMMIT.txt
SHA256SUMS.txt
```

The source commit is recorded next to the artifact so the package can be tied to the
exact GitHub Actions run. CI/package success remains separate from real-device
acceptance.

## Local project layout

```text
Makefile
control
FixSthenoUIWindows.m
FixSthenoUIWindows.plist
README.md
.github/workflows/build-roothide.yml
```

The current Linux host does not have Apple Xcode, Apple SDKs or Theos; the intended
build path is the GitHub-hosted macOS workflow.
