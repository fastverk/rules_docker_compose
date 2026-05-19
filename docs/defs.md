<!-- Generated with Stardoc: http://skydoc.bazel.build -->

User-facing Bazel rules for rules_docker_compose.

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

<a id="docker_compose"></a>

## docker_compose

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose")

docker_compose(<a href="#docker_compose-name">name</a>, <a href="#docker_compose-deps">deps</a>, <a href="#docker_compose-out">out</a>, <a href="#docker_compose-project_name">project_name</a>)
</pre>

Assemble service / volume / network shards into one canonical compose.yaml.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="docker_compose-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="docker_compose-deps"></a>deps |  Targets contributing services, volumes, networks, or service-image overrides.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="docker_compose-out"></a>out |  Path for the generated compose YAML (e.g. `compose.yaml`).   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="docker_compose-project_name"></a>project_name |  Top-level `name:` field. Defaults to empty (compose derives a name from the file's containing directory).   | String | optional |  `""`  |


<a id="docker_compose_network"></a>

## docker_compose_network

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_network")

docker_compose_network(<a href="#docker_compose_network-name">name</a>, <a href="#docker_compose_network-attachable">attachable</a>, <a href="#docker_compose_network-driver">driver</a>, <a href="#docker_compose_network-driver_opts">driver_opts</a>, <a href="#docker_compose_network-enable_ipv4">enable_ipv4</a>, <a href="#docker_compose_network-enable_ipv6">enable_ipv6</a>, <a href="#docker_compose_network-external">external</a>,
                       <a href="#docker_compose_network-internal">internal</a>, <a href="#docker_compose_network-ipam">ipam</a>, <a href="#docker_compose_network-labels">labels</a>, <a href="#docker_compose_network-name_override">name_override</a>, <a href="#docker_compose_network-network_name">network_name</a>)
</pre>

Network configuration for the Compose application.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="docker_compose_network-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="docker_compose_network-attachable"></a>attachable |  If true, standalone containers can attach to this network.   | Boolean | optional |  `False`  |
| <a id="docker_compose_network-driver"></a>driver |  Specify which driver should be used for this network. Default is 'bridge'.   | String | optional |  `""`  |
| <a id="docker_compose_network-driver_opts"></a>driver_opts |  Specify driver-specific options defined as key/value pairs.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_network-enable_ipv4"></a>enable_ipv4 |  Enable IPv4 networking.   | Boolean | optional |  `False`  |
| <a id="docker_compose_network-enable_ipv6"></a>enable_ipv6 |  Enable IPv6 networking.   | Boolean | optional |  `False`  |
| <a id="docker_compose_network-external"></a>external |  Specifies that this network already exists and was created outside of Compose.   | Boolean | optional |  `False`  |
| <a id="docker_compose_network-internal"></a>internal |  Create an externally isolated network.   | Boolean | optional |  `False`  |
| <a id="docker_compose_network-ipam"></a>ipam |  Custom IP Address Management configuration for this network. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_network-labels"></a>labels |  Add metadata to the network using labels.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_network-name_override"></a>name_override |  Custom name for this network.   | String | optional |  `""`  |
| <a id="docker_compose_network-network_name"></a>network_name |  Top-level key for this network in the rendered project. Defaults to the rule name.   | String | optional |  `""`  |


<a id="docker_compose_oci_image_ref"></a>

## docker_compose_oci_image_ref

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_oci_image_ref")

docker_compose_oci_image_ref(<a href="#docker_compose_oci_image_ref-name">name</a>, <a href="#docker_compose_oci_image_ref-oci_image">oci_image</a>, <a href="#docker_compose_oci_image_ref-oci_repo">oci_repo</a>, <a href="#docker_compose_oci_image_ref-service_name">service_name</a>)
</pre>

