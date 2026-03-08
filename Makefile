DEST := $(HOME)/Library/Application Support/Aseprite/extensions/white-block

.PHONY: install

install:
	rm -rf "$(DEST)"
	mkdir -p "$(DEST)"
	ln -s "$(CURDIR)/plugin.lua"   "$(DEST)/plugin.lua"
	ln -s "$(CURDIR)/package.json" "$(DEST)/package.json"
