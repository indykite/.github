#!/bin/bash
#
# DO NOT EDIT!!!
# Managed by GitHub Action and synced from a private repo!
#
# pipefail - BASH only, not supported in POSIX Shell
set -o errexit -o nounset -o pipefail
# default values and check for the mandatory args
: "${IS_CACHE:="false"}"
: "${IS_DEBUG:="0"}"
: "${IS_NPM:="0"}"
: "${GITHUB_ENV:=""}"
: "${GITHUB_TOKEN:=""}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_MAP_FILE="${SCRIPT_DIR}/.pkg_map.rc"
PRECOMMIT_CFG=".pre-commit-config.yaml"
PRECOMMIT_CFG_CI=".pre-commit-config-ci.yaml"
CACHE_DIR="${HOME}/.cache"
CACHE_BIN="${CACHE_DIR}/bin"
# define cache prefixes
HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
PIP_PREFIX="${CACHE_DIR}/pip"
NPM_PREFIX="${CACHE_DIR}/npm"
NPM_CACHE="${HOME}/.npm"
mkdir -p "${HOMEBREW_PREFIX}" "${PIP_PREFIX}" "${NPM_PREFIX}"
# ensure Homebrew installs into ~/.cache/homebrew
PATH="${HOMEBREW_PREFIX}/bin:${PATH}"
# ensure pip installs into ~/.cache/pip
PYTHONUSERBASE="${PIP_PREFIX}"
PATH="${PIP_PREFIX}/bin:${PATH}"
PYTHONPATH="${PIP_PREFIX}/lib/python$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')/site-packages:${PYTHONPATH:-}"
# ensure npm installs into ~/.cache/npm
npm config set prefix "${NPM_PREFIX}"
npm set cache "${NPM_CACHE}"
PATH="${NPM_PREFIX}/bin:${PATH}"
NODE_PATH="${NPM_PREFIX}/lib/node_modules:${NODE_PATH:-}"
# golang paths
GOBIN="${CACHE_DIR}/go/bin"
PATH="${GOBIN}:${PATH}"
# custom script & curl support
PATH="${CACHE_BIN}:${PATH}"
mkdir -p "${CACHE_BIN}"
export HOMEBREW_PREFIX PATH PYTHONUSERBASE PYTHONPATH NODE_PATH GOBIN
#######################################
# Remove repos from .pre-commit-config.yaml that have `# ci:ignore` inline comments.
#######################################
disable_ci_ignored_repos() {
    local cfg="${1}"
    cp -- "${cfg}" "${PRECOMMIT_CFG_CI}"
    echo "[INFO] Copied ${cfg} -> ${PRECOMMIT_CFG_CI}"
    # Extract repo URLs marked with '# ci:ignore'
    mapfile -t ignored_repos < <(
        grep -E '^[[:space:]]*-[[:space:]]*repo:' "${PRECOMMIT_CFG_CI}" |
            grep '# ci:ignore' |
            sed -E 's/^[[:space:]]*-[[:space:]]*repo:[[:space:]]*([^[:space:]#]+).*/\1/' || true
    )
    if [[ ${#ignored_repos[@]} -eq 0 ]]; then
        echo "[INFO] No repos with ci:ignore found in ${PRECOMMIT_CFG_CI}"
        return 0
    fi
    echo "[INFO] Disabling repos with ci:ignore..."
    for repo in "${ignored_repos[@]}"; do
        echo "  - Removing repo: ${repo}"
        yq -i "del(.repos[] | select(.repo == \"${repo}\"))" "${PRECOMMIT_CFG_CI}"
    done
    echo "[INFO] Updated ${PRECOMMIT_CFG_CI}"
}
#######################################
#
#######################################
git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/indykite/".insteadOf "ssh://git@github.com/indykite/"
# pre-create the directory so npm commands don't fail
mkdir -p "${NPM_PREFIX}/lib/node_modules"
# propagate env vars to later workflow steps
{
    echo "PATH=${PATH}"
    echo "PYTHONPATH=${PYTHONPATH}"
    echo "NODE_PATH=${NODE_PATH}"
} >>"${GITHUB_ENV}"
#
echo "alias terraform='tofu'" >>"${HOME}/.bashrc"
eval "$(brew shellenv || true)" >>"${HOME}/.bashrc"
# shellcheck source=/dev/null
source "${HOME}/.bashrc"
# parse and install dependencies automatically
BREW_INSTALL=$(grep "brew install" .pre-commit-config.yaml |
    awk -F"brew install" '{ print $2 }' |
    xargs -n1 |
    xargs)
echo "[DEBUG] detected dependencies: ${BREW_INSTALL}"
#
# parse .pkg_map.rc into PKG_MAP
declare -A PKG_MAP
declare -A PKG_MANAGERS # dynamic manager → packages map
# normalize map file to unix line endings
MAP_FILE_CONTENT=$(tr -d '\r' <"${PKG_MAP_FILE}")
while read -r line; do
    # strip inline comments
    line="${line%%#*}"
    # trim whitespace
    line="$(echo -n "${line}" | xargs)"
    [[ -z "${line}" ]] && continue
    # split: first word = pkg, rest = target
    pkg="${line%%[[:space:]]*}"
    target="${line#"${pkg}"}"
    target="$(echo -n "${target}" | xargs)" # trim leading/trailing spaces
    if [[ -n "${pkg}" && -n "${target}" ]]; then
        PKG_MAP["${pkg}"]="${target}"
    fi
done <<<"${MAP_FILE_CONTENT}"
#
for pkg in ${BREW_INSTALL}; do
    target="${PKG_MAP[${pkg}]:-}"
    case "${target}" in
    pre-installed)
        echo "✅ ${pkg} is pre-installed, skipping."
        ;;
    action)
        echo "✅ ${pkg} is handled via separate GitHub Action, skipping."
        ;;
    *://*)
        manager="${target%%://*}" # part before "://"
        realpkg="${target#*://}"  # full string after scheme
        if [[ "${manager}" == "script" ]]; then
            # One script command per line
            PKG_MANAGERS["${manager}"]+="${realpkg}"$'\n'
        else
            # All other managers: keep space separation
            PKG_MANAGERS["${manager}"]+="${realpkg} "
        fi
        ;;
    "")
        # not mapped -> default to brew
        PKG_MANAGERS["brew"]+="${pkg} "
        ;;
    *)
        echo "⚠️ Unknown mapping for ${pkg} -> ${target}"
        exit 1
        ;;
    esac
