#!/usr/bin/env bash
# Declarative test registry — the single source of truth for each test's layer and suite.
# To add a test: write test_<name>() in the appropriate tests/cases/*.sh file (grouped by area,
# not by layer), then add one register_test line below.

TEST_NAMES=(); TEST_FUNCS=(); TEST_MIN_SUITES=(); TEST_LAYERS=(); TEST_TIMEOUTS=(); TEST_TOOLS=()

register_test() {
  TEST_NAMES+=("$1")
  TEST_FUNCS+=("$2")
  TEST_MIN_SUITES+=("$3")
  TEST_LAYERS+=("$4")
  TEST_TIMEOUTS+=("$5")
  shift 5
  TEST_TOOLS+=("$*")
}

register_all_tests() {
  register_test plan-guard-table                test_plan_guard_table                    baseline static "$TIMEOUT_STATIC"
  register_test registry-matches-state          test_registry_matches_state              baseline static "$TIMEOUT_STATIC" terraform
  register_test registry-default-layer-attached test_registry_default_data_layer_is_attached baseline static "$TIMEOUT_STATIC"
  register_test registry-preamble-contract      test_registry_preamble_contract          baseline static "$TIMEOUT_STATIC"
  register_test registry-unknown-cluster-fails  test_registry_unknown_cluster_fails      baseline static "$TIMEOUT_STATIC"
  register_test static-terraform-validate test_static_terraform_validate baseline static "$TIMEOUT_STATIC" terraform

  register_test image-build-ddp-sample-golden test_image_build_ddp_sample_golden baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-custom-render     test_image_build_custom_render     baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-callers-exclusive test_image_build_callers_exclusive baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-guards            test_image_build_guards            baseline static "$TIMEOUT_STATIC" helm

  # P0 chart-contract: render the workshop serving workloads and assert their structure. Cluster
  # not needed, so these run in baseline/static on every PR and catch a broken serving chart.
  register_test static-gpu-serving-contract   test_static_gpu_serving_contract   baseline static "$TIMEOUT_STATIC" helm
  register_test static-neuron-plugin-contract test_static_neuron_plugin_contract baseline static "$TIMEOUT_STATIC" helm

  register_test control-plane   test_control_plane   baseline live-ro "$TIMEOUT_BASE"
  register_test system-nodes    test_system_nodes    baseline live-ro "$TIMEOUT_BASE"
  register_test karpenter       test_karpenter       baseline live-ro "$TIMEOUT_BASE"
  register_test csi-drivers     test_csi_drivers     baseline live-ro "$TIMEOUT_BASE"
  register_test device-plugins  test_device_plugins  baseline live-ro "$TIMEOUT_BASE"
  register_test trainer         test_trainer         baseline live-ro "$TIMEOUT_BASE"

  register_test storage-mount   test_storage_mount   baseline live-mut 180

  register_test gpu-node-launch  test_gpu_node_launch  full gpu "$TIMEOUT_GPU"
  register_test nvidia-smi-check test_nvidia_smi       full gpu "$TIMEOUT_BASE"
  register_test cuda-vector-add  test_cuda_vector_add  full gpu "$TIMEOUT_GPU"
  register_test gpu-fsx-mount    test_gpu_fsx_mount    full gpu "$TIMEOUT_GPU"
  register_test gpu-serving-vllm test_gpu_serving_vllm full gpu 1200 helm

  # Standalone Trainium suite (never in baseline/coverage/full). Runs only under `--suite neuron`;
  # self-skips when no Trainium node is present. 40 min timeout covers the first-run NEFF compile.
  register_test neuron-vllm-qwen3vl test_neuron_vllm_qwen3vl neuron neuron 2400 helm
}
