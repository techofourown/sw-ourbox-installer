# Installer Requirements

Status: draft  
Audience: `sw-ourbox-installer`, `sw-ourbox-os`, and `img-*` maintainers

This document is the working requirements contract for the unified OurBox
installer effort.

Its purpose is to keep three things separate:

- requirements this repo is actively expected to satisfy
- parked requirements we intend to implement later
- non-requirements we are explicitly not optimizing for

The core architectural rule is:

- the target never resolves artifacts, ever
- the host chooses, resolves, pulls, verifies, and stages the mission
- the target boots only local mission bytes in order to install the staged
  system

In the target architecture, a trusted host chooses the mission, resolves exact
artifact identities, pulls the bytes, verifies them, and stages them onto
mission media. The target consumes only local bytes.

The target-side work that remains allowed is local installation behavior, such
as:

- destructive storage confirmation
- hostname prompts
- username and password prompts
- identity and credential prompts already part of the install flow
- local provenance writing

This prohibition applies to all target-side paths:

- official paths
- debug paths
- fallback paths
- compatibility paths
- operator override paths

## Current Requirements

These are active requirements for the installer project now. Some are fully
implemented in phase one; some are mandatory direction even if follow-on phases
 still need more work below the hardware seam.

### 1. Single operator front door

- `sw-ourbox-installer` is the operator-facing front door for composing mission
  media.
- This repo owns host-side orchestration, mission metadata, cache handling, and
  vendored target adapter snapshots.
- This repo is expected to provide:
  - one CLI
  - one mission-manifest contract
  - one host-side cache
  - one place to vendor and pin target adapters
- This repo does not own hardware enablement or target runtime install logic.

### 2. Host-side selection is required

- The operator must be able to choose both:
  - an OS artifact
  - one or more application catalogs (currently transported as
    `airgap-platform` bundles)
  while provisioning installer media on the host.
- When the selected catalogs advertise catalog metadata, the operator must also
  be able to choose which applications from the merged effective catalog are
  installed:
  - the merged default app set
  - all apps from the merged catalog
  - a custom app subset from the merged catalog
- Host-side selection must happen before the target boots.
- The host-side selection surface must support:
  - official catalog selection
  - explicit OCI refs or digest-pinned refs
- No target-side mode may browse catalogs, resolve tags, log into registries,
  pull artifacts, or fetch remote defaults.

### 3. Target installation must be completely offline

- During installation, the target must be able to complete successfully with no
  network connectivity.
- Official install paths must succeed with the target NIC unplugged or otherwise
  disconnected from any network.
- The target must not require Ethernet, Wi-Fi, registry access, remote
  defaults, package mirrors, or any other network service in order to install
  the staged system.
- This requirement is about installation only. Post-install runtime networking
  is outside the scope of this document.

### 4. Host resolves exact identities

- The host must resolve selected artifacts to exact immutable digests before
  media is considered composed.
- The host must pull and verify staged bytes locally.
- Moving channel tags are convenience inputs, not ground truth.
- Catalog rows or explicit digest-pinned refs are the preferred truth surface.

### 5. Host-side application catalog selection remains bounded by the OS contract

- If the operator selects one or more application catalogs that differ from the
  OS payload's baked bundle, every selected catalog bundle must match the
  selected OS payload's `OURBOX_PLATFORM_CONTRACT_DIGEST`.
- Architecture must also match the target slot.
- The host must fail closed on contract mismatch, arch mismatch, or malformed
  bundle shape.
- The host must merge the selected catalogs into one effective catalog before
  application selection.
- If multiple selected catalogs provide the same stable app identity, the host
  must require an explicit source choice rather than silently picking one.
- The app-selection flow should reuse the same business logic regardless of
  whether the effective catalog came from one source catalog or many.
- If the operator chooses a custom app set, the selected app ids must be a
  subset of the merged catalog's declared applications.
- Catalog merge and deconfliction must be driven by stable app identity rather
  than display name alone.

### 6. Mission media is a mission pack

- Composed media is not a generic warehouse of all targets and all bundles.
- A mission pack is for one selected target/profile/artifact tuple, with one
  synthesized application bundle derived from one or more selected application
  catalogs.
- A mission pack is the selected mission for one stick, not a universal payload
  warehouse.
- Mission media must carry:
  - the staged OS bytes
  - the staged synthesized application-bundle bytes
  - the selected application catalog identities needed to explain where the
    app set came from
  - the selected-application metadata needed to reproduce the chosen app set
  - a mission manifest
  - the metadata actually required to compose and install those staged bytes

