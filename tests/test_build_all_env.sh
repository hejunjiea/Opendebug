#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

grep -Fq 'DEBUG=${DEBUG:-1}' "$repo/build_all.sh"
grep -Fq 'FINALPACKAGE=${FINALPACKAGE:-0}' "$repo/build_all.sh"
grep -Fq 'INSTALL=${INSTALL:-0}' "$repo/build_all.sh"
grep -Fq 'RESPRING=${RESPRING:-0}' "$repo/build_all.sh"
grep -Fq 'BUMP_VERSION=${BUMP_VERSION:-0}' "$repo/build_all.sh"
grep -Fq 'CLEAN=${CLEAN:-1}' "$repo/build_all.sh"
grep -Fq 'PORT="${ODBG_SSH_PORT:-2222}"' "$repo/build_all.sh"
grep -Fq '推送安装包失败，未执行 dpkg，也未声称安装成功' "$repo/build_all.sh"
grep -Fq 'dpkg 安装失败' "$repo/build_all.sh"
grep -Fq 'catch wait result' "$repo/build_all.sh"

printf 'build_all environment override checks passed\n'
