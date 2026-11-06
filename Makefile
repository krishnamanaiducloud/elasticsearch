.PHONY: build smoke scan builder push all
IMAGENAME=mohankrishna999/elasticsearch
VERSION=8.19.19-patched
PLATFORMS=linux/amd64,linux/arm64
BUILDER=securebridge
build:
	docker buildx build --load --platform linux/amd64 -t ${IMAGENAME}:${VERSION} .
smoke: build
	docker run --rm ${IMAGENAME}:${VERSION} elasticsearch --version
scan: build
	trivy image --scanners vuln --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --exit-code 1 ${IMAGENAME}:${VERSION}
	grype ${IMAGENAME}:${VERSION} --fail-on negligible
builder:
	docker buildx inspect ${BUILDER} >/dev/null 2>&1 || docker buildx create --name ${BUILDER} --driver docker-container >/dev/null
push: builder
	docker buildx build --builder ${BUILDER} --platform ${PLATFORMS} --sbom=true --provenance=mode=max -t ${IMAGENAME}:${VERSION} --push .
all: smoke scan push
