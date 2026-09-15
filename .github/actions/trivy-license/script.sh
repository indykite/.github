#!/usr/bin/env bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
# generate a LICENSES.(md|txt) report of 3rd-party dependency licenses via
# 'trivy fs --scanners license'.
#
# Designed to run identically in CI (called from the 'trivy-license' composite action) and on a
# developer's machine: run this script directly (with 'trivy' and 'jq' on PATH) from anywhere
# inside the repo to refresh the report.
#
set -euo pipefail

if ! command -v trivy >/dev/null 2>&1; then
    echo "error: 'trivy' is not installed or not on PATH." >&2
    echo "       install it locally, e.g. 'brew install trivy', then re-run this script." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: 'jq' is not installed or not on PATH." >&2
    echo "       install it locally, e.g. 'brew install jq', then re-run this script." >&2
    exit 1
fi

# Auto-detect the repository root; falls back to CWD when not inside a git worktree (e.g. some
# CI checkouts, or ad-hoc local runs against a plain directory).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

# GitHub 'org/repo' slug + URL, derived from the 'origin' remote (used only to look up the repo
# description below -- never printed in the report itself, since these reports may be shared
# externally with customers and the internal repo name/URL is not meant to be exposed).
REPO_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
REPO_URL="${REPO_URL%.git}"
REPO_URL="${REPO_URL/git@github.com:/https://github.com/}"
REPO_SLUG="${REPO_URL#https://github.com/}"

