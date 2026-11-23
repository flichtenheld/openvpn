# This script encodes some defaults for various operating systems
# so that we can store them in git per-branch instead of having to
# maintain them in the buildbot configuration for all possible
# branches.

set -eux

# Defaults
enable_werror="--enable-werror"
enable_werror_cmake="-DUSE_WERROR=ON"
default_configure_opts=
branch_pkg_config_path=

uname_kernel=$(uname -s)
# We do not support -Werror builds on NetBSD since they
# have not been very good about updating the compiler in
# the past
if [ "$uname_kernel" = "NetBSD" ]; then
    enable_werror="--disable-werror"
    enable_werror_cmake="-DUSE_WERROR=OFF"
fi
# On macOS we have different versions of OpenSSL and mbedTLS available
# So choose here a version appropriate for this branch.
if [ "$uname_kernel" = "Darwin" ]; then
    openssl_major=4
    mbedtls_major=4
    branch_pkg_config_path="/opt/homebrew/opt/openssl@${openssl_major}/lib/pkgconfig:/opt/homebrew/opt/mbedtls@${mbedtls_major}/lib/pkgconfig"
fi
# Enable systemd support on Linux by default
if [ "$uname_kernel" = "Linux" ]; then
    default_configure_opts="--enable-systemd"
    #XXX: TEST
    branch_pkg_config_path="/usr/local/test"
fi

echo "branch_config_opts=$enable_werror $default_configure_opts"
echo "branch_config_opts_cmake=$enable_werror_cmake"
if [ -n "${PKG_CONFIG_PATH:-}" ]; then
    if [ -n "branch_pkg_config_path" ]; then
        branch_pkg_config_path="$branch_pkg_config_path:$PKG_CONFIG_PATH"
    else
        branch_pkg_config_path="$PKG_CONFIG_PATH"
    fi
fi
echo "branch_pkg_config_path=$branch_pkg_config_path"
