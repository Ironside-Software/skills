#!/usr/bin/env bash
# Fetch every actionable, unresolved review comment on a PR as JSON.
#   fetch-comments.sh [<number>|<url>|<branch>] [extra gh pr view args, e.g. -R owner/repo]
# Run with no argument from the repo whose checked-out branch has the PR.
# Output: {pr:{number,url,title,headRefName,baseRefName,reviewDecision}, truncated:bool, items:[...]}
#   item.kind = "thread"  inline; reply with `reply.sh --thread <id>`.
#     .author/.body are the most recent comment (what's owed a reply); .comments[] is the full thread.
#     .bot is true only if every comment in the thread is bot-authored — one human reply flips it false.
#   item.kind = "review"  top-level review body with actionable text, human authors only;
#     reply with `reply.sh --pr <pr.url> --review <id>` — the --review tag marks it answered so a
#     rerun does not re-surface it (PullRequestReview has no resolved state of its own).
# Skipped: resolved threads, reviews with no non-whitespace body, bot-authored reviews (their own
# summaries/walkthroughs, not requests), review items already tagged as answered.
# ponytail: reviewThreads/comments/reviews/issue-comments are capped (100/20/50/100) with no
# pagination; `truncated:true` + a stderr warning fire instead of silently dropping — add
# `gh api graphql --paginate` if a PR blows past that.
set -euo pipefail

pr=$(gh pr view "$@" --json number,url,title,headRefName,baseRefName,reviewDecision)
url=$(jq -r .url <<<"$pr")
host=$(cut -d/ -f3 <<<"$url"); owner=$(cut -d/ -f4 <<<"$url"); repo=$(cut -d/ -f5 <<<"$url")
number=$(jq -r .number <<<"$pr")

raw=$(gh api graphql --hostname "$host" -f owner="$owner" -f repo="$repo" -F pr="$number" -f query='
query($owner:String!, $repo:String!, $pr:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviews(last:50) { pageInfo { hasNextPage } nodes { id author { login __typename } state body url } }
      reviewThreads(first:100) {
        pageInfo { hasNextPage }
        nodes {
          id isResolved isOutdated path line
          comments(first:20) { pageInfo { hasNextPage } nodes { author { login __typename } body url diffHunk } }
        }
      }
      comments(first:100) { pageInfo { hasNextPage } nodes { body } }
    }
  }
}')

jq -e '.errors' >/dev/null 2>&1 <<<"$raw" && { jq -r '.errors[].message' <<<"$raw" >&2; exit 1; }

truncated=$(jq '[.data.repository.pullRequest
  | .reviewThreads.pageInfo.hasNextPage, .reviews.pageInfo.hasNextPage, .comments.pageInfo.hasNextPage,
    (.reviewThreads.nodes[].comments.pageInfo.hasNextPage)] | any' <<<"$raw")
[ "$truncated" = true ] && echo "warning: hit a pagination cap, output is incomplete (see script header)" >&2

jq -n --argjson pr "$pr" --argjson raw "$raw" --argjson truncated "$truncated" '
  ($raw.data.repository.pullRequest) as $p
  | ($p.comments.nodes | map(.body // "") | join("\n")) as $issueBody
  | {
      pr: $pr,
      truncated: $truncated,
      items: (
        [ $p.reviewThreads.nodes[]
          | select(.isResolved == false)
          | { kind: "thread", id, path, line, outdated: .isOutdated,
              author: .comments.nodes[-1].author.login,
              bot: ([.comments.nodes[].author.__typename] | all(. == "Bot")),
              body: .comments.nodes[-1].body,
              url: .comments.nodes[-1].url,
              diffHunk: .comments.nodes[0].diffHunk,
              comments: [ .comments.nodes[] | {author: .author.login, bot: (.author.__typename == "Bot"), body} ] }
        ] +
        [ $p.reviews.nodes[]
          | . as $r
          | select((.body | gsub("\\s"; "") | length) > 0
                   and .author.__typename != "Bot"
                   and ($issueBody | test("revise-pr:review:" + $r.id) | not))
          | { kind: "review", id, author: .author.login, bot: false, state, url, body }
        ]
      )
    }'
