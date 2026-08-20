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

### The margin does not scale down to phone widths

The 3-column cushion above was sized for a 110-column line, where it is a
rounding error. In the phone tier it is the same 3 columns against a 40-column
line, and East Asian text makes that insufficient: `measure_cols` counts
codepoints, but a CJK character occupies two terminal cells. Measured with an
East-Asian-Width-aware counter, a Japanese directory name at a 32-column
viewport is 29 codepoints and **49 cells**, so the render believes it fits while
the terminal wraps or the container truncates it.

Truncation is correct in codepoints (including under `LC_ALL=C`, where bash's
own `${#s}` counts bytes; see `_clen`/`_head_cp`/`_tail_cp`), so this is
specifically a codepoints-vs-cells gap, not a locale bug. A real fix needs an
EAW-aware `measure_cols`, which would also let `WIDE_GLYPH_MARGIN` drop to 0 for
everyone. Until then, a mostly-CJK project name on a narrow client can still
cost you line 2.

## Viewport detection: `COLUMNS` works, `tput cols` still does not

Claude Code captures the script's stdout, so `tput cols` (and any language-level
terminal-size call) reads the pipe default, not the container. That has not
changed. What did change: since Claude Code v2.1.153 the statusline process is
given `COLUMNS`/`LINES`, and they carry the viewport of the client rendering the
session, not the machine running it. Verified on v2.1.220: the same session shows
`COLUMNS=52 LINES=38` for a render triggered from the Claude mobile app and
`COLUMNS=324 LINES=97` for one triggered at the desk, seconds apart.

Two consequences the script relies on:

- `SAFE_WIDTH` is narrowed to `COLUMNS - 1` when that is smaller than
  `STATUSLINE_WIDTH`; the configured width is only ever a cap, never raised.
- The layout tier is chosen per render, so a session can be wide on the desktop
  and phone-shaped on a phone at the same time.

Residual gap: a client that reports no viewport (or a stale one after a resize
with no session activity) renders at the last known width until the next tick.
`STATUSLINE_LAYOUT` or the `$XDG_CONFIG_HOME/cc-statusline/layout` file overrides
detection in that case.

## `perl` is a hard dependency

UTF-8-aware width measurement uses `perl` (a single helper, `measure_cols`).
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
is sanitized of control bytes first, so a crafted session title cannot inject a
spoofed terminal title.

## OSC 8 hyperlinks on the status icons are terminal-dependent

The service-status icons are wrapped in OSC 8 hyperlinks (GitHub icon to
`githubstatus.com`, Claude icon to `status.claude.com`) so they are clickable;
`STATUSLINE_HYPERLINKS=0` turns this off. Caveats:

- **It is Cmd+click (macOS) / Ctrl+click, not a plain single click.** The
  terminal handles the click, not Claude Code; there is no statusline API for a
  single-click action, and none for triggering an in-app change (e.g. altering
  effort) from a click.
- **Terminal support varies.** Ghostty, iTerm2, Kitty, and WezTerm render OSC 8;
  Terminal.app and many others do not. Unsupported terminals generally swallow
  the escape and show the glyph as plain text, but a few may show it literally,
  in which case `FORCE_HYPERLINK=1` (a Claude Code env var) can help. tmux and
  screen strip OSC sequences unless passthrough is configured.
- **`/tui` fullscreen makes no difference.** Statusline hyperlinks behave the
  same in normal and fullscreen mode; fullscreen's mouse support applies to
  menus and lists, not the statusline.
- **Only fixed glyphs are ever wrapped.** The truncation ladder must never slice
  a hyperlinked segment (that would cut mid-escape), so links stay on the status
  glyphs, which are never truncated. `measure_cols` (and the test harness's
  `vis_cols`/`_strip_ansi`) strip the OSC 8 wrapper, so it is zero-width for
  layout, matching what a terminal actually renders.
