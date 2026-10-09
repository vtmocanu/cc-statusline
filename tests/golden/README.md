These two Classic frames were captured from `statusline.sh` at main revision
`108227a`, using `01-happy-path.json`, an empty isolated HOME/config, no Git
repository, medium effort, the fixed epoch 1700000000, operational provider
status, a GitHub incident and the update tag v99.0.0. Wide uses 130 columns;
phone uses COLUMNS=40. `classic_golden_tests` reconstructs those inputs and
compares the complete ANSI bytes, including OSC 8 links and caps.
