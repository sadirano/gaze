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
- **`5h% / 7d%`** - rate limit windows with time until reset, red past 80%.
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
-h, --help
```

`GAZE_DIRTY_TTL` and `GAZE_HOOT_TTL` set the same intervals; flags win. Both
`--dirty-ttl 5` and `--dirty-ttl=5` are accepted, the latter because it reads
better inside a `settings.json` command string.

Turning both off (`--no-dirty --no-hoot`) renders in 7.0ms - the same as leaving
them cached, which is the point of the cache.

## Install

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
