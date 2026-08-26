# FixSthenoUIWindows

RootHide Theos **SpringBoard-only verification candidate** for the Stheno /
SquidExtender hosted-keyboard overlap on iOS 15.4.1.

## Candidate status

Version `0.0.4` is an unreviewed, device-verification candidate. It is not a
production fix and has not been accepted on the iPhone yet.

The candidate tests one narrow mechanism suggested by the runtime and exact
iOS 15.4.1 dyld evidence: a balanced `KeyboardArbiter` host-PID transition on
SpringBoard's own arbiter handle while a visible Stheno card and a keyboard
proxy host coexist in the same foreground Scene.

A successful build proves compilation and package structure only. The handset
must still verify keyboard appearance, menu touch routing, close cleanup, App
switch cleanup, lock cleanup, and ordinary portrait-app keyboard behavior.

## Package metadata

```text
Name:        FixSthenoUIWindows
Package:     com.tsangbaby.fixsthenouiwindows
Version:     0.0.4
Maintainer:  Tsangbaby
Description: Fix-Stheno-UIWindows
Scheme:      RootHide
```

## Injection boundary

The filter contains only:

- `com.apple.springboard`

No UIKit process or ordinary third-party application is injected. The source
does not modify `UIRemoteKeyboardWindow` geometry, window levels, z positions,
clipping, key-window state, or hit testing.

## Runtime gates

The candidate fails closed unless all of the following are true:

- `_UIKeyboardArbiter_ForSpringBoard` and
  `+launchAdvisorWithOmniscientDelegate:` exist with the expected ABI;
- the normal SpringBoard arbiter launch returns an advisor;
- `advisor.owner` and `owner.handlerForPID:` match the expected ABI;
- the returned handle identifies the current SpringBoard process;
- `setWindowHostingPID:active:` matches the expected ABI;
- a visible Stheno card exists in a foreground Scene;
- a visible `SGPanelWindow`/`LecardWindow` in that same Scene contains a
  visible keyboard host view;
- the Stheno Scene exposes a client process with a valid PID different from
  SpringBoard.

The remote PID is registered only after those gates pass. The exact saved
handle/PID pair is deactivated when the card or proxy host disappears, and
cleanup is restored for retry if the private call throws.

## Device acceptance

Install the unique `0.0.4` package, then test only the following bounded matrix:

1. Open Stheno and the SquidExtender keyboard menu; verify the menu is visible
   and its controls receive touches.
2. Close the menu and Stheno; verify no stale keyboard behavior remains.
3. Switch to another App and back; verify ordinary portrait keyboard behavior.
4. Lock/unlock once; verify the candidate does not leave a stale host state.

This is a functional verification step, not a release or review gate. If the
behavior is unchanged, retract this candidate and do not layer another fix on
it without new runtime evidence.

## Build

The workflow is:

```text
.github/workflows/build-roothide.yml
```

It runs on GitHub-hosted `macos-14`, installs `roothide/theos` and an iPhoneOS
SDK, builds with `THEOS_PACKAGE_SCHEME=roothide`, checks the Debian metadata and
SpringBoard-only filter, and uploads:

```text
FixSthenoUIWindows-roothide.deb
SOURCE_COMMIT.txt
SHA256SUMS.txt
```

The current Linux host has no Apple Xcode, Apple SDK, or Theos; GitHub Actions
is the build path.
