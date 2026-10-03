# Sourced by AT simulation runners after setting root and build_dir.
# Production has one fixed CPU implementation, with no opt-in macros.
# Reject obsolete profile overrides instead of silently running false A/Bs.
performance_config=${PCAT_PERF_CONFIG:-$root/config.tcl}
[[ -r "$performance_config" ]] || { echo "Missing performance config: $performance_config" >&2; return 1; }
mapfile -t project_macros < <(sed -n \
  's/^[[:space:]]*set_global_assignment -name VERILOG_MACRO "\(SPK286_P[0-9][0-9]_[A-Z0-9_]*\|SPK286_AT_RAM_READ_BUFFER\)".*/\1/p' \
  "$performance_config")
performance_flags=()
if [[ ${#project_macros[@]} != 0 ]]; then
  echo 'Retired CPU performance macros: use the matching historical source snapshot for old profiles.' >&2
  return 1
fi
: > "$build_dir/performance-macros.txt"
printf 'fixed-fast\n' > "$build_dir/cpu-implementation.txt"
sha256sum "$performance_config" > "$build_dir/performance-config.sha256"
