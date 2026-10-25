# Disable the pointer on the LG Magic Remote

Keep the Magic Remote's physical buttons while suppressing pointer movement
and scroll-wheel input on a rooted LG webOS TV. The native implementation uses
a small C hook injected into `lginput2`; it does not replace firmware files or
restart the input service.

The native hook passed isolated ARM/Thumb injection and rollback tests on a
2019 C9 with glibc 2.24. A live timed trial was confirmed by the owner: normal
remote operation with no pointer. See [NATIVE.md](NATIVE.md) for validation
details, source dependencies, and remaining test coverage.

## Why?

I built this because I hated the pointer showing up unexpectedly (like when sitting on the couch and the remote moves), which then triggered some player UI or TV menu. I've tried different solutions to disable the pointer but nothing was robust enough or as seamless as I wanted. I was using a dumb IR universal remote that worked great, but I still preferred the design and feel of the Magic Remote.

## How it works

`ezinject` loads `libmagicpointer.so` into the running input service. Frida Gum
is linked into the native library.

- Position and wheel emission are suppressed.
- Cursor-on custom events become cursor-off events.
- Pairing, disconnection, cursor-off, and other custom events pass through.
- The button emission function remains untouched.

The library lives in writable `/home/root/magic-pointer-native/`. A Homebrew
boot hook starts one watcher, which injects into each new `lginput2` process
and verifies an explicit readiness marker. The watcher refuses existing
hooks, stopped/traced processes, and repeated attempts after failed injection, including watcher restarts.
Failed targets are skipped while the watcher waits for a fresh process.
A restarted watcher adopts an already-ready native hook without reinjection.
An exclusive lock prevents multiple watchers from racing.

The patches exist only in process memory. A reboot removes them; the boot
hook reapplies them. The pointer can appear briefly before injection completes.
Homebrew root access must remain enabled.

## Build and install

Requirements: rooted TV with root SSH/key authentication and Homebrew startup
support; `flock`, `sha256sum`, and BusyBox's `timeout -t` on the TV. The verified
target is 32-bit ARM EABI5 soft-float even though its kernel is aarch64.

The automatic build setup supports Apple Silicon macOS with CMake, Git, curl,
pkg-config, Python 3, and a C compiler. Downloads and binaries stay in the
ignored `.build/` directory. Other build hosts require an appropriate SDK.

```sh
git clone https://github.com/bciuca/disable-lg-magic-remote.git
cd disable-lg-magic-remote
./test-native.sh
./build-native.sh
./stage-native.sh root@YOUR_TV_IP
```

For a new TV/firmware, follow the isolated tests and compatibility checks in
[NATIVE.md](NATIVE.md) before injecting into its real input service.

After validating the candidate:

```sh
./deploy.sh root@YOUR_TV_IP
ssh root@YOUR_TV_IP reboot
```

Deployment verifies uploaded checksums and installs native autostart.
It schedules activation for
the next reboot; it does not restart the TV or inject into the current process.
The native module receives duration `0` at boot, so it stays active for the
process lifetime. Timed restoration applies only to explicitly timed trials.

```text
/home/root/magic-pointer-native/
  candidate-<manifest hash>/     # immutable injector, module, test programs
  active                        # selected candidate path
  watch-native.sh
  restore-native.sh
/var/lib/webosbrew/init.d/disable-magic-pointer-native
```

## Status and rollback

```sh
ssh root@YOUR_TV_IP 'P=$(pidof lginput2); cat /tmp/magic-pointer-native-$P/status; cat /tmp/magic-pointer-native-watch.log'
```

`ready` means all native replacements installed. It does not replace a check
with the physical remote. Detailed injection logs are in
`/tmp/magic-pointer-native-module.log` and
`/tmp/magic-pointer-native-injector.log`.

Restore normal pointer behavior and disable native autostart without rebooting:

```sh
ssh root@YOUR_TV_IP 'sh /home/root/magic-pointer-native/restore-native.sh'
```

The library remains mapped until process exit to protect in-flight callbacks.
Re-enabling requires deployment followed by a fresh process/reboot.
