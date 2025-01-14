#!/bin/bash

# Author: Gwern Branwen
# Date: 2016-10-01
# When:  Time-stamp: "2023-12-21 09:34:28 gwern"
# License: CC-0
#
# Bash helper functions for Gwern.net wiki use.
# Intended to be sourced in `~/.bashrc` like `. ~/wiki/static/build/bash.sh`
#
# Helper functions include: website cache invalidation; PDF metadata query & editing; tab-completion for tag/directory names; querying the newsletters, filenames, annotation database, website, and IRC (in increasing generality); site-wide string search-and-replace (including a HTTP→HTTPS special-case which comes up a lot fixing redirects); functions to rename files & directories; and a `gwtag` CLIcommand which create new annotations (if there is a usable annotation source, such as being an Arxiv link) or add/remove tags from specified files/URLs.
#
# See also: /static/build/{upload, gwa, crossref, compressJpg2}

source /usr/share/bash-completion/bash_completion # useful for better `upload` tab-completion

# Default parallelism:
export N="29"

set -e

cloudflare-expire () {
    ARGS=$(echo "$@" | sed -e 's/^wiki\///' -e 's/\~\//\/home\/gwern\/wiki\//' -e 's/^\([a-zA-Z0-9].*\)/\/home\/gwern\/wiki\/\1/' -e 's/https:\/\/gwern\.net//g' -e 's/https:\/\/gwern\.net//g' -e 's/^\/doc/\/home\/gwern\/wiki\/doc/')
    for FILE in $(realpath $ARGS); do
        URL="$(echo $FILE | sed -e 's/\.page//' -e 's/\/home\/gwern\/wiki\/\(.*\)/https:\/\/gwern\.net\/\1/g' -e 's/\.page//g' | sort )"
        echo -n "Expiring: $FILE → $URL : "
        curl --silent --request POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_TARGET/purge_cache" \
            --header "X-Auth-Email:gwern@gwern.net" \
            --header "Authorization: Bearer $CLOUDFLARE_CACHE_TOKEN" \
            --header "Content-Type: application/json" \
            --data "{\"files\":[\"$URL\"]}" | jq '.success'
        (curl --silent "$URL" &) > /dev/null
    done
}
export -f cloudflare-expire
cloudflare-expire-all () {
    (find ~/wiki/ -name "*.page" -type f -not -wholename "*/\.*/*" -not -wholename "*/_*/*" | sort; find ~/wiki/static/ -type f | sort) | \
        sed -e 's/\.page//' -e 's/^\.\/\(.*\)$/https:\/\/gwern\.net\/\1/' | sort | parallel cloudflare-expire;
    }

pdf () {
    for ARG in "$@"; do
        TARGET=$(echo "$ARG" | sed -e 's/^\/doc\//\/home\/gwern\/wiki\/doc\//')
        (evince "$TARGET" &);
    done; }

# delete the first page of the PDF. This is useful to remove the spam in PDFs from JSTOR and many other academic publishers. (Some of them do 2 or even 3 spam pages, but you can just run `pdfcut` repeatedly quickly with <Up> arrow in bash, of course.)
pdfcut () { if [ $# -ne 1 ]; then echo "Too many arguments" && return 1; fi
            ORIGINAL=$(echo "$@" | sed -e 's/^\/doc\//\/home\/gwern\/wiki\/doc\//')
            TARGET=$(mktemp /tmp/XXXXXX.pdf);
            pdftk "$ORIGINAL" cat 2-end  output "$TARGET" &&
            # pdftk by default erases all metadata, so we need to copy it all to the new PDF:
                exiftool -TagsFromFile "$ORIGINAL" "$TARGET" &&
            mv "$TARGET" "$ORIGINAL" || rm "$TARGET";
          (crossref "$ORIGINAL" &);
          }

# add white pixels to an image which has been cropped too tightly to look good:
pad () {
    for FILE in "$@"; do
        ORIGINAL=$(echo "$FILE" | sed -e 's/^\/doc\//\/home\/gwern\/wiki\/doc\//')
        mogrify -bordercolor white -border 25 "$FILE"
    done
}

# crossref: defined in ~/wiki/static/build/crossref
cr () { crossref "$@" & }

# PDF cleanup: strip encryption, run through `pdftk` to render them standard & strip out weirdness, reformat titles.
e () { FILE=""
       # did I write '$ e -Title="Foobar" 2000-baz.pdf' or '$ e 2000-baz.pdf -Title="Foobar"'?
       if [[ "${1:0:1}" == "-" ]]; then
           FILE="${*: -1}"
       else
           FILE=$(echo "$1" | sed -e 's/^\/doc/\/home\/gwern\/wiki\/doc/')
           shift;
       fi
       if [[ -a "$FILE" ]]; then
           if [[ "$FILE" =~ .*\.pdf || "$FILE" =~ .*\.jpg || "$FILE" =~ .*\.png ]]; then
               if [[ "$FILE" =~ .*\.pdf ]]; then
                   ENCRYPTION=$(exiftool -q -q -Encryption "$FILE")
                   if [ "$ENCRYPTION" != "" ]; then
                       pdftk "$FILE" input_pw output foo.pdf && mv foo.pdf "$FILE";
                   fi;
                   # Sometimes PDFs are really weird and exiftool will claim to successfully write metadata to them
                   # and yet nothing will happen. I've found that if you pass them through pdftk first, they seem almost identical
                   # but the mysterious unwritable behavior stops. So we convert any PDF by default.
                   TMP="$(mktemp /tmp/XXXXX.pdf)"
                   # pdftk by default erases all metadata, so we need to copy it all to the new PDF:
                   pdftk "$FILE" cat output "$TMP" && \
                       exiftool -TagsFromFile "$FILE" "$TMP" && \
                         mv "$TMP" "$FILE"
               fi;
               echo "$FILE"
               exiftool -m -overwrite_original "$FILE" "$@";
               # getting very tired of these hyphen junk in my titles...
               TITLE1="$(exiftool -printFormat '$Title' -Title "$FILE")"
               TITLE2="$(echo "$TITLE1" | sed -e 's/‐/-/g' -e 's/^ \+//g' -e 's/ \+$//g' -e 's/\.$//' | tr '_' ':')" # WARNING: tr mangles Unicode, but sed doesn't
               if [[ "$TITLE1" != "$TITLE2" ]]; then exiftool -overwrite_original -Title="$TITLE2" "$FILE"; fi

           else emacsclient "$FILE";
           fi;
       else echo "File does not exist? $FILE"
       fi;
     }
alias E="e"
alias ea="exiftool -All"
alias exiftool="exiftool -overwrite_original"

# Gwern.net searches:
## fixed-grep gwern.net specifically:
gw () {
    if [ $# == 0 ]; then echo "Missing search query."; return 2; fi

    QUERY="$*";
    RESULTS=$( (find ~/wiki/ -type f -name "*.page";
         ls ~/.emacs;
         find ~/wiki/metadata/ ~/wiki/haskell/ -name "*.hs" -or -name "*.yaml";
         find ~/wiki/static/ -type f -name "*.js" -or -name "*.css" -or -name "*.hs" -or -name "*.conf" -or -name "*.yaml" -or -name "*.py" -or -name "*.sh";
         find ~/wiki/ -type f -name "*.html" -not -wholename "*/doc/*" ) | \
           grep -F -v -e '.#' -e 'auto.hs' -e doc/link-bibliography/ -e metadata/annotation/ | sort --unique  | \
           xargs grep -F --color=always --ignore-case --with-filename "$QUERY" | cut -c 1-2548);
    if [ -z "$RESULTS" ]; then
        gwl "$@" # fall back to double-checking IRC logs
    else
        echo "$RESULTS"
    fi
}

## file names only
gwf () { (cd ~/wiki/ && find . -type f | grep -F -v -e '.#' -e '_cache/' -e '_site/' -e '.git/' | grep --ignore-case "$@" | sed -e 's/^\.\//\//g') | sort; }
## Newsletter only:
gwn () { if [ $# != 1 ]; then QUERY="$*"; else QUERY="$@"; fi
        find ~/wiki/newsletter/ -type f -name "*.page" | \
             grep -F -v -e '.#' |
            sort --unique  | xargs grep -E --ignore-case --color=always --with-filename "$QUERY" | cut --characters 1-2048; }
## Annotations:
# gwa: defined in ~/wiki/static/build/gwa
gwal () { gwa "$@" | less -p "$@"; }

## #lesswrong IRC logs
gwl () { if [ $# != 1 ]; then QUERY="$*"; else QUERY="$@"; fi
         grep --context=1 --text --ignore-case -- "$QUERY" ~/doc/irclogs/*/\#lesswrong.log; }

# Gwern.net modifications:
## gwsed shortcut for the common use case of updating a domain HTTP → HTTPS; typically the URLs are otherwise unchanged, and don't need to be individually updated.
gwhttp () {
    if [ $# != 1 ]; then
        echo "HTTP migration only works for 1 domain, did you try a regular search-and-replace?"
        return 2
    else
        # extract top-level domain to do the search-and-replace on that:
        HTTP="http://$(echo "$1" | sed -e 's/[^/]*\/\/\([^@]*@\)\?\([^:/]*\).*/\2/')"
        HTTPS=${HTTP//http:/https:}
        gwsed "$HTTP" "$HTTPS"
    fi
}
export -f gwhttp

## Move a file and sync it and update all callers:
## TODO: handle pages/essays, not just files? see <rename.hs> for a sketch.
gwmv () {
    if [ $# != 2 ]; then
        echo "Need two arguments: OLD file and NEW file! Only got: \"$@\""
        return 2
    else
    (
        set -x
        if [[ ! $(pwd) =~ "/home/gwern/wiki/".* ]]; then cd ~/wiki/ ; fi
        OLD=$(echo "$1" | sed -e 's/https:\/\/gwern\.net//g' -e 's/^\///g' | xargs realpath | sed -e 's/\/home\/gwern\/wiki\//\//g' )
        NEW=$(echo "$2" | sed -e 's/https:\/\/gwern\.net//g' -e 's/^\///g' | xargs realpath | sed -e 's/\/home\/gwern\/wiki\//\//g')


        if [ -d "$HOME/wiki$OLD" ] || [ -d "${OLD:1}" ]; then
            echo "The first argument ($1 $OLD) is a directory. Please use 'gwmvdir' to rename entire directories."
            return 3
        elif [ ! -f "$HOME/wiki$OLD" ] && [ ! -f "${OLD:1}" ]; then
            echo "File $OLD not found in current directory or ~/wiki"
            return 3
        fi

        # strip any slash prefix like '/doc/psychology/2021-foo.pdf' → 'doc/psychology/2021-foo.pdf' to turn it into a local relative link

        # eg "gwMv 'doc/psychology/2021-foo.pdf' 'doc/psychology/writing'" as a shortcut for "gwmv 'doc/psychology/2021-foo.pdf' 'doc/psychology/writing/2021-foo.pdf'"
        if [ -d ~/wiki$NEW ]; then NEW=$(echo $NEW/$(basename $OLD) | sed -e 's/\/\//\//'); fi

        cd ~/wiki/
        if [[ -a ~/wiki$NEW ]]; then
            echo "Moved-to target file $NEW exists! Will not move $OLD and overwrite it. If you deliberately want to overwrite $NEW, then explicitly delete it first."
            return 4
            # to rename a gwern.net file:
            # 1. git mv the old filename to new
        elif [[ -a ~/wiki$OLD ]]; then
            touch ~/wiki"$NEW" && rm ~/wiki"$NEW" && git mv ~/wiki"$OLD" ~/wiki"$NEW" || return 3
            ssh gwern@176.9.41.242 "mkdir -p /home/gwern/gwern.net$(dirname $NEW)" # TODO: replace this ssh line with the `--mkpath` option in rsync when that becomes available:
            rsync --chmod='a+r' -q ~/wiki"$NEW" gwern@176.9.41.242:"/home/gwern/gwern.net$NEW" || echo "gwmv: rsync failed?" > /dev/null &
            # 2. gwsed old new
            gwsed "$OLD" "$NEW"
            # 3. add a redirected old to nw
            echo '"~^'"$OLD"'.*$" "'"$NEW"'";' | tee --append ~/wiki/static/redirect/nginx.conf
            # 4. delete outdated annotations:
            OLD_FILE=$(basename "$OLD")
            rm ~/wiki/metadata/annotation/*"$OLD_FILE"* || true > /dev/null
        else
                echo "File does not exist? $OLD (to be moved to $NEW)" && return 1;
        fi
        wait
        )
        set +x
    fi
}
## Move a directory:
gwmvdir () {
    cd ~/wiki/
    OLD="$1"
    NEW="$2"
    if [[ "$OLD" == /* ]]; then
        OLD="${OLD:1}"
    fi
    if [[ "$NEW" == /* ]]; then
        NEW="${NEW:1}"
    fi

    OLD="$(readlink --canonicalize "$OLD" | cut -d '/' -f 5-)"
    ls "$OLD"
    NEW="$(readlink --canonicalize "$NEW" | cut -d '/' -f 5-)"
    mkdir -p "$NEW"
    git add "$NEW"
    for FILE in $(ls "$OLD"/* | grep -F -v 'index.page'); do
        echo $FILE
        gwmv "$FILE" "$NEW/$(basename $FILE)"
    done
    rm "$OLD/index.page" || true
    rmdir "$OLD"
}

## 'Move' or tag an annotation:
## gwtag URL [tag]
## eg. `gwtag https://foo iq psychology sociology`
alias gwt="gwtag"
alias t="gwtag"
gwtag () { (
             wait; # just in case another tool might be running (eg. gwtag or gwsed)
             cd ~/wiki/ &&
                     # echo "---" && grep -F -- "$1" ./metadata/*.yaml || true
                     timeout 20m nice ./static/build/changeTag "$@"; echo "" # &&
                         # echo "---" && grep -F -- "$1" ./metadata/*.yaml
         ); }

# eg. `"ai ai/anime ai/anime/danbooru ... ai/scaling ai/scaling/economics ... japan/poetry/shotetsu japan/poetry/teika ... technology/digital-antiquarian ... zeo/short-sleeper"`
GWERNNET_DIRS_FULL="$(cd ~/ && find wiki/doc/ -type d | grep -F -v -e 'doc/rotten.com' -e 'doc/www/' \
                         -e 2000-iapac-norvir -e mountimprobable.com -e personal/2011-gwern-yourmorals.org \
                         -e psychology/european-journal-of-parapsychology -e reinforcement-learning/armstrong-controlproblem \
                         -e statistics/order/beanmachine-multistage -e gwern.net-gitstats -e metadata/annotation | \
                         cut --delimiter='/' --fields=3- | sort)"
# eg. `"1 2 2010-crc 2013-cicadas 3 4 5 abandoned-footnotes ab-testing ... www zeami zeo"`
GWERNNET_DIRS_SHORT="$(echo $GWERNNET_DIRS_FULL | tr '/' '\n' | tr ' ' '\n' | sort --unique)"
# for completing tags which may need to be disambiguated, like 'gpt/nonfiction':
# eg. `"1/lsd 2/2010-crc 3/fiction 3/nonfiction ... palm/2 personality/conscientiousness personality/psychopathy ... video/analysis video/generation vision/dream"`
GWERNNET_DIRS_SUFFIXES="$(echo $GWERNNET_DIRS_FULL | tr ' ' '\n' | grep -E -e '[a-z0-9-]+/[a-z0-9-]+/[a-z0-9-]+' | \
                               rev | cut --delimiter='/' --fields=1-2 | rev | sort --unique)"
complete -W "$GWERNNET_DIRS_FULL $GWERNNET_DIRS_SHORT $GWERNNET_DIRS_SUFFIXES" u gwtag gwt t

alias u="upload"
# 'upload' moved to ~/wiki/static/build/upload for easier calling from XMonad
## tab-complete the first argument as the local file, and the second argument as the remote directory:
_upload() {
    local cur cword
    _init_completion || return ## assumes `bash-completion` package is installed & sourced previously

    if [[ $cword -eq 1 ]]; then
        # File completion on first argument
        _filedir
    elif [[ $cword -eq 2 ]]; then
        # Directory completion on second argument
        COMPREPLY=( $(compgen -W "${GWERNNET_DIRS_FULL} ${GWERNNET_DIRS_SHORT} ${GWERNNET_DIRS_SUFFIXES}" -- "$cur") )
    fi
}
complete -F _upload upload

# wait for a file to become quiescent because eg. the web browser is still downloading it:
is_downloading() {
  file="$1"
  current_time=$(date +%s)

  # Check if the file exists
  if [ -f "$file" ]; then
    modified_time=$(stat -c %Y "$file")
    elapsed_time=$((current_time - modified_time))

    # Sleep if last-modified time is not at least 3 seconds ago
    if [ $elapsed_time -lt 4 ]; then
      sleep $((4 - elapsed_time))
    fi
  else
    echo "File not found."
  fi
}

# shortcut for handling link-archiving review:
# `mvuri`: takes a filename with a URI encoding
# like `file:///home/gwern/wiki/doc/www/www.patterns.app/d7aaf7b7491492af22c98dae1079fbfa93961b5b.html`
# and transform that argument into `/home/gwern/wiki/doc/www/www.patterns.app/d7aaf7b7491492af22c98dae1079fbfa93961b5b.html`
# (ignoring any anchor/hash on the original .html file) and then `mv` the URL snapshot to that like normal.
# If the target starts with 'doc/' (perhaps because it has been copied from `/metadata/archive.hs` while manually fixing)
# It is treated as if it had started with `file:///home/gwern/wiki/doc/`
#
# eg. `$ mvuri file:///home/gwern/wiki/doc/www/www.patterns.app/d7aaf7b7491492af22c98dae1079fbfa93961b5b.html`
# `$ mvuri file:///home/gwern/wiki/doc/www/www.patterns.app/d7aaf7b7491492af22c98dae1079fbfa93961b5b.html#toc`
# `$ mvuri doc/www/www.patterns.app/d7aaf7b7491492af22c98dae1079fbfa93961b5b.html`
# are all equivalent.
mvuri () {
    # Check if inotifywait is installed
    if ! command -v inotifywait &> /dev/null; then
        echo "inotifywait could not be found. Please install inotify-tools."
        exit
    fi

  local ENCODED_PATH="$1"
  local DECODED_PATH="${ENCODED_PATH//\%/\\x}"
  DECODED_PATH="${DECODED_PATH#file://}"
  DECODED_PATH="${DECODED_PATH%%#*}" # ignore anchors like `foo.html#id` by stripping them

  # Check if DECODED_PATH starts with 'doc/', if so prepend with '/home/gwern/wiki/'
  if [[ $DECODED_PATH == doc/* ]]; then
    DECODED_PATH="/home/gwern/wiki/$DECODED_PATH"
  fi

  local DESTINATION="$DECODED_PATH"

  local SOURCE
  # the browser may not have yet begun writing the file, so make sure we wait until it does:
  while true; do
      # we target the oldest .html file, in case others have started being created in the mean time:
    SOURCE="$(find ~/ -maxdepth 1 -name "*.html" -printf '%T+ %p\n' | sort --key=1,1 | cut --delimiter=' ' --fields=2- | head --lines=1)"
    if [ -n "$SOURCE" ]; then
      break
    else
      inotifywait --quiet --event create ~/
    fi
  done
  echo "$SOURCE" "$DESTINATION"
  # the file may not yet be fully written, so we additionally wait until it's (probably) complete:
  is_downloading "$SOURCE"
  mv "$SOURCE" "$DESTINATION"
}
