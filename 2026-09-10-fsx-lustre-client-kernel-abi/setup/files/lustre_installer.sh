#!/usr/bin/env bash
# lustre_installer.sh — install the Amazon FSx for Lustre client on Ubuntu.
#
# The client is a kernel module, and the packaged modules are published per exact kernel
# release. That makes the documented install depend on a package name that carries the kernel
# release, and it breaks whenever the running kernel has no published module. This installer
# takes the other route: it registers the client source with DKMS, so the module is rebuilt
# automatically whenever a kernel is installed, and no package name depends on a kernel
# release. The shape mirrors efa_installer.sh so that both can be driven the same way.
#
#   ./lustre_installer.sh -y                     install with DKMS, verify, print a summary
#   ./lustre_installer.sh -y --mode binary       install the published module for this kernel
#   ./lustre_installer.sh -y --kernel 6.8.0-1063-aws
#   ./lustre_installer.sh --uninstall -y
#
# Options:
#   -y, --yes            do not ask for confirmation
#   -m, --mode MODE      dkms (default) or binary
#   -k, --kernel REL     kernel release to build for; defaults to the running kernel
#   -s, --suite NAME     repository suite; defaults to this system's codename
#   -n, --no-verify      skip the post-install verification
#   -u, --uninstall      remove what this installer added
#   -q, --quiet          less output
#   -v, --version        print the installer version and exit
#   -h, --help           print this help and exit
#
# Exit status is 0 on success. Every failure prints the reason and what to do about it.

set -euo pipefail

INSTALLER_VERSION="1.0.0"

REPO_BASE="${LUSTRE_REPO_BASE:-https://fsx-lustre-client-repo.s3.amazonaws.com/ubuntu}"
KEY_URL="${LUSTRE_REPO_KEY_URL:-https://fsx-lustre-client-repo-public-keys.s3.amazonaws.com/fsx-ubuntu-public-key.asc}"
KEYRING="${LUSTRE_REPO_KEYRING:-/usr/share/keyrings/fsx-ubuntu-public-key.gpg}"
SOURCES_LIST="/etc/apt/sources.list.d/fsxlustreclientrepo.list"
WORK_DIR="${LUSTRE_WORK_DIR:-/var/lib/lustre-installer}"

ASSUME_YES="false"
MODE="dkms"
KERNEL="$(uname -r)"
SUITE=""
VERIFY="true"
UNINSTALL="false"
QUIET="false"

BUILD_PACKAGES=(
    autoconf automake bison build-essential bzip2 debhelper dkms fakeroot flex
    libkeyutils-dev libmount-dev libnl-genl-3-dev libselinux-dev libsnmp-dev libssl-dev
    libtool libyaml-dev module-assistant mpi-default-dev pkg-config python3-dev quilt rsync
)

log() { [[ "${QUIET}" == "true" ]] || printf '%s\n' "$*"; }
step() { [[ "${QUIET}" == "true" ]] || printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y | --yes) ASSUME_YES="true"; shift ;;
        -m | --mode) MODE="${2:?--mode needs dkms or binary}"; shift 2 ;;
        -k | --kernel) KERNEL="${2:?--kernel needs a kernel release}"; shift 2 ;;
        -s | --suite) SUITE="${2:?--suite needs a codename}"; shift 2 ;;
        -n | --no-verify) VERIFY="false"; shift ;;
        -u | --uninstall) UNINSTALL="true"; shift ;;
        -q | --quiet) QUIET="true"; shift ;;
        -v | --version) printf 'lustre_installer.sh %s\n' "${INSTALLER_VERSION}"; exit 0 ;;
        -h | --help) usage 0 ;;
        *) printf 'error: unknown option %s\n' "$1" >&2; usage 2 ;;
    esac
done

[[ "${MODE}" == "dkms" || "${MODE}" == "binary" ]] || die "--mode takes dkms or binary, got ${MODE}"
[[ ${EUID} -eq 0 ]] || die "run this installer as root"

# ---------------------------------------------------------------- environment

require_ubuntu() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing; cannot identify the system"
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "this installer targets Ubuntu. On Amazon Linux 2023 the kernel package provides the
       module, so 'dnf install -y lustre-client' is all that is needed."
    fi
    SUITE="${SUITE:-${VERSION_CODENAME:?VERSION_CODENAME is missing from /etc/os-release}}"
    log "system:  ${PRETTY_NAME:-ubuntu} (${SUITE})"
    log "kernel:  ${KERNEL} (running: $(uname -r))"
    log "mode:    ${MODE}"
}

