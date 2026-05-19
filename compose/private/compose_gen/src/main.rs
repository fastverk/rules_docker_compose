//! compose-gen: assemble per-service / per-volume / per-network JSON
//! shards (written by the rules_docker_compose Starlark rules) into a
//! single canonical compose.yaml.
//!
//! The Service / Volume / Network types come from typify-generated
//! bindings produced by `@rules_jsonschema//rust:defs.bzl%jsonschema_rust_library`
//! over the canonical compose-spec schema. The spec is the single
//! source of truth: any field the schema accepts is typed here, and
//! any unknown key in a shard fails decode (typify emits
//! `#[serde(deny_unknown_fields)]` whenever the schema sets
//! `additionalProperties: false`).
//!
//! Subcommands:
//!
//!   compose_gen project --name=NAME --service=name=PATH ... --out=PATH
//!   compose_gen image-ref --layout=DIR --repo=REPO --out=PATH
//!
//! ## Cargo-direct build
//!
//! Building this crate via plain `cargo build` doesn't work because
//! `compose_types` is materialised by Bazel at build time
//! (`jsonschema_rust_library` runs the typify codegen against the pinned
//! `@compose_spec//file:compose-spec.json`). Use `bazel build
//! //compose/private/compose_gen:compose_gen` for the canonical path.
//! For IDE integration, point rust-analyzer at the Bazel-driven
//! workspace (e.g. via the `bazel-buildbuddy-io/rules_rust_analyzer`
//! aspect or `bazel run @rules_rust//tools/rust_analyzer:gen_rust_project`).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde::Serialize;

use compose_types::{Network, Service, Volume};

// --- entry point ----------------------------------------------------

fn main() -> Result<()> {
    let mut argv: Vec<String> = std::env::args().collect();
    // First arg is `project` or `image-ref`; anything starting with
    // `--` means the caller skipped the subcommand and meant `project`.
    let (sub, skip): (&str, usize) = match argv.get(1).map(String::as_str) {
        Some("-h") | Some("--help") => {
            print_help();
            return Ok(());
        }
        Some("project") => ("project", 2),
        Some("image-ref") => ("image-ref", 2),
        Some(other) if !other.starts_with("--") => {
            return Err(anyhow!("unknown subcommand: {other}"));
        }
        _ => ("project", 1),
    };
    argv.drain(0..skip);
    match sub {
        "project" => run_project(argv),
        "image-ref" => run_image_ref(argv),
        _ => unreachable!(),
    }
}

fn print_help() {
    eprintln!(
        "compose-gen — render a docker compose YAML from typed JSON shards

Usage:
  compose_gen project [--name NAME] [--out PATH] [SHARDS...]
    --service NAME=PATH       (repeated) service shard JSON
    --volume  NAME=PATH       (repeated) volume shard JSON
    --network NAME=PATH       (repeated) network shard JSON
    --service-image NAME=PATH (repeated) override service image with
                              file contents (trimmed)

  compose_gen image-ref --layout DIR --repo REPO [--out PATH]
    Walk an OCI image layout's index.json, format its first manifest's
    digest as `<REPO>@<digest>`. Used by docker_compose_oci_image_ref."
    );
}

// --- project subcommand ---------------------------------------------

#[derive(Debug, Default)]
struct ProjectArgs {
    name: Option<String>,
    out: Option<PathBuf>,
    services: Vec<(String, PathBuf)>,
    volumes: Vec<(String, PathBuf)>,
    networks: Vec<(String, PathBuf)>,
    service_images: Vec<(String, PathBuf)>,
}

