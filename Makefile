# Build the Rocky 10 bootc base image.
#
# This is THE build. CI runs `make build verify` once per arch (see
# .github/workflows/build.yml) and only adds the parts that need GitHub:
# shipping the images between runners, assembling the multi-arch manifest,
# and signing. If you change how the image is built or checked, change it
# here and CI follows.
#
#   make build     # compose the rootfs, build the image, chunk its layers
#   make verify    # run the same checks CI runs before publishing
#   make shell     # poke around inside the result
#
# Requirements: podman. Rootless is the default and works on hosts that allow
# nested user namespaces (Fedora does). The compose wants mounts and
# namespaces some hosts refuse to unprivileged users -- Ubuntu 24.04's
# AppArmor policy, for one -- and fails there with "bwrap: Creating new
# namespace failed". On such a host, run it as root:
#   make build PODMAN="sudo podman"
# CI does exactly that, because GitHub's runners are Ubuntu.

# All of these can also come from the environment, which is how CI sets them.
PODMAN ?= podman
MAJOR  ?= 10
IMAGE  ?= localhost/rocky-bootc
TAG    ?= $(MAJOR)-minimal
# amd64 or arm64. Only `verify` uses it, to also assert the kernel's arch.
ARCH   ?=
# A published image whose layer plan `rechunk` should reuse -- normally
# yesterday's build of this same tag. Best-effort: see the rechunk target.
PREVIOUS ?=
# Set to 0 to stop `build` from chunking. The result still boots; it just
# ships as one layer, so every upgrade re-pulls the whole image.
RECHUNK ?= 1

REF := $(IMAGE):$(TAG)

# The toolchain image whose bootc-base-imagectl assembles the rootfs. Nothing
# of it survives into the output -- see 10/minimal/Containerfile.
BUILDER ?= quay.io/centos-bootc/centos-bootc:stream$(MAJOR)

# bootc-base-imagectl assembles the rootfs with mounts and loopback devices,
# which an unprivileged build cannot do.
COMPOSE_FLAGS := --cap-add=SYS_ADMIN,NET_ADMIN \
                 --device /dev/fuse \
                 --security-opt seccomp=unconfined \
                 --security-opt label=disable

.PHONY: all build rechunk verify shell pull clean help

all: build

help:
	@echo "Targets:"
	@echo "  build   Build $(REF) from $(MAJOR)/minimal/, then chunk it (default)"
	@echo "  rechunk Split $(REF) into per-package layers (part of build)"
	@echo "  verify  Run the pre-publish checks against $(REF)"
	@echo "  shell   Interactive shell inside $(REF)"
	@echo "  pull    Re-pull the builder toolchain"
	@echo "  clean   Remove the local image"
	@echo ""
	@echo "Variables:"
	@echo "  MAJOR    Rocky major version / source directory (default: $(MAJOR))"
	@echo "  IMAGE    image name (default: $(IMAGE))"
	@echo "  TAG      image tag (default: $(TAG))"
	@echo "  ARCH     amd64 or arm64; adds an arch check to verify (default: none)"
	@echo "  PODMAN   podman invocation (default: $(PODMAN))"
	@echo "  BUILDER  builder toolchain image (default: $(BUILDER))"
	@echo "  PREVIOUS published ref whose layer plan rechunk reuses (default: none)"
	@echo "  RECHUNK  0 to skip chunking in build (default: 1)"

# Re-pull each time: a stale toolchain silently pins the compose to old
# behaviour, which is confusing to debug.
pull:
	$(PODMAN) pull $(BUILDER)

build: pull
	$(PODMAN) build $(COMPOSE_FLAGS) -t $(REF) $(MAJOR)/minimal/
	@if [ "$(RECHUNK)" != "0" ]; then $(MAKE) --no-print-directory rechunk; fi
	@echo "==> Built $(REF). Check it with: make verify"

# `FROM scratch` + one COPY is a single layer holding the whole OS, so every
# daily rebuild makes everyone re-pull all of it. This splits it into up to 64
# content-addressed layers grouped by package, so `bootc upgrade` fetches only
# the chunks that actually changed. The daily rebuild is this repo's whole
# point; this is what keeps it cheap for the people following the tag.
#
# `bootc-base-imagectl rechunk` wraps this same rpm-ostree command, but does
# not expose --previous-build. Without that, the packer re-balances chunks from
# scratch on every run and files migrate between layers for reasons unrelated
# to any package changing -- churn that costs bandwidth and buys nothing. So
# this calls rpm-ostree directly.
#
# PREVIOUS is best-effort on purpose: the first build has nothing to compare
# against, and a fork has nothing published at all. Both must still work. The
# probe runs skopeo from the toolchain image rather than the host, so it needs
# nothing installed and, more to the point, resolves the ref under exactly the
# credentials rpm-ostree will have when it fetches the layer plan for real.
#
# The container reads and writes the host's image store, so every path the
# store records has to mean the same thing on both sides: it gets mounted at
# its own host path, with a storage.conf naming that path, rather than at the
# container's default. (Mounting it elsewhere leaves podman reading a db.sql
# that records the host path and refusing with "database configuration
# mismatch".) /home in a bootc image is a symlink to the empty /var/home, so
# a rootless store under $$HOME has nowhere to mount until /var/home exists;
# the tmpfs gives it one and is inert when the store is /var/lib/containers.
rechunk:
	@set -eu; \
	prev=""; \
	if [ -n "$(PREVIOUS)" ]; then \
	    if $(PODMAN) run --rm $(BUILDER) skopeo inspect --raw "$(PREVIOUS)" >/dev/null 2>&1; then \
	        echo "==> rechunk: reusing the layer plan from $(PREVIOUS)"; \
	        prev="--previous-build=$(PREVIOUS)"; \
	    else \
	        echo "==> rechunk: $(PREVIOUS) not readable; packing from scratch"; \
	    fi; \
	fi; \
	storage="$$($(PODMAN) info --format '{{.Store.GraphRoot}}')"; \
	driver="$$($(PODMAN) info --format '{{.Store.GraphDriverName}}')"; \
	conf="$$(mktemp -d)/storage.conf"; \
	printf '[storage]\ndriver = "%s"\ngraphroot = "%s"\nrunroot = "/run/containers/storage"\n' \
	    "$$driver" "$$storage" > "$$conf"; \
	$(PODMAN) run --rm --privileged --security-opt label=disable \
	    --tmpfs /var/home \
	    -v "$$storage:$$storage" \
	    -v "$$conf:/etc/containers/storage.conf:ro" \
	    $(BUILDER) \
	    rpm-ostree experimental compose build-chunked-oci \
	        --bootc --format-version=1 $$prev \
	        --from=$(REF) --output=containers-storage:$(REF)-rechunked; \
	rm -rf "$$(dirname "$$conf")"; \
	$(PODMAN) tag $(REF)-rechunked $(REF); \
	$(PODMAN) rmi $(REF)-rechunked
	@echo "==> Chunked $(REF) into $$($(PODMAN) inspect -f '{{len .RootFS.Layers}}' $(REF)) layers"

# The pre-publish checks. With ARCH set, also asserts the kernel's arch.
verify:
	PODMAN="$(PODMAN)" ./verify.sh $(REF) $(MAJOR) minimal $(ARCH)

shell:
	$(PODMAN) run --rm -it $(REF) /bin/bash

clean:
	-$(PODMAN) rmi $(REF)
