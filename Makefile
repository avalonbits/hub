# hub: build with a host copy of zap, the eZ80 assembler.
#
#   make                  build/hub.bin and the test programs
#   make test             run them in the emulator (the CLI one, and the full
#                         one for the user screen), and check the library
#                         package
#   make B=build/x GUARDS=0 REPAIR=0 SNAPSHOT=0 CAPTURE=0 PROMPTFONT=0 API_COUNT=8
#                         a build with a feature switched off, for the tests
#                         that check each feature is what makes them pass
#
# zap resolves INCLUDE and INCBIN against the directory it runs in, so the
# sources are staged into the build directory and assembled there.

ZAP_SRC ?= $(HOME)/code/zap
B       ?= build
GUARDS  ?= 1
REPAIR  ?= 1
SNAPSHOT ?= 1
CAPTURE ?= 1
PROMPTFONT ?= 1
API_COUNT ?= 9          # entries hub advertises; 8 poses as hub 0.3, for a test

ZAP     := $(abspath build/zap)
CORE_MAX := 1792        # CTL_BASE - CORE_BASE: the core's code must end below its data

ZAP_SRCS := $(addprefix $(ZAP_SRC)/, src/zap.c src/symtab.c src/scan.c src/expr.c \
	src/macro.c src/directive.c src/insn.c src/object.c src/buf_reader.c \
	src/value.c src/conv.c src/isa_table.c test/stubs/agon_stubs.c)

