#!/usr/bin/env bash
# Hermetic tests for verify-release-provenance.sh (IDA-7171). A fake `gh`
# serves canned GitHub API responses from a fixture directory, so every
# decision that lets a commit reach production is covered without network.
#
# Run: scripts/verify-release-provenance_test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/verify-release-provenance.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

TAG_SHA=1111111111111111111111111111111111111111
HEAD_SHA=2222222222222222222222222222222222222222
OTHER_SHA=3333333333333333333333333333333333333333
BASE_SHA=4444444444444444444444444444444444444444

# Fake gh: `gh api [--paginate] <path> [--jq <expr>]`. The response for
# <path> is $FIXTURES/<path with / and ? replaced by _>; a missing fixture is
# an API error. --jq is applied with jq.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == api ]] || { echo "fake gh: only api" >&2; exit 2; }
shift
path="" expr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paginate) shift ;;
    --jq) expr="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
file="$FIXTURES/$(tr '/?' '__' <<<"$path")"
[[ -f "$file" ]] || { echo "fake gh: HTTP 404 $path" >&2; exit 1; }
if [[ -n "$expr" ]]; then jq -r "$expr" "$file"; else cat "$file"; fi
EOF
chmod +x "$work/bin/gh"

fixture() { # fixture <api path> <json>
  printf '%s' "$2" >"$FIXTURES/$(tr '/?' '__' <<<"$1")"
}

R=repos/TomesGmbH/example
pr_json() { # pr_json <base> <author>
  printf '{"user":{"login":"%s"},"base":{"ref":"%s"},"head":{"sha":"%s"}}' "$2" "$1" "$HEAD_SHA"
}
review() { # review <login> <state> <commit> <association> <submitted_at>
  printf '{"user":{"login":"%s"},"state":"%s","commit_id":"%s","author_association":"%s","submitted_at":"%s"}' "$@"
}

# Baseline: v1.2.3 points to TAG_SHA, which is not on main and is the merge
# commit of PR 7 into hotfix/v1.2, approved on its head by member "bob".
ahead() { # ahead <commit>...: the commits the tag adds to main
  local list="" c
  for c in "$@"; do list="$list${list:+,}{\"sha\":\"$c\"}"; done
  fixture "$R/compare/main...$TAG_SHA?per_page=100" "{\"ahead_by\":$#,\"commits\":[$list]}"
}
reset_fixtures() {
  FIXTURES="$(mktemp -d "$work/fx.XXXX")"
  export FIXTURES
  fixture "$R/commits/refs/tags/v1.2.3" "{\"sha\":\"$TAG_SHA\"}"
  fixture "$R/compare/main...$TAG_SHA" '{"status":"diverged"}'
  ahead "$TAG_SHA"
  fixture "$R/commits/$TAG_SHA/pulls" "[{\"number\":7,\"merged_at\":\"2026-11-20T10:00:00Z\",\"merge_commit_sha\":\"$TAG_SHA\"}]"
  fixture "$R/pulls/7" "$(pr_json hotfix/v1.2 alice)"
  fixture "$R/pulls/7/reviews" "[$(review bob APPROVED "$HEAD_SHA" MEMBER 2026-11-20T09:00:00Z)]"
}

SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+$'
pass=0 failures=0
run() { # run <name> <expected: ok|fail> [env assignments...]
  local name="$1" expect="$2" output rc
  shift 2
  : >"$work/out" # each case's outputs only
  set +e
  output="$(env PATH="$work/bin:$PATH" GITHUB_OUTPUT="$work/out" REPO=TomesGmbH/example \
    DEFAULT_BRANCH=main TAG_PATTERN="$SEMVER" "$@" bash "$script" 2>&1)"
  rc=$?
  set -e
  if { [[ "$expect" == ok && $rc -eq 0 ]] || [[ "$expect" == fail && $rc -ne 0 ]]; }; then
    pass=$((pass + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name (expected $expect, exit $rc)"
    echo "$output" | sed 's/^/    /'
  fi
}
on_run() { run "$1" "$2" EVENT=workflow_run RUN_TAG=v1.2.3 RUN_SHA="$TAG_SHA" \
  RUN_CONCLUSION=success RUN_EVENT=push "${@:3}"; }

reset_fixtures
fixture "$R/compare/main...$TAG_SHA" '{"status":"behind"}'
on_run "commit on main" ok
fixture "$R/compare/main...$TAG_SHA" '{"status":"identical"}'
on_run "commit is main's head" ok

reset_fixtures
on_run "approved hotfix pull request" ok
grep -q "provenance=pull request #7 into hotfix/v1.2, approved by bob" "$work/out" ||
  { failures=$((failures + 1)); echo "FAIL: provenance output"; }

reset_fixtures
fixture "$R/commits/$TAG_SHA/pulls" '[]'
on_run "commit without pull request (pushed directly)" fail

reset_fixtures
fixture "$R/pulls/7" "$(pr_json feature/x alice)"
on_run "pull request merged into a non-release branch" fail

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review alice APPROVED "$HEAD_SHA" MEMBER 2026-11-20T09:00:00Z)]"
on_run "self-approval" fail

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review bob APPROVED "$OTHER_SHA" MEMBER 2026-11-20T09:00:00Z)]"
on_run "approval on an earlier commit (stale)" fail

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review bob APPROVED "$HEAD_SHA" MEMBER 2026-11-20T09:00:00Z),$(review bob CHANGES_REQUESTED "$HEAD_SHA" MEMBER 2026-11-20T09:30:00Z)]"
on_run "approval superseded by a change request" fail

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review bob APPROVED "$HEAD_SHA" MEMBER 2026-11-20T09:00:00Z),$(review bob DISMISSED "$HEAD_SHA" MEMBER 2026-11-20T09:30:00Z)]"
on_run "dismissed approval" fail

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review bob APPROVED "$HEAD_SHA" MEMBER 2026-11-20T09:00:00Z),$(review bob COMMENTED "$HEAD_SHA" MEMBER 2026-11-20T09:30:00Z)]"
on_run "a later comment keeps the approval" ok

