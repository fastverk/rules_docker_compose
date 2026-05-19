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
    for d in deps:
        if ComposeServiceInfo in d:
            info = d[ComposeServiceInfo]
            if info.service_name in services:
                fail("duplicate service '{}' contributed by {}".format(info.service_name, d.label))
            services[info.service_name] = info.json
        elif ComposeServiceImageRefInfo in d:
            info = d[ComposeServiceImageRefInfo]
            if info.service_name in image_refs:
                fail("duplicate image-ref for service '{}' contributed by {}".format(info.service_name, d.label))
            image_refs[info.service_name] = info.file
        elif ComposeVolumeInfo in d:
            info = d[ComposeVolumeInfo]
            if info.volume_name in volumes:
                fail("duplicate volume '{}' contributed by {}".format(info.volume_name, d.label))
            volumes[info.volume_name] = info.json
        elif ComposeNetworkInfo in d:
            info = d[ComposeNetworkInfo]
            if info.network_name in networks:
                fail("duplicate network '{}' contributed by {}".format(info.network_name, d.label))
            networks[info.network_name] = info.json
        else:
            fail("dep {} does not provide a Compose{{Service,Volume,Network,ServiceImageRef}}Info".format(d.label))

    # Image-ref targeting a non-existent service is almost certainly a
    # rename-by-the-other-half bug — flag it explicitly.
    for svc_name in image_refs:
        if svc_name not in services:
            fail("ComposeServiceImageRefInfo targets service '{}' but no docker_compose_service with that name is in deps".format(svc_name))

    return services, image_refs, volumes, networks

def _docker_compose_impl(ctx):
    services, image_refs, volumes, networks = _collect_shards(ctx.attr.deps)

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

    ctx.actions.run(
        outputs = [out],
        inputs = inputs,
        executable = ctx.executable._compose_gen,
        arguments = [args],
        mnemonic = "ComposeGen",
        progress_message = "compose-gen %s" % ctx.label.name,
    )

    return [
        DefaultInfo(files = depset([out])),
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
                [ComposeServiceImageRefInfo],
            ],
            doc = "Targets contributing services, volumes, networks, or service-image overrides.",
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

    runfiles = ctx.runfiles(files = [yaml_file])
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