fn parse_project(argv: &[String]) -> Result<ProjectArgs> {
    let mut out = ProjectArgs::default();
    let mut it = argv.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--name" => out.name = Some(it.next().context("--name requires a value")?.clone()),
            "--out" => out.out = Some(PathBuf::from(it.next().context("--out requires a value")?)),
            "--service" => out
                .services
                .push(split_kv(it.next().context("--service requires name=path")?)?),
            "--volume" => out
                .volumes
                .push(split_kv(it.next().context("--volume requires name=path")?)?),
            "--network" => out
                .networks
                .push(split_kv(it.next().context("--network requires name=path")?)?),
            "--service-image" => out
                .service_images
                .push(split_kv(it.next().context("--service-image requires name=path")?)?),
            other => return Err(anyhow!("unknown flag: {other}")),
        }
    }
    Ok(out)
}

fn run_project(argv: Vec<String>) -> Result<()> {
    let args = parse_project(&argv)?;

    let mut services = decode_shards::<Service>(&args.services, "service")?;
    for (name, path) in &args.service_images {
        apply_service_image_override(&mut services, name, path)?;
    }
    let volumes = decode_shards::<Volume>(&args.volumes, "volume")?;
    let networks = decode_shards::<Network>(&args.networks, "network")?;

    let project = Project {
        name: args.name.as_deref(),
        services: &services,
        volumes: &volumes,
        networks: &networks,
    };
    let yaml = render_project(&project)?;

    match &args.out {
        Some(p) => fs::write(p, yaml).with_context(|| format!("writing {}", p.display()))?,
        None => print!("{yaml}"),
    }
    Ok(())
}

/// Compose project container. typify's `ComposeSpecification` is left
/// unused — its maps use newtype keys (`ComposeSpecificationServicesKey`)
/// that would require wrapping every service name. Our flat `Project`
/// with `BTreeMap<String, ...>` is simpler and gives deterministic
/// top-level field iteration for free.
#[derive(Serialize)]
struct Project<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    services: &'a BTreeMap<String, Service>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    volumes: &'a BTreeMap<String, Volume>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    networks: &'a BTreeMap<String, Network>,
}

/// Serialise a `Project` to canonical YAML. typify mirrors HashMap
/// iteration order at serialization time, so we round-trip through
/// `serde_yaml::Value` to canonicalise: sort every Mapping by key.
/// Also normalises integer-valued floats — see `sort_yaml_maps`.
fn render_project(project: &Project<'_>) -> Result<String> {
    let raw = serde_yaml::to_value(project).context("serializing project")?;
    let sorted = sort_yaml_maps(raw);
    serde_yaml::to_string(&sorted).context("rendering YAML")
}

// --- shard helpers --------------------------------------------------

/// Read a shard as raw JSON. We don't decode straight into the
/// typify-generated `Service`/`Volume`/`Network` here so the caller
/// can give context-rich error messages naming which shard failed.
fn read_shard(path: &Path) -> Result<serde_json::Value> {
    let raw = fs::read_to_string(path)
        .with_context(|| format!("reading shard {}", path.display()))?;
    serde_json::from_str(&raw)
        .with_context(|| format!("parsing shard {}", path.display()))
}

/// Decode every `(name, path)` shard into `T` (a typify-generated
/// struct), collecting into a BTreeMap so the YAML emission is
/// deterministically sorted. `category` only feeds the error string.
fn decode_shards<T>(shards: &[(String, PathBuf)], category: &str) -> Result<BTreeMap<String, T>>
where
    T: serde::de::DeserializeOwned,
{
    let mut out = BTreeMap::new();
    for (name, path) in shards {
        let raw = read_shard(path)?;
        let decoded: T = serde_json::from_value(raw).with_context(|| {
            format!("decoding {category} shard for '{name}' at {}", path.display())
        })?;
        out.insert(name.clone(), decoded);
    }
    Ok(out)
}

/// Replace `services[name].image` with the trimmed contents of the
/// file at `path`. Used to thread build-time-resolved OCI digests
/// (`docker_compose_oci_image_ref`) into the rendered compose YAML.
fn apply_service_image_override(
    services: &mut BTreeMap<String, Service>,
    name: &str,
    path: &Path,
) -> Result<()> {
    let svc = services
        .get_mut(name)
        .ok_or_else(|| anyhow!("--service-image references unknown service '{name}'"))?;
    let ref_str = fs::read_to_string(path)
        .with_context(|| format!("reading image-ref file {}", path.display()))?;
    svc.image = Some(ref_str.trim().to_string());
    Ok(())
}

