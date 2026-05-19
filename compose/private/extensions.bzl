"""Module extension that fetches the canonical compose-spec schema.

Pins both the upstream commit SHA and the file's sha256 so the build
is reproducible without vendoring 1900 lines of JSON into this repo.
The codegen + diff_test cascade picks up whatever changed when the
pin is bumped.

Two lines move when refreshing the spec:
  - `_COMPOSE_SPEC_COMMIT` — pick a commit from compose-spec/compose-spec
  - `_COMPOSE_SPEC_SHA256` — `curl -fsSL <url> | shasum -a 256`
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")

# https://github.com/compose-spec/compose-spec — pinned to a specific
# commit so reproducibility doesn't depend on the upstream master moving.
_COMPOSE_SPEC_COMMIT = "8c28d854433e6efe224f3d1c288b3ab5d873402d"
_COMPOSE_SPEC_SHA256 = "1f91e091f16b2dd50ab8860e02bb391d22df553d91c145eacedb1b6eff9c3f0e"

def _impl(_mctx):
    http_file(
        name = "compose_spec",
        urls = [
            "https://raw.githubusercontent.com/compose-spec/compose-spec/{}/schema/compose-spec.json".format(
                _COMPOSE_SPEC_COMMIT,
            ),
        ],
        sha256 = _COMPOSE_SPEC_SHA256,
        downloaded_file_path = "compose-spec.json",
    )

compose_spec_extension = module_extension(implementation = _impl)
