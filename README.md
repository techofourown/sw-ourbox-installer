# OurBox Installer

`sw-ourbox-installer` is the host-side front door for composing OurBox mission
media.

Phase-one scope is intentionally narrow:

- target support: `woodbox` only
- host-side selection: choose an exact Woodbox OS artifact on the host
- host-side airgap selection: stage either the baked airgap bundle from the
  chosen OS payload or an explicit contract-matching host-selected bundle
- mission output: write a `mission-manifest.json` plus staged OS and airgap
  artifact bytes/metadata
- media compose: delegate to a vendored Woodbox media adapter snapshot while
  using the checked-out `img-ourbox-woodbox` repo as the substrate build source

What phase one does not do yet:

- Matchbox or Tinderbox support
- published-substrate composition without a checked-out target repo
- target-independent substrate composition

The immediate win is narrower but real: the host now resolves the Woodbox OS
artifact and selected airgap bundle up front, stages both into a mission
directory, and invokes a vendored target adapter to compose installer media that
installs from local mission bytes.

For Woodbox specifically, phase one already includes the purge of target-side
artifact browsing and pulling from the supported install path. The remaining
later-phase cleanup applies to other targets, especially Matchbox.

## Usage

From a workspace that also contains `img-ourbox-woodbox`:

```bash
./tools/prepare-installer-media.sh \
  --target woodbox \
  --os-channel stable \
  --airgap-channel stable \
  --output-dir ./out/woodbox
```

Useful flags:

- `--os-ref REF` to choose an explicit OS artifact ref instead of catalog-first channel resolution
- `--airgap-ref REF` to choose an explicit airgap bundle ref instead of the baked bundle or channel resolution
- `--airgap-channel CHANNEL` to choose a host-selected contract-matching airgap bundle instead of the baked bundle
- `--mission-only` to stop after staging the mission directory and manifest
- `--flash-device /dev/...` to pass the composed ISO to the Woodbox adapter for flashing
- `--adapter-repo-root /path/to/img-ourbox-woodbox` when the target repo is not in the default workspace location

Cache behavior:

- the tool keeps a host-side cache of pulled artifacts
- when matching cached assets are available, it asks whether to reuse them
- at the end of compose, it offers to clear cached assets to reclaim disk space

## Repository contract

- `schemas/mission-manifest.schema.json`
  - schema for the staged mission manifest
- `tools/cache.sh`
  - host-side OCI cache plumbing
- `tools/vendor-adapter.sh`
  - copies target adapter surfaces into `vendor/`
- `vendor/woodbox/`
  - pinned snapshot of the Woodbox adapter surface used for phase-one execution

Phase one uses the vendored adapter scripts as the execution surface and points
them at the checked-out target repo only for substrate-specific build inputs and
tooling.