# A short, human-facing description of what this repo/project is, safe to show in a report that
# may be shared with customers. Prefers the GitHub repo description (via 'gh'), falling back to
# the first descriptive paragraph of the root README.
detect_repo_description() {
    local desc=""
    if command -v gh >/dev/null 2>&1 && [[ -n "${REPO_SLUG}" ]]; then
        desc="$(gh repo view "${REPO_SLUG}" --json description -q '.description' 2>/dev/null || true)"
    fi
    if [[ -z "${desc}" ]]; then
        local readme
        readme="$(find "${REPO_ROOT}" -maxdepth 1 -iname 'README*' 2>/dev/null | head -1)"
        if [[ -n "${readme}" ]]; then
            desc="$(
                awk '
          /^#/ { next }               # skip headings
          /^\[!\[/ { next }           # skip badge lines
          /^[[:space:]]*[-_*=]{3,}[[:space:]]*$/ { next } # skip horizontal rules
          /^[[:space:]]*$/ { if (found) exit; next }
          { found = 1; line = line $0 " " }
          END { print line }
        ' "${readme}" |
                    sed -E 's/\[([^]]+)\]\([^)]+\)/\1/g; s/`//g; s/[[:space:]]+/ /g; s/^ //; s/ $//' |
                    cut -c1-300
            )"
        fi
    fi
    echo "${desc}"
}
REPO_DESCRIPTION="$(detect_repo_description)"

# How a human should regenerate this report: prefer the repo's own 'make trivy-licenses' target
# when it declares one, otherwise fall back to this script via a sibling '.github' checkout
# (the layout used across this org's repos) or, for '.github' itself, its own relative path.
detect_regen_cmd() {
    if grep -qE '^trivy-licenses:' "${REPO_ROOT}"/{Makefile,GNUmakefile} 2>/dev/null; then
        echo "make trivy-licenses"
        return
    fi
    if [[ "$(basename "${REPO_ROOT}")" == ".github" ]]; then
        echo ".github/actions/trivy-license/script.sh"
        return
    fi
    if [[ -f "$(dirname "${REPO_ROOT}")/.github/.github/actions/trivy-license/script.sh" ]]; then
        echo "../.github/.github/actions/trivy-license/script.sh"
        return
    fi
    echo ".github/.github/actions/trivy-license/script.sh (clone '.github' as a sibling of this repo)"
}
REGEN_CMD="$(detect_regen_cmd)"

CONFIG_ARGS=()
if [[ -f "${REPO_ROOT}/.trivy.yaml" ]]; then
    CONFIG_ARGS=(--config "${REPO_ROOT}/.trivy.yaml")
    echo "using Trivy config: ${REPO_ROOT}/.trivy.yaml"
else
    echo "no '.trivy.yaml' found at repo root, using Trivy defaults"
fi

# License scanning wants to see 'node_modules'/'vendor' (that's where npm/Go dependency source
# and license files actually live), so only exclude directories that are never useful here:
# '.git' and Terraform's downloaded module/plugin caches (e.g. present in the 'ops' repo after
# 'terraform init' -- those are not "our" 3rd-party deps to report on).
# Note: Trivy's '--skip-dirs' CLI flag replaces (not merges with) the config file's own
# 'skip-dirs', so this intentionally stays a short, safe-to-always-apply list.
SKIP_ARGS=(
    --skip-dirs "**/.terraform/**"
    --skip-dirs "**/.terragrunt-cache/**"
    --skip-dirs "**/.git/**"
)

# Trivy's Go license scanner only reads from the default '$GOPATH/pkg/mod' module cache -- not
# a custom 'GOMODCACHE', and not anything it downloads itself. On a fresh checkout (e.g. a CI
# runner with no warm cache) that directory is empty, so every Go package silently ends up with
# no detected license at all. Populate it upfront for every 'go.mod' found in the repo.
if command -v go >/dev/null 2>&1; then
    while IFS= read -r -d '' gomod; do
        gomod_dir="$(dirname "${gomod}")"
        echo "go.mod found in ${gomod_dir#"${REPO_ROOT}"/}, running 'go mod download'..."
        (cd "${gomod_dir}" && go mod download) || echo "warning: 'go mod download' failed in ${gomod_dir}, Go license detection may be incomplete" >&2
    done < <(find "${REPO_ROOT}" \( -path '*/.git' -o -path '*/.terraform' -o -path '*/.terragrunt-cache' -o -path '*/site-packages' -o -path '*/node_modules' \) -prune -o -name go.mod -print0 || true)
fi

# Pipenv installs into a venv OUTSIDE the repo by default ('~/.local/share/virtualenvs/...'), so
# Trivy never sees it when scanning the repo root -- every Python package silently ends up with
# no detected license (verified: 81 packages installed externally, 1 detected; the same 81
# packages found via an in-project '.venv', 1000+ detected). 'PIPENV_VENV_IN_PROJECT=1' makes the
# venv land in '<dir>/.venv', where the scan below will find it. Repos using 'uv' already default
# to an in-project '.venv' and need no such workaround.
if command -v pipenv >/dev/null 2>&1; then
    while IFS= read -r -d '' pipfile; do
        pipfile_dir="$(dirname "${pipfile}")"
        echo "Pipfile found in ${pipfile_dir#"${REPO_ROOT}"/}, running 'pipenv sync --dev' into an in-project .venv..."
        # 'sync' (not 'install'): installs exactly what's pinned in Pipfile.lock, never re-resolves
        # or rewrites it -- this is a read-only scan, not a dependency update.
        (cd "${pipfile_dir}" && PIPENV_VENV_IN_PROJECT=1 pipenv sync --dev) || echo "warning: 'pipenv sync' failed in ${pipfile_dir}, Python license detection may be incomplete" >&2
    done < <(find "${REPO_ROOT}" \( -path '*/.git' -o -path '*/.terraform' -o -path '*/.terragrunt-cache' -o -path '*/.venv' \) -prune -o -name Pipfile -print0 || true)
fi

REPORT_FORMAT="${REPORT_FORMAT:-md}" # md (default) or txt
REPORT_FILE="${REPO_ROOT}/LICENSES.${REPORT_FORMAT}"
JSON_FILE="$(mktemp -t trivy-license-XXXXXX).json"

echo "scanning ${REPO_ROOT} for 3rd-party dependency licenses..."
# '--exit-code 0' overrides any 'exit-code' set in the repo's own '.trivy.yaml': this scan only
# ever reports, it never enforces (allowed/forbidden licenses are the repo's own concern).
# '--offline-scan=false' overrides the repo's own 'scan.offline' setting (usually 'true', to keep
# the main vuln/misconfig scan network-free): license detection for Go/npm packages often needs
# to fetch package source when it isn't already in a warm module/dependency cache (e.g. a fresh
# CI runner), otherwise most packages silently end up with no detected license at all.
trivy fs --scanners license "${CONFIG_ARGS[@]}" "${SKIP_ARGS[@]}" --exit-code 0 --offline-scan=false \
    --format json --output "${JSON_FILE}" "${REPO_ROOT}"

GENERATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# Trivy ties license findings to a package name for Go modules and npm/yarn/pnpm packages, but
# for many ecosystems (notably Python) most findings come back as untied "Loose File License(s)"
# entries -- one row per source *file*, e.g. every single '.py' file under a package's
# 'site-packages' directory. Left as-is that's hundreds of near-duplicate rows per package.
# Recover the package name from the file path for common vendor-dir layouts, then de-duplicate:
# one row per (target, package, license) rather than one per file.
DEDUPED_JSON="$(mktemp -t trivy-license-deduped-XXXXXX).json"
trap 'rm -f "${JSON_FILE}" "${DEDUPED_JSON}"' EXIT
jq -c '
    def pkg_of($fp):
      # strip the "-<version>.dist-info" / ".dist-info" / ".egg-info" suffix Python metadata
      # dirs carry, so e.g. "boto3-1.43.89.dist-info" and "boto3" collapse to the same package
      def clean: sub("-[0-9][A-Za-z0-9_.!+]*\\.(dist|egg)-info$"; "") | sub("\\.(dist|egg)-info$"; "");
      if ($fp | test("/?site-packages/")) then ($fp | capture("site-packages/(?<p>[^/]+)/").p | clean)
      elif ($fp | test("/?node_modules/")) then ($fp | capture("node_modules/(?<p>@[^/]+/[^/]+|[^/]+)/").p)
      elif ($fp | test("/?vendor/")) then ($fp | capture("vendor/(?<p>[^/]+/[^/]+)").p)
      else $fp
      end;
    [.Results[]? | select(.Class == "license" or .Class == "license-file")
      | . as $r | ($r.Licenses // [])[] | . as $lic
      | { Target: $r.Target,
          Package: (if ($lic.PkgName // "") == "" then (try pkg_of($lic.FilePath // "-") catch ($lic.FilePath // "-")) else $lic.PkgName end),
          License: ($lic.Name // "UNKNOWN"),
          Classification: ($lic.Category // "-"),
          Severity: ($lic.Severity // "-") }]
    | unique
  ' "${JSON_FILE}" >"${DEDUPED_JSON}"

# One row per (target, package-manager type, de-duplicated license count) -- merges what Trivy's
# own table splits into a 'lang-pkgs' row (type) and a 'license'/'license-file' row (count).
GROUP_ROWS="$(
    jq -r --slurpfile deduped "${DEDUPED_JSON}" '
    ( [.Results[]? | select(.Class == "lang-pkgs") | {(.Target): (.Type // "-")}] | add // {} ) as $types
    | ($deduped[0] | group_by(.Target) | map({Target: .[0].Target, Count: length})) as $counts
    | $counts
    | sort_by(.Target)
    | .[]
    | [.Target, ($types[.Target] // "-"), (.Count | tostring)]
    | @tsv
  ' "${JSON_FILE}"
)"

# One row per (target, package, license, classification, severity), already de-duplicated above.
ROWS="$(
    jq -r '
    sort_by(.Target, .License, .Package)
    | .[]
    | [.Target, .Package, .License, .Classification, .Severity]
    | @tsv
  ' "${DEDUPED_JSON}"
)"

# Grouped by license name; classification/severity are taken from the first occurrence (Trivy
# derives both deterministically from the SPDX license id, so they don't vary per package).
SUMMARY_ROWS="$(
    jq -r '
    group_by(.License)
    | map({name: .[0].License, category: .[0].Classification, severity: .[0].Severity, count: length})
    | sort_by(-.count, .name)
    | .[]
    | [.name, .category, .severity, (.count | tostring)]
    | @tsv
  ' "${DEDUPED_JSON}"
)"

TOTAL_PACKAGES="$(echo -n "${ROWS}" | grep -c . || true)"

render_markdown() {
    {
        echo "# Third-Party License Report"
        echo
        if [[ -n "${REPO_DESCRIPTION}" ]]; then
            echo "${REPO_DESCRIPTION}"
            echo
        fi
        echo "Generated at: ${GENERATED_AT}"
        echo
        echo "DO NOT EDIT!!"
        echo
        echo "Auto-generated by \`trivy fs --scanners license\` via the"
        echo "[.github//trivy-license](https://github.com/indykite/.github/tree/master/.github/actions/trivy-license) action."
        echo "Regenerate with \`${REGEN_CMD}\`."
        echo
        echo "## Summary (by license)"
        echo
        echo "| License | Classification | Severity | Count |"
        echo "| --- | --- | --- | ---: |"
        if [[ -n "${SUMMARY_ROWS}" ]]; then
            echo "${SUMMARY_ROWS}" | awk -F'\t' '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/_/, "\\_", s); gsub(/\|/, "\\|", s); return s }
        { printf "| %s | %s | %s | %s |\n", esc($1), esc($2), esc($3), esc($4) }
      '
        fi
        echo
        echo "**Total packages scanned:** ${TOTAL_PACKAGES}"
        echo
        echo "## Report Summary (by target)"
        echo
        echo "| Target | Type | Licenses |"
        echo "| --- | --- | ---: |"
        if [[ -n "${GROUP_ROWS}" ]]; then
            echo "${GROUP_ROWS}" | awk -F'\t' '
        function esc(s) { gsub(/\\/, "\\\\", s); gsub(/_/, "\\_", s); gsub(/\|/, "\\|", s); return s }
        { printf "| %s | %s | %s |\n", esc($1), esc($2), esc($3) }
      '
        fi
        echo
        echo "## Details"
        echo
        awk -F'\t' '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/_/, "\\_", s); gsub(/\|/, "\\|", s); return s }
      NR == FNR { count[$1] = $3; type[$1] = $2; next }
      $1 != prev {
        if (prev != "") print ""
        printf "### `%s` (%s) -- %s license%s\n\n", $1, type[$1], count[$1], (count[$1] == 1 ? "" : "s")
        print "| Package | License | Classification | Severity |"
        print "| --- | --- | --- | --- |"
        prev = $1
      }
      { printf "| %s | %s | %s | %s |\n", esc($2), esc($3), esc($4), esc($5) }
    ' <(printf '%s\n' "${GROUP_ROWS}") <(printf '%s\n' "${ROWS}")
    } >"${REPORT_FILE}"
}

render_txt() {
    {
        echo "THIRD-PARTY LICENSE REPORT"
        if [[ -n "${REPO_DESCRIPTION}" ]]; then
            echo "${REPO_DESCRIPTION}"
        fi
        echo "Generated at: ${GENERATED_AT}"
        echo
        echo "DO NOT EDIT!!"
        echo
        echo "Auto-generated by: trivy fs --scanners license (.github//trivy-license action)"
        echo "https://github.com/indykite/.github/tree/master/.github/actions/trivy-license"
        echo "Regenerate with: ${REGEN_CMD}"
        echo
        echo "SUMMARY (BY LICENSE)"
        echo "---------------------"
        if [[ -n "${SUMMARY_ROWS}" ]]; then
            echo "${SUMMARY_ROWS}" | awk -F'\t' '{printf "%-20s %-14s %-8s %s\n", $1, $2, $3, $4}'
        fi
        echo
        echo "Total packages scanned: ${TOTAL_PACKAGES}"
        echo
        echo "REPORT SUMMARY (BY TARGET)"
        echo "---------------------------"
        if [[ -n "${GROUP_ROWS}" ]]; then
            echo "${GROUP_ROWS}" | awk -F'\t' '{printf "%-60s %-10s %s\n", $1, $2, $3}'
        fi
        echo
        echo "DETAILS"
        echo "-------"
        awk -F'\t' '
      NR == FNR { count[$1] = $3; type[$1] = $2; next }
      $1 != prev {
        if (prev != "") print ""
        printf "%s (%s) -- %s license%s\n", $1, type[$1], count[$1], (count[$1] == 1 ? "" : "s")
        printf "%-50s %-20s %-14s %s\n", "Package", "License", "Classification", "Severity"
        prev = $1
      }
      { printf "%-50s %-20s %-14s %s\n", $2, $3, $4, $5 }
    ' <(printf '%s\n' "${GROUP_ROWS}") <(printf '%s\n' "${ROWS}")
    } >"${REPORT_FILE}"
}

case "${REPORT_FORMAT}" in
md) RENDER=render_markdown ;;
txt) RENDER=render_txt ;;
*)
    echo "error: unsupported REPORT_FORMAT '${REPORT_FORMAT}' (expected 'md' or 'txt')" >&2
    exit 1
    ;;
esac

if [[ "${TOTAL_PACKAGES}" -eq 0 ]]; then
    echo "no 3rd-party licenses detected, skipping ${REPORT_FILE}"
    exit 0
fi

# Render to a temp file first: the report always embeds a fresh 'Generated at' timestamp, so a
# byte-for-byte comparison would never be stable (e.g. every 'pre-commit' run would flag the file
# as changed even when nothing else did). Only replace the committed file when content other than
# that timestamp actually differs, so re-running this script is idempotent when nothing changed.
TMP_REPORT="$(mktemp -t trivy-license-report-XXXXXX)"
trap 'rm -f "${JSON_FILE}" "${DEDUPED_JSON}" "${TMP_REPORT}"' EXIT
REPORT_FILE_ORIG="${REPORT_FILE}"
REPORT_FILE="${TMP_REPORT}"
"${RENDER}"
REPORT_FILE="${REPORT_FILE_ORIG}"

ignore_timestamp='/^Generated at: /d'
REPORT_UNCHANGED=0
if [[ -f "${REPORT_FILE}" ]]; then
    # shellcheck disable=SC2312 # 'diff's own exit status is what we check here, not sed's
    if diff -q <(sed "${ignore_timestamp}" "${REPORT_FILE}") <(sed "${ignore_timestamp}" "${TMP_REPORT}") >/dev/null; then
        REPORT_UNCHANGED=1
    fi
fi
if [[ "${REPORT_UNCHANGED}" -eq 1 ]]; then
    echo "${REPORT_FILE} is already up to date, leaving it untouched"
else
    mv "${TMP_REPORT}" "${REPORT_FILE}"
    echo "wrote ${REPORT_FILE}"
fi
