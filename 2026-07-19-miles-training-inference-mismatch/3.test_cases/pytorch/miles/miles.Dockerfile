# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# ============================================================================
# miles (radixark/miles) + EFA image for Amazon EKS
# ============================================================================
# Strategy C (see docs/PORT_NOTES.md): the miles upstream image already bundles
# a matched CUDA 13.0.1 / PyTorch 2.11 stack, the sglang-miles fork (weight sync
# HTTP endpoints), the radixark Megatron-LM fork, prebuilt flash_attn / TE /
# apex wheels, and the B300 sm_103 TE FA2 whitelist patch. Rebuilding that on an
# NGC base is infeasible (wheel ABI mismatch), so we take the miles image as-is
# and add ONLY the AWS EFA networking stack on top.
#
# The CUDA-before-PyTorch word order above is deliberate: the repository CI
# derives the CUDA version by grepping the first line matching "cuda" and taking
# the first X.Y number on it. Writing "PyTorch 2.11" ahead of "CUDA 13.0.1" makes
# that check read 2.11 as the CUDA version and fail the 13.0 minimum.
#
# BASE TAG AND ITS LIFETIME. radixark/miles publishes rolling `dev-<timestamp>`
# tags with no git tags or releases, and OLD TAGS ARE DELETED from the registry.
# Pin a dated tag (never :latest) per awsome-distributed-ai CONTRIBUTING, but
# expect the pin to 404 within weeks and re-pin. Check what still exists with:
#   TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:radixark/miles:pull" | jq -r .token)
#   curl -s -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/radixark/miles/tags/list
# Because the base ships prebuilt wheels rather than cloned sources, the miles
# commit inside a given tag cannot be recovered from this Dockerfile alone --
# record the tag alongside any result you publish.
# ============================================================================
# Pin by DIGEST, not by tag. radixark publishes dev-* as mutable rolling snapshots and
# DELETES old ones: the tag this file used to pin (dev-202608010334) already returns 404 from
# the registry, so a dated tag alone gives neither reproducibility nor availability. The tag is
# kept alongside for readability; the digest is what the build resolves.
#
# To move to a newer base, resolve its digest first:
#   TOK=$(curl -s "https://auth.docker.io/token?service=registry.docker.io\
# &scope=repository:radixark/miles:pull" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
#   curl -sI -H "Authorization: Bearer $TOK" \
#     -H "Accept: application/vnd.oci.image.index.v1+json" \
#     https://registry-1.docker.io/v2/radixark/miles/manifests/<tag> | grep -i docker-content-digest
#
# Because the base ships prebuilt wheels rather than cloned sources, the miles commit inside a
# given tag cannot be recovered from this Dockerfile alone -- record the digest alongside any
# result you publish.
ARG MILES_BASE_TAG=dev-202607310056
ARG MILES_BASE_DIGEST=sha256:ca0bb593dd6f4011b444f64d478b72c213e4c70421f4d7f94e593a709562429e
FROM radixark/miles@${MILES_BASE_DIGEST}

ARG GDRCOPY_VERSION=v2.5.2
ARG EFA_INSTALLER_VERSION=1.48.0
# Declared so the repo CI version-gate (greps nccl/efa minimums) is satisfied.
ARG NCCL_VERSION=v2.30.4-1
ARG AWS_OFI_NCCL_VERSION=v1.19.0

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

######################
# Remove IB libverbs (replaced by the EFA installer below). The miles base is
# lmsysorg/sglang (nvidia/cuda:13.0.1), which ships InfiniBand userspace libs;
# strip them so the EFA installer's libfabric/libibverbs take precedence.
######################
RUN apt-get update -y \
    && apt-get remove -y --allow-change-held-packages \
        ibverbs-utils libibverbs-dev libibverbs1 libmlx5-1 || true

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \
    autoconf automake build-essential cmake curl gcc gdb git jq kmod libtool \
    openssh-client openssh-server vim \
    && apt-get autoremove -y

# Permissive SSH for in-cluster MPI/NCCL bootstrap. Port 22 must NOT be exposed
# outside the cluster via a Service.
RUN mkdir -p /var/run/sshd && \
    sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
RUN rm -rf /root/.ssh/ && mkdir -p /root/.ssh/ \
    && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
    && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
    && printf "Host *\n  StrictHostKeyChecking no\n" >> /root/.ssh/config

