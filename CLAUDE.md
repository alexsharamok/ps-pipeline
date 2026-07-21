# CLAUDE.md — CHA Sitecore → Uniform migration

This directory runs a content migration via `Run.ps1`. The usual goal is **make a full `.\Run.ps1`
end without errors** (success = it ends on git branch `runs/_last` and exits 0). A full run is
~25-30 min. Fix issues at the **root cause** (often in the two tools below), not with pipeline
band-aids. This file is the fast path — read it before re-exploring the stack.

## Frontend questions → `D:\cha-website`
For any **frontend-related** question (the site's UI/components/rendering, not the migration
pipeline), the frontend code lives in `D:\cha-website` — look there. This repo (`D:\cha`) is the
content-migration pipeline only.

## Always timestamp the end of a turn
Whenever you finish a turn because **the work is done** or **you need my input** (a question,
a confirmation, or a blocking decision), end the message with the current local time on its own
final line, formatted `🕒 yyyy-MM-dd HH:mm:ss`. Get it from the machine — run
`Get-Date -Format 'yyyy-MM-dd HH:mm:ss'` (don't guess or reuse `currentDate`, which is date-only).
Skip it only for intermediate progress updates where you're continuing to work in the same turn.

## Answering investigation questions
When a question requires investigation before you can answer it (anything beyond a trivial lookup —
tracing a root cause, deciding why something behaves as it does, forming a verdict), structure the
**final** answer in exactly this order before giving the verdict:
1. `Your request: ...` — repeat my question back **verbatim**, unedited.
2. Then rephrase it in your own words, as you understood it (surfaces any misread before the payload).
3. Only then give what you planned to respond — the findings/verdict/recommendation.
This applies to the conclusion you deliver, not to intermediate progress updates.

## After a fix or pipeline change is verified
When a non-trivial fix or pipeline change is implemented **and confirmed working** (the stage passes /
the run goes green), before moving on **proactively ask me whether to write it back**. If I say yes:
(a) update the relevant memory file (or the "Known failure classes" list below) with the root cause +
where it's fixed, and (b) make sure the `src/` commit message (and the siphon/transformer
`migration-fixes` commit) captures the **why**, not just the **what**. Skip this prompt after trivial or
purely exploratory turns — it's for durable knowledge, not every edit.

## How `Run.ps1` works
- No args = full pipeline. It copies `src/` → `.p/stages/`, then runs `NN`-numbered stages in order
  across folders: `0-assets` → `1-prep` → `2-siphon` (canvas `0300`, content `0400`) →
  `3-transform` (~80 stages; ends with `4599-finish` = `uniform-transform validate`, the fail-fast
  integrity gate) → `4-deploy` → `5-publish` → `6-tests` (e2e innerText comparison of the stage
  frontend on `TEST_STAGE_URL` vs a frozen prod-mirror dataset; report → `tests/report.md`; needs
  the `D:\cha-website` frontend running on localhost:3000, else set `SkipTests=1`; full design in
  `src/6-tests/README.md`, operational detail in the `cha-6-tests-e2e` memory).
- Per-stage output → `z_stdout/<folder>--<stage>.log`. Progress → `.p/current-state.json`
  (`currentPipelineStageIndex`). Each stage is a git commit on `runs/cha-<attempt>`; a failed stage
  is committed as `… - failed or aborted`.
- **Stage timing lives in the commit dates**: each stage is committed as `… - stage started`, then
  plain `git commit --amend`ed with the result, so the **author date = stage start** and the
  **committer date = stage finish** (author−committer gap = stage duration). `git log` shows author
  dates by default; to see both: `git log --format='%h %ad → %cd %s' --date=format:'%H:%M:%S'
  runs/cha-<n>`.
- `-Resume` continues the same attempt from the failed stage (reuses prior canvas/content — big time
  saver). `-StartAt NNNN` / `-OnlyFolder N` / `-StopAfter NNNN` slice a run. Full flags in `readme.md`.
- Deploy/publish target **canary** Uniform (`UNIFORM_*` / `SIPHON_UNIFORM_*` in `.env`). Pushes are
  real but idempotent (`createOrUpdate` / `mirror` / `publish`).
