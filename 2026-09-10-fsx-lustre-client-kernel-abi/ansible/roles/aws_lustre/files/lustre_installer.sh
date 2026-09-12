#!/usr/bin/env bash
# lustre_installer.sh — install the Amazon FSx for Lustre client on Ubuntu.
#
# The client is a kernel module, and the packaged modules are published per exact kernel release.
# That makes the documented install depend on a package name that carries the kernel release, and
# it breaks whenever the running kernel has no published module. Two of the three modes here build
# from the source package instead, so the kernel release stops being part of what has to be
# available; the third installs the published module for hosts where one exists.
#
#   ./lustre_installer.sh -y
#   ./lustre_installer.sh -y --mode dkms
#   ./lustre_installer.sh -y --kernel 6.8.0-1063-aws
#   ./lustre_installer.sh --uninstall -y
#   ./lustre_installer.sh --check
#   ./lustre_installer.sh --refresh-policy
#
# Options:
#   -y, --yes            do not ask for confirmation
#   -m, --mode MODE      build (default), dkms, or binary
#                          build  compile the module for one kernel and install it. Right for an
#                                 image: the module is part of the artefact, a failed build fails
#                                 the build, and nothing is compiled on the running fleet
#                          dkms   register the source with DKMS so the module follows kernel
#                                 installs. Right for a host that updates kernels in place, at the
#                                 price of compiling on that host
#                          binary install the published module, which exists for some releases
#   -k, --kernel REL     kernel release to install for; defaults to the running kernel
#   -s, --suite NAME     repository suite; defaults to this system's codename
#       --key-fingerprint FPR
#                        expected fingerprint of the repository signing key
#   -n, --no-verify      skip the post-install verification
#   -u, --uninstall      remove every Lustre client on this host: the modules, any DKMS
#                        registration under the client's module name, the source trees, the module
#                        packages and the boot check
#   -c, --check          exit 0 when the running kernel has a loadable, mountable module and
#                        non-zero with the reason when it does not, then stop
#       --install-check-unit
#                        also install a systemd unit that runs --check at boot, so a kernel the
#                        client cannot follow is reported rather than discovered by a failed mount
#       --kernel-filter REGEX
#                        kernels DKMS may build for. By default this is derived from the kernel
#                        series the repository actually publishes modules for, so a newly supported
#                        series is picked up by --refresh-policy or by the next install, with no
#                        change to this script
#       --refresh-policy refresh that derived list and exit. Safe to run from cron or a
#                        configuration run; it does not rebuild anything
#   -q, --quiet          less output
#   -v, --version        print the installer version and exit
#   -h, --help           print this help and exit
#
# Exit status is 0 on success. A failed build or apt run prints the last lines of its log and where
# the whole log is.
# END-OF-HELP

set -euo pipefail

# Several decisions are taken by reading the output of apt, gpg and dkms, and that output is
# translated. Fixing the locale keeps those reads working on a host that is not in English.
export LC_ALL=C

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
ACTION="install"
INSTALL_CHECK_UNIT="false"
QUIET="false"
# DKMS runs from the kernel package's post-install hook. A build that fails there can leave the
# kernel package unconfigured, so kernels the source cannot support are excluded rather than
# attempted. Which kernels those are is not a constant: the repository gains series over time, so
# the list is derived from what it publishes and kept here, and every install and --refresh-policy
# copies it into the DKMS configuration. Setting --kernel-filter overrides the derivation.
POLICY_FILE="${LUSTRE_POLICY_FILE:-/etc/lustre-installer/supported-kernels}"
# Used when the policy file is missing or unusable. It defaults to the series of the kernel this run
# was asked for, which is the narrowest answer available at that point; a constant here would go
# stale and either exclude a working series or admit a broken one.
POLICY_FALLBACK="${LUSTRE_POLICY_FALLBACK:-}"
KERNEL_FILTER=""

# What a clean Ubuntu host needs to compile the client. flex, bison and python3-dev are here
# because lustre-source does not declare them, checked against 2.15.6-1fsx34: apt-get build-dep
# alone leaves a tree that fails partway through configure. Drop them once it does declare them.
BUILD_PACKAGES=(
    autoconf automake bison build-essential bzip2 debhelper dkms fakeroot flex
    libkeyutils-dev libmount-dev libnl-genl-3-dev libselinux-dev libsnmp-dev libssl-dev
    libtool libyaml-dev module-assistant mpi-default-dev pkg-config python3-dev quilt rsync
)

