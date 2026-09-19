# rocky-bootc

A Rocky Linux 10 bootc base image, built from Rocky's own repos, rebuilt
daily, signed, and published as a multi-arch manifest.

```sh
podman pull ghcr.io/schmidtw/rocky-bootc:10-minimal
```

> [!NOTE]
> This is a community build, not a Rocky Linux project. Every package in the
> image comes from Rocky's repos, and every published digest is signed; the
> [Trust](#trust) section shows how to verify both.

## Why this exists

Rocky publishes no bootc base image. As of this writing `quay.io/rockylinux`
carries three repositories — `rockylinux`, `rockylinux-shim`, `rocky-toolbox` —
and none of them are bootable. CIQ ships bootc images for Rocky, but behind a
commercial entitlement. The community builds that do exist go stale: the most
visible one was last rebuilt in March 2026.

This repo fills that gap: a base composed from Rocky's own repos, rebuilt every
day so the kernel and packages stay current, and published for anyone who wants
to run Rocky in image mode without maintaining the compose themselves.

Alternatively, you can use this repo as a starting point for your own bootc base
image. `minimal` is a small, self-contained compose that can be layered on to
add whatever packages you need.

## How it works

bootc ships its own base-image tool, `bootc-base-imagectl`, inside every bootc
image. It assembles a bootable rootfs from whatever RPM repos are configured.
So the `minimal` build uses the **CentOS Stream 10 bootc image purely as a
builder toolchain**, replaces its repo config with Rocky 10's, composes a
rootfs, and copies that into a `FROM scratch` image.

Nothing of CentOS survives into the output. Every package comes from
`mirrors.rockylinux.org`, and CI asserts `ID=rocky` before it publishes.

Everything that decides what the image is lives in [`10/minimal/`](10/minimal/):

| File | What it controls |
|---|---|
| `Containerfile` | The two-stage build |
| `rocky10.repo` | Which repos the rootfs is composed from (builder input; nothing of it ships) |
| `manifest.yaml` | Which packages end up in it, and which files |
| `20-rocky.toml` | The one file: XFS as the default disk filesystem |

A `FROM scratch` image is a single layer holding the whole OS, which would
make every daily rebuild a full re-download for anyone following the tag. So
the last build step splits it into per-package layers, the same way Fedora,
CentOS and AlmaLinux split theirs. An upgrade then pulls the packages that
changed rather than all 350-odd MB. The build also pins the layout to the
currently published image, so layers move when packages do and not because
the packer rearranged itself overnight.

One workflow, [`build.yml`](.github/workflows/build.yml), runs the Makefile
on an amd64 and an arm64 runner, verifies each result, and one publish job
pushes and signs the multi-arch manifest. Either both arches publish or
neither does.

## What's in it

The upstream `minimal` manifest — bootc, systemd, kernel, dnf, the SELinux
targeted policy — plus four small things. No network management, no ssh, no
cloud-init. Every entry in [`manifest.yaml`](10/minimal/manifest.yaml) says
why it's there; the short version:

- `bubblewrap` and an XFS default are what
  [bootc-image-builder](https://github.com/osbuild/bootc-image-builder) needs
  to turn the image into a disk.
- Upstream's growfs unit, so that root grows to fill the disk on first boot.
  It only fires in a VM and only if `/usr/bin/growpart` exists, so it is inert
  until you layer `cloud-utils-growpart`.
- A persistent journal, because journald's default silently keeps logs in
  memory on a fresh `/var`, and a dead machine with no logs is undebuggable.
  One drop-in overrides it if you want volatile.

One image, on purpose. A base is easy to add a variant to and nearly
impossible to take one away from, so this repo publishes the one thing nobody
else does and leaves the opinions to your layer. The next section covers the
parts of that layer that are not obvious.

## Using it

```dockerfile
FROM ghcr.io/schmidtw/rocky-bootc:10-minimal

RUN dnf -y --setopt=install_weak_deps=False install your-thing \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/log/dnf* /var/log/hawkey.log

RUN bootc container lint
```

Then `bootc switch` to your image, or feed it to
[bootc-image-builder](https://github.com/osbuild/bootc-image-builder) for a
qcow2/ISO/raw disk.

Three things about layering on this image are not obvious, and each one fails
quietly if you miss it:

- **Weak dependencies are off in the base; keep them off.** The compose runs
  with `recommends: false`. A plain `dnf install` turns them back on for
  your layer, and the image grows by whatever every package merely
  recommends. Hence the `install_weak_deps=False` above.

- **Packages that own directories under `/var` need tmpfiles entries.**
  `/var` is machine state, not image content, so a directory an RPM creates
  there at build time does not exist on the booted system unless a
  `tmpfiles.d` entry recreates it. The compose generates those for the base;
  `dnf` in a layer does not. `bootc container lint` warns about every one it
  finds. This generates them from RPM metadata for the packages your layer
  added:

  ```dockerfile
  RUN rpm -qa --qf '%{NAME}\n' | sort > /tmp/base-packages \
      && dnf -y --setopt=install_weak_deps=False install your-thing \
      && dnf clean all \
      && rm -rf /var/cache/dnf /var/cache/ldconfig /var/lib/dnf /var/log/dnf* /var/log/hawkey.log

  RUN set -euo pipefail; \
      known="$(cat /usr/lib/tmpfiles.d/*.conf | awk '$1 !~ /^#/ && NF >= 2 { print $2 }')"; \
      rpm -qa --qf '%{NAME}\n' | sort | comm -13 /tmp/base-packages - \
        | xargs rpm -q --dump \
        | awk -v known="$known" ' \
            BEGIN { n = split(known, a, "\n"); for (i = 1; i <= n; i++) k[a[i]] = 1 } \
            $1 ~ /^\/var\// && $5 ~ /^04/ && !($1 in k) { \
                printf "d %s %s %s %s - -\n", $1, substr($5, length($5) - 3), $6, $7 }' \
        | sort > /usr/lib/tmpfiles.d/my-layer-var.conf; \
      rm /tmp/base-packages
  ```

- **A cloud guest needs two more things than `cloud-init`.** If you are
  making the equivalent of Rocky's GenericCloud image:
  - `cloud-utils-growpart`, or the root filesystem never grows to fill the
    disk. The growfs unit is already in the image, waiting for it.
  - Rocky's identity. The stock `cloud-init` RPM ships the generic upstream
    default (`distro: rhel`, `default_user: cloud-user`); Rocky's own images
    override that in a kickstart a container build never runs. A drop-in in
    `/etc/cloud/cloud.cfg.d/` restores the first-boot user every other Rocky
    image gives you:

    ```yaml
    system_info:
      distro: rocky
      default_user:
        name: rocky
        gecos: rocky Cloud User
        groups: [adm, systemd-journal]
        sudo: ["ALL=(ALL) NOPASSWD:ALL"]
        shell: /bin/bash
    ```

### Tags

| Tag | Use it when |
|---|---|
| `10-minimal` | You want current. Moves with every publish. |
| `10-minimal-YYYYMMDD` | You want a given day's build. |

Both are multi-arch manifests covering `linux/amd64` and `linux/arm64`.

If you need an input that never moves, pin the digest. The datestamped tag
identifies a day, and a second publish on the same day overwrites it; the
digest is also the only thing the signature is bound to.

## Trust

**Signed.** Every published digest is signed with cosign keyless, bound to this
repo's workflow identity. Verify before you trust it:

```sh
cosign verify ghcr.io/schmidtw/rocky-bootc:10-minimal \
  --certificate-identity-regexp '^https://github\.com/schmidtw/rocky-bootc/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

**Reproducible-ish, not reproducible.** The build pulls current packages from
Rocky's mirrors, so two builds on different days differ. That's the point — but
it does mean you can't bit-for-bit reproduce an old image. Pin a digest if
you need a fixed input.

**Rebuilt daily.** A base image nobody rebuilds is worse than none, because
people `FROM` it and ship stale kernels without noticing. The daily schedule
is the core commitment of this repo.

**Forkable.** The entire build is a handful of files, and the Makefile and
workflow run unchanged in a fork. If your policy requires building your own
base, this repo is a working starting point rather than a dependency.

## Building it yourself

```sh
make build     # compose the rootfs, build the image, split its layers
make verify    # the pre-publish checks
make shell     # poke around inside the result
```

CI runs these same targets on each arch. The workflow only adds what needs
GitHub: one runner per arch, moving the images between runners, the
multi-arch manifest, and the signature. So what you build locally is what
gets published.

Rootless podman is the default and works where the host allows nested user
namespaces, Fedora included. Hosts that restrict them, Ubuntu 24.04 among
them, fail the compose with `bwrap: Creating new namespace failed`; there,
run it as root with `make build PODMAN="sudo podman"`, which is what CI does
on GitHub's Ubuntu runners. `make help` lists the knobs.

## Prior art

- [`AlmaLinux/bootc-images`](https://github.com/AlmaLinux/bootc-images) — the
  closest relative: AlmaLinux's own (experimental) bootc base, built the same
  way, with the CentOS Stream bootc image as the toolchain and a `FROM
  scratch` result. What this repo would look like if Rocky did it. Theirs is
  the `standard` compose and carries the firmware packages, so it is well
  over twice the size; `minimal` here is the smaller thing.
- [`git.resf.org/sig_containers/rocky-bootc`](https://git.resf.org/sig_containers/rocky-bootc)
  — the Rocky SIG/Containers build system this approach follows.
- [`antonym/bootc-rocky`](https://github.com/antonym/bootc-rocky) — an earlier
  community build.
- [Fedora's bootc base images](https://gitlab.com/fedora/bootc/base-images) —
  where the `bootc-base-imagectl` machinery comes from.

If Rocky publishes an official bootc base, prefer it. This repo exists to
cover the gap until then.

## License

MIT — see [LICENSE](LICENSE). Covers the build files in this repo. The packages
in the resulting image are Rocky Linux's, under their own respective licenses.
