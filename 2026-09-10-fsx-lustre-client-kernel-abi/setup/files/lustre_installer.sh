#!/usr/bin/env bash
# lustre_installer.sh — install the Amazon FSx for Lustre client on Ubuntu.
#
# The client is a kernel module, and the packaged modules are published per exact kernel
# release. That makes the documented install depend on a package name that carries the kernel
# release, and it breaks whenever the running kernel has no published module. This installer
# takes the source instead, and offers two ways to use it. build compiles the module for one
# kernel and installs it, which is what an image wants: the module is part of the artefact, a
# failed build fails the build, and nothing is compiled later on the running fleet. dkms registers
# the source so the module follows kernel installs, which is what a host that updates kernels in
# place wants, at the price of compiling on that host. The shape mirrors efa_installer.sh so
# that both can be driven the same way.
#
#   ./lustre_installer.sh -y                     build and install for this kernel, then verify
#   ./lustre_installer.sh -y --mode dkms         follow kernel installs from now on
#   ./lustre_installer.sh -y --mode binary       install the published module for this kernel
#   ./lustre_installer.sh -y --kernel 6.8.0-1063-aws
#   ./lustre_installer.sh --uninstall -y
#   ./lustre_installer.sh --check                 exit non-zero when this kernel has no module
#
# Options:
#   -y, --yes            do not ask for confirmation
#   -m, --mode MODE      build (default), dkms, or binary
#                          build  compile the module for one kernel and install it. Right for an
#                                 image: the module is part of the artefact, a failed build fails
#                                 the build, and nothing is compiled on the running fleet.
#                          dkms   register the source with DKMS so the module follows kernel
#                                 installs. Right for hosts that update kernels in place.
#                          binary install the published module, which exists for some releases
#   -k, --kernel REL     kernel release to build for; defaults to the running kernel
#   -s, --suite NAME     repository suite; defaults to this system's codename
#       --key-fingerprint FPR
#                        expected fingerprint of the repository signing key
#   -n, --no-verify      skip the post-install verification
#   -u, --uninstall      remove what this installer added
#   -c, --check          report whether the running kernel has a loadable module, then exit
#       --install-check-unit
#                        also install a systemd unit that runs --check at boot, so a kernel the
#                        client cannot follow is reported rather than discovered by a failed mount
#       --kernel-filter REGEX
#                        kernels DKMS may build for; defaults to the 6.x series, because the
#                        client source does not build against 7.x
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
# The key is pinned so that a substituted key is rejected rather than trusted. Override only if
# AWS rotates it, and check the new value against the published key before doing so.
KEY_FINGERPRINT="${LUSTRE_REPO_KEY_FINGERPRINT:-9C36DD9C515F10DBC3AA835C5D5CCC3383A962E1}"
SOURCES_LIST="/etc/apt/sources.list.d/fsxlustreclientrepo.list"
WORK_DIR="${LUSTRE_WORK_DIR:-/var/lib/lustre-installer}"

ASSUME_YES="false"
MODE="build"
KERNEL="$(uname -r)"
SUITE=""
VERIFY="true"
UNINSTALL="false"
CHECK="false"
INSTALL_CHECK_UNIT="false"
QUIET="false"
# DKMS runs from the kernel package's post-install hook. A build that fails there can leave the
# kernel package unconfigured, so kernels the source cannot support are excluded rather than
# attempted. 2.15.6 does not build against 7.x.
KERNEL_FILTER="${LUSTRE_KERNEL_FILTER:-^6\\.[0-9]+\\.}"

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
        --key-fingerprint) KEY_FINGERPRINT="${2:?--key-fingerprint needs a fingerprint}"; shift 2 ;;
        -n | --no-verify) VERIFY="false"; shift ;;
        -u | --uninstall) UNINSTALL="true"; shift ;;
        -c | --check) CHECK="true"; shift ;;
        --kernel-filter) KERNEL_FILTER="${2:?--kernel-filter needs a regex}"; shift 2 ;;
        --install-check-unit) INSTALL_CHECK_UNIT="true"; shift ;;
        -q | --quiet) QUIET="true"; shift ;;
        -v | --version) printf 'lustre_installer.sh %s\n' "${INSTALLER_VERSION}"; exit 0 ;;
        -h | --help) usage 0 ;;
        *) printf 'error: unknown option %s\n' "$1" >&2; usage 2 ;;
    esac
