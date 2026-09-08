# 0001 Spinel is pinned by commit

Date: 2026-09-08. Status: accepted.

## Context

Spinel has no releases and its master moves at roughly twenty commits a day. The melee project
(`/Users/jamie/orca/workspaces/chips/spike`) has already catalogued the dialect traps against one commit.

## Decision

`vendor/spinel` is a git submodule pinned to `b2cbeba390764bc7c395800672f1228043e9e940` (2026-09-05), the
same commit melee uses, so its trap list applies verbatim. Rebases are deliberate, one commit titled
"Rebase Spinel to <sha>", with `docs/spinel.md` updated in the same change. Never track master.

## Consequences

- `mise run spinel` builds the compiler from the submodule; `scripts/check.sh` uses that build.
- A rebase that breaks a parity test is a finding to record, not a surprise.
