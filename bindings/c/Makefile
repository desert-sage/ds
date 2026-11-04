# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# GENERATED. DO NOT EDIT.
#
# The C binding's example, built and run against a libds release
# tarball. DS names the tarball, unpacked:
#
#     make -C bindings/c DS=/path/to/ds-libds-<version>-<os>-<arch>
#     make -C bindings/c DS=... check   # exits 0 on "harness: OK"
#
# It takes include/libds.h, lib/libds.a, lib/libprotobuf-c.a and
# bin/dsc from DS, and the platform libraries PROVENANCE.txt's [link]
# line names. A row that ships no bin/dsc takes DSC=<the same
# release's dsc>. It needs a C99 compiler as CC, a C++ driver as CXX
# (libds.a carries C++ objects), and GNU make.

CFLAGS = -std=c99 -pedantic -Wall -Wextra -Werror -O2

ifeq ($(DS),)
ifneq ($(MAKECMDGOALS),clean)
$(error DS is not set: name an unpacked libds release tarball)
endif
endif

DSC = $(DS)/bin/dsc
LDLIBS = $(wordlist 8,999,$(shell grep '^c++ <your objects>' $(DS)/PROVENANCE.txt))

OUT = build

.PHONY: all check clean
all: $(OUT)/harness $(OUT)/harness.dsc

$(OUT)/harness.o: examples/harness.c $(DS)/include/libds.h
	mkdir -p $(OUT)
	$(CC) $(CFLAGS) -I$(DS)/include -c -o $@ examples/harness.c

$(OUT)/harness: $(OUT)/harness.o $(DS)/lib/libds.a $(DS)/lib/libprotobuf-c.a
	$(CXX) -o $@ $(OUT)/harness.o $(DS)/lib/libds.a $(DS)/lib/libprotobuf-c.a $(LDLIBS)

$(OUT)/harness.dsc: examples/harness.ds
	mkdir -p $(OUT)
	$(DSC) compile examples/harness.ds -o $@

# The harness exits EXIT_SUCCESS only when its run reaches the end and
# prints "harness: OK" (C_STYLE.md C.13).
check: all
	$(OUT)/harness $(OUT)/harness.dsc

clean:
	rm -rf $(OUT)
