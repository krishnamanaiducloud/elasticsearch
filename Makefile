.PHONY: build smoke scan push all
IMAGENAME=mohankrishna999/elasticsearch
VERSION=9.5.6-patched
build:
	IMAGE=${IMAGENAME}:${VERSION} sh build/build.sh
smoke: build
	docker run --rm -e discovery.type=single-node -e xpack.security.enabled=false ${IMAGENAME}:${VERSION} --version
scan: build
	trivy image --scanners vuln --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 1 ${IMAGENAME}:${VERSION}
	grype ${IMAGENAME}:${VERSION} --fail-on negligible
push:
	IMAGE=${IMAGENAME}:${VERSION} PLATFORMS=linux/amd64,linux/arm64 OUTPUT=--push sh build/build.sh
all: smoke scan push
