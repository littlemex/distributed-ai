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
  register_test plan-guard-owned-complete       test_plan_guard_owned_list_is_complete   baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-no-stray-platform    test_plan_guard_no_platform_resources_elsewhere baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-table                test_plan_guard_table                    baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-protected-complete   test_plan_guard_protected_covers_prevent_destroy baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-mlflow-backend       test_plan_guard_mlflow_backend_never_switches_silently baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-aws-lookup          test_plan_guard_aws_lookup_failure_is_not_absence baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-removed-vars        test_plan_guard_removed_variables_refuse_to_be_set baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-installer-vars      test_plan_guard_installer_vars_are_declared baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-only-escape-hatch   test_plan_guard_profiling_only_escape_hatch_is_reachable baseline static "$TIMEOUT_STATIC"
  register_test plan-guard-cb-region-profile   test_plan_guard_cb_scripts_resolve_region_and_profile baseline static "$TIMEOUT_STATIC"
  register_test registry-matches-state          test_registry_matches_state              baseline static "$TIMEOUT_STATIC" terraform
  register_test registry-default-layer-attached test_registry_default_data_layer_is_attached baseline static "$TIMEOUT_STATIC"
  register_test registry-preamble-contract      test_registry_preamble_contract          baseline static "$TIMEOUT_STATIC"
  register_test registry-unknown-cluster-fails  test_registry_unknown_cluster_fails      baseline static "$TIMEOUT_STATIC"
  register_test registry-layout-agrees         test_registry_layout_is_stated_once       baseline static "$TIMEOUT_STATIC"
  register_test registry-release-pin           test_registry_release_pin_is_stated_once  baseline static "$TIMEOUT_STATIC"
  register_test registry-release-pin-tag       test_registry_release_pin_matches_the_tag_here baseline static "$TIMEOUT_STATIC" git
  register_test registry-release-pin-sites     test_registry_release_pin_sites_are_intact baseline static "$TIMEOUT_STATIC" git
  register_test registry-preamble-kubectl       test_registry_preamble_configures_kubectl baseline static "$TIMEOUT_STATIC" kubectl
  register_test registry-stale-context-dropped  test_registry_failed_resolve_drops_context baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-latest        test_accelprof_client_resolves_newest_run baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-hints         test_accelprof_client_hints_are_plugin_form baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-chip          test_accelprof_client_chip_follows_the_request baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-wait          test_accelprof_client_wait_waits_for_the_recording baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-wait-timeout  test_accelprof_client_wait_fails_when_nothing_is_recorded baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-output-guard  test_accelprof_client_rejects_bad_output_before_submitting baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-alias         test_accelprof_client_alias_narrows_the_latest baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-mlflow-url    test_accelprof_client_mlflow_url_comes_from_the_contract baseline static "$TIMEOUT_STATIC"
  register_test accelprof-client-diagnosis     test_accelprof_client_separates_unreadable_from_unwired baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-discovery                test_distai_mcp_discovers_by_label_and_reads_the_declared_port baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-path                     test_distai_mcp_takes_the_path_from_the_annotation baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-probe                    test_distai_mcp_probe_reads_the_body_not_the_status baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-local-state              test_distai_mcp_down_and_status_use_local_state baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-denied-list              test_distai_mcp_reports_a_denied_list_as_a_permission_problem baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-old-chart                test_distai_mcp_names_an_old_chart_when_the_label_is_absent baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-local-port               test_distai_mcp_local_port_does_not_move_silently baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-exec                     test_distai_mcp_exec_exports_generic_names_and_passes_the_exit_code baseline static "$TIMEOUT_STATIC"
  register_test distai-mcp-chart-label              test_mcp_host_chart_labels_the_service baseline static "$TIMEOUT_STATIC"
  register_test static-terraform-validate test_static_terraform_validate baseline static "$TIMEOUT_STATIC" terraform
  register_test static-profiling-install-kubeconfig test_profiling_install_leaves_the_caller_kubeconfig_alone baseline static "$TIMEOUT_STATIC"

  register_test image-build-ddp-sample-golden test_image_build_ddp_sample_golden baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-custom-render     test_image_build_custom_render     baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-callers-exclusive test_image_build_callers_exclusive baseline static "$TIMEOUT_STATIC" helm
  register_test image-build-guards            test_image_build_guards            baseline static "$TIMEOUT_STATIC" helm

  # P0 chart-contract: render the workshop serving workloads and assert their structure. Cluster
  # not needed, so these run in baseline/static on every PR and catch a broken serving chart.
  register_test static-gpu-serving-contract   test_static_gpu_serving_contract   baseline static "$TIMEOUT_STATIC" helm
  register_test static-nccl-ifname-source     test_static_nccl_socket_ifname_single_source baseline static "$TIMEOUT_STATIC" helm
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
