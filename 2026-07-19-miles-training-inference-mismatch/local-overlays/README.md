# Local overlays (NOT for upstream)

Environment-specific overrides used to run this study on a borrowed validation cluster.
These must not be part of the upstream `3.test_cases/pytorch/miles/` contribution -- the
inner test case ships the correct production shape (head on a CPU node); these overlays
adapt it to a cluster that lacked the right node.

## Why this exists

The validation cluster had no large-disk CPU node -- only a small system nodegroup whose
nodes have ~18GB ephemeral-storage. The miles image is ~18.4GB, so the Ray head could not
be pulled there (Evicted, "no space left on device").

The upstream `3.test_cases/pytorch/miles/kubernetes/raycluster.yaml` keeps the head on a
CPU node (`node-role: cpu`) with an `ephemeral-storage` request, which is the correct
production design and assumes the CPU pool's root EBS is large enough (>=150Gi). This
overlay was used only because that node type was unavailable on the borrowed cluster.

## `raycluster.head-on-gpu.overlay.yaml`

Places the Ray head on a large-disk GPU node with a GPU toleration. The head is
num-gpus:0, so it does not consume a GPU; the worker keeps the full 8-GPU node, so there is
no contention. This is an environment-specific workaround, not a recommended design. The
GRPO results reported in the test case were produced with this overlay; only the
head-on-CPU variant of the manifest is untested (see the test case README Verification
Status).
