# gaze

The Claude Code status line, as a native binary.

Claude Code hands a JSON blob on stdin and prints whatever single line comes
back, on every redraw. gaze renders that line in **~7ms**. The PowerShell and
bash scripts it replaces took **~690ms** and **~620ms** on the same machine and
the same payload - and ~95% of that was starting a language runtime in order to
do about a millisecond of arithmetic.

```
(proj) src/core > Opus 5  main *dirty  🦉3  42% @2h15m / 88% @3d4h  #37%  @1.3M  $1.42  +142/-37  1h15m  15:38
```

| | median | vs gaze |
|---|---|---|
| **gaze** | **7.3ms** | - |
| `statusline.sh` (bash) | 619ms | 85x |
| `statusline.ps1` (PowerShell) | 687ms | 94x |

## Segments

Left to right, each one absent when its data is missing or zero:

- **`(alias) path`** - the nix alias root collapses to its name, so only the
  part below it is spelled out. Outside a nix session, or under no alias, the
  full absolute path. Uses `NIX_ALIAS` / `NIX_ALIAS_PATH`, which nix already
  exports into every `o` and `x` session.
- **`> model`** - the display name Claude Code sends.
- **`branch clean|*dirty`** - see below.
- **`🦉n`** - unseen hoot notifications; hidden when the inbox is empty or hoot
  is not installed.
- **`5h% / 7d%`** - the allowance windows the payload carries, with time until
  reset, red past 80%. Claude Code sends those two; Antigravity sends its own
  buckets and they render the same way. All of them are also appended to a quota
  log; see below.
- **`#n%`** - context window used.
- **`@n`** - cached context tokens (`cache_read + cache_creation`), k/M suffixed.
- **`$n`** - session cost, hidden below half a cent so a fresh session shows
  nothing rather than a stuck `$0.00`.
- **`+n/-n`** - lines added and removed this session.
- **`duration`**, **`clock`** - session wall time, and the time of the last redraw.

## The two expensive answers

Everything above is arithmetic on data already in the payload, except two
things, and they are the entire performance story:

- **is the tree dirty** - means diffing the index against the working tree.
  That work *is* what `git status` costs (~37ms measured). There is no correct
  shortcut.
- **the hoot count** - lives in a SQLite db, so reading it means spawning
  `hoot count` (~26ms) or linking SQLite. Linking would be an 11MB vendored
  dependency to save ~25ms on a number that changes maybe once an hour.

Both are therefore **polled on an interval** and cached in the temp dir, keyed
per repo. Between polls they are read from the cache, which is why the typical
render is 7ms. Both can lag by up to their interval - that is the deliberate
trade.

The **branch** is not one of these. It is read straight from `.git/HEAD`, which
is a single short file, so it is always current and effectively free.

## Flags

```
--dirty-ttl <seconds>   how often to re-check git      (default 10; 0 = every render)
--hoot-ttl <seconds>    how often to re-check hoot     (default 10; 0 = every render)
--no-dirty              never check git; branch alone
--no-hoot               never check hoot; drop the badge
--no-quota-log          do not append quota samples to the log
--source <name>         file quota samples under this tool's name instead of
                        the one inferred from the payload
-h, --help
```

`GAZE_DIRTY_TTL`, `GAZE_HOOT_TTL` and `GAZE_SOURCE` set the same three; flags
win. Both
`--dirty-ttl 5` and `--dirty-ttl=5` are accepted, the latter because it reads
better inside a `settings.json` command string.

Turning both off (`--no-dirty --no-hoot`) renders in 7.0ms - the same as leaving
them cached, which is the point of the cache.

## The quota log

An allowance that does not roll over makes pace matter as much as level - and the
payload only ever carries the level. Each render therefore appends its sample to
`%LOCALAPPDATA%\gaze\quota-<source>.log` (`GAZE_QUOTA_DIR` overrides the
directory).

`<source>` is the tool that sent the payload, so two tools sharing one gaze never
interleave and `ls quota-*.log` says which have ever reported:

| source | recognised by | windows |
|---|---|---|
| `claude` | `rate_limits.{five_hour,seven_day}` | `5h`, `7d` |
| `agy` | a `quota` map of buckets | whatever the buckets are called |

`--source <name>` (or `GAZE_SOURCE`) overrides the inferred name. A line is a
unix timestamp followed by one field per allowance window, tab separated:

