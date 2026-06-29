#!/usr/bin/env bash
#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
# Download a pinned istioctl into the target directory (arg $1, default /usr/local/bin).
# Referenced from .pkg_map.rc as a `script://` installer; the pre-commit action appends
# the cache bin dir as the final argument. Pin the version to the cluster's Istio minor
# so analyzer rules match. The version is renovate-tracked (see .github/renovate.json5).
set -euo pipefail

ISTIO_VERSION="1.30.2" # renovate: datasource=github-releases depName=istio/istio

target_dir="${1:-/usr/local/bin}"
mkdir -p "${target_dir}"

os="$(uname -s)"
arch="$(uname -m)"
case "${os}" in
Linux) os="linux" ;;
Darwin) os="osx" ;;
*)
    echo "ERROR: unsupported OS: ${os}" >&2
    exit 1
    ;;
esac
case "${arch}" in
x86_64 | amd64) arch="amd64" ;;
aarch64 | arm64) arch="arm64" ;;
*)
    echo "ERROR: unsupported arch: ${arch}" >&2
    exit 1
    ;;
esac

# istio publishes the osx amd64 asset without an arch suffix
if [[ "${os}" == "osx" && "${arch}" == "amd64" ]]; then
    asset="istioctl-${ISTIO_VERSION}-osx.tar.gz"
else
    asset="istioctl-${ISTIO_VERSION}-${os}-${arch}.tar.gz"
fi

base="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -fsSL -o "${tmp}/${asset}" "${base}/${asset}"
curl -fsSL -o "${tmp}/${asset}.sha256" "${base}/${asset}.sha256"

expected="$(awk '{print $1}' "${tmp}/${asset}.sha256")"
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
fi
if [[ "${expected}" != "${actual}" ]]; then
    echo "ERROR: istioctl checksum mismatch (expected ${expected}, got ${actual})" >&2
    exit 1
fi

tar -xzf "${tmp}/${asset}" -C "${tmp}" istioctl
install -m 0755 "${tmp}/istioctl" "${target_dir}/istioctl"
echo "Installed istioctl ${ISTIO_VERSION} to ${target_dir}/istioctl"
