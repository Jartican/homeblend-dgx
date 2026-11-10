#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

for command in cryptsetup mktemp truncate dd grep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 2
  }
done

work_dir="$(mktemp -d /tmp/homeblend-luks-format.XXXXXX)"
key_dir="$(mktemp -d /dev/shm/homeblend-luks-key.XXXXXX)"
case "$work_dir" in /tmp/homeblend-luks-format.*) ;; *) exit 2 ;; esac
case "$key_dir" in /dev/shm/homeblend-luks-key.*) ;; *) exit 2 ;; esac

image="$work_dir/postgres-test.luks"
key_file="$key_dir/key"
wrong_key_file="$key_dir/wrong-key"

cleanup() {
  case "$key_dir" in
    /dev/shm/homeblend-luks-key.*) rm -f -- "$key_file" "$wrong_key_file"; rmdir -- "$key_dir" 2>/dev/null || true ;;
  esac
  case "$work_dir" in
    /tmp/homeblend-luks-format.*) rm -f -- "$image"; rmdir -- "$work_dir" 2>/dev/null || true ;;
  esac
}
trap cleanup EXIT HUP INT TERM

chmod 0700 "$work_dir" "$key_dir"
dd if=/dev/urandom of="$key_file" bs=64 count=1 status=none
dd if=/dev/urandom of="$wrong_key_file" bs=64 count=1 status=none
chmod 0600 "$key_file" "$wrong_key_file"
[[ -s "$key_file" && -s "$wrong_key_file" ]] || {
  echo 'Ephemeral key creation failed.' >&2
  exit 1
}

truncate -s 128M "$image"
chmod 0600 "$image"
cryptsetup luksFormat \
  --batch-mode \
  --type luks2 \
  --pbkdf argon2id \
  --key-file "$key_file" \
  "$image"

cryptsetup isLuks --type luks2 "$image"
dump="$(cryptsetup luksDump "$image")"
grep -Eq '^Version:[[:space:]]+2$' <<<"$dump"
grep -Eq '^[[:space:]]+PBKDF:[[:space:]]+argon2id$' <<<"$dump"

if cryptsetup open --test-passphrase --key-file "$wrong_key_file" "$image" 2>/dev/null; then
  echo 'Wrong ephemeral key unexpectedly unlocked the test image.' >&2
  exit 1
fi
cryptsetup open --test-passphrase --key-file "$key_file" "$image"

echo 'LUKS_FORMAT_DRILL=passed'
echo 'Verified LUKS2, Argon2id, correct-key acceptance, and wrong-key rejection.'
echo 'No mapper was opened, nothing was mounted, and no live PostgreSQL path was touched.'
