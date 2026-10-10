VERSION ?= 1.3.0-dev
PREFIX = /usr/local
LIB_DIR = $(PREFIX)/share/aur-taw/lib
DOCKER_IMAGE ?= aur-dev

install:
	install -Dm755 aur-taw $(DESTDIR)$(PREFIX)/bin/aur-taw
	install -Dm644 aur-taw-completion.bash $(DESTDIR)/usr/share/bash-completion/completions/aur-taw
	
	install -d $(DESTDIR)$(LIB_DIR)
	install -Dm644 lib/*.bash $(DESTDIR)$(LIB_DIR)/
	
	sed -i 's/^VERSION=.*/VERSION="$(VERSION)"/' $(DESTDIR)$(PREFIX)/bin/aur-taw

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/aur-taw
	rm -f $(DESTDIR)/usr/share/bash-completion/completions/aur-taw
	rm -rf $(DESTDIR)$(LIB_DIR)

test:
	bash tests/run.bash

test-docker:
	docker run --rm --network none -e AUR_TAW_ARCH_INTEGRATION=1 -v "$(CURDIR):/src:ro" -w /src --entrypoint /bin/bash "$(DOCKER_IMAGE)" tests/run.bash

.PHONY: install uninstall test test-docker
