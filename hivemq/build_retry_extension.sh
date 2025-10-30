#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_NAME="retry-priority-extension"
EXTENSIONS_DIR="${SCRIPT_DIR}/hivemq_broker/extensions"

echo "Building ${EXTENSION_NAME} ..."
docker buildx build -t retry_extension_builder -f "${SCRIPT_DIR}/build_retry_extension_dockerfile" "${SCRIPT_DIR}"
docker run --rm -v "${SCRIPT_DIR}/retry-priority-extension:/app" retry_extension_builder gradle hivemqExtensionZip

echo "Cleaning previous extension installation ..."
rm -rfv "${EXTENSIONS_DIR}/${EXTENSION_NAME}"

echo "Extracting extension to HiveMQ extensions directory ..."
unzip -q "${SCRIPT_DIR}/retry-priority-extension/build/hivemq-extension/${EXTENSION_NAME}-1.0.0.zip" -d "${EXTENSIONS_DIR}"

echo "Build complete! Extension installed to hivemq_broker/extensions/${EXTENSION_NAME}/"
echo "Extension structure:"
ls -la "${EXTENSIONS_DIR}/${EXTENSION_NAME}"
