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
    _docker_compose_service = "docker_compose_service",
    _docker_compose_volume = "docker_compose_volume",
)

# Re-export the schema-derived rules + providers as public top-level
# symbols. Users `load("//compose:defs.bzl", "docker_compose_service")`
# and get the codegen output via this façade.
ComposeServiceInfo = _ComposeServiceInfo
ComposeVolumeInfo = _ComposeVolumeInfo
ComposeNetworkInfo = _ComposeNetworkInfo
docker_compose_service = _docker_compose_service
docker_compose_volume = _docker_compose_volume
docker_compose_network = _docker_compose_network

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
