export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = roothide

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FixSthenoUIWindows

FixSthenoUIWindows_FILES = FixSthenoUIWindows.m
FixSthenoUIWindows_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FixSthenoUIWindows_FRAMEWORKS = Foundation UIKit QuartzCore
FixSthenoUIWindows_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
