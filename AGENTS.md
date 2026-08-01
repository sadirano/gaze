# gaze - agent guide

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
  the render. Only two exist (`git status`, `hoot count`) and both are behind
  the interval cache in `cache.zig` for exactly that reason.
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

## Build and test

```
x gaze :build     # ReleaseFast + nix --sync-bin
x gaze :test      # unit tests
x gaze :demo      # render a sample payload to look at
```

ReleaseFast is not a preference. A Debug build gives back most of the startup
win that is the whole point.

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

- Local wall-clock time comes from `GetLocalTime`, to avoid carrying a timezone
  database for two digits. Other platforms fall back to UTC.
- `{d:0>2}` on a **signed** integer formats with an explicit `+`. Cast to
  unsigned before zero-filling, or you get `$1.+42`.
