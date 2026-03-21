# Plugin SDK Docs Implementation Plan

## Goal

Add a generated Plugin SDK reference to the existing Mintlify docs without
creating a second docs site or freezing accidental/internal helper surfaces.

The result should be:

- hand-written guides remain the explanation layer
- generated reference pages cover the intended public SDK surface
- docs drift is checked in CI
- the first release documents a curated stable subset instead of every export

## Why This Fits OpenClaw

OpenClaw already has the pieces this needs:

- Mintlify docs with `docs/docs.json`
- an explicit Plugin SDK entrypoint list in `scripts/lib/plugin-sdk-entrypoints.json`
- generated docs drift patterns for config docs under `docs/.generated/`
- existing hand-written plugin docs that currently duplicate some SDK reference material

The main project risk is not tooling. It is accidentally documenting transitional
or bundled-plugin-only helpers as if they were long-term public API.

## Non-Goals

- Do not publish a separate TypeDoc HTML site.
- Do not generate one page per symbol.
- Do not document `src/**` internals or bundled extension internals as public SDK.
- Do not expand to `docs/zh-CN/**` in v1.
- Do not treat the root `openclaw/plugin-sdk` barrel as the primary entrypoint for new users.

## Success Criteria

1. `docs/reference/plugin-sdk/` exists with a landing page and category pages.
2. A generator creates module reference pages from the real SDK interface.
3. The generator is driven by the canonical SDK entrypoint list.
4. The first shipped reference covers the high-value stable modules.
5. CI fails if generated docs drift from the checked-in source of truth.
6. Existing hand-written tables in plugin docs are replaced with links to the generated reference where appropriate.

## Canonical Public Surface

Use `scripts/lib/plugin-sdk-entrypoints.json` as the source of truth for
documented public subpaths.

Before generating module pages, classify each entrypoint into one of these tiers:

- `stable`: recommended public contract for plugin authors
- `advanced`: public but niche or low-level
- `legacy`: compatibility-only or deprecated
- `hidden`: exported today but intentionally omitted from docs until reviewed

This classification should live in a checked-in metadata file, for example:

- `scripts/lib/plugin-sdk-doc-metadata.ts`

That file should also assign each module to a docs category, for example:

- `core`
- `channel`
- `provider`
- `runtime`
- `utilities`
- `legacy`

## Docs IA

Keep the current hand-written docs as guides:

- `docs/plugins/building-plugins.md`
- `docs/plugins/sdk-migration.md`
- `docs/plugins/architecture.md`
- `docs/plugins/manifest.md`

Add a generated reference section under:

- `docs/reference/plugin-sdk/index.md`
- `docs/reference/plugin-sdk/import-model.md`
- `docs/reference/plugin-sdk/stability.md`
- `docs/reference/plugin-sdk/all-modules.md`
- `docs/reference/plugin-sdk/core.md`
- `docs/reference/plugin-sdk/channel.md`
- `docs/reference/plugin-sdk/provider.md`
- `docs/reference/plugin-sdk/runtime.md`
- `docs/reference/plugin-sdk/utilities.md`
- `docs/reference/plugin-sdk/legacy.md`
- `docs/reference/plugin-sdk/modules/*.mdx`

Keep `docs/docs.json` small. Only add the landing page and category pages to the
sidebar. Let category pages link to the generated module pages.

## Generator Design

Use:

- TSDoc comments in `src/plugin-sdk/**`
- TypeDoc JSON output as the extraction layer
- a repo-owned intermediate representation
- Markdown/MDX output that Mintlify serves directly

Recommended files:

- `scripts/generate-plugin-sdk-docs.ts`
- `scripts/lib/plugin-sdk-doc-metadata.ts`
- `scripts/lib/plugin-sdk-doc-ir.ts`
- `scripts/lib/plugin-sdk-doc-render.ts`

Recommended generated artifacts:

- `docs/.generated/plugin-sdk-doc-model.json`
- `docs/.generated/plugin-sdk-docs.manifest.jsonl`

Recommended package scripts:

- `plugin-sdk:docs:gen`
- `plugin-sdk:docs:check`

