#!/usr/bin/env python3
"""
presence_algorithms.py

The candidate replacement for the filter chain in
generate_species_presence_data.py, kept apart from it so both can be run over
the same input and compared before anything ships.

THE PROBLEM WITH THE SHIPPED CHAIN
----------------------------------
It filters, then buffers:

    drop cells with <3 records that touch no cell with >=3
    drop disconnected clusters holding <20 records beyond 500 km
    dilate by 1

Every judgement is therefore made on RAW, unbuffered cells, using RECORD
COUNTS. Both halves of that are wrong at a range edge, and the measurements say
so plainly:

  * Spotted bat's run north into BC is four cells holding 1, 1, 2 and 3
    records, separated from the cells at 47N by exactly ONE empty row. Judged
    raw, they touch nothing that clears the floor and die. Buffered first, that
    empty row closes and they are simply part of the main range.
  * The Hawaiian hoary bat is seven cells holding 18 records. The disconnected-
    cluster floor is 20. An entire island population is currently missing from
    the shipped data because it is two records short.

Recording effort is thinnest exactly where a range ends, so a per-cell record
floor is a proxy for survey intensity that we then read as a proxy for absence.

WHAT THIS DOES INSTEAD
----------------------
Niall's ordering — buffer, bridge, then judge:

    1. BUFFER   every observed cell grows by one cell in all directions.
    2. BRIDGE   morphological closing joins what the buffer left just short,
                filling the corridor between them into one mass.
    3. GROUP    flood-fill the mass into groups; a group survives on how many
                real observation cells it contains, not on how many records
                those cells hold.

The order is the fix. Judging AFTER bridging lets a thin edge inherit the
credibility of the range it is attached to, instead of being asked to justify
itself cell by cell — which is precisely what a sparsely-surveyed real edge
cannot do.

WHY THE GROUP TEST COUNTS CELLS AND NOT RECORDS
-----------------------------------------------
Measured against the four cases that decide it:

    Hawaii (LACI, real)      7 seed cells   18 records
    BC run  (EUMA, real)     4 seed cells    7 records
    Bogota  (PIPPIP, junk)   1 seed cell     4 records
    Alaska  (MYGR, junk)     1 seed cell     1 record

Cell count separates those four cleanly at 3, and record count cannot separate
them at all: any floor high enough to kill Bogota's 4 also kills BC's 7.

But cell count ALONE then deleted every island endemic — the Canary Islands
barbastelle, Madeira's grey long-eared bat — because a small archipelago cannot
fill three 1-degree cells no matter how many bats are in it. So a group
survives on EITHER test: enough cells (spread out, thinly recorded) or enough
records (concentrated, well recorded). Both floors have to fail before anything
is dropped. See MIN_GROUP_CELLS and MIN_GROUP_RECORDS.
"""

# NO THIRD-PARTY IMPORTS, DELIBERATELY. generate_species_presence_data imports
# this module, and both it and mvt_lite refuse dependencies on the grounds that
# a build-time tool has to still run in five years on whatever Python is
# installed then. The morphology below is a few set operations over at most
# 64,800 cells, which is nothing — numpy bought speed that was never needed and
# would have put a version-pinned wheel in the path of regenerating the app's
# range data.

# Grid geometry, matching generate_species_presence_data and the app.
CELL_DEGREES = 1.0
ROWS = int(round(180 / CELL_DEGREES))
COLS = int(round(360 / CELL_DEGREES))

# Step 1. Each observation grows by this many cells in every direction. One
# cell is ~111 km, which is both the shipped dilation and the width of the gap
# the Spotted bat's northern run needs closed.
BUFFER_CELLS = 1

# Step 2. Closing radius. Bridges a gap of up to 2x this between buffered
# blobs, so 2 spans ~440 km of unsurveyed ground — deliberately close to the
# shipped NEARBY_CLUSTER_KM of 500, which was sized for the same job (a strait,
# a stretch of unsurveyed coast) and has not misfired.
BRIDGE_CELLS = 2

# Step 3. Observation cells a group needs to be a distribution rather than a
# dot. Three is the measured separation between the real disjunct populations
# (Hawaii 7, BC 4) and the known artefacts (Bogota 1, Alaska 1).
MIN_GROUP_CELLS = 3

# The SECOND way a group can survive, and it is an OR with the cell count, not
# an AND. A group holding this many records is real however little ground it
# covers.
#
# Cell count alone was the first draft of this rule and it was wrong in a way
# only the data showed: it treats "small area" as "not a population", which
# deletes every island endemic. Measured, it dropped the Canary Islands
# barbastelle (2 cells, 37 records), Madeira's grey long-eared bat (2 cells, 28
# records), noctule in Sichuan (1 cell, 33 records) and Nyctinomops in Bahia
# (1 cell, 40 records). The Canaries cannot produce three 1-degree cells; there
# is not that much land.
#
# So the two tests catch two different kinds of evidence, and either suffices:
#
#     cells   a distribution SPREAD OUT but thinly recorded  (BC run, Hawaii)
#     records a distribution CONCENTRATED but well recorded  (Canaries, Madeira)
#
# Only a group that is both tiny in area AND thin in records is dropped, which
# is exactly the profile of a stray record. 20 sits in a wide empty gap in the
# measurements — the artefacts hold 1 and 4 records, the real outposts 28 to 40
# — and is the shipped chain's own MIN_COMPONENT_RECORDS, which was never the
# part of it that misfired.
MIN_GROUP_RECORDS = 20

# The largest group always survives, however thin. A species can be real and
# barely recorded, and dropping its only group turns "we know little about this
# bat" into "this bat is not here" — the app has an honest way to say the first
# (the unknown list) and must not be handed the second by accident.
KEEP_LARGEST_GROUP = True


