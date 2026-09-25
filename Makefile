# chain: build with a host copy of zap, the eZ80 assembler.
#
#   make                  build/chain.bin and the test programs
#   make test             run them in the emulator
#   make B=build/x GUARDS=0 REPAIR=0
#                         a build with a feature switched off, for the tests
#                         that check each feature is what makes them pass
#
# zap resolves INCLUDE and INCBIN against the directory it runs in, so the
# sources are staged into the build directory and assembled there.

ZAP_SRC ?= $(HOME)/code/zap
B       ?= build
GUARDS  ?= 1
REPAIR  ?= 1

ZAP     := $(abspath build/zap)
CORE_MAX := 2816        # CTL_BASE - CORE_BASE: the core's code must end below its data

ZAP_SRCS := $(addprefix $(ZAP_SRC)/, src/zap.c src/symtab.c src/scan.c src/expr.c \
	src/macro.c src/directive.c src/insn.c src/object.c src/buf_reader.c \
	src/value.c src/conv.c src/isa_table.c test/stubs/agon_stubs.c)

PROGS := $(patsubst test/progs/%.s,$(B)/test/%.bin,$(wildcard test/progs/*.s))

.PHONY: all test clean FORCE

all: $(B)/chain.bin $(PROGS)

$(ZAP): $(ZAP_SRCS)
	@mkdir -p $(dir $@)
	cc -std=gnu11 -O1 -fsigned-char -include $(ZAP_SRC)/test/stubs/host_types.h \
		-I$(ZAP_SRC)/src -I$(ZAP_SRC)/test/stubs -o $@ $(ZAP_SRCS)

# Rewritten only when a setting changes, so switching GUARDS rebuilds the core.
$(B)/config.inc: FORCE
	@mkdir -p $(B)
	@printf 'GUARDS: equ %s\nREPAIR: equ %s\n' $(GUARDS) $(REPAIR) > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

$(B)/core.bin: src/core.s src/mos_api.inc src/layout.inc $(B)/config.inc $(ZAP)
	cp src/core.s src/mos_api.inc src/layout.inc $(B)/
	cd $(B) && $(ZAP) -c core.s core.bin > core.log || { cat core.log; exit 1; }
	@size=$$(stat -c %s $@); if [ $$size -gt $(CORE_MAX) ]; then \
		echo "core is $$size bytes; it must fit in $(CORE_MAX)"; rm -f $@; exit 1; fi

$(B)/chain.bin: src/chain.s src/mos_api.inc src/layout.inc $(B)/core.bin $(ZAP)
	cp src/chain.s src/mos_api.inc src/layout.inc $(B)/
	cd $(B) && $(ZAP) -c chain.s chain.bin > chain.log || { cat chain.log; exit 1; }

$(B)/test/%.bin: test/progs/%.s src/mos_api.inc $(ZAP)
	@mkdir -p $(B)/test
	cp $< src/mos_api.inc $(B)/test/
	cd $(B)/test && $(ZAP) -c $*.s $*.bin > $*.log || { cat $*.log; exit 1; }

test: all
	test/run.sh

clean:
	rm -rf build