PROGS := $(patsubst test/progs/%.s,$(B)/test/%.bin,$(wildcard test/progs/*.s)) \
	$(B)/test/cclient.bin $(B)/test/cclienta.bin $(B)/test/shot.bin

AGONDEV ?= $(HOME)/agondev
ACC     ?= $(HOME)/code/acc/bin/acc     # acc's host build: libc, rt and headers beside it

.PHONY: all test clean FORCE

EXAMPLES := $(addprefix examples/bin/,seq.bin rep.bin see.bin hubinfo.bin)

all: $(B)/hub.bin $(B)/lib/agondev/libhub.a $(B)/lib/acc/libhub.a $(PROGS) $(EXAMPLES)

$(ZAP): $(ZAP_SRCS)
	@mkdir -p $(dir $@)
	cc -std=gnu11 -O1 -fsigned-char -include $(ZAP_SRC)/test/stubs/host_types.h \
		-I$(ZAP_SRC)/src -I$(ZAP_SRC)/test/stubs -o $@ $(ZAP_SRCS)

# Rewritten only when a setting changes, so switching GUARDS rebuilds the core.
$(B)/config.inc: FORCE
	@mkdir -p $(B)
	@printf 'GUARDS: equ %s\nREPAIR: equ %s\nSNAPSHOT: equ %s\nCAPTURE: equ %s\nPROMPTFONT: equ %s\nAPI_COUNT: equ %s\n' \
		$(GUARDS) $(REPAIR) $(SNAPSHOT) $(CAPTURE) $(PROMPTFONT) $(API_COUNT) > $@.new
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@

CORE_SRCS  := $(wildcard src/core/*.s)
SHELL_SRCS := $(wildcard src/shell/*.s)

$(B)/core.bin: src/core.s $(CORE_SRCS) src/mos_api.inc src/layout.inc src/hub.inc $(B)/config.inc $(ZAP)
	cp src/core.s src/mos_api.inc src/layout.inc src/hub.inc $(B)/
	rm -rf $(B)/core && cp -r src/core $(B)/core
	cd $(B) && $(ZAP) -c core.s core.bin > core.log || { cat core.log; exit 1; }
	@size=$$(stat -c %s $@); if [ $$size -gt $(CORE_MAX) ]; then \
		echo "core is $$size bytes; it must fit in $(CORE_MAX)"; rm -f $@; exit 1; fi

$(B)/hub.bin: src/hub.s $(SHELL_SRCS) src/mos_api.inc src/layout.inc src/hub.inc \
		src/version.inc $(B)/config.inc $(B)/core.bin $(ZAP)
	cp src/hub.s src/mos_api.inc src/layout.inc src/hub.inc src/version.inc $(B)/
	rm -rf $(B)/shell && cp -r src/shell $(B)/shell
	cd $(B) && $(ZAP) -c hub.s hub.bin > hub.log || { cat hub.log; exit 1; }

$(B)/test/%.bin: test/progs/%.s src/mos_api.inc src/hub.inc $(ZAP)
	@mkdir -p $(B)/test
	cp $< src/mos_api.inc src/hub.inc $(B)/test/
	cd $(B)/test && $(ZAP) -c $*.s $*.bin > $*.log || { cat $*.log; exit 1; }

# libhub.a: the C glue for include/hub/hub.h, assembled by zap from the one
# source for each toolchain: an ELF archive for agondev, an ACC one for acc.
$(B)/lib/agondev/libhub.a: lib/hub_glue.s src/hub.inc $(ZAP)
	@mkdir -p $(B)/lib/agondev
	cp lib/hub_glue.s src/hub.inc $(B)/lib/agondev/
	cd $(B)/lib/agondev && $(ZAP) hub_glue.s hub_glue.o -f elf > hub_glue.log \
		|| { cat hub_glue.log; exit 1; }
	rm -f $@
	$(AGONDEV)/bin/ez80-none-elf-ar rcs $@ $(B)/lib/agondev/hub_glue.o

$(B)/lib/acc/libhub.a: lib/hub_glue.s src/hub.inc $(ZAP)
	@mkdir -p $(B)/lib/acc
	cp lib/hub_glue.s src/hub.inc $(B)/lib/acc/
	cd $(B)/lib/acc && $(ZAP) hub_glue.s hub_glue.o -f acc > hub_glue.log \
		|| { cat hub_glue.log; exit 1; }
	rm -f $@
	$(ACC) -a $@ $(B)/lib/acc/hub_glue.o > /dev/null

# cclient: a C client, built by agondev's own makefile in a staged tree,
# since agondev takes its sources, headers and libraries from ./src,
# ./include and ./lib.
$(B)/test/cclient.bin: test/c/src/main.c include/hub/hub.h $(B)/lib/agondev/libhub.a
	@mkdir -p $(B)/cclient/src $(B)/cclient/include/hub $(B)/cclient/lib $(B)/test
	cp test/c/src/main.c $(B)/cclient/src/
	cp include/hub/hub.h $(B)/cclient/include/hub/
	cp $(B)/lib/agondev/libhub.a $(B)/cclient/lib/
	PATH=$(AGONDEV)/bin:$$PATH $(MAKE) -s -C $(B)/cclient \
		-f $(AGONDEV)/config/makefile.inc NAME=cclient LIBS=-lhub
	cp $(B)/cclient/bin/cclient.bin $@

# shot: the user-screen client test/screen.sh runs on the full emulator.
$(B)/test/shot.bin: test/shot/src/main.c include/hub/hub.h $(B)/lib/agondev/libhub.a
	@mkdir -p $(B)/shot/src $(B)/shot/include/hub $(B)/shot/lib $(B)/test
	cp test/shot/src/main.c $(B)/shot/src/
	cp include/hub/hub.h $(B)/shot/include/hub/
	cp $(B)/lib/agondev/libhub.a $(B)/shot/lib/
	PATH=$(AGONDEV)/bin:$$PATH $(MAKE) -s -C $(B)/shot \
		-f $(AGONDEV)/config/makefile.inc NAME=shot LIBS=-lhub
	cp $(B)/shot/bin/shot.bin $@

# cclienta: the same client built by acc, under its own name and block.
$(B)/test/cclienta.bin: test/c/src/main.c include/hub/hub.h $(B)/lib/acc/libhub.a
	@mkdir -p $(B)/test
	$(ACC) test/c/src/main.c -DCLIENT_ACC -Iinclude $(B)/lib/acc/libhub.a -o $@ > /dev/null

# The examples, built with agondev against the library as a program outside
# this repository would be, and kept in examples/bin for people to try.
examples/bin/%.bin: examples/src/%.c include/hub/hub.h build/lib/agondev/libhub.a
	@mkdir -p build/ex/$*/src build/ex/$*/include/hub build/ex/$*/lib
	cp $< build/ex/$*/src/
	cp include/hub/hub.h build/ex/$*/include/hub/
	cp build/lib/agondev/libhub.a build/ex/$*/lib/
	PATH=$(AGONDEV)/bin:$$PATH $(MAKE) -s -C build/ex/$* \
		-f $(AGONDEV)/config/makefile.inc NAME=$* LIBS=-lhub
	cp build/ex/$*/bin/$*.bin $@

examples/bin/hubinfo.bin: examples/src/hubinfo.s src/hub.inc $(ZAP)
	@mkdir -p build/ex/hubinfo
	cp examples/src/hubinfo.s src/hub.inc build/ex/hubinfo/
	cd build/ex/hubinfo && $(ZAP) -c hubinfo.s hubinfo.bin > hubinfo.log \
		|| { cat hubinfo.log; exit 1; }
	cp build/ex/hubinfo/hubinfo.bin $@

test: all
	test/run.sh
	test/screen.sh
	test/examples.sh
	test/libs.sh

clean:
	rm -rf build
