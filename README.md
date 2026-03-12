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
./tools/prepare-installer-media.sh
```

When run from a terminal, the host composer now mirrors the old installer UX:

- it prompts for the target type first
- it prompts for the OS artifact first
- `ENTER` accepts the default lane choice
- `c` chooses a different lane
- `l` lists catalog rows
- `r` enters a custom OCI ref
- `o` overrides the upstream repo/catalog
- after OS selection, it prompts for the airgap bundle with the same flow
- then it lists removable USB target media, makes you choose by number, and
  requires `SELECT` before the compose/flash step continues

Passing `--target`, `--os-channel`, or `--airgap-channel` changes the default
choice shown in those prompts. Passing `--os-ref` or `--airgap-ref` skips the
corresponding prompt and uses the exact ref non-interactively.

Useful flags:

- `--target TARGET` to preselect the target type instead of using the interactive target picker
- `--os-channel CHANNEL` to change the default OS lane offered in the host-side prompt
- `--os-ref REF` to choose an explicit OS artifact ref instead of the interactive picker
- `--airgap-channel CHANNEL` to change the default host-selected airgap lane offered in the prompt
- `--airgap-ref REF` to choose an explicit airgap bundle ref instead of the interactive picker or baked default
- `--output-dir DIR` to override the default output location under `./out/<target>`
- `--mission-only` to stop after staging the mission directory and manifest
- `--flash-device /dev/...` to bypass the interactive USB picker and flash that exact device
- `--adapter-repo-root /path/to/img-ourbox-woodbox` when the target repo is not beside this repo, nested inside it, or at `/techofourown/img-ourbox-woodbox`

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
