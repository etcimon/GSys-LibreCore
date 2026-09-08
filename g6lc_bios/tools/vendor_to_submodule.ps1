# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Promote a pristine vendored kernel-spec/ fork into a real git submodule
# WITHOUT re-cloning the working tree.
#
# Why this is not just `git submodule add <url>`: the vendored copies were
# committed into the parent repo with their `.git` removed, so there is no
# commit to pin. Committing the local content instead would produce a gitlink
# SHA that exists only on this machine, and `git clone --recurse-submodules`
# elsewhere would fail with "unable to find <sha>". So this script fetches the
# real upstream history and pins the upstream commit whose *content* matches
# the vendored tree.
#
# Windows checkouts lose the executable bit, so the match is content-only:
# a candidate is accepted when `git diff --numstat` reports no added or
# removed lines (mode-only entries report 0/0 and are ignored).
#
# The script refuses rather than guesses: if no upstream commit matches, it
# reports that and leaves the directory alone, because a local-only pin is
# worse than no submodule.
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$Url,
  [int]$Depth = 400
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Path)) { throw "no such directory: $Path" }
if (Test-Path (Join-Path $Path ".git")) { throw "$Path already has a .git" }

Push-Location $Path
try {
  git init -q
  # Windows drops the exec bit; without this every candidate looks dirty.
  git config core.fileMode false
  git remote add origin $Url
  Write-Host "[$Path] fetching $Url ..."
  git fetch -q origin
  if ($LASTEXITCODE -ne 0) { throw "fetch failed for $Url" }

  $head = (git rev-parse --verify -q origin/HEAD) 2>$null
  if (-not $head) { $head = "origin/main" }

  # Stage the vendored content once so `git diff <candidate>` compares the
  # working tree against each candidate.
  git add -A

  # A candidate matches when nothing is ADDED, MODIFIED or RENAMED relative to
  # it. Pure DELETIONS are tolerated because vendoring ran under the parent
  # repo's ignore rules (e.g. root `.gitignore: build/`), which stripped paths
  # the fork tracks upstream. Those files come back when the submodule is
  # checked out, which is a repair rather than drift. Any added or modified
  # line, by contrast, means the copy is genuinely not this commit.
  $match = $null
  $candidates = git rev-list --max-count=$Depth $head
  foreach ($c in $candidates) {
    $numstat = git diff --numstat --cached --diff-filter=ACMRT $c
    $changed = @($numstat | Where-Object { $_ -and ($_ -notmatch '^0\s+0\s') })
    if ($changed.Count -eq 0) { $match = $c; break }
  }

  # Verifying the tolerance did not hide real drift: every path we are missing
  # must actually be ignored by the parent repo.
  if ($match) {
    $missing = @(git diff --name-only --cached --diff-filter=D $match)
    if ($missing.Count -gt 0) {
      $prefix = (Resolve-Path .).Path
      $repoRoot = (git -C .. rev-parse --show-toplevel 2>$null)
      $unignored = @()
      foreach ($m in $missing) {
        $full = Join-Path $prefix $m
        $rel = $full.Substring($repoRoot.Length + 1).Replace('\', '/')
        git -C $repoRoot check-ignore -q --no-index -- $rel
        if ($LASTEXITCODE -ne 0) { $unignored += $rel }
      }
      if ($unignored.Count -gt 0) {
        Write-Host "[$Path] REFUSED: $($unignored.Count) missing path(s) are NOT parent-ignored, so this is real drift:"
        $unignored | Select-Object -First 10
        exit 5
      }
      Write-Host "[$Path] $($missing.Count) parent-ignored path(s) will be restored by the submodule checkout."
    }
  }

  if (-not $match) {
    Write-Host "[$Path] REFUSED: no upstream commit in the last $Depth of $head matches this content."
    Write-Host "[$Path] nearest tip drift:"
    git diff --stat --cached $head | Select-Object -Last 12
    exit 3
  }

  # Forced, because the vendored files are untracked in this fresh repo and a
  # plain checkout refuses to overwrite them. It is safe precisely because the
  # content comparison above already proved they are byte-identical to $match;
  # the only writes are the parent-ignored paths being restored.
  git checkout -f -q --detach $match
  $dirty = @(git status --porcelain)
  if ($dirty.Count -ne 0) {
    Write-Host "[$Path] REFUSED: tree is dirty at $match after checkout:"
    $dirty | Select-Object -First 12
    exit 4
  }
  Write-Host "[$Path] pinned upstream $match"
}
finally {
  Pop-Location
}
