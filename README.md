# Luma · A clearer view of home

**English** · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

Luma is a local-network camera viewer for **iOS 26 and later**, with native SwiftUI Liquid Glass controls. It connects directly to Hikvision cameras or recorders using RTSP for video and ISAPI for supported PTZ controls.

The app supports **English, Traditional Chinese and Simplified Chinese**. Its Chinese display name is **流光**. This is an early preview: simulator checks do not establish compatibility with every camera or successful installation on a physical iPhone.

## Features

| Available in this preview | Details |
| --- | --- |
| Live view | Main/sub streams, sound, full screen, fill/fit and bounded reconnect attempts |
| Dashboard | Up to four cameras per page, muted sub streams by default |
| PTZ | Eight directions, zoom and stop; separate control port and channel |
| Local captures | Snapshots and manual recordings, up to five minutes per recording |
| Media library | Preview snapshots, replay local recordings, export and confirm deletion |
| Configuration backup | Import/export JSON without passwords, snapshots or recordings |
| Appearance and language | Light/dark mode, native Liquid Glass and three localizations |

PTZ requires a device and account that support Hikvision timed ISAPI movement. A hold is limited to two seconds; release or press Stop to stop movement. HTTP controls require Digest authentication, and HTTPS uses system certificate validation.

**Not implemented:** automatic discovery, PTZ presets, two-way talk, camera SD-card/NVR recording search and playback, picture in picture, widgets, shortcuts and custom dashboard layouts. Playback in the media library refers to recordings made by Luma.

## Local by design

- No Luma account, cloud sync, remote-access relay, cloud recording or online push service.
- Camera passwords are stored in the device-only Keychain. Camera settings and media directories are excluded from system backups.
- Exported configuration includes device names, addresses and usernames; it excludes passwords and media. Newly imported cameras require passwords to be entered again. Existing camera IDs are preserved.
- Video pauses when the app enters the background. An active recording is stopped and finalized.
- GitHub Actions builds source code. It does not receive camera settings, video, Apple credentials or signing certificates. Runtime viewing does not require a development computer.

## Install on an iPhone

1. Use an iPhone running iOS 26 or later.
2. Obtain `Luma-unsigned.ipa` from a successful **Build Luma for iPhone** Actions run. Extract the downloaded artifact ZIP first.
3. On Windows, connect and unlock the iPhone, trust the computer, then open the IPA in [Sideloadly](https://sideloadly.io/).
4. Sign and install with an Apple account locally. Follow the iPhone's prompts for developer trust and Developer Mode.
5. Open Luma, allow Local Network access, connect to the camera's Wi-Fi network, and enter the device address and credentials in the app.

The IPA is unsigned and is not an App Store package. Free-account installation generally needs renewal after seven days; installation and renewal must be verified on the device. Never place Apple passwords or camera credentials in issues, commits or workflow secrets.

In the camera editor, use the RTSP port (usually 554) for video. Enable PTZ separately with the device's web control port (usually HTTP 80 or HTTPS 443). Start with one sub stream before trying a four-camera dashboard.

## Build and validate

| Component | Version / setting |
| --- | --- |
| Deployment target | iOS 26.0 |
| CI | Standard `macos-15` GitHub runner, Xcode 26.2 |
| Swift | Swift 5 language mode, complete concurrency checking |
| Project generation | XcodeGen 2.46.0 |
| Dependency manager | CocoaPods 1.16.2 |
| Playback | MobileVLCKit 3.7.3, pinned version and archive checksum |
| Bundle identifier | `app.luma.viewer` |

Local resource checks need Python 3:

```sh
python scripts/validate-project.py
```

After forking or cloning to a GitHub repository, a push to `main` triggers CI. GitHub CLI can also start and download a build:

```sh
gh workflow run ios.yml
gh run list --workflow ios.yml --limit 5
gh run download RUN_ID --name Luma-iPhone-unsigned --dir build/download
gh run download RUN_ID --name Luma-test-report --dir build/report
```

Replace `RUN_ID` with the actual run number. Build artifacts expire after **one day**; keep needed downloads locally. Standard runner usage is subject to [GitHub's current Actions billing rules](https://docs.github.com/en/billing/concepts/product-billing/github-actions), especially for private forks.

CI validates metadata and localization, builds the app, runs unit/UI tests and a real VLC integration test using a generated local H.264 clip, then builds an unsigned arm64 iPhone IPA. The integration test captures a snapshot and two consecutive recordings and replays both recordings. A failed test prevents packaging. Test code describes coverage; a particular run's result is the evidence that it passed.

Physical-device validation is still required for camera authentication, codec/audio compatibility, PTZ movement and stopping, network permissions, reconnect behavior, thermal load and sideloading. No live camera footage or credentials are included in this repository.

## Project layout

`Luma/` contains the app, `Tests/` and `UITests/` contain checks, `scripts/` contains the build pipeline, and `design/` contains the app artwork. Xcode projects and dependencies are generated from `project.yml`, `Podfile` and `Podfile.lock`.

See [third-party notices](ThirdPartyNotices.md) for VideoLAN components and artwork provenance. Features were researched using the [IPCams website](https://ipcams.app/), [release notes](https://ipcams.app/changelog/) and [App Store description](https://apps.apple.com/us/app/ip-camera-viewer-ipcams/id1045600272). Luma uses its own name, artwork, interface and implementation.
