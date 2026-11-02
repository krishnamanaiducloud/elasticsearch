# Elasticsearch hardened source build

Elasticsearch 9.5.6 built from the verified upstream release commit. Its Gradle-built
Linux distributions are repackaged without the bundled JDK and run on the current
Chainguard Wolfi OpenJDK 21 runtime. Published as
`mohankrishna999/elasticsearch:9.5.6-patched` for amd64 and arm64.

The image preserves ports 9200/9300 and `/usr/share/elasticsearch`, runs as UID 1000 with
primary GID 0, and keeps the configuration and data paths group-writable for OpenShift's
arbitrary UID model. Use a persistent volume at `/usr/share/elasticsearch/data`.
