# Sourced by AT simulation runners after setting root and build_dir.
# Use the same implementation-performance switches as the Quartus project.
# PCAT_PERF_CONFIG may name a frozen config for an explicit A/B comparison.
performance_config=${PCAT_PERF_CONFIG:-$root/config.tcl}
[[ -r "$performance_config" ]] || { echo "Missing performance config: $performance_config" >&2; return 1; }
mapfile -t project_macros < <(sed -n \
  's/^[[:space:]]*set_global_assignment -name VERILOG_MACRO "\(SPK286_P[0-9][0-9]_[A-Z0-9_]*\)".*/\1/p' \
  "$performance_config")
performance_flags=()
for macro in "${project_macros[@]}"; do performance_flags+=("-D$macro"); done
printf '%s\n' "${project_macros[@]}" > "$build_dir/performance-macros.txt"
sha256sum "$performance_config" > "$build_dir/performance-config.sha256"