Resolve an OCI image layout to `<repo>@sha256:<digest>` at build time and override the named service's `image:` in the rendered compose YAML.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="docker_compose_oci_image_ref-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="docker_compose_oci_image_ref-oci_image"></a>oci_image |  Target producing an OCI image layout (typically `@rules_oci//oci:defs.bzl%oci_image`).   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="docker_compose_oci_image_ref-oci_repo"></a>oci_repo |  Registry/repo prefix joined with the resolved digest (e.g. `ghcr.io/myorg/myapp`).   | String | required |  |
| <a id="docker_compose_oci_image_ref-service_name"></a>service_name |  Name of the `docker_compose_service` whose `image:` to override.   | String | required |  |


<a id="docker_compose_service"></a>

## docker_compose_service

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_service")

docker_compose_service(<a href="#docker_compose_service-name">name</a>, <a href="#docker_compose_service-annotations">annotations</a>, <a href="#docker_compose_service-attach">attach</a>, <a href="#docker_compose_service-blkio_config">blkio_config</a>, <a href="#docker_compose_service-build">build</a>, <a href="#docker_compose_service-cap_add">cap_add</a>, <a href="#docker_compose_service-cap_drop">cap_drop</a>, <a href="#docker_compose_service-cgroup">cgroup</a>,
                       <a href="#docker_compose_service-cgroup_parent">cgroup_parent</a>, <a href="#docker_compose_service-command">command</a>, <a href="#docker_compose_service-configs">configs</a>, <a href="#docker_compose_service-container_name">container_name</a>, <a href="#docker_compose_service-cpu_count">cpu_count</a>, <a href="#docker_compose_service-cpu_percent">cpu_percent</a>,
                       <a href="#docker_compose_service-cpu_period">cpu_period</a>, <a href="#docker_compose_service-cpu_quota">cpu_quota</a>, <a href="#docker_compose_service-cpu_rt_period">cpu_rt_period</a>, <a href="#docker_compose_service-cpu_rt_runtime">cpu_rt_runtime</a>, <a href="#docker_compose_service-cpu_shares">cpu_shares</a>, <a href="#docker_compose_service-cpus">cpus</a>, <a href="#docker_compose_service-cpuset">cpuset</a>,
                       <a href="#docker_compose_service-credential_spec">credential_spec</a>, <a href="#docker_compose_service-depends_on">depends_on</a>, <a href="#docker_compose_service-deploy">deploy</a>, <a href="#docker_compose_service-develop">develop</a>, <a href="#docker_compose_service-device_cgroup_rules">device_cgroup_rules</a>, <a href="#docker_compose_service-devices">devices</a>,
                       <a href="#docker_compose_service-dns">dns</a>, <a href="#docker_compose_service-dns_opt">dns_opt</a>, <a href="#docker_compose_service-dns_search">dns_search</a>, <a href="#docker_compose_service-domainname">domainname</a>, <a href="#docker_compose_service-entrypoint">entrypoint</a>, <a href="#docker_compose_service-env_file">env_file</a>, <a href="#docker_compose_service-environment">environment</a>,
                       <a href="#docker_compose_service-expose">expose</a>, <a href="#docker_compose_service-extends">extends</a>, <a href="#docker_compose_service-external_links">external_links</a>, <a href="#docker_compose_service-extra_hosts">extra_hosts</a>, <a href="#docker_compose_service-gpus">gpus</a>, <a href="#docker_compose_service-group_add">group_add</a>, <a href="#docker_compose_service-healthcheck">healthcheck</a>,
                       <a href="#docker_compose_service-hostname">hostname</a>, <a href="#docker_compose_service-image">image</a>, <a href="#docker_compose_service-init">init</a>, <a href="#docker_compose_service-ipc">ipc</a>, <a href="#docker_compose_service-isolation">isolation</a>, <a href="#docker_compose_service-label_file">label_file</a>, <a href="#docker_compose_service-labels">labels</a>, <a href="#docker_compose_service-links">links</a>, <a href="#docker_compose_service-logging">logging</a>,
                       <a href="#docker_compose_service-mac_address">mac_address</a>, <a href="#docker_compose_service-mem_limit">mem_limit</a>, <a href="#docker_compose_service-mem_reservation">mem_reservation</a>, <a href="#docker_compose_service-mem_swappiness">mem_swappiness</a>, <a href="#docker_compose_service-memswap_limit">memswap_limit</a>, <a href="#docker_compose_service-models">models</a>,
                       <a href="#docker_compose_service-network_mode">network_mode</a>, <a href="#docker_compose_service-networks">networks</a>, <a href="#docker_compose_service-oom_kill_disable">oom_kill_disable</a>, <a href="#docker_compose_service-oom_score_adj">oom_score_adj</a>, <a href="#docker_compose_service-pid">pid</a>, <a href="#docker_compose_service-pids_limit">pids_limit</a>,
                       <a href="#docker_compose_service-platform">platform</a>, <a href="#docker_compose_service-ports">ports</a>, <a href="#docker_compose_service-post_start">post_start</a>, <a href="#docker_compose_service-pre_stop">pre_stop</a>, <a href="#docker_compose_service-privileged">privileged</a>, <a href="#docker_compose_service-profiles">profiles</a>, <a href="#docker_compose_service-provider">provider</a>,
                       <a href="#docker_compose_service-pull_policy">pull_policy</a>, <a href="#docker_compose_service-pull_refresh_after">pull_refresh_after</a>, <a href="#docker_compose_service-read_only">read_only</a>, <a href="#docker_compose_service-restart">restart</a>, <a href="#docker_compose_service-runtime">runtime</a>, <a href="#docker_compose_service-scale">scale</a>, <a href="#docker_compose_service-secrets">secrets</a>,
                       <a href="#docker_compose_service-security_opt">security_opt</a>, <a href="#docker_compose_service-service_name">service_name</a>, <a href="#docker_compose_service-shm_size">shm_size</a>, <a href="#docker_compose_service-stdin_open">stdin_open</a>, <a href="#docker_compose_service-stop_grace_period">stop_grace_period</a>,
                       <a href="#docker_compose_service-stop_signal">stop_signal</a>, <a href="#docker_compose_service-storage_opt">storage_opt</a>, <a href="#docker_compose_service-sysctls">sysctls</a>, <a href="#docker_compose_service-tmpfs">tmpfs</a>, <a href="#docker_compose_service-tty">tty</a>, <a href="#docker_compose_service-ulimits">ulimits</a>, <a href="#docker_compose_service-use_api_socket">use_api_socket</a>, <a href="#docker_compose_service-user">user</a>,
                       <a href="#docker_compose_service-userns_mode">userns_mode</a>, <a href="#docker_compose_service-uts">uts</a>, <a href="#docker_compose_service-volumes">volumes</a>, <a href="#docker_compose_service-volumes_from">volumes_from</a>, <a href="#docker_compose_service-working_dir">working_dir</a>)