log() { [[ "${QUIET}" == "true" ]] || printf '%s\n' "$*"; }
# Functions whose output is captured have to warn on stderr, or the warning becomes part of the
# value the caller reads.
warn() { printf 'warning: %s\n' "$*" >&2; }
step() { [[ "${QUIET}" == "true" ]] || printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    # Printing to the marker rather than to a line number means adding an option cannot silently
    # truncate the help.
    sed -n '2,/^# END-OF-HELP$/p' "${BASH_SOURCE[0]}" |
        sed -e '/^# END-OF-HELP$/d' -e 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Taking the value here rather than through ${2:?...} keeps a missing argument in this script's
# error format rather than bash's.
need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; printf '%s' "$2"; }
select_action() {
    [[ "${ACTION}" == "install" ]] || die "$1 and --${ACTION} both ask for a different run; pass one"
    ACTION="$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y | --yes) ASSUME_YES="true"; shift ;;
        -m | --mode) MODE="$(need_value "$@")"; shift 2 ;;
        -k | --kernel) KERNEL="$(need_value "$@")"; shift 2 ;;
        -s | --suite) SUITE="$(need_value "$@")"; shift 2 ;;
        --key-fingerprint) KEY_FINGERPRINT="$(need_value "$@")"; shift 2 ;;
        -n | --no-verify) VERIFY="false"; shift ;;
        -u | --uninstall) select_action "$1" uninstall; shift ;;
        -c | --check) select_action "$1" check; shift ;;
        --kernel-filter) KERNEL_FILTER="$(need_value "$@")"; shift 2 ;;
        --refresh-policy) select_action "$1" refresh-policy; shift ;;
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
[[ "${KERNEL}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+ ]] ||
    die "--kernel wants a kernel release such as 6.8.0-1063-aws, got ${KERNEL}"
if [[ -z "${POLICY_FALLBACK}" ]]; then
    kernel_minor="${KERNEL#*.}"
    POLICY_FALLBACK="^${KERNEL%%.*}\\.${kernel_minor%%.*}\\."
    unset kernel_minor
fi
# The fallback ends up inside single quotes in generated shell, so a quote or a newline in it would
# produce a dkms.conf that does not parse.
[[ "${POLICY_FALLBACK}" != *"'"* && "${POLICY_FALLBACK}" != *$'\n'* ]] ||
    die "the kernel policy fallback must be one line and must not contain a single quote"
# gpg's colon output prints uppercase hex with no separators, so a fingerprint copied from a web
# page with spaces or in lower case is normalised rather than rejected.
KEY_FINGERPRINT="$(printf '%s' "${KEY_FINGERPRINT}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
[[ -n "${KEY_FINGERPRINT}" ]] ||
    warn "no key fingerprint is set, so the repository key is trusted as downloaded"
# Every action needs root, --check included: it answers "can this host mount" by loading the
# module, which is the failure it exists to catch and which an unprivileged caller cannot try.
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
    # The mode decides nothing outside an install, and reporting it during --refresh-policy or
    # --uninstall says something that is not about what is happening.
    [[ "${ACTION}" != "install" ]] || log "mode:    ${MODE}"
}

confirm() {
    [[ "${ASSUME_YES}" == "true" ]] && return 0
    read -r -p "Continue? [y/N] " reply
    [[ "${reply}" == "y" || "${reply}" == "Y" ]] || die "cancelled"
}

apt_get() {
    # unattended-upgrades runs on a fresh Ubuntu host and holds the dpkg lock for minutes, so
    # without a timeout an install started at the wrong moment fails for that alone.
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 "$@"
}

take_lock() {
    # apt guards its own database, but the source tree, the DKMS registration, the keyring, the
    # policy file and the build artefacts are all shared state with no lock of their own, and a
    # fleet tool that runs this twice on one host would interleave them.
    exec 9>"${WORK_DIR}/lock"
    flock -w 900 9 || die "another lustre_installer.sh run is holding ${WORK_DIR}/lock"
}

# ---------------------------------------------------------------- repository

fetch_url() {
    # wget takes http_proxy and https_proxy from the environment, but it cannot see a proxy that is
    # configured only for apt through Acquire::http::Proxy, so such a host has to export those too.
    # The explicit timeout keeps a blackholed route from stalling the run for wget's own default,
    # which is measured in minutes.
    command -v wget >/dev/null 2>&1 ||
        die "wget is needed to read ${1} and is not installed. Install it with
       'apt-get install -y wget' and run this installer again."
    wget -q --timeout=15 --tries=3 -O - "$1"
}

policy_is_valid_pattern() {
    # dkms.conf is shell that DKMS sources as root, so the pattern is restricted to what a kernel
    # series regex needs and nothing that means something to a shell. Without this an operator, or
    # anything that can write the policy file, could put a command substitution into a file this
    # installer copies into a root-sourced configuration.
    local pattern="$1"
    [[ -n "${pattern}" && "${pattern}" != *$'\n'* ]] || return 1
    [[ "${pattern}" != *[[:space:]]* ]] || return 1
    # Held in a variable because an unquoted bracket expression containing $( ) would be read as a
    # command substitution before it ever reached the regular expression engine.
    # shellcheck disable=SC2016 # the dollar signs are regex anchors, not expansions
    local allowed='^[A-Za-z0-9._^$()|\{}?*+-]+$'
    [[ "${pattern}" =~ ${allowed} ]] || return 1
    # And it has to compile, or DKMS would match nothing and skip every kernel in silence. A child
    # bash is used so the exit status belongs to a command: 0 matched, 1 did not, 2 did not compile.
    local probe=0
    bash -c '[[ 6.8.0-1063-aws =~ $1 ]]' _ "${pattern}" 2>/dev/null || probe=$?
    [[ ${probe} -le 1 ]]
}

write_policy() {
    # This file is where the policy is kept between runs, and every way of setting it goes through
    # here so that one function decides what a policy may be.
    # Padding from an editor or a configuration tool is trimmed; it would otherwise become part of
    # the regex and match no kernel release at all, skipping every build in silence.
    local pattern="$1"
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    policy_is_valid_pattern "${pattern}" ||
        die "'${pattern}' cannot be used as a kernel policy. It has to be one line, with no
       whitespace, made only of the characters a kernel series pattern needs, and it has to compile
       as an extended regular expression."
    mkdir -p "$(dirname "${POLICY_FILE}")"
    local tmp
    tmp="$(mktemp "${POLICY_FILE}.XXXXXX")"
    printf '%s\n' "${pattern}" > "${tmp}"
    # mktemp creates the file readable only by root and mv would keep that mode. This is the record
    # of which kernels a host builds for; anything that inspects a fleet should be able to read it.
    chmod 0644 "${tmp}"
    # Replaced whole, so no reader can see half of a new pattern.
    mv "${tmp}" "${POLICY_FILE}"
    log "kernel policy: ${pattern} (${POLICY_FILE})"
}

derive_policy() {
    # The uncompressed index is read directly rather than through apt, because apt's indexes do
    # not exist yet the first time this runs and this has to work before the source list is added.
    # What the repository publishes is a proxy for what the source compiles against, not proof of
    # it: it is the only machine-readable signal, and it is conservative in the direction that
    # matters, because AWS publishes for a series only after building for it.
    local index url series pattern
    url="${REPO_BASE}/dists/${SUITE}/main/binary-$(dpkg --print-architecture)/Packages"
    index="$(fetch_url "${url}" 2>/dev/null || true)"
    if [[ -z "${index}" ]]; then
        log "could not read ${url}; keeping the current policy"
        return 1
    fi
    # -aws is the standard flavour and -aws-64k the 64 KB page one on arm64. Both collapse to the
    # same series, which is the granularity the policy records: a source build is per kernel
    # release, so a flavour distinction would exclude releases that build perfectly well.
    series="$(printf '%s\n' "${index}" |
        sed -nE 's/^Package: lustre-client-modules-([0-9]+\.[0-9]+)\..*-aws(-64k)?$/\1/p' |
        sort -u -V)"
    [[ -n "${series}" ]] || { log "the index lists no module packages; keeping the current policy"; return 1; }
    pattern="^($(printf '%s\n' "${series}" | sed 's/\./\\./g' | paste -sd'|' -))\."
    # shellcheck disable=SC2086 # unquoted to join the one-per-line series into one log line
    log "supported kernel series from the repository: $(printf '%s ' ${series})"
    write_policy "${pattern}"
    return 0
}

