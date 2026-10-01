#!/bin/sh

set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
nvim_bin=${NVIM_BIN:-nvim}
passed=0

if [ -n "${NO_COLOR:-}" ]; then
  cyan=''
  green=''
  red=''
  reset=''
else
  cyan=$(printf '\033[36m')
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  reset=$(printf '\033[0m')
fi

for test_file in "$tests_dir"/test_*.lua; do
  test_name=$(basename -- "$test_file")
  printf '%sRUN%s: %s\n' "$cyan" "$reset" "$test_name"
  marker=$(mktemp)
  rm -f "$marker"
  status=0
  "$nvim_bin" --headless -u NONE -l "$tests_dir/run_one.lua" "$test_file" "$marker" || status=$?
  if [ "$status" -eq 0 ] && [ ! -f "$marker" ]; then
    printf '%s测试未跑完就退出了（退出码 0 但没有完成标记）%s\n' "$red" "$reset" >&2
    status=1
  fi
  rm -f "$marker"
  if [ "$status" -eq 0 ]; then
    passed=$((passed + 1))
    printf '%sPASS%s: %s\n' "$green" "$reset" "$test_name"
  else
    printf '%sFAIL%s: %s\n' "$red" "$reset" "$test_name" >&2
    exit "$status"
  fi
done

printf '%sPASS%s: %d test files\n' "$green" "$reset" "$passed"