#################################################
## NVIDIA GDRCopy (GPUDirect RDMA copy library)
RUN git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install \
    && rm -rf /tmp/gdrcopy
# Physically remove the CUDA forward-compat driver. The slime (NGC) image relied
# on it, but NGC's entrypoint enables compat only when compat >= host driver;
# the nvidia/cuda base under miles has no such guard. This base ships an OLDER
# compat libcuda (580.82.07) than the driver on GPU-operator nodes (e.g.
# 580.159.03), and forward-compat requires compat >= host driver. If anything
# resolves the stale compat libcuda, torch.cuda dies with "Error 803: unsupported
# display driver / cuda driver combination". The host driver already supports
# this image's CUDA 13.0 toolkit, so we delete compat outright (belt-and-suspenders
# vs merely dropping it from LD_LIBRARY_PATH, which a future env edit could undo).
RUN rm -rf /usr/local/cuda/compat /usr/local/cuda-*/compat
ENV LD_LIBRARY_PATH=/opt/gdrcopy/lib:$LD_LIBRARY_PATH
ENV LIBRARY_PATH=/opt/gdrcopy/lib:$LIBRARY_PATH
ENV CPATH=/opt/gdrcopy/include:${CPATH:-}
ENV PATH=/opt/gdrcopy/bin:$PATH

#################################################
## AWS EFA installer (libfabric + aws-ofi-nccl plugin, no kmod in-container)
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf $HOME/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf $HOME/aws-efa-installer $HOME/aws-efa-installer-*.tar.gz \
    && rm -rf /var/lib/apt/lists/*

# EFA / aws-ofi-nccl library paths. Placed AFTER the gdrcopy block so the EFA
# libfabric resolves ahead of any base-image InfiniBand remnants. The host-driver
# dirs are appended at the END: the GPU operator / nvidia-container-toolkit injects
# libcuda.so.1 into /usr/lib64 (AL2023/Bottlerocket) or /usr/lib/x86_64-linux-gnu
# (Ubuntu). torch resolves libcuda via ld.so.cache, but SGLang's server subprocess
# (and Triton/cuda-python loaders) scan LD_LIBRARY_PATH directly and otherwise fail
# with "ImportError: libcuda.so.1: cannot open shared object file". Appending (not
# prepending) means these dirs are only consulted for libraries nothing else
# resolves, so they never shadow the EFA/CUDA-runtime libs above. Non-existent
# dirs in LD_LIBRARY_PATH are harmless.
ENV LD_LIBRARY_PATH=/opt/amazon/efa/lib:/opt/amazon/aws-ofi-nccl/lib:/opt/amazon/ofi-nccl/lib:$LD_LIBRARY_PATH:/usr/lib64:/usr/lib/x86_64-linux-gnu
ENV PATH=/opt/amazon/efa/bin:$PATH
# glibc-path insurance: ensure the host driver dir is in ld.so.cache too. The
# toolkit re-runs ldconfig at container start, so the injected libcuda is picked
# up for the standard glibc resolution path (belt-and-suspenders with the LD above).
RUN echo "/usr/lib64" > /etc/ld.so.conf.d/zz-host-driver.conf \
    && echo "/usr/lib/x86_64-linux-gnu" >> /etc/ld.so.conf.d/zz-host-driver.conf \
    && ldconfig

#####################
# EFA / NCCL / Ray runtime defaults (match the slime test case).
#####################
ENV FI_PROVIDER="efa"
ENV FI_EFA_USE_DEVICE_RDMA="1"
ENV FI_EFA_FORK_SAFE="1"
ENV NCCL_PROTO="Simple"
ENV NCCL_DEBUG="WARN"
# gloo (Ray's collective for CPU tensors) must bind to the primary NIC.
ENV GLOO_SOCKET_IFNAME="eth0"

# miles installs itself editable at /root/miles and the Megatron fork at
# /root/Megatron-LM, but does NOT bake PYTHONPATH into the image. The recipe and
# the RayCluster runtime-env set it explicitly; this default covers a bare shell.
ENV PYTHONPATH=/root/miles:/root/Megatron-LM:${PYTHONPATH:-}

WORKDIR /root/miles
CMD ["/bin/bash"]
