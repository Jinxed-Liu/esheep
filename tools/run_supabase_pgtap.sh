#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
project_id="$(awk -F '"' '/^project_id = / { print $2; exit }' "$repo_root/supabase/config.toml")"
db_container="$(docker ps --format '{{.Names}}' | rg "^supabase_db_${project_id}$" | head -n 1)"

if [[ -z "$db_container" ]]; then
  print -u2 -- "未找到本地 Supabase 数据库容器，请先执行 supabase start 或 supabase db reset。"
  exit 1
fi

test_files=("$repo_root"/supabase/tests/database/*.test.sql(N))
if (( ${#test_files[@]} == 0 )); then
  print -u2 -- "未发现 Supabase pgTAP 测试文件。"
  exit 1
fi

planned_total=0
todo_total=0
for test_file in "${test_files[@]}"; do
  output_file="$(mktemp -t esheep-pgtap.XXXXXX)"
  print -r -- "pgTAP: ${test_file:t}"
  docker exec -i "$db_container" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres \
    < "$test_file" | tee "$output_file"

  if rg -q '^\s*not ok [0-9]+(?!.*# TODO)' --pcre2 "$output_file"; then
    print -u2 -- "pgTAP 存在非 TODO 失败：${test_file:t}"
    exit 1
  fi

  planned="$(sed -nE 's/^[[:space:]]*1\.\.([0-9]+)[[:space:]]*$/\1/p' "$output_file" | head -n 1)"
  if [[ -z "$planned" || "$planned" == "0" ]]; then
    print -u2 -- "pgTAP 测试发现数为 0：${test_file:t}"
    exit 1
  fi
  planned_total=$((planned_total + planned))
  todo_count="$(rg -c '^\s*not ok [0-9]+.*# TODO' "$output_file" || true)"
  todo_total=$((todo_total + todo_count))
done

print -r -- "Supabase pgTAP gate passed: files=${#test_files[@]}, planned=$planned_total, todo=$todo_total, failed=0"
