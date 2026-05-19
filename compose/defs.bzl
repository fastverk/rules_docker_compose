"""User-facing Bazel rules for rules_docker_compose.

The typed schema-derived rules live in
[compose/compose_rules.bzl](compose/compose_rules.bzl)
— they're regenerated from the canonical compose-spec schema via
`rules_jsonschema`'s `jsonschema_starlark_codegen`. Every spec property
becomes a typed Bazel `attr.*` automatically. This file owns the
pieces that aren't schema-derivable:

  * `docker_compose` — collects shards from the graph and invokes the
    Rust `compose-gen` binary to emit canonical YAML.
  * `docker_compose_oci_image_ref` — resolves an `@rules_oci` image to
    `<repo>@sha256:<digest>` at build time, contributes that ref to
    the aggregator via `ComposeServiceImageRefInfo`. The aggregator
    threads it to `compose-gen --service-image=...` so the rendered
    `image:` field carries the build-time digest.
  * `docker_compose_up` / `_down` — `bazel run` wrappers.

Re-exports the generated typed rules + providers so callers can `load`
everything from a single file.
"""

load(
    "//compose:compose_rules.bzl",
    _ComposeNetworkInfo = "ComposeNetworkInfo",
    _ComposeServiceInfo = "ComposeServiceInfo",
    _ComposeVolumeInfo = "ComposeVolumeInfo",
    _docker_compose_network = "docker_compose_network",
    _docker_compose_service_raw = "docker_compose_service",
    _docker_compose_volume = "docker_compose_volume",
)

# Re-export the schema-derived providers + the volume/network rules
# (these don't need a label-typed façade — their attrs are leaf scalars).
ComposeServiceInfo = _ComposeServiceInfo
ComposeVolumeInfo = _ComposeVolumeInfo
ComposeNetworkInfo = _ComposeNetworkInfo
docker_compose_volume = _docker_compose_volume
docker_compose_network = _docker_compose_network

# Escape hatch for advanced consumers who need the long-tail
# compose-spec attrs (cap_add/cgroup_parent/blkio_config/etc) directly
# as Bazel attrs rather than via the façade's `compose_extra` JSON.
# The public `docker_compose_service` below is the canonical entrypoint.
docker_compose_service_raw = _docker_compose_service_raw

ComposeProjectInfo = provider(
    doc = "A rendered compose project.",
    fields = {
        "yaml": "File: the rendered compose.yaml.",
    },
)

ComposeServiceImageRefInfo = provider(
    doc = "A build-time-resolved `<repo>@<digest>` image reference targeted at a named service.",
    fields = {
        "service_name": "string: name of the service whose `image:` to override.",
        "file": "File: a one-line text file containing the reference.",
    },
)

ComposeTransitiveInfo = provider(
    doc = "Bundled depsets of every compose shard reachable through the " +
          "label-typed attrs of a `docker_compose_service` graph. Populated " +
          "by `_compose_transitive_aspect`; consumed by the `docker_compose` " +
          "aggregator so root-only `deps` lists discover transitive volumes / " +
          "networks / image-refs / configs / secrets automatically.",
    fields = {
        "services": "depset of ComposeServiceInfo.",
        "image_refs": "depset of ComposeServiceImageRefInfo.",
        "volumes": "depset of ComposeVolumeInfo.",
        "networks": "depset of ComposeNetworkInfo.",
        "configs": "depset of ComposeConfigInfo.",
        "secrets": "depset of ComposeSecretInfo.",
        "runfiles_files": "depset of File for bind-mount sources + env files.",
    },
)

ComposeConfigInfo = provider(
    doc = "A top-level config (compose-spec `configs:` entry). Shard JSON matches the compose-spec config schema.",
    fields = {
        "config_name": "string: top-level key for this config in the rendered project.",
        "json": "File: the JSON shard.",
    },
)

ComposeSecretInfo = provider(
    doc = "A top-level secret (compose-spec `secrets:` entry). Shard JSON matches the compose-spec secret schema.",
    fields = {
        "secret_name": "string: top-level key for this secret in the rendered project.",
        "json": "File: the JSON shard.",
    },
)

# --- docker_compose_config -------------------------------------------
#
# Top-level `configs:` rule. Compose injects the named config's file
# content into services that reference it (via per-service
# `configs: [<name>]`). Closes a gap in the schema-derived codegen,
# which only emits service/volume/network top-level rules.

def _strip_empty(d):
    """Drop entries whose value is None / empty list / empty dict.
    Mirrors strip_empty from rules_jsonschema/runtime:helpers.bzl, kept
    local to avoid pulling in the helper for two call sites."""
    return {k: v for k, v in d.items() if v != None and v != [] and v != {} and v != ""}

