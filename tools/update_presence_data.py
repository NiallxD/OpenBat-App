#!/usr/bin/env python3
"""
update_presence_data.py

Does the whole "there's a new species, publish its range" runbook in one run:
pull the field guide, regenerate, verify, bump the version, publish to the
guide repo. The steps and their order are the ones written out in the app's
CLAUDE.md; this file exists so they can't be done in the wrong order or half
done, not to replace reading them.

    pull FieldGuide -> generate -> verify -> compare -> bump -> commit -> push

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
It does not touch the app repo. The bundled copy in `OpenBat/FieldGuide/` is a
cold-install seed refreshed at release time, not on every regeneration — the
same way the bundled SpeciesGuideData.json already lags the guide repo. The one
app-repo change this script makes is the DATA_VERSION constant in the
generator, which it prints a reminder to commit.

THE THREE THINGS THAT STOP IT
-----------------------------
  * the generator reports failures (a name lookup or density fetch died). A
    partial file is how the live GBIF path went wrong in the first place.
  * verify_presence_data.py fails. A regenerated file that no longer knows
    where a bat lives should never reach phones because a script was in a
    hurry. The built file is left in tools/ to look at; nothing is copied.
  * a species that HAD a range comes back with none. That is the regression
    shape the `unknown` list was invented to make visible, and no run should
    publish it silently. Species that are newly unknown are only warned about:
    a guide entry for a bat with 12 GBIF records is legitimately unknown, and
    that is the file saying "no opinion", which is the correct answer.

NO-OP RUNS DON'T PUBLISH
------------------------
`updatedAt` changes on every run, so byte-comparing the output would call every
run a change. The comparison here ignores `updatedAt` and `dataVersion`, so a
re-run that GBIF has nothing new for bumps nothing and pushes nothing — which
is what makes it safe to run whenever you wonder rather than only when you know.

Usage:
    python3 -u tools/update_presence_data.py
    python3 -u tools/update_presence_data.py --dry-run   # stop before publishing
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
GENERATOR = ROOT / "generate_species_presence_data.py"
VERIFIER = ROOT / "verify_presence_data.py"
BUILT = ROOT / "SpeciesPresenceData.json"

# The guide repo is a sibling clone of the app repo, which is the same layout
# the generator already assumes for reading SpeciesGuideData.json.
GUIDE_REPO = ROOT.parent.parent / "FieldGuide"
TRACKED_NAME = "SpeciesPresenceData.json"
PUBLISHED = GUIDE_REPO / TRACKED_NAME

# Fields that differ between two runs of identical data.
VOLATILE = ("dataVersion", "updatedAt")

DATA_VERSION_RE = re.compile(r"^(DATA_VERSION\s*=\s*)(\d+)\s*$", re.MULTILINE)


def run(cmd: list[str], cwd: Path | None = None) -> int:
    """Run a command with its output going straight to ours."""
    print(f"\n$ {' '.join(cmd)}", flush=True)
    return subprocess.call(cmd, cwd=str(cwd) if cwd else None)


def git(*args: str, check: bool = True) -> str:
    """Run git in the guide repo and return its stdout."""
    result = subprocess.run(
        ["git", *args], cwd=str(GUIDE_REPO),
        capture_output=True, text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def substantive(path: Path) -> dict:
    """The file's contents minus the fields that change on every run."""
    data = json.loads(path.read_text())
    return {k: v for k, v in data.items() if k not in VOLATILE}


def ranged_codes(data: dict) -> set[str]:
    return set(data.get("presence", {}))


def source_data_version() -> int:
    match = DATA_VERSION_RE.search(GENERATOR.read_text())
    if not match:
        raise RuntimeError(f"no DATA_VERSION line found in {GENERATOR.name}")
    return int(match.group(2))


