#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
fail(){ echo "not ok - $1" >&2; exit 1; }; pass(){ echo "ok - $1"; }
for c in awk git jq stat sha256sum mktemp date od tr sort install cmp flock find sed; do command -v "$c" >/dev/null || fail "missing $c"; done
repo="$T/repo"; mkdir -p "$repo" "$T/home" "$T/config/run-codex/projects" "$T/config/run-codex/lanes/collab-project"
git -C "$repo" init -q -b main; printf '%s\n' base > "$repo/payload"; git -C "$repo" add payload
git -C "$repo" -c user.name=smoke -c user.email=smoke.invalid commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"; git -C "$repo" worktree add -q -b review "$T/review"
printf 'path=%s\nprofile=generic\nclojure_mcp=off\nlane=default\nstate=isolated\nagent=codex\n' "$repo" > "$T/config/run-codex/projects/collab-project"
printf 'path=%s\nprofile=generic\nclojure_mcp=off\nlane=review\nstate=isolated\nagent=codex\n' "$T/review" > "$T/config/run-codex/lanes/collab-project/review"
run(){ env HOME="$T/home" XDG_CONFIG_HOME="$T/config" "$ROOT/bin/codex-collab" "$@"; }
h="$(run --help)"; for c in send deliver list read ack; do [[ "$h" == *"$c"* ]] || fail "help omits $c"; done
body="$T/body"; printf '%s\n' question > "$body"
if run send collab-project --lane default --to review --kind question --revision "${base:0:12}" --body-file "$body" >/dev/null 2>&1; then fail abbreviated; fi
run send collab-project --lane default --to review --kind question --revision "$base" --body-file "$body" > "$T/id"
id="$(<"$T/id")"; out="$T/config/run-codex/state/collab-project/default/collaboration/outbox"; in="$T/config/run-codex/state/collab-project/review/collaboration/inbox"
[[ -f "$out/$id.json" && ! -e "$in/$id.json" ]] || fail "send touched recipient inbox"
run deliver collab-project --lane default "$id" >/dev/null; run deliver collab-project --lane default "$id" >/dev/null
run read collab-project --lane review "$id" | jq -e --arg id "$id" '.id==$id' >/dev/null
run list collab-project --lane review | grep -F "$id" | grep -F PENDING >/dev/null; run ack collab-project --lane review "$id" >/dev/null; run ack collab-project --lane review "$id" >/dev/null
run list collab-project --lane review | grep -F "$id" | grep -F ACKED >/dev/null
rm "$T/config/run-codex/state/collab-project/review/collaboration/acks/$id.json"
cp "$in/$id.json" "$T/original.json"
jq '.body="tampered without updating hash"' "$in/$id.json" > "$T/tampered.json"
mv "$T/tampered.json" "$in/$id.json"
if run read collab-project --lane review "$id" >/dev/null 2>&1; then fail body-hash-tamper; fi
cp "$T/original.json" "$in/$id.json"
tmp="$T/conflict.json"; jq '.body="conflicting body"' "$in/$id.json" > "$tmp"
bh="$(jq -j '.body' "$tmp" | sha256sum | awk '{print $1}')"; jq --arg h "$bh" '.body_sha256=$h' "$tmp" > "$in/$id.json"
if run deliver collab-project --lane default "$id" >/dev/null 2>&1; then fail conflict; fi
find "$T/config/run-codex/state/collab-project/review/collaboration/quarantine" -name "$id.conflict.*.json" -print -quit | grep . >/dev/null || fail quarantine
printf dirty > "$T/review/dirty"; if run send collab-project --lane review --to default --kind result-available --revision "$base" --body-file "$body" >/dev/null 2>&1; then fail dirty; fi; rm "$T/review/dirty"
printf '%*s' 65537 x > "$T/large"; if run send collab-project --lane default --to review --kind question --revision "$base" --body-file "$T/large" >/dev/null 2>&1; then fail oversized; fi
ln -s "$body" "$T/link"; if run send collab-project --lane default --to review --kind question --revision "$base" --body-file "$T/link" >/dev/null 2>&1; then fail symlink; fi
if run send collab-project --lane default --to review --kind question --revision \
    0000000000000000000000000000000000000000 --body-file "$body" >/dev/null 2>&1; then fail stale; fi
printf '{"bad":true}\n' > "$in/bad.json"; if run list collab-project --lane review >/dev/null 2>&1; then fail malformed; fi; rm "$in/bad.json"
printf '{"version":1}\n' > "$T/config/run-codex/state/collab-project/review/collaboration/acks/$id.json"; if run list collab-project --lane review >/dev/null 2>&1; then fail invalid-ack; fi; rm "$T/config/run-codex/state/collab-project/review/collaboration/acks/$id.json"
mismatch_a="$T/mismatch-a"; mismatch_b="$T/mismatch-b"
mkdir -p "$mismatch_a" "$mismatch_b"
git -C "$mismatch_a" init -q -b main; printf a > "$mismatch_a/file"; git -C "$mismatch_a" add file
git -C "$mismatch_a" -c user.name=smoke -c user.email=smoke.invalid commit -qm a
git -C "$mismatch_b" init -q -b main; printf b > "$mismatch_b/file"; git -C "$mismatch_b" add file
git -C "$mismatch_b" -c user.name=smoke -c user.email=smoke.invalid commit -qm b
mkdir -p "$T/config/run-codex/lanes/mismatch"
printf 'path=%s\nprofile=generic\nclojure_mcp=off\nlane=default\nstate=isolated\nagent=codex\n' "$mismatch_a" > "$T/config/run-codex/projects/mismatch"
printf 'path=%s\nprofile=generic\nclojure_mcp=off\nlane=review\nstate=isolated\nagent=codex\n' "$mismatch_b" > "$T/config/run-codex/lanes/mismatch/review"
mkdir -p "$T/config/run-codex/state/mismatch/default/collaboration/outbox"
mismatch_id=0123456789abcdef0123456789abcdef
mismatch_body_hash="$(printf '%s' mismatch | sha256sum | awk '{print $1}')"
jq -n --arg id "$mismatch_id" --arg hash "$mismatch_body_hash" \
    '{version:1,id:$id,project:"mismatch",from_lane:"default",to_lane:"review",kind:"question",revision:"0000000000000000000000000000000000000000",created_at:"2026-01-01T00:00:00Z",body_sha256:$hash,body:"mismatch"}' \
    > "$T/config/run-codex/state/mismatch/default/collaboration/outbox/$mismatch_id.json"
if run deliver mismatch --lane default "$mismatch_id" >/dev/null 2>&1; then fail git-metadata-mismatch; fi
grep -Fq 'share project Git metadata' <(run deliver mismatch --lane default "$mismatch_id" 2>&1) || fail mismatch-diagnostic
outside="$T/outside-mailbox"; mkdir -p "$outside"; printf outside > "$outside/marker"
collab_state="$T/config/run-codex/state/collab-project/review/collaboration"
rm -rf "$collab_state"; ln -s "$outside" "$collab_state"
for operation in "list collab-project --lane review" \
    "read collab-project --lane review $id" \
    "deliver collab-project --lane default $id"; do
    if run $operation >/dev/null 2>&1; then fail "symlinked mailbox accepted by $operation"; fi
done
[[ "$(<"$outside/marker")" == outside ]] || fail "symlinked mailbox mutated outside state"
pass "collaboration mailbox lifecycle and validation"