</pre>

Configuration for a service.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="docker_compose_service-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="docker_compose_service-annotations"></a>annotations |  -   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_service-attach"></a>attach |  -   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-blkio_config"></a>blkio_config |  Block IO configuration for the service. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-build"></a>build |  Configuration options for building the service's image. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-cap_add"></a>cap_add |  Add Linux capabilities. For example, 'CAP_SYS_ADMIN', 'SYS_ADMIN', or 'NET_ADMIN'.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-cap_drop"></a>cap_drop |  Drop Linux capabilities. For example, 'CAP_SYS_ADMIN', 'SYS_ADMIN', or 'NET_ADMIN'.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-cgroup"></a>cgroup |  Specify the cgroup namespace to join. Use 'host' to use the host's cgroup namespace, or 'private' to use a private cgroup namespace.   | String | optional |  `""`  |
| <a id="docker_compose_service-cgroup_parent"></a>cgroup_parent |  Specify an optional parent cgroup for the container.   | String | optional |  `""`  |
| <a id="docker_compose_service-command"></a>command |  Override the default command declared by the container image, for example 'CMD' in Dockerfile.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-configs"></a>configs |  Grant access to Configs on a per-service basis.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-container_name"></a>container_name |  Specify a custom container name, rather than a generated default name.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_count"></a>cpu_count |  Number of usable CPUs. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_percent"></a>cpu_percent |  Percentage of CPU resources to use. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_period"></a>cpu_period |  Limit the CPU CFS (Completely Fair Scheduler) period.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_quota"></a>cpu_quota |  Limit the CPU CFS (Completely Fair Scheduler) quota.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_rt_period"></a>cpu_rt_period |  Limit the CPU real-time period in microseconds or a duration.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_rt_runtime"></a>cpu_rt_runtime |  Limit the CPU real-time runtime in microseconds or a duration.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpu_shares"></a>cpu_shares |  CPU shares (relative weight) for the container.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpus"></a>cpus |  Number of CPUs to use. A floating-point value is supported to request partial CPUs.   | String | optional |  `""`  |
| <a id="docker_compose_service-cpuset"></a>cpuset |  CPUs in which to allow execution (0-3, 0,1).   | String | optional |  `""`  |
| <a id="docker_compose_service-credential_spec"></a>credential_spec |  Configure the credential spec for managed service account. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-depends_on"></a>depends_on |  Express dependency between services. Service dependencies cause services to be started in dependency order. The dependent service will wait for the dependency to be ready before starting.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-deploy"></a>deploy |  JSON-encoded value. The shard reader deserialises the parsed JSON straight into the typed schema model.   | String | optional |  `""`  |
| <a id="docker_compose_service-develop"></a>develop |  JSON-encoded value. The shard reader deserialises the parsed JSON straight into the typed schema model.   | String | optional |  `""`  |
| <a id="docker_compose_service-device_cgroup_rules"></a>device_cgroup_rules |  Add rules to the cgroup allowed devices list.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-devices"></a>devices |  List of device mappings for the container.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-dns"></a>dns |  Custom DNS servers to set for the service container.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-dns_opt"></a>dns_opt |  Custom DNS options to be passed to the container's DNS resolver.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-dns_search"></a>dns_search |  Custom DNS search domains to set on the service container.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-domainname"></a>domainname |  Custom domain name to use for the service container.   | String | optional |  `""`  |
| <a id="docker_compose_service-entrypoint"></a>entrypoint |  Override the default entrypoint declared by the container image, for example 'ENTRYPOINT' in Dockerfile.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-env_file"></a>env_file |  Add environment variables from a file or multiple files. Can be a single file path or a list of file paths.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-environment"></a>environment |  Add environment variables. You can use either an array or a list of KEY=VAL pairs.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_service-expose"></a>expose |  Expose ports without publishing them to the host machine - they'll only be accessible to linked services. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-extends"></a>extends |  Extend another service, in the current file or another file. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-external_links"></a>external_links |  Link to services started outside this Compose application. Specify services as <service_name>:<alias>.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-extra_hosts"></a>extra_hosts |  Add hostname mappings to the container network interface configuration.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-gpus"></a>gpus |  Define GPU devices to use. Can be set to 'all' to use all GPUs, or a list of specific GPU devices. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-group_add"></a>group_add |  Add additional groups which user inside the container should be member of. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-healthcheck"></a>healthcheck |  Configure a health check for the container to monitor its health status. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-hostname"></a>hostname |  Define a custom hostname for the service container.   | String | optional |  `""`  |
| <a id="docker_compose_service-image"></a>image |  Specify the image to start the container from. Can be a repository/tag, a digest, or a local image ID.   | String | optional |  `""`  |
| <a id="docker_compose_service-init"></a>init |  Run as an init process inside the container that forwards signals and reaps processes.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-ipc"></a>ipc |  IPC sharing mode for the service container. Use 'host' to share the host's IPC namespace, 'service:[service_name]' to share with another service, or 'shareable' to allow other services to share this service's IPC namespace.   | String | optional |  `""`  |
| <a id="docker_compose_service-isolation"></a>isolation |  Container isolation technology to use. Supported values are platform-specific.   | String | optional |  `""`  |
| <a id="docker_compose_service-label_file"></a>label_file |  Add metadata to containers using files containing Docker labels.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-labels"></a>labels |  Add metadata to containers using Docker labels. You can use either an array or a list.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_service-links"></a>links |  Link to containers in another service. Either specify both the service name and a link alias (SERVICE:ALIAS), or just the service name.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-logging"></a>logging |  Logging configuration for the service. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-mac_address"></a>mac_address |  Container MAC address to set.   | String | optional |  `""`  |
| <a id="docker_compose_service-mem_limit"></a>mem_limit |  Memory limit for the container. A string value can use suffix like '2g' for 2 gigabytes.   | String | optional |  `""`  |
| <a id="docker_compose_service-mem_reservation"></a>mem_reservation |  Memory reservation for the container.   | String | optional |  `""`  |
| <a id="docker_compose_service-mem_swappiness"></a>mem_swappiness |  Container memory swappiness as percentage (0 to 100).   | String | optional |  `""`  |
| <a id="docker_compose_service-memswap_limit"></a>memswap_limit |  Amount of memory the container is allowed to swap to disk. Set to -1 to enable unlimited swap.   | String | optional |  `""`  |
| <a id="docker_compose_service-models"></a>models |  AI Models to use, referencing entries under the top-level models key.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-network_mode"></a>network_mode |  Network mode. Values can be 'bridge', 'host', 'none', 'service:[service name]', or 'container:[container name]'.   | String | optional |  `""`  |
| <a id="docker_compose_service-networks"></a>networks |  Networks to join, referencing entries under the top-level networks key. Can be a list of network names or a mapping of network name to network configuration.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-oom_kill_disable"></a>oom_kill_disable |  Disable OOM Killer for the container.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-oom_score_adj"></a>oom_score_adj |  Tune host's OOM preferences for the container (accepts -1000 to 1000). (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-pid"></a>pid |  PID mode for container.   | String | optional |  `""`  |
| <a id="docker_compose_service-pids_limit"></a>pids_limit |  Tune a container's PIDs limit. Set to -1 for unlimited PIDs.   | String | optional |  `""`  |
| <a id="docker_compose_service-platform"></a>platform |  Target platform to run on, e.g., 'linux/amd64', 'linux/arm64', or 'windows/amd64'.   | String | optional |  `""`  |
| <a id="docker_compose_service-ports"></a>ports |  Expose container ports. Short format ([HOST:]CONTAINER[/PROTOCOL]).   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-post_start"></a>post_start |  Commands to run after the container starts. If any command fails, the container stops. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-pre_stop"></a>pre_stop |  Commands to run before the container stops. If any command fails, the container stop is aborted. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-privileged"></a>privileged |  Give extended privileges to the service container.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-profiles"></a>profiles |  List of profiles for this service. When profiles are specified, services are only started when the profile is activated.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-provider"></a>provider |  Specify a service which will not be manage by Compose directly, and delegate its management to an external provider. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-pull_policy"></a>pull_policy |  Policy for pulling images. Options include: 'always', 'never', 'if_not_present', 'missing', 'build', or time-based refresh policies.   | String | optional |  `""`  |
| <a id="docker_compose_service-pull_refresh_after"></a>pull_refresh_after |  Time after which to refresh the image. Used with pull_policy=refresh.   | String | optional |  `""`  |
| <a id="docker_compose_service-read_only"></a>read_only |  Mount the container's filesystem as read only.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-restart"></a>restart |  Restart policy for the service container. Options include: 'no', 'always', 'on-failure', and 'unless-stopped'.   | String | optional |  `""`  |
| <a id="docker_compose_service-runtime"></a>runtime |  Runtime to use for this container, e.g., 'runc'.   | String | optional |  `""`  |
| <a id="docker_compose_service-scale"></a>scale |  Number of containers to deploy for this service.   | String | optional |  `""`  |
| <a id="docker_compose_service-secrets"></a>secrets |  Grant access to Secrets on a per-service basis.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-security_opt"></a>security_opt |  Override the default labeling scheme for each container.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-service_name"></a>service_name |  Top-level key for this service in the rendered project. Defaults to the rule name.   | String | optional |  `""`  |
| <a id="docker_compose_service-shm_size"></a>shm_size |  Size of /dev/shm. A string value can use suffix like '2g' for 2 gigabytes.   | String | optional |  `""`  |
| <a id="docker_compose_service-stdin_open"></a>stdin_open |  Keep STDIN open even if not attached.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-stop_grace_period"></a>stop_grace_period |  Time to wait for the container to stop gracefully before sending SIGKILL (e.g., '1s', '1m30s').   | String | optional |  `""`  |
| <a id="docker_compose_service-stop_signal"></a>stop_signal |  Signal to stop the container (e.g., 'SIGTERM', 'SIGINT').   | String | optional |  `""`  |
| <a id="docker_compose_service-storage_opt"></a>storage_opt |  Storage driver options for the container. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-sysctls"></a>sysctls |  Kernel parameters to set in the container. You can use either an array or a list.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_service-tmpfs"></a>tmpfs |  Mount a temporary filesystem (tmpfs) into the container. Can be a single value or a list.   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-tty"></a>tty |  Allocate a pseudo-TTY to service container.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-ulimits"></a>ulimits |  Override the default ulimits for a container. (JSON-encoded; the Rust shard reader parses this verbatim.)   | String | optional |  `""`  |
| <a id="docker_compose_service-use_api_socket"></a>use_api_socket |  Bind mount Docker API socket and required auth.   | Boolean | optional |  `False`  |
| <a id="docker_compose_service-user"></a>user |  Username or UID to run the container process as.   | String | optional |  `""`  |
| <a id="docker_compose_service-userns_mode"></a>userns_mode |  User namespace to use. 'host' shares the host's user namespace.   | String | optional |  `""`  |
| <a id="docker_compose_service-uts"></a>uts |  UTS namespace to use. 'host' shares the host's UTS namespace.   | String | optional |  `""`  |
| <a id="docker_compose_service-volumes"></a>volumes |  Mount host paths or named volumes accessible to the container. Short syntax (VOLUME:CONTAINER_PATH[:MODE])   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-volumes_from"></a>volumes_from |  Mount volumes from another service or container. Optionally specify read-only access (ro) or read-write (rw).   | List of strings | optional |  `[]`  |
| <a id="docker_compose_service-working_dir"></a>working_dir |  The working directory in which the entrypoint or command will be run   | String | optional |  `""`  |


