#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
control_version=$(awk '/^Version:/{print $2; exit}' "$repo/control")

grep -Fq "static NSString *gVersion = @\"$control_version\";" "$repo/odebugd.m"
grep -Fq 'static NSString *cmdUserspaceReboot(NSString *arg)' "$repo/odebugd.m"
grep -Fq 'argv[] = {launchctl.UTF8String, "reboot", "userspace", NULL}' "$repo/odebugd.m"
grep -Fq 'if ([cmd hasPrefix:@"!ureboot"])' "$repo/odebugd.m"
grep -Fq '[a isEqualToString:@"off all"]' "$repo/odebugd.m"
grep -Fq 'safeModeMarkersAbsent' "$repo/odebugd.m"
grep -Fq '!safe off all' "$repo/odebugd.m"
grep -Fq '!ureboot confirm' "$repo/odebug.sh"
grep -Fq '__ODEBUG_END__' "$repo/odebugd.m"
grep -Fq 'ODEBUG_WIRE_COMMAND' "$repo/odebug.sh"
grep -Fq '"重启用户空间（不修改安全模式）"' "$repo/odebug.sh"
grep -Fq '"退出安全模式并重启用户空间"' "$repo/odebug.sh"
grep -Fq 'safemode_daemon_interactive()' "$repo/odebug.sh"
grep -Fq '"进入安全模式并重启用户空间"' "$repo/odebug.sh"
grep -Fq '进入安全模式并重启整个用户空间' "$repo/odebug.sh"
grep -Fq '"安全模式菜单"' "$repo/odebug.sh"
grep -Fq '"!safe respring" "重启 SpringBoard（不修改安全模式）"' "$repo/odebug.sh"
grep -Fq '只重启 SpringBoard（不修改安全模式标记）' "$repo/odebug.sh"
grep -Fq '确认重启整个用户空间' "$repo/odebug.sh"
grep -Fq '确认删除安全模式标记并重启整个用户空间' "$repo/odebug.sh"

printf 'userspace reboot source checks passed\n'
