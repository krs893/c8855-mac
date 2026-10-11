#!/bin/bash
set -euo pipefail
task_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
task_source_key="$(printf '%s' "$task_source_dir" | shasum -a 256 | cut -c1-16)"
task_cache_dir="$HOME/Library/Caches/dev.lab.c8855/counter-cli-$task_source_key"
task_binary="$task_cache_dir/c8855_counter"
task_fingerprint_file="$task_cache_dir/sources.sha256"
task_dependencies=("$task_source_dir/counter_cli.sh" "$task_source_dir/c8855_client.cpp" "$task_source_dir/counter_cli.cpp")
while IFS= read -r -d '' task_dependency; do
  task_dependencies+=("$task_dependency")
done < <(find "$task_source_dir/include" "$task_source_dir/vendor" -type f -print0)
for task_dependency in "${task_dependencies[@]}"; do
  if [ ! -f "$task_dependency" ]; then printf 'Missing source dependency: %s\n' "$task_dependency" >&2; exit 2; fi
done
task_fingerprint="$(shasum -a 256 "${task_dependencies[@]}" | shasum -a 256 | cut -d ' ' -f1)"
mkdir -p "$task_cache_dir"
task_previous_fingerprint=""
if [ -f "$task_fingerprint_file" ]; then task_previous_fingerprint="$(cat "$task_fingerprint_file")"; fi
if [ ! -x "$task_binary" ] || [ "$task_fingerprint" != "$task_previous_fingerprint" ]; then
  if ! mkdir "$task_cache_dir/build.lock" 2>/dev/null; then
    printf 'Counter CLI build is already in progress; retry after it finishes.\n' >&2
    exit 2
  fi
  task_temp_binary="$(mktemp "$task_cache_dir/.counter-cli.XXXXXX")"
  task_temp_fingerprint="$(mktemp "$task_cache_dir/.sources.XXXXXX")"
  trap 'rm -f "$task_temp_binary" "$task_temp_fingerprint"; rmdir "$task_cache_dir/build.lock" 2>/dev/null || true' EXIT
  xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=13.0 -Wall -Wextra -Wpedantic -Werror \
    -I"$task_source_dir/include" -I"$task_source_dir/vendor" \
    "$task_source_dir/c8855_client.cpp" "$task_source_dir/counter_cli.cpp" \
    -lcurl -pthread -o "$task_temp_binary"
  printf '%s\n' "$task_fingerprint" > "$task_temp_fingerprint"
  mv "$task_temp_binary" "$task_binary"
  mv "$task_temp_fingerprint" "$task_fingerprint_file"
  rmdir "$task_cache_dir/build.lock"
  trap - EXIT
fi
exec "$task_binary" "$@"
