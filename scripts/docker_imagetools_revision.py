#!/usr/bin/env python3
"""Extract the OCI revision label from docker buildx imagetools JSON.

`docker buildx imagetools inspect --format '{{json .}}'` has changed shape
across buildx versions. Some versions put labels at Image.Labels, while newer
inspect output can nest them under image.config.Labels.  The release workflow
uses this helper so Docker :latest monotonicity checks do not silently miss the
revision label because of JSON key casing or nesting drift.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Iterable
from typing import Any

REVISION_LABEL = "org.opencontainers.image.revision"


def _label_dicts(node: Any) -> Iterable[dict[str, Any]]:
    """Yield every labels mapping found in a buildx inspect object."""
    if isinstance(node, dict):
        for key in ("Labels", "labels"):
            labels = node.get(key)
            if isinstance(labels, dict):
                yield labels
        for value in node.values():
            yield from _label_dicts(value)
    elif isinstance(node, list):
        for item in node:
            yield from _label_dicts(item)


def extract_revision(metadata: Any) -> str:
    """Return the first non-empty OCI revision label from inspect metadata."""
    for labels in _label_dicts(metadata):
        revision = labels.get(REVISION_LABEL)
        if isinstance(revision, str) and revision.strip():
            return revision.strip()
    return ""


def main() -> int:
    metadata = json.load(sys.stdin)
    print(extract_revision(metadata))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
