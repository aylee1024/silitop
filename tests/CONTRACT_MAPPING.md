# Legacy contract map

The 104 Python contracts present at the start of the native rewrite are mapped
below. A mapping names the Swift XCTest suites that preserve the behavior; the
new suite may express one legacy contract across multiple narrower tests.

## `test_extractors.py` — 25 contracts

Mapped to `PowerMetricsDecoderTests`, `ExtractorParityTests`,
`DashboardStateControllerTests`, and `TimingContractTests`:

- `test_combined_power_in_watts`
- `test_combined_power_does_not_depend_on_interval`
- `test_energy_fields_are_joules_per_interval`
- `test_energy_to_watts_scales_with_delta_t`
- `test_total_consistency`
- `test_extract_cpu_missing_processor`
- `test_extract_cpu_processor_not_a_dict`
- `test_extract_cpu_missing_clusters`
- `test_extract_cpu_missing_combined_power`
- `test_extract_cpu_skips_malformed_cluster_name`
- `test_extract_gpu_missing`
- `test_extract_gpu_not_a_dict`
- `test_extract_gpu_missing_idle_ratio`
- `test_extract_gpu_missing_freq`
- `test_extract_gpu_success`
- `test_extract_network_missing`
- `test_extract_network_partial`
- `test_extract_network_success`
- `test_extract_disk_missing`
- `test_extract_disk_partial`
- `test_extract_disk_success`
- `test_first_sample_falls_back_to_interval`
- `test_steady_state_returns_real_elapsed`
- `test_non_datetime_timestamps_fall_back`
- `test_zero_or_negative_delta_clamped_to_001`

## `test_helpers.py` — 24 contracts

Mapped to `NativeSensorIntegrationTests`, `SensorContractsTests`,
`TemperatureTestRunnerTests`, `TopologyDetectorTests`, and
`TopologyGenerationFixturesTests`. Helper-process failure contracts now map to
typed in-process unavailable/stale states rather than subprocess errors:

- `test_none_when_helper_missing` (temperature)
- `test_none_when_subprocess_raises` (temperature)
- `test_none_when_helper_times_out`
- `test_none_when_helper_nonzero_exit`
- `test_none_when_header_missing` (temperature)
- `test_none_when_header_wrong_version`
- `test_empty_dict_when_no_sensors`
- `test_parses_sensor_lines`
- `test_drops_malformed_lines_silently`
- `test_drops_nan_and_inf`
- `test_none_when_helper_missing` (fan)
- `test_none_when_subprocess_raises` (fan)
- `test_none_when_header_missing` (fan)
- `test_none_when_smc_unavailable`
- `test_empty_list_for_confirmed_fanless`
- `test_parses_fan_lines`
- `test_drops_lines_with_zero_max_rpm`
- `test_drops_nan_inf_rpm`
- `test_total_failure_yields_none_topology`
- `test_chip_line_used_when_sysctl_brand_string_fails`
- `test_m5_uppercase_matches`
- `test_m1_m4_lowercase_slow_prefix_still_matches`
- `test_empty_name_returns_false`
- `test_empty_prefix_returns_false`

## `test_install.py` — 12 contracts

Mapped to `InstallerContractsTests` and `ReleaseConfigurationTests`. The former
helper ownership contracts map to atomic `root:wheel` installation of the one
native executable and explicit legacy-helper cleanup:

- `test_root_uid_and_safe_mode_accepts_system_helper`
- `test_rejects_user_owned_system_helper`
- `test_rejects_group_writable_system_helper`
- `test_rejects_world_writable_system_helper`
- `test_returns_none_when_system_helper_missing`
- `test_root_does_not_fall_back_to_repo_local`
- `test_returns_local_when_present`
- `test_returns_none_when_neither_exists`
- `test_rejects_sudo_invocation`
- `test_path_shadow_check_is_present`
- `test_uses_install_with_root_wheel`
- `test_uninstall_is_documented`

## `test_interval_scaling.py` — 14 contracts

Mapped to `CLIOptionsTests`, `TimingContractTests`,
`DashboardStateControllerTests`, and `PowerMetricsProcessContractsTests`:

- `test_default_interval_keeps_120_samples`
- `test_interval_2_keeps_60_samples_for_120s`
- `test_interval_5_keeps_30_samples`
- `test_interval_60_keeps_30_floor`
- `test_default_30s_at_interval_1`
- `test_30s_at_interval_5_keeps_6_samples`
- `test_avg_below_interval_floors_at_one`
- `test_first_iteration_polls_immediately`
- `test_skips_until_3s_elapsed`
- `test_interval_1_fires_at_t3`
- `test_interval_5_fires_every_iteration`
- `test_interval_zero_rejected_before_subprocess`
- `test_interval_negative_rejected`
- `test_avg_below_interval_rejected`

The old slow-helper polling tests are represented by the native requirement
that sensors are sampled once per accepted powermetrics record; no recurring
helper process remains.

## `test_layout.py` — 15 contracts

Mapped to `DashboardRendererTests`, `MemoryCalculatorTests`,
`HostCollectorIntegrationTests`, and `AdditionalParityContractsTests`:

- `test_compute_bar_layout_clamps_and_never_overlaps`
- `test_core_row_suffix_stays_intact_at_99_100_and_over_100`
- `test_full_width_bar_suffix_stays_intact_at_100_and_over_100`
- `test_clamp_pct_safe_against_degenerate_inputs`
- `test_temp_color_thresholds_match_readme`
- `test_block_chars_and_hbar_removed`
- `test_fan_row_suffix_stays_intact`
- `test_m5_pro_snapshot_matches_activity_monitor`
- `test_low_pressure_idle`
- `test_returns_none_when_required_counter_missing`
- `test_returns_none_when_anonymous_missing`
- `test_pct_clamped_to_100`
- `test_swap_parsing_unchanged`
- `test_subprocess_failure_returns_none`
- `test_swap_subprocess_failure_does_not_void_panel`

## `test_lifecycle.py` — 14 contracts

Mapped to `NULRecordFramerTests`, `PowerMetricsProcessContractsTests`,
`SpawnedChildTests`, `KqueueTests`, `TerminalSessionTests`, and
`DashboardApplicationTests`. Temporary-file contracts map to the stronger
stdout-streaming invariant: no plist file is created at all.

- `test_creates_real_file`
- `test_path_starts_with_silitop_pm_under_tmp`
- `test_paths_are_unique_across_calls`
- `test_terminates_and_waits`
- `test_force_kills_when_wait_times_out`
- `test_swallows_already_dead_process`
- `test_handles_none_proc`
- `test_handles_missing_file`
- `test_handles_both_none`
- `test_unlinks_only_the_given_path`
- `test_returns_first_live_proc`
- `test_raises_when_all_samplers_fail`
- `test_handles_popen_oserror`
- `test_sigterm_handler_sets_event`

The rewritten contracts also cover PTY restoration, process-exit events, sampler fallback, fatal stalls,
backpressure, signals, and concurrent instances.

## Count reconciliation

The discoverable legacy counts are 25 + 24 + 12 + 14 + 15 + 14 = **104**.
The native suite contains at least 109 tests before legacy removal and expands
the contract surface rather than reducing it.
