OS := $(shell uname -s)

ifeq ($(OS), Darwin)
    # macOS 26+ (Tahoe) requires target=aarch64-macos-none to work with Zig 0.14
    TARGET_FLAGS := -target aarch64-macos-none
else
    TARGET_FLAGS :=
endif

.PHONY: all clean run

all: phterm

phterm: src/main.zig src/terminal.zig src/pty.zig src/vt.zig src/panel.zig src/renderer.zig src/input.zig
	zig build-exe src/main.zig -lc $(TARGET_FLAGS) --name phterm -O ReleaseSafe

debug: src/main.zig src/terminal.zig src/pty.zig src/vt.zig src/panel.zig src/renderer.zig src/input.zig
	zig build-exe src/main.zig -lc $(TARGET_FLAGS) --name phterm

run: phterm
	./phterm

clean:
	rm -f phterm phterm.o
	rm -rf .zig-cache zig-out
