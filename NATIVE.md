# Native pointer hook candidate

This implementation passes isolated hook and injection tests on the C9. The
owner confirmed the live native trial works normally with no pointer. The
default `deploy.sh` now installs native boot persistence; `deploy-legacy.sh`
retains the previous PHP installer.

## Build and local tests

On an Apple Silicon Mac with CMake, Git, curl, pkg-config, and a C compiler:

```sh
./test-native.sh
./build-native.sh
```

The build downloads a checksum-pinned macOS webOS SDK and the ARM static
libraries from the community native-input-hook SDK. It builds ezinject and
its module bootstrap from the same pinned source revision. All downloads,
build products, and extracted SDK files stay under ignored `.build/`.
Other hosts can supply a compatible extracted webOS SDK as the first argument
to `build-native.sh`; those hosts have not been tested here.

Output in `.build/dist/`:

- `ezinject`: matching 32-bit ARM injector.
- `libmagicpointer.so`: native C hook with statically linked Frida Gum and its
  support libraries; no PHP, external Frida, libatomic, or libgcc_s dependency.
- `pointer-fixture` and `pointer-fixture-thumb`: isolated ARM and Thumb input
  services for testing actual function replacement and restoration.
- `SHA256SUMS`: checksums for the candidate's four binaries.

The module still dynamically uses the TV's libc, libdl, libpthread, libm,
libresolv, and librt. Its architecture, loader compatibility, and required
symbols must be checked on the target before injection. Local tests cover the
filter and failure handling using a simulated hooking backend; they do not
prove that ARM instruction patching or the TV's remote works.

## Design

The module resolves all three symbols before patching. Frida installs the
replacements in a transaction, checks every return code, and rolls back a
partial installation. It does not hook `lginput_uinput_send_button`.

- Position and wheel events are suppressed.
- Custom event ID 4 becomes ID 5, forwarding the original handle and reason.
- Other custom events, including cursor-off, pass through unchanged.

These function signatures and custom-event IDs follow the community fork's
implementation and were checked against the C9 binary on 2026-10-25.
They are not the `0x4ae`/`0x4af` evdev key codes.

The module creates a private `/tmp/magic-pointer-native-<PID>/` directory.
Its `status` file is `ready`, `failed`, or `restored`. A control thread supports
a timed trial or a `restore` request. Restoration uses Frida to restore native
function entry points, while retaining the module and Gum allocations until
process exit so in-flight callbacks cannot return into unmapped memory.
Loading the module again into the same process is unsupported, even after
restoration. Use a fresh process for another trial.

## On-device validation — 2026-10-25

The TV reports Rockhopper 4.10.2-31 (goldilocks2-grampians), glibc 2.24,
and an aarch64 Linux 4.4.84 kernel. Its `lginput2` is a **32-bit ARM EABI5
soft-float executable**, using Thumb code for the input functions.

Candidate `44f0e90ef4018264` passed all four isolated runs:

- ARM fixture: real Frida hooks, forwarding, buttons, and restoration.
- Thumb fixture: the same checks with Thumb function entry points.
- ARM fixture: actual ezinject injection, readiness, filtering, and 10-second restoration.
- Thumb fixture: the same injection and timed-restoration checks.

Both injector runs exited successfully and left their fixture processes able
to validate restored input and exit normally. The actual `lginput2` process
remained unchanged, sleeping with no tracer attached; its legacy PHP hook was
still loaded. Existing pointer scripts were backed up locally to the ignored
`.build/tv-backup/legacy-pointer.tar`.

Disassembly confirms the three argument layouts used by the native hook. The
custom-event table maps function-level IDs 4 and 5 to evdev codes `0x4ae` and
`0x4af`; the corresponding strings are `CUSTOM_KEY_CURSOR_ON` and
`CUSTOM_KEY_CURSOR_OFF`. The table also includes pairing/disconnection events,
which the new filter forwards instead of discarding.

Inspected `lginput2` SHA-256:
`65d288e1c14698c4e675117864de8ca494c486744a078025e8a0d599771aacc9`.
Native library SHA-256:
`2dbd3e4c10c61edd9e77e3e8f315b9ea342e094a06bfa9002968ab883769d2b7`.

The clean-process trial subsequently ran in the real `lginput2` (PID 2710)
without changing its PID or leaving a tracer attached. The owner reported:
"everything works as expected. no pointer". The legacy boot hook was preserved
outside the startup directory before rebooting into this clean process.

