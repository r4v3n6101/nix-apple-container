NIX_VERSION       ?= $(shell sed -n 's/^FROM nixos\/nix:\(.*\)/\1/p' builder/Dockerfile)
CONTAINER_VERSION ?= $(shell sed -n 's/.*version = "\(.*\)".*/\1/p' package.nix | head -1)
IMAGE             := ghcr.io/halfwhey/nix-builder

.PHONY: _require_new_version
_require_new_version:
	@[ -n "$(NEW_VERSION)" ] || (printf 'error: NEW_VERSION is not set. Usage: make release NEW_VERSION=vX.Y.Z\n' >&2; exit 1)

.PHONY: release
release: _require_new_version ## Commit VERSION, push, create GitHub release (NEW_VERSION=vX.Y.Z)
	printf '%s\n' "$(NEW_VERSION)" > VERSION
	perl -i -pe 's|nix-apple-container/v[0-9][0-9.]*"|nix-apple-container/$(NEW_VERSION)"|' README.md
	git add VERSION README.md
	git commit -m "$(NEW_VERSION)"
	git tag "$(NEW_VERSION)"
	git push origin master
	git push origin "$(NEW_VERSION)"
	gh release create "$(NEW_VERSION)" --generate-notes

.PHONY: build
build: ## Build the builder image locally (multi-arch)
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(NIX_VERSION) \
		builder/

.PHONY: push
push: ## Build and push the builder image to ghcr.io
	docker buildx build --platform linux/amd64,linux/arm64 \
		-t $(IMAGE):latest -t $(IMAGE):$(NIX_VERSION) \
		--push builder/

.PHONY: ci
ci: ## Trigger the builder CI workflow on GitHub
	gh workflow run build-builder.yml

.PHONY: ci-status
ci-status: ## Show status of the latest CI runs
	gh run list --workflow=build-builder.yml --limit=5

.PHONY: update-container
update-container: ## Check and update apple/container to latest release
	@scripts/update-container.sh

.PHONY: update-kernel
update-kernel: ## Check and update kata-containers kernel to latest release
	@scripts/update-kernel.sh

.PHONY: update-nix-builder
update-nix-builder: ## Check and update nixos/nix base image to latest release
	@scripts/update-nix-builder.sh

.PHONY: bump-linux-builder
bump-linux-builder: ## Bump linuxBuilder default image in default.nix to current NIX_VERSION
	perl -i -pe 's|ghcr.io/halfwhey/nix-builder:[^"]*|ghcr.io/halfwhey/nix-builder:$(NIX_VERSION)|' default.nix
	git add default.nix
	git diff --cached --quiet || git commit -m "chore: bump linuxBuilder default to $(NIX_VERSION)"
	git push origin master

.PHONY: clean
clean: ## Remove local builder images
	docker rmi $(IMAGE):latest $(IMAGE):$(NIX_VERSION) 2>/dev/null || true
