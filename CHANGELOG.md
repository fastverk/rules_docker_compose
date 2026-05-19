# Changelog

All notable changes to rules_docker_compose. The format is loosely
[Keep a Changelog](https://keepachangelog.com/) — version headers
mirror the published bazel-registry entries.

## 0.2.3 — CI + CHANGELOG infrastructure

- `.github/workflows/ci.yml`: `bazel test //...` on ubuntu +
  macos, plus a buildifier lint job.
- `CHANGELOG.md` (this file) — backfills v0.2.0 / v0.2.1 / v0.2.2
  notes that were previously only in the git log.
- No API changes.

## 0.2.2 — `config_mounts` + `secret_mounts` on the service façade

- Adds `label_keyed_string_dict` variants for mounting configs +
  secrets at specific in-container paths (the existing `configs:` /
  `secrets:` label_list attrs only support the compose-spec short
  form, which mounts at `/<name>` / `/run/secrets/<name>` — fine for
  most cases but not for loki/prometheus/promtail/otel/tempo).
- `config_mounts = {":loki_config": "/etc/loki/local-config.yaml"}`
  emits the extended `configs: [{source, target}]` form.
- Transitive aspect walks the new attrs so root-level `deps` still
  picks up the underlying `docker_compose_config` /
  `docker_compose_secret` targets.

## 0.2.1 — smart-merge for `compose_extra`

- `compose_extra` on `docker_compose_service` now merges into the
  payload semantically instead of `dict.update()`-overwriting:
  - list-valued keys (`volumes`, `ports`, `command`, `networks`, …)
    → append `extra` to payload.
  - dict-valued keys (`environment`, `labels`, `sysctls`, …) →
    merge dicts (extra wins on key collision).
  - scalar keys → extra wins.
- Existing diff_tests unchanged (no smart-merge cases hit them).

## 0.2.0 — auto-discovery aspect + idiomatic service façade

- `docker_compose`'s `deps` attr now uses `_compose_transitive_aspect`
  to walk every `docker_compose_service`'s label-typed attrs
  (`deps`, `deps_healthy`, `deps_completed`, `networks`, `configs`,
  `secrets`, `named_volume_mounts`) and collect the transitive
  `Compose*Info` shards. Consumers only list the root services they
  actually want exposed; intermediate deps are picked up automatically.
- `docker_compose_service` façade replaces the verbose
  schema-derived raw rule for hand-written services: label-typed
  attrs for `image_ref`, `deps`, `networks`, etc. The schema-derived
  rules still ship for callers who want one big dict.

## 0.1.0 — initial release

- `docker_compose` rule: aggregates Bazel shards into a single
  canonical `docker-compose.yml` via the Rust `compose-gen` binary.
- `docker_compose_oci_image_ref`: resolves an `@rules_oci` image
  reference at build time, threading the `<repo>@sha256:<digest>`
  through the aggregator so the rendered `image:` field carries the
  digest.
- `docker_compose_up` / `docker_compose_down` `bazel run`
  wrappers.
- Schema-derived typed rules (`docker_compose_service`,
  `docker_compose_network`, `docker_compose_volume`) generated
  from the canonical compose-spec via
  `rules_jsonschema`'s `jsonschema_starlark_codegen`. Regenerated
  on every build; the diff_test in docs/ gates committed output.
- Stardoc-generated reference docs in `docs/`.
- End-to-end smoke tests covering aggregation, OCI image digest
  threading, and `bazel run //...:_up`/_down round-trips.
