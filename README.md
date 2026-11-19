# Tattle

A small Mac menu bar app that tells you, in plain English, what is running on your Mac that you can't see.

Click the eye icon in the menu bar and Tattle shows:

- **Apps running out of sight.** Things with no window and no Dock icon, and apps still running after you closed their window, with how much processor, memory and network each is using. Every app's helper processes are grouped under the app they belong to.
- **Microphone and camera.** Which app has the microphone open right now, and whether the camera is on.
- **Worth a look.** Anything working hard, sending a lot of data, or using the microphone while it has no window open, with the reason in a sentence.
- **Permissions.** Which apps you have allowed to read all your files, record your screen, watch your keyboard, or control your Mac.
- **Things set to start by themselves.** Updaters and helpers that launch at login or boot.
- **Shortcut clashes.** Keyboard shortcuts claimed by more than one app, plus a "press a key and see who reacts" test.
- **Activity.** A running list of apps that came to the front or launched, and whether anything you did explains it.

Tattle only watches and reports. The one thing it can do is quit an app when you press Quit. It never connects to the internet, and everything it records stays on your Mac in `~/Library/Application Support/Tattle`.

## Installing

1. Download the latest `Tattle-x.y.dmg` from the [Releases page](https://github.com/eliskia/tattle/releases), open it, and drag **Tattle** onto the **Applications** folder.
2. Open Tattle from Applications.

### macOS will warn you the first time

Tattle is not signed with a paid Apple developer account, so macOS will say it "could not verify" the app and refuse to open it. To allow it:

1. Try to open Tattle once and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the message about Tattle.
3. Confirm with your password or Touch ID.

You only need to do this once. Only do it if you trust whoever gave you the app, or have read the source code here.

### Two permissions

Tattle works without any permissions, but it sees much more with two. Its dropdown shows a blue card with an **Open** button for each:

- **Full Disk Access** lets Tattle read which powerful permissions other apps hold, and their saved keyboard shortcuts.
- **Accessibility** lets Tattle read menu shortcuts, spot menu bar icons, and notice shortcut presses (it looks only at fn, Caps Lock and shortcut combinations, never ordinary typing).

These are broad permissions. Tattle uses them only for the things listed above, and the source is here so you can check.

To keep Tattle watching after a restart, turn on **Start Tattle when I log in** under the gear icon.

## What it can't do

- It cannot see **what** an app sent over the network, only how much.
- It cannot see every file an app reads. It can only spot-check files an app has open at that moment.
- It can tell the camera is on, but macOS does not say which app turned it on.
- On macOS 27, microphone, camera and folder permissions are not readable; only the powerful permissions are.
- macOS keeps no master list of global keyboard shortcuts, so the shortcut list is best effort.
- It uses a few undocumented parts of macOS to work out which apps really have a window open. A future macOS update could break that.

## Compatibility

Needs macOS 14 or later. Developed and tested on one Apple Silicon Mac running macOS 27. The app includes an Intel build, but it has not been tested on an Intel Mac or on older macOS versions.

## Building it yourself

You need Xcode (or its command line tools).

```bash
./scripts/build.sh            # builds build/Tattle.app
./scripts/build.sh install    # also copies it to /Applications and starts it
./scripts/package.sh          # builds a .dmg for sharing
```

macOS ties the two permissions to the app's signature. With a plain local build the signature changes every time you rebuild, and the permissions silently stop working even though the switches still look on. To avoid that, create a code-signing certificate named **Tattle Local Signing** (Keychain Access → Certificate Assistant → Create a Certificate…, type "Code Signing"). The build script uses it automatically when it exists.

If permissions ever get stuck, clear them and switch them on again:

```bash
tccutil reset All local.tattle.app
```

## A regular review (optional)

`Tattle --report 7` prints a plain-text summary of the last 7 days: what used the most processor and network while hidden, microphone use, what was flagged, and what changed.

```bash
/Applications/Tattle.app/Contents/MacOS/Tattle --report 7
```

If you use an AI assistant that can run commands on a schedule, you can have it run that once a week and tell you what, if anything, looks fishy.

## Removing it

Quit Tattle from its gear menu, drag it from Applications to the Trash, and delete `~/Library/Application Support/Tattle`.