<a id="docker_compose_volume"></a>

## docker_compose_volume

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_volume")

docker_compose_volume(<a href="#docker_compose_volume-name">name</a>, <a href="#docker_compose_volume-driver">driver</a>, <a href="#docker_compose_volume-driver_opts">driver_opts</a>, <a href="#docker_compose_volume-external">external</a>, <a href="#docker_compose_volume-labels">labels</a>, <a href="#docker_compose_volume-name_override">name_override</a>, <a href="#docker_compose_volume-volume_name">volume_name</a>)
</pre>

Volume configuration for the Compose application.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="docker_compose_volume-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="docker_compose_volume-driver"></a>driver |  Specify which volume driver should be used for this volume.   | String | optional |  `""`  |
| <a id="docker_compose_volume-driver_opts"></a>driver_opts |  Specify driver-specific options.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_volume-external"></a>external |  Specifies that this volume already exists and was created outside of Compose.   | Boolean | optional |  `False`  |
| <a id="docker_compose_volume-labels"></a>labels |  Add metadata to the volume using labels.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="docker_compose_volume-name_override"></a>name_override |  Custom name for this volume.   | String | optional |  `""`  |
| <a id="docker_compose_volume-volume_name"></a>volume_name |  Top-level key for this volume in the rendered project. Defaults to the rule name.   | String | optional |  `""`  |


