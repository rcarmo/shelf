# wrapper Makefile for py2app invocation and cleaning

PYTHON ?= python

frameworks: Sparkle.framework

Sparkle.framework: Sparkle.framework.zip
	# expand Sparkle correctly, resource forks and all, using Archive Helper
	open Sparkle.framework.zip

.PHONY: all
all: dev
	@ :

.PHONY: dev
dev: frameworks
	$(PYTHON) setup.py py2app -A

.PHONY: dist
dist: frameworks
	$(PYTHON) setup.py py2app

.PHONY: clean
clean:
	rm -rf build dist Sparkle.framework Growl.framework
