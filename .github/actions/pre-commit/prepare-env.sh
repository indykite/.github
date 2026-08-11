#!/bin/bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#

set -o errexit -o nounset -o pipefail

: "${GITHUB_OUTPUT:=""}"

_PRE_COMMIT_CONFIG=".pre-commit-config.yaml"
PRE_COMMIT_RUN=0
CACHE_MONTH="$(date +'%Y%m')"

IS_TERRAFORM="${IS_TERRAFORM:-0}"

IS_GOLANG="${IS_GOLANG:-0}"
GOMOD_PATH="$(find . -name go.mod | head -n 1)"

# NOTE: IS_PYTHON is unused at the moment, defined for potential later
#   use in the `pre-commit/script.sh`.
IS_PYTHON="${IS_PYTHON:-0}"
PYTHON_VERSION="3.14"
PYTHON_VERSION_SPEC=""
PYTHON_VERSION_SOURCE=""

IS_NPM="${IS_NPM:-0}"
NODE_PM=""
NODE_PM_LOCKFILE=""
NODE_PM_WORKDIR="."
NODE_VERSION_FILE=""
PNPM_VERSION="latest"

toml_get() {
    local file="${1}" path="${2}"
    if [[ -f "${file}" ]]; then
        yq -p toml -e "${path}" "${file}" 2>/dev/null || true
    fi
}

# Python detection =====================================================

PYTHON_EXCLUDE_DIRS=(
    '*/.venv/*'
    '*/venv/*'
    '*/virtualenv/*'
    '*/.virtualenv/*'
    '*/env/*'
    '*/.tox/*'
    '*/site-packages/*'
    '*/node_modules/*'
    '*/.git/*'
)

find_py_project_file() {
    local name="${1}"
    local -a exclude_paths=()
    local pattern
    for pattern in "${PYTHON_EXCLUDE_DIRS[@]}"; do
        ((${#exclude_paths[@]})) && exclude_paths+=(-o)
        exclude_paths+=(-path "${pattern%/\*}")
    done
    find . -type d \( "${exclude_paths[@]}" \) -prune -o -type f -name "${name}" -print | sort | head -n1
}

# Extracts the first X.Y(.Z) numeric token from a version spec. If the
# requirement specifies >X,<Y, the Python version will be wrongly parsed
# which is fine as that can be fixed on the specification side without
# introducing any breaking changes or accidental version bumps.
# 3.14 => 3.14
# ^3.14 => 3.14
# >=3.14.1,<1.15 => 3.14.1
normalize_python_version() {
    if [[ "${1}" =~ ([0-9]+(\.[0-9]+){0,2}) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
    return 0
}

python_version_from() {
    case "${1}" in
    .python-version)
        local f
        f="$(find_py_project_file '.python-version')"
        if [[ -n "${f}" ]]; then
            cat "${f}" || true
        fi
        ;;
    "pyproject.toml (PEP 621)")
        local f
        f="$(find_py_project_file 'pyproject.toml')"
        if [[ -n "${f}" ]]; then
            toml_get "${f}" '.project."requires-python"'
        fi
        ;;
    "pyproject.toml (poetry)")
        local f
        f="$(find_py_project_file 'pyproject.toml')"
        if [[ -n "${f}" ]]; then
            toml_get "${f}" '.tool.poetry.dependencies.python'
        fi
        ;;
    Pipfile)
        local f
        f="$(find_py_project_file 'Pipfile')"
        if [[ -n "${f}" ]]; then
            toml_get "${f}" '.requires.python_version'
        fi
        ;;
    setup.py)
        local f
        f="$(find_py_project_file 'setup.py')"
        if [[ -n "${f}" ]]; then
            grep -oE "python_requires\s*=\s*['\"][^'\"]+['\"]" "${f}" |
                sed -E "s/.*['\"]([^'\"]+)['\"]/\1/" || true
        fi
        ;;
    *) ;;
    esac
}

PYTHON_SOURCES=(
    ".python-version"
    "pyproject.toml (PEP 621)"
    "pyproject.toml (poetry)"
    "Pipfile"
    "setup.py"
)

for source in "${PYTHON_SOURCES[@]}"; do
    value="$(python_version_from "${source}")"
    if [[ -n "${value}" ]]; then
        normalized="$(normalize_python_version "${value}")"
        if [[ -n "${normalized}" ]]; then
            PYTHON_VERSION_SPEC="${value}"
            PYTHON_VERSION_SOURCE="${source}"
            PYTHON_VERSION="${normalized}"
            break
        fi
    fi
