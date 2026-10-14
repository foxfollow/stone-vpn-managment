# StoneVPNManager — Xcode-проєкт у StoneVPNManager/, ядро — локальний пакет Packages/StoneVPNKit.
#   make build     Release-збірка → build/DerivedData/Build/Products/Release/StoneVPNManager.app
#   make install   скопіювати в /Applications (потрібно для helper-демона) і запустити
#   make test      unit-тести ядра (swift test у Packages/StoneVPNKit)
#   make status    діагностика без UI: --dump-status (порівнювати з ../main-vpn-manager.sh status)

PROJECT := StoneVPNManager/StoneVPNManager.xcodeproj
DERIVED := build/DerivedData
APP     := $(DERIVED)/Build/Products/Release/StoneVPNManager.app

.PHONY: build install test status clean

build:
	xcodebuild -project $(PROJECT) -scheme StoneVPNManager -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) build -quiet

install: build
	-pkill -x StoneVPNManager
	rm -rf /Applications/StoneVPNManager.app
	ditto $(APP) /Applications/StoneVPNManager.app
	open /Applications/StoneVPNManager.app

test:
	cd Packages/StoneVPNKit && swift test

status: build
	$(APP)/Contents/MacOS/StoneVPNManager --dump-status

clean:
	rm -rf build Packages/StoneVPNKit/.build