// --- YAML canonicalisation ------------------------------------------

/// Recursively normalise every YAML node:
///   - mappings → key-sorted
///   - sequences → recurse (order preserved — meaningful in YAML)
///   - integer-valued floats → integers
///
/// The integer-valued-float normalisation matters because several
/// compose-spec fields (notably `healthcheck.retries`) declare their
/// schema as `["number", "string"]`. typify chooses f64 for the number
/// variant, which serde_yaml then renders as e.g. `3.0`. Compose
/// itself accepts both forms, but `3` reads better and matches what
/// every hand-authored compose file in the wild uses.
fn sort_yaml_maps(value: serde_yaml::Value) -> serde_yaml::Value {
    match value {
        serde_yaml::Value::Mapping(map) => {
            let mut entries: Vec<(serde_yaml::Value, serde_yaml::Value)> = map
                .into_iter()
                .map(|(k, v)| (k, sort_yaml_maps(v)))
                .collect();
            entries.sort_by(|a, b| compare_yaml(&a.0, &b.0));
            let mut sorted = serde_yaml::Mapping::with_capacity(entries.len());
            for (k, v) in entries {
                sorted.insert(k, v);
            }
            serde_yaml::Value::Mapping(sorted)
        }
        serde_yaml::Value::Sequence(seq) => {
            serde_yaml::Value::Sequence(seq.into_iter().map(sort_yaml_maps).collect())
        }
        serde_yaml::Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                if f.is_finite() && f == f.trunc() && (i64::MIN as f64..=i64::MAX as f64).contains(&f) {
                    return serde_yaml::Value::Number(serde_yaml::Number::from(f as i64));
                }
            }
            serde_yaml::Value::Number(n)
        }
        other => other,
    }
}

fn compare_yaml(a: &serde_yaml::Value, b: &serde_yaml::Value) -> std::cmp::Ordering {
    use serde_yaml::Value::*;
    match (a, b) {
        (String(x), String(y)) => x.cmp(y),
        // Mixed-type map keys are vanishingly rare in compose files;
        // fall back to debug-string comparison so the output stays
        // deterministic even if they occur.
        (x, y) => format!("{x:?}").cmp(&format!("{y:?}")),
    }
}

// --- image-ref subcommand -------------------------------------------

struct ImageRefArgs {
    layout: PathBuf,
    repo: String,
    out: Option<PathBuf>,
}

fn parse_image_ref(argv: &[String]) -> Result<ImageRefArgs> {
    let mut layout = None;
    let mut repo = None;
    let mut out = None;
    let mut it = argv.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--layout" => layout = Some(PathBuf::from(it.next().context("--layout requires value")?)),
            "--repo" => repo = Some(it.next().context("--repo requires value")?.clone()),
            "--out" => out = Some(PathBuf::from(it.next().context("--out requires value")?)),
            other => return Err(anyhow!("unknown flag: {other}")),
        }
    }
    Ok(ImageRefArgs {
        layout: layout.ok_or_else(|| anyhow!("--layout is required"))?,
        repo: repo.ok_or_else(|| anyhow!("--repo is required"))?,
        out,
    })
}

fn run_image_ref(argv: Vec<String>) -> Result<()> {
    let args = parse_image_ref(&argv)?;
    let reference = resolve_image_ref(&args.layout, &args.repo)?;
    match &args.out {
        Some(p) => fs::write(p, format!("{reference}\n"))
            .with_context(|| format!("writing {}", p.display()))?,
        None => println!("{reference}"),
    }
    Ok(())
}

