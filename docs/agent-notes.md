# Agent notes (full)

The complete agent notes. AGENTS.md keeps only the rules that must hold before
any edit; read the section here for the subsystem you are changing.


gaze renders the Claude Code status line. It is a filter: JSON on stdin, one
line on stdout, run on every redraw. See README.md for the segment list.

## The one invariant

**Every failure degrades to a missing segment, never to an error or a guess.**
A status line that fails to print is worse than a short one, and a status line
that shows the wrong branch is worse than one showing no branch. That is why
almost nothing in here returns an error union to the caller - `git.find`,
`dirty.check`, `hoot.count` and `cache.read` all return null/`unknown` on any
problem, and the renderer simply omits that segment.

Do not "improve" this by propagating errors upward.

## Performance is the reason this exists

The shell scripts this replaced took ~620-690ms per render; gaze takes ~7ms.
Before adding anything, know what it costs:

- Arithmetic on the parsed payload is free. Add freely.
- **A process spawn costs 25-40ms on Windows** - roughly 5x the entire rest of
  the render. Only two exist (`git status`, and `hoot count` when the opt-in
  hoot badge is on) and both are behind the interval cache in `cache.zig` for
  exactly that reason. A failed poll is cached like a success, and both run
  under a deadline, so a missing or hung binary cannot cost every render.
- Reading a small file is ~0.1ms. That is why the branch comes from
  `.git/HEAD` directly rather than from `git`.

If you need a new segment that requires spawning something, put it behind
`cache.zig` with its own `--<name>-ttl` flag. Do not add an uncached spawn.

## Layout

| file | holds |
|---|---|
| `src/main.zig` | arg parsing, the render order, all formatting helpers |
| `src/git.zig` | `.git` discovery (dir, and the `gitdir:` file form) + branch from HEAD |
| `src/dirty.zig` | the `git status` call, behind the cache |
| `src/hoot.zig` | the `hoot count` call, behind the cache |
| `src/cache.zig` | `<unix seconds> <value>` one-line cache in the temp dir |
| `src/quota.zig` | appends each source's quota samples to its own durable log, deduped, under a lock on the state file |
| `src/codex_quota.zig` | `gaze codex-quota`: the JSON-RPC collector. Never on the render path |
| `src/codex_peek.zig` | Codex's limits, read from its session transcripts. Cached |
| `src/peers.zig` | the other sources' levels, read from their logs |
| `src/pace.zig` | the pace glyphs: activity profile, schedule and capacity. Cached inputs |
| `src/quota_report.zig` | `gaze quota`, plus the log parser and ratio learner pace reuses |

## Build and test

```
zig build -Doptimize=ReleaseFast   # x gaze :build also runs nix --sync-bin
zig build test                     # x gaze :test
zig build test-codex               # the Codex collector's unit and protocol tests
```

ReleaseFast is not a preference. A Debug build gives back most of the startup
win that is the whole point.

## More than one tool sends quota

gaze is the status line for Claude Code and for Antigravity, and they disagree
about quota: Claude names two fixed windows and reports what is SPENT,
Antigravity hands a map of buckets it names itself and reports what is LEFT.

`collectQuota` in `main.zig` is the only place that knows the difference. It
reduces either shape to `{source, windows[]}`, inverts Antigravity's fraction,
and anchors a `reset_in_seconds` countdown to an absolute timestamp - so the
renderer and `quota.zig` only ever see "how much is gone, by when". A third tool
is a third branch there and nothing else.

Each source owns `quota-<source>.log`, which is what keeps two tools sharing one
gaze from interleaving. Do not merge them back into one file: `tail -1` per
source is the read that matters, and a source column would put a grep in front
of every one of them.

**A payload shape is not guessable from the outside.** Set `GAZE_DUMP_PAYLOAD`
to a path and run one session of the tool: it writes the raw stdin there every
render. Do that before writing a parser, not after.

## Two ways to learn a tool's quota, and when each is allowed

Claude Code and Antigravity are status lines: they hand gaze a payload, so their
logs write themselves for free. Codex is not, which leaves two routes, and the
distinction is load-bearing:

- **`codex_peek.zig` - read what the tool already wrote.** Codex records
  `rate_limits` into its own session rollouts, so gaze reads the tail of the
  newest one. No spawn, no request, and the sample is filed under the record's
  own `timestamp`, never the render time, so an old transcript stays old. A
  record without one is skipped (mtime moves with every later append). A
  sample no newer than the log's last line is dropped, checked under the state
  lock. This is the only route the render path may take, and even it sits behind `cache.zig`
  (`--codex-ttl`) because the walk costs ~1ms.