policy_is_usable() {
    # The same judgement write_policy makes, applied to a file this installer may not have written.
    # Nothing that fails here reaches dkms.conf.
    [[ -s "$1" ]] || return 1
    policy_is_valid_pattern "$(cat "$1")"
}

current_policy() {
    # A reader, and only a reader: what this returns is what the next write puts into dkms.conf, so
    # an unusable file is reported and stepped over rather than rewritten behind the operator.
    if policy_is_usable "${POLICY_FILE}"; then
        cat "${POLICY_FILE}"
        return 0
    fi
    [[ ! -e "${POLICY_FILE}" ]] ||
        warn "${POLICY_FILE} is not a single-line pattern and is being ignored; run
       --refresh-policy to replace it"
    printf '%s\n' "${POLICY_FALLBACK}"
}

keyring_matches_pin() {
    # signed-by makes apt trust every key in the file, so the pin has to bound the file rather than
    # merely appear in it: one primary key, and it is the pinned one.
    local keyring="$1" keys primaries
    [[ -z "${KEY_FINGERPRINT}" ]] && return 0
    keys="$(gpg --show-keys --with-colons "${keyring}" 2>/dev/null || true)"
    primaries="$(grep -c '^pub:' <<<"${keys}" || true)"
    [[ "${primaries}" == "1" ]] || return 1
    grep -qx "${KEY_FINGERPRINT}" <<<"$(awk -F: '/^fpr:/{print $10}' <<<"${keys}")"
}

no_suite_message() {
    cat <<MESSAGE
the repository has no ${SUITE} suite. That is the normal state for a release AWS has not
       onboarded, and it is not something this installer can work around. Until it appears, point
       at a suite that exists and build the module locally, which works because the module is
       compiled against this host's kernel either way:
         ${0} -y --mode dkms --suite noble
       The userspace tools then also come from that suite; check that they run before relying on
       them.
MESSAGE
}

suite_exists() {
    # Asking before writing anything separates "AWS has not onboarded this release" from "apt is
    # unhappy for some other reason", and reports the first without leaving a source list behind.
    # Only a 404 is read as absent. A 403, a redirect to a login page or an unreachable host are
    # what a proxy or an inspecting middlebox look like, and apt reaches the repository through
    # configuration this check cannot see, so those are left for apt to report.
    local response
    response="$(wget -q --spider --server-response --timeout=15 --tries=1 \
        "${REPO_BASE}/dists/${SUITE}/Release" 2>&1 || true)"
    ! grep -qE 'HTTP/[0-9.]+ 404' <<<"${response}"
}

