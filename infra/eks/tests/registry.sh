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
  register_test static-terraform-validate test_static_terraform_validate baseline static "$TIMEOUT_STATIC" terraform
  register_test static-userdata-baseline  test_static_userdata_baseline  coverage static "$TIMEOUT_STATIC" terraform
  register_test static-userdata-headroom  test_static_userdata_headroom  coverage static "$TIMEOUT_STATIC" terraform
  register_test static-reaper-render      test_static_reaper_render      coverage static "$TIMEOUT_STATIC" terraform
  register_test static-reaper-script      test_static_reaper_script      coverage static 60 python3
  register_test static-neuron-cache-render test_static_neuron_cache_render coverage static 60 helm

  register_test image-build-ddp-sample-golden test_image_build_ddp_sample_golden baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-custom-render     test_image_build_custom_render     baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-callers-exclusive test_image_build_callers_exclusive baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-guards            test_image_build_guards            baseline static "$TIMEOUT_STATIC" helm

  register_test control-plane           test_control_plane           baseline live-ro "$TIMEOUT_BASE"
  register_test system-nodes            test_system_nodes            baseline live-ro "$TIMEOUT_BASE"
  register_test karpenter               test_karpenter               baseline live-ro "$TIMEOUT_BASE"
  register_test csi-drivers             test_csi_drivers             baseline live-ro "$TIMEOUT_BASE"
  register_test device-plugins          test_device_plugins          baseline live-ro "$TIMEOUT_BASE"
  register_test trainer                 test_trainer                 baseline live-ro "$TIMEOUT_BASE"
  register_test reaper-cronjob-presence test_reaper_cronjob_presence coverage live-ro 60 terraform jq
  register_test reaper-dryrun-flag      test_reaper_dryrun_flag      coverage live-ro 60 terraform jq

  register_test storage-mount            test_storage_mount              baseline live-mut 180
  register_test reaper-dryrun-job        test_reaper_dryrun_job          coverage live-mut 360 terraform jq
  register_test neuron-cache-pvc-bound   test_neuron_cache_pvc_bound     coverage live-mut 180 jq
  register_test neuron-cache-multi-pvc   test_neuron_cache_multi_pvc_coexist coverage live-mut 180 jq

  register_test gpu-node-launch               test_gpu_node_launch               full gpu "$TIMEOUT_GPU"
  register_test nvidia-smi-check              test_nvidia_smi                    full gpu "$TIMEOUT_BASE"
  register_test cuda-vector-add               test_cuda_vector_add               full gpu "$TIMEOUT_GPU"
  register_test gpu-fsx-mount                 test_gpu_fsx_mount                 full gpu "$TIMEOUT_GPU"
  register_test kubelet-headroom-live         test_kubelet_headroom_live         full gpu 120 terraform jq python3
  register_test kubelet-headroom-default-live test_kubelet_headroom_default_live full gpu 60 terraform jq
}