confirm() {
    [[ "${ASSUME_YES}" == "true" ]] && return 0
    read -r -p "Continue? [y/N] " reply
    [[ "${reply}" == "y" || "${reply}" == "Y" ]] || die "cancelled"
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@"
}

# ---------------------------------------------------------------- repository

add_repository() {
    step "Registering the FSx for Lustre client repository"
    apt_get install -y --no-install-recommends ca-certificates gpg wget >/dev/null
    if [[ ! -f "${KEYRING}" ]]; then
        wget -qO - "${KEY_URL}" | gpg --dearmor > "${KEYRING}"
        log "installed the signing key at ${KEYRING}"
    else
        log "signing key already present"
    fi
    local line="deb [signed-by=${KEYRING}] ${REPO_BASE} ${SUITE} main"
    if [[ ! -f "${SOURCES_LIST}" ]] || ! grep -qxF "${line}" "${SOURCES_LIST}"; then
        printf '%s\n' "${line}" > "${SOURCES_LIST}"
        log "wrote ${SOURCES_LIST}"
    else
        log "repository already registered"
    fi
    apt_get update >/dev/null
}

install_utils() {
    step "Installing the userspace tools"
    # Without /sbin/mount.lustre the kernel receives the raw option list and refuses the mount,
    # so the tools are not optional even when only the module is wanted.
    apt_get install -y lustre-client-utils >/dev/null
    [[ -x /sbin/mount.lustre ]] || die "lustre-client-utils did not provide /sbin/mount.lustre"
    log "lustre-client-utils $(dpkg-query -W -f='${Version}' lustre-client-utils)"
}

# ---------------------------------------------------------------- binary mode

install_binary_module() {
    step "Installing the published module for ${KERNEL}"
    local pkg="lustre-client-modules-${KERNEL}"
    if ! apt-cache policy "${pkg}" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        die "no ${pkg} package is published for ${SUITE}.
       Published modules cover only some kernel releases. Either run this installer without
       --mode binary, which builds the module with DKMS and follows kernel updates, or boot a
       kernel release the repository covers."
    fi
    apt_get install -y "${pkg}" >/dev/null
    log "${pkg} $(dpkg-query -W -f='${Version}' "${pkg}")"
}

# ---------------------------------------------------------------- dkms mode

source_version() {
    # lustre-source ships one tarball whose Debian version carries the packaging revision;
    # DKMS wants the upstream version, which is the part before the last hyphen.
    dpkg-query -W -f='${Version}' lustre-source | sed 's/-[^-]*$//'
}

install_dkms_tree() {
    step "Preparing the DKMS source tree"
    apt_get install -y "${BUILD_PACKAGES[@]}" >/dev/null
    apt_get install -y "linux-headers-${KERNEL}" >/dev/null
    [[ -d "/lib/modules/${KERNEL}/build" ]] ||
        die "/lib/modules/${KERNEL}/build is missing, so there is no kernel build tree to
       compile against. Install linux-headers-${KERNEL} and run this installer again."
    apt_get install -y lustre-source >/dev/null

    local version dest
    version="$(source_version)"
    dest="/usr/src/lustre-client-modules-${version}"
    log "lustre-source $(dpkg-query -W -f='${Version}' lustre-source) -> DKMS version ${version}"

    if [[ -f "${dest}/dkms.conf" ]]; then
        log "source tree already present at ${dest}"
        printf '%s\n' "${version}" > "${WORK_DIR}/version"
        return 0
    fi

    mkdir -p "${WORK_DIR}"
    rm -rf "${WORK_DIR}/src"
    mkdir -p "${WORK_DIR}/src"
    tar -xjf /usr/src/lustre-*.tar.bz2 -C "${WORK_DIR}/src"
    local tree="${WORK_DIR}/src/modules/lustre"
    [[ -f "${tree}/debian/dkms.conf.in" ]] ||
        die "the source package does not carry debian/dkms.conf.in, so DKMS mode cannot be used"

    rm -rf "${dest}"
    cp -a "${tree}" "${dest}"
    # This is what the source package's own DKMS target does: substitute the version into the
    # template. Building the DKMS .deb is skipped on purpose, because its dependencies are
    # written for Debian and name a linux-image metapackage Ubuntu does not ship.
    sed -e "s/[@]UPVERSION[@]/${version}/" "${tree}/debian/dkms.conf.in" > "${dest}/dkms.conf"
    printf '%s\n' "${version}" > "${WORK_DIR}/version"
    log "installed the source tree at ${dest}"
}