done

[[ -n "${PYTHON_VERSION_SOURCE}" ]] && IS_PYTHON=1

# NodeJS detection =====================================================
# Detect Node package manager cache strategy from lockfile presence.
# Supports non-root lockfile/package.json locations.

find_pm_lockfile() {
    find . -type d -path '*/node_modules' -prune -o -type f "$@" -print | sort | head -n1
}

lockfile_for() {
    case "${1}" in
    pnpm) find_pm_lockfile -name 'pnpm-lock.yaml' ;;
    npm) find_pm_lockfile \( -name 'package-lock.json' -o -name 'npm-shrinkwrap.json' \) ;;
    yarn) find_pm_lockfile -name 'yarn.lock' ;;
    *) ;;
    esac
}

NODE_PM_ORDER=(pnpm npm yarn)

for pm in "${NODE_PM_ORDER[@]}"; do
    lockfile="$(lockfile_for "${pm}")"
    if [[ -n "${lockfile}" ]]; then
        NODE_PM="${pm}"
        NODE_PM_LOCKFILE="${lockfile#./}"
        break
    fi
done

if [[ -n "${NODE_PM_LOCKFILE}" ]]; then
    NODE_PM_WORKDIR="$(dirname "${NODE_PM_LOCKFILE}")"
fi

if [[ -f "${NODE_PM_WORKDIR}/package.json" ]]; then
    NODE_VERSION_FILE="${NODE_PM_WORKDIR}/package.json"
elif [[ -f "package.json" ]]; then
    NODE_VERSION_FILE="package.json"
fi

if [[ -n "${NODE_VERSION_FILE}" ]]; then
    package_manager=$(jq -r '.packageManager // empty' "${NODE_VERSION_FILE}" 2>/dev/null || true)
    [[ "${package_manager}" == pnpm@* ]] && PNPM_VERSION="${package_manager#pnpm@}"
fi

# Pre-commit detection =================================================
set -x
if [[ ! -f "${_PRE_COMMIT_CONFIG}" ]]; then
    echo "[INFO] ${_PRE_COMMIT_CONFIG} not found, skipping pre-commit action setup."
else
    npm_matches=$(grep -Ec "(npm|node)" "${_PRE_COMMIT_CONFIG}" || true)
    node_language_matches=$(grep -Ec "language: node" "${_PRE_COMMIT_CONFIG}" || true)
    IS_NPM=$((npm_matches - node_language_matches))

    if [[ "${IS_NPM}" -gt 0 && -z "${NODE_PM}" ]]; then
        echo "[ERROR] Node hooks detected in ${_PRE_COMMIT_CONFIG}, but no supported lockfile found. \
            Expected one of: pnpm-lock.yaml, package-lock.json, npm-shrinkwrap.json, \
            yarn.lock (at repo root or nested)." >&2
        exit 1
    fi

    PRE_COMMIT_RUN=1
    IS_TERRAFORM=$(grep -c "terraform" "${_PRE_COMMIT_CONFIG}" || true)
    IS_GOLANG=$(grep -E "\<(go|golang)\>" "${_PRE_COMMIT_CONFIG}" | grep -vEc "(language: go|gone|- repo)" || true)
fi

{
    echo "IS_TERRAFORM=${IS_TERRAFORM}"

    echo "IS_GOLANG=${IS_GOLANG}"
    echo "gomod_path=${GOMOD_PATH}"

    echo "IS_PYTHON=${IS_PYTHON}"
    echo "PYTHON_VERSION=${PYTHON_VERSION}"
    echo "PYTHON_VERSION_SPEC=${PYTHON_VERSION_SPEC}"
    echo "PYTHON_VERSION_SOURCE=${PYTHON_VERSION_SOURCE}"

    echo "IS_NPM=${IS_NPM}"
    echo "NODE_PM=${NODE_PM}"
    echo "NODE_PM_LOCKFILE=${NODE_PM_LOCKFILE}"
    echo "NODE_PM_WORKDIR=${NODE_PM_WORKDIR}"
    echo "NODE_VERSION_FILE=${NODE_VERSION_FILE}"
    echo "PNPM_VERSION=${PNPM_VERSION}"

    echo "PRE_COMMIT_RUN=${PRE_COMMIT_RUN}"
    echo "CACHE_MONTH=${CACHE_MONTH}"
} >>"${GITHUB_OUTPUT}"