# --------------------------------------------------------------------------
# Grid primitives
#
# Cells are row-major integer indices, row 0 at the south pole, column 0 at
# -180 degrees — the same encoding the app decodes in
# SpeciesPresenceStore.cellIndex.


def _offsets(radius: int) -> list[tuple[int, int]]:
    return [(d_row, d_col)
            for d_row in range(-radius, radius + 1)
            for d_col in range(-radius, radius + 1)]


def _neighbours(index: int, offsets: list[tuple[int, int]]):
    """Cells around `index`, wrapping in longitude but NOT in latitude.

    Longitude wraps because the antimeridian is a seam in the indexing, not in
    the world. Latitude must not: there is no cell north of the north pole, and
    letting it wrap would join Arctic cells to Antarctic ones. A neighbour off
    the top or bottom yields None, which both callers read as "not occupied".
    """
    row, col = divmod(index, COLS)
    for d_row, d_col in offsets:
        r = row + d_row
        yield None if not (0 <= r < ROWS) else r * COLS + ((col + d_col) % COLS)


def dilate(cells: set[int], radius: int) -> set[int]:
    """Grow by `radius` cells, square (8-neighbour) structuring element."""
    if radius <= 0:
        return set(cells)
    offsets = _offsets(radius)
    grown: set[int] = set()
    for index in cells:
        for neighbour in _neighbours(index, offsets):
            if neighbour is not None:
                grown.add(neighbour)
    return grown


def erode(cells: set[int], radius: int) -> set[int]:
    """Keep only cells whose whole neighbourhood is occupied."""
    if radius <= 0:
        return set(cells)
    offsets = _offsets(radius)
    kept: set[int] = set()
    for index in cells:
        if all(neighbour is not None and neighbour in cells
               for neighbour in _neighbours(index, offsets)):
            kept.add(index)
    return kept


def close(cells: set[int], radius: int) -> set[int]:
    """Fill gaps up to 2*radius wide without growing the outer boundary.

    Dilate then erode. The dilation floods the gaps between nearby blobs; the
    erosion pulls the outer edge back to where it started, so what remains
    added is the bridge and nothing else.

    Unioned with the input because that guarantee is only exact away from the
    latitude edges, where a neighbour off the pole reads as empty and the
    erosion would nibble. Closing is meant to be purely additive, so this makes
    it so.
    """
    if radius <= 0:
        return set(cells)
    return erode(dilate(cells, radius), radius) | cells


def components(cells: set[int]) -> list[set[int]]:
    """Connected groups of occupied cells, 8-neighbour, longitude wrapping."""
    offsets = [o for o in _offsets(1) if o != (0, 0)]
    remaining = set(cells)
    groups: list[set[int]] = []
    while remaining:
        start = remaining.pop()
        group = {start}
        stack = [start]
        while stack:
            for neighbour in _neighbours(stack.pop(), offsets):
                if neighbour is not None and neighbour in remaining:
                    remaining.discard(neighbour)
                    group.add(neighbour)
                    stack.append(neighbour)
        groups.append(group)
    return groups


# --------------------------------------------------------------------------
# The pipeline


def build_presence(raw: dict[int, int], *,
                   buffer_cells: int = BUFFER_CELLS,
                   bridge_cells: int = BRIDGE_CELLS,
                   min_group_cells: int = MIN_GROUP_CELLS,
                   min_group_records: int = MIN_GROUP_RECORDS,
                   keep_largest_group: bool = KEEP_LARGEST_GROUP) -> dict:
    """Raw density cells -> presence cells, plus every intermediate.

    The intermediates are returned rather than discarded because the point of
    this module is to be argued with: `groups` carries the keep/drop verdict
    and the numbers behind it for each group, so a surprising map can be traced
    to the decision that produced it without re-running anything.
    """
    seeds = set(raw)
    result = {
        "seeds": seeds,
        "total_records": sum(raw.values()),
        "buffered": set(),
        "mass": set(),
        "kept": set(),
        "dropped": set(),
        "groups": [],
    }
    if not seeds:
        return result

    # 1. Buffer.
    buffered = dilate(seeds, buffer_cells)
    result["buffered"] = buffered

    # 2. Bridge into one mass.
    mass = close(buffered, bridge_cells)
    result["mass"] = mass

    # 3. Judge each group by the observations inside it.
    groups = components(mass)
    scored = []
    for group in groups:
        inside = group & seeds
        scored.append({
            "cells": group,
            "seed_cells": len(inside),
            "records": sum(raw[i] for i in inside),
            "mass_cells": len(group),
        })
    # Largest by observation cells, not by area: a big empty bridged blob is
    # not more credible than a compact well-recorded one.
    scored.sort(key=lambda g: (g["seed_cells"], g["records"]), reverse=True)

    for rank, group in enumerate(scored):
        if rank == 0 and keep_largest_group:
            group["kept"] = True
            group["why"] = "largest group"
        elif group["seed_cells"] >= min_group_cells:
            group["kept"] = True
            group["why"] = f"{group['seed_cells']} observation cells (spread)"
        elif group["records"] >= min_group_records:
            # The island-endemic route: too small to spread, well enough
            # recorded to be believed anyway.
            group["kept"] = True
            group["why"] = (f"{group['records']} records in "
                            f"{group['seed_cells']} cell"
                            f"{'' if group['seed_cells'] == 1 else 's'} (concentrated)")
        else:
            group["kept"] = False
            group["why"] = (f"{group['seed_cells']} cell"
                            f"{'' if group['seed_cells'] == 1 else 's'} and "
                            f"{group['records']} records — under both floors")
        (result["kept"] if group["kept"] else result["dropped"]).update(group["cells"])
        result["groups"].append(group)

    return result
