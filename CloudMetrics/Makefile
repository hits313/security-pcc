SDK  ?= iphoneos
ARCH ?= arm64

REPO_ROOT ?= $(shell git rev-parse --show-toplevel)
BUILD_DIR := ${REPO_ROOT}/build
ROOTS_DIR := ${BUILD_DIR}/roots

ABI_DERIVED_DATA := ${REPO_ROOT}/.ABI_DerivedData
ABI_BASELINES_DIR := ${REPO_ROOT}/ABI_Baselines
ABI_COLLECTION_SCRIPT := ${REPO_ROOT}/SupportingFiles/Scripts/ABICollection.sh

.default: help
.PHONY: help
help:
	@echo "-------- building ----------------------------------------------------"
	@echo "build:   builds the CloudMetrics xcodeworkspace with xcodebuild"
	@echo "buildit: builds the CloudMetrics xcodeworkspace with buildit"
	@echo "package: packages up built roots for use with purple restore"
	@echo "clean:   deletes all built products"
	@echo "-------- utilities ---------------------------------------------------"
	@echo "defang:  disables code signing requirements for local development"
	@echo "refang:  renables standard code signing requirements"
	@echo "-------- abi breakage checker ----------------------------------------"
	@echo "abi:     regenerate ABI baseline files"

# roots ------------------------------------------------------------------------
.PHONY: lint
lint:
	@echo "linting..."
	@swiftlint lint --quiet --strict --config .swiftlint.yml Sources

.PHONY: build lint
build:
	@echo "building..."
	@mkdir -p ${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}
	@xcodebuild \
		-project CloudMetrics.xcodeproj \
		-sdk ${SDK}.internal \
		-arch ${ARCH} \
		-scheme skywagon_macos \
		install DSTROOT=${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH} \
		SRCROOT=${REPO_ROOT}

.PHONY: package
package:
	@echo "packaging roots..."
	@for root in `find ${ROOTS_DIR} -type d -maxdepth 1 -mindepth 1` ; do \
		echo "packaging root: $${root}" ; \
		tar --uid 0 --gid 0 -C $${root} -cz -f $${root}.root.tar.gz . ; \
	done

	@pushd "${ROOTS_DIR}"
	@sudo rm -f "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.dmg"
	@sudo mkdir -p "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.root"
	@sudo tar -xvf "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.root.tar.gz" -C "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.root"
	@sudo hdiutil create -fs HFS+ -layout NONE -srcfolder "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.root" "${ROOTS_DIR}/CloudMetrics-${SDK}-${ARCH}.dmg"


.PHONY: clean
clean:
	@echo "cleaning..."
	rm -rf ${BUILD_DIR}

# utilities --------------------------------------------------------------------
.PHONY: defang
defang:
	sudo defaults write \
		/Library/Preferences/com.apple.security.coderequirements \
		Entitlements -string always

.PHONY: refang
refang:
	sudo defaults delete \
		/Library/Preferences/com.apple.security.coderequirements \
		Entitlements

.PHONY: buildit
buildit: clean
	@echo "building..."
	@sudo xbs buildit . \
		-release SilverLining \
		-project CloudMetrics
	@rm -rf ${ABI_DERIVED_DATA}	

.PHONY: abi
abi:
	@echo "Building abi schema..."
	@xcodebuild \
		-project CloudMetrics.xcodeproj \
		-scheme abi \
		-destination generic/platform=iOS \
		-destination generic/platform=macOS \
		-derivedDataPath ${ABI_DERIVED_DATA} \
		RUN_SWIFT_ABI_CHECKER_TOOL=NO
	@${ABI_COLLECTION_SCRIPT} ${ABI_DERIVED_DATA} ${ABI_BASELINES_DIR}

.PHONY: protos
protos:
	protoc Tests/FakeOTLPServer/Protos/*.proto --grpc-swift_out=. --swift_out=. --grpc-swift_opt=Client=false
