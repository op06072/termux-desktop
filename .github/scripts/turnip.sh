#!/bin/bash -e

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

WORKDIR="$(pwd)/turnip_workdir"

log_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PATCHES_DIR="$SCRIPT_DIR/patches"

if [ -z "${MESA_VERSION}" ]; then
	log_error "MESA_VERSION environment variable is required but not provided"
	log_error "Please set MESA_VERSION before running this script"
	echo ""
	echo "Example usage:"
	echo "  MESA_VERSION=25.1.5 $0 aarch64"
	exit 1
fi

MESA_ARCHIVE_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"

BUILD_ARCHITECTURES=()

show_usage() {
	echo "Usage: MESA_VERSION=x.x.x $0 [architecture]"
	echo ""
	echo "Arguments:"
	echo "  aarch64    Build only for ARM64 (64-bit) - native build"
	echo "  arm        Build only for ARM (32-bit) - uses QEMU emulation"
	echo "  <none>     Build for aarch64 only (default)"
	echo ""
	echo "Environment Variables:"
	echo "  MESA_VERSION    Mesa version to build (REQUIRED - no default)"
	echo ""
	echo "Examples:"
	echo "  MESA_VERSION=25.1.5 $0              # Build for aarch64"
	echo "  MESA_VERSION=25.1.5 $0 aarch64      # Build for ARM64"
	echo "  MESA_VERSION=25.1.5 $0 arm          # Build for ARM32 (QEMU)"
	echo ""
	echo "Patches:"
	echo "  The script will automatically apply patches from the 'patches' directory"
	echo "  located in the same directory as this script. Patches are applied in"
	echo "  numerical order (0001, 0002, 0003, etc.)"
	exit 1
}

parse_arguments() {
	log_info "Using Mesa version: $MESA_VERSION"

	if [ $# -eq 0 ]; then
		# No arguments - build for aarch64 only
		BUILD_ARCHITECTURES=(aarch64)
		log_info "No architecture specified - building for aarch64"
	elif [ $# -eq 1 ]; then
		case "$1" in
		aarch64)
			BUILD_ARCHITECTURES=(aarch64)
			log_info "Building for ARM64 (aarch64) - native build"
			;;
		arm)
			BUILD_ARCHITECTURES=(arm)
			log_info "Building for ARM32 - using QEMU emulation"
			;;
		--help | -h)
			show_usage
			;;
		*)
			log_error "Invalid architecture: $1"
			log_error "Valid options: aarch64, arm"
			show_usage
			;;
		esac
	else
		log_error "Too many arguments"
		show_usage
	fi
}

prepare_mesa() {
	log_info "Preparing Mesa source..."

	cd "$WORKDIR"
	local archive_file="mesa-${MESA_VERSION}.tar.xz"
	local extracted_dir="mesa-${MESA_VERSION}"

	if [ ! -f "$archive_file" ]; then
		log_info "Downloading Mesa $MESA_VERSION archive..."
		curl -L "$MESA_ARCHIVE_URL" \
			--output "$archive_file" \
			--progress-bar

		if [ ! -f "$archive_file" ]; then
			log_error "Failed to download Mesa archive"
			exit 1
		fi
		log_success "Mesa archive downloaded"
	else
		log_info "Using existing Mesa archive: $archive_file"
	fi

	if [ -d mesa ]; then
		log_warning "Removing existing Mesa directory"
		rm -rf mesa
	fi

	log_info "Extracting Mesa archive..."
	tar -xf "$archive_file"

	if [ -d "$extracted_dir" ]; then
		mv "$extracted_dir" mesa
	else
		log_error "Extracted directory not found: $extracted_dir"
		exit 1
	fi

	cd mesa

	log_success "Mesa $MESA_VERSION prepared"
}

