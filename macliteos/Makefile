# MacLiteOS build. Everything is C11 + libc; optional accelerators come from
# out/config.mk (run ./configure first — build.sh does it for you).
CC      ?= gcc
OUT     := out
-include $(OUT)/config.mk

CFLAGS  := -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
           -Icore/include -I. $(ML_EXTRA_CFLAGS) -fno-strict-aliasing
LDLIBS  := $(ML_EXTRA_LIBS) -lm -lpthread -ldl
HEADER_DEPS := $(wildcard core/include/*.h core/include/ml/*.h hardware/*.h compositor/*.h compositor/client/*.h)

CORE_SRC := $(wildcard core/src/*.c)
CORE_OBJ := $(patsubst core/src/%.c,$(OUT)/core/%.o,$(CORE_SRC))
LIB      := $(OUT)/libmica.a
HW_SRC   := $(wildcard hardware/*.c)
HW_OBJ   := $(patsubst hardware/%.c,$(OUT)/hw/%.o,$(HW_SRC))
HWLIB    := $(OUT)/libhw.a
CLIENT_SRC := compositor/client/mica_client.c compositor/client/shellkit.c
CLIENT_OBJ := $(OUT)/client/mica_client.o $(OUT)/client/shellkit.o

BINS := $(OUT)/mica-comp $(OUT)/mica-shell $(OUT)/g1os-splash $(OUT)/g1os-ui-health $(OUT)/g1os-failure-ui
APPS := $(OUT)/mica-finder $(OUT)/mica-terminal $(OUT)/mica-viewer \
        $(OUT)/mica-settings $(OUT)/mica-sysinfo $(OUT)/mica-textedit \
        $(OUT)/mica-player $(OUT)/mica-music $(OUT)/mica-pdf \
        $(OUT)/maclite-browser $(OUT)/maclite-video $(OUT)/mica-installer
TOOLS := $(OUT)/maclite-memory $(OUT)/maclite-performance $(OUT)/maclite-ui-benchmark \
         $(OUT)/maclite-diagnostics $(OUT)/maclite-gpu $(OUT)/maclite-gpu-benchmark \
         $(OUT)/maclite-display $(OUT)/maclite-brightness $(OUT)/maclite-audio \
         $(OUT)/maclite-video-test $(OUT)/maclite-network $(OUT)/maclite-usb \
         $(OUT)/maclite-storage $(OUT)/maclite-power $(OUT)/maclite-hardware \
         $(OUT)/maclite-cpu $(OUT)/maclite-drivers $(OUT)/maclite-fan
TESTS := $(OUT)/test_render $(OUT)/test_units $(OUT)/test_idle $(OUT)/test_leak \
         $(OUT)/test_hardware $(OUT)/test_installer $(OUT)/test_cursor_damage \
         $(OUT)/test_cursor_render

$(BINS) $(APPS) $(TOOLS) $(TESTS): $(HEADER_DEPS)

.PHONY: all build test iso core hw bins apps tools tests clean
build: all
test: all
	sh scripts/run-tests.sh
iso:
	sh scripts/build.sh
all: core hw bins apps tools tests
core: $(LIB)
$(LIB): $(CORE_OBJ)
	@mkdir -p $(dir $@)
	ar rcs $@ $^
hw: $(HWLIB)
$(HWLIB): $(HW_OBJ)
	@mkdir -p $(dir $@)
	ar rcs $@ $^
$(OUT)/core/%.o: core/src/%.c $(HEADER_DEPS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/hw/%.o: hardware/%.c $(HEADER_DEPS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/client/%.o: compositor/client/%.c $(HEADER_DEPS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@
$(OUT)/mica-comp: compositor/comp.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/g1os-splash: boot/g1os-splash.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/g1os-ui-health: boot/g1os-ui-health.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/g1os-failure-ui: boot/g1os-failure-ui.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)
$(OUT)/mica-shell: desktop/mica-shell.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-finder: finder/mica-finder.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-terminal: applications/mica-terminal.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-viewer: applications/mica-viewer.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-settings: settings/mica-settings.c $(CLIENT_OBJ) $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-sysinfo: settings/mica-sysinfo.c $(CLIENT_OBJ) $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-textedit: applications/mica-textedit.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-player: multimedia/mica-player.c $(CLIENT_OBJ) $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-music: multimedia/mica-music.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-pdf: applications/mica-pdf.c $(CLIENT_OBJ) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-browser: applications/maclite-browser.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-video: multimedia/maclite-video.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/mica-installer: installer/mica-installer.c $(CLIENT_OBJ) $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-memory: performance/maclite-memory.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-performance: performance/maclite-performance.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-ui-benchmark: performance/maclite-ui-benchmark.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-diagnostics: performance/maclite-diagnostics.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-gpu: diagnostics/maclite-gpu.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-gpu-benchmark: diagnostics/maclite-gpu-benchmark.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-display: diagnostics/maclite-display.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-brightness: diagnostics/maclite-brightness.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-audio: diagnostics/maclite-audio.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-video-test: diagnostics/maclite-video-test.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-network: diagnostics/maclite-network.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-usb: diagnostics/maclite-usb.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-storage: diagnostics/maclite-storage.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-power: diagnostics/maclite-power.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-hardware: diagnostics/maclite-hardware.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-cpu: diagnostics/maclite-cpu.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-drivers: diagnostics/maclite-drivers.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/maclite-fan: diagnostics/maclite-fan.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_render: tests/test_render.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_units: tests/test_units.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_idle: tests/test_idle.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_leak: tests/test_leak.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_hardware: tests/test_hardware.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_installer: tests/test_installer.c $(HWLIB) $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_cursor_damage: tests/test_cursor_damage.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
$(OUT)/test_cursor_render: tests/test_cursor_render.c $(LIB)
	$(CC) $(CFLAGS) $(filter-out $(HEADER_DEPS),$^) -o $@ $(LDLIBS)
bins: $(BINS)
apps: $(APPS)
tools: $(TOOLS)
tests: $(TESTS)
clean:
	rm -rf $(OUT)
