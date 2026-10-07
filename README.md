# gaze

The Claude Code status line, as a native binary.

Claude Code hands a JSON blob on stdin and prints whatever single line comes
back, on every redraw. gaze renders that line in **~7ms**. The PowerShell and
bash scripts it replaces took **~690ms** and **~620ms** on the same machine and
the same payload - and ~95% of that was starting a language runtime in order to
do about a millisecond of arithmetic.

```
(proj) src/core > Opus 5  main *dirty  42% @2h15m / 88% @3d4h  #37%  @1.3M  $1.42  +142/-37  1h15m  15:38
```

| | median | vs gaze |
|---|---|---|
| **gaze** | **7.3ms** | - |
| `statusline.sh` (bash) | 619ms | 85x |
| `statusline.ps1` (PowerShell) | 687ms | 94x |

gaze is built and used on Windows. It compiles and runs elsewhere, with three
differences: the clock prints UTC, the pace glyphs use the plain wall clock
instead of a learned activity profile, and state goes to `$XDG_STATE_HOME/gaze`
or `$HOME/gaze`.

## Install

You need [Zig 0.16](https://ziglang.org/download/).

```
zig build -Doptimize=ReleaseFast
```

ReleaseFast is not a preference: process start time is the whole point, and a
Debug build gives most of it back. The binary lands in `zig-out/bin/` (`gaze.exe`
on Windows). Copy it to a directory on your PATH, then point Claude Code at it in
`~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "gaze"
  }
}
```

Or skip the copy and give the full path, with **forward slashes**, and quoted
if it contains a space:

```json
{
  "statusLine": {
    "type": "command",
    "command": "\"C:/Program Files/gaze/gaze.exe\""
  }
}
```

Backslashes will not work here. Claude Code runs this command through a shell,
so a JSON `"C:\\path\\to.exe"` arrives as `C:\path\to.exe`, the backslashes are
read as escape characters, and you get `C:pathto.exe: command not found` - which
looks like gaze failing rather than a bad path. Forward slashes work in both
POSIX shells and PowerShell, and Windows accepts them for execution.

### With nix

[nix](https://github.com/sadirano/nix) users can register the checkout and let
it keep a copy on PATH:

```
nix gaze <path/to/this/checkout>   # once
x gaze :build                      # ReleaseFast, then nix --sync-bin
```

`:build` ends in `nix --sync-bin`, which installs the `[bin]` export from
`.nix/actions.toml` into `~/.nix/bin`, already on PATH, so the settings entry
above is just `gaze`. Moving the checkout is then one `nix gaze <new path>`.

## Segments

Left to right, each one absent when its data is missing or zero:

- **`(alias) path`** - under a [nix](https://github.com/sadirano/nix) alias
  (`NIX_ALIAS` / `NIX_ALIAS_PATH` in the environment), the alias root collapses
  to its name and only the part below it is spelled out. Otherwise the full
  absolute path.
- **`> model`** - the display name Claude Code sends.
- **`branch clean|*dirty`** - see below.
- **`🦉n`** - opt-in (`--hoot` or `GAZE_HOOT=1`): the unseen count reported by
  `hoot count`, for anyone running the hoot notifier. Hidden when the count is
  zero or hoot is not on PATH.
- **`5h% / 7d%`** - the allowance windows the payload carries, as percentage
  used, with time until reset, red past 80%. Claude Code sends those two;
  Antigravity sends its own buckets and they render the same way. All of them
  are also appended to a quota log; see below. Each level of this tool carries
  a pace glyph: `=` even burn, `-` behind, `+` ahead. Weekly `--` means skipping
  one more 5h window would leave the rest unspendable; weekly `++` means ahead
  by more than a window's worth; 5h `++` means past half and more than 10
  points ahead. "Even" runs on active hours learned from the log, and
  `gaze quota` shows the numbers behind each glyph.
- **`Ag33% X98%`** - how much the OTHER tools have USED, one letter each, so
  free quota elsewhere is a glance rather than a question. See below.
- **`#n%`** - context window used.
- **`@n`** - cached context tokens (`cache_read + cache_creation`), k/M suffixed.
- **`$n`** - session cost, hidden below half a cent so a fresh session shows
  nothing rather than a stuck `$0.00`.
- **`+n/-n`** - lines added and removed this session.
- **`duration`**, **`clock`** - session wall time, and the time of the last redraw.

Text that comes from the payload or the environment has control characters
replaced with `?`, so it can neither break the line nor drive the terminal.

## The expensive answers

Everything above is arithmetic on data already in the payload, except two
things, and they are the entire performance story:

- **is the tree dirty** - means diffing the index against the working tree.
  That work *is* what `git status` costs (~37ms measured). There is no correct
  shortcut.
- **the hoot count**, when turned on - lives in a SQLite db, so reading it means
  spawning `hoot count` (~26ms) or linking SQLite. Linking would be an 11MB
  vendored dependency to save ~25ms on a number that changes maybe once an hour.

Both are therefore **polled on an interval** and cached in the temp dir, keyed
per repo. Between polls they are read from the cache, which is why the typical
render is 7ms. Both can lag by up to their interval - that is the deliberate
trade. A failed poll is cached too, and each spawn has a deadline (1s for git,
0.5s for hoot), so a missing or hung binary costs one attempt per interval and
never stalls the line for long.

The **branch** is not one of these. It is read straight from `.git/HEAD`, which
is a single short file, so it is always current and effectively free.

## Flags

```
--dirty-ttl <seconds>   how often to re-check git      (default 10; 0 = every render)
--no-dirty              never check git; branch alone
--hoot                  show the hoot unseen count (off by default)
--hoot-ttl <seconds>    how often to re-check hoot     (default 10; 0 = every render)
--no-hoot               never check hoot, even with GAZE_HOOT=1
--no-quota-log          write no quota log at all, including Codex's
--source <name>         file quota samples under this tool's name instead of
                        the one inferred from the payload
--no-peers              do not show how much the other tools have used
--pace-ttl <seconds>    how often to re-learn pace inputs from the log
                        (default 600; 0 = every render)
--no-pace               drop the pace glyphs
--codex-ttl <seconds>   how often to re-read Codex's transcripts
                        (default 60; 0 = every render)
-h, --help
```

`GAZE_DIRTY_TTL`, `GAZE_HOOT_TTL`, `GAZE_CODEX_TTL`, `GAZE_PACE_TTL` and
`GAZE_SOURCE` set the same intervals and name, and `GAZE_HOOT=1` turns the hoot
badge on; flags win. Both `--dirty-ttl 5` and `--dirty-ttl=5` are accepted, the
latter because it reads better inside a `settings.json` command string.

Turning the dirty check off (`--no-dirty`) renders in 7.0ms - the same as
leaving it cached, which is the point of the cache.

## The quota log

Run `gaze quota` for a read-only pace report (`--brief` and `--json` are available).

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
| `codex` | written from Codex's transcripts or by `gaze codex-quota` | `5h`, `7d`, `<bucket>.<window>` |

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

A line is written when any window's percentage or reset moves, and otherwise
once every five minutes for as long as the status line keeps redrawing. A busy
session writes about one line per point; an idle one that keeps redrawing still
writes about 300 lines a day. **Nothing rotates or trims the log** - delete it
when you no longer want the history, or pass `--no-quota-log`, which stops every
write gaze makes there. Dedupe state lives per source in `quota-<source>.state`,
which also serves as the lock that keeps concurrent writers from interleaving.

This costs one small read on the common path and no process spawn. As with every
other segment, failure is silent: an unwritable log costs a gap in the history
and never a status line.

`GAZE_DUMP_PAYLOAD=<path>` overwrites that file with the raw stdin on every
render, which is how a new tool's field names get learned in the first place.
The payload holds your working directory and session details, so keep the dump
out of anything you publish.

**Upgrading:** the pre-source log had positional columns
(`<ts> <5h pct> <5h reset> <7d pct> <7d reset>`) and cannot be appended to in
this shape. The first write after the upgrade renames it to `quota-v1.log`
(never over an existing one) and deletes the old `quota.state`; the per-source
files start fresh.

## How much the other tools have used

Every source writes `quota-<source>.log`, so the tools' levels already sit on
disk next to each other. gaze renders the ones this session is not:

```
(gaze) src > Opus 5  main clean  61% @3h6m / 53% @139h56m  Ag33% X98%  16:03
```

`C` is Claude Code, `A` Antigravity, `X` CodeX, and the number is **percentage
used**: `X98%` means Codex has 2% left. Within one allowance the fullest window
binds. A tool metering several independent allowances reports its
**least-used** one and names it: `Ag33%` is Antigravity's Gemini tier at 33%
used, `Ac` its third-party one. Reporting the fullest would send work away from
a tool with a free window, which is the whole point of showing it.

One tail read per peer, no spawn. Two honesty rules, because showing a stale
number as a current one is the failure this project refuses:

- **A window past its reset reads as 0%.** The old level certainly ended; what
  was spent since is unknown, so treat it as a floor.
- **Anything older than 30 minutes renders `~98%`**, because the tool has not
  reported since and nobody knows what it did meanwhile.

`--no-peers` turns the segment off.

### Codex, which is nobody's status line

Claude Code and Antigravity hand gaze a payload on every redraw, so their logs
write themselves. Codex does not - and asking it costs a process spawn and a
daemon round trip, which the render path cannot afford.

It does not have to be asked. Codex already records its own limits: every
session rollout under `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`
carries a `rate_limits` object, at the tail of the file where a positioned read
finds it. So gaze reads the file - the same move as taking the branch from
`.git/HEAD` rather than running `git`.

The sample is filed under the time Codex wrote it, not the time gaze read it,
so a transcript from hours ago renders as hours old (`~`), and it never replaces
a newer line already in the log. It reflects Codex's use on this machine; use of
the same account elsewhere shows up only when this machine's Codex next records
a sample.

The walk is four directory listings and a 64KB read - about 1ms, real next to a
7ms render - so it sits behind `cache.zig` on `--codex-ttl` (default 60s). With
the cache warm the whole peers segment costs about **0.1ms**.

### `gaze codex-quota`: the authoritative refresh

`gaze codex-quota` asks Codex's own app-server for the signed-in account's
limits over JSON-RPC (the
[account/rateLimits/read protocol](https://learn.chatgpt.com/docs/app-server))
and records a sample in `quota-codex.log` through the same writer. It needs only
`codex` on PATH, signed in; it never starts a model turn, and it is never run by
the status line.

```
gaze codex-quota                 one sample, then exit
gaze codex-quota --watch         a sample every five minutes until Ctrl+C
gaze codex-quota --proxy         use a running shared Codex daemon
gaze codex-quota --input r.json  record an already-obtained response
gaze codex-quota --help          every option
```

By default it starts a private stdio app-server and closes it after the read.
These are account-wide limits, not one task's token usage. It prefers
`rateLimitsByLimitId`, keeps additional buckets distinct (as
`<bucket>.<window>`), derives window labels from their durations, and skips
missing percentages. No credentials or account identifiers go into the log. An
unavailable service is an error that leaves the last sample to age; it never
writes a fabricated zero. Nothing installs it as an autostart task.

Run it from your normal user terminal: an agent sandbox may lack access to
Codex's runtime even when it can read project files.

## Development

```
zig build test         # every unit test plus the Codex protocol tests
zig build test-codex   # just the Codex collector's
```

Neither needs a Codex account or the network. `docs/agent-notes.md` covers the
internals, and `AGENTS.md` the rules for changing them.

Every failure path in gaze degrades to a missing segment rather than an error:
a status line that lies about which branch you are on, or that fails to print,
is worse than one that quietly shows less.

## License

MIT - see [LICENSE](LICENSE).
