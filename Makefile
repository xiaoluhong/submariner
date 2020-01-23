status ?= onetime
version ?= 1.14.2
logging ?= false
kubefed ?= false
deploytool ?= helm
armada ?= true
debug ?= false

TARGETS := $(shell ls scripts | grep -v dapper-image)

.dapper:
	@echo Downloading dapper
	@curl -sL https://releases.rancher.com/dapper/latest/dapper-`uname -s`-`uname -m` > .dapper.tmp
	@@chmod +x .dapper.tmp
	@./.dapper.tmp -v
	@mv .dapper.tmp .dapper

dapper-image: .dapper
	./.dapper -m bind dapper-image

$(TARGETS): .dapper
	DAPPER_ENV="OPERATOR_IMAGE"  ./.dapper -m bind $@ $(status) $(version) $(logging) $(kubefed) $(deploytool) $(armada) $(debug)

.DEFAULT_GOAL := ci

.PHONY: $(TARGETS)

