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
generate_records(){
    local template="$1" destination="$2" first="$3" last="$4"
    awk -v destination="$destination" -v first="$first" -v last="$last" '
        { template[NR] = $0 }
        END {
            for (n = first; n <= last; n++) {
                id = sprintf("%032x", n)
                file = destination "/" id ".json"
                for (line_number = 1; line_number <= NR; line_number++) {
                    line = template[line_number]
                    if (line ~ /^  "id":/) {
                        line = "  \"id\": \"" id "\","
                    }
                    print line > file
                }
                close(file)
            }
        }
    ' "$template"
}
h="$(run --help)"; for c in send deliver list read ack prune; do [[ "$h" == *"$c"* ]] || fail "help omits $c"; done
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

body_exact="$T/body-exact"
awk 'BEGIN { for (i = 0; i < 32768; i++) printf "x\n" }' > "$body_exact"
[[ "$(stat -c %s "$body_exact")" == 65536 ]] || fail exact-body-fixture
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$body_exact" >/dev/null || fail exact-body-rejected

delivered_dir="$T/config/run-codex/state/collab-project/default/collaboration/delivered"
acks_dir="$T/config/run-codex/state/collab-project/review/collaboration/acks"
bulk_completed="$T/bulk-completed"
bulk_unresolved="$T/bulk-unresolved"
mkdir -p "$delivered_dir" "$acks_dir" "$bulk_completed" "$bulk_unresolved"
generate_records "$T/original.json" "$bulk_completed" 1 1000
cp -- "$bulk_completed"/*.json "$out/"
cp -- "$bulk_completed"/*.json "$in/"
sha256sum "$bulk_completed"/*.json | while read -r digest file; do
    extra_id="${file##*/}"
    extra_id="${extra_id%.json}"
    printf '{"version":1,"message_id":"%s","message_sha256":"%s","delivered_at":"2026-01-01T00:00:00Z"}\n' \
        "$extra_id" "$digest" > "$delivered_dir/$extra_id.json"
    printf '{"version":1,"message_id":"%s","message_sha256":"%s","acknowledged_at":"2026-01-01T00:00:00Z"}\n' \
        "$extra_id" "$digest" > "$acks_dir/$extra_id.json"
done
printf '%s\n' pending > "$T/pending-body"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/capacity-id" || fail "delivered outbox records consumed pending limit"
capacity_id="$(<"$T/capacity-id")"
run deliver collab-project --lane default "$capacity_id" >/dev/null ||
    fail "acknowledged inbox records consumed pending limit"
