# Known issues

## Width: codepoints vs. terminal cells (wide glyphs)

The width off-by-2 that used to live here is **resolved**. `statusline.sh` no longer
estimates line width in bash (`L1_EST` / `L2_BASE_W` are gone). Both lines, every
line-2 candidate (rate-detail tiers, cache, service icon), and the post-truncation
result are measured with a single ANSI-aware `measure_cols` (perl) helper, the same
codepoint count the test harness uses. Truncation targets `SAFE_WIDTH` exactly, so
the harness now runs with `WIDTH_SLOP=0`.

Residual caveat: `measure_cols` counts Unicode **codepoints**, but a terminal may
render a Nerd Font glyph (folder, git, k8s, model, clock, cache icons) as **two
cells**. That is genuinely terminal- and font-dependent and not knowable from the
script. To stay safe on terminals that render those glyphs double-width, truncation
targets `SAFE_WIDTH - WIDE_GLYPH_MARGIN` (default 3). Power users on a known
mono-width Nerd Font can reclaim those columns with `STATUSLINE_GLYPH_MARGIN=0`.

A perfect fix would need a wcwidth-style table that knows each glyph's cell count
per terminal; that is not worth the fragility, so the small documented margin
stands in for it.

**Workaround for tighter terminals**: set `STATUSLINE_WIDTH` a few columns below
your terminal's safe width (e.g. `STATUSLINE_WIDTH=105` for a 110-col container).

## `perl` is a hard dependency

ANSI/OSC/control stripping, UTF-8-aware width measurement, and topic
sanitization all use `perl` (a single helper, `measure_cols`, plus `_strip_ctl`).
This replaced the earlier macOS-only `gsed` dependency, so `gsed`/`gnu-sed` is no
longer required on any platform. `perl` ships by default on macOS and every Linux
distro and the GitHub Actions runner image, so this is a safe baseline; the
installer checks for it. (KNOWN_ISSUES previously floated migrating to `python3`;
we kept `perl` deliberately, since it was already the hard dependency and is ~2x
faster to start than `python3` for these tiny one-shot invocations.)

## Account detection for the rate-limits cache scans ancestor process envs

The shared rate-limits cache is keyed per account so `CLAUDE_CODE_OAUTH_TOKEN=...
claude` sessions don't cross-pollute the default keychain account's bars. Claude
Code consumes that variable before spawning subprocesses and the statusline stdin
JSON carries no account identifier, so the only available signal is the exec-time
environment of the ancestor `claude` process: `/proc/PID/environ` on Linux,
`ps eww` on macOS/BSD (both owner-readable only). Caveats:

- If a launcher breaks the ancestor chain (more than 6 hops between the
  statusline and `claude`, or a daemonized intermediary reparented to PID 1) or
  the platform hides process args, token sessions silently fall back to the
  shared unsuffixed cache: the pre-keying behavior, not a crash.
- The token itself never reaches disk or the cache filename; only a 32-bit
  `cksum` hash does. Different tokens for the *same* account get separate caches
  (less sharing than possible, never wrong values).
- `CC_STATUSLINE_RL_KEY=<label>` overrides detection entirely for setups the
  scan can't see through; empty forces the shared cache.

Setting the terminal tab title via `printf '\033]1;%s\007' > /dev/tty` only works
when the script has a controlling terminal. Under tmux, screen, and most CI
runners it silently no-ops (since v2.0.1, without leaking stderr). The title text
is sanitized of control bytes first, so a crafted session topic cannot inject a
spoofed title.
