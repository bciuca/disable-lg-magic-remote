# Disable the pointer on the LG Magic Remote

_Note:_ Latest update removes PHP dependency and replaces it with a native C hook instead in an attempt to fix the seemingly random magic remote disconnects.

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

The module resolves all three symbols before patching and rolls back a partial installation if a replacement fails.
Custom event ID 4 becomes ID 5 while preserving the original handle and reason. These are function-level IDs,
corresponding to evdev codes `0x4ae` and `0x4af` on the tested C9.

## Requirements

- A rooted ([webOS Homebrew](https://www.webosbrew.org/rooting/)) LG TV with root SSH enabled.
- Build environment: CMake, Git, curl, pkg-config, Python 3, and a C compiler. Other hosts require a compatible webOS SDK.
- The native binaries target 32-bit ARM EABI5 soft-float, glibc. The tested TV is a 2019 C9 with glibc 2.24.

## Install

```bash
git clone git@github.com:bciuca/disable-lg-magic-remote.git
cd disable-lg-magic-remote
./test-native.sh
./build-native.sh
./stage-native.sh root@YOUR_TV_IP
```

Before deploying to a new TV/firmware, follow the [compatibility checks and testing steps](#compatibility-and-testing) below.
After validating the candidate:

```bash
./deploy.sh root@YOUR_TV_IP
ssh root@YOUR_TV_IP reboot
```

### Build output

The build downloads checksum-pinned SDKs and builds ezinject and its module runtime from the same pinned revision.
Downloads, SDKs, and generated binaries stay in the ignored `.build/` directory. Other build hosts can pass a
compatible extracted webOS SDK as the first argument to `build-native.sh`; those hosts have not been tested.

`.build/dist/` contains:

- `ezinject`: the ARM injector
- `libmagicpointer.so`: the native hook with Frida Gum and its support libraries linked in
- `pointer-fixture` and `pointer-fixture-thumb`: isolated ARM and Thumb test programs
- `SHA256SUMS`: checksums for the four binaries

### Compatibility and testing

1. Tested on a 2019 C9 running webOS 4.10.2-31 with glibc 2.24. 
2. Stage the build using `./stage-native.sh root@YOUR_TV_IP`. This uploads the candidate without injecting or enabling autostart.
3. On the TV, run both fixture binaries with the absolute path to `libmagicpointer.so` as their argument.
   They check actual function replacement, event forwarding, button calls, and restoration in isolated processes.
4. Test injection separately: start `pointer-fixture --serve`, then use its printed PID with the candidate's injector
   and a 10-second duration. Repeat with `pointer-fixture-thumb --serve`:

   ```bash
   /path/to/ezinject -l /tmp/magic-pointer-native-test.log PID /path/to/libmagicpointer.so 10
   ```

5. Before a live trial, disable autostart with `sh /home/root/magic-pointer-native/restore-native.sh`, then reboot the TV. This 
   starts a fresh `lginput2` process without loading the hook. After reconnecting over SSH, run pidof `lginput2` to get the PID 
   for the trial command. To end a trial early, run `touch /tmp/magic-pointer-native-PID/restore` on the TV and check that 
   its status becomes `restored`.
6. Reboot between trials and restoration for a clean run. After successful validation, deploy with:

   ```bash
   ./deploy.sh root@YOUR_TV_IP
   ssh root@YOUR_TV_IP reboot
   ```


### Deployment details

- Pushes the native injector, library, and test programs into a candidate directory
- Verifies uploaded checksums
- Installs the watcher and restoration script
- Installs the boot hook for activation on the next reboot

This is the on-TV layout `deploy.sh` creates:

```
/home/root/magic-pointer-native/
  candidate-<manifest hash>/                    # injector, native library, test programs
  active                                       # selected candidate path
  watch-native.sh                              <- tv/watch-native.sh
  restore-native.sh                            <- tv/restore-native.sh
/var/lib/webosbrew/init.d/disable-magic-pointer-native <- tv/boot-native.sh
```

### Check status

```bash
ssh root@YOUR_TV_IP 'P=$(pidof lginput2); cat /tmp/magic-pointer-native-$P/status; cat /tmp/magic-pointer-native-watch.log'
```

The module status is `ready`, `failed`, or `restored`. `ready` confirms installation of all replacements;
check the physical remote as well. Injection logs are in `/tmp/magic-pointer-native-module.log` and
`/tmp/magic-pointer-native-injector.log` on the TV.

## Uninstall

Uninstalling disables the boot hook and watcher and restores normal pointer behavior without rebooting.

```bash
ssh root@YOUR_TV_IP 'sh /home/root/magic-pointer-native/restore-native.sh'

# optional, remove the files after restoration succeeds
ssh root@YOUR_TV_IP 'rm -rf /home/root/magic-pointer-native'
```

The library stays mapped until the input process exits. Re-enabling requires deployment followed by a reboot.

## Known issues

- Sometimes root access is reset and the boot hook will not work.
  - **Fix:** Open webOS Homebrew Channel app and go into settings and make sure root is on,
    then reboot the TV.

- The magic remote buttons may become unresponsive, except for the power button. Latest fix 
  should address this issue but leaving this comment here until confirmed.
  - **Fix:** Power cycle the remote by pulling out a battery briefly and reinserting.

- If the pointer comes on right before the hook, it may remain visible until a cursor-off 
  event or the TV's timeout clears it.
  - **Workaround:** Wait for it to disappear; the timeout with the native hook still needs physical testing.

## Dependencies and attribution

- [ezinject](https://github.com/smx-smx/ezinject), revision `d9338952cd01597c5fdd7d6e98991474df5dc89c`: injector and matching module runtime.
- [Frida Gum](https://github.com/frida/frida-gum): native interception engine, supplied by [openlgtv's 2026.08-webos SDK](https://github.com/openlgtv/buildroot-nc4/releases/tag/2026.08-webos).
- [webOS native toolchain](https://github.com/webosbrew/native-toolchain/releases/tag/webos-d7ed7ee.6): macOS ARM cross compiler and base sysroot.
- [inputhookpp's build recipe](https://github.com/sundermann/inputhookpp/blob/main/.github/workflows/build.yml): dependency SDK selection and checksum.
- [Fenrir200678's pointer hook](https://github.com/Fenrir200678/disable-lg-magic-remote): reference for selective cursor-event handling and function signatures.

## License

[MIT](LICENSE) Copyright (c) 2026, BC (https://github.com/bciuca).
