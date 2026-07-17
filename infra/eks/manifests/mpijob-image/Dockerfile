# mpijob-hf-sample
#
# pytorch/pytorch base + the mpi-operator SSH setup (vendored verbatim from
# github.com/kubeflow/mpi-operator build/base/Dockerfile + sshd_config, the same base every
# upstream v2beta1 example — e.g. examples/v2beta1/pi — builds on) + Open MPI + the HF Trainer
# stack. Built because pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime ships neither Open MPI nor
# sshd/openssh-server (verified: `finch run --rm <image> which mpirun sshd` returned nothing),
# so mpi-operator's Worker sshd auto-injection and the Launcher's mpirun rsh have nothing to
# run. Rather than apt-get at Pod-start (races mpirun's first rsh attempt against the Worker's
# own apt-get finishing, and needs network egress to Ubuntu mirrors + PyPI on every run), all
# of that is baked in here once. See README.md in this directory for build/push instructions.
#
# Note: mpi-operator's OWN build/base/Dockerfile provides only the sshd half — Open MPI comes
# from the example image built on top of it (mpioperator/mpi-pi:openmpi), so openmpi-bin is
# added here too (confirmed missing via `finch run --rm <image> which mpirun` on a first build
# that only followed the sshd half).
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ARG SSH_PORT=2222

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server \
      openssh-client \
      openmpi-bin \
      libopenmpi-dev \
      libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd \
    && setcap CAP_NET_BIND_SERVICE=+eip /usr/sbin/sshd \
    && apt-get remove -y libcap2-bin

# Disable StrictHostKeyChecking/UserKnownHostsFile (mpi-operator mounts .ssh from a Secret,
# so there is no interactive prompt to answer and no writable known_hosts) and StrictModes
# (the Secret-mounted key's permissions do not pass sshd's default paranoia check). Verified
# against kubeflow/mpi-operator's build/base/Dockerfile — copied verbatim, not reinvented.
RUN sed -i "s/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g" /etc/ssh/ssh_config \
    && echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config \
    && sed -i "s/[ #]\(.*Port \).*/ \1${SSH_PORT}/g" /etc/ssh/ssh_config \
    && sed -i "s/#\(StrictModes \).*/\1no/g" /etc/ssh/sshd_config \
    && sed -i "s/#\(Port \).*/\1${SSH_PORT}/g" /etc/ssh/sshd_config

RUN useradd -m mpiuser
WORKDIR /home/mpiuser

# HostKey points at the operator-mounted Secret (/home/mpiuser/.ssh/id_rsa) — mpi-operator's
# Pod spec remaps the Secret's `ssh-privatekey` key to the path `id_rsa` via volume `items`
# (confirmed by reading the actual Worker Pod spec on this cluster), so no ssh-keygen -A /
# baked host key is needed: the same key used for client auth doubles as the Worker's host
# key.
COPY sshd_config .sshd_config
RUN echo "Port ${SSH_PORT}" >> /home/mpiuser/.sshd_config \
    && chown mpiuser:mpiuser /home/mpiuser/.sshd_config

RUN pip install --no-cache-dir \
      'transformers==4.46.3' \
      'datasets==3.1.0' \
      'accelerate==1.1.1'

COPY --chown=mpiuser:mpiuser train_smollm.py /home/mpiuser/train_smollm.py

USER mpiuser
