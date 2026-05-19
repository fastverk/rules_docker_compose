# rules_docker_compose

Bazel rules that build a Docker Compose project from typed
service / volume / network targets scattered across your code graph.

The user-facing Starlark surface mirrors the [compose-spec](https://github.com/compose-spec/compose-spec)
**exhaustively** — every property the spec accepts is a typed Bazel
`attr.*`. There's no hand-curated subset and no allowlist of deferred
fields. Drift is impossible by construction:

- The canonical schema is fetched on-demand from
  [`compose-spec/compose-spec`](https://github.com/compose-spec/compose-spec)
  at a commit + sha256 pinned in
  [`compose/private/extensions.bzl`](compose/private/extensions.bzl).
- [`rules_jsonschema`](https://github.com/fastverk/rules_jsonschema)'s
  `jsonschema_rust_library` emits a Rust library (`compose_types`) of typed
  bindings from that schema via [`typify`](https://crates.io/crates/typify).
- The same repo's `jsonschema_starlark_codegen` emits
  [`compose/compose_rules.bzl`](compose/compose_rules.bzl) —
  one `rule()` per schema definition, typed `attr.*` per schema property.
- The Rust `compose-gen` binary decodes per-target JSON shards into
  the typed `Service`/`Volume`/`Network` structs (`#[serde(deny_unknown_fields)]`
  rejects anything the schema doesn't declare) and emits canonical YAML.

The hand-written part of the repo is small and scoped to things the
schema can't describe: graph aggregation, OCI digest resolution,
and `bazel run` wrappers around `docker compose`. Both codegen
passes go through rules_jsonschema's plugin contract — see that
repo's [`plugin_contract.md`](https://github.com/fastverk/rules_jsonschema/blob/main/jsonschema/plugin_contract.md)
if you want to swap a plugin for one of your own.

## What ships

- **rules** (re-exported by [compose/defs.bzl](compose/defs.bzl)):
  - `docker_compose_service` / `_volume` / `_network` — typed rules
    generated from the compose-spec; see
    [docs/compose_rules.md](docs/compose_rules.md) for the full attr list.
  - `docker_compose` — collects shards from `deps` and renders one
    canonical `compose.yaml`.
  - `docker_compose_oci_image_ref` — resolves an OCI image layout to
    `<repo>@sha256:<digest>` at build time and overrides a service's
    `image:` in the rendered output.
  - `docker_compose_up` / `_down` — `bazel run` wrappers around
    `docker compose -f <generated> {up,down}`.
- **providers**: `ComposeServiceInfo`, `ComposeVolumeInfo`,
  `ComposeNetworkInfo`, `ComposeProjectInfo`, `ComposeServiceImageRefInfo`.

Reference docs ([docs/defs.md](docs/defs.md), [docs/compose_rules.md](docs/compose_rules.md))
are stardoc-generated, committed to source, and diff_tested.

## Install

`.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/fastverk/bazel-registry/main/
common --registry=https://bcr.bazel.build/
```

`MODULE.bazel`:

```python
bazel_dep(name = "rules_docker_compose", version = "0.1.0")
```

`rules_jsonschema`, `rules_rust`, and a Rust toolchain are pulled in
transitively.

## Quick start

```python
load(
    "@rules_docker_compose//compose:defs.bzl",
    "docker_compose",
    "docker_compose_network",
    "docker_compose_service",
    "docker_compose_up",
    "docker_compose_volume",
)

docker_compose_network(name = "appnet", driver = "bridge")
docker_compose_volume(name = "cache")

docker_compose_service(
    name = "web",
    image = "nginx:1.27",
    ports = ["8080:80"],
    networks = ["appnet"],
    depends_on = ["redis"],
    restart = "unless-stopped",
    environment = {"NGINX_HOST": "example.local"},
)

docker_compose_service(
    name = "redis",
    image = "redis:7",
    networks = ["appnet"],
    volumes = ["cache:/data"],
    # Complex nested objects (build, healthcheck, deploy, …) are
    # JSON-encoded — the Rust shard reader parses them straight into
    # the typed schema model.
    healthcheck = json.encode({
        "test": ["CMD", "redis-cli", "ping"],
        "interval": "10s",
        "retries": 3,
    }),
)

docker_compose(
    name = "stack",
    project_name = "myapp",
    deps = [":appnet", ":cache", ":redis", ":web"],
    out = "compose.yaml",
)

docker_compose_up(name = "stack.up", project = ":stack")
```

`bazel build //path:stack` produces `bazel-bin/path/compose.yaml`.
`bazel run //path:stack.up -- -d` cd's to the workspace root and runs
`docker compose -f bazel-bin/path/compose.yaml up -d`, so relative
bind-mounts resolve against your source tree.

## Attr ergonomics

Most compose-spec properties type cleanly:

| Spec shape | Bazel attr | Example |
|---|---|---|
| `string` | `attr.string` | `image = "nginx:1.27"` |
| `enum` of strings | `attr.string(values=...)` | `restart = "unless-stopped"` |
| `boolean` (or `[boolean, string, object]` union) | `attr.bool` | `init = True`, `external = True` |
| `integer` / `number` | `attr.int` | |
| `[number, string]` union | `attr.string` | `shm_size = "256m"` |
| Array of strings (incl. `oneOf [string, object]` short-form) | `attr.string_list` | `ports = ["8080:80"]` |
| Object with string-valued props | `attr.string_dict` | `labels = {"k": "v"}` |
| Compose-spec's `list_or_dict` shape | `attr.string_dict` | `environment = {"FOO": "bar"}` |
| Nested object (`build`, `healthcheck`, `deploy`, …) | `attr.string` taking JSON | `build = json.encode({...})` |

[docs/compose_rules.md](docs/compose_rules.md) lists every attr.

## OCI integration

`docker_compose_oci_image_ref` resolves an OCI image layout to a
digest-pinned reference at build time:

```python
load("@rules_oci//oci:defs.bzl", "oci_image")
load(
    "@rules_docker_compose//compose:defs.bzl",
    "docker_compose_oci_image_ref",
    "docker_compose_service",
    "docker_compose",
)

oci_image(name = "worker_image", ...)

docker_compose_service(
    name = "worker",
    # image left unset — supplied at build time via image_ref below.
    command = ["./worker"],
)

docker_compose_oci_image_ref(
    name = "worker_image_ref",
    service_name = "worker",
    oci_image = ":worker_image",
    oci_repo = "ghcr.io/myorg/worker",
)

docker_compose(
    name = "stack",
    deps = [":worker", ":worker_image_ref"],
    out = "compose.yaml",
)
```

The rendered `compose.yaml` will pin `worker.image` to
`ghcr.io/myorg/worker@sha256:<digest>`, where the digest is read from
the OCI layout's `index.json` at build time. Whoever runs
`docker compose up` is guaranteed to pull exactly what Bazel built.

Push the image separately (e.g. via `@rules_oci`'s `oci_push`) so the
registry actually has it at the resolved digest.

## How drift is controlled

The schema is fetched by a Bazel module extension pinned in
[compose/private/extensions.bzl](compose/private/extensions.bzl)
(commit SHA + sha256). Two codegen passes consume it on every build:

1. **typify** (`jsonschema_rust_library`) generates typed Rust bindings.
   Removing a field upstream surfaces as a Rust compile error.
2. **`schema_to_starlark`** (`jsonschema_starlark_codegen`) generates
   typed Bazel rule definitions. The generated `.bzl` is committed,
   and `//compose:compose_rules_up_to_date` re-runs codegen on
   every CI build to detect drift.

Adding a typed Bazel attr for a new spec field is **zero** code change
beyond bumping the pin: typify picks up the new struct field,
`schema_to_starlark` emits the new `attr.*`, and the diff_test fails
until you commit the regenerated `compose_rules.bzl`.

To bump the spec:

```sh
# 1. Pick a commit from https://github.com/compose-spec/compose-spec
# 2. Edit _COMPOSE_SPEC_COMMIT + _COMPOSE_SPEC_SHA256 in
#    compose/private/extensions.bzl
#    (compute the sha256 with: curl -fsSL <url> | shasum -a 256)
# 3. Re-run codegen + docs:
bazel run //compose:update_compose_rules
bazel run //docs:update
bazel test //...
```

Both update targets are
[`write_source_files`](https://github.com/fastverk/rules_jsonschema/blob/main/util/write_source_files.bzl)
instances — pure Starlark, no hand-written shell scripts.

The schema itself is never copied into this repo — Bazel fetches it
from GitHub on first build and caches it like any other external dep.

## Compatibility

- **Bazel**: 7.4+, bzlmod required (tested on 9.1).
- **Rust**: 1.88+ (transitive deps need stabilised `let-chains`).
- **docker compose**: v2 plugin (`docker compose`, not `docker-compose`).

### Cargo-direct builds

The `compose-gen` crate depends on `compose_types`, a `rust_library`
materialised by Bazel's `jsonschema_rust_library` rule at build time. Plain
`cargo build` / `cargo clippy` from the workspace root cannot resolve
that import — Cargo never sees the schema → Rust pipeline. Use Bazel
for builds and tests; for IDE integration, generate a rust-analyzer
project from Bazel via
[`@rules_rust//tools/rust_analyzer:gen_rust_project`](https://bazelbuild.github.io/rules_rust/rust_analyzer.html).

`rules_jsonschema`'s own tools (`schema_to_rust`, `schema_to_starlark`)
have no Bazel-only deps, so cargo works for those if you're hacking on
the codegen.

## Testing

```sh
bazel test //...
```

Six tests, all hermetic:

| Target | What it covers |
|---|---|
| `//compose/private/compose_gen:compose_gen_test` | 12 Rust unit tests — YAML normalisation, OCI image-ref resolution, service-image override, shard decoding |
| `//compose:compose_rules_up_to_date` | schema_to_starlark output is fresh against the committed `.bzl` |
| `//docs:defs_doc_up_to_date` + `//docs:compose_rules_doc_up_to_date` | stardoc freshness |
| `//examples/smoke:stack_yaml_up_to_date` | end-to-end smoke golden |
| `//examples/coverage:stack_yaml_up_to_date` | end-to-end coverage golden (build, healthcheck, profiles, OCI refs, …) |

## License

MIT.
