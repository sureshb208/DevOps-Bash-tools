#!/usr/bin/env bash
#
#  Author: Hari Sekhon
#  Date: 2019-09-18
#
#  https://github.com/harisekhon/devops-bash-tools
#
#  License: see accompanying LICENSE file
#
#  https://www.linkedin.com/in/harisekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x

usage(){
    cat <<EOF
Fetches a GitHub user's public SSH key via HTTP

User can be given as first argument, or environment variables \$GITHUB_USER or \$USER

Technically should use the GitHub API instead as it's more guaranteed to be stable
See instead: github_get_user_ssh_public_key.sh


${0##*/} <user>
EOF
    exit 3
}

for arg; do
    case "$arg" in
        -*)     usage
                ;;
    esac
done

if [ $# -gt 1 ]; then
    usage
elif [ $# -eq 1 ]; then
    user="$1"
elif [ -n "${GITHUB_USER:-}" ]; then
    user="$GITHUB_USER"
elif [ -n "${USER:-}" ]; then
    if [[ "$USER" =~ hari|sekhon ]]; then
        user=harisekhon
    else
        user="$USER"
    fi
else
    usage
fi


echo "# Fetching SSH Public Key(s) from GitHub for account:  $user" >&2
echo "#" >&2
curl -sS --fail "https://github.com/$user.keys"
