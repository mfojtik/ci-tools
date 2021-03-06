# Old-skool build tools.
#
# Targets (see each target for more information):
#   all: Build code.
#   build: Build code.
#   test: Run all tests.
#   clean: Clean up.

OUT_DIR = _output
OS_OUTPUT_GOPATH ?= 1

export GOFLAGS
export TESTFLAGS

# Tests run using `make` are most often run by the CI system, so we are OK to
# assume the user wants jUnit output and will turn it off if they don't.
JUNIT_REPORT ?= true

# Build code.
#
# Args:
#   WHAT: Directory names to build.  If any of these directories has a 'main'
#     package, the build will produce executable files under $(OUT_DIR)/local/bin.
#     If not specified, "everything" will be built.
#   GOFLAGS: Extra flags to pass to 'go' when building.
#   TESTFLAGS: Extra flags that should only be passed to hack/test-go.sh
#
# Example:
#   make
#   make all
#   make all WHAT=cmd/oc GOFLAGS=-v
all build:
	hack/build-go.sh $(WHAT) $(GOFLAGS)
.PHONY: all build

# Verify code conventions are properly setup.
#
# Example:
#   make verify
verify:
	{ \
	hack/verify-gofmt.sh ||r=1;\
	hack/verify-govet.sh ||r=1;\
	make verify-gen || rc=1;\
	exit $$r ;\
	}
.PHONY: verify

# Verify code conventions are properly setup.
#
# Example:
#   make lint
lint:
	./hack/lint.sh
.PHONY: lint

# Run unit tests.
#
# Args:
#   GOFLAGS: Extra flags to pass to 'go' when building.
#
# Example:
#   make test
test:
	GOTEST_FLAGS="$(TESTFLAGS)" hack/test-go.sh
.PHONY: test

# Remove all build artifacts.
#
# Example:
#   make clean
clean:
	rm -rf $(OUT_DIR)
.PHONY: clean

# Format all Go source code.
#
# Example:
#   make format
format:
	gofmt -s -w $(shell go list -f '{{ .Dir }}' ./... )
.PHONY: format

# Update vendored code and manifests to ensure formatting.
#
# Example:
#   make update-vendor
update-vendor:
	docker run --rm \
		--user=$$UID \
		-v $$(go env GOCACHE):/.cache:Z \
		-v $$PWD:/go/src/github.com/openshift/ci-tools:Z \
		-w /go/src/github.com/openshift/ci-tools \
		-e GO111MODULE=on \
		-e GOPROXY=https://proxy.golang.org \
		golang:1.14 \
		/bin/bash -c "go mod tidy && go mod vendor"
.PHONY: update-vendor
SHELL=/usr/bin/env bash -o pipefail

# Validate vendored code and manifests to ensure formatting.
#
# Example:
#   make validate-vendor
validate-vendor:
	go version
	GO111MODULE=on GOPROXY=https://proxy.golang.org go mod tidy
	GO111MODULE=on GOPROXY=https://proxy.golang.org go mod vendor
	git status -s ./vendor/ go.mod go.sum
	test -z "$$(git status -s ./vendor/ go.mod go.sum | grep -v vendor/modules.txt)"
.PHONY: validate-vendor

# Install Go binaries to $GOPATH/bin.
#
# Example:
#   make install
install:
	go install ./cmd/...
.PHONY: install

# Install Go binaries to $GOPATH/bin.
# Set version and name variables.
#
# Example:
#   make production-install
production-install:
	hack/install.sh
.PHONY: production-install

# Run integration tests.
#
# Accepts a specific suite to run as an argument.
#
# Example:
#   make integration
#   make integration SUITE=multi-stage
integration:
	# legacy, so we don't break them
	test/secret-wrapper-integration.sh
	hack/test-integration.sh $(SUITE)
.PHONY: integration

# Run e2e tests.
#
# Accepts a specific suite to run as an argument.
#
# Example:
#   make e2e
#   make e2e SUITE=multi-stage
e2e:
	hack/test-e2e.sh $(SUITE)
.PHONY: e2e

# Update golden output files for integration tests.
#
# Example:
#   make update-integration
#   make update-integration SUITE=multi-stage
update-integration:
	UPDATE=true make integration
.PHONY: update-integration

pr-deploy-configresolver:
	$(eval USER=$(shell curl --fail -Ss https://api.github.com/repos/openshift/ci-tools/pulls/$(PULL_REQUEST)|jq -r .head.user.login))
	$(eval BRANCH=$(shell curl --fail -Ss https://api.github.com/repos/openshift/ci-tools/pulls/$(PULL_REQUEST)|jq -r .head.ref))
	oc --context app.ci --as system:admin process -p USER=$(USER) -p BRANCH=$(BRANCH) -p PULL_REQUEST=$(PULL_REQUEST) -f hack/pr-deploy.yaml | oc  --context app.ci --as system:admin apply -f -
	for cm in ci-operator-master-configs step-registry config; do oc  --context app.ci --as system:admin get --export configmap $${cm} -n ci -o json | oc  --context app.ci --as system:admin create -f - -n ci-tools-$(PULL_REQUEST); done
	echo "server is at https://$$( oc  --context app.ci --as system:admin get route server -n ci-tools-$(PULL_REQUEST) -o jsonpath={.spec.host} )"
.PHONY: pr-deploy

pr-deploy-backporter:
	$(eval USER=$(shell curl --fail -Ss https://api.github.com/repos/openshift/ci-tools/pulls/$(PULL_REQUEST)|jq -r .head.user.login))
	$(eval BRANCH=$(shell curl --fail -Ss https://api.github.com/repos/openshift/ci-tools/pulls/$(PULL_REQUEST)|jq -r .head.ref))
	oc --context app.ci --as system:admin process -p USER=$(USER) -p BRANCH=$(BRANCH) -p PULL_REQUEST=$(PULL_REQUEST) -f hack/pr-deploy-backporter.yaml | oc  --context app.ci --as system:admin apply -f -
	oc  --context app.ci --as system:admin get --export configmap plugins -n ci -o json | oc  --context app.ci --as system:admin create -f - -n ci-tools-$(PULL_REQUEST)
	oc  --context app.ci --as system:admin get --export secret bugzilla-credentials-openshift-bugzilla-robot -n ci -o json | oc  --context app.ci --as system:admin create -f - -n ci-tools-$(PULL_REQUEST)
	echo "server is at https://$$( oc  --context app.ci --as system:admin get route bp-server -n ci-tools-$(PULL_REQUEST) -o jsonpath={.spec.host} )"
.PHONY: pr-deploy-backporter

check-breaking-changes:
	test/validate-prowgen-breaking-changes.sh
.PHONY: check-breaking-changes

.PHONY: generate
generate:
	hack/update-codegen.sh

.PHONY: verify-gen
verify-gen: generate
	@if !(git diff --quiet HEAD); then \
		git diff; \
		echo "generated files are out of date, run make generate"; exit 1; \
	fi

update-unit:
	UPDATE=true go test ./...
.PHONY: update-unit
