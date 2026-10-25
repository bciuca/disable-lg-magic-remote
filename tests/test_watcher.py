"""Exercise the actual POSIX watcher with simulated processes/injector."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-watcher-")
        self.root = Path(self.temp.name)
        self.base = self.root / "base"
        self.runtime = self.root / "runtime"
        self.proc = self.root / "proc"
        self.bin = self.root / "bin"
        self.payload = self.base / "candidate-test"
        for directory in (self.base, self.runtime, self.proc, self.bin, self.payload):
            directory.mkdir(parents=True, exist_ok=True)
        (self.base / "active").write_text(str(self.payload) + "\n")
        (self.payload / "libmagicpointer.so").touch()
        (self.payload / "SHA256SUMS").touch()
        self.script(self.bin / "pidof", 'cat "$MP_PROC/pid"\n', shell=True)
        self.script(self.bin / "sha256sum", 'exit 0\n', shell=True)
        self.script(self.bin / "flock", """
import fcntl, sys
try:
    fcntl.flock(int(sys.argv[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
""")
        self.script(self.bin / "timeout", """
import os, sys
assert sys.argv[1:5] == ['-t', '30', '-s', 'KILL']
os.execv(sys.argv[5], sys.argv[5:])
""")
        self.script(self.payload / "ezinject", """
import os, sys
from pathlib import Path
runtime = Path(os.environ['MP_RUNTIME'])
pid = sys.argv[3]
assert sys.argv[5] == '0'
with (runtime / 'calls').open('a') as file:
    file.write(pid + '\\n')
if os.environ.get('MP_TEST_FAIL') == 'injector':
    sys.exit(7)
state = runtime / ('magic-pointer-native-' + pid)
state.mkdir()
(state / 'status').write_text('failed\\n' if os.environ.get('MP_TEST_FAIL') == 'hook' else 'ready\\n')
(Path(os.environ['MP_PROC']) / pid / 'maps').write_text('libmagicpointer.so\\n')
""")
        self.env = dict(os.environ, MP_BASE=str(self.base), MP_RUNTIME=str(self.runtime),
                        MP_PROC=str(self.proc), PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.children = []
        self.process(500001, 100)

    @staticmethod
    def script(path, body, shell=False):
        import sys
        path.write_text(("#!/bin/sh\n" if shell else f"#!{sys.executable}\n") + body)
        path.chmod(0o755)

    def process(self, pid, start, maps="", tracer=0):
        directory = self.proc / str(pid)
        directory.mkdir(exist_ok=True)
        (directory / "comm").write_text("lginput2\n")
        fields = [str(pid), "(lginput2)", "S"] + ["0"] * 19
        fields[21] = str(start)
        (directory / "stat").write_text(" ".join(fields))
        (directory / "status").write_text(f"State:\tS (sleeping)\nTracerPid:\t{tracer}\n")
        (directory / "maps").write_text(maps)
        (self.proc / "pid").write_text(str(pid) + "\n")

    def launch(self):
        child = subprocess.Popen(["sh", str(ROOT / "tv/watch-native.sh")], env=self.env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        self.children.append(child)
        return child

    def calls(self):
        path = self.runtime / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def wait_for(self, condition):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.05)
        self.fail("watcher condition timed out")

    def tearDown(self):
        (self.base / "disabled").touch()
        for child in self.children:
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        self.temp.cleanup()

    def test_singleton_and_respawn(self):
        first = self.launch()
        self.wait_for(lambda: self.calls() == ["500001"])
        self.assertEqual(self.launch().wait(timeout=3), 0)
        self.assertIsNone(first.poll())
        self.process(500002, 200)
        self.wait_for(lambda: self.calls() == ["500001", "500002"])
        (self.base / "disabled").touch()
        self.assertEqual(first.wait(timeout=4), 0)

    def test_old_hook_refused(self):
        self.process(500001, 100, maps="/old/libphp.so\n")
        child = self.launch()
        self.wait_for(lambda: (self.runtime / "magic-pointer-native-watch.log").exists() and "skipped; watcher remains" in (self.runtime / "magic-pointer-native-watch.log").read_text())
        self.assertIsNone(child.poll())
        self.assertEqual(self.calls(), [])

    def test_traced_target_refused(self):
        self.process(500001, 100, tracer=123)
        child = self.launch()
        self.wait_for(lambda: (self.runtime / "magic-pointer-native-watch.log").exists() and "skipped; watcher remains" in (self.runtime / "magic-pointer-native-watch.log").read_text())
        self.assertIsNone(child.poll())
        self.assertEqual(self.calls(), [])

    def test_injector_failure_does_not_retry(self):
        self.env["MP_TEST_FAIL"] = "injector"
        child = self.launch()
        self.wait_for(lambda: (self.runtime / "magic-pointer-native-watch.log").exists() and "skipped; watcher remains" in (self.runtime / "magic-pointer-native-watch.log").read_text())
        self.assertIsNone(child.poll())
        self.assertEqual(self.calls(), ["500001"])

    def test_hook_failure_does_not_retry(self):
        self.env["MP_TEST_FAIL"] = "hook"
        child = self.launch()
        self.wait_for(lambda: (self.runtime / "magic-pointer-native-watch.log").exists() and "skipped; watcher remains" in (self.runtime / "magic-pointer-native-watch.log").read_text())
        self.assertIsNone(child.poll())
        self.assertEqual(self.calls(), ["500001"])

    def test_restoration_is_not_reinjected(self):
        child = self.launch()
        status = self.runtime / "magic-pointer-native-500001/status"
        self.wait_for(lambda: status.exists())
        time.sleep(0.2)
        status.write_text("restored\n")
        time.sleep(2.2)
        self.assertIsNone(child.poll())
        self.assertEqual(self.calls(), ["500001"])


    def ready(self):
        log = self.runtime / "magic-pointer-native-watch.log"
        return log.exists() and "Native hook ready" in log.read_text()

    def stop_watcher(self, child):
        (self.base / "disabled").touch()
        self.assertEqual(child.wait(timeout=4), 0)
        (self.base / "disabled").unlink()

    def test_failure_record_survives_watcher_restart(self):
        self.env["MP_TEST_FAIL"] = "injector"
        first = self.launch()
        self.wait_for(lambda: self.calls() == ["500001"])
        self.stop_watcher(first)
        second = self.launch()
        time.sleep(2.3)
        self.assertIsNone(second.poll())
        self.assertEqual(self.calls(), ["500001"])
        self.process(500002, 200)
        self.wait_for(lambda: self.calls() == ["500001", "500002"])

    def test_pid_reuse_archives_old_state(self):
        child = self.launch()
        self.wait_for(self.ready)
        self.process(500001, 200)
        self.wait_for(lambda: self.calls() == ["500001", "500001"])
        self.assertIsNone(child.poll())
        archived = self.runtime / "magic-pointer-native-attempts/500001:100-state/status"
        self.assertEqual(archived.read_text(), "ready\n")

    def test_restart_adopts_ready_hook_and_supervises_respawn(self):
        first = self.launch()
        self.wait_for(self.ready)
        self.stop_watcher(first)
        second = self.launch()
        self.wait_for(lambda: "supervising without reinjection" in
                      (self.runtime / "magic-pointer-native-watch.log").read_text())
        self.assertEqual(self.calls(), ["500001"])
        self.process(500002, 200)
        self.wait_for(lambda: self.calls() == ["500001", "500002"])
        self.assertIsNone(second.poll())

    def test_failed_hook_does_not_prevent_fresh_process(self):
        self.env["MP_TEST_FAIL"] = "hook"
        child = self.launch()
        self.wait_for(lambda: self.calls() == ["500001"])
        self.process(500002, 200)
        self.wait_for(lambda: self.calls() == ["500001", "500002"])
        self.assertIsNone(child.poll())


if __name__ == "__main__":
    unittest.main()
