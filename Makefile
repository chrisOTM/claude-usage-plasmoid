PLASMOID_ID := com.github.chrisotm.claude-usage-plasmoid
INSTALL_DIR := $(HOME)/.local/share/plasma/plasmoids/$(PLASMOID_ID)

install:
	@mkdir -p $(INSTALL_DIR)
	@cp -r contents metadata.json $(INSTALL_DIR)/
	@echo "✅ Installed to $(INSTALL_DIR)"
	@echo "   Restart Plasma: make restart  (or log out / in)"

update: install

remove:
	@rm -rf $(INSTALL_DIR)
	@echo "✅ Removed."

restart:
	@killall plasmashell 2>/dev/null; kstart plasmashell &>/dev/null &
	@echo "🔄 Plasma shell restarted"

test:
	@python3 contents/code/collect.py

.PHONY: install update remove restart test
