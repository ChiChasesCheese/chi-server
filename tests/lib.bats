#!/usr/bin/env bats
# Unit tests for scripts/lib.sh helpers. Run: bats tests/

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CHI_ROOT="$REPO"
  # shellcheck source=../scripts/lib.sh
  . "$REPO/scripts/lib.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "set_kv appends a missing key" {
  printf 'A=1\n' >"$TMP/env"
  set_kv "$TMP/env" B 2
  run cat "$TMP/env"
  [ "$output" = $'A=1\nB=2' ]
}

@test "set_kv replaces an existing key and keeps the others" {
  printf 'A=1\nB=old\nC=3\n' >"$TMP/env"
  set_kv "$TMP/env" B new
  run cat "$TMP/env"
  [ "$output" = $'A=1\nB=new\nC=3' ]
}

@test "set_kv keeps values containing = and special characters" {
  set_kv "$TMP/env" URL 'https://x.example/?a=b&c=/d'
  run get_kv "$TMP/env" URL
  [ "$output" = 'https://x.example/?a=b&c=/d' ]
}

@test "get_kv strips quotes and returns the last occurrence" {
  printf 'K="first"\nK="second"\n' >"$TMP/env"
  run get_kv "$TMP/env" K
  [ "$output" = second ]
}

@test "get_kv on a missing file prints nothing and succeeds" {
  run get_kv "$TMP/nope" K
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "rand_alnum returns the requested length of alphanumerics" {
  run rand_alnum 20
  [ "${#output}" -eq 20 ]
  [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "render_tmpl substitutes placeholders literally" {
  printf 'a=__FOO__ b=__BAR__ c=__NONE__\n' >"$TMP/t"
  TPL_FOO='x&y/z\b' TPL_BAR='#1' run render_tmpl "$TMP/t"
  [ "$output" = 'a=x&y/z\b b=#1 c=__NONE__' ]
}

@test "resolve_stacks prefers arguments, then CHI_STACKS, then core" {
  run resolve_stacks media ai
  [ "$output" = "media ai" ]
  CHI_STACKS="core public" run resolve_stacks
  [ "$output" = "core public" ]
  unset CHI_STACKS
  run resolve_stacks
  [ "$output" = core ]
}

@test "every stack has a compose.yaml or fetch.sh, and a stack.conf with a description" {
  for s in $(all_stacks); do
    [ -f "$REPO/stacks/$s/compose.yaml" ] || [ -x "$REPO/stacks/$s/fetch.sh" ]
    [ -n "$(stack_conf "$s" DESCRIPTION)" ]
  done
}

@test "stack_conf reads keys without leaking into the caller" {
  run stack_conf core SERVE
  [[ "$output" == *"443="* ]]
  stack_conf core DESCRIPTION >/dev/null
  [ -z "${DESCRIPTION:-}" ]
}

@test "stack_conf on a stack without a manifest prints nothing" {
  run stack_conf does-not-exist SERVE
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "SERVE ports are unique across stacks" {
  dupes="$(for s in $(all_stacks); do for p in $(stack_conf "$s" SERVE); do echo "${p%%=*}"; done; done | sort | uniq -d)"
  [ -z "$dupes" ]
}

@test "chi stacks lists every stack" {
  run "$REPO/bin/chi" stacks
  [ "$status" -eq 0 ]
  for s in $(all_stacks); do [[ "$output" == *" $s "* ]]; done
}

@test "chi with an unknown command exits non-zero" {
  run "$REPO/bin/chi" no-such-command
  [ "$status" -ne 0 ]
}
