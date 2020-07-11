#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#  args: ../playlists/spotify/Rocky
#
#  Author: Hari Sekhon
#  Date: 2020-06-25 22:28:51 +0100 (Thu, 25 Jun 2020)
#
#  https://github.com/harisekhon/bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

# https://developer.spotify.com/documentation/web-api/reference/tracks/get-several-tracks/
#
# https://developer.spotify.com/documentation/web-api/reference/albums/get-several-albums/
#
# https://developer.spotify.com/documentation/web-api/reference/artists/get-several-artists/

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="[<files>] [<curl_options>]"

# shellcheck disable=SC2034
usage_description="
Takes Spotify URIs and converts them to Track, Album or Artist names using the Spotify API

Spotify URIs are read from file arguments or standard input and can accept any of the following forms for convenience:

spotify:<type>:<alphanumeric_ID>
http://open.spotify.com/<type>/<alphanumeric_ID>
<alphanumeric_ID>

where <type> is track / album / artist

These IDs are 22 chars, but this is length is not enforced in case the Spotify API changes

Output format (depending on whether it's a track, an album or an artist URI):

Artist - Track
Artist - Album
Artist

or if \$SPOTIFY_CSV environment variable is set then:

\"Artist\",\"Track\"
\"Artist\",\"Album\"
\"Artist\"

Useful for saving Spotify playlists in a format that is easier to understand, revision control changes or export to other music systems

The first argument that doesn't correspond to a file and all subsequent arguements are fed as is to curl as options

Requires \$SPOTIFY_CLIENT_ID and \$SPOTIFY_CLIENT_SECRET to be defined in the environment
"

# shellcheck disable=SC1090
. "$srcdir/lib/utils.sh"

help_usage "$@"

#sleep_secs="0.1"
sleep_secs="0"

declare -a curl_options
curl_options=()

if [ -z "${SPOTIFY_ACCESS_TOKEN:-}" ]; then
    SPOTIFY_ACCESS_TOKEN="$("$srcdir/spotify_api_token.sh")"
    export SPOTIFY_ACCESS_TOKEN
fi

uri_type="${SPOTIFY_URI_TYPE:-track}"

if ! [[ "$uri_type" =~ ^(track|album|artist)$ ]]; then
    usage "invalid \$SPOTIFY_URI_TYPE '$uri_type' - must be track, album or artist"
fi

url_base="/v1/${uri_type}s"

uri_inferred=0
infer_uri_type(){
    local uri="$1"
    if [ $uri_inferred = 0 ] && [ -z "${SPOTIFY_URI_TYPE:-}" ]; then
        if [[ "$uri" =~ ^spotify:(track|album|artist):|^https?://open.spotify.com/(track|album|artist)/ ]]; then
            for x in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; do
                if [ -n "$x" ]; then
                    uri_type="$x"
                    url_base="/v1/${uri_type}s"
                    break
                fi
            done
        fi
    fi
}

validate_spotify_uri(){
    local uri="$1"
    if ! [[ "$uri" =~ ^(spotify:(track|album|artist):|^https?://open.spotify.com/(track|album|artist)/)?[[:alnum:]]+(\?.+)?$ ]]; then
        echo "Invalid URI provided: $uri" >&2
        exit 1
    fi
    if [[ "$uri" =~ open.spotify.com/|^spotify: ]]; then
        if ! [[ "$uri" =~ open.spotify.com/$uri_type|^spotify:$uri_type ]]; then
            echo "Invalid URI type '$uri_type' vs URI '$uri'" >&2
            exit 1
        fi
    fi
    uri="${uri##*[:/]}"
    uri="${uri%%\?*}"
    echo "$uri"
}

convert(){
    while true; do
        declare -a ids
        ids=()
        while [ "${#ids[@]}" -lt 50 ]; do
            read -r -s uri || break
            [ -z "$uri" ] && break
            if is_local_uri "$uri"; then
                if [ -n "${ids[*]:-}" ]; then
                    query_bulk "${ids[@]}"
                    ids=()
                fi
                output_local_uri "$uri"
                continue
            fi
            infer_uri_type "$uri"
            uri="$(validate_spotify_uri "$uri")"
            ids+=("$uri")
        done
        if [ -z "${ids[*]:-}" ]; then
            return
        fi
        query_bulk "${ids[@]}"
    done
}

query_bulk(){
    local ids
    # join array arg on commas
    { local IFS=','; ids="$*"; }
    if [ -z "$ids" ]; then
        return
    fi
    url_path="$url_base?ids=$ids"
    # cannot quote curl_options as when empty as this results in a blank literal which breaks curl
    # shellcheck disable=SC2068
    output="$("$srcdir/spotify_api.sh" "$url_path" ${curl_options[@]:-})"
    # shellcheck disable=SC2181
    if [ $? != 0 ] || [ "$(jq -r '.error' <<< "$output")" != null ]; then
        echo "$output" >&2
        exit 1
    fi
    output
    sleep "$sleep_secs"
}

is_local_uri(){
    [[ "$1" =~ ^spotify:local:|open.spotify.com/local/ ]]
}

output_local_uri(){
    local uri="$1"
    if [[ "$uri" =~ ^spotify:local: ]]; then
        uri="${uri#spotify:local:}"
        artist="${uri%%:*}"
        uri="${uri#*:}"
        uri="${uri#*:}"
        uri="${uri%:*}"
    elif [[ "$uri" =~ open.spotify.com/local/ ]]; then
        uri="${uri#http://open.spotify.com/local/}"
        artist="${uri%%/*}"
        uri="${uri#*/}"
        uri="${uri#*/}"
        uri="${uri%/*}"
    else
        echo "Unrecognized track URI format: $uri"
        exit 1
    fi
    track="${uri//+/ }"
    if [ -n "$artist" ]; then
        artist="${artist//+/ }"
        track="$artist - $track"
    fi
    "$srcdir/urldecode.sh" <<< "$track"
}

output(){
    if [[ "$output" =~ \"(tracks|albums|artists)\"[[:space:]]*:[[:space:]]+\[[[:space:]]*null[[:space:]]*\] ]]; then
        echo "no matching $uri_type URI found - did you specify an incorrect URI or wrong \$SPOTIFY_URI_TYPE for that URI?" >&2
        return
    fi
    local conversion="@tsv"
    if [ -n "${SPOTIFY_CSV:-}" ]; then
        conversion="@csv"
    fi
    if [ "$uri_type" = track ]; then
        output_artist_item
    elif [ "$uri_type" = artist ]; then
        jq -r ".${uri_type}s[] | [([.name] | join(\", \"))] | $conversion"
    elif [ "$uri_type" = album ]; then
        output_artist_item
    else
        echo "URI type '$uri' parsing not implemented" >&2
        exit 1
    fi <<< "$output" |
    clean_output
}

output_artist_item(){
    if [ -n "${SPOTIFY_CSV:-}" ]; then
        jq -r ".${uri_type}s[] | [([.artists[].name] | join(\", \")), .name] | $conversion"
    else
        jq -r ".${uri_type}s[] | [([.artists[].name] | join(\", \")), \"-\", .name] | $conversion"
    fi
}

clean_output(){
    tr '\t' ' ' |
    sed '
        s/^[[:space:]]*-//;
        s/^[[:space:]]*//;
        s/[[:space:]]*$//
    '
}

files=()

for filename in "$@"; do
    if [ -f "$filename" ]; then
        files+=("$filename")
        shift || :
    else
        break
    fi
done

if [ $# -gt 0 ]; then
    curl_options=("$@")
fi

if [ -n "${files[*]:-}" ]; then
    for filename in "${files[@]}"; do
        convert < "$filename"
    done
else
    convert  # read from stdin
fi