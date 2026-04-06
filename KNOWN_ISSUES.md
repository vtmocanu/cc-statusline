# Known issues

## Width estimation off by a few columns

`statusline.sh` truncates K8s context, branch, and topic based on a bash-string-length estimate (`L1_EST`, `L2_BASE_W`). This estimate is fast (no extra processes spawned per render) but slightly inaccurate:

- The L1 seed includes a "3-char icon safety margin" (`L1_EST=5`), but the recalculation paths after K8s/branch/topic truncation start from `L1_EST=2` and lose that margin.
- The L2 base estimate also undercounts a few separator/space characters.

Net effect: when `STATUSLINE_WIDTH=110`, the actual measured visible columns can be **111-113**. In practice, Claude Code's `cli-truncate` does not drop lines at this boundary on most terminal widths, so the bug is cosmetic. The test harness (`tests/run-tests.sh`) tolerates this with `WIDTH_SLOP=5`.

**Fix path** (deferred, candidate v2.2.0):

1. Replace the bash-arithmetic `L1_EST` / `L2_BASE_W` estimates with a real ANSI-aware character-count measurement, called *before* truncation decisions instead of after.
2. Use a single shared helper for all measurements (today: `measure_cols` in `statusline.sh` and `vis_cols` in `tests/run-tests.sh`).
3. **Replace perl with python3** while you're in there. Perl is currently used for the existing measurement helpers; python3 is the preferred modernisation target (available on macOS by default since 12.3, on every Linux distro, on the Codeberg CI image). Python's `len(str)` after `re.sub('\x1b\[[0-9;]*m', '', s)` is the equivalent of the current perl one-liner. Adds ~20ms startup vs perl's ~10ms, still well under the perception threshold.
4. After the refactor: drop `WIDTH_SLOP` from the test harness, lower `SAFE_WIDTH` closer to the real `cli-truncate` threshold for tighter terminals.

The script renders on every prompt, so any added measurement call increases latency. Today there is one measurement call per render (the trailing line-padding `measure_cols`). The fix would change that to **two** calls per render at most: one to get the full-width estimate before truncation, one to verify after truncation if anything was trimmed. Both can be batched into a single python invocation that takes multiple lines on stdin and emits multiple counts on stdout (same protocol as today's `measure_cols`).

**Workaround for users today**: set `STATUSLINE_WIDTH` to 5 below your terminal's safe width (e.g. `STATUSLINE_WIDTH=105` for a 110-col container).

## `gsed` dependency on macOS

`hooks/session-topic-capture.sh` and `statusline.sh` use `gsed` for ANSI stripping in one place. On macOS without `gsed` (`brew install gnu-sed`), the topic field will quietly degrade to including raw escape sequences. The installer warns about this; the script should ideally fall back to `sed -E` and `tr` instead.

## Tab-title write requires `/dev/tty`

Setting the terminal tab title via `printf '\033]1;%s\007' > /dev/tty` only works when the script has a controlling terminal. Under tmux, screen, and most CI runners it silently no-ops (since v2.0.1, without leaking stderr).
