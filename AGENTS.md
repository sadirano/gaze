# gaze - agent guide

gaze renders the Claude Code (and Antigravity) status line: JSON on stdin, one
line on stdout, on every redraw. The details (layout, quota sources, the Codex
routes, peers, the Windows traps) are in `docs/agent-notes.md`: read the
relevant section before changing a subsystem.

Build and test: `zig build -Doptimize=ReleaseFast` (ReleaseFast is required,
not a preference; `x gaze :build` adds `nix --sync-bin`) and `zig build test`
(`x gaze :test`).

## Invariants

- **Every failure degrades to a missing segment**, never to an error or a
  guess. Do not propagate errors upward.
- **No uncached process spawn on the render path.** A spawn costs 25-40 ms,
  about 5x the whole render. Anything spawned goes behind `cache.zig` with its
  own `--<name>-ttl`, caches its failures too, and runs under a deadline.
- **`codex-quota` (the JSON-RPC collector) is never called from a render.**
  The render path only peeks Codex's own transcripts, behind the cache.
- **`collectQuota` is the only place that knows payload shapes.** Each source
  keeps its own `quota-<source>.log`: never merge them. Before parsing a new
  tool, capture a real payload with `GAZE_DUMP_PAYLOAD`.
- **Another tool's level fails toward saying less**: a stale sample is marked
  `~`, and a sample read from a transcript keeps the time it was recorded.
  Past reset reads as 0%, documented as a floor, not a measurement.
- **Payload text is untrusted**: everything rendered goes through
  `Line.color`, which strips controls; every payload float goes through
  `whole` before an integer cast.
- When changing the assembled line, diff against a reference over edge
  payloads, including a sibling dir sharing an alias prefix.
- Cast to unsigned before `{d:0>2}`. The settings `statusLine` path uses
  forward slashes.