### 7. Installer substrate and mission media are distinct objects

- The architecture must distinguish:
  - installer substrate
  - mission media
- Installer substrate is target-owned boot/install runtime without selected
  mission bytes.
- Mission media is host-composed substrate plus selected OS bytes, selected
  airgap bytes, mission manifest, and provenance.
- Target adapters operate on this distinction, and the unified host tool must
  compose from a published target-owned substrate artifact rather than
  requiring a checked-out target repo in the normal operator path.

### 8. Mission manifest is a first-class contract

- `sw-ourbox-installer` owns the `mission-manifest` schema.
- The mission manifest must record, at minimum:
  - target identity
  - media kind
  - compose tool identity
  - adapter identity
  - selected OS identity
  - selected application catalog identities
  - selected application-set identity
  - platform-contract identity
  - staged file paths and integrity hashes
  - install-mode fields relevant to target-side configuration prompts

### 9. Adapters compose local bytes; they do not choose missions

- Target adapters exist to turn already-selected local bytes into bootable media
  for that target.
- Target adapters must not own catalog browsing, ref resolution, or registry
  pulls in the intended operator path.
- Adapter surfaces are vendored into `sw-ourbox-installer` at pinned revisions.
- The unified tool must not execute remote dynamic adapter code fetched at
  compose time.
- Adapters must not contain target-side artifact discovery or pull logic, even
  as debug, rescue, compatibility, or fallback behavior.
- Adapter metadata must declare, at minimum:
  - target id
  - supported media kinds
  - expected OS artifact kind/type
  - expected airgap architecture
  - host prerequisites
  - whether output is a file or a raw block device
  - minimum media size estimate
  - runtime prompts intentionally kept on target

### 10. Host-side cache reuse is required

- The installer must maintain a host-side cache of resolved and pulled assets
  that can accelerate repeat mission composition.
- This is separate from requirement 3.
- Requirement 3 is about the target during installation.
- This requirement is about normal host-side compose behavior.
- If matching cached assets are available for the requested mission inputs, the
  tool must present the operator with the option to reuse those cached assets.
- Cache reuse must not depend on the operator knowing about or supplying a
  special mode flag.
- Reused cached assets must still be validated against the expected artifact
  identities and integrity checks before compose continues.
- The cache must cover the refs and catalog artifacts touched by the compose
  path when those inputs have already been fetched.
- At the end of the compose flow, the operator must be offered the option to
  clear cached assets to reclaim disk space.

### 11. Target-side responsibilities remain local

- The architecture keeps these on the target side:
  - local payload verification
  - destructive storage confirmation
  - hostname configuration
  - username and password configuration
  - identity and credential prompts
  - target-specific boot and install mechanics
  - local provenance writing
  - first-boot bootstrap behavior
- Keeping these local does not widen target authority to resolve or pull
  artifacts.

### 12. Phase-one target scope is Woodbox first and includes the purge

- Phase one is allowed to be Woodbox-only.
- Phase one must establish the reusable host-side shape:
  - cache manager
  - host-side resolver
  - mission-manifest schema
  - media composer skeleton
  - adapter vendoring and pinning
- While phase one is underway, no new official flow should be added that
  depends on target networking.
- Phase one also requires deleting the Woodbox target-side browse/pull path.
- No Woodbox target-side install path may retain:
  - target-side OS catalog browsing
  - target-side airgap catalog browsing
  - target-side `oras` bootstrapping or pulling
  - target-side registry login
  - target-side remote `install-defaults`
  - moving-tag resolution on target
- This purge is a current requirement, not a parked cleanup item.
- Thin or substrate artifacts may still exist as host-composition inputs, but
  they must not preserve a target-side artifact-resolution install path.

### 13. Preserve the existing ownership seam

- `sw-ourbox-os` remains the upstream platform repo.
- `img-*` repos remain target repos and own target substrate and runtime install
  mechanics.
- `sw-ourbox-installer` orchestrates mission composition across those surfaces.
- OCI remains the interchange format between build pipelines and the host
  composer; it is not part of the intended stressed-target operator contract.

## Parked Requirements

These are intended requirements, but they are parked for later phases rather
than phase one.

### 1. Matchbox migration to fat/local mission media

