# skarwm build.
#
# Required at *runtime*:   libxcb + libxcb-randr
# Required at *build* time: odin
#
# Configuration is a plain-text rc file — there is no embedded
# interpreter, so the only runtime dependency is libxcb. Targets:
#   make            build a release binary into build/skarwm
#   make debug      build an assertion-enabled binary into build/skarwm-debug
#   make test       run the unit suite (tests/core_tests) then the X11
#                   integration tests
#   make xephyr     run interactively in a nested X server
#   make xephyr-multi  run with two nested RandR monitor objects
#   make install    install the minimal WM, IPC client, and session files
#   make clean      remove build/

PREFIX   ?= /usr/local
ODIN     ?= odin
XEPHYR_DISPLAY ?= :2

ODIN_SRCS := $(shell find src -name '*.odin')

all: build/skarwm build/skarwm-msg

# release build
build/skarwm: $(ODIN_SRCS)
	@mkdir -p build
	$(ODIN) build src -o:speed -out:$@

build/skarwm-msg: $(shell find cmd/skarwm-msg src/core -name '*.odin')
	@mkdir -p build
	$(ODIN) build cmd/skarwm-msg -o:speed -out:$@

# debug build (same features, asserts/checks enabled)
build/skarwm-debug: $(ODIN_SRCS)
	@mkdir -p build
	$(ODIN) build src -debug -out:$@

debug: build/skarwm-debug

install: build/skarwm build/skarwm-msg
	install -Dm755 build/skarwm $(DESTDIR)$(PREFIX)/bin/skarwm
	install -Dm755 build/skarwm-msg $(DESTDIR)$(PREFIX)/bin/skarwm-msg
	install -Dm755 config/skarwm-session $(DESTDIR)$(PREFIX)/bin/skarwm-session
	install -Dm644 config/skarwm.desktop $(DESTDIR)$(PREFIX)/share/xsessions/skarwm.desktop
	install -Dm644 config/example.rc $(DESTDIR)$(PREFIX)/share/skarwm/config.rc.example

test: build/skarwm build/skarwm-msg
	odin run tests/core_tests
	scripts/itest.sh
	scripts/itest-randr.sh

xephyr: build/skarwm build/skarwm-msg
	SKARWM_XEPHYR_DISPLAY="$(XEPHYR_DISPLAY)" scripts/xephyr.sh single

xephyr-multi: build/skarwm build/skarwm-msg
	SKARWM_XEPHYR_DISPLAY="$(XEPHYR_DISPLAY)" scripts/xephyr.sh multi

clean:
	rm -rf build

.PHONY: all debug install test xephyr xephyr-multi clean
