from pathlib import Path


WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "docker-publish.yml"


def _manifest_script() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    start = text.index("      - name: Create manifest list and push")
    end = text.index("      - name: Inspect image", start)
    return text[start:end]


def test_main_push_publishes_main_tag_without_moving_latest() -> None:
    script = _manifest_script()
    non_release_branch = script.split("\n          else\n", 1)[1].split("          fi\n", 1)[0]

    assert '-t "${IMAGE_NAME}:main"' in non_release_branch
    assert "${IMAGE_NAME}:latest" not in non_release_branch


def test_release_latest_update_is_guarded_by_current_registry_latest_revision() -> None:
    script = _manifest_script()
    release_branch = script.split('if [ "${{ github.event_name }}" = "release" ]; then\n', 1)[1].split(
        "\n          else\n",
        1,
    )[0]

    assert '-t "${IMAGE_NAME}:${TAG}"' in release_branch
    assert '-t "${IMAGE_NAME}:latest"' in release_branch
    assert 'docker buildx imagetools inspect "${IMAGE_NAME}:latest"' in release_branch
    assert "org.opencontainers.image.revision" in release_branch
    assert 'merge-base --is-ancestor "$latest_revision" "$tag_commit"' in release_branch
