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
        "file": "./" + src_file.short_path if src_file else None,
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
        "file": "./" + src_file.short_path if src_file else None,
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
        src_path = "./" + files[0].short_path
        out.append("{}:{}".format(src_path, mount))
    return out

def _docker_compose_service_impl(ctx):
    if ctx.attr.image and ctx.attr.oci_image:
        fail("{}: docker_compose_service.image (string) and .oci_image (label) are mutually exclusive.".format(ctx.label))
    if not ctx.attr.image and not ctx.attr.oci_image:
        fail("{}: docker_compose_service requires either `image` (string) or `oci_image` (label).".format(ctx.label))

    item_name = ctx.attr.service_name or ctx.label.name

    # Long-tail compose-spec attrs flow through `compose_extra` (JSON dict).
    extra = json.decode(ctx.attr.compose_extra) if ctx.attr.compose_extra else {}

    # Hot-path payload — only non-empty fields end up in the shard
    # (typify/serde's `skip_serializing_if = Option::is_none` handles
    # the rest in the Rust binary).
    payload = {
        "image": ctx.attr.image if ctx.attr.image else "",  # placeholder; oci_image override applies via image-ref shard
        "command": ctx.attr.command,
        "entrypoint": ctx.attr.entrypoint,
        "environment": ctx.attr.environment,
        "env_file": ["./" + f.short_path for f in ctx.files.env_file],
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
        "configs": [c[ComposeConfigInfo].config_name for c in ctx.attr.configs],
        "secrets": [s[ComposeSecretInfo].secret_name for s in ctx.attr.secrets],
        "profiles": ctx.attr.profiles,
        "privileged": ctx.attr.privileged if ctx.attr.privileged else None,
        "init": ctx.attr.init if ctx.attr.init else None,
        "stdin_open": ctx.attr.stdin_open if ctx.attr.stdin_open else None,
        "tty": ctx.attr.tty if ctx.attr.tty else None,
    }
    # Merge compose_extra over the hot-path payload (extra wins on collision).
    payload.update(extra)
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
            doc = "docker_compose_config targets referenced by this service.",
        ),
        "secrets": attr.label_list(
            providers = [ComposeSecretInfo],
            doc = "docker_compose_secret targets referenced by this service.",
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
    for d in deps:
        # A target can contribute multiple kinds (e.g. a future façade
        # rule that emits a service shard + an inline image ref). Walk
        # every provider rather than using elif.
        matched = False
        if ComposeServiceInfo in d:
            info = d[ComposeServiceInfo]
            if info.service_name in services:
                fail("duplicate service '{}' contributed by {}".format(info.service_name, d.label))
            services[info.service_name] = info.json
            matched = True
        if ComposeServiceImageRefInfo in d:
            info = d[ComposeServiceImageRefInfo]
            if info.service_name in image_refs:
                fail("duplicate image-ref for service '{}' contributed by {}".format(info.service_name, d.label))
            image_refs[info.service_name] = info.file
            matched = True
        if ComposeVolumeInfo in d:
            info = d[ComposeVolumeInfo]
            if info.volume_name in volumes:
                fail("duplicate volume '{}' contributed by {}".format(info.volume_name, d.label))
            volumes[info.volume_name] = info.json
            matched = True
        if ComposeNetworkInfo in d:
            info = d[ComposeNetworkInfo]
            if info.network_name in networks:
                fail("duplicate network '{}' contributed by {}".format(info.network_name, d.label))
            networks[info.network_name] = info.json
            matched = True
        if ComposeConfigInfo in d:
            info = d[ComposeConfigInfo]
            if info.config_name in configs:
                fail("duplicate config '{}' contributed by {}".format(info.config_name, d.label))
            configs[info.config_name] = info.json
            matched = True
        if ComposeSecretInfo in d:
            info = d[ComposeSecretInfo]
            if info.secret_name in secrets:
                fail("duplicate secret '{}' contributed by {}".format(info.secret_name, d.label))
            secrets[info.secret_name] = info.json
            matched = True
        if not matched:
            fail("dep {} does not provide a Compose{{Service,Volume,Network,Config,Secret,ServiceImageRef}}Info".format(d.label))
        # Carry forward any source files the dep contributed via its
        # DefaultInfo runfiles (e.g. docker_compose_config's src file).
        # `docker_compose_up`'s runner script needs them in runfiles so
        # the bind-mount path resolves at `docker compose up` time.
        if DefaultInfo in d:
            di = d[DefaultInfo]
            if di.default_runfiles:
                extra_runfiles.append(di.default_runfiles)

    # Image-ref targeting a non-existent service is almost certainly a
    # rename-by-the-other-half bug — flag it explicitly.
    for svc_name in image_refs:
        if svc_name not in services:
            fail("ComposeServiceImageRefInfo targets service '{}' but no docker_compose_service with that name is in deps".format(svc_name))

    return services, image_refs, volumes, networks, configs, secrets, extra_runfiles

def _docker_compose_impl(ctx):
    services, image_refs, volumes, networks, configs, secrets, extra_runfiles = _collect_shards(ctx.attr.deps)

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

    aggregated_runfiles = ctx.runfiles(files = [out]).merge_all(extra_runfiles)
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
            doc = "Targets contributing services, volumes, networks, configs, secrets, or service-image overrides.",
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

def _compose_runner_impl(ctx):
    yaml_file = ctx.attr.project[ComposeProjectInfo].yaml
    subcommand = ctx.attr.subcommand

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

cd "$BUILD_WORKSPACE_DIRECTORY"
exec docker compose -f "$YAML_ABS" {sub} "$@"
""".format(
            sub = subcommand,
            ws_name = ctx.workspace_name,
            yaml_sp = yaml_file.short_path,
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
