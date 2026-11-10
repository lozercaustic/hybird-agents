ZIG ?= mise exec zig@0.17.1 -- zig
build:
	$(ZIG) build --release=small && strip -x zig-out/bin/hy
install: build
	cp zig-out/bin/hy ~/.local/bin/hy.new && mv -f ~/.local/bin/hy.new ~/.local/bin/hy
	mkdir -p ~/.local/lib ~/.local/share/hy
	cp zig-out/lib/libhy.dylib ~/.local/lib/libhy.dylib.new && mv -f ~/.local/lib/libhy.dylib.new ~/.local/lib/libhy.dylib
	cp ui/hy_ui.py ui/hy_live.py ~/.local/share/hy/
test: install
	./tests/smoke.sh