Then wire `plugin-sdk:docs:check` into `check:docs`.

## Intermediate Representation

Do not render directly from raw TypeDoc JSON to MDX in one step.

The normalized doc model for each module should capture:

- subpath
- import specifier
- category
- stability tier
- deprecation state
- short summary
- source file path
- exported members grouped by kind
- symbol signatures
- params
- returns
- remarks
- examples
- source anchors

This keeps OpenClaw-specific policy separate from the extraction tool.

## Page Shape

Generate one page per subpath, not one page per symbol.

Each module page should include:

1. title and short summary
2. import snippet
3. stability marker
4. "use this when" guidance
5. export index
6. detailed symbol sections
7. related modules
8. source links

Symbol sections should use anchors so deep links work per export.

## Phased Rollout

### Phase 1: Scaffolding

- add `docs/reference/plugin-sdk/` landing and category pages
- add `docs/docs.json` navigation entries
- add the metadata map for category + stability
- add a short note in current plugin docs pointing readers to the upcoming reference area

Deliverable:

- navigation and information architecture land without generated module pages yet

### Phase 2: Generator MVP

- add TypeDoc dependency and config
- implement `scripts/generate-plugin-sdk-docs.ts`
- read `scripts/lib/plugin-sdk-entrypoints.json`
- filter to the reviewed stable subset
- generate module pages for the first 12 to 15 high-value modules
- add `plugin-sdk:docs:gen` and `plugin-sdk:docs:check`
- add CI drift checking

Initial stable subset should prioritize:

- `core`
- `plugin-entry`
- `channel-setup`
- `channel-pairing`
- `channel-reply-pipeline`
- `channel-config-schema`
- `channel-actions`
- `channel-contract`
- `command-auth`
- `secret-input`
- `webhook-ingress`
- `runtime-store`
- `testing`
- `reply-payload`
- `allow-from`

### Phase 3: Comment Coverage and Docs Cleanup

- improve TSDoc coverage for the high-value stable subset
- add module-level summaries where missing
- add `@deprecated` and `@remarks` tags for compatibility surfaces
- replace duplicated long import tables in:
  - `docs/plugins/building-plugins.md`
  - `docs/plugins/sdk-migration.md`
- keep short curated lists in guides and link out to the generated reference

### Phase 4: Coverage Expansion

- expand generated coverage to the rest of the reviewed stable modules
- add `advanced` and `legacy` pages only after stable pages are solid
- decide whether any currently exported modules should move to `hidden` or be removed from the public surface entirely

### Phase 5: Optional Governance

- evaluate API Extractor only after the generated docs flow is working
- use it for API review and contract governance, not as the first renderer

## Validation

The implementation should be considered healthy when:

- `plugin-sdk:docs:gen` is deterministic
- `plugin-sdk:docs:check` fails on drift
- the generated pages are readable in Mintlify locally
- adding a new documented stable entrypoint requires metadata review and a generated page update
- compatibility-only modules are visually marked as legacy or deprecated

## Risks

### Risk: accidental API blessing

Mitigation:

- require explicit stability metadata before a module appears in the generated reference

### Risk: poor generated quality from sparse comments

Mitigation:

- ship a curated subset first
- improve TSDoc coverage for the most-used modules before broad rollout

### Risk: sidebar and search noise

Mitigation:

- keep only landing and category pages in `docs/docs.json`
- link module pages from category indexes instead of listing all of them in nav

### Risk: docs churn from unstable surfaces

Mitigation:

- classify compatibility layers as `legacy`
- keep bundled-plugin-only helpers out of the generated public reference

## Proposed First PR Sequence

### PR 1

- create `docs/reference/plugin-sdk/` landing and category pages
- add docs nav entries
- add metadata map for category + stability

### PR 2

- add generator script
- add TypeDoc config and dependency
- generate pages for the initial stable subset
- add docs drift check

### PR 3

- improve TSDoc coverage for the initial stable subset
- replace duplicated manual SDK tables with links to the generated reference
- expand stable coverage as comments and metadata improve

## Recommendation

Ship this as a curated generated reference for the stable Plugin SDK, not as a
blind dump of every current export.
