# skarwm build.
#
# Required at *runtime*:   libxcb + libxcb-randr + libxcb-shape; the optional
#                          bar additionally uses libX11 + libXft/fontconfig
# Required at *build* time: odin
#
# Configuration uses modular INI-style files, with legacy rc compatibility and
# no embedded interpreter. Targets:
#   make            build skarwm, skarwm-msg, and optional skarwm-bar binaries
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

BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share
SESSIONDIR := $(DATADIR)/xsessions
SYSCONFDIR ?= /etc
SKARWMDIR := $(SYSCONFDIR)/skarwm
SHARESKARWMDIR := $(DATADIR)/skarwm

all: build/skarwm build/skarwm-msg build/skarwm-bar

# release build
build/skarwm: $(ODIN_SRCS)
	@mkdir -p build
	$(ODIN) build src -o:speed -out:$@

build/skarwm-msg: $(shell find cmd/skarwm-msg src/core -name '*.odin')
	@mkdir -p build
	$(ODIN) build cmd/skarwm-msg -o:speed -out:$@

build/skarwm-bar: $(shell find src/bar src/x11 src/core -name '*.odin')
	@mkdir -p build
	$(ODIN) build src/bar -o:speed -out:$@

# debug build (same features, asserts/checks enabled)
build/skarwm-debug: $(ODIN_SRCS)
	@mkdir -p build
	$(ODIN) build src -debug -out:$@

debug: build/skarwm-debug

install: build/skarwm build/skarwm-msg build/skarwm-bar
	install -Dm755 build/skarwm $(DESTDIR)$(BINDIR)/skarwm
	install -Dm755 build/skarwm-msg $(DESTDIR)$(BINDIR)/skarwm-msg
	install -Dm755 build/skarwm-bar $(DESTDIR)$(BINDIR)/skarwm-bar
	install -Dm755 assets/skarwm-session $(DESTDIR)$(BINDIR)/skarwm-session
	install -Dm644 assets/skarwm.desktop $(DESTDIR)$(SESSIONDIR)/skarwm.desktop
	install -Dm644 assets/default.conf $(DESTDIR)$(SKARWMDIR)/default.conf
	install -Dm644 assets/config.d/*.conf -t $(DESTDIR)$(SKARWMDIR)/config.d
	install -Dm644 assets/default.conf $(DESTDIR)$(SHARESKARWMDIR)/default.conf
	install -Dm644 assets/config.d/*.conf -t $(DESTDIR)$(SHARESKARWMDIR)/config.d
	install -Dm644 assets/example.rc $(DESTDIR)$(SKARWMDIR)/config.rc

test: build/skarwm build/skarwm-msg build/skarwm-bar
	odin run tests/config_tests
	odin run tests/core_tests
	bash scripts/itest-config.sh
	scripts/itest.sh
	scripts/itest-randr.sh

xephyr: build/skarwm build/skarwm-msg
	SKARWM_XEPHYR_DISPLAY="$(XEPHYR_DISPLAY)" scripts/xephyr.sh single

xephyr-multi: build/skarwm build/skarwm-msg
	SKARWM_XEPHYR_DISPLAY="$(XEPHYR_DISPLAY)" scripts/xephyr.sh multi

xephyr-anush: build/skarwm build/skarwm-msg
	SKARWM_XEPHYR_DISPLAY="$(XEPHYR_DISPLAY)" scripts/xephyr.sh single -c "$(HOME)/.config/skarwm/default.conf"

itest-decoration: build/skarwm build/skarwm-msg
	bash scripts/itest-decoration.sh

itest-config: build/skarwm build/skarwm-msg
	bash scripts/itest-config.sh

clean:
	rm -rf build

.PHONY: all debug install test xephyr xephyr-multi itest-decoration itest-config clean
