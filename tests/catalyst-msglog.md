# Catalyst message-log regression

`catalyst-msglog.m` is our own executable, not an Apple application. Build it against
our source-built runtime. Run `inventory` with `CATALYST_MSGLOG=1`, then `ring` with
`CATALYST_MSGLOG=ring`, both with `CATALYST_MSGLOG_INVENTORY` naming an inventory of
only source-built runtime images. Exclude the test executable itself. Run `none`
with an absent inventory to verify fail-closed behavior. Require both process exit
zero and `HARNESS done: ... checks, 0 failed`.

Generate it with `python3 -I tools/catalyst-msglog-inventory.py ROOT OUT` from
an entirely source-built ROOT. The helper is shipped in this repository; the
inventory is a build-side input, not automatically installed by libobjc. Its
lines are `<byte-size> <absolute guest path>`; use canonical paths and regenerate
after replacing images. Path plus size is an operational identity check, not an
authenticity check against same-path/same-size replacement. Never generate an
inventory from a tree containing copied Apple binaries.

`python3 tests/catalyst-diagnostics-native.py OUT` generates a Ninja fixture. Build
with `ninja -C OUT -j6` under the host build slot; run `OUT/diagnostic-test FIXTURES`
with a fresh existing FIXTURES directory. It extracts our real secure_open and
ring helpers. It checks symlink, hardlink, wrong-mode, wrong-owner and directory
refusals without truncating their targets, plus ring overflow/order and exclusions.
The ownership metadata is mocked; this native fixture cannot certify Objective-C
cache behavior. The `ring` guest mode tests repeated real sends without cache fill.
All filesystem fixtures are preserved.
