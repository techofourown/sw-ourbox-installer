# OurBox Installer

`sw-ourbox-installer` is the host-side front door for composing OurBox mission
media.

Current scope:

- target support: `woodbox` and `matchbox`
- host-side selection: choose an exact target OS artifact on the host
- host-side application selection:
  - Woodbox: choose one or more application catalogs, merge them into one
    effective catalog, and select the desired app set
  - Matchbox: choose one published arm64 application bundle bounded by the
    selected OS payload's platform-contract digest
- mission output: write a `mission-manifest.json` plus staged OS bytes,
  staged application bytes, and selected metadata
- media compose: delegate to a vendored target adapter snapshot while pulling
  the published target installer substrate artifact automatically

What this repo still does not do yet:

- Tinderbox support
- target-independent substrate composition

The immediate win is no longer Woodbox-only. The host now resolves the selected
target OS artifact, the selected application input for that target, and the
published target installer substrate up front, stages the mission directory,
and invokes a vendored target adapter to compose installer media that installs
from local mission bytes.

For both Woodbox and Matchbox, the supported install path now purges
target-side artifact browsing and pulling. The target installer consumes only
the embedded local mission bytes.

## Usage

From a normal checkout of `sw-ourbox-installer`:

```bash
git clone --recurse-submodules https://github.com/techofourown/sw-ourbox-installer.git
cd sw-ourbox-installer
./tools/prepare-installer-media.sh
# move the installer media to the target machine, boot it, follow the prompts,
# let it power off, remove the installer media, then boot the installed system disk
```

When run from a terminal, the host composer now mirrors the old installer UX:

- it prompts for the target type first
- it prompts for the OS artifact first
- the default OS path must resolve through the upstream OS catalog; if that
  catalog is unavailable or malformed, the run fails fast
- `ENTER` accepts the default lane choice
- `c` chooses a different lane
- `l` lists catalog rows newest-first with `n`/`p` page navigation
- `r` enters a custom OCI ref
- `o` overrides the upstream repo/catalog
- after OS selection, it prompts for one or more application catalogs
- for official Woodbox catalogs, the default catalog ids must come from
  upstream `sw-ourbox-os` install-defaults data
- if that upstream defaults artifact is missing or malformed, the installer
  fails fast instead of falling back to adapter-local default policy
- official Woodbox catalog ids resolve through each catalog repo's published
  `catalog.tsv`, so the installer picks a contract-compatible pinned bundle
  instead of trusting floating bundle tags
- if an upstream catalog cannot be fetched or does not expose a compatible
  row, the official default path fails fast instead of degrading to mutable
  non-catalog tags
- if the selected catalogs provide the same app uid from multiple catalogs, it
  only stops when the duplicated app definitions differ; identical duplicates
  are deduped automatically
- after duplicate app sources are resolved, it merges the catalogs into one
  effective catalog and prompts for the applications:
  - `ENTER` uses the merged default app set
  - `a` installs all apps from the merged catalog
  - `c` chooses a custom app set by number
- after application selection, it asks whether you want to stage installed-target
  SSH access at all:
  - `ENTER` or `n` continues without any installed-target SSH key
  - `y` opens the named-key chooser
  - in the named-key chooser, pick an existing named key to reuse it across
    installs and target families
  - `n` creates a new named key
  - `d` deletes one named key
  - `x` deletes all named keys
- then it lists removable USB target media, makes you choose by number, and
  requires `SELECT` before the compose/flash step continues
- the normal no-flag path flashes removable media; it does not keep extra build
  artifacts by default

Passing `--target`, `--os-channel`, or `--airgap-channel` changes the default
choice shown in those prompts. Passing `--os-ref` or `--airgap-ref` skips the
corresponding prompt and uses the exact ref non-interactively. Passing
`--all-apps` or `--app-ids` skips the interactive application chooser.

Useful flags:

- `--target TARGET` to preselect the target type instead of using the interactive target picker
- `--os-channel CHANNEL` to change the default OS lane offered in the host-side prompt
- `--os-ref REF` to choose an explicit OS artifact ref instead of the interactive picker
- `--airgap-channel CHANNEL[,CHANNEL...]` to preselect one or more application catalog ids in the prompt flow
- `--airgap-ref REF[,REF...]` to choose one or more explicit application catalog refs instead of the interactive picker; a ref may point at an exact bundle or at a catalog index such as `ghcr.io/example/catalog:catalog-amd64`, which will be resolved to the newest contract-compatible pinned bundle
- `--all-apps` to install every app published by the merged catalog set
- `--app-ids ID[,ID...]` to install an explicit subset of apps from the merged catalog set
- `--app-source-resolutions APP_UID=CATALOG_ID[,APP_UID=CATALOG_ID...]` to resolve duplicate app sources non-interactively
- `--installed-target-ssh-key-name NAME` to reuse or create a named host-side SSH key and stage its public key for the installed target
- `--mission-only` to stage only the mission directory under `./out/<target>` (or `--output-dir`)
- `--compose-only` to compose installer media to disk under `./out/<target>` (or `--output-dir`) without flashing
- `--output-dir DIR` to keep staged mission or composed media in a specific directory for those explicit non-default modes
- `--flash-device /dev/...` to bypass the interactive USB picker and flash that exact device
- `--help` to print the optional CI/dev flags without changing the normal no-flag operator flow

Cache behavior:

- the tool keeps a host-side cache of pulled artifacts
- when matching cached assets are available, it asks whether to reuse them
- at the end of compose, it offers to clear cached assets to reclaim disk space

Installed-target SSH behavior:

- host-side installed-target SSH staging is optional
- if you skip it, compose still continues and the mission carries no staged
  installed-target SSH key
- named host-side SSH keys are stored in `${XDG_STATE_HOME:-$HOME/.local/state}/ourbox/installed-target-ssh-keys` by default
- the staged mission carries only the selected public key, never the private key
- the installed target can use that staged host key for key-based SSH
- password-based installed-target SSH remains a separate target-side prompt during installation

## Repository contract

- `schemas/mission-manifest.schema.json`
  - JSON Schema for the staged mission-manifest contract
- `tools/cache.sh`
  - host-side OCI cache plumbing
- `tools/vendor-adapter.sh`
  - copies target adapter surfaces into `vendor/`
- `vendor/woodbox/`
  - pinned snapshot of the Woodbox adapter surface used for phase-one execution

Phase one uses the vendored adapter scripts as the execution surface and points
them at the published Woodbox installer substrate artifact for target-specific
media composition.

Terminology note:

- the transport artifact is still named `airgap-platform` for compatibility
- the user-facing concept is now one or more application catalogs plus a
  selected app set from the merged effective catalog