<a id="ComposeNetworkInfo"></a>

## ComposeNetworkInfo

<pre>
load("@rules_docker_compose//compose:defs.bzl", "ComposeNetworkInfo")

ComposeNetworkInfo(<a href="#ComposeNetworkInfo-network_name">network_name</a>, <a href="#ComposeNetworkInfo-json">json</a>)
</pre>

A network contributed by a target. Shard JSON matches the network schema.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ComposeNetworkInfo-network_name"></a>network_name |  string: top-level key for this network in the rendered project.    |
| <a id="ComposeNetworkInfo-json"></a>json |  File: the JSON shard.    |


<a id="ComposeProjectInfo"></a>

## ComposeProjectInfo

<pre>
load("@rules_docker_compose//compose:defs.bzl", "ComposeProjectInfo")

ComposeProjectInfo(<a href="#ComposeProjectInfo-yaml">yaml</a>)
</pre>

A rendered compose project.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ComposeProjectInfo-yaml"></a>yaml |  File: the rendered compose.yaml.    |


<a id="ComposeServiceImageRefInfo"></a>

## ComposeServiceImageRefInfo

<pre>
load("@rules_docker_compose//compose:defs.bzl", "ComposeServiceImageRefInfo")

ComposeServiceImageRefInfo(<a href="#ComposeServiceImageRefInfo-service_name">service_name</a>, <a href="#ComposeServiceImageRefInfo-file">file</a>)
</pre>

