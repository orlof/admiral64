KICKASS := java -jar $(HOME)/bin/KickAssembler/KickAss.jar
PYTHON  := python3
SRC     := src
BUILD   := $(CURDIR)/build
TOP     := admiral

EXAMPLES_DIR := examples
PACK         := tools/pack_str_record.py
# pack_object.py serializes a .admiral file's RETURN value (a dict) via the
# real admiral.prg in py65 so LOAD returns the object directly. Used for the
# graphics-mode libraries; needs the .venv (py65) and the freshly built PRG.
PACK_OBJ     := tools/pack_object.py
VENV_PY      := .venv/bin/python3
# Extensions packed as serialized objects (not source strings). Each must
# correspond to an examples/<name>.admiral whose body ends with `RETURN <var>`.
OBJECT_EXAMPLES := text hires mc
# VICE — install VICE and the binaries are at these paths on macOS.
# Override with `make C1541=... X64=...` for other locations.
VICE_BIN     := /Applications/vice-arm64-gtk3-3.9/bin
C1541        := $(VICE_BIN)/c1541
X64          := $(VICE_BIN)/x64sc

PLUGIN_SRCS  := $(wildcard plugins/*.asm)
PLUGIN_BINS  := $(patsubst plugins/%.asm,$(BUILD)/plugin_%.bin,$(PLUGIN_SRCS))
PLUGIN_WRITES = $(foreach src,$(PLUGIN_SRCS),\
    -write $(BUILD)/plugin_$(basename $(notdir $(src))).bin $(basename $(notdir $(src))),s)

EXAMPLE_SRCS := $(wildcard $(EXAMPLES_DIR)/*.admiral)
EXAMPLE_BINS := $(patsubst $(EXAMPLES_DIR)/%.admiral,$(BUILD)/%.bin,$(EXAMPLE_SRCS))
# Build the per-file `-write hostfile cbmname,s` trio for each example.
EXAMPLE_WRITES = $(foreach src,$(EXAMPLE_SRCS),\
    -write $(BUILD)/$(basename $(notdir $(src))).bin $(basename $(notdir $(src))),s)

PRG  := $(BUILD)/$(TOP).prg
DISK := $(BUILD)/$(TOP).d64

GENERATED := $(SRC)/tst_builtins.asm
SOURCES   := $(filter-out $(GENERATED),$(wildcard $(SRC)/*.asm)) $(GENERATED)

.PHONY: all prg disk clean test run

all: $(DISK)

prg: $(PRG)

disk: $(DISK)

$(GENERATED): tools/build_tst.py
	$(PYTHON) $< $@

$(PRG): $(SOURCES) | $(BUILD)
	$(KICKASS) -odir $(BUILD) -vicesymbols $(SRC)/$(TOP).asm

# v2 TYPE_CODE plugins: three-base assembly + fixup table + record framing.
$(BUILD)/plugin_%.bin: plugins/%.asm $(SRC)/sys.inc tools/build_plugin.py | $(BUILD)
	$(PYTHON) tools/build_plugin.py $< $@

# Pack one .admiral source into a single-record TYPE_STR stream that
# `LOAD("<name>")` deserializes into a callable/editable string. The
# explicit rules below override this for OBJECT_EXAMPLES.
$(BUILD)/%.bin: $(EXAMPLES_DIR)/%.admiral $(PACK) | $(BUILD)
	$(PYTHON) $(PACK) $< $@

# Object-serialized extensions: run the source through admiral.prg in py65,
# call SAVE on its RETURN value, capture the on-disk bytes. The user does
# `LOAD("HIRES")` (no parens) and gets the dict directly.
define OBJECT_RULE
$$(BUILD)/$1.bin: $$(EXAMPLES_DIR)/$1.admiral $$(PACK_OBJ) $$(PRG) | $$(BUILD)
	$$(VENV_PY) $$(PACK_OBJ) $$< $$@ $(shell echo $1 | tr a-z A-Z)
endef
$(foreach name,$(OBJECT_EXAMPLES),$(eval $(call OBJECT_RULE,$(name))))

# Bundle admiral.prg + every examples/*.admiral (packed) into a fresh .d64
# via VICE's c1541. `-format` creates a blank disk; subsequent `-write`
# commands push each file in. Remove any stale image first since `-format`
# overwrites cleanly but we want a fresh inode each build.
$(DISK): $(PRG) $(EXAMPLE_BINS) $(PLUGIN_BINS) | $(BUILD)
	rm -f $@
	$(C1541) -format "admiral nn,01" d64 $@ \
	  -write $(PRG) $(TOP),p \
	  $(EXAMPLE_WRITES) \
	  $(PLUGIN_WRITES)

$(BUILD):
	mkdir -p $@

test: $(PRG)
	.venv/bin/pytest tests/ -v

# Build the disk image and boot it in VICE (true-1541 emulation, autostart).
# Detached: stdout/stderr must be redirected or make blocks on the open pipe.
run: $(DISK)
	$(X64) -autostart $(DISK) > /dev/null 2>&1 &

clean:
	rm -rf $(BUILD)
	rm -f $(GENERATED)