- **`codex_quota.zig` - ask the tool.** A spawn plus a daemon round trip.
  Authoritative and on demand, and **never callable from a render**. `main.zig`
  dispatches it as the `codex-quota` subcommand before the status line path
  begins, which is what keeps that rule structural rather than a convention.

Both routes name windows through `codex_quota.windowName`, so a sample recorded
by a peek and one recorded by a refresh cannot land under different names. The
two surfaces spell the fields differently - the app-server sends `usedPercent`,
the transcript `used_percent` - and that is the only thing that differs.

Before adding a third tool, look for what it already writes to disk. gaze reads
`.git/HEAD` rather than running `git`, and this is the same move.

## gaze quota

`gaze quota` is a read-only, explicit report over each source's own
`quota-<source>.log`. It computes the remaining 5h windows, learns weekly cost
per 5h point from log history, and prints a table, `--brief`, or `--json`.
`--hours` adjusts active time per day. `GAZE_QUOTA_NOW` overrides the clock for
tests. Missing logs appear as unsampled buckets; this command is never called
from the status-line render path (its log parser and ratio learner are, through
`pace.zig`, behind the pace cache).

## Pace glyphs

`src/pace.zig` is the one evaluator behind both the status line glyph and the
`schedule` line of `gaze quota`. Never compute a glyph anywhere else.

- **Two activity models, on purpose.** The schedule ("even burn") weights each
  hour by how often it saw use. An hour counts once per day, never once per
  sample, because the log writes one line per point moved. Capacity (the `--`
  test) asks when you *could* spend, so it takes the profile's busiest
  `QUOTA_ACTIVE_HOURS` hours as fully available. Pricing capacity by past use
  made a quiet week read as unrecoverable. `--` wins when the two disagree.
- **Cache history, never the answer.** Only the ratio and profile are cached
  (`gaze-pace-*` in the temp dir, `--pace-ttl`). The glyph is recomputed from
  the payload on every render, so it cannot outlive a reset.
- A reset already passed, or an implausible level, means no glyph. Never guess
  about the new window.

## Showing another tool's level honestly

`peers.zig` renders a source's log that this session did not write. A number
from another process is stale by construction, so two rules keep it from
lying: a window past its `reset` reads as 0% (a floor: whatever was spent since
is unknown), and a sample older than `stale_after_s` is marked `~`. The number
is percentage USED, and a tool with several independent allowances shows its
least-used one. If you add a third display rule, make
sure it also fails towards "say less" rather than "guess".

## Changing the rendered line

The unit tests cover the formatting helpers (cost grouping, token suffixes,
duration units, the alias-relative path, HEAD parsing, cache staleness). They do
not cover the assembled line.

For that, diff against a reference implementation over a spread of payloads -
zero cost, sub-cent cost, missing `rate_limits`, a detached HEAD, a path outside
any alias, a sibling directory sharing an alias prefix. The last one matters:
`/srv/proj/owl-extra` must not render as a subdirectory of alias root
`/srv/proj/owl`, and a naive prefix check gets it wrong.

## Windows notes

gaze is developed and used on Windows. It builds elsewhere, but off Windows the
clock is UTC, pace learns no activity profile (it falls back to the wall
clock), and the default state directory is `$XDG_STATE_HOME/gaze` or
`$HOME/gaze`.

- Local wall-clock time comes from `GetLocalTime`, to avoid carrying a timezone
  database for two digits. Other platforms fall back to UTC.
- `{d:0>2}` on a **signed** integer formats with an explicit `+`. Cast to
  unsigned before zero-filling, or you get `$1.+42`.
- The `statusLine` command in settings.json is run **through a shell**, so the
  path must use forward slashes. A backslash path reaches the shell as escape
  characters and collapses (`C:\a\b.exe` -> `C:ab.exe`, "command not found"),
  which presents as "gaze is broken" rather than as a config error.

## Testing changes to the rendered line

Beware two traps that make a working binary look broken:

- **Shell-mangled test payloads.** `echo '{"cwd":"C:\\x"}'` emits `C:\x` under
  some shells, which is invalid JSON, and gaze correctly prints `> ?`. Build
  payloads with a JSON library or use forward slashes in test paths.
- **Git Bash path translation.** MSYS rewrites POSIX-looking arguments and env
  vars when handing them to native binaries, so `NIX_ALIAS_PATH=/srv/x` may not
  arrive as written. `MSYS2_ARG_CONV_EXCL='*'` disables it for a test run.
