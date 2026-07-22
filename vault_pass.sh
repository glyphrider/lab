#!/bin/bash
# Vault password lookup, scoped to this repo's own pass store (not ~/.password-store)
# so it travels with `git clone` instead of living only in the home directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASSWORD_STORE_DIR="$SCRIPT_DIR/.password-store" pass ansible/vault