def set_versions(version: int) -> None:
    """Write the new version to both the generator constant and the built file.

    Both, because they are two records of the same fact: the constant is what
    the next run starts from, the file is what the app reads. Letting them
    drift would make the next run's bump land on a number already shipped.
    """
    text = GENERATOR.read_text()
    GENERATOR.write_text(DATA_VERSION_RE.sub(rf"\g<1>{version}", text, count=1))

    # Rewritten with the generator's own serialisation so the only difference
    # from what it wrote is the number.
    data = json.loads(BUILT.read_text())
    data["dataVersion"] = version
    BUILT.write_text(json.dumps(data, separators=(",", ":"), sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true",
                        help="pull, generate and verify, then report what would "
                             "be published without writing to the guide repo")
    args = parser.parse_args()

    if not (GUIDE_REPO / ".git").exists():
        print(f"error: no field guide clone at {GUIDE_REPO}. This script "
              f"publishes to it, so it has to be there.", file=sys.stderr)
        return 1

    # A locally modified presence file means someone edited by hand or a
    # previous run half-finished. Either way the pull below could conflict and
    # the commit below would sweep up work this script didn't do.
    if git("status", "--porcelain", "--", TRACKED_NAME):
        print(f"error: {TRACKED_NAME} has uncommitted changes in {GUIDE_REPO}. "
              f"Commit or discard them first — this run would overwrite them.",
              file=sys.stderr)
        return 1

    # 1. Fresh guide. The generator reads the sibling clone's
    #    SpeciesGuideData.json, so a stale checkout silently generates against
    #    yesterday's species list — the exact thing this script is for.
    if run(["git", "pull", "--ff-only"], cwd=GUIDE_REPO) != 0:
        print("error: couldn't fast-forward the field guide repo.", file=sys.stderr)
        return 1

    before = substantive(PUBLISHED) if PUBLISHED.exists() else None

    # 2. Generate. Unbuffered so a redirected run prints as it goes.
    if run([sys.executable, "-u", str(GENERATOR)]) != 0:
        print("\nerror: generation failed — see the failures above. Nothing "
              "published; the partial file is in tools/.", file=sys.stderr)
        return 1

    # 3. Verify against places we know real bats are and aren't.
    if run([sys.executable, str(VERIFIER), str(BUILT)]) != 0:
        print(f"\nerror: verification failed. Nothing published. The built file "
              f"is at {BUILT} to look at — render_range_maps.py draws the "
              f"before/after if the question is which filter cut it.",
              file=sys.stderr)
        return 1

    after = substantive(BUILT)

    # 4. A species that had a range and now has none is a regression, not news.
    if before is not None:
        lost = sorted(ranged_codes(before) - ranged_codes(after))
        if lost:
            print(f"\nerror: {len(lost)} species had a range and now have none: "
                  f"{', '.join(lost)}\nNothing published. Check the generator's "
                  f"output above for the taxonomy lines — a name that resolved "
                  f"before and doesn't now needs a TAXON_ALIASES entry.",
                  file=sys.stderr)
            return 1

        gained = sorted(ranged_codes(after) - ranged_codes(before))
        if gained:
            print(f"\nnew ranges: {', '.join(gained)}")

        # Newly unknown is a warning, not a stop: it is the file correctly
        # saying "no opinion" about a bat GBIF barely knows.
        newly_unknown = sorted(set(after.get("unknown", [])) - set(before.get("unknown", [])))
        if newly_unknown:
            print(f"warning: no range data for {', '.join(newly_unknown)} — the "
                  f"app will hold no opinion about them. Fine for a sparse "
                  f"species; check the taxonomy lines above if it isn't one.")

    if before == after:
        print("\nno change: GBIF has nothing new for any species. Version not "
              "bumped, nothing published.")
        return 0

    version = max(source_data_version(), json.loads(PUBLISHED.read_text())["dataVersion"]
                  if PUBLISHED.exists() else 0) + 1

    if args.dry_run:
        print(f"\n--- dry run --- would publish as dataVersion {version}: "
              f"{len(after.get('presence', {}))} species with ranges, "
              f"{len(after.get('unknown', []))} unknown.")
        return 0

    # 5. Bump and publish.
    set_versions(version)
    shutil.copyfile(BUILT, PUBLISHED)

    git("add", "--", TRACKED_NAME)
    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    if run(["git", "commit", "-m",
            f"Update species presence data to dataVersion {version}"],
           cwd=GUIDE_REPO) != 0:
        print("error: commit failed.", file=sys.stderr)
        return 1
    if run(["git", "push", "origin", branch], cwd=GUIDE_REPO) != 0:
        print("error: push failed. The commit is made — push it yourself.",
              file=sys.stderr)
        return 1

    print(f"\npublished dataVersion {version} to {branch}. Installed apps will "
          f"pick it up without an update.")
    print(f"Still yours to commit: DATA_VERSION = {version} in "
          f"{GENERATOR.name} (app repo), and the bundled seed copy in "
          f"OpenBat/FieldGuide/ if a release is close.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
