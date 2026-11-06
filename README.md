# Elasticsearch hardened image

Elasticsearch 8.19.24 repackaged from Elastic's official Linux release archive (SHA-512 verified)
on a current Chainguard Wolfi runtime, with the OpenJDK 27.0.1 that Elastic bundles in 8.19.24.
Third-party jars with known vulnerabilities are replaced by fixed releases from Maven Central, each
pinned by SHA-256 in `build/jars.txt`. Published as
`mohankrishna999/elasticsearch:8.19.24-patched` for amd64 and arm64.

The image follows Elastic's Docker distribution: settings can be passed as environment variables
(for example `discovery.type=single-node`), logs go to the console, and the entrypoint handles
`ELASTIC_PASSWORD`. It preserves ports 9200/9300 and `/usr/share/elasticsearch`, runs as UID 1000
with primary GID 0, and keeps `config`, `data`, `logs` and `plugins` group-writable for OpenShift's
arbitrary UID model. Use a persistent volume at `/usr/share/elasticsearch/data`.

## Known scanner findings

Trivy reports no vulnerabilities. Grype reports one, for which no fix is available yet:

- CVE-2026-84243 in glibc 2.44 (matched through NVD). Neither Wolfi nor Chainguard ships a patched
  glibc yet. The image will be rebuilt under a new tag once one is available.
