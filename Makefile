export THEOS_DEVICE_IP = 192.168.180.14
export THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ODebug

ODebug_FILES = Tweak.xm \
               TANDebugConsole.m \
               TANDebugVCDump.m \
               TANHookConsole.m \
               TANSafeMode.m

ODebug_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
ODebug_FRAMEWORKS = UIKit CoreGraphics
ODebug_LDFLAGS += -undefined dynamic_lookup $(THEOS)/vendor/lib/iphone/roothide/libsubstrate.tbd

include $(THEOS_MAKE_PATH)/tweak.mk

# 常驻调试服务（LaunchDaemon，root）：安全模式下插件内控制台必然消失，
# 这个服务从进程外工作，所以安全模式下照旧可用（保命通道 + root 调试 + 后续注入器）。
TOOL_NAME = odebugd
odebugd_FILES = odebugd.m
odebugd_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
odebugd_FRAMEWORKS = Foundation
odebugd_INSTALL_PATH = /usr/bin
# LaunchDaemon 默认在沙盒里 ⇒ 没有 task_for_pid / 列进程 / 读 jbroot 的权限。
# 这套 entitlement 从真机 /usr/sbin/frida-server.ent 里挑了最小集合（见文件内注释）。
odebugd_CODESIGN_FLAGS = -Slayout/usr/share/odebugd/odebugd.ent

include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += Settings

include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
