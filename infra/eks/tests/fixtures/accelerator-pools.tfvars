# Input fixture for static render/regression checks. It is intentionally versioned to make
# cluster-independent Terraform console assertions meaningful and deterministic; update it only
# when adding pool-shape coverage. This fixture is never applied.
accelerator_pools = {
  nvidia-headroom-reaper = {
    instance_types                         = ["g6e.12xlarge"]
    device_plugin                          = "nvidia"
    capacity_types                         = ["on-demand"]
    kubelet_system_reserved_memory         = "8Gi"
    kubelet_eviction_hard_memory_available = "4Gi"
    stuck_node_reaper_enabled              = true
  }

  nvidia-default = {
    instance_types = ["g6e.12xlarge"]
    device_plugin  = "nvidia"
    capacity_types = ["on-demand"]
  }
}