/// Locate the `index.json` under `layout`, parse the first manifest's
/// digest, and return `<repo>@<digest>`. Pulled out of `run_image_ref`
/// so it's directly testable without touching argv / file output.
fn resolve_image_ref(layout: &Path, repo: &str) -> Result<String> {
    let index_path = find_index_json(layout)
        .ok_or_else(|| anyhow!("no index.json under {}", layout.display()))?;
    let raw = fs::read_to_string(&index_path)
        .with_context(|| format!("reading {}", index_path.display()))?;
    // OCI index.json is an external schema; decode permissively.
    let idx: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", index_path.display()))?;
    let digest = idx
        .pointer("/manifests/0/digest")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("index.json has no manifests[0].digest"))?;
    Ok(format!("{repo}@{digest}"))
}

/// rules_oci's `oci_image` declares its layout as a directory output.
/// Accept either the directory itself or any direct sub-directory
/// holding `index.json` — TreeArtifact propagation occasionally nests
/// the layout under a rule-named sub-dir.
fn find_index_json(p: &Path) -> Option<PathBuf> {
    let meta = fs::metadata(p).ok()?;
    if !meta.is_dir() {
        return if p.file_name().and_then(|n| n.to_str()) == Some("index.json") {
            Some(p.to_path_buf())
        } else {
            None
        };
    }
    let direct = p.join("index.json");
    if direct.exists() {
        return Some(direct);
    }
    for entry in fs::read_dir(p).ok()? {
        let entry = entry.ok()?;
        if entry.file_type().ok()?.is_dir() {
            let candidate = entry.path().join("index.json");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    None
}

// --- misc helpers ---------------------------------------------------

/// Split `"name=path"` into a `(String, PathBuf)` tuple for the
/// repeated `--service`/`--volume`/`--network`/`--service-image` flags.
fn split_kv(s: &str) -> Result<(String, PathBuf)> {
    let idx = s
        .find('=')
        .ok_or_else(|| anyhow!("expected name=path, got {s:?}"))?;
    Ok((s[..idx].to_string(), PathBuf::from(&s[idx + 1..])))
}

// --- tests ----------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_yaml::Value;

    // --- argv parsing -------------------------------------------------

    #[test]
    fn parse_project_handles_each_flag() {
        let argv: Vec<String> = [
            "--name", "demo",
            "--out", "/tmp/out.yaml",
            "--service", "web=/tmp/web.json",
            "--service", "redis=/tmp/redis.json",
            "--volume", "cache=/tmp/cache.json",
            "--network", "appnet=/tmp/appnet.json",
            "--service-image", "worker=/tmp/worker-ref.txt",
        ]
        .iter()
        .map(|&s| s.to_string())
        .collect();
        let a = parse_project(&argv).unwrap();
        assert_eq!(a.name.as_deref(), Some("demo"));
        assert_eq!(a.out, Some(PathBuf::from("/tmp/out.yaml")));
        assert_eq!(a.services.len(), 2);
        assert_eq!(a.services[1], ("redis".into(), PathBuf::from("/tmp/redis.json")));
        assert_eq!(a.volumes.len(), 1);
        assert_eq!(a.networks.len(), 1);
        assert_eq!(a.service_images.len(), 1);
    }

    #[test]
    fn parse_project_rejects_missing_value() {
        let argv = vec!["--name".to_string()];
        assert!(parse_project(&argv).is_err());
    }

    #[test]
    fn parse_project_rejects_unknown_flag() {
        let argv = vec!["--bogus".to_string()];
        assert!(parse_project(&argv).is_err());
    }

    #[test]
    fn parse_project_rejects_malformed_kv() {
        let argv = vec!["--service".into(), "no-equals-sign".into()];
        let err = parse_project(&argv).unwrap_err();
        assert!(err.to_string().contains("name=path"), "{err}");
    }

    #[test]
    fn parse_image_ref_happy_path() {
        let argv: Vec<String> = [
            "--layout", "/tmp/layout",
            "--repo", "ghcr.io/foo/bar",
            "--out", "/tmp/ref.txt",
        ]
        .iter()
        .map(|&s| s.to_string())
        .collect();
        let a = parse_image_ref(&argv).unwrap();
        assert_eq!(a.layout, PathBuf::from("/tmp/layout"));
        assert_eq!(a.repo, "ghcr.io/foo/bar");
        assert_eq!(a.out, Some(PathBuf::from("/tmp/ref.txt")));
    }

    #[test]
    fn parse_image_ref_requires_layout_and_repo() {
        assert!(parse_image_ref(&["--layout".into(), "x".into()]).is_err());
        assert!(parse_image_ref(&["--repo".into(), "x".into()]).is_err());
    }

    // --- sort_yaml_maps ----------------------------------------------

    #[test]
    fn sort_yaml_maps_sorts_keys() {
        let raw: Value = serde_yaml::from_str("zeta: 1\nalpha: 2\nmu: 3\n").unwrap();
        let sorted = sort_yaml_maps(raw);
        let out = serde_yaml::to_string(&sorted).unwrap();
        let alpha = out.find("alpha:").unwrap();
        let mu = out.find("mu:").unwrap();
        let zeta = out.find("zeta:").unwrap();
        assert!(alpha < mu && mu < zeta, "got: {out}");
    }

    #[test]
    fn sort_yaml_maps_normalises_integer_valued_floats() {
        let mut map = serde_yaml::Mapping::new();
        map.insert(Value::String("retries".into()), Value::from(3.0_f64));
        let sorted = sort_yaml_maps(Value::Mapping(map));
        let out = serde_yaml::to_string(&sorted).unwrap();
        assert_eq!(out.trim(), "retries: 3");
    }

    #[test]
    fn sort_yaml_maps_leaves_fractional_floats_alone() {
        let mut map = serde_yaml::Mapping::new();
        map.insert(Value::String("cpus".into()), Value::from(1.5_f64));
        let sorted = sort_yaml_maps(Value::Mapping(map));
        let out = serde_yaml::to_string(&sorted).unwrap();
        assert_eq!(out.trim(), "cpus: 1.5");
    }

    #[test]
    fn sort_yaml_maps_recurses_into_sequences_and_nested_maps() {
        let raw: Value = serde_yaml::from_str(
            "outer:\n  zeta: 1.0\n  alpha:\n    - b\n    - a\n",
        )
        .unwrap();
        let sorted = sort_yaml_maps(raw);
        let out = serde_yaml::to_string(&sorted).unwrap();
        assert!(out.find("alpha:").unwrap() < out.find("zeta:").unwrap());
        assert!(out.contains("zeta: 1\n"), "got: {out}");
        let a_pos = out.find("- a").unwrap();
        let b_pos = out.find("- b").unwrap();
        assert!(b_pos < a_pos, "sequences should preserve order: {out}");
    }

    // --- end-to-end YAML round-trip via render_project ----------------

    #[test]
    fn render_project_produces_sorted_canonical_yaml() {
        let mut services: BTreeMap<String, Service> = BTreeMap::new();
        services.insert(
            "zeta".into(),
            Service {
                image: Some("nginx".into()),
                ..Default::default()
            },
        );
        services.insert(
            "alpha".into(),
            Service {
                image: Some("redis".into()),
                ..Default::default()
            },
        );
        let volumes = BTreeMap::new();
        let networks = BTreeMap::new();
        let project = Project {
            name: Some("demo"),
            services: &services,
            volumes: &volumes,
            networks: &networks,
        };
        let yaml = render_project(&project).unwrap();
        // Top-level fields appear and services come out sorted.
        assert!(yaml.starts_with("name: demo\n"), "{yaml}");
        let alpha = yaml.find("alpha:").unwrap();
        let zeta = yaml.find("zeta:").unwrap();
        assert!(alpha < zeta, "services not sorted:\n{yaml}");
        // Empty volumes/networks maps are skipped.
        assert!(!yaml.contains("volumes:"), "{yaml}");
        assert!(!yaml.contains("networks:"), "{yaml}");
    }

    // --- find_index_json --------------------------------------------

    #[test]
    fn find_index_json_direct_layout() {
        let dir = tempfile_dir();
        let index = dir.join("index.json");
        std::fs::write(&index, br#"{"manifests":[]}"#).unwrap();
        assert_eq!(find_index_json(&dir), Some(index));
    }

    #[test]
    fn find_index_json_nested_layout() {
        let dir = tempfile_dir();
        let inner = dir.join("inner");
        std::fs::create_dir_all(&inner).unwrap();
        let index = inner.join("index.json");
        std::fs::write(&index, br#"{"manifests":[]}"#).unwrap();
        assert_eq!(find_index_json(&dir), Some(index));
    }

    #[test]
    fn find_index_json_file_path_passes_through() {
        let dir = tempfile_dir();
        let index = dir.join("index.json");
        std::fs::write(&index, b"{}").unwrap();
        assert_eq!(find_index_json(&index), Some(index));
    }

    #[test]
    fn find_index_json_returns_none_on_miss() {
        let dir = tempfile_dir();
        assert_eq!(find_index_json(&dir), None);
    }

    // --- resolve_image_ref -------------------------------------------

    #[test]
    fn resolve_image_ref_happy_path() {
        let dir = tempfile_dir();
        std::fs::write(
            dir.join("index.json"),
            br#"{
                "schemaVersion": 2,
                "manifests": [
                    {"mediaType": "application/vnd.oci.image.manifest.v1+json",
                     "digest": "sha256:cafef00d", "size": 100}
                ]
            }"#,
        )
        .unwrap();
        let got = resolve_image_ref(&dir, "ghcr.io/foo/bar").unwrap();
        assert_eq!(got, "ghcr.io/foo/bar@sha256:cafef00d");
    }

    #[test]
    fn resolve_image_ref_fails_on_missing_digest() {
        let dir = tempfile_dir();
        std::fs::write(dir.join("index.json"), br#"{"manifests":[]}"#).unwrap();
        let err = resolve_image_ref(&dir, "x").unwrap_err();
        assert!(err.to_string().contains("manifests[0].digest"), "{err}");
    }

    // --- apply_service_image_override --------------------------------

    #[test]
    fn apply_service_image_override_trims_and_replaces() {
        let mut services: BTreeMap<String, Service> = BTreeMap::new();
        services.insert(
            "web".into(),
            Service {
                image: Some("placeholder".into()),
                ..Default::default()
            },
        );

        let dir = tempfile_dir();
        let ref_file = dir.join("ref.txt");
        std::fs::write(&ref_file, "ghcr.io/foo/bar@sha256:cafe\n").unwrap();

        apply_service_image_override(&mut services, "web", &ref_file).unwrap();
        assert_eq!(
            services["web"].image.as_deref(),
            Some("ghcr.io/foo/bar@sha256:cafe")
        );
    }

    #[test]
    fn apply_service_image_override_fails_on_unknown_service() {
        let mut services: BTreeMap<String, Service> = BTreeMap::new();
        let dir = tempfile_dir();
        let ref_file = dir.join("ref.txt");
        std::fs::write(&ref_file, "x").unwrap();
        let err = apply_service_image_override(&mut services, "ghost", &ref_file).unwrap_err();
        assert!(err.to_string().contains("ghost"), "{err}");
    }

    // --- helpers ------------------------------------------------------

    /// Bazel's rust_test sandboxes the cwd and `TEST_TMPDIR`. We
    /// deliberately avoid pulling in `tempfile` (extra crate dep) and
    /// hand-roll a per-test directory whose name is unique enough.
    fn tempfile_dir() -> PathBuf {
        let base = std::env::var_os("TEST_TMPDIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let unique = format!(
            "compose_gen_test_{}_{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        let p = base.join(unique);
        std::fs::create_dir_all(&p).unwrap();
        p
    }
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
}
