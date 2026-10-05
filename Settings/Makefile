include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OpenDebugSettings

OpenDebugSettings_FILES = TANOpenDebugRootController.m \
                          TANOpenDebugAltListController.m \
                          ATLApplicationListControllerBase.m \
                          ATLApplicationListMultiSelectionController.m \
                          ATLApplicationListSelectionController.m \
                          ATLApplicationListSubcontroller.m \
                          ATLApplicationListSubcontrollerController.m \
                          ATLApplicationSection.m \
                          ATLApplicationSelectionCell.m \
                          ATLApplicationSubtitleCell.m \
                          ATLApplicationSubtitleSwitchCell.m \
                          LSApplicationProxy+AltList.m \
                          PSSpecifier+AltList.m

OpenDebugSettings_FRAMEWORKS = UIKit CoreGraphics
OpenDebugSettings_RESOURCES = $(wildcard Resources/*.plist)
OpenDebugSettings_INSTALL_PATH = /Library/PreferenceBundles
OpenDebugSettings_CFLAGS = -fobjc-arc -fmodules-cache-path=/private/tmp/clang-module-cache
OpenDebugSettings_LDFLAGS += -undefined dynamic_lookup

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp Resources/OpenDebugSettings.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/OpenDebugSettings.plist$(ECHO_END)

include $(THEOS_MAKE_PATH)/bundle.mk
