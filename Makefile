KICKASS := java -jar $(HOME)/bin/KickAssembler/KickAss.jar
PYTHON  := python3
SRC     := src
BUILD   := $(CURDIR)/build
TOP     := admiral

GENERATED := $(SRC)/tst_builtins.asm
SOURCES   := $(filter-out $(GENERATED),$(wildcard $(SRC)/*.asm)) $(GENERATED)

.PHONY: all clean test

all: $(BUILD)/$(TOP).prg

$(GENERATED): tools/build_tst.py
	$(PYTHON) $< $@

$(BUILD)/$(TOP).prg: $(SOURCES) | $(BUILD)
	$(KICKASS) -odir $(BUILD) -vicesymbols $(SRC)/$(TOP).asm

$(BUILD):
	mkdir -p $@

test: all
	.venv/bin/pytest tests/ -v

clean:
	rm -rf $(BUILD)
	rm -f $(GENERATED)
