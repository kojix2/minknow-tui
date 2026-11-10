# minknow-tui

A read-only MinKNOW terminal monitor inspired by LazyDocker, written in Crystal
with Crysterm. Connect to one Manager and inspect its sequencing positions,
current and historical protocol runs, acquisition statistics and events.

The interface uses dark forest green surfaces and bright green selection and
focus accents, with turquoise for secondary data. Coral and amber distinguish
failed yield and temperature traces. The palette is defined in
`src/minknow_tui/theme.cr`.

## Build and run

Requires Crystal >= 1.20, Shards, libnghttp2, libunibilium, OpenSSL and the
readline/editline libraries used by Crysterm.

```sh
# macOS
brew install crystal nghttp2 unibilium openssl readline libedit

# Debian / Ubuntu, after installing Crystal and Shards
sudo apt-get install libnghttp2-dev libunibilium-dev libssl-dev libreadline-dev libedit-dev

shards install
shards build
bin/minknow-tui --demo
bin/minknow-tui
bin/minknow-tui --host localhost --port 9501
```

`--demo` generates live data entirely in-process. It never connects to MinKNOW
or touches sequencing hardware. `--help` and `--version` do not open the TUI.

## Navigation

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Move focus |
| j / k, arrows | Select rows or scroll |
| 1–4 | Overview, Yield, Quality, Device |
| p | Choose a position or host overview |
| r | Choose a protocol run from available API history |
| a | Choose an acquisition within the selected protocol |
| / | Filter positions and runs |
| Esc | Clear filter or close a dialog |
| ? | Help |
| q / Ctrl-Q / Ctrl-C | Quit |

The standard layout has position and run tables, detail tabs and an event pane.
Below 100 columns or 30 rows, the tables fold away; `p`, `r` and `a` open
selection dialogs. Basic navigation works at 80×24. Splitters can be resized
with the mouse or the arrow keys when their divider has focus. Scroll up in
Events to pause following new messages; End resumes following.

## Connecting and authentication

The default Manager is `localhost:9501`, using TLS. CLI host/port values override
`MINKNOW_HOST` and `MINKNOW_PORT`. When no port is specified and 9501 refuses the
connection, the client retries 9502. It does not switch ports for certificate or
authentication errors, or when client certificates are configured.

| Environment variable | Purpose |
| --- | --- |
| `MINKNOW_HOST`, `MINKNOW_PORT` | Default Manager endpoint |
| `MINKNOW_TLS` | TLS enabled by default; `false` for a deliberately configured plaintext test server |
| `MINKNOW_TRUSTED_CA` | MinKNOW CA certificate file |
| `MINKNOW_AUTH_TOKEN` | Explicit local-auth token |
| `MINKNOW_API_CLIENT_CERTIFICATE_CHAIN`, `MINKNOW_API_CLIENT_KEY` | Client certificate and private key; supply both |
| `MINKNOW_API_USE_LOCAL_TOKEN` | Set to `false` to disable localhost token discovery |
| `PROTOCOL_TOKEN` | Optional protocol-auth metadata |

The minknow shard searches the standard installed MinKNOW CA locations. Local
token discovery is bounded by the same five-second deadline as other single
requests. Remote hosts need explicit authentication and a certificate valid for
the host name used to connect. Credentials and token contents are not displayed
or logged.

## Statistics and compatibility

- Statistics are for the **selected acquisition**, not the whole protocol.
  Calibration and sequencing acquisitions are not automatically combined.
- Estimated bases and basecalled pass/fail bases are distinct. Basecall counts
  can differ from acquired read counts. N50 and distributions identify their
  data source. Pore occupancy and channel time fractions are not live pore counts.
- Only the visible tab's detailed statistics are subscribed to. Basic position
  monitoring continues while viewing historical runs.
- Manager notifications and position user messages have separate sources.
  These are MinKNOW API messages, not operating-system log files.
- Unknown enum values are shown numerically. Unsupported watch/activity RPCs
  fall back to polling. Missing optional statistics disable that information
  without disabling the other panels. Device shows individual API availability.
- Authentication failures, communication failures, absent runs and unsupported
  RPCs are distinguished. Last received data remains visible during failures.
  Quiet streams are normal and do not cause a disconnect indication.
- Protocol phases fall back from `phase_history` to the legacy `phase` field.
  Absent `reported_output_path` falls back to `output_path`; an explicit empty
  reported path stays empty.
- Events are retained in memory up to 2,000 entries; chart series compact long
  histories to at most 1,440 points. Replayed timestamps replace existing data.
  Exiting cancels subscriptions and closes connections. No run history is saved
  locally. MinKNOW restart/reset can limit the history available through its API.

The generated API definitions in the development workspace are 6.10.4. Core 6.x
is the primary target; older versions are supported as far as their available
RPCs permit. Full support for untested releases is not claimed.

| Validation target | Status |
| --- | --- |
| In-process demo | Automated headless UI checks |
| Local fake HTTP/2 MinKNOW server | Compatibility, missing APIs, authentication and selection-race tests |
| Real MinKNOW Core / hardware | Not yet verified |

## Development

```sh
crystal spec
crystal tool format --check src spec tools
crystal run tools/capture.cr -- /tmp/minknow-tui-captures
```

`src/minknow_tui/model.cr` holds normalized state and bounded histories;
`api.cr` owns read-only gRPC access, normalization and subscription lifetimes;
`ui.cr` owns the Crysterm view and navigation; `demo.cr` supplies generated data.
The view does not depend on protobuf types. Dependencies under `lib/` are not
modified by this application.

For a headless demo capture, use Crysterm's built-in configuration, for example:

```sh
CRYSTERM_DUMP=/tmp/minknow-tui.dump bin/minknow-tui --demo
```

See the upstream [MinKNOW API](https://github.com/nanoporetech/minknow_api) and
[Crysterm](https://github.com/crystallabs/crysterm) documentation for API and
terminal rendering details.
