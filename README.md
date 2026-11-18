# minknow-tui

[![Build](https://github.com/kojix2/minknow-tui/actions/workflows/build.yml/badge.svg)](https://github.com/kojix2/minknow-tui/actions/workflows/build.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fminknow-tui%2Flines)](https://tokei.kojix2.net/github/kojix2/minknow-tui)

Read-only MinKNOW terminal monitor. Displays positions, protocol runs,
acquisition statistics and events through the MinKNOW API.

## Build

Install Crystal, Shards and native libraries:

```sh
# macOS
brew install crystal libnghttp2 unibilium openssl readline libedit

# Debian / Ubuntu (install Crystal and Shards separately)
sudo apt-get install libnghttp2-dev libunibilium-dev libssl-dev libreadline-dev libedit-dev

shards install --frozen
shards build
bin/minknow-tui --demo
bin/minknow-tui --host localhost --port 9501
```

`--demo` requires no MinKNOW installation or hardware. `--help` lists options.

## Keys

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Change focus |
| j / k, arrows | Select or scroll |
| 1–6 | Overview, Yield, Quality, Device, Pores, Activity |
| v | Switch Quality graphs or Device history graphs |
| h | Show full read-length range or trim 1% at each end |
| d / u | Activity: detailed/grouped states; percent/absolute time |
| p / r / a | Select position / protocol run / acquisition |
| i | Inspect full IDs, run settings, channel time fractions and API status |
| / | Filter positions and runs |
| Esc | Clear filter or close dialog |
| End | Resume following events after scrolling up |
| ? | Help |
| q / Ctrl-Q / Ctrl-C | Quit |

Below 100 columns or 30 rows, use selection dialogs instead of the sidebar.
The minimum supported size is 80×24. Pane dividers can be resized.

The header identifies the position, run start time and sample for the statistics
on screen. `HISTORY` includes earlier acquisitions within a running protocol.
Pores always shows the current device. Returning to a statistics tab restores
the selected history. Press `r`, then Enter to follow the current run and its
acquisitions again. If the position is idle, this follows the next run when it starts.

## Connection

Default: `localhost:9501`, TLS enabled. CLI values override environment values.
When no port is specified, connection refusal on 9501 retries 9502. Certificate
and authentication errors do not trigger port changes.

| Variable | Purpose |
| --- | --- |
| `MINKNOW_HOST`, `MINKNOW_PORT` | Manager endpoint |
| `MINKNOW_TLS` | Set to `false` for a plaintext test server |
| `MINKNOW_TRUSTED_CA` | MinKNOW CA certificate file |
| `MINKNOW_AUTO_DETECT_CA` | Set to `false` (also `0` or `no`) to skip local default-path CA discovery |
| `MINKNOW_AUTH_TOKEN` | Explicit local-auth token |
| `MINKNOW_API_CLIENT_CERTIFICATE_CHAIN`, `MINKNOW_API_CLIENT_KEY` | Client certificate and key; supply both |
| `MINKNOW_API_USE_LOCAL_TOKEN` | Set to `false` to disable localhost token discovery |
| `PROTOCOL_TOKEN` | Protocol-auth metadata |

With TLS enabled, `MINKNOW_TRUSTED_CA` takes precedence for any host. If set,
it must point to a certificate file; an invalid path is an error, not a fallback.
Otherwise, for `localhost`, `127.0.0.1`, or `::1`, the TUI checks only MinKNOW's
standard CA paths for the current OS. On Linux it checks
`/data/rpc-certs/minknow/ca.crt` and then
`/var/lib/minknow/data/rpc-certs/minknow/ca.crt`. Other hosts, or connections
with discovery disabled, use the normal TLS trust store unless a CA is
explicitly supplied. TLS certificate and hostname verification remain enabled.

Local token discovery and unary calls time out after five seconds. Remote
connections require explicit authentication and a matching certificate.
Automatically discovered local tokens are refreshed while monitoring.

## Data and compatibility

Statistics belong to the selected acquisition. Calibration and sequencing data
are not combined. Estimated bases, basecalled bases and basecall counts are
shown separately. Pore occupancy is not a live pore count.
Live selection follows acquisition changes; manually selected historical
acquisitions stay selected.

Activity shows channel state time by minute, grouped into five-minute buckets
after 48 minutes. Channel names and colors come from acquisition metadata when
available. Pores uses state colors as cell backgrounds with contrasting black
or white letters, also shown in its legend. If metadata is missing, colors fall
back to MinKNOW 25.09 sequencing defaults. Dots mark channels with no received
state. Terminals without true color use the nearest supported colors.
Q-score graphs require basecalling. The Overview's remaining time
comes from MinKNOW run-until estimates and may be unavailable for historical
runs. Read-length trimming only changes the chart; it does not change N50.

Unsupported watch APIs fall back to polling. Open details with `i` to inspect
individual API statuses, including authentication and connection errors. Last known
data remains visible during connection loss. Quiet streams are normal.

History is limited to what MinKNOW retains through its API, and can disappear
on restart or reset. Events and chart data are held in memory, up to 2,000 events
and 1,440 points per series. No history is saved locally.

Core 6.x is the primary target. Older versions work where their APIs permit.
Tests use a fake HTTP/2 server and headless UI; real hardware is not yet verified.

## CI and releases

Normal pushes to `main` and pull requests run format/lint checks and the full
fake-API/headless test suite on Linux and macOS. They compile one test
executable, without release optimization or archive packaging. New commits
cancel obsolete runs for the same branch or pull request; feature-branch pushes
are checked through their pull requests instead of creating duplicate runs.

Tag pushes run the same checks and additionally build the portable release
archives. A manual workflow run can also request archives with the `package`
input. Only tag pushes publish a GitHub Release. Release builds still use
`--release`; their optimization cost is kept out of ordinary development CI.

`.github/scripts/build.sh check` performs checks; `build.sh release` also builds
and packages the application (the default for direct invocation). Each phase
reports its elapsed time, and the test runner prints compiler and test profiles.

CI caches `lib/`, native static libraries and Crystal compilation results under
`.ci-cache/`. Cache keys include OS/architecture, the compiler image or macOS
toolchain, `shard.lock`, the native build recipe and application/test sources.
Native libraries use a stable path so restored caches remain usable. Changing
source invalidates the test executable but can reuse Crystal object files.
Completed compiler work is cached even when a test fails.

The native script builds nghttp2 1.71.0 and, on Linux, unibilium 2.1.4 only when
the corresponding cached archive/version is missing. Linux releases use
`crystallang/crystal:latest-alpine` for static linking; the resolved image ID
separates incompatible compiler caches. macOS releases statically link external
libraries and allow only OS system libraries as dynamic dependencies. Linkage,
CLI/demo startup and archive checks remain part of release packaging.

CI needs neither MinKNOW nor bulk FAST5/POD5 data. Integration tests use a small
local HTTP/2 fake server; UI tests run headlessly. Full MinKNOW playback is a
local investigation and is not part of this repository's CI.

Dependabot checks GitHub Actions weekly. Application dependencies use `shard.lock`.

## Checks

```sh
brew install crystal-ameba/ameba/ameba  # or use your package manager
ameba src spec tools
bash spec/test_runner_spec.sh
bash tools/test.sh --profile
crystal tool format --check src spec tools
crystal run tools/capture.cr -- /tmp/minknow-tui-captures
```

`tools/test.sh` keeps the test executable in `.ci-cache/bin/spec`. It hashes
Crystal sources, spec files, shard sources/manifests and compiler identity before reuse;
changes trigger a rebuild. Filters and random seeds are runtime options, so
changing only those does not recompile:

```sh
bash tools/test.sh --example "headless UI"
bash tools/test.sh --order random
bash tools/test.sh --rebuild --profile  # force relinking after native-library changes
```

For a model-only edit, `crystal spec spec/model_spec.cr` avoids compiling the
API and UI dependencies. The complete CI suite still runs every spec. Fake-peer
tests use shorter polling intervals; production polling and RPC deadlines keep
their normal values.
