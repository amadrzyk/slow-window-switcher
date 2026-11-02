# Slow Window Switcher

A macOS menu bar app that softens sudden changes in screen brightness.

When you switch from a dark window to a bright one, the screen goes from dark to bright in one frame. Slow Window Switcher catches that jump. It holds the screen at the old brightness, then fades to the new brightness over a few seconds. Your eyes get time to adjust.

## Why

I keep my apps in dark mode, but many web pages and documents are still white. Each switch from a dark window to a white one hits my eyes with a flash of light. macOS makes that change in one frame and has no setting to slow it down. This app makes the change take a few seconds instead.

## Features

- Smooths changes in both directions. A dark screen that goes bright fades up. A bright screen that goes dark fades down.
- Works on each display separately.
- Lets all clicks through. The overlay never blocks the mouse or the keyboard.
- Stays out of screen shares. People who watch your screen see the normal screen.
- Runs from the menu bar, with no Dock icon.
- Starts at login. You can turn this off.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel
- The Screen Recording permission. The app uses it to measure brightness. See [Privacy](#privacy).

## Install

### Download

1. Download `SlowWindowSwitcher-<version>.zip` from the [latest release](https://github.com/amadrzyk/slow-window-switcher/releases/latest).
2. Unzip the file, and move `SlowWindowSwitcher.app` to `/Applications`.
3. Open the app.
4. Give the app the Screen Recording permission. When the app asks, click **Open System Settings**. Turn on **SlowWindowSwitcher** in **Privacy & Security > Screen & System Audio Recording**.
5. Quit the app from the menu bar, then open it again from `/Applications`.

A sun icon appears in the menu bar. The app now smooths brightness changes.

Apple notarizes each release. The first time you open the app, macOS asks you to confirm, then opens it.

### Build from source

You need the Xcode Command Line Tools.

1. Install the Command Line Tools, if you do not have them:

   ```sh
   xcode-select --install
   ```

2. Clone the repository:

   ```sh
   git clone https://github.com/amadrzyk/slow-window-switcher.git
   cd slow-window-switcher
   ```

3. Build and install the app:

   ```sh
   SIGN_IDENTITY=- ./build.sh
   ```

   The script builds `SlowWindowSwitcher.app`, replaces any copy in `/Applications`, and opens the app. To use your own certificate, see [Code signature](#code-signature).

4. Do steps 4 and 5 of [Download](#download).

#### Code signature

`build.sh` signs the app with the author's Developer ID by default. You do not have that certificate, so set `SIGN_IDENTITY`:

| Value | Result |
| --- | --- |
| `-` | An ad-hoc signature. You do not need a certificate. macOS can ask for the Screen Recording permission again after each rebuild. |
| Your own identity, for example `"Apple Development: Jane Doe (ABCDE12345)"` | A stable signature. The permission stays after a rebuild. |

An Apple Development certificate from a free Apple account works. To list the signing identities on your Mac, run:

```sh
security find-identity -v -p codesigning
```

## Use

Click the sun icon in the menu bar to open the menu.

| Item | Function |
| --- | --- |
| Status line | Shows the number of displays that the app smooths, or shows a problem. |
| **Enabled** | Turns the smoothing on or off. |
| **Fade Duration** | Sets the time a fade takes to get 95% of the way to the new brightness: 0.5, 1, 1.5, 2, 3, 5, 7, or 10 seconds. The default is 3 seconds. |
| **Start at Login** | Opens the app when you log in. This is on by default. |
| **Quit** | Closes the app. |

The app keeps your settings after a restart.

The app checks its state once a minute. If the Screen Recording permission or the login item turns off, the app tells you.

## How it works

1. **Measure.** For each display, the app uses ScreenCaptureKit to capture a small image, 128 pixels wide, at the refresh rate of the display. It calculates the mean light output (linear luminance) of that image. The capture does not include the app's own overlay.
2. **Follow.** The app keeps a second value: the brightness that you see. A critically damped spring moves that value toward the measured brightness. The spring eases in and out, and it does not overshoot. The app uses a log scale, because the eye responds to ratios of light, not to differences.
3. **Cover.** A full-screen, click-through window sits above all other windows. When the screen gets brighter, the window shows black at partial opacity, so the screen stays at the old level. When the screen gets darker, the window shows white at partial opacity. The overlay then fades to clear as the spring catches up.

When the two values match, the app stops the animation until the next change. When you connect or disconnect a display, the app starts its measurements again.

## Privacy

The Screen Recording permission lets an app see everything on your screen. This is what Slow Window Switcher does with it:

- The app captures a 128-pixel-wide image of each display. It reduces each image to one number: the mean brightness.
- The app does not save the images. It does not send data anywhere. The app has no network code.
- All of the app code is in one file, [`main.swift`](main.swift). You can read all of it.

## Limits

- The app sees a new frame only after macOS shows it. The first one or two frames of a jump appear at full brightness, before the overlay covers them.
- The app measures the mean brightness of the whole display. A small bright window on a dark screen causes only a small change.
- The app reacts to all changes on the screen, not only to window switches. Video scene cuts and page loads also fade. To stop this, turn off **Enabled**.
- When the screen gets darker, the white overlay lowers the contrast for a short time.
- The overlay changes the pixels on the screen. It does not change the backlight of the display.

## Uninstall

1. Open the menu and turn off **Start at Login**.
2. Click **Quit**.
3. Delete the app, its settings, and its permission:

   ```sh
   rm -rf /Applications/SlowWindowSwitcher.app
   defaults delete local.slow-window-switcher
   tccutil reset ScreenCapture local.slow-window-switcher
   ```

## Development

The project has four files and no Xcode project:

| File | Contents |
| --- | --- |
| `main.swift` | All of the app code. `DisplaySmoother` measures one display and controls its overlay. `AppController` owns the menu, the permission checks, and the login item. |
| `Info.plist` | The bundle settings. `LSUIElement` hides the Dock icon. |
| `build.sh` | Compiles, signs, installs, and restarts the app. |
| `release.sh` | Builds a universal app, notarizes it, and publishes it as a GitHub release. |

After you change the code, run `./build.sh` again. The script stops the running copy and opens the new one.

To publish a release:

1. Set `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Commit and push the change.
3. Run the release script with your notarytool keychain profile:

   ```sh
   NOTARY_PROFILE=<profile> ./release.sh
   ```

The script needs a Developer ID certificate and the `gh` CLI. To make a notarytool profile, run `xcrun notarytool store-credentials <profile>` one time.

## License

MIT. See [LICENSE](LICENSE).
