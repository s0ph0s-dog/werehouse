# Configure here
VERSION := 1.1.1
REDBEAN_VERSION := 3.0.1beta
OUTPUT := werehouse.com
SRV_DIR := srv
LIBS := lib/third_party/fullmoon.lua \
    lib/third_party/htmlparser.lua \
    lib/third_party/htmlparser/ElementNode.lua \
    lib/third_party/htmlparser/voidelements.lua \
    lib/third_party/multipart.lua \
	lib/third_party/telegram_lib.lua \
    lib/db.lua \
	lib/functools.lua \
	lib/fstools.lua \
	lib/giftools.lua \
	lib/scraper_pipeline.lua \
	lib/scraper_types.lua \
    lib/reverse_image_search.lua \
	lib/scrapers/bluesky.lua \
	lib/scrapers/deviantart.lua \
	lib/scrapers/twitter.lua \
	lib/scrapers/cohost.lua \
	lib/scrapers/itakuee.lua \
	lib/scrapers/inkbunny.lua \
	lib/scrapers/mastodon.lua \
	lib/scrapers/furaffinity.lua \
	lib/scrapers/weasyl.lua \
	lib/scrapers/telegram.lua \
	lib/scrapers/e621.lua \
	lib/scrapers/test.lua \
	lib/network_utils.lua \
	lib/tg_bot.lua \
	lib/nanoid.lua \
	lib/web/init.lua
SRCS := src/.init.lua \
    src/manage.lua \
    src/favicon.ico \
    src/icon-180.png \
    src/icon-192.png \
    src/icon-512.png \
    src/icon-192-maskable.png \
    src/icon-512-maskable.png \
    src/icon.svg \
    src/sw.js \
    src/index.js \
    src/htmx@2.0.1.min.js \
    src/manifest.webmanifest \
    src/templates/400.html \
    src/templates/404.html \
    src/templates/500.html \
    src/templates/layouts/main.html \
    src/templates/layouts/dialog.html \
    src/templates/components/artist_verified.html \
    src/templates/components/image_gallery.html \
    src/templates/components/record_view.html \
    src/templates/components/thumbnail.html \
    src/templates/components/pagination_controls.html \
    src/templates/components/queue_records.html \
    src/templates/components/group_box.html \
    src/templates/components/share_widget.html \
    src/templates/accept_invite.html \
    src/templates/link_telegram.html \
    src/templates/login.html \
    src/templates/archive.html \
    src/templates/artist_add.html \
    src/templates/artist_edit.html \
    src/templates/artist.html \
    src/templates/artists.html \
    src/templates/help/index.html \
    src/templates/help/faq.html \
    src/templates/help/getting-started.html \
    src/templates/help/vocab.html \
    src/templates/help/known-issues.html \
    src/templates/help/how-queue-works.html \
    src/templates/help/sharing.html \
    src/templates/help/version-history.html \
    src/templates/image.html \
    src/templates/image_edit.html \
    src/templates/image_share.html \
    src/templates/images.html \
    src/templates/image_groups.html \
    src/templates/image_group.html \
    src/templates/image_group_edit.html \
    src/templates/enqueue.html \
    src/templates/queue.html \
    src/templates/queue_help.html \
    src/templates/query_stats.html \
    src/templates/about.html \
    src/templates/account.html \
    src/templates/share_ping_list.html \
    src/templates/share_ping_list_add.html \
    src/templates/share_ping_list_edit.html \
    src/templates/tags.html \
    src/templates/tag.html \
    src/templates/tag_edit.html \
    src/templates/tag_add.html \
    src/templates/tag_rule_add.html \
    src/templates/tag_rule_changelist.html \
    src/templates/tag_rule_bulk_add.html \
    src/templates/tag_rules.html \
    src/templates/tag_rule.html \
    src/templates/tag_rule_edit.html \
    src/templates/tos.html \
	src/style.css \
	src/templates/home.html \
    src/usr/share/ssl/root/usertrust.pem
TEST_LIBS := lib/third_party/luaunit.lua