done
echo -e "\n📦 Summary of detected dependencies per pkg manager / method of installation:"
for manager in "${!PKG_MANAGERS[@]}"; do
    if [[ "${manager}" == "script" ]]; then
        echo "  - ${manager}:"
        while IFS= read -r cmd; do
            [[ -z "${cmd}" ]] && continue
            echo "      * ${cmd}"
        done <<<"${PKG_MANAGERS[${manager}]}"
    else
        echo "  - ${manager}: ${PKG_MANAGERS[${manager}]}"
    fi
done
echo
# installed into './node_modules/' and not cached
if [[ ${IS_NPM} -gt 0 ]]; then
    npm ci --no-fund --cache "${NPM_CACHE}" --prefer-offline
fi
if [[ ${IS_CACHE} != "true" ]]; then
    echo -e "\nInstalling dependencies..."
    for manager in "${!PKG_MANAGERS[@]}"; do
        pkgs="${PKG_MANAGERS[${manager}]}"
        echo "⬇️ Installing via ${manager}: ${pkgs}"
        case "${manager}" in
        brew)
            # shellcheck disable=SC2086
            time brew install ${pkgs}
            ;;
        pip)
            # shellcheck disable=SC2086
            time python -m pip install -q --upgrade --user pre-commit ${pkgs} # 'pre-commit' is the must, so hard-coded just in case
            ;;
        npm)
            # shellcheck disable=SC2086
            time npm install -g ${pkgs}
            ;;
        go)
            # shellcheck disable=SC2086
            time for pkg in ${pkgs}; do
                go install "${pkg}" # must be installed individually
            done
            ;;
        script)
            time while IFS= read -r cmd; do
                [[ -z "${cmd}" ]] && continue
                echo "⬇️ Running installer script: ${cmd} ${CACHE_BIN}"
                eval "${cmd} ${CACHE_BIN}"
            done <<<"${PKG_MANAGERS["script"]}"
            ;;
        *)
            echo "⚠️ Unsupported manager: ${manager}"
            exit 1
            ;;
        esac
    done
fi
#
if [[ ${IS_DEBUG} == "1" ]]; then
    echo -e "\nInstalled versions:"
    set -x
    brew ls --versions || true
    python -m pip freeze --local || true
    npm list -g -all || true
    go list || true
fi
#
disable_ci_ignored_repos "${PRECOMMIT_CFG}"
time pre-commit install --config "${PRECOMMIT_CFG_CI}" --install-hooks -t pre-commit # don't install 'commit-msg'
#
if [[ ${IS_CACHE} != "true" ]]; then
    time {
        echo "[CLEANUP] remove all caches..."
        brew cleanup
        pip cache purge || true
        npm cache clean --force || true
        go clean -cache -modcache -testcache || true
        rm -rf "$(brew --cache || true)" \
            "${PIP_PREFIX}/http" "${PIP_PREFIX}/http-v2" "${PIP_PREFIX}/selfcheck" "${PIP_PREFIX}/wheels" "${PIP_PREFIX}/packages" \
            "${HOME}/.npm/_logs" "${NPM_PREFIX}/_logs" \
            "${CACHE_DIR}/go-build" # can be caused by 'script' type as well as 'pre-commit --install-hooks'
    }
    du -d 1 -h "${CACHE_DIR}"
fi