Native autostart was then installed and verified through another TV reboot.
The watcher injected once into the fresh `lginput2` (PID 2692), received `ready`,
and retained its exclusive lock. The process was sleeping normally with
`TracerPid: 0`, and only the native module was mapped (no PHP hook). Starting
a second watcher exited harmlessly without reinjection or changing the log.
Checksums of all three installed shell scripts matched the repository files.
Boot injection passes duration `0`, so there is no trial-expiration timer.

Power-loss cold start, standby/resume, and remote reconnection are not yet
separately verified. Process-respawn supervision is covered by local watcher
tests; the real input service has not been deliberately crashed/restarted.

## TV validation and rollout

1. Inspect the running `lginput2` binary, its exported function signatures,
   glibc version, required libraries, and existing injected libraries.
2. Stage the candidate with `./stage-native.sh root@TV-IP`. This only copies
   files to a directory identified by the candidate's manifest checksum. It
   neither injects nor installs a boot hook.
3. Run both fixture binaries on the TV with the absolute library path as their
   argument. They exercise the real ARM/Thumb hook engine in separate processes,
   preserving event arguments, return values, button calls, and restoration.
4. Test the injector itself against an isolated process before touching
   `lginput2`. The fixture's direct `dlopen` test does not cover ptrace injection.
   Start `pointer-fixture --serve`, use its printed PID as the injection target,
   and pass `10` as the module's trial duration. The fixture checks filtering
   and restored behavior, then exits. Repeat with `pointer-fixture-thumb`.
5. Ensure the old PHP hook and any other input hook are absent from the target
   process. Do not layer the new hook over the old one. Updating files on disk
   does not remove loaded hooks. Disabling the old boot hook followed by a
   planned reboot can provide a clean process without restarting the radio
   service in a running TV session.
6. With a verified clean target, the module accepts one argument after its
   path: a trial duration in seconds (1–3600), or `0` for the process lifetime.
   For example, after completing the above checks:

   ```sh
   /path/to/ezinject -l /tmp/magic-pointer-native.log PID /path/to/libmagicpointer.so 120
   cat /tmp/magic-pointer-native-PID/status
   ```

   Check D-pad, OK, Home, Settings, volume, held buttons, remote reconnect,
   pointer motion, and wheel behavior. A 120-second trial restores native
   input automatically while the process/control thread is running. Earlier
   restoration can be requested with:

   ```sh
   touch /tmp/magic-pointer-native-PID/restore
   cat /tmp/magic-pointer-native-PID/status
   ```

7. After successful TV testing, run `./deploy.sh root@TV-IP`, then reboot.
   This installs `tv/watch-native.sh` and `tv/boot-native.sh`, selecting the
   staged payload via an `active` file. The watcher holds a `flock` lock,
   identifies processes by PID plus start time, uses a bounded injector run,
   and requires module readiness. It never retries a failed/partial injection
   in the same process. It can resume its own previously running target if
   injection leaves it stopped with no tracer. Existing stopped/traced targets
   are refused. `tv/restore-native.sh` disables autostart, waits for the watcher
   to stop, and requests live restoration. See the main README for commands.

Runtime injection changes process memory, not the read-only firmware. Boot
integration must reapply it on each new process and still requires Homebrew
root access. It does not remove the interval before injection when the pointer
can appear. The timed restore cannot recover a crashed or stopped process.

## Dependencies and attribution

- [ezinject](https://github.com/smx-smx/ezinject), revision
  `d9338952cd01597c5fdd7d6e98991474df5dc89c`: injector and matching module runtime.
- [Frida Gum](https://github.com/frida/frida-gum): native interception engine,
  distributed in [openlgtv's 2026.08-webos SDK](https://github.com/openlgtv/buildroot-nc4/releases/tag/2026.08-webos).
- [webOS native toolchain](https://github.com/webosbrew/native-toolchain/releases/tag/webos-d7ed7ee.6):
  macOS ARM cross compiler and base sysroot.
- [inputhookpp's build recipe](https://github.com/sundermann/inputhookpp/blob/main/.github/workflows/build.yml):
  identifies the compatible dependency SDK and its published checksum.
- [Fenrir200678's pointer hook](https://github.com/Fenrir200678/disable-lg-magic-remote/blob/main/tv/pointer-hook.php):
  reference for selective cursor-on/cursor-off handling and function signatures.

Third-party source and license files are retained in their downloaded trees.
Generated binaries are local test artifacts, not committed release assets.
Review and include the licenses/notices for all statically linked dependencies
before distributing a binary release.
