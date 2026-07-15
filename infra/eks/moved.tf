# moved.tf
# State migrations for the accelerator-pool refactor: the single-purpose GPU EC2NodeClass
# and NodePool were generalized into for_each resources keyed by pool name. These `moved`
# blocks migrate existing state in place so the live gpu-training NodePool/EC2NodeClass is
# preserved (no destroy + recreate).

moved {
  from = kubectl_manifest.ec2nodeclass_gpu_training
  to   = kubectl_manifest.accelerator_nodeclass["gpu-training"]
}

moved {
  from = kubectl_manifest.nodepool_gpu_training
  to   = kubectl_manifest.accelerator_nodepool["gpu-training"]
}
