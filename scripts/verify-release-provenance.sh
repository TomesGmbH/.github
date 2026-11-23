#!/usr/bin/env bash
# Decides whether a release tag may be deployed to production (IDA-7171).
#
# Runs in the reusable workflow verify-release.yml, before any cloud
# credential or signing secret is requested. The calling production workflow
# runs from the default branch, so this script and that workflow are reviewed
# code; the tag they check is not. A tag is deployable when it matches the
# caller's release tag pattern, still points to the commit that was tested,
# and that commit
#   - is part of the default branch, or
#   - is the merge result of a pull request into the default branch or a
#     hotfix/* branch whose head commit a member other than the author
#     approved, with no later change request or dismissal (reviewed hotfixes).
# Break-glass (workflow_dispatch with an INC key) skips the provenance check;
# verify-release.yml opens the review issue before the deploy can start.
#
# Environment:
#   EVENT           github.event_name (workflow_run | workflow_dispatch)
#   REF             github.ref (a dispatch must run on the default branch)
#   REPO            owner/name
#   DEFAULT_BRANCH  default branch name
#   TAG_PATTERN     bash regular expression the release tag must match
#   RUN_TAG/RUN_SHA tag and commit of the completed tag workflow run
#   RUN_CONCLUSION  conclusion of that run (must be success)
#   RUN_EVENT       event of that run (must be push)
#   RUN_ATTEMPT     github.run_attempt (a break-glass dispatch runs once)
#   DISPATCH_TAG    tag input of a break-glass dispatch
#   INCIDENT        INC key input of a break-glass dispatch
#   GH_TOKEN        token with contents: read and pull-requests: read
# Writes tag, sha, provenance and break-glass to GITHUB_OUTPUT.

set -euo pipefail

fail() {
  echo "::error title=Release not deployable::$1"
  exit 1
}

: "${EVENT:?}" "${REPO:?}" "${DEFAULT_BRANCH:?}" "${TAG_PATTERN:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

case "$EVENT" in
  workflow_run)
    [[ "${RUN_CONCLUSION:-}" == success ]] ||
      fail "the tag workflow run did not succeed (${RUN_CONCLUSION:-unknown}); nothing is deployed"
    [[ "${RUN_EVENT:-}" == push ]] ||
      fail "the triggering run was started by ${RUN_EVENT:-unknown}, not by a tag push"
    tag="${RUN_TAG:-}"
    expected_sha="${RUN_SHA:-}"
    [[ -n "$expected_sha" ]] || fail "the triggering run has no commit"
    emergency=false
    ;;
  workflow_dispatch)
    [[ "${REF:-}" == "refs/heads/$DEFAULT_BRANCH" ]] ||
      fail "break-glass deploys must be started on $DEFAULT_BRANCH, not ${REF:-?}"
    # A re-run keeps the review issue of the first attempt and could deploy
    # again without a new one; an emergency needs a fresh dispatch.
    [[ "${RUN_ATTEMPT:-1}" == 1 ]] ||
      fail "a break-glass run cannot be re-run; start a new dispatch with the INC key"
    tag="${DISPATCH_TAG:-}"
    expected_sha=""
    [[ "${INCIDENT:-}" =~ ^INC-[0-9]+$ ]] ||
      fail "a break-glass deploy needs the INC key of the emergency (e.g. INC-123), got '${INCIDENT:-}'"
    emergency=true
    ;;
  *)
    fail "unsupported event $EVENT"
    ;;
esac

[[ "$tag" =~ $TAG_PATTERN ]] || fail "'$tag' is not a release tag of this workflow ($TAG_PATTERN)"
# Defence in depth for a loose caller pattern: the tag ends up in API paths.
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || fail "'$tag' contains characters a release tag never has"

# The commit the tag points to now (annotated tags are dereferenced).
sha="$(gh api "repos/$REPO/commits/refs/tags/$tag" --jq .sha)" ||
  fail "tag $tag does not exist"
if [[ -n "$expected_sha" && "$sha" != "$expected_sha" ]]; then
  fail "tag $tag moved from the tested commit $expected_sha to $sha"
fi

if [[ "$emergency" == true ]]; then
  echo "::warning title=Break-glass deploy::$tag ($sha) is deployed without provenance check for $INCIDENT"
  provenance="break-glass $INCIDENT"
else
  status="$(gh api "repos/$REPO/compare/$DEFAULT_BRANCH...$sha" --jq .status)"
  if [[ "$status" == "behind" || "$status" == "identical" ]]; then
    provenance="$DEFAULT_BRANCH"
  else
    provenance=""
    prs="$(gh api --paginate "repos/$REPO/commits/$sha/pulls" \
      --jq ".[] | select(.merged_at != null and .merge_commit_sha == \"$sha\") | .number")"
    for pr in $prs; do
      pr_json="$(gh api "repos/$REPO/pulls/$pr")"
      author="$(jq -r .user.login <<<"$pr_json")"
      base="$(jq -r .base.ref <<<"$pr_json")"
      head_sha="$(jq -r .head.sha <<<"$pr_json")"
      # Only the protected default branch and hotfix branches count; a merge
      # into any other branch is not a release path.
      if [[ "$base" != "$DEFAULT_BRANCH" && "$base" != hotfix/* ]]; then
        echo "pull request #$pr merged into $base, which is not a release branch"
        continue
      fi
      # An approval counts only if it is the reviewer's latest decision, was
      # given on the merged head commit (no unreviewed commits pushed after
      # it), and comes from a member or collaborator other than the author.
      approver="$(gh api --paginate "repos/$REPO/pulls/$pr/reviews" --jq '.[]' |
        jq -rs --arg author "$author" --arg head "$head_sha" '
          map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
          | group_by(.user.login)
          | map(sort_by(.submitted_at) | last)
          | map(select(.state == "APPROVED"
              and .user.login != $author
              and .commit_id == $head
              and (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")))
          | .[0].user.login // empty')"
      if [[ -n "$approver" ]]; then
        provenance="pull request #$pr into $base, approved by $approver"
        break
      fi
      echo "pull request #$pr has no current approval on its head commit by another member"
    done
    [[ -n "$provenance" ]] || fail "$tag ($sha) is neither on $DEFAULT_BRANCH nor the merge of an approved pull request. Merge the fix through a reviewed pull request and tag its merge commit, or start a break-glass deploy with the INC key."
  fi
fi

echo "Deploying $tag ($sha), provenance: $provenance"
{
  echo "tag=$tag"
  echo "sha=$sha"
  echo "provenance=$provenance"
  echo "break-glass=$emergency"
} >>"$out"
