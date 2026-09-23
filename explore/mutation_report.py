"""How every mutation harness reports what it found.

Shared for one reason, and it is a measured one rather than a tidiness one. All
five harnesses had grown the same summary block, and all five had the same bug
in it: a mutation whose anchor no longer matched the source was appended to the
survivor list and reported as though the tests had failed to catch it.

That is not a cosmetic mislabel. A survivor and a stale anchor call for opposite
responses -- write a test, versus fix the script -- and the merged number hides
the second behind the first. Measured in mutate_panel.py: #30 and #31 moved
eight of 134 anchors between them, every one was reported as a survivor for two
merges, and the tests that catch all eight were present and passing the whole
time. Nothing anywhere said the lines had stopped being tested.

Only the reporting lives here. Each harness keeps its own mutation list, its own
targets and its own test command, because those are genuinely different between
them and a runner general enough to cover all five would be harder to read than
the five loops it replaced.
"""

from __future__ import annotations


def note_stale(description: str) -> None:
    """Say that a mutation never ran, in the harness's per-mutation output."""
    print(f"STALE  {description}\n       (anchor not found -- fix the script)")


def summarise(stale: list[str], survivors: list[str], total: int) -> int:
    """Print the closing report and return the exit code the harness should use.

    Stale anchors come first and are counted apart from survivors. A harness
    that has been reporting a comfortable number may start failing outright the
    first time this runs -- that is the point, and the number it was reporting
    before was not real.
    """
    print()

    if stale:
        print(f"{len(stale)} of {total} mutations never ran:")
        for s in stale:
            print(f"  - {s}")
        print()

    if survivors:
        print(f"{len(survivors)} of {total} mutations survived:")
        for s in survivors:
            print(f"  - {s}")

    if stale or survivors:
        return 1

    print(f"All {total} mutations caught.")
    return 0
