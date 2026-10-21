# NODE Print updates (v1)

NODE Print keeps itself current from the GitHub releases of `Node-Live/print` on its own: no prompt, no
button, no setting. Nobody in a warehouse is asked anything, and nothing is shown; the only visible trace is
the new version number at the top of the window afterwards. Both apps carry the same version, a release bumps
both, and each app updates from the files of its own platform (see the top-level README for the file names).

## When

- One timer per app: the first check runs 1 hour after the app starts, then every hour. The timer is not
  persisted; a restart, an update included, starts it over.
- A check runs only while the app is idle: no job on either channel, and the last job ended at least 5 minutes
  ago. No job since the app started counts as idle. A job counts from the moment `POST /print` arrives until
  its response has been sent, whatever the outcome, so a body still being received is a job. Both apps keep
  "jobs in flight" and "when the last one ended" for this.
- Not idle at the tick: nothing happens until the next tick. No catch-up, no shorter retry.
- Anything that fails (no network, GitHub answering an error or a rate limit, a broken download, a folder the
  app may not write) is logged and left for the next tick; the app keeps printing meanwhile.

## What a check does

1. Finds the newest release. Prereleases (tags with a suffix, `v1.2.3-rc.1`) are never taken.
2. Compares its version with the app's own, numerically per component; only a newer one goes on. A same or
   older version is nothing to do.
3. Downloads the platform's package.
4. If the app is still idle (same rule): stops the local server, so a request arriving during the swap is
   refused outright (the web says "cannot reach", and a retry works once the app is back), applies the update
   and starts the new version without its window, the way a login launch does. If a job came in meanwhile,
   the download is kept and applied at the next idle tick without downloading again.

## Windows

Velopack, which already installs the app, does the update. `UpdateManager` on
`SimpleWebSource("https://github.com/Node-Live/print/releases/latest/download")`: the latest release's download
links redirect to its files, so `releases.win.json` and the packages are read from there with no GitHub API
call, no rate limit, and no prerelease (a prerelease is never "latest"). `CheckForUpdatesAsync` is the check,
`DownloadUpdatesAsync` the download (a delta when the release has one, else the full package),
`WaitExitThenApplyUpdates(update, silent: true, restart: true, ["--tray"])` followed by the app's own quit
(server stopped, tray icon gone) is the swap: `Update.exe` waits for the process to exit, replaces `current\`
without a window of its own and starts the new version, which takes the `Global\NODE Print` mutex only once
the old process is gone. Velopack's apply-on-launch is off (`SetAutoApplyOnStartup(false)`): a download kept
from an earlier tick is found through `UpdatePendingRestart` and applied by the scheduler, never by a launch.
The Run key points at `current\NodePrint.exe`, which an update leaves where it is.

Build: `PublishAot` stays free of trimming warnings from `UpdateManager`. The release carries
`releases.win.json`, `NodePrint-<version>-full.nupkg` and, when the CI had the previous release to diff
against (`vpk download github` before `vpk pack`, on tag builds only), `NodePrint-<version>-delta.nupkg`;
`release.yml` uploads whichever of these exist.

## macOS

There is no Velopack here; the app does it itself, from inside `NodePrintCore`.

1. Version: `HEAD https://github.com/Node-Live/print/releases/latest` without following the redirect; the
   `Location` ends in `/releases/tag/v<version>`. No GitHub API, so no rate limit and no token.
2. Download: `https://github.com/Node-Live/print/releases/latest/download/NODE-Print-macos.zip` with
   `URLSession`, 5 minutes, into a staging folder `.node-print-update` beside the installed bundle, on the
   same volume, so installing is a rename. Where that folder cannot be written (checked by creating a file in
   it), or the app does not run from a `.app` bundle (`swift run`, a mounted DMG), the check logs that and
   stops.
3. Unpack with `ditto -x -k`. The unpacked `NODE Print.app` is accepted only when `codesign --verify --deep
   --strict` passes and its `CFBundleShortVersionString` is the version from step 1. A file the app downloads
   itself carries no quarantine attribute, so Gatekeeper never asks about the new version.
4. Install: rename the running bundle to `old.app` inside the staging folder, rename the new one into its
   place; when the second rename fails, put the old one back. The old bundle is not deleted now: the running
   process is its image, and macOS kills a child spawned from a deleted image. The new version removes the
   staging folder beside itself when it starts.
5. Relaunch: spawn `/bin/sh -c 'while kill -0 <pid> 2>/dev/null; do sleep 0.2; done; open "<bundle>" --args
   --tray'` in a session of its own (`posix_spawn` with `POSIX_SPAWN_SETSID`, stdio closed), then stop the
   server and exit. Left in the app's own process group, the helper dies with it when launchd ends the group
   of a login-item job or, on some macOS versions, of the job the Dock opened the app in. `--tray` is new on
   macOS and means what it means on Windows: start without the window. The single-instance check in the new
   process finds nothing, because the helper only runs `open` once the old process is gone.

## Logging

One line per attempt that downloaded, applied or failed; nothing for ticks that found nothing newer or were
skipped as busy. Windows: `%LOCALAPPDATA%\NODE Print\error.log` (the existing file). macOS:
`~/Library/Logs/NODE Print/update.log`.

## Testing

Set `NODE_PRINT_UPDATES=<base URL>` and the app reads releases from there instead of GitHub, with the first
check 2 seconds after start instead of an hour later (then hourly as usual; the idle rule still applies).
Windows reads a Velopack feed at that URL (`SimpleWebSource`: `releases.win.json` and the packages). macOS
expects the shape GitHub has: `<base>/latest` answering a redirect whose `Location` ends in `/tag/v<version>`,
and `<base>/latest/download/NODE-Print-macos.zip` serving the package. CI uses this to prove the whole chain
on a fake newer version: the app checks the local feed, downloads, swaps, and comes back listening with the
new version in place.

Unit tests, one per rule: the idle rule (a job in flight; the last job 4 minutes ago; 5 minutes ago; none
since start), the version comparison (newer, same, older), a check skipped while busy, an update downloaded
and applied when idle, an apply deferred when a job arrives between download and apply. macOS also: the
redirect parsed and a malformed one refused, a staged bundle refused for a wrong version or a broken
signature, the old bundle put back when the install fails halfway. No test waits for real time: the timer
takes a clock.
