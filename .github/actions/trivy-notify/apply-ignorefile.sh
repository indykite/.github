#!/usr/bin/env bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
# Appends ignore-file entries (see 'find-new-cves'/'script.sh' for the resolved path) for the
# CVEs found this run. Runs *after* direct API creation, so the statement can reference the
# actual created issue key returned by Jira, using:
#   {"created": [{"issue_key": "ENG-1234"}]}
# or per-CVE tickets:
#   {"created": [{"cve_id": "CVE-2024-0001", "issue_key": "ENG-1234"}, ...]}
# When no issue key is returned, the CVEs remain unsuppressed so a successful HTTP response cannot
# hide an unfiled alert.
#
set -euo pipefail

# env vars provided by the caller ('trivy-notify/action.yaml'), not by this script
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${RUN_URL:?RUN_URL is required}"
: "${IGNOREFILE:?IGNOREFILE is required}"
: "${JIRA_PROJECT:?JIRA_PROJECT is required}"
: "${JIRA_TEAM:?JIRA_TEAM is required}"
: "${SLACK_TEXT:?SLACK_TEXT is required}"

TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# cve_id -> issue_key map from the response; empty map when it's missing, empty, or not
# valid JSON (a top-level parse error isn't catchable by jq's own 'try', so validate first).
RESPONSE_BODY="${JIRA_RESPONSE_BODY:-}"
if [[ -z "${RESPONSE_BODY// /}" ]] || ! jq empty <<<"${RESPONSE_BODY}" >/dev/null 2>&1; then
    RESPONSE_BODY='{}'
fi
KEYS_JSON="$(jq -c '(.created // []) | map(select(.cve_id != null and .issue_key != null) | {(.cve_id): .issue_key}) | add // {}' <<<"${RESPONSE_BODY}" 2>/dev/null || echo '{}')"
GLOBAL_ISSUE_KEY="$(jq -r '[.created[]? | select(.cve_id == null and .issue_key != null) | .issue_key] | first // ""' <<<"${RESPONSE_BODY}")"

# Unique created issue keys, comma-separated, for the caller's commit message (empty when the
# response didn't return any -- see the header comment above).
CREATED_ISSUE_KEYS="$(jq -rn --argjson keys "${KEYS_JSON}" --arg global_key "${GLOBAL_ISSUE_KEY}" '([$global_key] + [$keys[]]) | map(select(. != "")) | unique | join(", ")')"
echo "created_issue_keys=${CREATED_ISSUE_KEYS}" >>"${GITHUB_OUTPUT}"

JIRA_TEXT="$(jq -rn \
    --arg project "${JIRA_PROJECT}" \
    --arg team "${JIRA_TEAM}" \
    --arg run_url "${RUN_URL}" \
    --argjson keys "${KEYS_JSON}" \
    --arg global_key "${GLOBAL_ISSUE_KEY}" \
    '(
      ([$global_key] + [$keys[]]
        | map(select(. != null and . != "")
        | "<https://indykite.atlassian.net/browse/\(.)|\(.)>") | unique)
    ) as $links
    | if ($links | length) > 0 then
        "" + ($links | join(", ")) + " (team " + $team + "), run: " + $run_url
      else
        "filed under " + $project + " (team " + $team + "), issue key not returned; run: " + $run_url
      end')"
echo "jira_text=${JIRA_TEXT}" >>"${GITHUB_OUTPUT}"

{
    echo "slack_text<<TRIVY_NOTIFY_EOF"
    printf '%s\n' "${SLACK_TEXT}"
    printf '%s\n' "${JIRA_TEXT}"
    echo "TRIVY_NOTIFY_EOF"
} >>"${GITHUB_OUTPUT}"

if [[ -z "${CREATED_ISSUE_KEYS}" ]]; then
    echo "warning: API returned no created issue key; leaving CVEs unsuppressed" >&2
    echo "jira_confirmed=false" >>"${GITHUB_OUTPUT}"
    exit 0
fi
echo "jira_confirmed=true" >>"${GITHUB_OUTPUT}"

IGNORE_ENTRIES_JSON="$(
    jq -c --arg ts "${TIMESTAMP}" --arg run_url "${RUN_URL}" --arg global_key "${GLOBAL_ISSUE_KEY}" --argjson keys "${KEYS_JSON}" '
      map({
        id: .id,
        statement: (
          ($keys[.id] // $global_key // "") as $key
          | (if $key != "" then $key + " - " else "" end)
          + "auto-filed " + $ts + " by trivy-notify; affected: " + (.packages | join(", ")) + "; run: " + $run_url
        )
      })
    ' new-cves.json
)"

if [[ ! -f "${IGNOREFILE}" ]]; then
    printf -- '---\n' >"${IGNOREFILE}"

    # First CVE ever suppressed for this repo: '.trivy.yaml' 'ignorefile:' is commented out (or
    # absent) up to this point, to avoid trivy's FATAL "ignore file not found" before this file
    # existed. Enable it now so every future scan (CI and local) actually honors it.
    CONFIGURED_IGNOREFILE="$(yq eval '.ignorefile // ""' .trivy.yaml 2>/dev/null || true)"
    if [[ -f .trivy.yaml ]] && [[ "${CONFIGURED_IGNOREFILE}" != "${IGNOREFILE}" ]]; then
        sed -i.bak -E "/^#[[:space:]]*ignorefile:/d" .trivy.yaml && rm -f .trivy.yaml.bak
        yq eval -i ".ignorefile = \"${IGNOREFILE}\"" .trivy.yaml
    fi
fi
yq eval -i ".vulnerabilities = ((.vulnerabilities // []) + ${IGNORE_ENTRIES_JSON})" "${IGNOREFILE}"
