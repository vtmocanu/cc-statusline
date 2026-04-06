# Known issues

## Width estimation off by a few columns

`statusline.sh` truncates K8s context, branch, and topic based on a bash-string-length estimate (`L1_EST`, `L2_BASE_W`). This estimate is fast (no perl per render) but slightly inaccurate:

- The L1 seed includes a "3-char icon safety margin" (`L1_EST=5`), but the recalculation paths after K8s/branch/topic truncation start from `L1_EST=2` and lose that margin.
- The L2 base estimate also undercounts a few separator/space characters.

Net effect: when `STATUSLINE_WIDTH=110`, the actual measured visible columns can be **111-112**. In practice, Claude Code's `cli-truncate` does not drop lines at this boundary on most terminal widths, so the bug is cosmetic. The test harness (`tests/run-tests.sh`) tolerates this with `WIDTH_SLOP=5`.

**Fix path** (deferred): rebuild line 1 and line 2 with a single perl ANSI-aware width pass during truncation, instead of the bash-string estimate. This requires care: the script renders on every prompt and an extra perl invocation per truncation step adds latency.

**Workaround**: set `STATUSLINE_WIDTH` to 5 below your terminal's safe width (e.g. `STATUSLINE_WIDTH=105` for a 110-col container).

## `gsed` dependency on macOS

`hooks/session-topic-capture.sh` and `statusline.sh` use `gsed` for ANSI stripping in one place. On macOS without `gsed` (`brew install gnu-sed`), the topic field will quietly degrade to including raw escape sequences. The installer warns about this; the script should ideally fall back to `sed -E` and `tr` instead.

## Tab-title write requires `/dev/tty`

Setting the terminal tab title via `printf '\033]1;%s\007' > /dev/tty` only works when the script has a controlling terminal. Under tmux, screen, and most CI runners it silently no-ops (since v2.0.1, without leaking stderr).