# Infrastructure variables here
ABOUT_FILE := $(SRV_DIR)/.lua/about.lua
REDBEAN := redbean-$(REDBEAN_VERSION).com
TEST_REDBEAN := test-$(REDBEAN)
SRCS_OUT := $(patsubst src/%,$(SRV_DIR)/%,$(SRCS))
LIBS_OUT := $(patsubst lib/%,$(SRV_DIR)/.lua/%,$(LIBS))
TEST_LIBS_OUT := $(patsubst lib/%,$(SRV_DIR)/.lua/%,$(TEST_LIBS))
CSSO_PATH := $(shell which csso)

build: $(OUTPUT)

release: build
	cp $(OUTPUT) $(patsubst %.com,%-$(VERSION).com,$(OUTPUT))

# This is below build so that build is still the default target.
include Makefile.secret

clean:
	rm -r $(SRV_DIR) $(TESTS_DIR)
	rm -f $(OUTPUT) $(TEST_REDBEAN)

check: $(TEST_REDBEAN)
	DA_CLIENT_ID=1 DA_CLIENT_SECRET=1 IB_USERNAME=1 IB_PASSWORD=1 ./$< -i test/test.lua

test: check

check-format:
	stylua --check src lib test

format:
	stylua src lib test

.PHONY: build clean check check-format test format release

# Don't delete any of these if make is interrupted
.PRECIOUS: $(SRV_DIR)/. $(SRV_DIR)%/.

# Create directories (and their child directories) automatically.
$(SRV_DIR)/.:
	mkdir -p $@

$(SRV_DIR)%/.:
	mkdir -p $@

$(ABOUT_FILE):
	echo "return { NAME = 'werehouse (github.com/s0ph0s-2/werehouse)', VERSION = '$(VERSION)', REDBEAN_VERSION = '$(REDBEAN_VERSION)' }" > "$@"

$(REDBEAN):
	curl -sSL "https://redbean.dev/$(REDBEAN)" -o "$(REDBEAN)" && chmod +x $(REDBEAN)
	shasum -c redbean.sums

# Via https://ismail.badawi.io/blog/automatic-directory-creation-in-make/
# Expand prerequisite lists twice, with automatic variables (like $(@D)) in
# scope the second time.  This sets up the right dependencies for the automatic
# directory creation rules above. (The $$ is so that the first expansion
# replaces $$ with $ and makes the rule syntactically valid the second time.)
.SECONDEXPANSION:

$(SRV_DIR)/.lua/%.lua: lib/%.lua | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.html: src/%.html | $$(@D)/.
	cp $< $@

$(SRV_DIR)/usr/share/ssl/root/%.pem: src/usr/share/ssl/root/%.pem | $$(@D)/.
	cp $< $@

$(SRV_DIR)/.init.lua: src/.init.lua | $$(@D)/.
	cp $< $@

$(SRV_DIR)/manage.lua: src/manage.lua | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.css: src/%.css | $$(@D)/.
ifeq (,$(CSSO_PATH))
	cp $< $@
else
	csso $< -o $@
endif

$(SRV_DIR)/%.png: src/%.png | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.ico: src/%.ico | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.svg: src/%.svg | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.webmanifest: src/%.webmanifest | $$(@D)/.
	cp $< $@

$(SRV_DIR)/%.js: src/%.js | $$(@D)/.
	cp $< $@

# Remove SRV_DIR from the start of each path, and also don't try to zip Redbean
# into itself.
$(OUTPUT): $(REDBEAN) $(SRCS_OUT) $(LIBS_OUT) $(ABOUT_FILE)
	if [ ! -f "$@" ]; then cp "$(REDBEAN)" "$@"; fi
	cd srv && zip -R "../$@" $(patsubst $(SRV_DIR)/%,%,$(filter-out $<,$?))

$(TEST_REDBEAN): $(REDBEAN) $(SRCS_OUT) $(LIBS_OUT) $(TEST_LIBS_OUT) $(ABOUT_FILE)
	if [ ! -f "$@" ]; then cp "$(REDBEAN)" "$@"; fi
	cd srv && zip -R "../$@" $(patsubst $(SRV_DIR)/%,%,$(filter-out $<,$?))