add_repository() {
    step "Registering the FSx for Lustre client repository"
    apt_get install -y --no-install-recommends ca-certificates gpg wget >/dev/null
    # Before the keyring or the source list, because those are the first things this run would
    # change and a release AWS has not onboarded is worth reporting without changing anything.
    suite_exists || die "$(no_suite_message)"
    if [[ -s "${KEYRING}" ]] && keyring_matches_pin "${KEYRING}"; then
        log "signing key already present"
    else
        # The keyring is built aside and moved into place: writing it directly would truncate a
        # working key before the download is proven, turning a network failure into a host that
        # can no longer use a repository it could use a moment ago.
        local tmp
        tmp="$(mktemp)"
        # shellcheck disable=SC2064
        trap "rm -f '${tmp}'" EXIT
        fetch_url "${KEY_URL}" | gpg --dearmor > "${tmp}" ||
            die "could not download or convert the repository signing key from ${KEY_URL}"
        [[ -s "${tmp}" ]] || die "the downloaded repository signing key is empty"
        keyring_matches_pin "${tmp}" ||
            die "the downloaded repository key does not contain ${KEY_FINGERPRINT}. Either the
       key was rotated, in which case check the published key and pass --key-fingerprint, or
       something between this host and ${KEY_URL} replaced it."
        install -m 0644 "${tmp}" "${KEYRING}"
        rm -f "${tmp}"
        trap - EXIT
        log "installed the signing key at ${KEYRING} (${KEY_FINGERPRINT:-unpinned})"
    fi
    # This installer owns exactly this path, and rewrites it when it does not already say what this
    # run needs. A source list at any other path is the administrator's and is left alone.
    local line="deb [signed-by=${KEYRING}] ${REPO_BASE} ${SUITE} main"
    local wrote_sources_list="false"
    if [[ ! -f "${SOURCES_LIST}" ]] || ! grep -qxF "${line}" "${SOURCES_LIST}"; then
        printf '%s\n' "${line}" > "${SOURCES_LIST}"
        wrote_sources_list="true"
        log "wrote ${SOURCES_LIST}"
    else
        log "repository already registered"
    fi
    if ! apt_get update >"${WORK_DIR}/apt-update.log" 2>&1; then
        # Some other source on the host is broken. That is not this installer's to fix, and it is
        # not a reason to stop, so the FSx source alone is refreshed and the rest is reported. The
        # host's apt configuration stays as broken as it was, which the operator has to see.
        log "a repository refresh reported errors from at least one source; see ${WORK_DIR}/apt-update.log"
        grep -iE '^(E|W):' "${WORK_DIR}/apt-update.log" | head -5 || true
        log "retrying with only the FSx source, which is the one this installer needs"
        if ! apt_get update -o Dir::Etc::sourcelist="${SOURCES_LIST}" -o Dir::Etc::sourceparts=- \
                -o APT::Get::List-Cleanup=0 >/dev/null; then
            if [[ "${wrote_sources_list}" == "true" ]]; then
                rm -f "${SOURCES_LIST}"
                die "the FSx repository could not be refreshed; see ${WORK_DIR}/apt-update.log.
       The source list this run added has been removed so apt is left usable."
            fi
            die "the FSx repository could not be refreshed; see ${WORK_DIR}/apt-update.log.
       ${SOURCES_LIST} was already there before this run and has been left as it was."
        fi
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
    local pkg="lustre-client-modules-${KERNEL}" policy
    # Read once, then match: see module_state for why grep -q must not terminate a pipe here.
    policy="$(apt-cache policy "${pkg}" 2>&1)" ||
        die "apt-cache could not be queried, so whether ${pkg} is published is unknown:
       ${policy}"
    if ! grep -q 'Candidate: [0-9]' <<<"${policy}"; then
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
    install_source_package
    local tree="${WORK_DIR}/src/modules/lustre"
    unpack_source
    # kdist_config is where the tree learns which kernel it is being built against, and it takes
    # that only from the environment, so the two steps are driven explicitly with KVERS and KSRC
    # set rather than through module-assistant, which would pick the running kernel.
    local start
    start="$(date +%s)"
    # The package lands in /usr/src rather than beside the tree, because that is where the tree's
    # own rules put it. Clearing same-named artefacts first is what lets the search below insist on
    # finding exactly one, instead of picking up a package an earlier run left there.
    rm -f /usr/src/lustre-client-modules-"${KERNEL}"_*.deb \
          "${WORK_DIR}"/src/lustre-client-modules-"${KERNEL}"_*.deb
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
    local built=() candidate
    for candidate in /usr/src/lustre-client-modules-"${KERNEL}"_*.deb \
                     "${WORK_DIR}"/src/lustre-client-modules-"${KERNEL}"_*.deb; do
        [[ -f "${candidate}" ]] && built+=("${candidate}")
    done
    [[ ${#built[@]} -eq 1 ]] ||
        die "the build should have produced one module package for ${KERNEL} and produced ${#built[@]}${built[*]+: ${built[*]}}"
    log "built $(basename "${built[0]}") in $(( $(date +%s) - start ))s"
    apt_get install -y "${built[0]}" >/dev/null
    depmod -a "${KERNEL}"
}

# ---------------------------------------------------------------- dkms mode

source_version() {
    # lustre-source ships one tarball whose Debian version is [epoch:]upstream-revision; DKMS wants
    # the upstream part, so an epoch and the last hyphenated field are dropped.
    dpkg-query -W -f='${Version}' lustre-source | sed -E -e 's/^[0-9]+://' -e 's/-[^-]*$//'
}

set_kernel_filter() {
    # The policy reaches dkms.conf as a literal pattern, written by this installer and by nothing
    # else. An earlier revision put a command substitution here so that editing the policy file
    # alone would take effect; that made every later DKMS operation, including the one a kernel
    # package runs from its post-install hook, depend on reading a mutable path. A read that
    # returned part of a file, a path replaced by a FIFO, or a fallback value that echo interprets
    # each produced a pattern matching no kernel at all, silently. Rewriting the line is what
    # --refresh-policy does, so nothing is lost but the hand edit that skips it.
    # Any assignment already present is dropped rather than edited, because the pattern contains
    # characters a substitution would collide with, and the file is replaced whole so a failure
    # cannot leave it half written.
    local conf="$1" pattern tmp
    pattern="$(current_policy)"
    tmp="$(mktemp "${conf}.XXXXXX")"
    grep -v -E '^[[:space:]]*(export[[:space:]]+)?BUILD_EXCLUSIVE_KERNEL=' "${conf}" > "${tmp}" || true
    # Single quotes, because DKMS sources this file: inside double quotes a dollar sign or a
    # backtick in the pattern would be expanded by the shell running the kernel package's hook.
    # policy_is_valid_pattern refuses a quote, so the quoting here cannot be escaped from.
    printf "BUILD_EXCLUSIVE_KERNEL='%s'\n" "${pattern}" >> "${tmp}"
    chmod --reference="${conf}" "${tmp}" 2>/dev/null || chmod 0644 "${tmp}"
    mv "${tmp}" "${conf}"
    log "DKMS will build only for kernels matching ${pattern}"
}

effective_policy() {
    # What DKMS will actually use for a version, read back from the configuration rather than from
    # the policy file. These are two copies now, and only this one decides anything.
    sed -nE "s/^BUILD_EXCLUSIVE_KERNEL='(.*)'$/\\1/p" \
        "/usr/src/lustre-client-modules-$1/dkms.conf" 2>/dev/null | tail -1
}

apply_policy_to_registered_tree() {
    # The registered configuration holds a literal pattern, so a refreshed policy file means nothing
    # until it is copied there. This is what makes --refresh-policy enough on its own: the module is
    # not re-registered and nothing is rebuilt, only the line that decides which kernels DKMS may
    # build for. Rewriting is idempotent.
    # Every registration this installer owns is visited, not just the most recent one, because any
    # of them is built on every kernel install. A registration that cannot be reached is reported as
    # a failure: exiting 0 after changing nothing would be the refresh telling the operator that a
    # widened policy is in effect when it is not.
    local version conf found="false" unreachable=() foreign=()
    while IFS= read -r version; do
        [[ -n "${version}" ]] || continue
        if ! owns_version "${version}"; then
            foreign+=("${version}")
            continue
        fi
        conf="/usr/src/lustre-client-modules-${version}/dkms.conf"
        if [[ ! -f "${conf}" ]]; then
            unreachable+=("${version}")
            continue
        fi
        set_kernel_filter "${conf}"
        log "version ${version} now builds for $(effective_policy "${version}")"
        found="true"
    done < <(registered_dkms_versions)
    [[ ${#foreign[@]} -eq 0 ]] ||
        warn "these DKMS registrations were not created by this installer and were left as they
       are: ${foreign[*]}. They keep whatever kernel policy they already had."
    if [[ ${#unreachable[@]} -gt 0 ]]; then
        die "the policy file was refreshed but these registrations could not be updated:
       ${unreachable[*]}. Their source trees have no dkms.conf, so DKMS still applies the policy
       they were registered with. Run this installer in --mode dkms to re-register them."
    fi
    [[ "${found}" == "true" ]] ||
        log "no registration of this installer's is present, so the refreshed policy applies to the
      next install"
}

install_build_dependencies() {
    apt_get install -y "${BUILD_PACKAGES[@]}" >/dev/null
    apt_get install -y "linux-headers-${KERNEL}" >/dev/null
    [[ -d "/lib/modules/${KERNEL}/build" ]] ||
        die "/lib/modules/${KERNEL}/build is missing, so there is no kernel build tree to
       compile against. Install linux-headers-${KERNEL} and run this installer again."
}

install_source_package() {
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
    step "Deciding which kernel series DKMS may build for"
    if [[ -n "${KERNEL_FILTER}" ]]; then
        write_policy "${KERNEL_FILTER}"
    else
        derive_policy || [[ -e "${POLICY_FILE}" ]] ||
            warn "the repository could not be read and no policy file exists, so DKMS will build
       only for ${POLICY_FALLBACK} until '--refresh-policy' succeeds. Other kernel series this
       client supports will be skipped without further notice."
    fi
    log "policy in effect: $(current_policy)"

    step "Preparing the DKMS source tree"
    install_build_dependencies
    install_source_package

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
        set_kernel_filter "${dest}/dkms.conf"
        return 0
    fi
    # The replacement is prepared before anything is torn down. Removing the registration first
    # would mean a failure while unpacking left the host with neither the old coverage nor the new.
    unpack_source
    local tree="${WORK_DIR}/src/modules/lustre"
    [[ -f "${tree}/debian/dkms.conf.in" ]] ||
        die "the source package does not carry debian/dkms.conf.in, so DKMS mode cannot be used"

    if [[ -f "${dest}/dkms.conf" ]]; then
        # Same upstream version, different packaging revision -- or a tree from a revision of this
        # installer that recorded no package version. Either way the tree is replaced and every
        # built module rebuilt, because a fix in the new revision would otherwise be skipped: DKMS
        # sees the same version and considers the module already installed. Replacing is a removal,
        # so it needs the same ownership test that cleanup uses.
        if [[ -d "/var/lib/dkms/lustre-client-modules/${version}" ]] && ! owns_version "${version}"; then
            die "version ${version} is already registered with DKMS and this installer did not
       register it, so replacing it is not this installer's call. Remove it yourself with
       'dkms remove -m lustre-client-modules -v ${version} --all', or run --uninstall."
        fi
        log "the source package changed to ${package_version}; replacing the registered tree"
        remove_dkms_version "${version}"
    fi

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

re_quote() {
    # Debian versions carry + and ~, and a kernel release could carry any of these, so the whole
    # metacharacter set is escaped rather than the dot alone.
    printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'
}

dkms_installed_for() {
    # dkms 2.x prints "name, version, kernel, arch: installed" and dkms 3.x prints
    # "name/version, kernel, arch: installed", so both forms are accepted. The state is read from
    # the printed table rather than a per-module query, because the query form differs between dkms
    # releases while the printed one does not.
    local version="$1" kernel="$2" status
    status="$(dkms status 2>/dev/null || true)"
    grep -qE "^lustre-client-modules[/,] ?$(re_quote "${version}"), $(re_quote "${kernel}"),.*: installed" <<<"${status}"
}

OWNERSHIP_MARKER=".installed-by-lustre-installer"

record_owned_version() {
    # Which registrations this installer created, so that cleanup can leave alone one a distribution
    # package or another administrator put there: without a record, "remove the other versions"
    # means removing whatever else happens to be registered under the same module name.
    # The mark is written twice on purpose. The file in the source tree travels with the thing it
    # describes and survives the loss of the work directory; the list in the work directory survives
    # a tree that was removed by hand. Either one is enough to claim a version.
    local version="$1" tree="/usr/src/lustre-client-modules-$1"
    [[ ! -d "${tree}" ]] || : > "${tree}/${OWNERSHIP_MARKER}"
    grep -qxF "${version}" "${WORK_DIR}/owned-versions" 2>/dev/null ||
        printf '%s\n' "${version}" >> "${WORK_DIR}/owned-versions"
}

forget_owned_version() {
    # A claim over a version that is no longer registered would authorise removing whatever is
    # registered under that name next.
    local version="$1" list="${WORK_DIR}/owned-versions" tmp
    [[ -f "${list}" ]] || return 0
    tmp="$(mktemp "${list}.XXXXXX")"
    grep -vxF "${version}" "${list}" > "${tmp}" || true
    mv "${tmp}" "${list}"
}

owns_version() {
    [[ -f "/usr/src/lustre-client-modules-$1/${OWNERSHIP_MARKER}" ]] && return 0
    grep -qxF "$1" "${WORK_DIR}/owned-versions" 2>/dev/null && return 0
    # A tree registered by a revision of this installer that predates the marker names the policy
    # file inside its configuration, which nothing else would do.
    grep -q "${POLICY_FILE}" "/usr/src/lustre-client-modules-$1/dkms.conf" 2>/dev/null
}

registered_dkms_versions() {
    # /var/lib/dkms/<module>/ holds one directory per registered version, and dkms 3.x also puts a
    # kernel-<release>-<arch> symlink there that points into one of them. Following that symlink as
    # if it named a version asks dkms to remove something that was never registered, so only real
    # directories count.
    local dir name
    for dir in /var/lib/dkms/lustre-client-modules/*/; do
        name="${dir%/}"
        [[ -d "${name}" && ! -L "${name}" ]] || continue
        printf '%s\n' "${name##*/}"
    done
}

remove_dkms_version() {
    # A registration whose source tree is gone still gets built on every kernel install and fails
    # there, so the tree is removed only once DKMS has let go of it.
    local version="$1"
    # A tree in /usr/src that DKMS never took is not a registration, and asking DKMS to remove it
    # would fail on a host where the previous run stopped between unpacking and 'dkms add'.
    if [[ ! -d "/var/lib/dkms/lustre-client-modules/${version}" ]]; then
        rm -rf "/usr/src/lustre-client-modules-${version}"
        return 0
    fi
    log "removing the superseded DKMS registration ${version}"
    forget_owned_version "${version}"
    dkms remove -m lustre-client-modules -v "${version}" --all >/dev/null 2>&1 ||
        die "could not remove the DKMS registration ${version}. Resolve it with
       'dkms remove -m lustre-client-modules -v ${version} --all' and run this installer again;
       leaving it registered would make the next kernel install fail on it."
    rm -rf "/usr/src/lustre-client-modules-${version}"
}

build_with_dkms() {
    local version
    version="$(cat "${WORK_DIR}/version")"
    step "Building the module with DKMS for ${KERNEL}"
    # Every registered version is built on each kernel install, so an obsolete one that no longer
    # compiles fails the whole kernel transaction.
    local other
    while IFS= read -r other; do
        [[ -n "${other}" && "${other}" != "${version}" ]] || continue
        if ! owns_version "${other}"; then
            warn "the DKMS registration ${other} was not created by this installer and is left
       alone. It will be built on every kernel install alongside ${version}; remove it yourself if
       that is not what you want."
            continue
        fi
        remove_dkms_version "${other}"
    done < <(registered_dkms_versions)
    local registered_by_this_run="false"
    if [[ ! -d "/var/lib/dkms/lustre-client-modules/${version}" ]]; then
        dkms add -m lustre-client-modules -v "${version}"
        registered_by_this_run="true"
        # After the registration exists, not before: a failed add would otherwise leave a claim over
        # a version this installer does not have.
        record_owned_version "${version}"
    else
        log "already registered with DKMS"
    fi
    if dkms_installed_for "${version}" "${KERNEL}"; then
        log "already installed for ${KERNEL}"
        report_uncovered_kernels "${version}"
        return 0
    fi
    local start
    start="$(date +%s)"
    dkms build -m lustre-client-modules -v "${version}" -k "${KERNEL}" >"${WORK_DIR}/build.log" 2>&1 || {
        printf 'error: the DKMS build failed. The last lines of %s follow.\n' "${WORK_DIR}/build.log" >&2
        tail -n 25 "${WORK_DIR}/build.log" >&2
        # A registration whose first build failed would be retried from every later kernel install
        # and fail there too, turning one failure into a host that cannot install kernels. Only a
        # registration this run created is withdrawn: one that was already working for other kernels
        # is not this run's to remove because a build for one kernel failed.
        if [[ "${registered_by_this_run}" == "true" ]]; then
            if dkms remove -m lustre-client-modules -v "${version}" --all >/dev/null 2>&1; then
                die "the client source does not build against kernel ${KERNEL}; the DKMS
       registration this run added has been withdrawn so kernel installs on this host are
       unaffected"
            fi
            die "the client source does not build against kernel ${KERNEL}, and the registration
       this run added could not be withdrawn afterwards. Remove it with
       'dkms remove -m lustre-client-modules -v ${version} --all' before installing another
       kernel, because it would fail there too."
        fi
        die "the client source does not build against kernel ${KERNEL}. The registration that was
       already here has been left alone; if it cannot build for a kernel you intend to install,
       narrow the policy with --kernel-filter before installing that kernel"
    }
    # --force is what lets a DKMS module take over from one installed by --mode binary or by an
    # earlier --mode build on the same kernel; without it DKMS refuses to overwrite that file.
    dkms install -m lustre-client-modules -v "${version}" -k "${KERNEL}" --force >>"${WORK_DIR}/build.log" 2>&1 || {
        printf 'error: the module built but DKMS could not install it. The last lines of %s follow.\n' "${WORK_DIR}/build.log" >&2
        tail -n 25 "${WORK_DIR}/build.log" >&2
        die "DKMS install failed for ${KERNEL}"
    }
    log "built and installed in $(( $(date +%s) - start ))s"
    log "DKMS will rebuild this module whenever a matching kernel is installed"
    report_uncovered_kernels "${version}"
}

report_uncovered_kernels() {
    # DKMS builds for a kernel when that kernel is installed, so a kernel that was already on this
    # host when the installer first ran gets no module until it is reinstalled. Naming those kernels
    # turns a gap that would surface as a failed mount after a reboot into something readable now.
    local version="$1" policy dir other uncovered=()
    policy="$(current_policy)"
    for dir in /lib/modules/*/; do
        other="${dir%/}"; other="${other##*/}"
        [[ "${other}" != "${KERNEL}" ]] || continue
        # A removed kernel package leaves its directory behind with the modules gone. Naming such a
        # kernel as uncovered would send an operator after a kernel that cannot boot anyway.
        [[ -f "${dir}modules.builtin" ]] || continue
        [[ "${other}" =~ ${policy} ]] || continue
        dkms_installed_for "${version}" "${other}" && continue
        uncovered+=("${other}")
    done
    [[ ${#uncovered[@]} -gt 0 ]] || return 0
    log "these installed kernels are within the policy but have no module yet: ${uncovered[*]}"
    log "build for them now with --kernel <release>, or let their next package update do it"
}

# ---------------------------------------------------------------- verification

module_state() {
    # Prints one line about the client for a kernel release and returns non-zero when it is not
    # usable. For the running kernel that means loaded and mountable, and reaching that answer means
    # loading the module, so this is not read-only: a module that is present but refuses to load is
    # exactly the state worth catching. For any other kernel only the built module can be inspected,
    # which the printed line says.
    local kernel="$1" vermagic loaded module
    vermagic="$(modinfo -F vermagic -k "${kernel}" lustre 2>/dev/null || true)"
    if [[ -z "${vermagic}" ]]; then
        printf 'no lustre module is installed for %s\n' "${kernel}"
        return 1
    fi
    if [[ "${vermagic%% *}" != "${kernel}" ]]; then
        printf 'the installed module targets %s but %s was asked for; the kernel refuses a module built for another release\n' \
            "${vermagic%% *}" "${kernel}"
        return 1
    fi
    if [[ "${kernel}" != "$(uname -r)" ]]; then
        printf 'ok: a module for %s is installed; the load was not tried because that kernel is not running\n' "${kernel}"
        return 0
    fi
    if ! modprobe lustre 2>/dev/null; then
        printf 'the module for %s exists but does not load\n' "${kernel}"
        return 1
    fi
    # grep -q exits at the first match, which would send SIGPIPE to lsmod and, under pipefail, look
    # like a failure. Read the table once instead.
    loaded="$(lsmod)"
    for module in libcfs lnet lustre; do
        grep -q "^${module} " <<<"${loaded}" || {
            printf '%s is not resident after loading the client\n' "${module}"
            return 1
        }
    done
    if [[ ! -x /sbin/mount.lustre ]]; then
        printf 'the module is loaded but /sbin/mount.lustre is missing, so a mount would still fail\n'
        return 1
    fi
    printf 'ok: %s is loaded and mountable\n' "${vermagic}"
}

verify() {
    step "Verifying the client"
    local state
    state="$(module_state "${KERNEL}")" || die "${state}"
    log "module:  $(modinfo -F filename -k "${KERNEL}" lustre)"
    log "${state}"
    [[ "${KERNEL}" == "$(uname -r)" ]] || return 0
    log "loaded:  $(lsmod | awk '$1=="lustre"{print $1" "$2" bytes"}')"
    log "client:  $(lctl --version)"
}

summary() {
    step "Summary"
    log "mode:    ${MODE}"
    log "kernel:  ${KERNEL}"
    dpkg-query -W -f='${Package} ${Version}\n' 'lustre*' 2>/dev/null | sed 's/^/package: /' || true
    if [[ "${MODE}" == "dkms" ]]; then
        dkms status 2>/dev/null | grep '^lustre-client-modules' | sed 's/^/dkms:    /' || true
    fi
    case "${MODE}" in
        dkms) log "policy:  $(current_policy)" ;;
        build|binary) log "next kernel: not covered; run this installer again or use --mode dkms" ;;
    esac
    log ""
    log "Mounting a file system is left to you, for example:"
    log "  mount -t lustre -o noatime,flock <fs-dns-name>@tcp:/<mount-name> /mnt/fsx"
}

# ---------------------------------------------------------------- uninstall

uninstall() {
    step "Removing every Lustre client on this host"
    # Removal acts on every Lustre mount, module and package on the host, and deliberately does not
    # consult the record of which registrations this installer created. Cleanup during an install is
    # a side effect and has to stay inside what this installer owns; --uninstall is someone asking
    # for the client to be gone. A host with a second, independently managed client has to be told
    # apart by whoever runs the command, not by this script.
    local failures=() mounts
    mounts="$(mount)"
    if grep -q ' type lustre ' <<<"${mounts}"; then
        umount -a -t lustre || failures+=("a mounted file system could not be unmounted")
    fi
    if grep -q '^lustre ' <<<"$(lsmod)"; then
        lustre_rmmod || failures+=("the client modules are still loaded")
    fi
    local version
    while IFS= read -r version; do
        [[ -n "${version}" ]] || continue
        if dkms remove -m lustre-client-modules -v "${version}" --all; then
            rm -rf "/usr/src/lustre-client-modules-${version}"
        else
            # The tree is kept, because a registration DKMS still holds and whose source is gone
            # fails on every later kernel install and is harder to recover from than this.
            failures+=("dkms could not remove ${version}; its source tree was left in place")
        fi
    done < <(registered_dkms_versions)
    # A tree whose registration is already gone is still a leftover, and DKMS would try to build
    # from it if anything re-added it.
    local tree
    for tree in /usr/src/lustre-client-modules-*/; do
        [[ -d "${tree}" ]] || continue
        version="${tree%/}"; version="${version##*/}"; version="${version#lustre-client-modules-}"
        [[ ! -d "/var/lib/dkms/lustre-client-modules/${version}" ]] || continue
        rm -rf "${tree}"
        log "removed the unregistered source tree ${tree}"
    done
    local packages=()
    for pkg in $(dpkg-query -W -f='${Package}\n' 'lustre-client-modules-*' lustre-source 2>/dev/null || true); do
        packages+=("${pkg}")
    done
    if [[ ${#packages[@]} -gt 0 ]]; then
        apt_get remove -y "${packages[@]}" >/dev/null || failures+=("apt could not remove ${packages[*]}")
    fi
    # The boot-time check has to go with the modules. Left behind, it fails at every boot on a host
    # that is deliberately without a client, which trains whoever watches unit state to ignore it.
    if [[ -e /etc/systemd/system/lustre-client-check.service ]]; then
        systemctl disable --now lustre-client-check.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/lustre-client-check.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        log "removed the boot-time check and its unit"
    fi
    # The policy is kept when something is still registered: a registration that outlives its
    # policy file falls back to a series regex that was never chosen for this host.
    if [[ ${#failures[@]} -eq 0 ]]; then
        rm -f "${INSTALLED_SELF}" "${POLICY_FILE}"
        rmdir "$(dirname "${POLICY_FILE}")" 2>/dev/null || true
    else
        log "${POLICY_FILE} and ${INSTALLED_SELF} were kept because something is still registered"
    fi
    # What stays, and why: the userspace tools because another client may be using them, and the
    # repository registration and its key because they are apt configuration an administrator may
    # have adopted, and removing a source list this run did not write is not this installer's call.
    log "lustre-client-utils was left installed; remove it separately if nothing else needs it"
    log "the repository registration at ${SOURCES_LIST} and its signing key were left in place"
    if [[ ${#failures[@]} -eq 0 ]]; then
        rm -rf "${WORK_DIR}"
    else
        log "${WORK_DIR} was kept because the removal was incomplete; its logs say what happened"
    fi
    if [[ ${#failures[@]} -gt 0 ]]; then
        printf 'error: the removal was incomplete:\n' >&2
        printf '  - %s\n' "${failures[@]}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------- boot-time check

INSTALLED_SELF=/usr/local/sbin/lustre_installer.sh

install_self() {
    # The unit must not point at wherever the script happened to be run from, so a copy at a stable
    # path is what it calls. The copy is refreshed whenever it exists, because a host that upgraded
    # this installer would otherwise keep running the older copy at every boot.
    # BASH_SOURCE names the file bash is reading, where $0 names the interpreter when the script is
    # piped into a shell -- and copying that would install the shell itself as the check command.
    local self
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -z "${self}" ]] || [[ ! -f "${self}" ]] || ! grep -q '^INSTALLER_VERSION=' "${self}"; then
        die "this run cannot find its own script file, which happens when the installer is piped
       into a shell. Save it to a file and run that file to install the boot-time check."
    fi
    [[ "${self}" != "${INSTALLED_SELF}" ]] || return 0
    install -m 0755 "${self}" "${INSTALLED_SELF}"
    log "installed a copy at ${INSTALLED_SELF}"
}

install_check_unit() {
    step "Installing the boot-time check"
    # The unit reports and does not block boot, because a node that refuses to start is worse than
    # one that reports a fault. kubelet is ordered after it so that a node whose client did not
    # survive a kernel update has said so before the first pod asks for the file system; the
    # ordering is a no-op on a host with no kubelet unit, which is why it is unconditional.
    [[ -d /run/systemd/system ]] ||
        die "systemd is not running here, so the boot-time check cannot be installed. Drop
       --install-check-unit, and have whatever supervises this host run
       '${INSTALLED_SELF} --check' instead."
    install_self
    local unit=/etc/systemd/system/lustre-client-check.service
    # A unit that was here before this run is kept aside, so a failing check does not cost the
    # operator whatever was there already.
    local previous=""
    if [[ -f "${unit}" ]]; then
        previous="$(mktemp)"
        cp -p "${unit}" "${previous}"
    fi
    # RemainAfterExit keeps a passing check visible as active rather than collapsing to inactive
    # once it exits, so 'systemctl is-active' answers the question the unit exists to answer.
    cat > "${unit}" <<UNIT
[Unit]
Description=Report whether a Lustre client module is available for the running kernel
After=local-fs.target
Before=kubelet.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${INSTALLED_SELF} --check

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    # Run it before enabling it. A unit that has only ever been enabled says nothing until the next
    # boot, so an install would hand over a check nobody has seen work -- and enabling one that
    # cannot pass creates exactly the every-boot fault this is meant to report. The run is skipped
    # when this run targeted a kernel that is not running, because the check asks about the running
    # one and would fail on a host that is about to reboot into the kernel this run built for.
    if [[ "${KERNEL}" == "$(uname -r)" ]]; then
        # restart rather than start: an instance left active by an earlier run would make start a
        # no-op, and this run would then report that its own unit had passed without running it.
        systemctl restart lustre-client-check.service >/dev/null 2>&1 || {
            systemctl status lustre-client-check.service --no-pager >&2 || true
            if [[ -n "${previous}" ]]; then
                cp -p "${previous}" "${unit}"
                rm -f "${previous}"
                log "the unit that was here before this run has been put back"
            else
                systemctl disable lustre-client-check.service >/dev/null 2>&1 || true
                rm -f "${unit}"
            fi
            systemctl daemon-reload >/dev/null 2>&1 || true
            die "the boot-time check failed the moment it was installed, so this host would have
       reported a fault at every boot. Nothing has been left enabled and the output above says why."
        }
        log "the check ran now and passed, so the unit is known to work rather than assumed to"
    else
        log "the check will first run when ${KERNEL} boots"
    fi
    rm -f "${previous}"
    systemctl enable lustre-client-check.service >/dev/null 2>&1 ||
        die "could not enable lustre-client-check.service"
    log "installed ${unit}; check it with 'systemctl status lustre-client-check'"
}

# ---------------------------------------------------------------- check

check_only() {
    # After a kernel update DKMS may have skipped the new kernel or failed on it, and a host with
    # no module for its running kernel cannot mount, which is silent until something tries.
    local state
    if state="$(module_state "$(uname -r)")"; then
        log "${state}"
    else
        printf '%s\n' "${state}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------- main

require_ubuntu
[[ "${ACTION}" == "install" || "${INSTALL_CHECK_UNIT}" == "false" ]] ||
    die "--install-check-unit installs the boot check as part of an install, and --${ACTION} does
       not install anything. Run it without --${ACTION}."
case "${ACTION}" in
    check)
        # No lock is taken: this runs at boot and from health checks, and must answer even while an
        # install is in progress. It reads state and loads a module; it changes no configuration.
        check_only
        exit 0
        ;;
    refresh-policy)
        mkdir -p "${WORK_DIR}"
        take_lock
        if [[ -n "${KERNEL_FILTER}" ]]; then
            write_policy "${KERNEL_FILTER}"
        else
            derive_policy || die "the policy could not be refreshed"
        fi
        apply_policy_to_registered_tree
        log "policy in effect: $(current_policy)"
        exit 0
        ;;
    uninstall)
        confirm
        mkdir -p "${WORK_DIR}"
        take_lock
        uninstall
        exit 0
        ;;
esac

[[ -n "${KERNEL_FILTER}" && "${MODE}" != "dkms" ]] &&
    log "note: --kernel-filter only decides which kernels DKMS may build for, so it does nothing
      in --mode ${MODE}"
confirm
mkdir -p "${WORK_DIR}"
take_lock
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
if [[ "${MODE}" != "dkms" ]] && compgen -G '/var/lib/dkms/lustre-client-modules/*/' >/dev/null; then
    log "note: a DKMS registration is still present, so kernel installs will keep rebuilding the"
    log "      module. Remove it with --uninstall if this host should not follow kernel updates."
fi
[[ "${INSTALL_CHECK_UNIT}" == "true" || ! -f "${INSTALLED_SELF}" ]] || install_self
[[ "${INSTALL_CHECK_UNIT}" == "true" ]] && install_check_unit
[[ "${VERIFY}" == "true" ]] && verify
summary
