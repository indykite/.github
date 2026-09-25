#!/usr/bin/env bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
# Finds vulnerabilities in 'trivy-results.json' (produced by a prior 'trivy' composite action
# run against this repo, without an ignorefile-suppressed CVE re-appearing -- see the header
# comment in 'action.yaml' for why "present in the scan" already means "new"), builds the Jira
# payload + Slack message, and appends '.trivyignore.yaml' entries so the same
# CVE is not re-notified on the next scheduled run.
#
set -euo pipefail

# env vars provided by the caller ('trivy-notify/action.yaml'), not by this script
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${RUN_URL:?RUN_URL is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${REPO:?REPO is required}"
: "${DEFAULT_SLACK_CHANNEL:?DEFAULT_SLACK_CHANNEL is required}"
: "${DEFAULT_SLACK_MENTION:?DEFAULT_SLACK_MENTION is required}"
: "${DEFAULT_JIRA_PROJECT:?DEFAULT_JIRA_PROJECT is required}"
: "${DEFAULT_JIRA_TEAM:?DEFAULT_JIRA_TEAM is required}"
: "${DEFAULT_JIRA_LABELS:?DEFAULT_JIRA_LABELS is required}"

if [[ ! -f trivy-results.json ]]; then
    echo "error: trivy-results.json not found -- run the 'trivy' composite action first" >&2
    exit 1
fi

# ---- Collect distinct CVEs across all scanned targets/packages ----
jq -c '
  [ .Results[]?
    | .Target as $target
    | (.Vulnerabilities // [])[]
    | { id: .VulnerabilityID, severity: (.Severity // "UNKNOWN"), pkg_name: .PkgName,
                installed_version: (.InstalledVersion // "unknown"), fixed_version: (.FixedVersion // "n/a"),
                title: (.Title // .VulnerabilityID), target: $target }
  ]
  | group_by(.id)
  | map({
      id: .[0].id,
      severity: .[0].severity,
      title: .[0].title,
      fixed_version: .[0].fixed_version,
      packages: ([.[].pkg_name] | unique),
    package_versions: (map(.pkg_name + " v" + .installed_version) | unique),
      targets: ([.[].target] | unique)
    })
  | sort_by(. as $item | ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"] | index($item.severity))
' trivy-results.json >new-cves.json

NEW_COUNT="$(jq 'length' new-cves.json)"
echo "new_count=${NEW_COUNT}" >>"${GITHUB_OUTPUT}"

if [[ "${NEW_COUNT}" -eq 0 ]]; then
    echo "no new (non-ignored) vulnerabilities found"
    exit 0
fi

echo "found ${NEW_COUNT} new vulnerability/vulnerabilities"

# ---- Ignore file path: whatever the repo's own '.trivy.yaml' configures (trivy itself reads
#      the same key at scan time), falling back to trivy's own default when unset. The entries
#      themselves are written later, by 'apply-ignorefile.sh', after the API call --
#      so a returned issue key (if any) can be included in the statement. ----
IGNOREFILE=".trivyignore.yaml"
if [[ -f .trivy.yaml ]]; then
    CONFIGURED_IGNOREFILE="$(yq eval '.ignorefile // ""' .trivy.yaml)"
    [[ -n "${CONFIGURED_IGNOREFILE}" ]] && IGNOREFILE="${CONFIGURED_IGNOREFILE}"
fi
echo "ignorefile=${IGNOREFILE}" >>"${GITHUB_OUTPUT}"

# ---- Per-repo notify config, falling back to org-wide defaults ----
notify_value() {
    local yq_path="$1" default_value="$2"
    local value=""
    if [[ -f .trivy.yaml ]]; then
        value="$(yq eval "${yq_path} // \"\"" .trivy.yaml 2>/dev/null || true)"
    fi
    if [[ -z "${value}" || "${value}" == "null" ]]; then
        value="${default_value}"
    fi
    echo "${value}"
}

SLACK_CHANNEL="$(notify_value '.notify.slack.channel' "${DEFAULT_SLACK_CHANNEL}")"
SLACK_MENTION="$(notify_value '.notify.slack.mention' "${DEFAULT_SLACK_MENTION}")"
JIRA_PROJECT="$(notify_value '.notify.jira.project' "${DEFAULT_JIRA_PROJECT}")"
JIRA_TEAM="$(notify_value '.notify.jira.team' "${DEFAULT_JIRA_TEAM}")"

JIRA_LABELS_JSON="[]"
if [[ -f .trivy.yaml ]]; then
    JIRA_LABELS_JSON="$(yq eval -o=json '.notify.jira.labels // []' .trivy.yaml 2>/dev/null || echo '[]')"
fi
if [[ "${JIRA_LABELS_JSON}" == "[]" || "${JIRA_LABELS_JSON}" == "null" ]]; then
    JIRA_LABELS_JSON="$(jq -cn --arg labels "${DEFAULT_JIRA_LABELS}" '$labels | split(",")')"
fi

PACKAGE_SUMMARY="$(jq -r '[.[].package_versions[]] | unique | join(", ")' new-cves.json)"
REPO_NAME="${REPO##*/}"
SECURITY_TITLE="[SECURITY] ${REPO_NAME}, ${PACKAGE_SUMMARY} ${NEW_COUNT} CVE(s)"
SLACK_TITLE="[SECURITY] \`${REPO_NAME}\`, \`${PACKAGE_SUMMARY}\` ${NEW_COUNT} CVE(s)"

{
    echo "slack_channel=${SLACK_CHANNEL}"
    echo "jira_project=${JIRA_PROJECT}"
    echo "jira_team=${JIRA_TEAM}"
    echo "security_title=${SECURITY_TITLE}"
    echo "slack_title=${SLACK_TITLE}"
} >>"${GITHUB_OUTPUT}"

# ---- payload; 'fields' follows REST v3 Create issue. The description carries run
#      metadata and CVE details. ----
JIRA_PAYLOAD="$(
    jq -cn \
        --slurpfile findings new-cves.json \
        --arg repo "${REPO}" \
        --arg run_id "${RUN_ID}" \
        --arg run_url "${RUN_URL}" \
        --arg project "${JIRA_PROJECT}" \
        --arg team "${JIRA_TEAM}" \
        --arg summary "${SECURITY_TITLE}" \
        --argjson labels "${JIRA_LABELS_JSON}" \
        'def text($value): {type: "text", text: $value};
                 ($findings[0] | map({
                     type: "listItem",
                     content: [{
                         type: "paragraph",
                         content: [text((.id + " (" + .severity + ") - " + (.packages | join(", ")) +
                             "; installed: " + (.package_versions | join(", ")) +
                             "; fixed: " + .fixed_version))]
                     }]
                 })) as $finding_items
                 | {
                         kind: "trivy-cve-batch",
                         findings: $findings[0],
                         fields: {
                             project: {key: $project},
                             issuetype: {name: "Vulnerability"},
                             summary: $summary,
                             labels: $labels,
                             customfield_10041: {value: $team},
                             description: {
                                 type: "doc",
                                 version: 1,
                                 content: [
                                     {type: "paragraph", content: [text("Repository: " + $repo)]},
                                     {type: "paragraph", content: [text("Run ID: " + $run_id)]},
                                     {type: "paragraph", content: [text("Run URL: " + $run_url)]},
                                     {type: "paragraph", content: [text("Team: " + $team)]},
                                     {type: "paragraph", content: [text("CVE count: " + (($findings[0] | length) | tostring))]},
                                     {type: "paragraph", content: [text("Findings:")]},
                                     {type: "bulletList", content: $finding_items}
                                 ]
                             }
                         }
                     }'
)"
echo "jira_payload=${JIRA_PAYLOAD}" >>"${GITHUB_OUTPUT}"

# ---- Slack summary ----
TOP_FINDINGS="$(jq -r '.[] | "- \(.id) (\(.severity)) - \(.packages | join(", "))"' new-cves.json | head -20)"

{
    echo "slack_text<<TRIVY_NOTIFY_EOF"
    printf ':rotating_light: %s %s\n' "${SLACK_TITLE}" "${SLACK_MENTION}"
    printf '%s\n' "${TOP_FINDINGS}"
    echo "TRIVY_NOTIFY_EOF"
} >>"${GITHUB_OUTPUT}"