- **Deploy/publish is incremental** (`src/_incremental-deploy.ps1`, verified cha-229/230: 22 min full
  → 29 s no-change): stages diff `result/uniform-canvas` against the baseline in `.p/.last-deployed.json`
  (gitignored — tracks the CANARY's state; written by `5500-record-deployed` only after a fully green
  deploy+publish, via the marker 4600 drops) and push/publish only changed files/ids from a staging dir
  under `.temp/deploy-incremental/`. Mirror kinds (component/composition/entry/category) with
  **deletions** in the delta auto-fall back to a full mirror push (only mirror deletes remotely).
  Full-deploy fallbacks: missing/invalid/foreign-project baseline or `DeployIncremental=0` in `.env`.
  The delta is baseline→**working tree** (uncommitted canvas edits + untracked files deploy too,
  and are carried in the state file until committed) — hotfix flow: edit the canvas file, then
  `Run.ps1 -StartAt 4600 -NoCommit` (without `-NoCommit`, Git-Setup wipes uncommitted edits).
  **Re-baseline** (force full deploy): delete `.p/.last-deployed.json`. Details in the
  `cha-incremental-deploy` memory.

## Put ALL temporary files in `.temp/` (never in `.p/` or the repo root)
Any scratch file **you** (the agent) create while driving this — run/output logs, supervisor scripts,
sentinel/`.done` files, ad-hoc `.json` scratch — goes under `.temp/` at the repo root, and nowhere
else. `.temp/` is gitignored, so it never pollutes a commit or a stage's change assertion.
- **Do not write into `.p/`.** That directory is the pipeline's own working area (`.p/stages`,
  `.p/current-state.json`); dropping `_resume_run.log`, `run-NNNN.out.log`, `_resume_supervisor.ps1`,
  etc. there is what got those temp files accidentally committed. Read from `.p/` (poll state), but
  write your scratch only to `.temp/`.
- The repo root is also off-limits for scratch (only `/*.log` and `/*.ps1` are ignored there, which is
  fragile). Use `.temp/` for everything.

## Driving it headless (iterate without burning tokens)
- Launch via `powershell -Command "& '.\Run.ps1' <args>"`, **never `-File`** — Windows PowerShell 5.1
  leaves `$PSScriptRoot` empty in a `[CmdletBinding()]` param default under `-File`. The user's
  interactive `.\Run.ps1` is fine.
- A run outlasts tool timeouts, so start it **detached** (a tiny supervisor written to
  `.temp/_supervise.ps1` that `Start-Process powershell -Command "& '.\Run.ps1' …" -Wait` then writes a
  sentinel file like `.temp/_run.done`) and redirect output to a file **inside `.temp/`** (e.g.
  `*> '.temp/_run.log'`) — do NOT capture the ~110MB canvas log. Poll `.p/current-state.json` +
  `git log runs/cha-<n>` + the failing `z_stdout` log.
- On failure: read the failing stage's log, fix the root cause, then `Run.ps1 -Resume`.
- **Read logs by grepping, never whole.** `z_stdout/<folder>--<stage>.log` files are large; search for
  the failure (`Select-String -Path 'z_stdout\*4599*' -Pattern 'error|unknown|Couldn''t|fail'`) or use
  the Grep tool, then read only the surrounding lines. **Never `Read` the canvas `0300` log (~110MB)** —
  grep it or skip it. Same for `result/uniform-canvas/**` (thousands of files): grep, don't bulk-read.
- **Delegate stack investigation to a subagent.** For any "where is X / how does Y work" sweep across
  `src/`, `D:\content-siphon`, or `D:\transformer`, spawn an `Explore` agent instead of reading files
  into this session — it returns the conclusion and keeps the main context lean (the single biggest
  per-session token saver for a stack this size). Reserve direct reads for the specific file you already
  know you need to edit.
