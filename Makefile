# pg_durable Makefile

.PHONY: build test test-unit test-e2e clean docker-build docker-push

# Default target
all: build

# Build the extension
build:
	cargo build

# Run all tests (unit + E2E)
test:
	./scripts/test.sh --all

# Run only pgrx unit tests
test-unit:
	./scripts/test.sh --unit

# Run only E2E tests (Docker-based)
test-e2e:
	./scripts/test.sh --e2e

# Build Docker image
docker-build:
	docker build --platform linux/amd64 -t pg_durable:latest .

# Build and push to ACR
docker-push: docker-build
	docker tag pg_durable:latest toygresacr.azurecr.io/pg_durable:latest
	az acr login --name toygresacr
	docker push toygresacr.azurecr.io/pg_durable:latest

# Run local development server
run:
	cargo pgrx run pg17

# Clean build artifacts
clean:
	cargo clean
	rm -rf target/

# Install extension locally
install:
	cargo pgrx install

# Help
help:
	@echo "pg_durable Makefile targets:"
	@echo ""
	@echo "  build         - Build the extension"
	@echo "  test          - Run all tests (unit + E2E)"
	@echo "  test-unit     - Run pgrx unit tests only"
	@echo "  test-e2e      - Run E2E tests only (Docker)"
	@echo "  docker-build  - Build Docker image"
	@echo "  docker-push   - Build and push to ACR"
	@echo "  run           - Start local pgrx dev server"
	@echo "  clean         - Clean build artifacts"
	@echo "  install       - Install extension locally"