generate_records "$T/original.json" "$bulk_unresolved" 1001 1999
cp -- "$bulk_unresolved"/*.json "$out/"
cp -- "$bulk_unresolved/$(printf '%032x' 1001).json" "$in/"
if run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" >/dev/null 2>&1; then fail "unresolved outbox records did not consume pending limit"; fi
rm -- "$out"/0000000000000000000000000000*.json
rm -- "$in"/0000000000000000000000000000*.json
rm -- "$delivered_dir"/0000000000000000000000000000*.json
rm -- "$acks_dir"/0000000000000000000000000000*.json

atomic_body="$T/atomic-body"; printf atomic > "$atomic_body"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$atomic_body" > "$T/atomic-id"
atomic_id="$(<"$T/atomic-id")"; atomic_source="$out/$atomic_id.json"
atomic_bin="$T/atomic-bin"; mkdir -p "$atomic_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${3:-}" == -- && "${4:-}" == "'$atomic_source'" ]]; then' \
    '    jq ''.to_lane="default"'' "$4" > "$4.replaced"' \
    '    mv -- "$4.replaced" "$4"' \
    'fi' \
    'exec /bin/install "$@"' > "$atomic_bin/install"
chmod 755 "$atomic_bin/install"
if PATH="$atomic_bin:$PATH" run deliver collab-project --lane default "$atomic_id" >/dev/null 2>&1; then
    fail "delivery accepted an atomically replaced source"
fi
[[ ! -e "$in/$atomic_id.json" ]] || fail "replaced source was published to inbox"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/enumeration-id"
enumeration_id="$(<"$T/enumeration-id")"
find_bin="$T/find-bin"; mkdir -p "$find_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "'$out'" || "${1:-}" == "'$in'" ]]; then' \
    '    exit 42' \
    'fi' \
    'exec /usr/bin/find "$@"' > "$find_bin/find"
chmod 755 "$find_bin/find"
out_records=("$out"/*.json)
out_count="${#out_records[@]}"
if PATH="$find_bin:$PATH" run send collab-project --lane default --to review \
    --kind question --revision "$base" --body-file "$T/pending-body" \
    >/dev/null 2> "$T/find-send.err"; then
    fail "send accepted a partial mailbox enumeration"
fi
grep -Fq 'Cannot enumerate collaboration mailbox' "$T/find-send.err" ||
    fail "send omitted its mailbox enumeration diagnostic"
out_records=("$out"/*.json)
[[ "${#out_records[@]}" == "$out_count" ]] ||
    fail "failed capacity enumeration published an outbox record"
if PATH="$find_bin:$PATH" run deliver collab-project --lane default \
    "$enumeration_id" >/dev/null 2> "$T/find-deliver.err"; then
    fail "delivery accepted a partial mailbox enumeration"
fi
grep -Fq 'Cannot enumerate collaboration mailbox' "$T/find-deliver.err" ||
    fail "delivery omitted its mailbox enumeration diagnostic"
[[ ! -e "$in/$enumeration_id.json" ]] ||
    fail "failed capacity enumeration published an inbox record"
if PATH="$find_bin:$PATH" run list collab-project --lane review \
    >/dev/null 2> "$T/find-list.err"; then
    fail "list accepted a partial mailbox enumeration"
fi
grep -Fq 'Cannot enumerate collaboration mailbox' "$T/find-list.err" ||
    fail "list omitted its mailbox enumeration diagnostic"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/prune-pre-race-id"
prune_pre_race_id="$(<"$T/prune-pre-race-id")"
run deliver collab-project --lane default "$prune_pre_race_id" >/dev/null
prune_pre_race_record="$out/$prune_pre_race_id.json"
prune_pre_race_marker="$delivered_dir/$prune_pre_race_id.json"
prune_pre_replacement="$T/prune-pre-replacement.json"
jq '.body="pre-move replacement"' "$prune_pre_race_record" > "$T/prune-pre-body.json"
prune_pre_body_hash="$(jq -j '.body' "$T/prune-pre-body.json" | sha256sum | awk '{print $1}')"
jq --arg hash "$prune_pre_body_hash" '.body_sha256=$hash' \
    "$T/prune-pre-body.json" > "$prune_pre_replacement"
prune_pre_bin="$T/prune-pre-bin"; mkdir -p "$prune_pre_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == -T && "${2:-}" == -- && "${3:-}" == "'$prune_pre_race_marker'" ]]; then' \
    '    /bin/mv "$@"' \
    '    cp -- "'$prune_pre_replacement'" "'$prune_pre_race_record'.replacement"' \
    '    /bin/mv -T -- "'$prune_pre_race_record'.replacement" "'$prune_pre_race_record'"' \
    '    exit 0' \
    'fi' \
    'exec /bin/mv "$@"' > "$prune_pre_bin/mv"
chmod 755 "$prune_pre_bin/mv"
if PATH="$prune_pre_bin:$PATH" run prune collab-project --lane default \
    >/dev/null 2>&1; then
    fail "prune accepted a record replaced before its hold"
fi
jq -e '.body == "pre-move replacement"' "$prune_pre_race_record" >/dev/null ||
    fail "pre-move replacement was stranded outside the mailbox"
[[ ! -e "$prune_pre_race_marker" ]] ||
    fail "pre-move replacement inherited the stale completion marker"
prune_pre_quarantine="$T/config/run-codex/state/collab-project/default/collaboration/quarantine"
prune_pre_stale_marker="$(find "$prune_pre_quarantine" -mindepth 1 -maxdepth 1 \
    -type f -name "$prune_pre_race_id.prune-marker.*.json" -print -quit)"
[[ -f "$prune_pre_stale_marker" ]] || fail "stale prune marker was not quarantined"
rm -- "$prune_pre_race_record" "$prune_pre_stale_marker"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/prune-race-id"
prune_race_id="$(<"$T/prune-race-id")"
run deliver collab-project --lane default "$prune_race_id" >/dev/null
prune_race_record="$out/$prune_race_id.json"
prune_race_marker="$delivered_dir/$prune_race_id.json"
prune_bin="$T/prune-bin"; mkdir -p "$prune_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == -T && "${2:-}" == -- && "${3:-}" == "'$prune_race_record'" ]]; then' \
    '    /bin/mv "$@"' \
    '    cp -- "$4" "$3"' \
    '    printf " " >> "$3"' \
    '    exit 0' \
    'fi' \
    'exec /bin/mv "$@"' > "$prune_bin/mv"
chmod 755 "$prune_bin/mv"
PATH="$prune_bin:$PATH" run prune collab-project --lane default >/dev/null
[[ -f "$prune_race_record" && ! -e "$prune_race_marker" ]] ||
    fail "prune deleted the replacement record or retained the old marker"
if find "$delivered_dir" -mindepth 1 -maxdepth 1 -type d \
    -name ".${prune_race_id}.prune.*" -print -quit | grep -q .; then
    fail "successful prune retained its private hold"
fi
rm -- "$prune_race_record"
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/prune-id"
prune_id="$(<"$T/prune-id")"
run deliver collab-project --lane default "$prune_id" >/dev/null
run ack collab-project --lane review "$prune_id" >/dev/null
run send collab-project --lane default --to review --kind question --revision "$base" \
    --body-file "$T/pending-body" > "$T/unresolved-id"
unresolved_id="$(<"$T/unresolved-id")"
run prune collab-project --lane default >/dev/null
run prune collab-project --lane review >/dev/null
[[ ! -e "$out/$prune_id.json" && -e "$out/$unresolved_id.json" ]] ||
    fail "prune mishandled completed/unresolved outbox records"
[[ ! -e "$in/$prune_id.json" && -e "$in/$capacity_id.json" ]] ||
    fail "prune mishandled acknowledged/unresolved inbox records"

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
