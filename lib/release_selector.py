#!/usr/bin/env python3
"""Select the newest IpponTipp tag for a deployment channel."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Any

CHANNEL_PATTERNS = {
    "release-candidate": re.compile(
        r"^release/(?P<major>0|[1-9][0-9]*)\."
        r"(?P<minor>0|[1-9][0-9]*)\."
        r"(?P<patch>0|[1-9][0-9]*)-rc\."
        r"(?P<prerelease>0|[1-9][0-9]*)$"
    ),
    "production": re.compile(
        r"^release/(?P<major>0|[1-9][0-9]*)\."
        r"(?P<minor>0|[1-9][0-9]*)\."
        r"(?P<patch>0|[1-9][0-9]*)$"
    ),
}


class NoMatchingRelease(RuntimeError):
    """Raised when a channel has no deployable tag."""


class TagNotOnMaster(RuntimeError):
    """Raised when a selected tag does not resolve to a commit on master."""


@dataclass(frozen=True)
class Release:
    tag: str
    version: str
    sha: str
    version_tuple: tuple[int, ...]

    def as_dict(self) -> dict[str, str]:
        return {"sha": self.sha, "tag": self.tag, "version": self.version}


def select_release(tags: list[dict[str, Any]], channel: str) -> Release:
    try:
        pattern = CHANNEL_PATTERNS[channel]
    except KeyError as exc:
        raise ValueError(f"Unsupported deployment channel: {channel}") from exc

    releases = []
    for tag in tags:
        name = tag.get("name")
        sha = tag.get("commit", {}).get("sha")
        if not isinstance(name, str) or not isinstance(sha, str):
            continue
        match = pattern.fullmatch(name)
        if match is None:
            continue
        core_version = tuple(
            int(match.group(part)) for part in ("major", "minor", "patch")
        )
        prerelease = match.groupdict().get("prerelease")
        if prerelease is None:
            version = ".".join(str(part) for part in core_version)
            version_tuple = core_version
        else:
            prerelease_number = int(prerelease)
            version = (
                f"{'.'.join(str(part) for part in core_version)}-rc.{prerelease_number}"
            )
            version_tuple = (*core_version, prerelease_number)
        releases.append(
            Release(
                tag=name,
                version=version,
                sha=sha,
                version_tuple=version_tuple,
            )
        )

    if not releases:
        raise NoMatchingRelease(f"No release tag matches channel {channel!r}")

    return max(releases, key=lambda release: release.version_tuple)


def assert_master_contains(comparison: dict[str, Any], candidate_sha: str) -> None:
    merge_base_sha = comparison.get("merge_base_commit", {}).get("sha")
    if merge_base_sha != candidate_sha:
        raise TagNotOnMaster(
            f"Selected commit {candidate_sha} is not reachable from master"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--channel", choices=sorted(CHANNEL_PATTERNS))
    operation.add_argument("--assert-master-contains", metavar="SHA")
    arguments = parser.parse_args()

    try:
        payload = json.load(sys.stdin)
        if arguments.assert_master_contains:
            if not isinstance(payload, dict):
                raise TypeError("GitHub compare response must be a JSON object")
            assert_master_contains(payload, arguments.assert_master_contains)
            return 0

        if not isinstance(payload, list):
            raise TypeError("GitHub tag response must be a JSON array")
        release = select_release(payload, arguments.channel)
    except (
        json.JSONDecodeError,
        NoMatchingRelease,
        TagNotOnMaster,
        TypeError,
        ValueError,
    ) as exc:
        print(f"release-selector: {exc}", file=sys.stderr)
        return 2

    json.dump(release.as_dict(), sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