def _docker_compose_config_impl(ctx):
    item_name = ctx.attr.config_name or ctx.label.name
    src_file = ctx.file.src

    payload = _strip_empty({
        "file": "${WORKSPACE_DIR}/" + src_file.short_path if src_file else None,
        "external": ctx.attr.external if ctx.attr.external else None,
        "name": ctx.attr.name_override,
        "template_driver": ctx.attr.template_driver,
        "labels": ctx.attr.labels,
    })

    shard = ctx.actions.declare_file("{}.config.json".format(ctx.label.name))
    ctx.actions.write(shard, content = json.encode(payload))

    runfiles_files = [src_file] if src_file else []
    return [
        DefaultInfo(
            files = depset([shard]),
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
        ComposeConfigInfo(config_name = item_name, json = shard),
    ]

docker_compose_config = rule(
    implementation = _docker_compose_config_impl,
    doc = "Define a top-level `configs:` entry. Reference from a service via " +
          "the schema-derived `configs` attr (list of config names).",
    attrs = {
        "config_name": attr.string(
            doc = "Override the top-level config key. Defaults to target name.",
        ),
        "src": attr.label(
            allow_single_file = True,
            doc = "File providing the config payload. Bind-mounted by compose at the per-service `target:` path.",
        ),
        "external": attr.bool(
            doc = "If True, compose expects an existing external config rather than creating one.",
        ),
        "name_override": attr.string(
            doc = "Override the rendered `name:` field (defaults to project + key).",
        ),
        "template_driver": attr.string(
            doc = "Compose template driver (uncommon; for external secret managers).",
        ),
        "labels": attr.string_dict(
            doc = "User-defined labels on the config.",
        ),
    },
    provides = [ComposeConfigInfo],
)

# --- docker_compose_secret -------------------------------------------
#
# Top-level `secrets:` rule. Same shape as docker_compose_config plus
# the `environment:` source variant (compose-spec lets a secret read
# from an env var instead of a file).

def _docker_compose_secret_impl(ctx):
    item_name = ctx.attr.secret_name or ctx.label.name
    src_file = ctx.file.src

    if src_file and ctx.attr.environment:
        fail("{}: docker_compose_secret cannot have both `src` and `environment`.".format(ctx.label))

    payload = _strip_empty({
        "file": "${WORKSPACE_DIR}/" + src_file.short_path if src_file else None,
        "environment": ctx.attr.environment,
        "external": ctx.attr.external if ctx.attr.external else None,
        "name": ctx.attr.name_override,
        "driver": ctx.attr.driver,
        "driver_opts": ctx.attr.driver_opts,
        "template_driver": ctx.attr.template_driver,
        "labels": ctx.attr.labels,
    })

    shard = ctx.actions.declare_file("{}.secret.json".format(ctx.label.name))
    ctx.actions.write(shard, content = json.encode(payload))

    runfiles_files = [src_file] if src_file else []
    return [
        DefaultInfo(
            files = depset([shard]),
            runfiles = ctx.runfiles(files = runfiles_files),
        ),
        ComposeSecretInfo(secret_name = item_name, json = shard),
    ]

docker_compose_secret = rule(
    implementation = _docker_compose_secret_impl,
    doc = "Define a top-level `secrets:` entry. Reference from a service via the " +
          "schema-derived `secrets` attr (list of secret names).",
    attrs = {
        "secret_name": attr.string(
            doc = "Override the top-level secret key. Defaults to target name.",
        ),
        "src": attr.label(
            allow_single_file = True,
            doc = "File providing the secret payload. Mutually exclusive with `environment`.",
        ),
        "environment": attr.string(
            doc = "Name of an env var whose value is the secret. Mutually exclusive with `src`.",
        ),
        "external": attr.bool(
            doc = "If True, compose expects an existing external secret rather than creating one.",
        ),
        "name_override": attr.string(
            doc = "Override the rendered `name:` field.",
        ),
        "driver": attr.string(
            doc = "Compose secret driver (e.g. `external`, `vault`).",
        ),
        "driver_opts": attr.string_dict(
            doc = "Driver options as a string map.",
        ),
        "template_driver": attr.string(
            doc = "Compose template driver.",
        ),
        "labels": attr.string_dict(
            doc = "User-defined labels on the secret.",
        ),
    },
    provides = [ComposeSecretInfo],
)

# --- docker_compose_service (public façade) --------------------------
#
# Hand-written counterpart to `_docker_compose_service_raw` (the
# schema-derived rule). Lifts the high-traffic compose-spec attrs from
# their string form into idiomatic Bazel attrs:
#
#   * deps / deps_healthy / deps_completed — label_list providing
#     ComposeServiceInfo. Compiled to the compose-spec extended
#     `depends_on` form (object with `condition:` per service) when any
#     conditional list is non-empty; otherwise the simple list form.
#   * networks — label_list of docker_compose_network targets.
#   * named_volume_mounts — label_keyed_string_dict; keys are
#     docker_compose_volume targets, values are the in-container path
#     (with optional `:ro`/`:rw` suffix). Compiled to compose's
#     `volumes: ["<volume_name>:<target>"]` form.
#   * bind_mounts — label_keyed_string_dict; keys are file/filegroup
#     targets, values are the in-container path. Source paths resolve
#     to `./<workspace-relative-path>` so they bind-mount cleanly under
#     `docker compose up`. Source files contributed to the rule's
#     runfiles so the aggregator carries them through.
#   * configs / secrets — label_list of docker_compose_{config,secret}.
#     Compiled to per-service `configs: [<name>]` / `secrets: [<name>]`.
#   * env_file — label_list (`allow_files=True`); workspace-relative
#     paths emitted into `env_file:` and source files contributed to
#     runfiles.
#   * image — string for tag-pinned external images. For Bazel-built
#     OCI layouts, use a sibling `docker_compose_oci_image_ref` (or set
#     `oci_image` here to emit one inline; see below).
#   * oci_image — label to an OCI image layout. When set, the façade
#     emits a sibling ComposeServiceImageRefInfo provider so the
#     aggregator threads the build-time-resolved `<repo>@<digest>` into
#     the rendered `image:` field. Either `image` (string) or
#     `oci_image` (label) must be set; not both.
#   * compose_extra — JSON-encoded dict of any compose-spec attrs not
#     hoisted into the façade (cpu_count, mem_limit, deploy, ...).
#     Merged into the emitted shard verbatim.
#
# Long-tail consumers can still call `docker_compose_service_raw`
# directly for full attr coverage.

_CONDITION_STARTED = "service_started"
_CONDITION_HEALTHY = "service_healthy"
_CONDITION_COMPLETED = "service_completed_successfully"

def _compile_depends_on(deps, deps_healthy, deps_completed):
    """Render `depends_on` in the simple list form when no conditional
    deps are present, else the extended object form. Compose accepts
    both; the simple form reads cleaner."""
    simple = [d[ComposeServiceInfo].service_name for d in deps]
    healthy = [d[ComposeServiceInfo].service_name for d in deps_healthy]
    completed = [d[ComposeServiceInfo].service_name for d in deps_completed]
    if not (simple or healthy or completed):
        return None
    if not (healthy or completed):
        return simple
    out = {}
    for n in simple:
        out[n] = {"condition": _CONDITION_STARTED}
    for n in healthy:
        out[n] = {"condition": _CONDITION_HEALTHY}
    for n in completed:
        out[n] = {"condition": _CONDITION_COMPLETED}
    return out

def _compile_volumes(named_volume_mounts, bind_mounts):
    """Combine named-volume mounts + bind-mounts into the single
    compose-spec `volumes:` list form (`"src:target[:mode]"`)."""
    out = []
    for vol_target, mount in named_volume_mounts.items():
        vol_name = vol_target[ComposeVolumeInfo].volume_name
        out.append("{}:{}".format(vol_name, mount))
    for src_target, mount in bind_mounts.items():
        files = src_target[DefaultInfo].files.to_list()
        if not files:
            fail("bind_mount source {} has no files".format(src_target.label))
        if len(files) > 1:
            fail("bind_mount source {} resolves to {} files; expected exactly 1".format(
                src_target.label,
                len(files),
            ))
        src_path = "${WORKSPACE_DIR}/" + files[0].short_path
        out.append("{}:{}".format(src_path, mount))
    return out

def _docker_compose_service_impl(ctx):
    if ctx.attr.image and ctx.attr.oci_image:
        fail("{}: docker_compose_service.image (string) and .oci_image (label) are mutually exclusive.".format(ctx.label))
    if not ctx.attr.image and not ctx.attr.oci_image:
        fail("{}: docker_compose_service requires either `image` (string) or `oci_image` (label).".format(ctx.label))

    item_name = ctx.attr.service_name or ctx.label.name

    # Long-tail compose-spec attrs flow through `compose_extra` (JSON dict).
    # Merge semantics (not naive overwrite):
    #   - list-valued keys (volumes, ports, command, …) → append extra to payload
    #   - dict-valued keys (environment, labels, …) → merge dicts (extra wins on collision)
    #   - scalar keys → extra wins
    # Lets a service supplement, not replace, what the hot-path attrs emit.
    extra = json.decode(ctx.attr.compose_extra) if ctx.attr.compose_extra else {}

    # Hot-path payload — only non-empty fields end up in the shard
    # (typify/serde's `skip_serializing_if = Option::is_none` handles
    # the rest in the Rust binary).
    payload = {
        "image": ctx.attr.image if ctx.attr.image else "",  # placeholder; oci_image override applies via image-ref shard
        "command": ctx.attr.command,
        "entrypoint": ctx.attr.entrypoint,
        "environment": ctx.attr.environment,
        "env_file": ["${WORKSPACE_DIR}/" + f.short_path for f in ctx.files.env_file],
        "ports": ctx.attr.ports,
        "restart": ctx.attr.restart,
        "user": ctx.attr.user,
        "working_dir": ctx.attr.working_dir,
        "container_name": ctx.attr.container_name,
        "hostname": ctx.attr.hostname,
        "healthcheck": json.decode(ctx.attr.healthcheck) if ctx.attr.healthcheck else None,
        "networks": [d[ComposeNetworkInfo].network_name for d in ctx.attr.networks],
        "depends_on": _compile_depends_on(ctx.attr.deps, ctx.attr.deps_healthy, ctx.attr.deps_completed),
        "volumes": _compile_volumes(ctx.attr.named_volume_mounts, ctx.attr.bind_mounts),
        "configs": (
            [c[ComposeConfigInfo].config_name for c in ctx.attr.configs] +
            [
                {"source": cfg[ComposeConfigInfo].config_name, "target": target}
                for cfg, target in ctx.attr.config_mounts.items()
            ]
        ),
        "secrets": (
            [s[ComposeSecretInfo].secret_name for s in ctx.attr.secrets] +
            [
                {"source": sec[ComposeSecretInfo].secret_name, "target": target}
                for sec, target in ctx.attr.secret_mounts.items()
            ]
        ),
        "profiles": ctx.attr.profiles,
        "privileged": ctx.attr.privileged if ctx.attr.privileged else None,
        "init": ctx.attr.init if ctx.attr.init else None,
        "stdin_open": ctx.attr.stdin_open if ctx.attr.stdin_open else None,
        "tty": ctx.attr.tty if ctx.attr.tty else None,
    }
    # Smart-merge compose_extra into the payload (see semantics in the
    # compose_extra section above).
    for k, v in extra.items():
        if k in payload and type(payload[k]) == "list" and type(v) == "list":
            payload[k] = payload[k] + v
        elif k in payload and type(payload[k]) == "dict" and type(v) == "dict":
            merged = dict(payload[k])
            merged.update(v)
            payload[k] = merged
        else:
            payload[k] = v
    # Drop empty values; the typify-generated Service struct uses
    # `#[serde(skip_serializing_if = "Option::is_none")]` and a present
    # empty list emits a sequence rather than getting elided.
    payload = {
        k: v
        for k, v in payload.items()
        if v != None and v != [] and v != {} and v != ""
    }

    shard = ctx.actions.declare_file("{}.service.json".format(ctx.label.name))
    ctx.actions.write(shard, content = json.encode(payload))

    providers = [
        ComposeServiceInfo(service_name = item_name, json = shard),
    ]

    # Collect runfiles from bind_mounts + env_file so the aggregator's
    # `_compose_runner` can find every source path the rendered yaml
    # references at `docker compose up` time.
    rf_files = list(ctx.files.env_file)
    for src_target in ctx.attr.bind_mounts:
        rf_files.extend(src_target[DefaultInfo].files.to_list())
    runfiles = ctx.runfiles(files = rf_files)

    # Optional oci_image: emit an inline image-ref shard. Reuses the
    # exact mechanism docker_compose_oci_image_ref uses so the
    # aggregator's `--service-image` flag handles it the same way.
    if ctx.attr.oci_image:
        ref_out = ctx.actions.declare_file("{}.image-ref.txt".format(ctx.label.name))
        layout_files = ctx.attr.oci_image[DefaultInfo].files.to_list()
        if not layout_files:
            fail("{}: oci_image target {} has no files".format(ctx.label, ctx.attr.oci_image.label))
        ctx.actions.run(
            outputs = [ref_out],
            inputs = layout_files,
            executable = ctx.executable._compose_gen,
            arguments = [
                "image-ref",
                "--layout",
                layout_files[0].path,
                "--repo",
                ctx.attr.oci_repo,
                "--out",
                ref_out.path,
            ],
            mnemonic = "ComposeImageRef",
            progress_message = "compose-gen image-ref %s" % ctx.label,
        )
        providers.append(ComposeServiceImageRefInfo(
            service_name = item_name,
            file = ref_out,
        ))
        # The aggregator picks up the image-ref via providers, not via
        # the shard files set. Don't add ref_out to DefaultInfo.files.

    providers.append(DefaultInfo(
        files = depset([shard]),
        runfiles = runfiles,
    ))
    return providers

docker_compose_service = rule(
    implementation = _docker_compose_service_impl,
    doc = "Idiomatic, label-typed compose service. Most consumers use this; for the long tail " +
          "of compose-spec attrs, see `docker_compose_service_raw`.",
    attrs = {
        "service_name": attr.string(
            doc = "Override the compose-rendered service key. Defaults to target name.",
        ),

        # ── Image ─────────────────────────────────────────────────────
        "image": attr.string(
            doc = "Tag-pinned image reference (e.g. `nginx:1.27`). Mutually exclusive with `oci_image`.",
        ),
        "oci_image": attr.label(
            allow_files = True,
            doc = "OCI image layout label (e.g. `@caddy` or `//path:image`). At build time, the " +
                  "façade resolves `<repo>@sha256:<digest>` from the layout and threads it into " +
                  "the rendered `image:` via a sibling ComposeServiceImageRefInfo provider.",
        ),
        "oci_repo": attr.string(
            doc = "Registry/repo prefix to combine with the resolved digest. Required when " +
                  "`oci_image` is set.",
        ),

        # ── Command + lifecycle ────────────────────────────────────────
        "command": attr.string_list(),
        "entrypoint": attr.string_list(),
        "user": attr.string(),
        "working_dir": attr.string(),
        "container_name": attr.string(),
        "hostname": attr.string(),
        "restart": attr.string(),
        "init": attr.bool(),
        "stdin_open": attr.bool(),
        "tty": attr.bool(),
        "privileged": attr.bool(),

        # ── Env ───────────────────────────────────────────────────────
        "environment": attr.string_dict(),
        "env_file": attr.label_list(
            allow_files = True,
            doc = "Files whose lines are merged into the service environment. Source files " +
                  "are added to runfiles for `docker compose up`.",
        ),

        # ── Network ───────────────────────────────────────────────────
        "ports": attr.string_list(),
        "networks": attr.label_list(
            providers = [ComposeNetworkInfo],
        ),

        # ── Dependencies (by condition) ───────────────────────────────
        "deps": attr.label_list(
            providers = [ComposeServiceInfo],
            doc = "Services that must start before this one (compose `service_started` condition).",
        ),
        "deps_healthy": attr.label_list(
            providers = [ComposeServiceInfo],
            doc = "Services that must be healthy before this one starts (compose `service_healthy`).",
        ),
        "deps_completed": attr.label_list(
            providers = [ComposeServiceInfo],
            doc = "Services that must exit successfully before this one starts " +
                  "(compose `service_completed_successfully`).",
        ),

        # ── Mounts ────────────────────────────────────────────────────
        "named_volume_mounts": attr.label_keyed_string_dict(
            providers = [ComposeVolumeInfo],
            doc = "Map of docker_compose_volume targets to in-container mount paths. " +
                  "Value may include a `:ro`/`:rw` suffix.",
        ),
        "bind_mounts": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of file/filegroup targets to in-container mount paths. The source path " +
                  "renders as `./<workspace-relative>` so it resolves at `docker compose up` time. " +
                  "Value may include a `:ro`/`:rw` suffix.",
        ),

        # ── Configs + Secrets ─────────────────────────────────────────
        "configs": attr.label_list(
            providers = [ComposeConfigInfo],
            doc = "docker_compose_config targets referenced by this service. Mounted at " +
                  "the compose-default path (`/<config_name>`). Use `config_mounts` for a " +
                  "specific target path.",
        ),
        "config_mounts": attr.label_keyed_string_dict(
            providers = [ComposeConfigInfo],
            doc = "Map of docker_compose_config targets to in-container mount paths. " +
                  "Emits the compose-spec extended `configs: [{source, target}]` form.",
        ),
        "secrets": attr.label_list(
            providers = [ComposeSecretInfo],
            doc = "docker_compose_secret targets referenced by this service. Mounted at " +
                  "`/run/secrets/<secret_name>`. Use `secret_mounts` to override.",
        ),
        "secret_mounts": attr.label_keyed_string_dict(
            providers = [ComposeSecretInfo],
            doc = "Map of docker_compose_secret targets to in-container mount paths.",
        ),

        # ── Misc ──────────────────────────────────────────────────────
        "profiles": attr.string_list(
            doc = "Compose profiles this service belongs to.",
        ),
        "healthcheck": attr.string(
            doc = "JSON-encoded healthcheck dict (test, interval, retries, etc).",
        ),
        "compose_extra": attr.string(
            doc = "JSON-encoded dict of long-tail compose-spec attrs not hoisted into the façade " +
                  "(cpu_count, mem_limit, blkio_config, deploy, ...). Merged over the hot-path " +
                  "payload; `compose_extra` wins on collision.",
        ),

        # ── Internal ──────────────────────────────────────────────────
        "_compose_gen": attr.label(
            default = Label("//compose/private/compose_gen:compose_gen"),
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [ComposeServiceInfo],
)

# --- docker_compose_oci_image_ref -----------------------------------

def _docker_compose_oci_image_ref_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".image-ref.txt")
    layout_files = ctx.attr.oci_image[DefaultInfo].files.to_list()
    if len(layout_files) == 0:
        fail("{}: oci_image target {} has no files".format(ctx.label, ctx.attr.oci_image.label))
    layout_root = layout_files[0]
    ctx.actions.run(
        outputs = [out],
        inputs = layout_files,
        executable = ctx.executable._compose_gen,
        arguments = [
            "image-ref",
            "--layout",
            layout_root.path,
            "--repo",
            ctx.attr.oci_repo,
            "--out",
            out.path,
        ],
        mnemonic = "ComposeImageRef",
        progress_message = "compose-gen image-ref %s" % ctx.label,
    )
    return [
        DefaultInfo(files = depset([out])),
        ComposeServiceImageRefInfo(
            service_name = ctx.attr.service_name,
            file = out,
        ),
    ]

docker_compose_oci_image_ref = rule(
    implementation = _docker_compose_oci_image_ref_impl,
    doc = "Resolve an OCI image layout to `<repo>@sha256:<digest>` at build time and " +
          "override the named service's `image:` in the rendered compose YAML.",
    attrs = {
        "service_name": attr.string(
            mandatory = True,
            doc = "Name of the `docker_compose_service` whose `image:` to override.",
        ),
        "oci_image": attr.label(
            allow_files = True,
            mandatory = True,
            doc = "Target producing an OCI image layout (typically `@rules_oci//oci:defs.bzl%oci_image`).",
        ),
        "oci_repo": attr.string(
            mandatory = True,
            doc = "Registry/repo prefix joined with the resolved digest (e.g. `ghcr.io/myorg/myapp`).",
        ),
        "_compose_gen": attr.label(
            default = Label("//compose/private/compose_gen:compose_gen"),
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [ComposeServiceImageRefInfo],
)

# --- docker_compose aggregator ---------------------------------------

def _collect_shards(deps):
    """Walk the deps graph, classify each by its provider, fail on duplicates.

    Service rules contribute `ComposeServiceInfo` (the shard); separate
    `ComposeServiceImageRefInfo`-providing targets ride alongside to
    override the resolved image. We pair them up by service_name.
    """
    services = {}
    image_refs = {}
    volumes = {}
    networks = {}
    configs = {}
    secrets = {}
    extra_runfiles = []

    # Gather everything reachable through the transitive aspect first
    # (root services list root-only deps; the aspect walks the rest).
    aspect_services = []
    aspect_image_refs = []
    aspect_volumes = []
    aspect_networks = []
    aspect_configs = []
    aspect_secrets = []
    aspect_runfiles_files = []
    for d in deps:
        if ComposeTransitiveInfo in d:
            t = d[ComposeTransitiveInfo]
            aspect_services.extend(t.services.to_list())
            aspect_image_refs.extend(t.image_refs.to_list())
            aspect_volumes.extend(t.volumes.to_list())
            aspect_networks.extend(t.networks.to_list())
            aspect_configs.extend(t.configs.to_list())
            aspect_secrets.extend(t.secrets.to_list())
            aspect_runfiles_files.extend(t.runfiles_files.to_list())

    def _add(d, key, value, kind):
        if key in d and d[key] != value:
            fail("duplicate {} '{}' contributed multiple times with different shards".format(kind, key))
        d[key] = value

    for info in aspect_services:
        _add(services, info.service_name, info.json, "service")
    for info in aspect_image_refs:
        _add(image_refs, info.service_name, info.file, "image-ref")
    for info in aspect_volumes:
        _add(volumes, info.volume_name, info.json, "volume")
    for info in aspect_networks:
        _add(networks, info.network_name, info.json, "network")
    for info in aspect_configs:
        _add(configs, info.config_name, info.json, "config")
    for info in aspect_secrets:
        _add(secrets, info.secret_name, info.json, "secret")

    # Image-ref targeting a non-existent service is almost certainly a
    # rename-by-the-other-half bug — flag it explicitly.
    for svc_name in image_refs:
        if svc_name not in services:
            fail("ComposeServiceImageRefInfo targets service '{}' but no docker_compose_service with that name is reachable".format(svc_name))

    return services, image_refs, volumes, networks, configs, secrets, aspect_runfiles_files

# --- _compose_transitive_aspect --------------------------------------
#
# Walks `deps`/`deps_healthy`/`deps_completed`/`networks`/`configs`/
# `secrets`/`named_volume_mounts` on every docker_compose_service in the
# graph and bundles the discovered Compose*Info providers into a single
# ComposeTransitiveInfo on each visited target. The aggregator reads
# the top-level ComposeTransitiveInfo to build the full shard set
# without requiring every label to be listed in `deps` directly.
#
# Targets that don't have these attrs (docker_compose_volume,
# docker_compose_network, etc.) still get an aspect run — they just
# contribute their own provider and don't propagate further.

def _bundle_transitive(ts):
    """Return seven lists of `transitive=` depsets (one per shard category
    plus runfiles_files) from a list of visited targets that may carry
    ComposeTransitiveInfo. Entries that aren't Bazel Targets (e.g. string
    elements from a raw rule's `configs`/`secrets`/`networks` string_list)
    are silently skipped."""
    services = []
    image_refs = []
    volumes = []
    networks = []
    configs = []
    secrets = []
    runfiles_files = []
    for t in ts:
        if type(t) != "Target":
            continue
        if ComposeTransitiveInfo in t:
            info = t[ComposeTransitiveInfo]
            services.append(info.services)
            image_refs.append(info.image_refs)
            volumes.append(info.volumes)
            networks.append(info.networks)
            configs.append(info.configs)
            secrets.append(info.secrets)
            runfiles_files.append(info.runfiles_files)
    return services, image_refs, volumes, networks, configs, secrets, runfiles_files

def _compose_transitive_aspect_impl(target, ctx):
    # Direct providers contributed by THIS target.
    direct_services = [target[ComposeServiceInfo]] if ComposeServiceInfo in target else []
    direct_image_refs = [target[ComposeServiceImageRefInfo]] if ComposeServiceImageRefInfo in target else []
    direct_volumes = [target[ComposeVolumeInfo]] if ComposeVolumeInfo in target else []
    direct_networks = [target[ComposeNetworkInfo]] if ComposeNetworkInfo in target else []
    direct_configs = [target[ComposeConfigInfo]] if ComposeConfigInfo in target else []
    direct_secrets = [target[ComposeSecretInfo]] if ComposeSecretInfo in target else []

    # Direct runfiles (bind_mount sources + env_file sources) — flow up so
    # the aggregator can stage them for `docker compose up`.
    direct_runfiles_files = []
    if DefaultInfo in target:
        di = target[DefaultInfo]
        if di.default_runfiles:
            direct_runfiles_files.extend(di.default_runfiles.files.to_list())

    # Walk every label-typed attr we propagate through. hasattr guards
    # let the aspect apply to volume / network / config / secret rules
    # (which don't have these attrs) without error.
    walked = []
    rule_attrs = ctx.rule.attr
    if hasattr(rule_attrs, "deps"):
        walked.extend(rule_attrs.deps)
    if hasattr(rule_attrs, "deps_healthy"):
        walked.extend(rule_attrs.deps_healthy)
    if hasattr(rule_attrs, "deps_completed"):
        walked.extend(rule_attrs.deps_completed)
    if hasattr(rule_attrs, "networks"):
        walked.extend(rule_attrs.networks)
    if hasattr(rule_attrs, "configs"):
        walked.extend(rule_attrs.configs)
    if hasattr(rule_attrs, "secrets"):
        walked.extend(rule_attrs.secrets)
    if hasattr(rule_attrs, "named_volume_mounts"):
        walked.extend(rule_attrs.named_volume_mounts.keys())
    if hasattr(rule_attrs, "config_mounts"):
        walked.extend(rule_attrs.config_mounts.keys())
    if hasattr(rule_attrs, "secret_mounts"):
        walked.extend(rule_attrs.secret_mounts.keys())

    ts_services, ts_image_refs, ts_volumes, ts_networks, ts_configs, ts_secrets, ts_runfiles = _bundle_transitive(walked)

    return [
        ComposeTransitiveInfo(
            services = depset(direct_services, transitive = ts_services),
            image_refs = depset(direct_image_refs, transitive = ts_image_refs),
            volumes = depset(direct_volumes, transitive = ts_volumes),
            networks = depset(direct_networks, transitive = ts_networks),
            configs = depset(direct_configs, transitive = ts_configs),
            secrets = depset(direct_secrets, transitive = ts_secrets),
            runfiles_files = depset(direct_runfiles_files, transitive = ts_runfiles),
        ),
    ]

_compose_transitive_aspect = aspect(
    implementation = _compose_transitive_aspect_impl,
    attr_aspects = [
        "deps",
        "deps_healthy",
        "deps_completed",
        "networks",
        "configs",
        "config_mounts",
        "secrets",
        "secret_mounts",
        "named_volume_mounts",
    ],
)

def _docker_compose_impl(ctx):
    services, image_refs, volumes, networks, configs, secrets, extra_runfiles_files = _collect_shards(ctx.attr.deps)

    out = ctx.outputs.out
    args = ctx.actions.args()
    if ctx.attr.project_name:
        args.add("--name", ctx.attr.project_name)
    args.add("--out", out.path)

    inputs = []
    for name in sorted(services.keys()):
        shard = services[name]
        args.add("--service", "{}={}".format(name, shard.path))
        inputs.append(shard)
        ref = image_refs.get(name)
        if ref != None:
            args.add("--service-image", "{}={}".format(name, ref.path))
            inputs.append(ref)
    for name in sorted(volumes.keys()):
        f = volumes[name]
        args.add("--volume", "{}={}".format(name, f.path))
        inputs.append(f)
    for name in sorted(networks.keys()):
        f = networks[name]
        args.add("--network", "{}={}".format(name, f.path))
        inputs.append(f)
    for name in sorted(configs.keys()):
        f = configs[name]
        args.add("--config", "{}={}".format(name, f.path))
        inputs.append(f)
    for name in sorted(secrets.keys()):
        f = secrets[name]
        args.add("--secret", "{}={}".format(name, f.path))
        inputs.append(f)

    ctx.actions.run(
        outputs = [out],
        inputs = inputs,
        executable = ctx.executable._compose_gen,
        arguments = [args],
        mnemonic = "ComposeGen",
        progress_message = "compose-gen %s" % ctx.label.name,
    )

    aggregated_runfiles = ctx.runfiles(files = [out] + extra_runfiles_files)
    return [
        DefaultInfo(files = depset([out]), runfiles = aggregated_runfiles),
        ComposeProjectInfo(yaml = out),
    ]

docker_compose = rule(
    implementation = _docker_compose_impl,
    doc = "Assemble service / volume / network shards into one canonical compose.yaml.",
    attrs = {
        "project_name": attr.string(
            doc = "Top-level `name:` field. Defaults to empty (compose derives a name " +
                  "from the file's containing directory).",
        ),
        "deps": attr.label_list(
            providers = [
                [ComposeServiceInfo],
                [ComposeVolumeInfo],
                [ComposeNetworkInfo],
                [ComposeConfigInfo],
                [ComposeSecretInfo],
                [ComposeServiceImageRefInfo],
            ],
            aspects = [_compose_transitive_aspect],
            doc = "Targets contributing services, volumes, networks, configs, secrets, " +
                  "or service-image overrides. Lists ROOT services (those not depended " +
                  "on by another listed service); the transitive aspect walks " +
                  "`deps`/`deps_healthy`/`deps_completed`/`networks`/`configs`/`secrets`/" +
                  "`named_volume_mounts` on each docker_compose_service to discover " +
                  "everything else automatically. Listing extra targets is still allowed " +
                  "(for unreferenced volumes/networks or back-compat).",
        ),
        "out": attr.output(
            mandatory = True,
            doc = "Path for the generated compose YAML (e.g. `compose.yaml`).",
        ),
        "_compose_gen": attr.label(
            default = Label("//compose/private/compose_gen:compose_gen"),
            executable = True,
            cfg = "exec",
        ),
    },
    provides = [ComposeProjectInfo],
)

# --- bazel run wrappers ----------------------------------------------

def _shell_quote(s):
    """Bash single-quote `s`, escaping any internal single quote."""
    return "'" + s.replace("'", "'\\''") + "'"

def _compose_runner_impl(ctx):
    yaml_file = ctx.attr.project[ComposeProjectInfo].yaml
    subcommand = ctx.attr.subcommand

    # Fixed args sit between SUBCOMMAND and "$@" on the docker-compose
    # invocation. Composed as:
    #   <flag_args> [<service>] [<command...>]
    # Each arg is shell-single-quoted so embedded spaces / quotes work.
    fixed_args = list(ctx.attr.flag_args)
    if ctx.attr.service:
        fixed_args.append(ctx.attr.service)
    fixed_args.extend(ctx.attr.command)
    quoted_fixed_args = " ".join([_shell_quote(a) for a in fixed_args])

    # Bind-mount paths in compose files resolve relative to the YAML
    # file's directory, so for `./data:/data` to mean the user's
    # source tree we cd to BUILD_WORKSPACE_DIRECTORY and pass `-f`
    # the generated yaml's absolute runfiles path.
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = runner,
        is_executable = True,
        content = """\
#!/usr/bin/env bash
# Generated by docker_compose_{sub}: invokes `docker compose -f <yaml> {sub}`.
set -euo pipefail

if [[ -z "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]]; then
  echo "error: docker_compose_{sub} must be invoked via 'bazel run'" >&2
  exit 1
fi

if [[ -z "${{RUNFILES_DIR:-}}" ]]; then
  if [[ -d "$0.runfiles" ]]; then
    RUNFILES_DIR="$0.runfiles"
  fi
fi

WS_NAME="{ws_name}"
yaml_sp="{yaml_sp}"
if [[ "$yaml_sp" == "../"* ]]; then
  YAML_ABS="${{RUNFILES_DIR}}/${{yaml_sp#../}}"
else
  YAML_ABS="${{RUNFILES_DIR}}/${{WS_NAME}}/${{yaml_sp}}"
fi
if [[ ! -f "$YAML_ABS" ]]; then
  echo "ERROR: cannot find generated compose yaml at $YAML_ABS" >&2
  exit 2
fi

# Compose resolves `env_file:` / `configs.<n>.file` / `secrets.<n>.file`
# paths relative to the compose FILE's parent dir (NOT `--project-directory`).
# That makes `./foo` written in a BUILD.bazel unresolvable when the yaml
# lives in runfiles. Rather than relocate the yaml at runtime, the
# façade emits those paths as `${{WORKSPACE_DIR}}/<short_path>` — compose
# v2 interpolates `${{VAR}}` from the parent process's env BEFORE
# resolving paths, so the final path is absolute and cwd-independent.
# Export WORKSPACE_DIR here so that substitution lands.
export WORKSPACE_DIR="$BUILD_WORKSPACE_DIRECTORY"
cd "$BUILD_WORKSPACE_DIRECTORY"
exec docker compose -f "$YAML_ABS" {sub} {fixed} "$@"
""".format(
            sub = subcommand,
            ws_name = ctx.workspace_name,
            yaml_sp = yaml_file.short_path,
            fixed = quoted_fixed_args,
        ),
    )

    # Carry forward the project's runfiles so `docker compose up`'s
    # `configs.*.file` / `secrets.*.file` bind-mount sources are present.
    project_di = ctx.attr.project[DefaultInfo]
    runfiles = ctx.runfiles(files = [yaml_file])
    if project_di.default_runfiles:
        runfiles = runfiles.merge(project_di.default_runfiles)
    return [DefaultInfo(executable = runner, runfiles = runfiles)]

_compose_runner = rule(
    implementation = _compose_runner_impl,
    executable = True,
    attrs = {
        "project": attr.label(
            mandatory = True,
            providers = [ComposeProjectInfo],
            doc = "A `docker_compose` target whose generated yaml to invoke.",
        ),
        "subcommand": attr.string(mandatory = True, doc = "docker compose subcommand."),
        "flag_args": attr.string_list(
            default = [],
            doc = "Flag args between the subcommand and `<service>`/`<command>` " +
                  "(e.g. `[\"--rm\", \"-T\"]`).",
        ),
        "service": attr.string(
            default = "",
            doc = "Optional service name for subcommands that target one " +
                  "(exec, run, logs <svc>, restart <svc>, ...).",
        ),
        "command": attr.string_list(
            default = [],
            doc = "Command + args to run inside the container (for exec / run).",
        ),
    },
)

def docker_compose_up(name, project, **kwargs):
    """`bazel run :<name>` -> `docker compose -f <generated.yaml> up`.

    Args after `--` are passed through to docker compose
    (e.g. `bazel run :stack.up -- -d` for detached mode).
    """
    _compose_runner(
        name = name,
        project = project,
        subcommand = "up",
        **kwargs
    )

def docker_compose_down(name, project, **kwargs):
    """`bazel run :<name>` -> `docker compose -f <generated.yaml> down`."""
    _compose_runner(
        name = name,
        project = project,
        subcommand = "down",
        **kwargs
    )

# ─── docker_compose_exec ─────────────────────────────────────────────
#
# `bazel run :<name>` -> `docker compose -f <yaml> exec [flags] <service> <cmd...>`.
# Fail-loud if the service isn't running (docker compose's own error
# surfaces clearly; no auto-up).

def docker_compose_exec(
        name,
        project,
        service,
        command = [],
        user = "",
        workdir = "",
        env = {},
        detach = False,
        no_tty = False,
        privileged = False,
        index = 0,
        **kwargs):
    """Name a `docker compose exec` invocation as a Bazel target.

    Args:
      name: Bazel target name. `bazel run :<name>` triggers the exec.
      project: `docker_compose` target whose rendered yaml to use.
      service: name of the service to exec into.
      command: list of strings — the program + args to run in-container.
      user: pass through as `--user <user>` (empty = service default).
      workdir: pass through as `--workdir <dir>`.
      env: dict of `KEY: VALUE` — each becomes `--env KEY=VALUE`.
      detach: if True, pass `--detach` (the exec returns immediately).
      no_tty: if True, pass `-T` (disable TTY allocation; needed for
              non-interactive use, e.g. CI).
      privileged: if True, pass `--privileged`.
      index: 1-based container index if the service has replicas; ignored
             when 0 (the default).
      **kwargs: forwarded to the underlying `_compose_runner` rule
                (visibility, tags, etc).
    """
    flag_args = []
    if user:
        flag_args.extend(["--user", user])
    if workdir:
        flag_args.extend(["--workdir", workdir])
    for k in sorted(env.keys()):
        flag_args.extend(["--env", "{}={}".format(k, env[k])])
    if detach:
        flag_args.append("--detach")
    if no_tty:
        flag_args.append("-T")
    if privileged:
        flag_args.append("--privileged")
    if index > 0:
        flag_args.extend(["--index", str(index)])
    _compose_runner(
        name = name,
        project = project,
        subcommand = "exec",
        flag_args = flag_args,
        service = service,
        command = command,
        **kwargs
    )

# ─── docker_compose_run ──────────────────────────────────────────────
#
# `bazel run :<name>` -> `docker compose -f <yaml> run [flags] <service> <cmd...>`.
# Spawns a one-off container based on the service definition. Default
# is `--rm` so the container is cleaned up on exit.

def docker_compose_run(
        name,
        project,
        service,
        command = [],
        user = "",
        workdir = "",
        env = {},
        rm = True,
        detach = False,
        no_tty = False,
        service_ports = False,
        use_aliases = False,
        no_deps = False,
        name_override = "",
        **kwargs):
    """Name a `docker compose run` invocation as a Bazel target.

    Args:
      name: Bazel target name.
      project: `docker_compose` target whose rendered yaml to use.
      service: service definition to base the one-off container on.
      command: command + args to run; if empty, uses the service's
               default entrypoint+command.
      user / workdir / env: as for `docker_compose_exec`.
      rm: if True (default), pass `--rm`.
      detach: if True, pass `--detach`.
      no_tty: if True, pass `-T`.
      service_ports: if True, publish the service's `ports:` block.
      use_aliases: if True, use the service's network aliases.
      no_deps: if True, don't start linked services.
      name_override: if non-empty, pass `--name <name>` to the container.
      **kwargs: forwarded to the underlying rule.
    """
    flag_args = []
    if rm:
        flag_args.append("--rm")
    if user:
        flag_args.extend(["--user", user])
    if workdir:
        flag_args.extend(["--workdir", workdir])
    for k in sorted(env.keys()):
        flag_args.extend(["--env", "{}={}".format(k, env[k])])
    if detach:
        flag_args.append("--detach")
    if no_tty:
        flag_args.append("-T")
    if service_ports:
        flag_args.append("--service-ports")
    if use_aliases:
        flag_args.append("--use-aliases")
    if no_deps:
        flag_args.append("--no-deps")
    if name_override:
        flag_args.extend(["--name", name_override])
    _compose_runner(
        name = name,
        project = project,
        subcommand = "run",
        flag_args = flag_args,
        service = service,
        command = command,
        **kwargs
    )

# ─── docker_compose_command ──────────────────────────────────────────
#
# Generic escape hatch for the long tail of `docker compose <sub>`
# verbs we don't have a typed wrapper for (logs, ps, restart, cp, top,
# events, port, images, version, …). Fixed args after the subcommand
# can be supplied via `args`; anything after `--` on the bazel run
# command line is appended verbatim.

def docker_compose_command(
        name,
        project,
        subcommand,
        args = [],
        service = "",
        **kwargs):
    """`bazel run :<name>` -> `docker compose -f <yaml> <subcommand> <args> [service] [extra...]`.

    Args:
      name: Bazel target name.
      project: `docker_compose` target whose rendered yaml to use.
      subcommand: e.g. `"logs"`, `"ps"`, `"restart"`, `"cp"`.
      args: list of strings, threaded between the subcommand and the
            optional `service` token.
      service: optional service name appended after `args`.
      **kwargs: forwarded to the underlying rule.
    """
    _compose_runner(
        name = name,
        project = project,
        subcommand = subcommand,
        flag_args = args,
        service = service,
        **kwargs
    )