- After killing a run, **`rm .git/index.lock`** first (stale/transient locks recur and halt the
  next stage's commit).
- **Fast re-test of one stage (skip the ~25-min siphon + earlier transforms).** Every stage is a
  git commit, so to exercise a stage you added/changed: `git checkout <commit-of-the-stage-just-
  before-yours>` (find it in `git log` — e.g. the `…2602-add-contact-us-pattern (cha/N)` commit
  precedes a new `2604` stage), then `Run.ps1 -StartAt <your-NNNN>`. A non-`-Resume` `-StartAt` does
  a fresh `Git-Setup` that **resets the canvas to that commit** (the prior stage's exact output —
  full entries, pre-deletion), **rebuilds `.p/stages` from your *current* `src/`** (gitignored, so
  the checkout doesn't touch it — your edited/added/deleted stages apply), and runs **only your
  stage → deploy → publish**. So a stage in `34-add` is verified end-to-end (incl. the real canary
  push) in a few minutes instead of a full run. The checkout commit just needs to be a valid
  earlier-than-your-stage state; its attempt number is irrelevant.

## The two tools the pipeline drives
- **`D:\content-siphon`** (C# `Siphon.Migration.exe`; `.env SIPHON_PATH_OVERRIDE` points at the local
  Release build, so a rebuild takes effect immediately). Emits the Uniform canvas+content under
  `result/uniform-canvas`. Build `dotnet build src/Siphon.sln -c Release`; tests
  `dotnet test src/UnitTests/UnitTests.csproj` (5 failures are **pre-existing & unrelated**:
  GetValidName casing, GetItemIgnoreCase, a logging-thread test).
  - **Internals map (so you don't re-discover the structure).** Siphon runs as **two separate
    `Siphon.Migration.exe` stages** — canvas `0300` (`ProjectMapService` → `component/`, `composition/`,
    `projectMapNode/`, `datatype/`) and content `0400` (`ContentService` → `contentType/`, `entry/`).
    They share **only the on-disk `result/uniform-canvas`, no in-memory state** — so a content-stage fix
    can't read the canvas stage's node/def set (this decides whether a fix belongs in siphon or the
    transformer). In `ContentService.cs`: `SaveContentTypes`→`GetTypeFields` builds content types from the
    template field **schema** (never values); `SaveContent` builds entries — the two gate templates
    **independently**, so siphon can emit an entry whose content type was dropped. `OrderedFieldCollection`
    throws `CaseInsensitiveDuplicateFieldException` on case-colliding field ids. Route links:
    `InternalLinkFieldProcessor.GetValue` emits a `projectMapNode` link for **any `IsPage()` item**, but a
    node is generated only for items passing `ItemModelExtensions.FilterPageItem` (`IsPage` + under StartPath
    + **not** in `SIPHON_PAGESTOEXCLUDE`); both ids derive from `Utils.ComputeGuidHash(path)`, so the link
    gate is a superset of the node gate ⇒ dangling links.
- **`D:\transformer`** (TS `uniform-transform`, npm-linked; `npm run build`). Mutates the
  serialization between siphon and deploy. Its CLAUDE.md requires build+lint+test+e2e before commit.
- Fixes for this migration are on a local **`migration-fixes`** branch in each of `content-siphon`,
  `transformer`, and `src` (not merged to main/master). On the base branches the failures below recur.
- **`src/` is its OWN git repo** (a separate `.git`, nested inside `D:\cha` — not the same repo as the
  `runs/cha-*` pipeline branches). Any change you make under `src/` (new/edited/deleted stages,
  config, helpers) **must be committed in the `src/` repo** — e.g. `git -C src add -A && git -C src
  commit`. The pipeline copies `src/` → `.p/stages/` at run start, so uncommitted edits still execute,
  but they are lost on the next `Git-Setup`/checkout if not committed. Always commit `src/` changes.

## Gotchas that cost the most time
1. **Component cache is NOT invalidated when the siphon binary changes.** `SIPHON_CACHECOMPONENTS=true`
   caches defs in `.components.cache`, `.components.ref.map.cache`, `.components.fingerprint`,
   `.models.cache` (gitignored → survive Git-Setup). **After rebuilding siphon, delete those files**
   or the fix is silently bypassed — post-load passes (e.g. slot reconciliation) still apply, but
   generation-path fixes (e.g. parameter derivation) load stale defs from cache.
2. **Stale `.git/index.lock`** after a killed run or transient git contention → `rm .git/index.lock`,
   then `-Resume`.
3. A stage **comment** containing the literal `Must change files` / `Must create files` triggers the
   change assertion (Run.ps1 plain-substring-matches the whole file) — never write those phrases in
   a comment.
4. `SkipDeployMedia=1` in `.env` self-skips `0100` only (no media upload); `0700` placeholder
   resolution now always runs (it used to be gated by the same flag — see the broken-image failure
   class below). Canvas `0300` is the slow stage.
5. Hand-maintained `data/*.json` config may have trailing commas (WinPS 5.1 `ConvertFrom-Json`
   rejects them) — read via the lenient `Read-JsonFileLenient` in `src/_format-json.ps1`.
6. **`z_stdout/cha-<n>/` archives mix fresh + carried-forward STALE logs.** Each archive is a snapshot of
   the root `z_stdout` that includes logs the current attempt never rewrote (left over from a prior
   attempt), so file sizes/counts mislead — e.g. a `4599` validate log reporting `4023 entry` files inside
   an attempt whose canvas has ~14k. Ground truth = the **live** `z_stdout/<folder>--<stage>.log` of the run
   you just did, plus the **per-attempt branch commits** (`git log runs/cha-<n>`; `… - failed or aborted`
   marks where it stopped) — not the carried-forward copies. A concurrent run + sliced (`-StartAt`) runs
   make this worse; when unsure, trust a clean full run.
7. **Stage numeric prefixes must be unique across ALL folders; letter suffixes don't work.** Run.ps1
   validates at startup and exits 1 (`Duplicate leading numbers in stages`) before running anything, so
   a committed `4589a-…` stage silently blocks every future run. File order is lexical (a suffix would
   sort right), but the dup check and `-Resume`/`-StartAt`/`-StopAfter` all key on the parsed integer.
   To insert a stage where no integer is free, shift-renumber the downstream block (`git mv`
   highest-first) and update header comments that cite the shifted numbers (the 458x/4525/4530 headers
   reference the prune stages by number).

## Known failure classes → root cause & where fixed (so you don't re-derive)
- **Publish 400 `defines slot/parameter X that does not exist on component Y`** — a composition
  references a slot/param its component definition doesn't declare. Root cause was **siphon**
  building defs and compositions in unreconciled passes (`ProjectMapService.cs`:
  `PopulateAllowedComponents` skipped a missing slot; `MigrateCompositionComponentDefinition` built
  params from one arbitrary item, so empty fields were dropped non-deterministically). Fixed at the
  source: the definition is the union of what its compositions use. **Find these in seconds** (vs a
  30-min publish cycle): scan `result/uniform-canvas/composition/*.json` instance slot names + param
  keys against each `component/*.json`'s declared slots/params (skip `$`-prefixed virtual types and
  datatype-only roots like `Page`).
- **`validate` error `composition root (type X) defines parameter P not declared on component X`**
  (151 at once on `EventDetailPage`/`link`; a publish blocker too) — a param exists on composition
  **instances** but not on the component **definition** (`component/X.json`). Root cause was the
  **transformer**'s `copy-field` command (driven by stage `3-transform/4401-eventdetailpage-link`,
  which copies `EventDetailPage.relatedProjectMapNode` → a new `link` param in a `card` group):
  `FieldCopierService` updated the content type, entries, compositions and patterns, but **never the
  component definition** the validator gates on. Fixed in the **transformer** (`main` commit
  `9e478bf`): added a `copyFieldInComponentDefinitions` pass mirroring the content-type logic (clone
  the source param, register it under `--newGroupId`), wired through `componentsDir`. So any
  `copy-field` usage now declares the new param on the component too. **Find in seconds**: scan
  `composition/*.json` root/instance `parameters` keys against the matching `component/*.json`
  declared `parameters` (same scan as the publish-400 class above, param side).
- **`validate` false-positives** — seed (`--seedDir`) content is reference-only (findings →
  warnings, not gate failures); `$`-prefixed virtual types (`$loop`, `$slotSection`) and composition
  datatype roots (`Page`) are valid; the `{composition, pattern:true}` componentPattern form is
  valid. Dangling group `childrenParams` and wrongly-deleted nested-`$block` content types are fixed
  in the transformer's field-remover / unused-content-type-remover. Also non-gating: `tab`
  content-type findings and `projectMapNode` findings inside the **seed** `composition`/`componentPattern`
  are `[WARN] [seedDir]` (reference-only) — don't chase them.
- **`validate` error `entry references unknown content type X`** (also deploy 400 `Content type X not
  found` at `5100-sync-entries`) — an entry's root `type` resolves to no content type. Root cause:
  **siphon**'s content-type build (`ContentService.SaveContentTypes` → `GetTypeFields`) injects a standard
  `DisplayName` field, so when the template *also* has a field whose id collides case-insensitively (e.g.
  a literal lowercase `displayname`), the ordered field collection throws
  `CaseInsensitiveDuplicateFieldException`; the per-template `try/catch` swallows it (logs `Couldn't save
  content type: X … won't be migrated` in the `0400` log) so the **content type is dropped**, yet
  `SaveContent` still emits that template's entries → orphan-typed entries. Fixed at the source: dedup the
  generated field list case-insensitively (keep first occurrence) before `contentType.Fields.AddRange`, so
  the type is still produced. Hit it on `ListFacet`/`DistanceFacet`/`Facet` (SXA facet settings, which
  carry a lowercase `displayname`). **Find in seconds**: scan `result/uniform-canvas/entry/*.json`
  `entry.type` against `contentType/*.json` ids, or grep the `0400` log for `Couldn't save content type`.
- **`validate` error `projectMapNode link references unknown project-map node X`** (300+ at once; also a
  deploy blocker) — a `projectMapNode` link (`relatedProjectMapNode` on entries, plus links on
  composition/block components) points to a node that was never serialized. Root cause is **siphon**'s
  link-emission gate (`InternalLinkFieldProcessor.GetValue`, only `IsPage()`) being a *superset* of its
  node-generation gate (`ItemModelExtensions.FilterPageItem` = `IsPage` + under StartPath + **not in
  `PagesToExclude`**); both derive the id from `ComputeGuidHash(path)`, so every `PagesToExclude` item
  (`SIPHON_PAGESTOEXCLUDE` = `*/data/*` datasources like `AccordionItem`/`TabItem`, plus `*/search`,
  `*/Member Dashboard`, `*/404`, `*/LoginRedirect`, `*/Hospital Directory`) gets a link to a node siphon
  never generates. Fixed at the boundary by transformer command
  `downgrade-dangling-project-map-node-links` (stage `3-transform/39a-last/4598`, before validate), which
  rewrites each dangling link (`nodeId` not in rootDir∪seedDir nodes) to a `{type:url,path}` link. **Find
  in seconds**: scan entry/composition `{type:projectMapNode,nodeId}` against `projectMapNode/*.json` ids
  (+ `data/seed-content/projectMapNode`).
- **`4514-remove-unref-entries` deletes a live composition-referenced entry** (dangling `entryId` left in
  the composition → publish/validate hazard) — `remove-orphan-entries` is composition-aware
  (`collectEntryIdReferencesDeep` deep-walks compositions/patterns/nodes and whitelists referenced
  entries), but its reference-shape matcher only recognized the **plural** `variables.entryIds`
  (comma-separated, used by multi-value resources like `multipleTopic`) plus `contentReference` arrays —
  it **missed the *singular* `variables.entryId`** that single-value data resources (e.g. `ProductCallout`)
  use to bind one entry. So an entry referenced solely via a singular-`entryId` resource looked orphaned
  and was deleted. Fixed in the **transformer** (`migration-fixes` commit `69fc4f5`): the walker now also
  collects singular `variables.entryId` by shape, regardless of resource `type`. (The entry→entry BFS
  extractor stays type-gated on `uniformContentInternalReference` — entries key their own refs under that
  type; singular-`entryId` typed resources only appear in layouts.) **Find in seconds**: scan
  `composition/*.json` (+ pattern/node) `dataResources.<name>.variables.entryId` values against
  `entry/*.json` ids.
- **Deploy/publish flakiness** — the `uniform` CLI is wrapped with retry (`src/_uniform-retry.ps1`)
  for transient canary `ECONNRESET`/`ConnectTimeout`; `5400` publishes the migration's own
  composition ids in batches, **never `--all`**, so separately-owned **seed** compositions (the only
  `Page`-rooted ones, which carry orphan params like `canonicalurl`) can't fail the run. Those seed
  orphans are a `data/seed-content` problem, not siphon — don't chase them in the pipeline.
- **Slot-removal silently exposes a component to `4530` entry-extraction → dangling `entryId` binds** —
  `4530-extract-patterns-with-entries` binds every **slot-less atomic leaf** 1-to-1 to its `sourceItem`'s
  entry. A component's own slot can *accidentally shield* it from this stage by making it non-atomic; the
  moment a transform removes that slot, the component becomes a bare leaf and 4530 binds all its instances —
  and if that component's `sourceItem`s have **no materialized entries**, every bind dangles
  (`_dataResources.<name>.variables.entryId` → non-existent entry) and swallows the instance's data.
  Validate/deploy/publish do **not** gate on this, so the run stays **green while the data is lost** — only
  a result inspection catches it. Hit on **RelatedTopics**: stage `1400` was changed to propagate the new
  `topicsBlock` `$block` param (via `propagate-root-component-property`, replacing the dead
  `propagate-root-slot --slot topics`), which removed RelatedTopics' `topics` slot → 4530 produced **1008**
  dangling binds. Fixed by adding `--excludeComponentTypes "RelatedTopics"` to `4530` so `topicsBlock` stays
  inline (`src` commits `66cc1c6` + `eb7dc2f`; verified cha-201 green: 1102 inline, 61 empty-topic pattern
  refs, **0 dangling**). **Find in seconds after any slot-removal:** scan `composition/*.json` for that
  type's `_dataResources.<name>.variables.entryId` against actual `entry/*.json` `_id`/`_sitecoreId`.
  (Frontend caveat: `D:\cha-website` RelatedTopics.tsx still reads a `topics` **slot**, no `topicsBlock`
  reader — needs a frontend change to consume the param, else topics won't render.)
- **`4530` emits a near-empty pattern (`parameters: {}`) for a leaf whose data lives on the page root, not
  the leaf** — `extract-patterns-with-entries` built the pattern's params ONLY from **locales-form params
  physically present on the inline instances**. Components like **Breadcrumb** carry no content params on
  the leaf (siphon leaves `DisplayName` and the `contenttypeBlock` `$block` empty — that data sits on the
  `Page` root), so the generated `Breadcrumb <- <PageType>` pattern had empty params and the entry's fields
  never reached the component. Fixed in the **transformer** (`main` commit `e6a4671`) by deriving the
  missing binds from the **component definition + content-type schemas** rather than instance data:
  **(A)** a component-declared scalar param whose id matches an entry field binds 1-1 via jptr — value-form
  if non-localizable (`DisplayName`), locales-form otherwise; migration/system fields excluded. **(B)** a
  `<X>Block` `$block` param binds through the entry's single `contentReference` field `<X>`, instantiating
  the `<Y>Block` type (from `allowedTypes`) whose referenced content type is `<Y>` (both by stripping the
  `Block` suffix — the migration's naming rule); each block field also present on the referenced type,
  scalar, and non-system binds via a **deep jptr** `…/<X>/value/entry/fields/<field>/value`. Binds are
  pattern-level (not in `_overridability.parameters`); anything off-convention (multi-ref field, missing
  referenced type, no shared fields) is left unbound, not mis-bound. Verified: regenerates the hand-authored
  `Breadcrumb <- CHTArticleDetailPage` pattern exactly and generalizes to all 6 Breadcrumb→page-type
  patterns; only 7 of 29 stage-4530 patterns change, none over-bound. **Find in seconds:** scan
  `componentPattern/*.json` for `type:Breadcrumb` patterns with `parameters: {}`. (Frontend caveat:
  `D:\cha-website` Breadcrumb must actually read `contenttypeBlock`/`DisplayName` for it to render — same
  shape as the RelatedTopics `topicsBlock` caveat above.)
  **Follow-up (`main` `d7f4d8d`): the same schema-driven bind also skipped `asset`/`link`/`contentReference`
  params** (its `NON_SCALAR_TYPES` gate over-excluded them), so any such param empty on the leaf stayed
  unbound — notably **FeaturedCard's `link`** (siphon puts the link value on the `<PageType>` entry, not the
  leaf, so it never reached the instance path and the schema path refused it). Fix narrows the deny-set to
  the genuinely structural `group`/`$block`/`$loop`; the three data-bearing types now bind 1-1 via
  `${#jptr:/…/fields/<id>/value}` (the entry field already holds the resolved value). A `link` bind is a
  live jptr *reference*, so it inherits the `4598 downgrade-dangling-links` result — no new hazard — and
  matches the component's declared param. Verified 4530→validate: `FeaturedCard from CaseStudyDetailPage`
  (`36e02d14…`) binds `link`; 14 link + 30 asset params across 138 patterns; validate 0 errors / 5717 files.
  **Find in seconds:** scan `componentPattern/*.json` for a component-declared `link`/`asset` param absent
  from the pattern's `parameters`.
- **Broken rich-text images: `<img src="/uniform_asset/<id>">` reaches deploy unresolved** (NO
  validate/deploy/publish stage gates on it — the run stays green while the site renders broken images; hit
  on 795 entries / 878 unique assets, e.g. the PLS Nutrition-in-the-Critically-Ill-Child page) — siphon
  `0300`/`0400` emit `/uniform_asset/<uniform-asset-id>` placeholders that stage `0700`
  (`post-process-assets`, `AssetsPostProcessingService`) rewrites to real asset URLs via a **live Uniform
  API lookup per id** (the placeholder id IS the deterministic Uniform asset id,
  `ComputeGuidHash(ItemID+language)` — no `0100` mapping file is consulted, so resolution works whenever the
  assets exist in the project, regardless of when they were uploaded). Root cause: `0700` was gated by the
  same `SkipDeployMedia` flag as the slow `0100` binary upload, so the perma-set flag also skipped the pure
  text substitution; the stage additionally carried dead Azure-release invocation code (version-file lookup
  + bare `siphon` call) that ignored `SIPHON_PATH_OVERRIDE` and would have crashed locally. Fixed in **src**
  (`migration-fixes` commit `7a7499c`): gate removed (never-uploaded ids are left as-is with a `0700` log
  warning `Can not find asset`, so the stage is safe even on a fresh project) + standard
  `RunSiphon.ps1 -Command 'post-process-assets'` invocation; verified cha/226 (0700 rewrote 1493 files;
  published entry on canary carries the real `canary-img.uniform.global` URL). Residual, separate gap: ids
  never uploaded to Uniform stay placeholders — as of cha/226, 52 ids across 87 files (media added after the
  last `0100` upload of 2026-06-15); the only cure is a user-authorized `0100` run. Note `SIPHON_CACHEASSETS=true`
  caches lookups in `cache/.assets.cache` — same staleness class as gotcha #1 if assets are ever re-uploaded.
  **Find in seconds:** grep `result/uniform-canvas/**/*.json` for `/uniform_asset/`, or the `0700` log for
  `Can not find asset`.
- **Static composition-pattern slot without a `$slotSection` ⇒ `4580` silently drops everything authored in
  that slot** (run stays green while per-page content is lost) — the transformer's
  `apply-composition-pattern` relocates a composition's authored slot content **only** into `$slotSection`
  overrides (matched by slot *key*), then deletes the composition's inline `slots` wholesale; any slot key
  with no placeholder in the pattern is discarded, leaving only the items' orphaned per-instance
  `dataResources` overrides behind (ids that exist nowhere in the pattern — that residue is the detection
  signal). Hit on the **EventDetailPage** pattern (`dbc7ad68…`): unlike the CaseStudy/Product/News patterns
  (thin all-`$slotSection` scaffolds, which relocate the whole `ArticleDetail` and are immune), the Event
  pattern was a rich static tree whose `ArticleDetail` carried a static VimeoPlayer (`bottom-placeholder`)
  and a static **empty** DownloadMaterials (`page-bottom-placeholder`) — so all 151 event pages lost 185
  DownloadMaterialsLink items (108 pages; the missing `download-material-component`), 73 EventSessions, 129
  authored VimeoPlayers and 6 PromoCards. Fixed in **src** (`migration-fixes` commit `2e79b73`): both
  statics replaced with `$slotSection` placeholders so 4580 relocates each page's authored subtree — note a
  host component gaining a `$slotSection` joins the structure gate (composition must have the same count of
  that host type; every event page has exactly 1 ArticleDetail, so all 151 still convert). Verified cha/226
  green + localhost matches prod-mirror. **Find in seconds:** for each pattern-based composition, scan
  `_overrides` keys of the *flat* (non-`compId|nodeId`) form against instance ids present in the referenced
  `compositionPattern` + the composition's own slot-section override items — a flat override whose id
  matches neither is dropped content. Cheap offline re-test without a pipeline run: `git archive
  <pre-4580-commit> result/uniform-canvas/{composition,entry,componentPattern} | tar -x -C .temp/…`, then
  run `uniform-transform apply-composition-pattern` against it and diff relocated type counts vs
  pre-conversion.
- **Inline `$block` values are NOT entry references ⇒ a block→`entryIds` conversion placed after
  `remove-unref-entries` emits dangling refs** (validate/publish blocker) — the orphan-entry pruner keeps an
  entry only if something references it by id (`variables.entryId(s)`, `contentReference`); an entry whose
  only consumer is an inline block value (e.g. a `ContentTypeFallbackBlock` carrying its `sourceItem`) gets
  pruned, so a later stage rewriting that block into a multi-entry data resource points at a deleted entry.
  Hit twice: the "Analysis" and "Perspective" `ContentTypeFallback` facets (each referenced by exactly one
  page's inline typeBlock and by no page entry's ContentType field). Fixed by ORDERING: stage
  `4589-apply-relatedcontent-pattern` (the `apply-component-pattern` conversions, spec 036) runs BEFORE the
  remove-unref-entries stage, whose shape-based walker then collects the freshly-written `entryIds` and the
  entries keep themselves alive — this also removes the topics' implicit dependency on page entries
  happening to reference every Topic. Corollary from the same work: a pattern-parameter data resource with
  `ignorePatternParameterDefault: true` makes every instance that doesn't select it a runtime error
  ("Required pattern data resource is not selected" + a `$loop` binding error per page) — omit the flag when
  the pattern's default (empty `entryIds` → empty list → loop renders nothing) is the intended fallback.
  Details in the `cha-apply-component-pattern` memory.
- **A pattern reference's `variant` silently falls back to the pattern's base variant (`Default`)** (NO
  validate/deploy/publish stage gates on it — run stays green while every non-default instance renders the
  wrong variant; same signature as the 4530/4580 data-loss classes) — when `apply-component-pattern`
  (stage `4589`) converts an inline instance into a thin `_pattern` reference, it hoists that instance's
  `parameters`/`dataResources` into the flat `_overrides[instanceId]` channel but originally left the
  **`variant` only inline** on the reference node. Uniform reads a pattern reference's effective variant
  from `_overrides[instanceId].variant` (where the params already live), **not** the inline node — so the
  override was dropped and the instance took the pattern's base variant. The FeaturedCardGrid pattern
  `878317a5` is one shared pattern backing **134 instances across 5 variants** (base variant empty =
  Default); **119 non-Default** instances (75 `threeColumnWide`, 28 `topicListing`, 8 `twoColumn`, 8
  `contentListing`) all rendered Default. Same for RelatedContent `313ca80e`. Root-caused via the one
  hand-authored **known-good** case in the canvas — the seed PromoCard `rail` override carries `variant`
  in **both** inline and `_overrides[id]`. Fixed in the **transformer** (`main` commit `cb2fe6a`):
  `apply-component-pattern` now writes `variant` into `_overrides[instanceId].variant` (kept inline too;
  existing authored value wins, mirroring the parameter merge). No frontend change needed — `variant` is
  Uniform's standard variant mechanism, unlike the `topicsBlock`/`contenttypeBlock` param caveats. Verified
  cha/259 green (validate 0 errors / 5027 files; incremental deploy pushed+published 892 changed
  compositions): 957 pattern-refs carry a variant, **all 957** now have a matching `_overrides.variant`, 0
  missing. **Find in seconds:** scan `composition/*.json` for a `_pattern`-referencing node with an inline
  `variant` whose `_overrides[<node _id>].variant` is absent.
- **Run is green but rendered CONTENT diverges from prod (frontend-side classes)** — validate/deploy/
  publish never gate on what the site renders; `6-tests` (innerText comparison vs the prod mirror) is
  the only gate. First full comparison (cha/266) scored 81.3%; four **`D:\cha-website`** fixes +
  harness corrections took cha/269 to 90.7% (425/535 pages at exactly 100%). The four frontend
  classes, all fixed on `develop` (`78d1d24b4`, `dd4597642`, `5caa9459f`): (1) DetailHero renders
  title-first on the DEFAULT variant only (live prod updated just that template; non-default variants
  keep the scriban breadcrumb-first order) — was 227 pages of reordered text; (2) a dynamic listing
  configured with ONLY a ContentTypes facet (blog/newsroom/safety-watch indexes) rendered empty —
  FeaturedCardGrid gated its fetch on topics alone; (3) RelatedContent with a topic-less datasource
  and RelatedEvents with an empty featuredevents slot rendered nothing — legacy filled both
  dynamically (page-topics fallback / next-upcoming-event query); (4) card eyebrow label — the card's
  own `contenttype` (link target's type) must beat the stage-1001-propagated host-page
  `contenttypeBlock`. Residual ~9% is snapshot staleness (Sitecore export ~2026-06-15 vs live mirror:
  missing post-cutoff items shift listing membership; prod-side edits like removed QUICK TAKES) — only
  a fresh export cures it. Details in the `cha-6-tests-e2e` + `cha-frontend-content-parity` memories.
