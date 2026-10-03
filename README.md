# Screen Recorder

A small menu bar app for your Mac that records your whole screen **and the sound your Mac is playing**, then saves the video to your Movies folder.

1. Click the ⏺ icon in the menu bar and choose **Start Recording**.
2. While it records, the icon turns into a red ⏹ with a timer. Click it to **stop**.
3. The video is saved in **Movies → Screen Recordings**, and Finder opens to it.

It records whatever you'd hear: videos, music, people on a call. Your microphone is **not** recorded. Recordings are regular `.mp4` files that play almost anywhere, at full resolution and 30 frames per second. They take up to about 4 GB per hour, and much less when the screen is mostly still.

## Install

You need macOS 13 Ventura or newer.

1. Open **Terminal** (press ⌘ Space, type `Terminal`, press Return) and paste:

   ```sh
   git clone https://github.com/FayzaanS/ScreenRecorder.git
   cd ScreenRecorder
   ./build.sh
   ```

   If macOS offers to install the "command line developer tools", click **Install**, wait for it to finish, and paste the commands again.

2. The script builds the app, puts it in your Applications folder and opens it. The ⏺ icon appears near the right end of the menu bar.

3. The first time, macOS asks for permission to record the screen. Click **Open System Settings**, turn on **Screen Recorder**, then click **Quit & Reopen**.

## Good to know

- **Which screen:** with more than one display, it records the screen whose menu bar you clicked.
- **Can't see the icon?** On MacBooks with a notch, a crowded menu bar can hide it. Open Screen Recorder again (⌘ Space, type `Screen Recorder`). That does the same as clicking the icon: it shows the menu, or stops a recording in progress.
- **Monthly check:** macOS 15 and newer occasionally ask you to confirm that Screen Recorder may keep recording your screen. Click **Allow**.
- **Start it at login:** System Settings → General → Login Items → click **+** and pick Screen Recorder.
- **Rebuilt the app and recording no longer works?** macOS ties the permission to the exact build. In System Settings → Privacy & Security → Screen & System Audio Recording (just "Screen Recording" on macOS 13 and 14), select Screen Recorder, remove it with **–**, then open the app again and allow it.
- **Uninstall:** choose **Quit Screen Recorder** from its menu, then drag Screen Recorder from Applications to the Trash.

## How it works

- `Sources/Recorder.swift` captures the screen and system audio with Apple's ScreenCaptureKit and writes H.264 video + AAC audio with AVFoundation. To change the frame rate or video quality, edit `frameRate` or `AVVideoAverageBitRateKey` there and run `./build.sh` again.
- `Sources/App.swift` is the menu bar icon and menu.
- `build.sh` compiles both files with `swiftc` into `Screen Recorder.app`. No Xcode project or third-party code is needed.
- On every push, GitHub Actions builds the app and records a short test clip (`Tests/SmokeTest.swift`) to check the file comes out right.
