#!/usr/bin/env bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
set -o nounset -o pipefail

: "${TF_PLUGIN_CACHE_DIR:?TF_PLUGIN_CACHE_DIR is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# Rewrite ssh://git@github.com/indykite/ to HTTPS so tofu init can download
# private modules without an SSH deploy key on the runner.
if [[ -n "${INPUT_GITHUB_TOKEN:-}" ]]; then
    git config --global url."https://x-access-token:${INPUT_GITHUB_TOKEN}@github.com/indykite/".insteadOf "ssh://git@github.com/indykite/"
fi

mkdir -p "${TF_PLUGIN_CACHE_DIR}"

LOG_DIR="${RUNNER_TEMP}/terraform-validate"
mkdir -p "${LOG_DIR}"
FULL_LOG="${LOG_DIR}/terraform-validate-full.log"
: >"${FULL_LOG}"
echo "full_log_path=${FULL_LOG}" >>"${GITHUB_OUTPUT}"
echo "full_log_gz_path=${FULL_LOG}.gz" >>"${GITHUB_OUTPUT}"

exclude_csv="${INPUT_EXCLUDE_DIRS:-}"
if [[ -n "${TF_VALIDATE_EXCLUDE_DIRS:-}" ]]; then
    exclude_csv+="${exclude_csv:+,}${TF_VALIDATE_EXCLUDE_DIRS}"
fi

exclude_file="${INPUT_EXCLUDE_FILE:-}"
if [[ -n "${exclude_file}" && -f "${exclude_file}" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "${line}" | xargs)"
        [[ -z "${line}" ]] && continue
        exclude_csv+="${exclude_csv:+,}${line}"
    done <"${exclude_file}"
fi

declare -a exclude_items=()
if [[ -n "${exclude_csv}" ]]; then
    exclude_lines="$(echo "${exclude_csv}" | tr ',;' '\n')"
    while IFS= read -r item; do
        item="$(echo "${item}" | xargs)"
        [[ -z "${item}" ]] && continue
        exclude_items+=("${item}")
    done <<<"${exclude_lines}"
fi

is_excluded_dir() {
    local path="${1}"
    local norm="${path#./}"
    local ex

    for ex in "${exclude_items[@]}"; do
        if [[ "${norm}" == "${ex}" || "${norm}" == "${ex}/"* || "${norm}" == */"${ex}" || "${norm}" == */"${ex}/"* ]]; then
            return 0
        fi
    done
    return 1
}

if [[ ${#exclude_items[@]} -gt 0 ]]; then
    echo "[INFO] excluding directories: ${exclude_items[*]}"
fi

declare -A seen_dirs=()
if [[ "${INPUT_CHANGED_ONLY:-false}" == "true" ]]; then
    echo "[INFO] changed-only mode enabled"

    diff_ready=1
    if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
        if ! git rev-parse --verify HEAD^1 >/dev/null 2>&1; then
            diff_ready=0
        fi
        diff_cmd=(git diff --name-only HEAD^1 HEAD -- '*.tf')
    else
        if ! git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
            diff_ready=0
        fi
        diff_cmd=(git diff --name-only HEAD~1 HEAD -- '*.tf')
    fi

    if [[ ${diff_ready} -eq 1 ]]; then
        diff_output="$("${diff_cmd[@]}" || true)"
        while IFS= read -r file; do
            [[ -z "${file}" ]] && continue
            [[ "${file}" == *"/.terraform/"* ]] && continue
            [[ "${file}" == *"/.terragrunt-cache/"* ]] && continue
            dir="$(dirname "${file}")"
            if is_excluded_dir "${dir}"; then
                continue
            fi
            seen_dirs["${dir}"]=1
        done <<<"${diff_output}"
    else
        echo "[WARN] no parent commit available for diff; falling back to full scan"
    fi
fi

if [[ ${#seen_dirs[@]} -eq 0 ]]; then
    tmp_find="$(mktemp)"
    find . -type f -name '*.tf' -not -path '*/.terraform/*' -not -path '*/.terragrunt-cache/*' -print0 >"${tmp_find}"
    while IFS= read -r -d '' file; do
        dir="$(dirname "${file}")"
        if is_excluded_dir "${dir}"; then
            continue
        fi
        seen_dirs["${dir}"]=1
    done <"${tmp_find}"
    rm -f "${tmp_find}"
fi

if [[ ${#seen_dirs[@]} -eq 0 ]]; then
    echo "[INFO] no Terraform directories found, skipping."
    exit 0
fi

tmp_dirs="$(mktemp)"
printf '%s\n' "${!seen_dirs[@]}" | sort >"${tmp_dirs}"
mapfile -t tf_dirs <"${tmp_dirs}"
rm -f "${tmp_dirs}"

failed=0
failed_modules=()
for dir in "${tf_dirs[@]}"; do
    echo "[INFO] validating ${dir}"

    {
        echo "[INFO] validating ${dir}"
    } >>"${FULL_LOG}"

    safe_dir="${dir#./}"
    safe_dir="${safe_dir//\//__}"
    module_log="${LOG_DIR}/${safe_dir}.log"
    : >"${module_log}"

    pushd "${dir}" >/dev/null || exit 1

    tofu init -upgrade -backend=false -input=false -no-color >"${module_log}" 2>&1
    init_status=$?

    validate_status=0
    if [[ ${init_status} -eq 0 ]]; then
        tofu validate -no-color >>"${module_log}" 2>&1
        validate_status=$?
    else
        validate_status=${init_status}
    fi

    popd >/dev/null || exit 1

    cat "${module_log}" >>"${FULL_LOG}"

    summary_pattern='^(Upgrading modules\.\.\.|Initializing provider plugins\.\.\.|- Installed .+|- Using .+|'
    summary_pattern+="Success! The configuration is valid\\.|"
    summary_pattern+="OpenTofu has been successfully initialized!|"
    summary_pattern+="Terraform has been successfully initialized!)"
    grep -E "${summary_pattern}" "${module_log}" || true

    if [[ ${validate_status} -ne 0 ]]; then
        failed=1
        failed_modules+=("${dir}")
        echo "[ERROR] validation failed in ${dir}; full output follows"
        cat "${module_log}"
    fi
done

gzip -9 -c "${FULL_LOG}" >"${FULL_LOG}.gz"

if [[ ${failed} -ne 0 ]]; then
    echo "[ERROR] terraform validation failed in: ${failed_modules[*]}"
fi

exit "${failed}"