reset_fixtures
fixture "$R/pulls/7/reviews" "[$(review mallory APPROVED "$HEAD_SHA" NONE 2026-11-20T09:00:00Z)]"
on_run "approval by a non-member" fail

reset_fixtures
fixture "$R/commits/$TAG_SHA/pulls" "[{\"number\":7,\"merged_at\":null,\"merge_commit_sha\":\"$TAG_SHA\"}]"
on_run "unmerged pull request" fail

reset_fixtures
on_run "tag moved after the tests" fail RUN_SHA="$OTHER_SHA"
on_run "not a release tag" fail RUN_TAG=feature/x
on_run "unknown tag" fail RUN_TAG=v9.9.9
on_run "triggering run without commit" fail RUN_SHA=
on_run "failed test run" fail RUN_CONCLUSION=failure
on_run "triggering run not started by a push" fail RUN_EVENT=workflow_dispatch
on_run "tag with a suffix the pattern does not allow" fail RUN_TAG=v1.2.3-prod
on_run "tag with characters outside a release tag" fail 'TAG_PATTERN=^v.*$' 'RUN_TAG=v1.2.3/../x'

# Channel patterns (desktop, bridge): the suffix is part of the tag.
reset_fixtures
fixture "$R/commits/refs/tags/v1.2.3-beta.4" "{\"sha\":\"$TAG_SHA\"}"
on_run "suffixed tag matching the pattern" ok RUN_TAG=v1.2.3-beta.4 \
  'TAG_PATTERN=^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$'
grep -q "tag=v1.2.3-beta.4" "$work/out" && grep -q "break-glass=false" "$work/out" ||
  { failures=$((failures + 1)); echo "FAIL: suffixed tag output"; }

# A hotfix branch carrying a commit that was pushed to it directly: the
# follow-up pull request's approval does not cover it.
reset_fixtures
ahead "$BASE_SHA" "$TAG_SHA"
fixture "$R/commits/$BASE_SHA/pulls" '[]'
on_run "hotfix branch with a directly pushed commit" fail

reset_fixtures
ahead "$BASE_SHA" "$TAG_SHA"
fixture "$R/commits/$BASE_SHA/pulls" '[{"number":6,"merged_at":"2026-11-19T10:00:00Z","merge_commit_sha":"5555555555555555555555555555555555555555"}]'
fixture "$R/pulls/6" "$(pr_json hotfix/v1.2 carol)"
fixture "$R/pulls/6/reviews" "[$(review bob APPROVED "$HEAD_SHA" MEMBER 2026-11-19T09:00:00Z)]"
on_run "hotfix branch whose earlier commit came through an approved pull request" ok

reset_fixtures
ahead "$BASE_SHA" "$TAG_SHA"
fixture "$R/commits/$BASE_SHA/pulls" '[{"number":6,"merged_at":"2026-11-19T10:00:00Z","merge_commit_sha":"5555555555555555555555555555555555555555"}]'
fixture "$R/pulls/6" "$(pr_json hotfix/v1.2 carol)"
fixture "$R/pulls/6/reviews" "[$(review carol APPROVED "$HEAD_SHA" MEMBER 2026-11-19T09:00:00Z)]"
on_run "earlier hotfix commit from a self-approved pull request" fail

reset_fixtures
fixture "$R/compare/main...$TAG_SHA?per_page=100" "{\"ahead_by\":101,\"commits\":[{\"sha\":\"$TAG_SHA\"}]}"
on_run "more commits ahead of main than can be checked" fail

reset_fixtures
rm "$FIXTURES/$(tr '/?' '__' <<<"$R/compare/main...$TAG_SHA")"
on_run "API failure fails closed" fail

reset_fixtures
bg() { run "$1" "$2" EVENT=workflow_dispatch REF=refs/heads/main DISPATCH_TAG=v1.2.3 \
  INCIDENT=INC-123 "${@:3}"; }
bg "break-glass with INC key" ok
grep -q "break-glass=true" "$work/out" ||
  { failures=$((failures + 1)); echo "FAIL: break-glass output"; }
bg "break-glass re-run" fail RUN_ATTEMPT=2
bg "break-glass tag outside the pattern" fail DISPATCH_TAG=v1.2.3-dev.1
bg "break-glass without INC key" fail INCIDENT=
bg "break-glass with malformed INC key" fail 'INCIDENT=INC-1; rm -rf /'
bg "break-glass from another branch" fail REF=refs/heads/evil
run "unsupported event" fail EVENT=push

echo "$pass passed, $failures failed"
[[ $failures -eq 0 ]]
