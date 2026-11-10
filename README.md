# minknow-tui

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
| 1–4 | Overview, Yield, Quality, Device |
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
| `MINKNOW_AUTH_TOKEN` | Explicit local-auth token |
| `MINKNOW_API_CLIENT_CERTIFICATE_CHAIN`, `MINKNOW_API_CLIENT_KEY` | Client certificate and key; supply both |
| `MINKNOW_API_USE_LOCAL_TOKEN` | Set to `false` to disable localhost token discovery |
| `PROTOCOL_TOKEN` | Protocol-auth metadata |

Local token discovery and unary calls time out after five seconds. Remote
connections require explicit authentication and a matching certificate.

## Data and compatibility

Statistics belong to the selected acquisition. Calibration and sequencing data
are not combined. Estimated bases, basecalled bases and basecall counts are
shown separately. Pore occupancy is not a live pore count.

Unsupported watch APIs fall back to polling. Missing optional APIs are listed
in Device; authentication and connection errors are distinguished. Last known
data remains visible during connection loss. Quiet streams are normal.

History is limited to what MinKNOW retains through its API, and can disappear
on restart or reset. Events and chart data are held in memory, up to 2,000 events
and 1,440 points per series. No history is saved locally.

Core 6.x is the primary target. Older versions work where their APIs permit.
Tests use a fake HTTP/2 server and headless UI; real hardware is not yet verified.

## CI and releases

`.github/workflows/build.yml` prepares the CI environments and runs
`.github/scripts/build.sh` to test, build and package Linux and macOS binaries.
The script builds `libnghttp2.a` from the latest stable source release.
Linux uses `crystallang/crystal:latest-alpine` for fully static linking.
macOS statically links external libraries and allows only OS system libraries
as dynamic dependencies. Linkage and CLI/demo startup are checked before packaging.

Push a tag to publish a Release after both builds pass. Assets are native
architecture `.tar.gz` archives and SHA-256 checksums. Archives include the
binary, README, manifests and toolchain information. macOS support follows
the runner's SDK; Homebrew runtime libraries are not required. Terminal database
and MinKNOW authentication files remain host data.

Dependabot checks GitHub Actions weekly. Application dependencies use `shard.lock`.

## Checks

```sh
brew install ameba  # or install Ameba through your package manager
ameba src spec tools
crystal spec
crystal tool format --check src spec tools
crystal run tools/capture.cr -- /tmp/minknow-tui-captures
```
