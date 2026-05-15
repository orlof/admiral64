KICKASS := java -jar $(HOME)/bin/KickAssembler/KickAss.jar
PYTHON  := python3
SRC     := src
BUILD   := $(CURDIR)/build
TOP     := admiral

EXAMPLES_DIR := examples
PACK         := tools/pack_str_record.py
# VICE's c1541 — install VICE and the binary is at this path on macOS.
# Override with `make C1541=/path/to/c1541` for other locations.
C1541        := /Applications/vice-arm64-gtk3-3.9/bin/c1541

EXAMPLE_SRCS := $(wildcard $(EXAMPLES_DIR)/*.admiral)
EXAMPLE_BINS := $(patsubst $(EXAMPLES_DIR)/%.admiral,$(BUILD)/%.bin,$(EXAMPLE_SRCS))
# Build the per-file `-write hostfile cbmname,s` trio for each example.
EXAMPLE_WRITES = $(foreach src,$(EXAMPLE_SRCS),\
    -write $(BUILD)/$(basename $(notdir $(src))).bin $(basename $(notdir $(src))),s)

PRG  := $(BUILD)/$(TOP).prg
DISK := $(BUILD)/$(TOP).d64

GENERATED := $(SRC)/tst_builtins.asm
SOURCES   := $(filter-out $(GENERATED),$(wildcard $(SRC)/*.asm)) $(GENERATED)

.PHONY: all prg disk clean test

all: $(DISK)

prg: $(PRG)

disk: $(DISK)

$(GENERATED): tools/build_tst.py
	$(PYTHON) $< $@

$(PRG): $(SOURCES) | $(BUILD)
	$(KICKASS) -odir $(BUILD) -vicesymbols $(SRC)/$(TOP).asm

# Pack one .admiral source into a single-record TYPE_STR stream that
# `LOAD("<name>")` deserializes into a callable/editable string.
$(BUILD)/%.bin: $(EXAMPLES_DIR)/%.admiral $(PACK) | $(BUILD)
	$(PYTHON) $(PACK) $< $@

# Bundle admiral.prg + every examples/*.admiral (packed) into a fresh .d64
# via VICE's c1541. `-format` creates a blank disk; subsequent `-write`
# commands push each file in. Remove any stale image first since `-format`
# overwrites cleanly but we want a fresh inode each build.
$(DISK): $(PRG) $(EXAMPLE_BINS) | $(BUILD)
	rm -f $@
	$(C1541) -format "admiral nn,01" d64 $@ \
	  -write $(PRG) $(TOP),p \
	  $(EXAMPLE_WRITES)

$(BUILD):
	mkdir -p $@

test: $(PRG)
	.venv/bin/pytest tests/ -v

clean:
	rm -rf $(BUILD)
	rm -f $(GENERATED)
