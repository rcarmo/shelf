# Native Swift app build plus the original py2app targets.

PYTHON ?= python

VERSION = $(shell grep 'version =' legacy/setup.py | cut -d'"' -f 2)

.PHONY: all
all: native-app
	@ :

.PHONY: native-build
native-build:
	swift build

.PHONY: native-release
native-release:
	swift build -c release

.PHONY: native-run
native-run:
	swift run Shelf

.PHONY: native-app
native-app:
	scripts/build-native-app.sh

.PHONY: legacy-dev
legacy-dev:
	@echo -
	@echo - dev build will not work under Snow Leopard unless you\'ve fixed your local build!!
	@echo -
	cd legacy && $(PYTHON) setup.py py2app -A

.PHONY: legacy-dist
legacy-dist:
	cd legacy && $(PYTHON) setup.py py2app

.PHONY: zip
zip:
	cd dist && rm -f Shelf-$(VERSION).zip
	cd dist && zip -r9 Shelf-$(VERSION).zip Shelf.app/
	du -k dist/*.zip

.PHONY: clean
clean:
	rm -rf .build build dist legacy/build legacy/dist