A build-time-resolved `<repo>@<digest>` image reference targeted at a named service.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ComposeServiceImageRefInfo-service_name"></a>service_name |  string: name of the service whose `image:` to override.    |
| <a id="ComposeServiceImageRefInfo-file"></a>file |  File: a one-line text file containing the reference.    |


<a id="ComposeServiceInfo"></a>

## ComposeServiceInfo

<pre>
load("@rules_docker_compose//compose:defs.bzl", "ComposeServiceInfo")

ComposeServiceInfo(<a href="#ComposeServiceInfo-service_name">service_name</a>, <a href="#ComposeServiceInfo-json">json</a>)
</pre>

A service contributed by a target. Shard JSON matches the service schema.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ComposeServiceInfo-service_name"></a>service_name |  string: top-level key for this service in the rendered project.    |
| <a id="ComposeServiceInfo-json"></a>json |  File: the JSON shard.    |


<a id="ComposeVolumeInfo"></a>

## ComposeVolumeInfo

<pre>
load("@rules_docker_compose//compose:defs.bzl", "ComposeVolumeInfo")

ComposeVolumeInfo(<a href="#ComposeVolumeInfo-volume_name">volume_name</a>, <a href="#ComposeVolumeInfo-json">json</a>)
</pre>

A volume contributed by a target. Shard JSON matches the volume schema.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="ComposeVolumeInfo-volume_name"></a>volume_name |  string: top-level key for this volume in the rendered project.    |
| <a id="ComposeVolumeInfo-json"></a>json |  File: the JSON shard.    |


<a id="docker_compose_down"></a>

## docker_compose_down

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_down")

docker_compose_down(<a href="#docker_compose_down-name">name</a>, <a href="#docker_compose_down-project">project</a>, <a href="#docker_compose_down-kwargs">**kwargs</a>)
</pre>

`bazel run :<name>` -> `docker compose -f <generated.yaml> down`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="docker_compose_down-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="docker_compose_down-project"></a>project |  <p align="center"> - </p>   |  none |
| <a id="docker_compose_down-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


<a id="docker_compose_up"></a>

## docker_compose_up

<pre>
load("@rules_docker_compose//compose:defs.bzl", "docker_compose_up")

docker_compose_up(<a href="#docker_compose_up-name">name</a>, <a href="#docker_compose_up-project">project</a>, <a href="#docker_compose_up-kwargs">**kwargs</a>)
</pre>

`bazel run :<name>` -> `docker compose -f <generated.yaml> up`.

Args after `--` are passed through to docker compose
(e.g. `bazel run :stack.up -- -d` for detached mode).

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="docker_compose_up-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="docker_compose_up-project"></a>project |  <p align="center"> - </p>   |  none |
| <a id="docker_compose_up-kwargs"></a>kwargs |  <p align="center"> - </p>   |  none |


