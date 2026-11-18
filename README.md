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
| / | Filter positions and runs |
| Esc | Clear filter or close dialog |
| End | Resume following events after scrolling up |
| ? | Help |
| q / Ctrl-Q / Ctrl-C | Quit |

Below 100 columns or 30 rows, use selection dialogs instead of the sidebar.
The minimum supported size is 80×24. Pane dividers can be resized.

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

Unsupported watch APIs fall back to polling. Missing optional APIs are listed
in Device; authentication and connection errors are distinguished. Last known
data remains visible during connection loss. Quiet streams are normal.

History is limited to what MinKNOW retains through its API, and can disappear
on restart or reset. Events and chart data are held in memory, up to 2,000 events
and 1,440 points per series. No history is saved locally.

Core 6.x is the primary target. Older versions work where their APIs permit.
Tests use a fake HTTP/2 server and headless UI; real hardware is not yet verified.

## Live playback on Linux

`tools/playback.py` runs the installed MinKNOW in a separate workspace directory,
with hardware discovery disabled and one simulated MinION (`MS00000`). It uses
MinKNOW's bundled Python, TLS certificates generated for this environment, and a
dedicated CPU Dorado server. It does not require sudo. Port 9501 must be free;
the script refuses to take over another manager.

From this repository:

```sh
PY=/opt/ont/minknow/ont-python/bin/python
"$PY" tools/playback.py start
"$PY" tools/playback.py run --minutes 15 --basecalling
"$PY" tools/playback.py tui
```

The default input is the existing `/srv/nanopore-data/r10_5khz.fast5` bulk FAST5,
recorded at 5 kHz with SQK-LSK114. Defaults use FLO-MIN114 and the installed
`dna_r10.4.1_e8.2_400bps_fast@v5.2.0` model. To use another recording, pass
`--bulk /absolute/path/bulk.fast5` and matching `--kit`, `--product`, and, when
basecalling, `--model`. This input is a **bulk** FAST5 recording, rather than a
per-read FAST5 file. The original recording is opened for playback without
copying it into the repository.

Omit `--basecalling` to check signal and estimated-yield monitoring alone.
Initialization includes temperature stabilization, calibration and a mux scan,
which can take a few minutes. `--minutes` sets the sequencing duration; the
recording loops during that time. Playback writes POD5, and basecalling also
writes FASTQ. Configuration, certificates, logs and outputs remain under the
git-ignored `.playback/` directory. Set `MINKNOW_PLAYBACK_ROOT` to choose another
directory before running any of these commands.

```sh
"$PY" tools/playback.py status    # protocol/acquisition state and yield as JSON
"$PY" tools/playback.py stop-run  # stop this environment's sequencing run
"$PY" tools/playback.py stop      # stop this environment's manager
```

The manager remains running after a run finishes, so another `run` can be
started. Stopping waits for acquisition/basecalling and retains outputs and
logs. If shutdown times out, it reports the pending state without forcing
process termination. `start` / `stop` manage only this
workspace's process; the system MinKNOW service is managed separately.

To check actual API data through the TUI and save all six tabs as PNG/text
captures, run this while the simulated device is sequencing:

```sh
MINKNOW_TRUSTED_CA="$PWD/.playback/data/rpc-certs/minknow/ca.crt" \
  crystal run tools/check_playback.cr -Dwithout_readline -- .playback/captures
```

The check waits for read statistics, yield, read lengths, temperature, bias
voltage, live channel states and pore activity. When basecalling is enabled it
also checks basecall counts and both Q-score graphs. Captures and
`summary.json` are written to the destination. This validates the installed
MinKNOW with a simulated device; physical hardware remains unverified.
The playback option is described in ONT's
[official start_protocol example](https://github.com/nanoporetech/minknow_api/blob/master/python/minknow_api/examples/start_protocol.py).

## CI and releases

`.github/workflows/build.yml` prepares the CI environments and runs
`.github/scripts/build.sh` to test, build and package Linux and macOS binaries.
The script builds `libnghttp2.a` from nghttp2 1.71.0 source.
Linux uses `crystallang/crystal:latest-alpine` for fully static linking.
It also builds unibilium 2.1.4 to read modern terminfo files.
Native source versions are pinned in the script; builds do not query GitHub's
releases API.
macOS statically links external libraries and allows only OS system libraries
as dynamic dependencies. Linkage and CLI/demo startup are checked before packaging.

Push a tag to publish a Release after both builds pass. Assets are native
architecture `.tar.gz` archives. Archives include the binary, README, manifests
and toolchain information. macOS support follows the runner's SDK; Homebrew
runtime libraries are not required. Terminal database and MinKNOW authentication
files remain host data.

Dependabot checks GitHub Actions weekly. Application dependencies use `shard.lock`.

## Checks

```sh
brew install crystal-ameba/ameba/ameba  # or use your package manager
ameba src spec tools
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s spec -p '*_test.py' -v
crystal spec
crystal tool format --check src spec tools
crystal run tools/capture.cr -- /tmp/minknow-tui-captures
```