build_with_dkms() {
    local version
    version="$(cat "${WORK_DIR}/version")"
    step "Building the module with DKMS for ${KERNEL}"
    # dkms status is matched by text rather than queried per module, because the query form
    # differs between dkms releases while the printed form does not.
    if [[ ! -d "/var/lib/dkms/lustre-client-modules/${version}" ]]; then
        dkms add -m lustre-client-modules -v "${version}"
    else
        log "already registered with DKMS"
    fi
    if dkms status 2>/dev/null | grep -q "^lustre-client-modules/${version}, ${KERNEL},.*: installed"; then
        log "already installed for ${KERNEL}"
        return 0
    fi
    local start
    start="$(date +%s)"
    dkms build -m lustre-client-modules -v "${version}" -k "${KERNEL}" >"${WORK_DIR}/build.log" 2>&1 || {
        printf 'error: the DKMS build failed. The last lines of %s follow.\n' "${WORK_DIR}/build.log" >&2
        tail -n 25 "${WORK_DIR}/build.log" >&2
        die "the client source does not build against kernel ${KERNEL}"
    }
    dkms install -m lustre-client-modules -v "${version}" -k "${KERNEL}" --force >>"${WORK_DIR}/build.log" 2>&1
    log "built and installed in $(( $(date +%s) - start ))s"
    log "DKMS will rebuild this module whenever another kernel is installed"
}

# ---------------------------------------------------------------- verification

verify() {
    step "Verifying the client"
    local expected="${KERNEL}" vermagic
    vermagic="$(modinfo -F vermagic -k "${KERNEL}" lustre 2>/dev/null || true)"
    [[ -n "${vermagic}" ]] || die "no lustre module is installed for ${KERNEL}"
    [[ "${vermagic%% *}" == "${expected}" ]] ||
        die "the module reports ${vermagic%% *} but ${expected} was requested; the kernel refuses
       a module built for another release"
    log "module:  $(modinfo -F filename -k "${KERNEL}" lustre)"
    log "vermagic: ${vermagic}"

    if [[ "${KERNEL}" == "$(uname -r)" ]]; then
        modprobe lustre
        local missing=()
        for module in libcfs lnet lustre; do
            lsmod | grep -q "^${module} " || missing+=("${module}")
        done
        [[ ${#missing[@]} -eq 0 ]] || die "these modules did not load: ${missing[*]}"
        log "loaded:  $(lsmod | awk '$1=="lustre"{print $1" "$2" bytes"}')"
        log "client:  $(lctl --version)"
    else
        log "skipped the load check because ${KERNEL} is not running"
    fi
}

summary() {
    step "Summary"
    log "mode:    ${MODE}"
    log "kernel:  ${KERNEL}"
    dpkg-query -W -f='${Package} ${Version}\n' 'lustre*' 2>/dev/null | sed 's/^/package: /' || true
    if [[ "${MODE}" == "dkms" ]]; then
        dkms status 2>/dev/null | grep '^lustre-client-modules' | sed 's/^/dkms:    /' || true
    fi
    log ""
    log "Mounting a file system is left to you, for example:"
    log "  mount -t lustre -o noatime,flock <fs-dns-name>@tcp:/<mount-name> /mnt/fsx"
}

# ---------------------------------------------------------------- uninstall

uninstall() {
    step "Removing what this installer added"
    local version=""
    [[ -f "${WORK_DIR}/version" ]] && version="$(cat "${WORK_DIR}/version")"
    umount -a -t lustre 2>/dev/null || true
    lustre_rmmod 2>/dev/null || true
    if [[ -n "${version}" && -d "/var/lib/dkms/lustre-client-modules/${version}" ]]; then
        dkms remove -m lustre-client-modules -v "${version}" --all || true
        rm -rf "/usr/src/lustre-client-modules-${version}"
    fi
    apt_get remove -y 'lustre-client-modules-*' lustre-client-utils lustre-source >/dev/null 2>&1 || true
    rm -rf "${WORK_DIR}"
    log "the repository registration at ${SOURCES_LIST} was left in place"
}

# ---------------------------------------------------------------- main

require_ubuntu
if [[ "${UNINSTALL}" == "true" ]]; then
    confirm
    uninstall
    exit 0
fi
confirm
mkdir -p "${WORK_DIR}"
add_repository
install_utils
case "${MODE}" in
    binary) install_binary_module ;;
    dkms)
        install_dkms_tree
        build_with_dkms
        ;;
esac
[[ "${VERIFY}" == "true" ]] && verify
summary