apply_patches() {
	log_info "Checking for patches in: $PATCHES_DIR"

	if [ ! -d "$PATCHES_DIR" ]; then
		log_info "No patches directory found, skipping patch application"
		return 0
	fi

	cd "$WORKDIR/mesa"

	local patch_files=()
	while IFS= read -r -d '' patch_file; do
		patch_files+=("$patch_file")
	done < <(find "$PATCHES_DIR" -name "*.patch" -type f -print0 | sort -z)

	if [ ${#patch_files[@]} -eq 0 ]; then
		log_info "No patch files found in patches directory, skipping patch application"
		return 0
	fi

	log_info "Found ${#patch_files[@]} patch file(s) to apply"

	for patch_file in "${patch_files[@]}"; do
		local patch_name
		patch_name=$(basename "$patch_file")
		log_info "Applying patch: $patch_name"

		if git apply --check "$patch_file" >/dev/null 2>&1; then
			if git apply "$patch_file"; then
				log_success "Successfully applied patch: $patch_name"
			else
				log_error "Failed to apply patch: $patch_name"
				log_error "Patch application failed, exiting"
				exit 1
			fi
		else
			log_warning "Git apply check failed for $patch_name, trying patch command"
			if patch -p1 --dry-run <"$patch_file" >/dev/null 2>&1; then
				if patch -p1 <"$patch_file"; then
					log_success "Successfully applied patch: $patch_name"
				else
					log_error "Failed to apply patch: $patch_name"
					log_error "Patch application failed, exiting"
					exit 1
				fi
			else
				log_error "Patch $patch_name cannot be applied (dry-run failed)"
				log_error "This may indicate the patch is incompatible with Mesa version $MESA_VERSION"
				log_error "Patch application failed, exiting"
				exit 1
			fi
		fi
	done

	log_success "All patches applied successfully"
}

build_for_architecture() {
	local arch="$1"

	if [ "$arch" = "arm" ]; then
		build_arm32
	else
		build_aarch64
	fi
}

build_aarch64() {
	log_info "Building Turnip for aarch64 (native)..."

	cd "$WORKDIR/mesa"

	local build_dir="build-aarch64"

	if [ -d "$build_dir" ]; then
		log_info "Cleaning existing build directory..."
		rm -rf "$build_dir"
	fi

	log_info "Configuring Mesa with meson..."

	# Setup ccache
	if [ -n "${CCACHE_DIR}" ]; then
		export CCACHE_DIR
		log_info "Using ccache directory: $CCACHE_DIR"
	fi

	# Use LLVM 20 if available, otherwise use system default
	local llvm_config=""
	if [ -f "/usr/lib/llvm-20/bin/llvm-config" ]; then
		llvm_config="/usr/lib/llvm-20/bin/llvm-config"
		export LLVM_CONFIG="$llvm_config"
		log_info "Using LLVM 20: $llvm_config"
	fi

	# Minimal Turnip-only configuration
	CC="ccache gcc" CXX="ccache g++" meson setup "$build_dir" \
		--prefix=/usr \
		-Dplatforms=x11,wayland \
		-Dgallium-drivers= \
		-Dgallium-va=disabled \
		-Dgallium-mediafoundation=disabled \
		-Dvulkan-drivers=freedreno \
		-Dvulkan-layers= \
		-Dgles1=disabled \
		-Dgles2=disabled \
		-Dopengl=false \
		-Dgbm=disabled \
		-Dglx=disabled \
		-Dxlib-lease=disabled \
		-Dfreedreno-kmds=kgsl \
		-Degl=disabled \
		-Dglvnd=disabled \
		-Dintel-rt=disabled \
		-Dmicrosoft-clc=disabled \
		-Dllvm=disabled \
		-Dvalgrind=disabled \
		-Dbuild-tests=false \
		-Dlibunwind=disabled \
		-Dlmsensors=disabled \
		-Dandroid-libbacktrace=disabled \
		-Dbuildtype=release

	log_info "Building Mesa..."
	ninja -C "$build_dir" -j "$(nproc)"

	log_success "Build completed for aarch64"
}

build_arm32() {
	log_info "Building Turnip for ARM32 using QEMU..."

	cd "$WORKDIR"

	# Setup ccache directory for ARM32
	local ccache_dir="$SCRIPT_DIR/../.ccache-arm32"
	mkdir -p "$ccache_dir"

	log_info "Creating ARM32 build container..."

	# Create Dockerfile for ARM32 build
	cat >Dockerfile.arm32 <<'EOF'
FROM arm32v7/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get build-dep -y mesa && \
    apt-get install -y \
        git ccache \
        clang llvm \
        ninja-build patchelf unzip curl \
        python3-pip python3-mako flex bison \
        zip cmake glslang-tools && \
    apt-get remove -y meson || true && \
    pip3 install --upgrade meson --break-system-packages && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
EOF

	log_info "Building Docker image for ARM32..."
	docker build -f Dockerfile.arm32 -t mesa-arm32-builder:latest .

	log_info "Running ARM32 build in Docker container..."
	docker run --rm \
		--platform linux/arm/v7 \
		-v "$WORKDIR/mesa:/build/mesa" \
		-v "$ccache_dir:/root/.ccache" \
		-e CCACHE_DIR=/root/.ccache \
		mesa-arm32-builder:latest \
		bash -c "
			set -e
			cd /build/mesa

			# Configure ccache
			ccache --max-size=2G
			ccache --zero-stats

			# Configure Mesa
			CC='ccache gcc' CXX='ccache g++' meson setup build-arm \
				--prefix=/usr \
				-Dplatforms=x11,wayland \
				-Dgallium-drivers= \
				-Dgallium-va=disabled \
				-Dgallium-mediafoundation=disabled \
				-Dvulkan-drivers=freedreno \
				-Dvulkan-layers= \
				-Dgles1=disabled \
				-Dgles2=disabled \
				-Dopengl=false \
				-Dgbm=disabled \
				-Dglx=disabled \
				-Dxlib-lease=disabled \
				-Dfreedreno-kmds=kgsl \
				-Degl=disabled \
				-Dglvnd=disabled \
				-Dintel-rt=disabled \
				-Dmicrosoft-clc=disabled \
				-Dllvm=disabled \
				-Dvalgrind=disabled \
				-Dbuild-tests=false \
				-Dlibunwind=disabled \
				-Dlmsensors=disabled \
				-Dandroid-libbacktrace=disabled \
				-Dbuildtype=release

			# Build
			ninja -C build-arm -j \$(nproc)

			# Install to temporary directory (do this inside Docker)
			DESTDIR=/build/mesa/install-arm meson install -C build-arm

			# Show ccache stats
			ccache --show-stats

			# Fix permissions so host can access files
			chmod -R 777 /build/mesa/install-arm
		"

	if [ $? -eq 0 ]; then
		log_success "ARM32 build completed successfully"
	else
		log_error "ARM32 build failed"
		exit 1
	fi

	# Cleanup
	rm -f Dockerfile.arm32
}

package_architecture() {
	local arch="$1"

	log_info "Packaging Turnip for $arch..."

	local package_dir="$WORKDIR/turnip_package_${arch}"
	mkdir -p "$package_dir"
	rm -rf "${package_dir:?}"/*

	cd "$WORKDIR/mesa"

	# For ARM32, files are already installed by Docker, just copy them
	if [ "$arch" = "arm" ]; then
		log_info "Copying ARM32 installation from Docker build..."
		if [ -d "$WORKDIR/mesa/install-arm" ]; then
			cp -r "$WORKDIR/mesa/install-arm"/* "$package_dir/"
			log_success "Packaged Mesa installation for $arch"
		else
			log_error "ARM32 installation directory not found"
			return 1
		fi
	else
		# For aarch64, use meson install as before
		log_info "Installing Mesa to temporary directory..."
		DESTDIR="$package_dir" meson install -C "build-aarch64"
		log_success "Packaged Mesa installation for $arch"
	fi
}

create_package() {
	local arch="$1"

	log_info "Creating zip package for $arch..."

	local package_name="turnip-${MESA_VERSION}-${arch}"
	local package_dir="$WORKDIR/turnip_package_${arch}"

	cd "$package_dir"

	# Create zip from the installed files
	zip -r "$WORKDIR/${package_name}.zip" .

	if [ -f "$WORKDIR/${package_name}.zip" ]; then
		log_success "Package created: $WORKDIR/${package_name}.zip"
		log_info "Package size: $(du -h "$WORKDIR/${package_name}.zip" | cut -f1)"
		log_info "Package contents:"
		unzip -l "$WORKDIR/${package_name}.zip" | head -20
		echo ""
	else
		log_error "Package creation failed for $arch"
		return 1
	fi
}

main() {
	parse_arguments "$@"

	log_info "Starting Turnip builder for architectures: ${BUILD_ARCHITECTURES[*]} (Mesa $MESA_VERSION)"
	log_info "Build mode: Native for ARM64, QEMU for ARM32"

	mkdir -p "$WORKDIR"
	cd "$WORKDIR"

	prepare_mesa
	apply_patches

	local successful_builds=()
	local failed_builds=()

	for arch in "${BUILD_ARCHITECTURES[@]}"; do
		log_info "Processing architecture: $arch"

		if build_for_architecture "$arch"; then
			log_success "Successfully built for $arch"

			if package_architecture "$arch"; then
				if create_package "$arch"; then
					successful_builds+=("$arch")
					log_success "Successfully packaged $arch"
				else
					failed_builds+=("$arch")
					log_error "Failed to create package for $arch"
				fi
			else
				failed_builds+=("$arch")
				log_error "Failed to package $arch"
			fi
		else
			failed_builds+=("$arch")
			log_error "Failed to build for $arch"
		fi
		echo ""
	done

	log_info "Build Summary:"
	if [ ${#successful_builds[@]} -gt 0 ]; then
		log_success "Successfully built and packaged: ${successful_builds[*]}"
		for arch in "${successful_builds[@]}"; do
			local package_name="turnip-${MESA_VERSION}-${arch}.zip"
			log_info "  → $WORKDIR/$package_name"
		done
	fi

	if [ ${#failed_builds[@]} -gt 0 ]; then
		log_error "Failed builds: ${failed_builds[*]}"
		exit 1
	fi

	log_success "All operations completed successfully!"
	log_info "Output directory: $WORKDIR"
}

main "$@"
