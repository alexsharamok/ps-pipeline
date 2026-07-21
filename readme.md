# Pipeline scripts

## `Run.ps1`

Template wrapper that resolves `$(NAME)` tokens from `.env` and runs PowerShell scripts.

### What it does

1. Loads `.env` from the script directory (or `-EnvPath`).
2. Resolves cross-references inside `.env` values (e.g. `Root=$(HomeDir)/cha`, `DataDir=$(Root)/data`). Cycles abort with the chain shown.
3. User's pre-existing process env wins over `.env` (running with `$env:ABC='1'` keeps `ABC=1` even if `.env` has `ABC=2`).
4. Exports resolved values into the process environment so scripts and child processes see them via `$env:X` or `getenv("X")`. State is restored on exit so the calling shell isn't polluted.
5. Substitutes `$(NAME)` tokens (including dotted names like `$(Release.ReleaseName)`) in each script before running.
6. Halts on error: the rendered script runs with `$ErrorActionPreference = 'Stop'`, so non-zero exits and unhandled errors stop the pipeline immediately.

### Strict vs lenient

- Scripts containing the string `Enforce all env vars` (typically as a comment marker) require every referenced `$(NAME)` to exist in `.env`. Missing → halt before running.
- Scripts without the marker run in lenient mode: missing tokens are replaced with empty strings, with a yellow warning listing them.

### Modes

- **Single script**: `Run.ps1 -ScriptPath .\02-foo.ps1`
- **Pipeline**: `Run.ps1` (no args) — runs every `NN*.ps1` in the current directory in alphabetical order, with timing and a separator banner per step.

### Selecting steps

- `-StartAt 04` or `-StartAt git` — start from a step (number prefix or substring match)
- `-StopAfter 06` or `-StopAfter tune` — stop after a step
- `-StartAt 04 -StopAfter 06` — slice a range

Numeric arg matches the leading prefix only (`-StartAt 03` skips `02-ababa03.ps1`). Non-numeric arg falls back to case-insensitive substring search on the filename.

### Resume

Before each pipeline step, `Run.ps1` writes `.p/current-state.json` (JSON: `{ "currentPipelineStageIndex": "NN" }`).

`Run.ps1 -Resume` reads that file and resumes from the recorded step. Useful after a failure: fix the failing step and re-run with `-Resume`.

`-Resume` and `-StartAt` are mutually exclusive.

### Git branching

Each pipeline run gets a fresh attempt number (`lastAttemptNumber + 1`, persisted in `.p/current-state.json`) and produces one branch per stage under `runs/<project>/<attempt>/<stage>`.

- **Before any `NN*.ps1` runs**: checks out `runs/<project>/<attempt>/00-start`, then `git reset --hard` and `git clean -f` to start each attempt from a clean working tree.
- **For each stage** (two-commit-then-amend pattern, so the commit message reflects the final outcome):
  1. **Before running**: an empty per-stage log is written at `z_stdout/<folder>--<stage>.log`, then `git add z_stdout` + commit with subject `<folder>/<stage> (<project>/<attempt>) - RUNNING`. Most stages stage only the empty `.log` file at this point.
  2. **Run the stage** (its output streams into that same `.log` file).
  3. **After running**: `git add *` + `git commit --amend --allow-empty -m '<folder>/<stage> (<project>/<attempt>) - <suffix>'`. The amend folds the stage's working-tree changes into the RUNNING commit and rewrites the subject. `<suffix>` is `no changes`, `N changed`, `N new`, or `X changed, Y new` (counts ignore `z_stdout/` entries).

  If the stage fails (non-zero exit or a `Must change/create files` assertion), the amend never happens and the `… - RUNNING` commit remains as a marker.

`<project>` is the working directory's leaf name (e.g. `cha`).

## `EditPipeline.ps1`

Inserts a new stage into the pipeline, shifting later steps.

```
EditPipeline.ps1 -InsertStage 03-git-checkout
```

Behavior:

1. Parses the leading number from the argument (`03`).
2. Renames every existing `NN-*.ps1` whose prefix is `>= 03`, incrementing each prefix by 1. Renames in descending order so there are no collisions (`05→06` first, then `04→05`, then `03→04`).
3. Creates `03-git-checkout.ps1` with template content:
   ```
   # "Enforce all env vars"

   echo 'todo'
   ```

If `03-git-checkout.ps1` already exists, the script aborts before renaming anything.