```
1789924544      5h=4@1789942200 7d=47@1790434800
1789925385      gemini-3-pro=27 fast=50@1789939785
```

Each field is `<window>=<used percent>` plus `@<reset unix>` when the payload
said one. Windows keep the payload's own order, a window the payload did not
report is simply absent, and the names are cut to 32 characters of
`[A-Za-z0-9._-]` - so a bucket id can never split a field or put a non-ASCII
byte in the log. Antigravity reports what is *left*; gaze inverts it, so the log
only ever holds what is gone.

`tail -1 quota-claude.log` is therefore the whole current picture for that tool,
with no filtering.

A line is written when any window's percentage moves, and otherwise at most once
every five minutes, so an idle redraw loop writes nothing and a busy one writes
about one line per point. Dedupe state lives per source in
`quota-<source>.state`.

This costs one small read on the common path and no process spawn. As with every
other segment, failure is silent: an unwritable log costs a gap in the history
and never a status line.

`GAZE_DUMP_PAYLOAD=<path>` writes the raw stdin there on every render, which is
how a new tool's field names get learned in the first place.

**Upgrading:** the pre-source log had positional columns
(`<ts> <5h pct> <5h reset> <7d pct> <7d reset>`) and cannot be appended to in
this shape. The first write after the upgrade renames it to `quota-v1.log` and
starts the per-source files fresh. Nothing is lost; old history just reads with
the old rules.

## Install

### Codex account quota

`x gaze :codex-quota` reads the signed-in Codex account's limits and records a
sample in `quota-codex.log`. `x gaze :codex-quota-watch` repeats every five
minutes until stopped (Ctrl+C). Build gaze first. The collector needs Python 3
and `codex` on PATH, signed in with the same ChatGPT account as the desktop app.
It starts a private stdio app-server and closes it after the read. Pass
`-- --proxy` to use an existing shared Codex daemon instead. Run it from your
normal user terminal: an agent sandbox may lack access to Codex's runtime even
when it can read project files.

The bridge uses the official
[account/rateLimits/read protocol](https://learn.chatgpt.com/docs/app-server),
not a model turn. These are account-wide limits, not this task's token usage.
It prefers `rateLimitsByLimitId`, keeps additional buckets distinct, derives
window labels from their durations, and skips missing percentages. It passes
the normalized quota map (`used_percentage`, optional `reset_time`) to gaze with
`--source codex`; gaze owns the log format
and deduplication. No credentials or account identifiers go into the quota log.
An unavailable service produces an error and leaves the last sample to age;
it never writes a fabricated zero. `--input response.json` can record an
already-obtained response, and `--directory PATH` isolates a test's logs.

Display it with `x han :quota-codex`. The collector and panel are independent;
neither action installs an autostart task. These optional integration actions
require Codex and Python; normal gaze builds and status-line rendering do not.
`x gaze :test-codex` runs the bridge
tests without an account or network.

### Claude status line

Register the project with [nix](https://github.com/sadirano/nix), then build:

```
nix gaze <path/to/this/checkout>   # once
x gaze :build                      # ReleaseFast + nix --sync-bin
```

`:build` ends in `nix --sync-bin`, which installs the `[bin]` export from
`.nix/actions.toml` into `~/.nix/bin` - already on PATH. Point Claude Code at
the name in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "gaze"
  }
}
```

nix keeps the alias and the `~/.nix/bin` copy in step, so the config only needs
the name. Moving this checkout is then one `nix gaze <new path>`, with nothing
else to update.

### Without nix

Point at the built binary directly, using **forward slashes**:

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:/path/to/gaze/zig-out/bin/gaze.exe"
  }
}
```

Backslashes will not work here. Claude Code runs this command through a shell,
so a JSON `"C:\\path\\to.exe"` arrives as `C:\path\to.exe`, the backslashes are
read as escape characters, and you get `C:pathto.exe: command not found` - which
looks like gaze failing rather than a bad path. Forward slashes work in both
POSIX shells and PowerShell, and Windows accepts them for execution.

Note that this path points inside `zig-out`, so it needs updating whenever the
checkout moves.

## Development

```
x gaze :test       # zig build test
x gaze :demo       # render a sample payload, coloured and stripped
```

Every failure path in gaze degrades to a missing segment rather than an error:
a status line that lies about which branch you are on, or that fails to print,
is worse than one that quietly shows less.
