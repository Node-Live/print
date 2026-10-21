#!/usr/bin/env python3
"""Goes through the whole update chain on the packed app. A copy relabelled 9.9.9 is served the way GitHub serves
releases; the app, installed in a temp folder, checks that feed, downloads, swaps the bundles and comes back from the
new one, listening again.

The app runs as a child of this script that is not reaped, in a process group of its own. Once it has quit it stays
a zombie, which the relaunch helper's `kill -0` still sees, so the swap can be looked at before the new version
clears the staging folder. Killing the group then does what launchd does when a login item's job ends; the helper
has to survive that.
"""
import http.server
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

VERSION = "9.9.9"
PACKAGE = "NODE-Print-macos.zip"
STATUS = "http://127.0.0.1:19233/status"


class Feed(http.server.BaseHTTPRequestHandler):
    """`/latest` redirects to the release tag and `/latest/download/<asset>` serves the asset, as on GitHub."""

    package = b""

    def do_HEAD(self):
        self.answer(with_body=False)

    def do_GET(self):
        self.answer(with_body=True)

    def answer(self, with_body):
        if self.path == "/latest":
            host, port = self.server.server_address[:2]
            self.send_response(302)
            self.send_header("Location", f"http://{host}:{port}/releases/tag/v{VERSION}")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/latest/download/" + PACKAGE:
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(len(self.package)))
            self.end_headers()
            if with_body:
                self.wfile.write(self.package)
        else:
            self.send_error(404)


def run(*command):
    subprocess.run(command, check=True)


def output(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()


def version(app):
    return output("plutil", "-extract", "CFBundleShortVersionString", "raw", app + "/Contents/Info.plist")


def listening():
    """The pid answering /status on 19233, else None."""
    if subprocess.run(["curl", "-sf", "--max-time", "2", "-o", "/dev/null", STATUS]).returncode != 0:
        return None
    pids = output("lsof", "-t", "-nP", "-iTCP:19233", "-sTCP:LISTEN").split()
    return int(pids[0]) if pids else None


def wait_for(what, seconds, check):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    sys.exit("gave up waiting for " + what)


def expect(condition, failure):
    if not condition:
        sys.exit(failure)


def main():
    app = os.path.abspath(sys.argv[1])
    work = tempfile.mkdtemp()
    release = os.path.join(work, "release", "NODE Print.app")
    installed = os.path.join(work, "install", "NODE Print.app")
    staging = os.path.join(work, "install", ".node-print-update")
    log = os.path.expanduser("~/Library/Logs/NODE Print/update.log")

    run("ditto", app, release)
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        run("plutil", "-replace", key, "-string", VERSION, release + "/Contents/Info.plist")
    run("codesign", "--force", "--deep", "--sign", "-", release)
    run("ditto", "-c", "-k", "--keepParent", release, os.path.join(work, PACKAGE))
    with open(os.path.join(work, PACKAGE), "rb") as file:
        Feed.package = file.read()
    run("ditto", app, installed)
    before = version(installed)

    feed = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Feed)
    threading.Thread(target=feed.serve_forever, daemon=True).start()
    environment = dict(os.environ, NODE_PRINT_UPDATES=f"http://127.0.0.1:{feed.server_address[1]}")

    wait_for("the smoke run's app to quit", 30, lambda: subprocess.run(["pgrep", "-x", "NODE Print"], capture_output=True).returncode != 0)
    old = subprocess.Popen([installed + "/Contents/MacOS/NODE Print"], env=environment, start_new_session=True)
    try:
        wait_for(f"{before} to listen", 30, lambda: listening() == old.pid)
        print(f"{before} listening as pid {old.pid}, installed at {installed}", flush=True)

        wait_for(f"{before} to install {VERSION} and quit", 120, lambda: output("ps", "-o", "stat=", "-p", str(old.pid)).startswith("Z"))
        print(f"pid {old.pid} has quit; the bundle in place is {version(installed)}, old.app is {version(staging + '/old.app')}", flush=True)
        run("ls", "-la", staging)
        helper = output("pgrep", "-f", f"kill -0 {old.pid} ")
        print(f"relaunch helper: {output('ps', '-o', 'pid=,pgid=,command=', '-p', helper) if helper else 'none'}", flush=True)
        expect(version(installed) == VERSION, f"the bundle in place is not {VERSION}")
        expect(version(staging + "/old.app") == before, f"old.app {before} is not in the staging folder")
        expect(helper, "no relaunch helper is waiting")
        expect(int(output("ps", "-o", "pgid=", "-p", helper)) != old.pid, "the relaunch helper is in the app's process group")

        try:
            os.killpg(old.pid, signal.SIGKILL)
        except OSError:
            pass
        old.wait()

        new = wait_for(f"{VERSION} to listen", 90, lambda: (lambda pid: pid if pid and pid != old.pid else None)(listening()))
        command = output("ps", "-o", "args=", "-p", str(new))
        print(f"pid {new} listening: {command}", flush=True)
        print(output("curl", "-s", STATUS), flush=True)
        expect(f"{os.path.basename(work)}/install/NODE Print.app/Contents/MacOS/NODE Print" in command, "the new process is not the installed bundle")
        expect(command.endswith(" --tray"), "the new process was not started with --tray")
        expect(version(installed) == VERSION, f"the bundle in place is not {VERSION}")
        expect(not os.path.exists(staging), "the new version left the staging folder")
        with open(log) as file:
            expect(any(line.endswith(" downloaded and applied " + VERSION) for line in file.read().splitlines()), "update.log has no applied line")
        print("the update chain went through", flush=True)
    finally:
        if os.path.exists(log):
            with open(log) as file:
                print("update.log:\n" + file.read(), flush=True)
        if old.poll() is None:
            old.kill()
            old.wait()
        for pid in output("pgrep", "-x", "NODE Print").split():
            os.kill(int(pid), signal.SIGTERM)
        feed.shutdown()


main()
