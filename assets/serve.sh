LD_LIBRARY_PATH= python3 "$(dirname "$0")/serve.py" "$@"
# Jai nix shells put an older glibc on LD_LIBRARY_PATH, which stack-smashes
# the system Python. Clear it for the HTTP server only.