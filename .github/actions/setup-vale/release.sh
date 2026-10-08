#!/usr/bin/env bash
# Reviewed release data shared by hosted setup and local checkout readiness.
VALE_RELEASE_VERSION=3.9.5
vale_release_checksum() {
	[[ "$1" == "$VALE_RELEASE_VERSION" ]] || return 1
	case "$2" in
	macOS_arm64) echo 8819b41321d69ad46604e16a1edbc00787c9737742be2c9e2d6a306494cb4d2a ;;
	macOS_64-bit) echo 458619bbd6b1862b3cc8c2d9ff585a247d31f1e4390afa88732795e77ea0305d ;;
	Linux_arm64) echo c2238664e7861d33ee5b9d4296cf4bab72f3576f28addd2a86f7d74ed4891c96 ;;
	Linux_64-bit) echo 774c034771f990e25fdbb4f940213423f2563b8df99ec31a296643e0872324cb ;;
	*) return 1 ;;
	esac
}
