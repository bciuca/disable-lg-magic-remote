# Disable the pointer on the LG Magic Remote

This script disables the pointer on LG Magic Remotes on rooted webOS LG TVs at boot time.

Use at your own risk. There's no firmware modification on the TV and it is completely reversible so it _should_ be safe. The script injects a native C hook into a running system process to suppress pointer movement and scroll-wheel input at boot time. I tested this on my TV (2019 C9 OLED) and am mostly satisfied with it (see [known issues](#known-issues)).


## Why?

I built this because I hated the pointer showing up unexpectedly (like when sitting on the couch and the remote moves), which then triggered some player UI or TV menu. I've tried different solutions to disable the pointer but nothing was robust enough or as seamless as I wanted. I was using a dumb IR universal remote that worked great, but I still preferred the design and feel of the Magic Remote.

## How it works

At the service layer `lginput2` (`com.webos.service.mrcu` on the [Luna service URI](https://webostv.developer.lge.com/develop/references/magic-remote)) exposes the emit paths of the magic remote as
separate functions:

- `lginput_uinput_send_position` — cursor X/Y
- `lginput_uinput_send_wheel` — scroll
- `lginput_uinput_send_custom_event` — the LG cursor on/off keys
- `lginput_uinput_send_button` — the real buttons

Inject a hook (via [`ezinject`](https://github.com/smx-smx/ezinject)) into the running `lginput2` that turns position and wheel emission into no-ops and leaves `send_button` alone. Cursor-on custom events become cursor-off events; pairing, disconnection, and other custom events pass through. Injection uses [ptrace](https://man7.org/linux/man-pages/man2/ptrace.2.html) to load `libmagicpointer.so`, a small C hook with [Frida Gum](https://github.com/frida/frida-gum) linked into it.


At boot time, `/var/lib/webosbrew/init.d/disable-magic-pointer-native` launches `watch-native.sh`, which waits
for `lginput2`, injects the hook as soon as it appears, and injects into the fresh process if `lginput2` ever
respawns. The cursor can become active before injection happens if triggered by shaking the remote or pressing the Home button.

An exclusive lock prevents multiple watchers from running. Injection attempts are recorded by PID and start time,
so restarting the watcher cannot retry a failed injection in the same process. The watcher keeps waiting for a fresh
process after a failure and can adopt an already-ready native hook without reinjecting. Boot injection stays active
for the process lifetime.

## Requirements

- A rooted ([webOS Homebrew](https://www.webosbrew.org/rooting/)) LG TV with root SSH enabled.
- Homebrew startup support, `flock`, `sha256sum`, and BusyBox's `timeout -t` on the TV.
- Build environment: Apple Silicon macOS with CMake, Git, curl, pkg-config, Python 3, and a C compiler. Other hosts require a compatible webOS SDK.
- The native binaries target 32-bit ARM EABI5 soft-float, glibc. The tested TV is a 2019 C9 with glibc 2.24.

## Install

```bash
git clone git@github.com:bciuca/disable-lg-magic-remote.git
cd disable-lg-magic-remote
./test-native.sh
./build-native.sh
./stage-native.sh root@YOUR_TV_IP
```

Before deploying to a new TV/firmware, follow the isolated tests and compatibility checks in [NATIVE.md](NATIVE.md).
After validating the candidate:

```bash
./deploy.sh root@YOUR_TV_IP
ssh root@YOUR_TV_IP reboot
```

### What deploy.sh does

- pushes the native injector, library, and test programs into a candidate directory
- verifies uploaded checksums
- installs the watcher and restoration script
- installs the boot hook for activation on the next reboot

This is the on-TV layout `deploy.sh` creates:

```
/home/root/magic-pointer-native/
  candidate-<manifest hash>/                    # injector, native library, test programs
  active                                       # selected candidate path
  watch-native.sh                              <- tv/watch-native.sh
  restore-native.sh                            <- tv/restore-native.sh
/var/lib/webosbrew/init.d/disable-magic-pointer-native <- tv/boot-native.sh
```

## Uninstall

Uninstalling disables the boot hook and watcher and restores normal pointer behavior without rebooting.

```bash
ssh root@YOUR_TV_IP 'sh /home/root/magic-pointer-native/restore-native.sh'

# optional, remove the files after restoration succeeds
ssh root@YOUR_TV_IP 'rm -rf /home/root/magic-pointer-native'
```

The library stays mapped until the input process exits. Re-enabling requires deployment followed by a reboot.

## Known issues

- Sometimes root access is reset and the boot hook will not work
  - **Fix:** Open webOS Homebrew Channel app and go into settings and make sure root is on,
    then reboot the TV.

- The magic remote buttons may become unresponsive, except for the power button. Latest fix should address but has not been 100% confirmed yet.
  - **Fix:** Power cycle the remote by pulling out a battery for a few seconds and reinserting.

- If the pointer comes on right before the hook, it can remain visible until a cursor-off event or the TV's timeout clears it.
  The hook does not immediately clear a pointer that was already visible when it loaded.
  - **Workaround:** Wait for it to disappear; the timeout with the native hook still needs physical testing.