done

case "${MODE}" in
    build | dkms | binary) ;;
    *) die "--mode takes build, dkms or binary, got ${MODE}" ;;
esac
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

keyring_matches_pin() {
    local keyring="$1"
    [[ -z "${KEY_FINGERPRINT}" ]] && return 0
    gpg --show-keys --with-colons "${keyring}" 2>/dev/null |
        awk -F: '/^fpr:/{print $10}' | grep -qx "${KEY_FINGERPRINT}"
}

add_repository() {
    step "Registering the FSx for Lustre client repository"
    apt_get install -y --no-install-recommends ca-certificates gpg wget >/dev/null
    # A pipeline into the keyring truncates it before wget runs, so a failed download would
    # leave an empty file that later runs mistake for a working key. Build it aside and move it.
    if [[ -s "${KEYRING}" ]] && ! keyring_matches_pin "${KEYRING}"; then
        log "the existing keyring is not the pinned key; replacing it"
        rm -f "${KEYRING}"
    fi
    if [[ ! -s "${KEYRING}" ]]; then
        local tmp
        tmp="$(mktemp)"
        wget -qO - "${KEY_URL}" | gpg --dearmor > "${tmp}" || { rm -f "${tmp}"; die "could not download or convert the repository signing key from ${KEY_URL}"; }
        [[ -s "${tmp}" ]] || { rm -f "${tmp}"; die "the downloaded repository signing key is empty"; }
        keyring_matches_pin "${tmp}" || {
            rm -f "${tmp}"
            die "the downloaded repository key does not contain ${KEY_FINGERPRINT}. Either the
       key was rotated, in which case check the published key and pass --key-fingerprint, or
       the download was tampered with."
        }
        install -m 0644 "${tmp}" "${KEYRING}"
        rm -f "${tmp}"
        log "installed the signing key at ${KEYRING} (${KEY_FINGERPRINT})"
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
    if ! apt_get update >"${WORK_DIR}/apt-update.log" 2>&1; then
        log "a repository refresh reported errors; retrying with only the FSx source"
        grep -iE '^(E|W):' "${WORK_DIR}/apt-update.log" | head -5 || true
        apt_get update -o Dir::Etc::sourcelist="${SOURCES_LIST}" -o Dir::Etc::sourceparts=- \
            -o APT::Get::List-Cleanup=0 >/dev/null ||
            die "the FSx repository could not be refreshed; see ${WORK_DIR}/apt-update.log"
    fi
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

# ---------------------------------------------------------------- build mode

build_module_package() {
    step "Building a module package for ${KERNEL}"
    install_build_dependencies
    local tree="${WORK_DIR}/src/modules/lustre"
    unpack_source
    # module-assistant leaves the kernel trees unset and the tree has to be configured before it
    # is built, so both steps are driven explicitly.
    local start
    start="$(date +%s)"
    rm -f /usr/src/lustre-client-modules-"${KERNEL}"_*.deb
    (
        cd "${tree}"
        export KVERS="${KERNEL}" KSRC="/lib/modules/${KERNEL}/build" \
               KSRC_TREE="/lib/modules/${KERNEL}/build" \
               LINUX="/lib/modules/${KERNEL}/build" LINUX_OBJ="/lib/modules/${KERNEL}/build"
        fakeroot debian/rules kdist_config >"${WORK_DIR}/configure.log" 2>&1 || {
            tail -n 25 "${WORK_DIR}/configure.log" >&2
            exit 1
        }
        fakeroot debian/rules binary-modules >"${WORK_DIR}/build.log" 2>&1 || {
            tail -n 25 "${WORK_DIR}/build.log" >&2
            exit 1
        }
    ) || die "the client source does not build against kernel ${KERNEL}"
    local built
    built="$(find /usr/src -maxdepth 1 -name "lustre-client-modules-${KERNEL}_*.deb" | head -1)"
    [[ -n "${built}" ]] || die "the build produced no module package for ${KERNEL}"
    log "built $(basename "${built}") in $(( $(date +%s) - start ))s"
    apt_get install -y "${built}" >/dev/null
    depmod -a "${KERNEL}"
    log "installed the built package; nothing has to be rebuilt for this kernel again"
    log "the build dependencies stay installed, because other DKMS modules such as EFA need them"
    log "a kernel update will need this installer again, or --mode dkms to follow updates"
}

# ---------------------------------------------------------------- dkms mode

source_version() {
    # lustre-source ships one tarball whose Debian version carries the packaging revision;
    # DKMS wants the upstream version, which is the part before the last hyphen.
    dpkg-query -W -f='${Version}' lustre-source | sed -e 's/^[0-9]\+://' -e 's/-[^-]*$//'
}

set_kernel_filter() {
    local conf="$1"
    if grep -q '^BUILD_EXCLUSIVE_KERNEL=' "${conf}"; then
        sed -i "s|^BUILD_EXCLUSIVE_KERNEL=.*|BUILD_EXCLUSIVE_KERNEL=\"${KERNEL_FILTER}\"|" "${conf}"
    else
        printf 'BUILD_EXCLUSIVE_KERNEL="%s"\n' "${KERNEL_FILTER}" >> "${conf}"
    fi
    log "DKMS will skip kernels that do not match ${KERNEL_FILTER}"
}

install_build_dependencies() {
    apt_get install -y "${BUILD_PACKAGES[@]}" >/dev/null
    apt_get install -y "linux-headers-${KERNEL}" >/dev/null
    [[ -d "/lib/modules/${KERNEL}/build" ]] ||
        die "/lib/modules/${KERNEL}/build is missing, so there is no kernel build tree to
       compile against. Install linux-headers-${KERNEL} and run this installer again."
    apt_get install -y lustre-source >/dev/null
}

unpack_source() {
    local tarballs=()
    local candidate
    for candidate in /usr/src/lustre-*.tar.bz2; do
        [[ -f "${candidate}" ]] && tarballs+=("${candidate}")
    done
    [[ ${#tarballs[@]} -eq 1 ]] ||
        die "expected exactly one source tarball in /usr/src, found ${#tarballs[@]}${tarballs[*]+: ${tarballs[*]}}"
    rm -rf "${WORK_DIR}/src"
    mkdir -p "${WORK_DIR}/src"
    tar -xjf "${tarballs[0]}" -C "${WORK_DIR}/src"
    [[ -f "${WORK_DIR}/src/modules/lustre/debian/rules" ]] ||
        die "the unpacked source does not look like the expected tree"
}

install_dkms_tree() {
    step "Preparing the DKMS source tree"
    install_build_dependencies

    local version dest
    version="$(source_version)"
    dest="/usr/src/lustre-client-modules-${version}"
    log "lustre-source $(dpkg-query -W -f='${Version}' lustre-source) -> DKMS version ${version}"

    local package_version
    package_version="$(dpkg-query -W -f='${Version}' lustre-source)"
    if [[ -f "${dest}/dkms.conf" ]] &&
       [[ "$(cat "${WORK_DIR}/source-package-version" 2>/dev/null)" == "${package_version}" ]]; then
        log "source tree already present at ${dest}"
        printf '%s\n' "${version}" > "${WORK_DIR}/version"
        # The filter is policy, not content, so it is rewritten even when the tree is reused.
        set_kernel_filter "${dest}/dkms.conf"
        return 0
    fi
    if [[ -f "${dest}/dkms.conf" ]]; then
        # Same upstream version, different packaging revision: the tree has to be replaced and
        # every built module rebuilt, otherwise a fix in the new revision is silently skipped.
        log "the source package changed to ${package_version}; replacing the registered tree"
        dkms remove -m lustre-client-modules -v "${version}" --all >/dev/null 2>&1 || true
    fi

    unpack_source
    local tree="${WORK_DIR}/src/modules/lustre"
    [[ -f "${tree}/debian/dkms.conf.in" ]] ||
        die "the source package does not carry debian/dkms.conf.in, so DKMS mode cannot be used"

    rm -rf "${dest}"
    cp -a "${tree}" "${dest}"
    # This is what the source package's own DKMS target does: substitute the version into the
    # template. Building the DKMS .deb is skipped on purpose, because its dependencies are
    # written for Debian and name a linux-image metapackage Ubuntu does not ship.
    sed -e "s/[@]UPVERSION[@]/${version}/" "${tree}/debian/dkms.conf.in" > "${dest}/dkms.conf"
    set_kernel_filter "${dest}/dkms.conf"
    printf '%s\n' "${version}" > "${WORK_DIR}/version"
    dpkg-query -W -f='${Version}' lustre-source > "${WORK_DIR}/source-package-version"
    log "installed the source tree at ${dest}"
}

dkms_installed_for() {
    # dkms 2.x prints "name, version, kernel, arch: installed" and dkms 3.x prints
    # "name/version, kernel, arch: installed", so both forms are accepted.
    local version="$1" kernel="$2" status
    status="$(dkms status 2>/dev/null || true)"
    grep -qE "^lustre-client-modules[/,] ?${version//./\\.}, ${kernel//./\\.},.*: installed" <<<"${status}"
}

build_with_dkms() {
    local version
    version="$(cat "${WORK_DIR}/version")"
    step "Building the module with DKMS for ${KERNEL}"
    # dkms status is matched by text rather than queried per module, because the query form
    # differs between dkms releases while the printed form does not.
    # Every registered version is built on each kernel install, and an obsolete one failing can
    # fail the whole kernel transaction. Removing the source of a registration that is still
    # present would make that worse, so a failed removal stops the run.
    local other
    while IFS= read -r other; do
        [[ -n "${other}" && "${other}" != "${version}" ]] || continue
        log "removing the superseded DKMS registration ${other}"
        dkms remove -m lustre-client-modules -v "${other}" --all >/dev/null 2>&1 ||
            die "could not remove the superseded DKMS registration ${other}; resolve it with
       'dkms remove -m lustre-client-modules -v ${other} --all' and run this installer again"
        rm -rf "/usr/src/lustre-client-modules-${other}"
    done < <(find /var/lib/dkms/lustre-client-modules -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true)
    if [[ ! -d "/var/lib/dkms/lustre-client-modules/${version}" ]]; then
        dkms add -m lustre-client-modules -v "${version}"
    else
        log "already registered with DKMS"
    fi
    if dkms_installed_for "${version}" "${KERNEL}"; then
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
    dkms install -m lustre-client-modules -v "${version}" -k "${KERNEL}" --force >>"${WORK_DIR}/build.log" 2>&1 || {
        printf 'error: the module built but DKMS could not install it. The last lines of %s follow.\n' "${WORK_DIR}/build.log" >&2
        tail -n 25 "${WORK_DIR}/build.log" >&2
        die "DKMS install failed for ${KERNEL}"
    }
    log "built and installed in $(( $(date +%s) - start ))s"
    # Other kernels are already installed on an image that has been updated in place, and they
    # would otherwise keep an older module or none at all until their next reinstall.
    dkms autoinstall >>"${WORK_DIR}/build.log" 2>&1 || true
    log "DKMS will rebuild this module whenever a matching kernel is installed"
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
        local loaded missing=()
        # grep -q exits at the first match, which would send SIGPIPE to lsmod and, under
        # pipefail, look like a failure. Read the table once instead.
        loaded="$(lsmod)"
        for module in libcfs lnet lustre; do
            grep -q "^${module} " <<<"${loaded}" || missing+=("${module}")
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
    local failures=() mounts
    mounts="$(mount)"
    if grep -q ' type lustre ' <<<"${mounts}"; then
        umount -a -t lustre || failures+=("a mounted file system could not be unmounted")
    fi
    if lsmod | grep -q '^lustre '; then
        lustre_rmmod || failures+=("the client modules are still loaded")
    fi
    local version
    for version in $(ls /var/lib/dkms/lustre-client-modules 2>/dev/null || true); do
        dkms remove -m lustre-client-modules -v "${version}" --all ||
            failures+=("dkms could not remove ${version}")
        rm -rf "/usr/src/lustre-client-modules-${version}"
    done
    local packages=()
    for pkg in $(dpkg-query -W -f='${Package}\n' 'lustre-client-modules-*' lustre-source 2>/dev/null || true); do
        packages+=("${pkg}")
    done
    if [[ ${#packages[@]} -gt 0 ]]; then
        apt_get remove -y "${packages[@]}" >/dev/null || failures+=("apt could not remove ${packages[*]}")
    fi
    log "lustre-client-utils was left installed; remove it separately if nothing else needs it"
    rm -rf "${WORK_DIR}"
    log "the repository registration at ${SOURCES_LIST} was left in place"
    if [[ ${#failures[@]} -gt 0 ]]; then
        printf 'error: the removal was incomplete:\n' >&2
        printf '  - %s\n' "${failures[@]}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------- boot-time check

install_check_unit() {
    step "Installing the boot-time check"
    # DKMS skips kernels outside the filter and can fail on a kernel the source does not
    # support. Either way the node boots without a client and a mount is the first thing that
    # notices. This unit makes the state visible at boot instead. It reports; it does not block
    # boot, because a node that refuses to start is worse than one that reports a fault.
    # The unit must not point at wherever the script happened to be run from, so a copy with a
    # stable path is what it calls.
    local self installed=/usr/local/sbin/lustre_installer.sh
    self="$(readlink -f "$0")"
    if [[ "${self}" != "${installed}" ]]; then
        install -m 0755 "${self}" "${installed}"
    fi
    local unit=/etc/systemd/system/lustre-client-check.service
    cat > "${unit}" <<UNIT
[Unit]
Description=Report whether a Lustre client module is available for the running kernel
After=local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${installed} --check

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable lustre-client-check.service >/dev/null 2>&1 ||
        die "could not enable lustre-client-check.service"
    log "installed ${unit}; check it with 'systemctl status lustre-client-check'"
}

# ---------------------------------------------------------------- check

check_only() {
    # Meant for a node health check: after a kernel update DKMS may have skipped or failed, and
    # a host with no module for its running kernel cannot mount, which is otherwise silent.
    local running vermagic
    running="$(uname -r)"
    vermagic="$(modinfo -F vermagic lustre 2>/dev/null || true)"
    if [[ -z "${vermagic}" ]]; then
        printf 'no lustre module is available for the running kernel %s\n' "${running}" >&2
        exit 1
    fi
    if [[ "${vermagic%% *}" != "${running}" ]]; then
        printf 'the installed module targets %s but the running kernel is %s\n' "${vermagic%% *}" "${running}" >&2
        exit 1
    fi
    if ! modprobe lustre 2>/dev/null; then
        printf 'the module for %s exists but does not load\n' "${running}" >&2
        exit 1
    fi
    local loaded module
    loaded="$(lsmod)"
    for module in libcfs lnet lustre; do
        grep -q "^${module} " <<<"${loaded}" || {
            printf '%s is not resident after loading the client\n' "${module}" >&2
            exit 1
        }
    done
    [[ -x /sbin/mount.lustre ]] || { printf '/sbin/mount.lustre is missing\n' >&2; exit 1; }
    log "ok: lustre module present and loadable for ${running}"
}

# ---------------------------------------------------------------- main

require_ubuntu
if [[ "${CHECK}" == "true" ]]; then
    check_only
    exit 0
fi
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
    build) build_module_package ;;
    dkms)
        install_dkms_tree
        build_with_dkms
        ;;
esac
[[ "${INSTALL_CHECK_UNIT}" == "true" ]] && install_check_unit
[[ "${VERIFY}" == "true" ]] && verify
summary