- Matchbox should gain a local mission partition and local OS/application-catalog read path.
- Official Matchbox installs should work with the target NIC unplugged.
- Matchbox purge follows with that migration:
  - target-side OS catalog browsing removed
  - target-side application-catalog browsing removed
  - target-side `oras` bootstrapping and pulling removed
  - target-side registry login removed
  - target-side remote `install-defaults` removed
  - moving-tag resolution on target removed

### 2. Additional targets

- Matchbox support is parked for a later phase.
- Tinderbox support is parked for a later phase.

### 3. CI no-network validation gates

- Later phases should add explicit validation that official compose/install
  flows succeed without target network access.

### 4. Canonical publish/provenance bundle embedding

- Embedding upstream/downstream publish-record JSON or candidate-provenance JSON
  is not required for phase-one execution.
- If we later decide we want those records on mission media for audit or support
  reasons, that should be added as an explicit later requirement with a defined
  file contract.

### 5. Operator-supplied local file inputs

- Phase one does not require the host composer to accept arbitrary operator-
  supplied local artifact files as primary mission inputs.
- In this document, "local file inputs" means files already present on the
  operator's workstation, such as a local OS payload tarball or local
  `airgap-platform` tarball, chosen instead of a catalog or OCI ref.
- Support for composing from those local files is parked for a later phase.

## Non-Requirements

These are explicitly not goals of the installer effort.

### 1. One stick containing everything

- The installer is not required to produce a universal stick carrying every
  target, every OS build, and every airgap bundle.
- The intended model is mission-specific media, not a tiny portable warehouse.

### 2. Target-side artifact discovery as a product goal

- We are not trying to preserve target-side browsing, resolution, or pulling as
  a long-term product capability in any path.
- Existing target-side browse/pull flows are not an allowed compatibility mode
  and should be deleted rather than carried forward.

### 3. Dynamic remote code execution for adapters

- The installer must not fetch and execute unpinned adapter code from a remote
  repository at compose time.
- Adapters are vendored and reviewed snapshots.

### 4. Floating tags as the source of truth

- The installer is not required to trust moving `stable-*`, `beta-*`, or other
  floating tags as canonical truth.
- If those tags disappear or drift, the compose model should still be grounded
  in catalogs or exact digests.

### 5. Arbitrary freeform app composition in phase one

- Phase one is not required to generate arbitrary custom app sets from scratch.
- Choosing among published `airgap-platform` bundles and explicit digests is
  sufficient for the current architecture.
- Operator-supplied local bundle inputs are later-scope, not part of the
  current execution contract.

### 6. Live-boot mission media

- This installer contract is not trying to create a live-boot product mode.
- Mission media is install media, not a persistent live environment.

### 7. Shipping canonical pipeline provenance records just to archive them

- Mission media is not required to carry upstream/downstream publish-record or
  candidate-provenance bundles unless some actual compose/install behavior
  consumes them.
- The installer is not an archival evidence bundle by default.

### 8. Unifying target-specific runtime UX right now

- The installer effort does not currently require Matchbox and Woodbox to share
  identical target-side storage prompts, confirmation wording, or runtime UI.
- Those behaviors remain target-owned below the hardware seam unless we
  explicitly standardize them later.

### 9. Making `install-defaults` a permanent runtime pillar

- The long-term architecture does not require target runtimes to depend on
  remote `install-defaults`.
- Transitional host-side use is acceptable, but preserving remote target-time
  defaults as a permanent dependency is not a design goal.

## Phase-One Read

The simplest phase-one interpretation is:

- the target-never-resolves rule is already the architectural requirement
- the target install must complete with no network connectivity
- the unified repo exists
- Woodbox is the first target
- the host can choose OS and airgap inputs while provisioning media
- the host can choose a selected app set from the chosen application catalog
- the host can choose from catalogs and explicit refs
- the host stages verified local bytes plus a mission manifest and the metadata
  actually needed for installation
- the tool is cache-aware by default and offers cached-asset reuse with
  operator confirmation
- the tool offers cache cleanup at the end of compose
- the adapter seam is pinned and vendored
- Woodbox target-side browse/pull code is removed rather than preserved as a
  compatibility path

That last point is important:

- phase one does not mean the final architecture is done
- phase one does mean the unified tool already treats host-side OS and airgap
  choice as a requirement, not as an optional later idea
- phase one creates no carve-out for target-side debug, fallback, or
  compatibility resolution paths
- if a target-side path resolves or pulls artifacts, that path is out of
  contract and should be removed
