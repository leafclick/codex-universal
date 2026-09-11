#!/usr/bin/env python3
"""Regression checks for the helper's private Unix transport."""

import argparse
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


class NetworkContextChecks(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="codex-unix-transport-"))
        self.project = self.work / "project"
        self.state = self.work / "state"
        (self.project / ".codex").mkdir(parents=True)
        (self.project / "subdir").mkdir()
        self.state.mkdir()
        self.children = []
        (self.project / ".codex" / "clojure-development.edn").write_text(
            '{:default-runtime :dev '
            ':runtimes {:dev {:kind :deps '
            ':repl ["/bin/false" "--bind" "127.0.0.1" "--port" "0"]} '
            ':bb {:kind :babashka :workdir "subdir" :one-off ["bb" "-e"]}}}\n',
            encoding="utf-8",
        )
        self.control = self.state / "service-control.fifo"
        os.mkfifo(self.control)
        self.operations = self.state / "operations.log"
        self.supervisor = self.work / "context-supervisor.py"
        self.supervisor.write_text(
            "#!/usr/bin/env python3\n"
            "import os, socket, sys\n"
            "with open(os.environ['CODEX_CONTEXT_OPERATIONS'], 'a', encoding='utf-8') as stream:\n"
            "    stream.write((sys.argv[-1] if sys.argv[1] == 'control' else sys.argv[1]) + '\\n')\n"
            "operation = sys.argv[-1] if sys.argv[1] == 'control' else sys.argv[1]\n"
            "if operation == 'start':\n"
            "    with open(os.environ['CODEX_CLOJURE_STATE_DIR'] + '/repl.log', 'a', encoding='utf-8') as stream:\n"
            "        stream.write('nREPL server started on port 41234\\n')\n"
            "if operation == 'bridge':\n"
            "    path = sys.argv[-1]\n"
            "    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "    try:\n"
            "        os.unlink(path)\n"
            "    except FileNotFoundError:\n"
            "        pass\n"
            "    sock.bind(path)\n"
            "    sock.listen(1)\n"
            "    print('bridged ' + path)\n"
            "elif operation == 'context':\n"
            "    print('private-unix')\n"
            "elif operation == 'status':\n"
            "    print(os.environ.get('CODEX_STATUS_RESPONSE', 'stopped'))\n"
            "else:\n"
            "    print('stopped')\n",
            encoding="utf-8",
        )
        self.supervisor.chmod(0o755)

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        shutil.rmtree(self.work)

    def start_source_service(self):
        """Start an isolated service using the checked-in supervisor source."""
        source_supervisor = Path(self.helper).with_name("clojure-process-supervisor")
        self.control.unlink(missing_ok=True)
        service = subprocess.Popen(
            [str(source_supervisor), "service", "--control", str(self.control),
             "--project-root", str(self.project), "--state-root", str(self.state)],
            env=dict(os.environ, CODEX_CLOJURE_SERVICE_NETNS=os.readlink(
                "/proc/self/ns/net")),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(service)
        for _ in range(100):
            if self.control.is_fifo():
                return source_supervisor
            if service.poll() is not None:
                self.fail("source supervisor exited before creating its control FIFO")
            time.sleep(0.02)
        self.fail("source supervisor did not create its control FIFO")

    def run_helper(self, operation, *args, network=None, extra=None):
        env = os.environ.copy()
        env.update({"CODEX_PROJECT_ROOT": str(self.project),
                    "CODEX_CLOJURE_STATE_DIR": str(self.state),
                    "CODEX_CLOJURE_SERVICE_NETNS": network
                    if network is not None else "net:[999999]"})
        if extra:
            env.update(extra)
        return subprocess.run(
            [self.bb, self.helper, operation, *args],
            cwd=self.project,
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.bb = shutil.which("bb")
        if not cls.bb:
            raise unittest.SkipTest("bb unavailable")
        if not getattr(cls, "helper", None):
            raise unittest.SkipTest("helper path was not supplied")

    def assert_requires_elevation_without_side_effects(self, result, empty=True):
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn(":requires-elevation", result.stdout)
        self.assertIn(":not-submitted", result.stdout)
        self.assertIn(":not-inspected", result.stdout)
        if empty:
            self.assertEqual(list(self.state.iterdir()), [])

    def test_missing_service_returns_actionable_exit_two(self):
        result = self.run_helper(
            "repl-start", extra={"CODEX_CLOJURE_SUPERVISOR": str(self.work / "missing")}
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Clojure process supervisor is unavailable", result.stderr)

    def test_mismatched_eval_preserves_unknown_state_and_sends_no_request(self):
        original = (
            "{:phase :running :port 41234 :project-root \"" + str(self.project) +
            "\" :directory \"" + str(self.project) + "\" :runtime-kind :deps "
            ":runtime :dev :command [\"/bin/false\" \"--bind\" \"127.0.0.1\" \"--port\" \"0\"] "
            ":evaluation {:status :unknown :token \"keep-me\"}}\n"
        ).encode()
        (self.state / "state.edn").write_bytes(original)
        result = self.run_helper("repl-eval", "(+ 1 2)",
                                 extra={"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                                        "CODEX_LIVE_NETWORK_CONTEXT": "network-context net:[999999]",
                                        "CODEX_CONTEXT_OPERATIONS": str(self.operations)})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unknown server execution state", result.stdout + result.stderr)
        self.assertNotIn(":requires-elevation", result.stdout)
        self.assertEqual((self.state / "state.edn").read_bytes(), original)
        self.assertFalse(self.operations.exists())

    def test_legacy_running_state_without_socket_is_rejected(self):
        (self.state / "state.edn").write_text(
            '{:phase :running :port 41234 :project-root "' + str(self.project) +
            '" :directory "' + str(self.project) + '" :runtime-kind :deps '
            ':runtime :dev :command ["/bin/false" "--bind" "127.0.0.1" "--port" "0"] '
            ':control-path "' + str(self.control) + '" :control-token "owner-token"}\n',
            encoding="utf-8")
        result = self.run_helper(
            "repl-eval", "(+ 1 2)",
            extra={"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                   "CODEX_CONTEXT_OPERATIONS": str(self.operations)})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("private Unix transport", result.stderr)
        self.assertFalse(self.operations.exists())

    def test_running_status_reports_ownership_without_claiming_endpoint_health(self):
        socket_path = self.state / "repl.sock"
        state = ('{:phase :running :socket-path "' + str(socket_path) +
                 '" :project-root "' +
                 str(self.project) + '" :directory "' + str(self.project) +
                 '" :runtime-kind :deps :runtime :dev :command ["/bin/false" '
                 '"--bind" "127.0.0.1" "--port" "0"] :control-path "' +
                 str(self.control) + '" :control-token "owner-token"}\n')
        (self.state / "state.edn").write_text(state, encoding="utf-8")
        common = {"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                  "CODEX_STATUS_RESPONSE": "running 1234",
                  "CODEX_CONTEXT_OPERATIONS": str(self.operations)}
        result = self.run_helper("repl-status", extra=common)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(":status :running", result.stdout)
        self.assertIn(":endpoint-status :unreachable", result.stdout)

    def test_one_off_runs_without_service_and_preserves_stdio(self):
        result = self.run_helper(
            "one-off", '(do (println "one-off-stdout") '
            '(println (System/getProperty "user.dir")) '
            '(binding [*out* *err*] (println "one-off-stderr")))', "bb",
            network="malformed",
            extra={"CODEX_CLOJURE_SERVICE_NETNS": "net:[999999]"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(":done", result.stdout)
        self.assertIn("one-off-stdout", result.stdout)
        self.assertIn("one-off-stderr", result.stdout)
        self.assertIn(str(self.project / "subdir"), result.stdout)
        self.assertIn(":exit 0", result.stdout)
        self.assertIn(":termination-confirmed true", result.stdout)
        self.assertFalse(self.operations.exists())

    def test_other_project_cannot_eval_or_stop(self):
        foreign = self.work / "other-project"
        foreign.mkdir()
        # EDN syntax is deliberately kept simple for this fixture.
        (self.state / "state.edn").write_text(
            '{:phase :running :port 41234 :project-root "' + str(foreign) +
            '" :directory "' + str(foreign) + '" :runtime-kind :deps '
            ':runtime :dev :command ["/bin/false"] :control-path "' +
            str(self.control) + '" :control-token "foreign-token"}\n', encoding="utf-8")
        original = (self.state / "state.edn").read_bytes()
        common = {"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                  "CODEX_LIVE_NETWORK_CONTEXT": "network-context " + os.readlink("/proc/self/ns/net"),
                  "CODEX_CONTEXT_OPERATIONS": str(self.operations)}
        result = self.run_helper("repl-eval", "(+ 1 2)", extra=common)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(":runtime-project-mismatch", result.stdout)
        self.assertIn(":not-submitted", result.stdout)
        self.assertEqual(original.count(b"foreign-token"), 1)
        self.assertEqual((self.state / "state.edn").read_bytes(), original)
        result = self.run_helper("repl-stop", extra=common)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(":runtime-project-mismatch", result.stdout)
        self.assertEqual((self.state / "state.edn").read_bytes(), original)
        self.assertFalse(self.operations.exists())

    def test_owner_cannot_eval_changed_recipe_but_can_cleanup(self):
        inert = [sys.executable, "-c", "import time; time.sleep(60)",
                 "--bind", "127.0.0.1", "--port", "0"]
        inert_edn = "[" + " ".join(json.dumps(item) for item in inert) + "]"
        original = ('{:phase :running :port 41234 :project-root "' + str(self.project) +
                    '" :directory "' + str(self.project) + '" :runtime-kind :deps '
                    ':runtime :dev :command ' + inert_edn + ' :control-path "' +
                    str(self.control) + '" :control-token "owner-token"}\n')
        (self.state / "state.edn").write_text(original, encoding="utf-8")
        config = self.project / ".codex" / "clojure-development.edn"
        config.write_text(config.read_text(encoding="utf-8").replace(
            '["/bin/false" "--bind" "127.0.0.1" "--port" "0"]', inert_edn), encoding="utf-8")
        source_supervisor = self.start_source_service()
        start = subprocess.run(
            [str(source_supervisor), "start", "--log", str(self.state / "repl.log"),
             "--dir", str(self.project), str(self.control), "owner-token", "--",
             *inert],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertEqual(start.returncode, 0, start.stderr)
        pid = int(start.stdout.strip().split()[-1])
        running = subprocess.run(
            [str(source_supervisor), "control", str(self.control), "owner-token", "status"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertTrue(running.stdout.startswith("running "), running.stdout)
        config.write_text(config.read_text(encoding="utf-8").replace(inert_edn, inert_edn.replace(sys.executable, "/bin/true")), encoding="utf-8")
        common = {"CODEX_CLOJURE_SUPERVISOR": str(source_supervisor),
                  "CODEX_CONTEXT_OPERATIONS": str(self.operations)}
        result = self.run_helper("repl-eval", "(+ 1 2)", extra=common)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("runtime-recipe-mismatch", result.stdout + result.stderr)
        self.assertIn(":not-submitted", result.stdout)
        self.assertTrue((self.state / "state.edn").exists())
        running = subprocess.run(
            [str(source_supervisor), "control", str(self.control), "owner-token", "status"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertTrue(running.stdout.startswith("running "), running.stdout)
        result = self.run_helper("repl-stop", extra=common)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(":termination :confirmed", result.stdout)
        self.assertFalse((self.state / "state.edn").exists())

    def test_local_eval_rejects_no_state_or_invalid_config_without_context(self):
        for invalid_config in (False, True):
            with self.subTest(invalid_config=invalid_config):
                if invalid_config:
                    (self.project / ".codex" / "clojure-development.edn").write_text(
                        "{:runtimes invalid}", encoding="utf-8")
                    (self.state / "state.edn").write_text(
                        '{:phase :running :runtime :dev :runtime-kind :deps '
                        ':directory "' + str(self.project) + '" :project-root "' +
                        str(self.project) + '" :command ["/bin/false"]}\n', encoding="utf-8")
                result = self.run_helper(
                    "repl-eval", "(+ 1 2)",
                    extra={"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                           "CODEX_CONTEXT_OPERATIONS": str(self.operations)})
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(":requires-elevation", result.stdout)
                self.assertFalse(self.operations.exists())
                state_files = [path for path in self.state.iterdir()
                               if path.name != "service-control.fifo"]
                self.assertEqual([path.name for path in state_files],
                                 ["state.edn"] if invalid_config else [])

    def test_malformed_start_config_is_rejected_before_context(self):
        (self.project / ".codex" / "clojure-development.edn").write_text(
            "{:runtimes invalid}", encoding="utf-8")
        result = self.run_helper(
            "repl-start", extra={"CODEX_CLOJURE_SUPERVISOR": str(self.supervisor),
                                  "CODEX_CONTEXT_OPERATIONS": str(self.operations)})
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.operations.exists())
        self.assertEqual([path.name for path in self.state.iterdir()
                          if path.name != "service-control.fifo"], [])

    def test_unresponsive_stale_fifo_obeys_existing_request_deadline(self):
        reader = self.work / "fifo-reader.py"
        reader.write_text(
            "import os, sys, time\n"
            "fd = os.open(sys.argv[1], os.O_RDONLY)\n"
            "os.read(fd, 4096)\n"
            "time.sleep(30)\n", encoding="utf-8")
        self.control.unlink()
        os.mkfifo(self.control)
        (self.state / "state.edn").write_text(
            '{:phase :running :socket-path "' + str(self.state / "repl.sock") +
            '" :project-root "' + str(self.project) +
            '" :directory "' + str(self.project) + '" :runtime-kind :deps '
            ':runtime :dev :command ["/bin/false" "--bind" "127.0.0.1" "--port" "0"] '
            ':control-path "' + str(self.control) + '" :control-token "owner-token"}\n',
            encoding="utf-8")
        child = subprocess.Popen([sys.executable, str(reader), str(self.control)])
        self.children.append(child)
        started = time.monotonic()
        result = self.run_helper(
            "repl-eval", "(+ 1 2)", extra={"CODEX_CLOJURE_SUPERVISOR": str(
                Path(self.helper).with_name("clojure-process-supervisor"))})
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("No running configured nREPL", result.stdout + result.stderr)
        self.assertGreaterEqual(elapsed, 4)
        self.assertLess(elapsed, 8)

    def test_supervisor_survives_one_fifo_read_eagain(self):
        source = Path(self.helper).with_name("clojure-process-supervisor")
        marker = self.work / "inject-eagain"
        wrapper = self.work / "eagain-supervisor.py"
        wrapper.write_text(
            "import errno, os, runpy, sys\n"
            "source, control, marker = sys.argv[1:4]\n"
            "original_read = os.read\n"
            "injected = False\n"
            "def read(fd, size):\n"
            "    global injected\n"
            "    try: target = os.path.realpath('/proc/self/fd/' + str(fd))\n"
            "    except OSError: target = ''\n"
            "    if (not injected and os.path.exists(marker) and target == os.path.realpath(control)):\n"
            "        injected = True\n"
            "        os.unlink(marker)\n"
            "        raise BlockingIOError(errno.EAGAIN, 'injected test EAGAIN')\n"
            "    return original_read(fd, size)\n"
            "os.read = read\n"
            "sys.argv = [source] + sys.argv[4:]\n"
            "runpy.run_path(source, run_name='__main__')\n", encoding="utf-8")
        wrapper.chmod(0o755)
        self.control.unlink()
        service = subprocess.Popen(
            [sys.executable, str(wrapper), str(source), str(self.control), str(marker),
             "service", "--control", str(self.control), "--project-root", str(self.project),
             "--state-root", str(self.state)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.children.append(service)
        self.addCleanup(service.stderr.close)
        for _ in range(100):
            if self.control.is_fifo():
                break
            time.sleep(0.02)
        if not self.control.is_fifo():
            detail = service.stderr.read() if service.poll() is not None else "service still running"
            self.fail(detail)
        start = subprocess.run(
            [str(source), "start", "--log", str(self.state / "repl.log"),
             "--dir", str(self.project), str(self.control), "owner-token", "--",
             sys.executable, "-c", "import time; time.sleep(60)",
             "--bind", "127.0.0.1", "--port", "0"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertEqual(start.returncode, 0, start.stderr)
        pid = int(start.stdout.strip().split()[-1])
        marker.touch()
        context = subprocess.run(
            [str(source), "control", str(self.control), "-", "context"],
            text=True, capture_output=True, check=False, timeout=7)
        traceback = service.stderr.read() if service.poll() is not None else ""
        self.assertEqual(context.returncode, 0, traceback)
        self.assertTrue(context.stdout.startswith("network-context "), traceback)
        self.assertFalse(marker.exists())
        self.assertIsNone(service.poll(), traceback)
        status = subprocess.run(
            [str(source), "control", str(self.control), "owner-token", "status"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertTrue(status.stdout.startswith("running "), status.stdout)
        stop = subprocess.run(
            [str(source), "control", str(self.control), "owner-token", "stop"],
            text=True, capture_output=True, check=False, timeout=7)
        self.assertEqual(stop.returncode, 0, traceback)
        self.assertEqual(stop.stdout.strip(), "stopped confirmed")
        for _ in range(100):
            if not Path("/proc", str(pid)).exists():
                break
            time.sleep(0.02)
        self.assertFalse(Path("/proc", str(pid)).exists())

    def test_competing_fifo_reader_does_not_kill_service(self):
        source = Path(self.helper).with_name("clojure-process-supervisor")
        marker = self.work / "steal-fifo"
        wrapper = self.work / "stealing-supervisor.py"
        wrapper.write_text(
            "import errno, os, runpy, sys\n"
            "source, control, marker = sys.argv[1:4]\n"
            "original_read = os.read\n"
            "stolen = False\n"
            "def read(fd, size):\n"
            "    global stolen\n"
            "    target = os.path.realpath('/proc/self/fd/' + str(fd))\n"
            "    if not stolen and os.path.exists(marker) and target == os.path.realpath(control):\n"
            "        stolen = True\n"
            "        os.unlink(marker)\n"
            "        other = os.open(control, os.O_RDONLY | os.O_NONBLOCK)\n"
            "        try: original_read(other, 65536)\n"
            "        finally: os.close(other)\n"
            "    return original_read(fd, size)\n"
            "os.read = read\n"
            "sys.argv = [source] + sys.argv[4:]\n"
            "runpy.run_path(source, run_name='__main__')\n", encoding="utf-8")
        wrapper.chmod(0o755)
        self.control.unlink()
        service = subprocess.Popen(
            [sys.executable, str(wrapper), str(source), str(self.control), str(marker),
             "service", "--control", str(self.control), "--project-root", str(self.project),
             "--state-root", str(self.state)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.children.append(service)
        self.addCleanup(service.stderr.close)
        for _ in range(100):
            if self.control.is_fifo():
                break
            time.sleep(0.02)
        if not self.control.is_fifo():
            detail = service.stderr.read() if service.poll() is not None else "service still running"
            self.fail(detail)
        start = subprocess.run(
            [str(source), "start", "--log", str(self.state / "repl.log"),
             "--dir", str(self.project), str(self.control), "owner-token", "--",
             sys.executable, "-c", "import time; time.sleep(60)",
             "--bind", "127.0.0.1", "--port", "0"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertEqual(start.returncode, 0, start.stderr)
        marker.touch()
        first = subprocess.run(
            [str(source), "control", str(self.control), "-", "context"],
            text=True, capture_output=True, check=False, timeout=7)
        self.assertNotEqual(first.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIsNone(service.poll(), service.stderr.read()
                          if service.poll() is not None else "")
        second = subprocess.run(
            [str(source), "control", str(self.control), "-", "context"],
            text=True, capture_output=True, check=False, timeout=7)
        self.assertEqual(second.returncode, 0, service.stderr.read() if service.poll() else "")
        status = subprocess.run(
            [str(source), "control", str(self.control), "owner-token", "status"],
            text=True, capture_output=True, check=False, timeout=5)
        self.assertTrue(status.stdout.startswith("running "), status.stdout)
        stop = subprocess.run(
            [str(source), "control", str(self.control), "owner-token", "stop"],
            text=True, capture_output=True, check=False, timeout=7)
        self.assertEqual(stop.returncode, 0)
        self.assertEqual(stop.stdout.strip(), "stopped confirmed")

    def test_control_and_config_operations_remain_available_on_mismatch(self):
        for operation, expected in (("config-validate", ":valid"),
                                    ("repl-status", ":stopped"),
                                    ("repl-stop", ":stopped")):
            with self.subTest(operation=operation):
                result = self.run_helper(operation)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertNotIn(":requires-elevation", result.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("helper")
    args, remaining = parser.parse_known_args()
    NetworkContextChecks.helper = str(Path(args.helper).resolve())
    unittest.main(argv=["check-clojure-network-context.py", *remaining])


if __name__ == "__main__":
    main()
