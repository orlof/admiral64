KICKASS := java -jar $(HOME)/bin/KickAssembler/KickAss.jar
SRC     := src
BUILD   := $(CURDIR)/build
TOP     := admiral

SOURCES := $(wildcard $(SRC)/*.asm)

.PHONY: all clean test

all: $(BUILD)/$(TOP).prg

$(BUILD)/$(TOP).prg: $(SOURCES) | $(BUILD)
	$(KICKASS) -odir $(BUILD) -vicesymbols $(SRC)/$(TOP).asm

$(BUILD):
	mkdir -p $@

test: all
	.venv/bin/pytest tests/ -v

clean:
	rm -rf $(BUILD)
