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
#   make install-extra  install the full user desktop into ~/.config/skarwm
#   make clean      remove build/

PREFIX   ?= /usr/local
ODIN     ?= odin
XEPHYR_DISPLAY ?= :2
SKARWM_CONFIG_DIR ?= $(HOME)/.config/skarwm

ODIN_SRCS := $(shell find src -name '*.odin')
EXTRA_CONFIG_FILES := $(shell find \
	extra/dunst extra/kitty extra/picom extra/polybar extra/quickshell \
	extra/rofi extra/wallpaper -type f ! -name '.gitkeep') \
	extra/config.rc extra/bar-height extra/bar-scale extra/pomodoro \
	extra/weather-location extra/weather-units

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
	install -Dm755 extra/skarwm-session $(DESTDIR)$(PREFIX)/bin/skarwm-session
	install -Dm644 extra/skarwm.desktop $(DESTDIR)$(PREFIX)/share/xsessions/skarwm.desktop
	install -Dm644 config/example.rc $(DESTDIR)$(PREFIX)/share/skarwm/config.rc.example

install-extra:
	@set -e; for src in $(EXTRA_CONFIG_FILES); do \
		rel=$${src#extra/}; \
		install -Dm644 "$$src" "$(SKARWM_CONFIG_DIR)/$$rel"; \
	done
	@printf 'Installed skarwm desktop configuration to %s\n' "$(SKARWM_CONFIG_DIR)"

# Short alias, allowing `make extra` after the minimal system install.
extra: install-extra

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

.PHONY: all debug install install-extra extra test xephyr xephyr-multi clean
