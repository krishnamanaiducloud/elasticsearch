# Elasticsearch hardened image

Elasticsearch 9.5.6 repackaged from Elastic's official Linux release archive (SHA-512 verified)
on a current Chainguard Wolfi runtime, with the OpenJDK 27.0.1 that Elastic bundles in 9.5.6.
Third-party jars with known vulnerabilities are replaced by fixed releases from Maven Central, each
pinned by SHA-256 in `build/jars.txt`. Published as
`mohankrishna999/elasticsearch:9.5.6.1-patched` for amd64 and arm64.

The image follows Elastic's Docker distribution: settings can be passed as environment variables
(for example `discovery.type=single-node`), logs go to the console, the entrypoint handles
`ELASTIC_PASSWORD`, and `curl` is available for health checks. It preserves ports 9200/9300 and
`/usr/share/elasticsearch`, runs as UID 1000 with primary GID 0, and keeps `config`, `data`, `logs`
and `plugins` group-writable for OpenShift's arbitrary UID model. Use a persistent volume at
`/usr/share/elasticsearch/data`.

## 9.5.6.1-patched

Earlier `9.5.6-patched` images were built from source and ran on Wolfi's OpenJDK 21 with
`bin/elasticsearch` as the entrypoint. This release uses Elastic's release archive, bundled JDK and
Docker entrypoint, as the 8.19 images do.

Jar changes in `build/jars.txt`:

- guava 32.0.1-jre and 33.4.0-jre to 33.8.0-jre, with failureaccess 1.0.3 (CVE-2026-102554).
  Affected modules: `x-pack-security`, `x-pack-watcher`, `x-pack-identity-provider`,
  `x-pack-inference`, `repository-gcs`, `esql-datasource-gcs` and `esql-datasource-grpc`.
  `x-pack-inference` had no failureaccess and gets one, because guava 33 requires it.
- OpenTelemetry API 1.62.0 to 1.67.0 in `repository-gcs` and `esql-datasource-gcs`
  (CVE-2026-118259, quadratic parsing of W3C `tracestate` headers).
- The `apm` module moves to the newest aligned OpenTelemetry release set (CVE-2026-118259). It runs
  the OpenTelemetry SDK, which upstream releases and tests as one version, so the whole set moves
  together:
  - OpenTelemetry 1.64.0 to 1.67.0: API, SDK, OTLP exporters and the OkHttp sender.
  - Instrumentation 2.30.0 to 2.33.1.
  - Semantic conventions 1.43.0 to 1.44.0.
  - Disk buffering 1.59.0 to 1.62.1, with wire-runtime 7.1.2, OkHttp 5.5.0 and Okio 3.18.2, which
    these releases are built against.
- commons-lang3 3.9 to 3.20.0 in `x-pack-ent-search` (CVE-2025-48924).
- elastic-apm-agent 1.55.6 to 1.57.1, which bundles log4j-api 2.26.1 instead of 2.25.4
  (CVE-2026-49844).
- The SQL CLI's shaded jline 3.21.0 to 3.30.17, with JNA 5.19.1 (CVE-2026-77420), as in 8.19.24.
- Two shaded bundles are rebuilt with fixed releases of the libraries they embed. This is done by
  `build/Reshade.java`, a `reshade` operation in `patch-jars.sh`.
  - `iceberg-bundled-guava-1.10.2` embeds a relocated guava 33.4.8; it now embeds guava 33.8.0
    with failureaccess 1.0.3 (CVE-2026-102554).
  - `parquet-hadoop-bundle-1.18.1` embeds a relocated jackson-core and jackson-databind 2.22.2; it
    now embeds 2.22.4 (CVE-2026-89407, CVE-2026-89425, CVE-2026-91776, CVE-2026-91777).
  - Both are already the newest releases of these bundles, and both still embed vulnerable
    versions upstream.
  - The bundle keeps its selection of classes and its relocation, and its own files stay as they
    were. Given the old guava and jackson jars, the tool rebuilds both original bundles class for
    class.

Verified on the built image, side by side with Elastic's `elasticsearch:9.5.6` image:

- **Linkage:** an ASM-based check covers every module with a changed jar, and the SQL CLI. Every
  class, method and field reference into those modules' jars resolves as it does in Elastic's image.
- **Cluster:**
  - Two nodes form a green cluster with transport compression on.
  - YAML, CBOR and Smile requests and responses work, as do SQL over REST and the SQL CLI terminal
    (jline 3.30).
  - ingest-attachment, the ML native controller, the inference API and ent-search all work, as
    does Watcher, including an email action.
  - The Azure and GCS repository clients build.
- **APM:** the APM agent 1.57.1 attaches and tracing starts. With OpenTelemetry metrics export
  enabled, the following happen as in Elastic's image:
  - metrics are buffered to disk while the OTLP endpoint is down
  - they are replayed when it comes back
  - after that, they are exported every interval
- **Security:** default security sets up TLS. HTTPS with authentication works and anonymous
  requests are rejected.

## Known scanner findings

Trivy reports no vulnerabilities. Elastic's `elasticsearch:9.5.6` image has 255. Grype reports two,
neither of which has a fix yet:

- CVE-2026-84243 in glibc 2.44 (matched through NVD). Neither Wolfi nor Chainguard ships a patched
  glibc yet.
- CVE-2026-119586 in sqlite-libs 3.54.1. It affects the sqlite3 command-line shell, which is not
  installed. The library comes in with `curl`: libcurl needs libldap, and every Wolfi libsasl2
  build depends on SQLite. No fixed SQLite release exists yet.

The image will be rebuilt under a new tag as fixes become available.
