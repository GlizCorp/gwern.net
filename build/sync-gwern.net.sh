#!/bin/bash

# sync-gwern.net.sh: shell script which automates a full build and sync of Gwern.net. A simple build
# can be done using 'runghc hakyll.hs build', but that is slow, semi-error-prone (did you
# remember to delete all intermediates?), and does no sanity checks or optimizations like compiling
# the MathJax to static CSS/fonts (avoiding multi-second JS delays).
#
# This script automates all of that: it cleans up, compiles a hakyll binary for faster compilation,
# generates a sitemap XML file, optimizes the MathJax use, checks for many kinds of errors, uploads,
# and cleans up.
#
# Author: Gwern Branwen
# Date: 2016-10-01
# When:  Time-stamp: "2019-09-15 14:38:14 gwern"
# License: CC-0

bold () { echo -e "\033[1m$@\033[0m"; }
red  () { echo -e "\e[41m$@\e[0m"; }
## function to wrap checks and print red-highlighted warning if non-zero output (self-documenting):
wrap () { OUTPUT=$($1 2>&1)
         WARN="$2"
         if [ -n "$OUTPUT" ]; then
             red "$WARN";
             echo -e "$OUTPUT";
         fi; }
eg () { egrep --color=always "$@"; }
gf () { fgrep --color=always "$@"; }

# key dependencies: GHC, Hakyll, s3cmd, emacs, curl, tidy (HTML5 version), urlencode
# ('gridsite-clients' package), linkchecker, fdupes, ImageMagick, exiftool, mathjax-node-page (eg.
# `npm i -g mathjax-node-page`), parallel, xargs, php7…

if ! [[ -n $(command -v ghc) && -n $(command -v git) && -n $(command -v rsync) && -n $(command -v curl) && -n $(command -v ping) && \
          -n $(command -v tidy) && -n $(command -v linkchecker) && -n $(command -v du) && -n $(command -v rm) && -n $(command -v find) && \
          -n $(command -v fdupes) && -n $(command -v urlencode) && -n $(command -v sed) && -n $(command -v parallel) && -n $(command -v xargs) && \
          -n $(command -v file) && -n $(command -v exiftool) && -n $(command -v identify) && -n $(command -v pdftotext) && \
          -n $(command -v ~/src/node_modules/mathjax-node-page/bin/mjpage) && -n $(command -v static/build/link-extractor.hs) && \
          -n $(command -v static/build/anchor-checker.php) && -n $(command -v php) && -n $(command -v static/build/generateDirectory.hs) && \
          -n $(command -v static/build/generateLinkBibliography.hs) && \
          -n $(command -v static/build/generateBacklinks.hs) ]] && \
          -n $(command -v static/build/generateSimilarLinks.hs) ]] && \
       [ -z "$(pgrep hakyll)" ];
then
    red "Dependencies missing or Hakyll already running?"
else
    set -e

    # lower priority of everything we run (some of it is expensive):
    renice -n 15 "$$" &>/dev/null

    ## Parallelization: WARNING: post-2022-03 Hakyll uses parallelism which catastrophically slows down at >= # of physical cores; see <https://groups.google.com/g/hakyll/c/5_evK9wCb7M/m/3oQYlX9PAAAJ>
    N="$(if [ ${#} == 0 ]; then echo 24; else echo "$1"; fi)"

    (cd ~/wiki/ && git status || true) &
    bold "Pulling infrastructure updates…"
    (cd ./static/ && git status && git pull --verbose 'https://gwern.obormot.net/static/.git/' master || true)

    bold "Executing string rewrite cleanups…" # automatically clean up some Gwern.net bad URL patterns, typos, inconsistencies, house-styles:
    (gwsed 'https://mobile.twitter.com' 'https://twitter.com' & gwsed 'https://twitter.com/' 'https://nitter.hu/' & gwsed 'https://mobile.twitter.com/' 'https://nitter.hu/' & gwsed 'https://www.twitter.com/' 'https://nitter.hu/' & gwsed 'https://www.reddit.com/r/' 'https://old.reddit.com/r/' & gwsed 'https://en.m.wikipedia.org/' 'https://en.wikipedia.org/' & gwsed 'https://www.greaterwrong.com/posts/' 'https://www.lesswrong.com/posts' & gwsed '&hl=en' '' & gwsed '?hl=en&' '?' & gwsed '?hl=en' '' & gwsed '?usp=sharing' '' & gwsed '<p> ' '<p>' & gwsed 'EMBASE' 'Embase' & gwsed 'Medline' 'MEDLINE' & gwsed 'PsychINFO' 'PsycINFO' & gwsed 'http://web.archive.org/web/' 'https://web.archive.org/web/' & gwsed 'https://youtu.be/' 'https://www.youtube.com/watch?v=' & gwsed '.html?pagewanted=all' '.html' & gwsed '(ie,' '(ie.' & gwsed '(ie ' '(ie. ' & gwsed '(i.e.,' '(ie.' & gwsed 'ie., ' 'ie. ' & gwsed '(i.e.' '(ie.' & gwsed '(eg, ' '(eg. ' & gwsed ' eg ' ' eg. ' & gwsed '(eg ' '(eg. ' & gwsed '[eg ' '[eg. ' & gwsed 'e.g. ' 'eg. ' & gwsed ' e.g. ' ' eg. ' & gwsed 'e.g.,' 'eg.' & gwsed 'eg.,' 'eg.' & gwsed ']^[' '] ^[' & gwsed ' et al., ' ' et al ' & gwsed 'et al., ' 'et al ' & gwsed '(cf ' '(cf. ' & gwsed ' cf ' ' cf. ' & gwsed ' _n_s' ' <em>n</em>s' & gwsed ' (n = ' ' (<em>n</em> = ' & gwsed ' (N = ' ' (<em>n</em> = ' & gwsed '<sup>St</sup>' '<sup>st</sup>' & gwsed '<sup>Th</sup>' '<sup>th</sup>' & gwsed '<sup>Rd</sup>' '<sup>rd</sup>' & gwsed ' de novo ' ' <em>de novo</em> ' & gwsed ' De Novo ' ' <em>De Novo</em> '  &  gwsed ', Jr.' ' Junior' & gwsed ' Jr.' ' Junior' & gwsed ', Junior' ' Junior' & gwsed '.full-text' '.full' & gwsed '.full.full' '.full' & gwsed '.full-text' '.full' & gwsed '.full-text.full' '.full' & gwsed '.full.full.full' '.full' & gwsed '.full.full' '.full' & gwsed '#allen#allen' '#allen' & gwsed '#deepmind#deepmind' '#deepmind' & gwsed '#nvidia#nvidia' '#nvidia' & gwsed '#openai#openai' '#openai' & gwsed '#google#google' '#google' & gwsed '#uber#uber' '#uber' & gwsed 'MSCOCO' 'MS COCO' & gwsed '&feature=youtu.be' '' & gwsed 'Rene Girard' 'René Girard' & gwsed 'facebookok' 'facebook' & gwsed ':443/' '/'  &  gwsed 'border colly' 'border collie'  &  gwsed ':80/' '/'  &  gwsed '.gov/labs/pmc/articles/P' '.gov/pmc/articles/P' & gwsed 'rjlipton.wpcomstaging.com' 'rjlipton.wordpress.com' & gwsed '?s=r' '' & gwsed 'backlinks-not' 'backlink-not') &> /dev/null
    wait

    bold "Compiling…"
    cd ./static/build
    compile () { ghc -O2 -Wall -rtsopts -threaded --make "$@"; }
    compile hakyll.hs
    compile generateLinkBibliography.hs
    compile generateDirectory.hs
    compile preprocess-markdown.hs &
    ## NOTE: generateSimilarLinks.hs & link-suggester.hs are done at midnight by a cron job because
    ## they are too slow to run during a regular site build & don't need to be super-up-to-date
    ## anyway
    cd ../../
    cp ./metadata/auto.yaml "/tmp/auto-$(date +%s).yaml.bak" || true # backup in case of corruption
    cp ./metadata/archive.hs "/tmp/archive-$(date +%s).hs.bak"
    bold "Checking embeddings database…"
    ghci -i/home/gwern/wiki/static/build/ static/build/GenerateSimilar.hs  -e 'e <- readEmbeddings' &>/dev/null && cp ./metadata/embeddings.bin "/tmp/embeddings-$(date +%s).bin.bak"

    # duplicates a later check but if we have a fatal link error, we'd rather find out now rather than 30 minutes later while generating annotations:
    λ(){ fgrep -e 'href=""' -- ./metadata/*.yaml || true; }
    wrap λ "Malformed empty link in annotations?"

    # We update the linkSuggestions.el in a cron job because too expensive, and vastly slows down build.

    # Update the directory listing index pages: there are a number of directories we want to avoid,
    # like the various mirrors or JS projects, or directories just of data like CSVs, or dumps of
    # docs, so we'll blacklist those:
    bold "Building directory indexes…"
    ./static/build/generateDirectory +RTS -N"$N" -RTS \
                $(find docs/ fiction/ haskell/ newsletter/ nootropics/ notes/ reviews/ zeo/ -type d \
                      | sort | fgrep -v -e 'docs/www' -e 'docs/rotten.com' -e 'docs/genetics/selection/www.mountimprobable.com' \
                                        -e 'docs/biology/2000-iapac-norvir' -e 'docs/gwern.net-gitstats' -e 'docs/rl/armstrong-controlproblem' \
                                        -e 'docs/statistics/order/beanmachine-multistage' \
                -e 'docs/link-bibliography' | shuf) # we want to generate all directories first before running Hakyll in case a new tag was created

    bold "Updating link bibliographies…"
    ./static/build/generateLinkBibliography +RTS -N"$N" -RTS $(find . -type f -name "*.page" | sort | fgrep -v -e 'index.page' -e '404.page' -e 'docs/link-bibliography/' | sed -e 's/\.\///' | shuf) &

    bold "Check/update VCS…"
    cd ./static/ && (git status; git pull; git push --verbose &)
    cd ./build/
    # Cleanup pre:
    rm --recursive --force -- ~/wiki/_cache/ ~/wiki/_site/ ./static/build/hakyll ./static/build/*.o ./static/build/*.hi ./static/build/generateDirectory ./static/build/generateLinkBibliography ./static/build/generateBacklinks ./static/build/link-extractor ./static/build/link-suggester || true

    cd ../../ # go to site root
    bold "Building site…"
    time ./static/build/hakyll build +RTS -N"$N" -RTS || (red "Hakyll errored out!"; exit 1)
    bold "Results size…"
    du -chs ./_cache/ ./_site/; find ./_site/ -type f | wc --lines

    # cleanup post:
    rm -- ./static/build/hakyll ./static/build/*.o ./static/build/*.hi ./static/build/generateDirectory ./static/build/generateLinkBibliography ./static/build/generateBacklinks ./static/build/link-extractor &>/dev/null || true

    ## WARNING: this is a crazy hack to insert a horizontal rule 'in between' the first 3 sections
    ## on /index (Newest/Popular/Notable), and the rest (starting with Statistics); the CSS for
    ## making the rule a block dividing the two halves just doesn't work in any other way, but
    ## Pandoc Markdown doesn't let you write stuff 'in between' sections, either. So… a hack.
    sed -i -e 's/section id=\"statistics\"/hr class="horizontalRule-nth-1" \/> <section id="statistics"/' ./_site/index

    bold "Building sitemap.xml…"
    ## generate a sitemap file for search engines:
    ## possible alternative implementation in hakyll: https://www.rohanjain.in/hakyll-sitemap/
    (echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?> <urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"
     ## very static files which rarely change: PDFs, images, site infrastructure:
     find -L _site/docs/ _site/images/ _site/static/ -not -name "*.page" -type f | fgrep --invert-match -e 'docs/www/' -e 'docs/link-bibliography' -e 'metadata/' -e '.git' -e '404' -e '/static/templates/default.html' -e '/docs/personal/index' | \
         sort | xargs urlencode -m | sed -e 's/%20/\n/g' | \
         sed -e 's/_site\/\(.*\)/\<url\>\<loc\>https:\/\/www\.gwern\.net\/\1<\/loc><changefreq>never<\/changefreq><\/url>/'
     ## Everything else changes once in a while:
     find -L _site/ -not -name "*.page" -type f | fgrep --invert-match -e 'static/' -e 'docs/' -e 'images/' -e 'Fulltext' -e 'metadata/' -e '-768px.' | \
         sort | xargs urlencode -m | sed -e 's/%20/\n/g' | \
         sed -e 's/_site\/\(.*\)/\<url\>\<loc\>https:\/\/www\.gwern\.net\/\1<\/loc><changefreq>monthly<\/changefreq><\/url>/'
     echo "</urlset>") >> ./_site/sitemap.xml

    ## generate a syntax-highlighted HTML fragment (not whole standalone page) version of source code files for popup usage:
    ### We skip .json/.jsonl/.csv because they are too large & Pandoc will choke; and we truncate at 1000 lines because such
    ### long source files are not readable as popups and their complexity makes browsers choke while rendering them.
    ### (We include plain text files in this in order to get truncated versions of them.)
    bold "Generating syntax-highlighted versions of source code files…"
    syntaxHighlight () {
        #### NOTE: for each new extension, add a `find` name, and an entry in `extracts-content.js`
        declare -A extensionToLanguage=( ["R"]="R" ["c"]="C" ["py"]="Python" ["css"]="CSS" ["hs"]="Haskell" ["js"]="Javascript" ["patch"]="Diff" ["diff"]="Diff" ["sh"]="Bash" ["bash"]="Bash" ["html"]="HTML" ["conf"]="Bash" ["php"]="PHP" ["opml"]="Xml" ["xml"]="Xml" ["page"]="Markdown" ["txt"]="" ["yaml"]="YAML" ["jsonl"]="JSON" ["json"]="JSON" ["csv"]="CSV" )
        for FILE in "$@"; do
            FILEORIGINAL=$(echo "$FILE" | sed -e 's/_site//')
            FILENAME=$(basename -- "$FILE")
            EXTENSION="${FILENAME##*.}"
            LANGUAGE=${extensionToLanguage[$EXTENSION]}
            FILELENGTH=$(cat "$FILE" | wc --lines)
            (echo -e "~~~{.$LANGUAGE}";
            if [ $EXTENSION == "page" ]; then # the very long lines look bad in narrow popups, so we fold:
                cat "$FILE" | fold --spaces --width=65 | head -1100 | iconv -t utf8 -c;
            else
                cat "$FILE" | head -1000;
            fi
             echo -e "\n~~~"
             if (( $FILELENGTH >= 1000 )); then echo -e "\n\n…[File truncated due to length; see <a class=\"link-local\" href=\"$FILEORIGINAL\">original file</a>]…"; fi;
            ) | pandoc --mathjax --write=html5 --from=markdown+smart >> $FILE.html
        done
    }
    export -f syntaxHighlight
    set +e
    find _site/static/ -type f,l -name "*.html" | sort | parallel --jobs 25 syntaxHighlight # NOTE: run .html first to avoid duplicate files like 'foo.js.html.html'
    find _site/ -type f,l -name "*.R" -or -name "*.c" -or -name "*.css" -or -name "*.hs" -or -name "*.js" -or -name "*.patch" -or -name "*.diff" -or -name "*.py" -or -name "*.sh" -or -name "*.bash" -or -name "*.php" -or -name "*.conf" -or -name "*.opml" -or -name "*.page" -or -name "*.txt" -or -name "*.json" -or -name "*.jsonl" -or -name "*.yaml" -or -name "*.xml" -or -name "*.csv"  | \
        sort |  fgrep -v \
                 `# Pandoc fails on embedded Unicode/regexps in JQuery` \
                 -e 'mountimprobable.com/assets/app.js' -e 'jquery.min.js' -e 'static/js/tablesorter.js' \
                 -e 'metadata/backlinks.hs' -e 'metadata/embeddings.bin' -e 'metadata/archive.hs' -e 'docs/www/' | parallel  --jobs 25 syntaxHighlight
    set -e

    bold "Stripping compile-time-only classes unnecessary at runtime…"
    cleanClasses () {
        sed -i -e 's/class=\"\(.*\)archive-local \?/class="\1/g' \
               -e 's/class=\"\(.*\)archive-not \?/class="\1/g' \
               -e 's/class=\"\(.*\)backlink-not \?/class="\1/g' \
               -e 's/class=\"\(.*\)id-not \?/class="\1/g' \
               -e 's/class=\"\(.*\)link-annotated-not \?/class="\1/g' \
               -e 's/class=\"\(.*\)link-live-not \?/class="\1/g' \
               -e 's/ data-embedding[-Dd]istance="0.[0-9]\+"//' \
               -e 's/ data-link[-Tt]ags="[a-z0-9 \/-]\+">/>/' \
    "$@"; }; export -f cleanClasses
    find ./ -path ./_site -prune -type f -o -name "*.page" | fgrep -v -e '#' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | parallel --max-args=100 cleanClasses || true
    find ./_site/metadata/ -type f -name "*.html" | sort | parallel --max-args=100 cleanClasses || true

    ## Pandoc/Skylighting by default adds empty self-links to line-numbered code blocks to make them clickable (as opposed to just setting a span ID, which it also does). These links *would* be hidden except that self links get marked up with up/down arrows, so arrows decorate the codeblocks. We have no use for them and Pandoc/skylighting has no option or way to disable them, so we strip them.
    bold "Stripping self-links from syntax-highlighted HTML…"
    cleanCodeblockSelflinks () {
        if [[ $(fgrep -e 'class="sourceCode' "$@") ]]; then
            sed -i -e 's/<a href="\#cb[0-9]\+-[0-9]\+" aria-hidden="true" tabindex="-1"><\/a>//g' -e 's/<a href="\#cb[0-9]\+-[0-9]\+" aria-hidden="true" tabindex="-1" \/>//g' -- "$@";
        fi
    }
    export -f cleanCodeblockSelflinks
    find ./ -path ./_site -prune -type f -o -name "*.page" | fgrep -v -e '#' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | parallel --max-args=100 cleanCodeblockSelflinks || true

    bold "Reformatting HTML sources to look nicer using HTML Tidy…"
    # WARNING: HTML Tidy breaks the static-compiled MathJax. One of Tidy's passes breaks the mjpage-generated CSS (messes with 'center', among other things). So we do Tidy *before* the MathJax.
    # WARNING: HTML Tidy by default will wrap & add newlines for cleaner HTML in ways which don't show up in rendered HTML - *except* for when something is an 'inline-block', then the added newlines *will* show up, as excess spaces. <https://developer.mozilla.org/en-US/docs/Web/API/Document_Object_Model/Whitespace#spaces_in_between_inline_and_inline-block_elements> <https://patrickbrosset.medium.com/when-does-white-space-matter-in-html-b90e8a7cdd33> And we use inline-blocks for the #page-metadata block, so naive HTML Tidy use will lead to the links in it having a clear visible prefixed space. We disable wrapping entirely by setting `-wrap 0` to avoid that.
    tidyUpFragment () { tidy -indent -wrap 0 --clean yes --break-before-br yes --logical-emphasis yes -quiet --show-warnings no --show-body-only yes -modify "$@" || true; }
    ## tidy wants to dump whole well-formed HTML pages, not fragments to transclude, so switch.
    tidyUpWhole () {    tidy -indent -wrap 0 --clean yes --break-before-br yes --logical-emphasis yes -quiet --show-warnings no --show-body-only no  -modify "$@" || true; }
    export -f tidyUpFragment tidyUpWhole
    find ./metadata/annotations/ -type f -name "*.html" |  parallel --max-args=250 tidyUpFragment
    find ./ -path ./_site -prune -type f -o -name "*.page" | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | fgrep -v -e '#' -e 'Death-Note-script' | parallel --max-args=250 tidyUpWhole

    ## use https://github.com/pkra/mathjax-node-page/ to statically compile the MathJax rendering of the MathML to display math instantly on page load
    ## background: https://joashc.github.io/posts/2015-09-14-prerender-mathjax.html ; installation: `npm install --prefix ~/src/ mathjax-node-page`
    bold "Compiling LaTeX JS+HTML into static CSS+HTML…"
    staticCompileMathJax () {
        if [[ $(fgrep -e '<span class="math inline"' -e '<span class="math display"' "$@") ]]; then
            TARGET=$(mktemp /tmp/XXXXXXX.html)
            cat "$@" | ~/src/node_modules/mathjax-node-page/bin/mjpage --output CommonHTML --fontURL '/static/font/mathjax' | \
            ## WARNING: experimental CSS optimization: can't figure out where MathJax generates its CSS which is compiled,
            ## but it potentially blocks rendering without a 'font-display: swap;' parameter (which is perfectly safe since the user won't see any math early on)
                sed -e 's/^\@font-face {/\@font-face {font-display: swap; /' >> "$TARGET";

            if [[ -s "$TARGET" ]]; then
                mv "$TARGET" "$@" && echo "$@ succeeded";
            else red "$@ failed MathJax compilation";
            fi
        fi
    }
    export -f staticCompileMathJax
    (find ./ -path ./_site -prune -type f -o -name "*.page" | fgrep -v -e '#' | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/';
     find _site/metadata/annotations/ -name '*.html') | shuf | \
        parallel --jobs 31 --max-args=1 staticCompileMathJax

    # 1. turn "As per Foo et al 2020, we can see." → "<p>As per Foo et al 2020, we can see.</p>" (&nbsp;); likewise for 'Foo 2020' or 'Foo & Bar 2020'
    # 2. add non-breaking character to punctuation after links to avoid issues with links like '[Foo](/bar);' where ';' gets broken onto the next line (this doesn't happen in regular text, but only after links, so I guess browsers have that builtin but only for regular text handling?), (U+2060 WORD JOINER (HTML &#8288; · &NoBreak; · WJ))
    # 3. add hair space ( U+200A   HAIR SPACE (HTML &#8202; · &hairsp;)) in slash-separated links or quotes, to avoid overlap of '/' with curly-quote
                               # -e 's/\([a-zA-Z‘’-]\)[   ]et[   ]al[   ]\([1-2][0-9][0-9a-z]\+\)/\1 <span class="etal"><span class="etalMarker">et al<\/span> <span class="etalYear">\2<\/span><\/span>/g' \
                           # -e 's/\([A-Z][a-zA-Z]\+\)[   ]\&[   ]\([A-Z][a-zA-Z]\+\)[   ]\([1-2][0-9][0-9a-z]\+\)/\1 \& \2 <span class="etalYear">\3<\/span>/g' \
    bold "Adding non-breaking spaces…"
    nonbreakSpace () { sed -i -e 's/\([a-zA-Z]\) et al \([1-2]\)/\1 et al \2/g' \
                              -e 's/\([A-Z][a-zA-Z]\+\) \([1-2]\)/\1 \2/g' \
                              `# "Foo & Quux 2020" Markdown → "Foo &amp; Quux 2020" HTML` \
                              -e 's/\([A-Z][a-zA-Z]\+\) \&amp\; \([A-Z][a-zA-Z]\+\) \([1-2][1-2][1-2][1-2]\)/\1 \&amp\;_\2 \3/g' \
                              `# "Foo & Quux 2020" Markdown → "Foo &amp; Quux&nbsp;2020" HTML` \
                              -e 's/\([A-Z][a-zA-Z]\+\) \&amp\; \([A-Z][a-zA-Z]\+\)\&nbsp\;\([1-2][1-2][1-2][1-2]\)/\1 \&amp\;_\2\&nbsp\;\3/g' \
                              -e 's/<\/a>;/<\/a>\⁠;/g' -e 's/<\/a>,/<\/a>\⁠,/g' -e 's/<\/a>\./<\/a>\⁠./g' -e 's/<\/a>\//<\/a>\⁠\//g' \
                              -e 's/\/<wbr><a /\/ <a /g' -e 's/\/<wbr>"/\/ "/g' \
                              -e 's/\([a-z]\)…\([0-9]\)/\1⁠…⁠\2/g' -e 's/\([a-z]\)…<sub>\([0-9]\)/\1⁠…⁠<sub>\2/g' -e 's/\([a-z]\)<sub>…\([0-9]\)/\1⁠<sub>…⁠\2/g' -e 's/\([a-z]\)<sub>…<\/sub>\([0-9]\)/\1⁠<sub>…⁠<\/sub>\2/g' \
                              -e 's/\([a-z]\)⋯\([0-9]\)/\1⁠⋯⁠\2/g' -e 's/\([a-z]\)⋯<sub>\([0-9]\)/\1⁠⋯⁠<sub>\2/g' \
                              -e 's/\([a-z]\)⋱<sub>\([0-9]\)/\1⁠⋱⁠<sub>\2/g' -e 's/\([a-z]\)<sub>⋱\([0-9]\)/\1<sub>⁠⋱⁠\2/g' \
                              -e 's/ \+/ /g' -e 's/​​\+/​/g' -e 's/​ ​​ ​\+/​ /g' -e 's/​ ​\+/ /g' -e 's/​ ​ ​ \+/ /g' -e 's/​ ​ ​ \+/ /g' \
                            "$@"; }; export -f nonbreakSpace;
    find ./ -path ./_site -prune -type f -o -name "*.page" | fgrep -v -e '#' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | parallel --max-args=100 nonbreakSpace || true
    find ./_site/metadata/annotations/ -type f -name "*.html" | sort | parallel --max-args=100 nonbreakSpace || true

    bold "Adding #footnotes section ID…" # Pandoc bug; see <https://github.com/jgm/pandoc/issues/8043>; fixed in <https://github.com/jgm/pandoc/commit/50c9848c34d220a2c834750c3d28f7c94e8b94a0>, presumably will be fixed in Pandoc >2.18
    footnotesIDAdd () { sed -i -e 's/<section class="footnotes footnotes-end-of-document" role="doc-endnotes">/<section class="footnotes" role="doc-endnotes" id="footnotes">/' "$@"; }; export -f footnotesIDAdd
    find ./ -path ./_site -prune -type f -o -name "*.page" | fgrep -v -e '#' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | parallel --max-args=100 footnotesIDAdd || true

    # Testing compilation results:
    set +e

    bold "Checking annotations…"
    λ(){ ghci -istatic/build/ ./static/build/LinkMetadata.hs  -e 'readLinkMetadataAndCheck' 2>&1 >/dev/null; }
    wrap λ "Metadata lint checks fired."

    λ(){ PAGES="$(find ./ -type f -name "*.page" | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/') $(find _site/metadata/annotations/ -type f -name '*.html' | sort)"
         echo "$PAGES" | xargs fgrep -l --color=always -e '<span class="math inline">' -e '<span class="math display">' -e '<span class="mjpage">' | \
                                     fgrep --invert-match -e '/docs/cs/1955-nash' -e '/Backstop' -e '/Death-Note-Anonymity' -e '/Differences' \
                                                          -e '/Lorem' -e '/Modus' -e '/Order-statistics' -e '/Conscientiousness-and-online-education' \
                                -e 'docs%2Fmath%2Fhumor%2F2001-borwein.pdf' -e 'statistical_paradises_and_paradoxes.pdf' -e '1959-shannon.pdf' \
                                -e '/The-Existential-Risk-of-Mathematical-Error' -e '/Replication' \
                                -e '%2Fperformance-pay-nobel.html' -e '/docs/cs/index' -e '/docs/math/index' -e '/Coin-flip' \
                                -e '/nootropics/Magnesium' -e '/Selection' -e 'docs/statistics/bayes/1994-falk' -e '/Zeo' \
                                -e '/Mail-delivery' -e 'docs/link-bibliography/Complexity-vs-AI' -e 'docs/link-bibliography/newsletter/2021/04' \
                                -e '/docs/math/humor/index' -e '/docs/ai/index' -e '/docs/statistics/bias/index' -e '/Variables';
       }
    wrap λ "Warning: unauthorized LaTeX users somewhere"

    λ(){ VISIBLE_N=$(cat ./_site/sitemap.xml | wc --lines); [ "$VISIBLE_N" -le 13040 ] && echo "$VISIBLE_N" && exit 1; }
    wrap λ "Sanity-check number-of-public-site-files in sitemap.xml failed"

    λ(){ COMPILED_N="$(find -L ./_site/ -type f | wc --lines)"
         [ "$COMPILED_N" -le 21000 ] && echo "File count: $COMPILED_N" && exit 1;
         COMPILED_BYTES="$(du --summarize --total --dereference --bytes ./_site/ | tail --lines=1 | cut --field=1)"
         [ "$COMPILED_BYTES" -le 41000000000 ] && echo "Total filesize: $COMPILED_BYTES" && exit 1; }
    wrap λ "Sanity-check: number of files & file-size"

    λ(){ SUGGESTIONS_N=$(cat ./metadata/linkSuggestions.el | wc --lines); [ "$SUGGESTIONS_N" -le 17000 ] && echo "$SUGGESTIONS_N"; }
    wrap λ "Link-suggestion database broken?"

    λ(){ BACKLINKS_N=$(cat ./metadata/backlinks.hs | wc --lines); [ "$BACKLINKS_N" -le 57000 ] && echo "$BACKLINKS_N"; }
    wrap λ "Backlinks database broken?"

    λ(){ egrep -e '#[[:alnum:]-]+#' -e '[[:alnum:]-]+##[[:alnum:]-]+' metadata/*.yaml metadata/*.hs; }
    wrap λ "Broken double-hash anchors in links somewhere?"

    λ(){ egrep -- '/[[:graph:]]\+[0-9]–[0-9]' ./metadata/*.yaml ./metadata/*.hs || true;
         fgrep -- '–' ./metadata/*.hs || true; }
    wrap λ "En-dashes in URLs?"

    λ(){ gf '\\' ./static/css/*.css; }
    wrap λ "Warning: stray backslashes in CSS‽ (Dangerous interaction with minification!)"

    λ(){ find ./ -type f -name "*.page" | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | xargs --max-args=100 fgrep --with-filename --color=always -e '!Wikipedia' -e '!W'")" -e '!W \"' -e ']( http' -e ']( /' -e '!Margin:' -e '<span></span>' -e '<span />' -e '<span/>' -e 'http://gwern.net' -e 'http://www.gwern.net' -e 'https//www' -e 'http//www'  -e 'hhttp://' -e 'hhttps://' -e ' _n_s' -e '/journal/vaop/ncurrent/' -e '://bit.ly/' -e 'remote/check_cookie.html'; }
    wrap λ "Stray or bad URL links in Markdown/HTML."

    λ(){ egrep 'http.*http' metadata/archive.hs  | fgrep -v -e 'web.archive.org' -e 'https-everywhere' -e 'check_cookie.html' -e 'translate.goog' -e 'archive.md' -e 'webarchive.loc.gov' -e 'https://http.cat/'; }
    wrap λ "Bad URL links in archive database (and perhaps site-wide)."

    λ(){ find ./ -type f -name "*.page" | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | xargs --max-args=100 fgrep --with-filename --color=always -e '<div>' | fgrep -v -e 'I got around this by adding in the Hakyll template an additional'; }
    wrap λ "Stray <div>?"

    λ(){ find ./ -type f -name "*.page" | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | xargs --max-args=100 fgrep --with-filename --color=always -e '.invertible-not}{' -e '.invertibleNot' -e '.invertible-Not' -e '{.sallcaps}' -e '{.invertible-not}' -e 'no-image-focus' -e 'no-outline' -e 'idNot' -e 'backlinksNot' -e 'abstractNot' -e 'displayPopNot' -e 'small-table' -e '{.full-width' -e 'collapseSummary' -e 'tex-logotype' -e ' abstract-not' -e 'localArchive' -e 'backlinks-not'; }
    wrap λ "Misspelled/outdated classes in Markdown/HTML."

     λ(){ find ./ -type f -name "*.page" | fgrep -v '/Variables' | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/' | xargs --max-args=100 fgrep --with-filename --color=always -e '{#'; }
     wrap λ "Bad link ID overrides in Markdown."

    λ(){ find ./ -type f -name "*.page" | fgrep --invert-match '_site' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/'  | parallel --max-args=100 egrep --with-filename --color=always -e 'pdf#page[0-9]' -e 'pdf#pg[0-9]' -e '\#[a-z]\+\#[a-z]\+'; }
    wrap λ "Incorrect PDF page links in Markdown."

    λ(){ find ./ -type f -name "*.page" -type f -exec egrep --color=always -e 'cssExtension: [a-c,e-z]' {} \; ; }
    wrap λ "Incorrect drop caps in Markdown."

    λ(){ find ./ -type f -name "*.page" | fgrep --invert-match '_site' | fgrep -v 'Lorem.page' | sort | sed -e 's/\.page$//' -e 's/\.\/\(.*\)/_site\/\1/'  | parallel --max-args=100 "fgrep --with-filename -- '<span class=\"er\">'"; } # NOTE: filtered out Lorem.page's deliberate CSS test-case use of it
    wrap λ "Broken code in Markdown."

    λ(){ eg -e '<div class="admonition .*">[^$]' -e '<div class="epigrah">' **/*.page; }
    wrap λ "Broken admonition paragraph or epigraph in Markdown."

    λ(){ eg -e ' a [aeio]' **/*.page | egrep ' a [aeio]' | fgrep -v -e 'static/build/' -e '/GPT-3' -e '/GPT-2-preference-learning' -e 'sicp/'; }
    wrap λ "Grammar: 'a' → 'an'?"

    λ(){ find -L . -type f -size 0  -printf 'Empty file: %p %s\n' | fgrep -v '.git/FETCH_HEAD' -e './.git/modules/static/logs/refs/remotes/'; }
    wrap λ "Empty files somewhere."

    λ(){ find ./_site/ -type f -not -name "*.*" -exec grep --quiet --binary-files=without-match . {} \; -print0 | parallel --null --max-args=100 "fgrep --color=always --with-filename -- '————–'"; }
    wrap λ "Broken tables in HTML."

    λ(){ eg -e '^"~/' -e '\$";$' -e '$" "docs' ./static/redirects/nginx*.conf; }
    wrap λ "Warning: caret/tilde-less Nginx redirect rule (dangerous—matches anywhere in URL!)"

    λ(){ ghci -istatic/build/ ./static/build/LinkMetadata.hs -e 'warnParagraphizeYAML "metadata/custom.yaml"'; }
    wrap λ "Annotations that need to be rewritten into paragraphs."

    λ(){ runghc -istatic/build/ ./static/build/link-prioritize.hs 20; }
    wrap λ "Links needing annotations by priority:"

    λ(){ eg -e '[a-zA-Z]- ' -e 'PsycInfo Database Record' -e 'https://www.gwern.net' -e '/home/gwern/' -- ./metadata/*.yaml; }
    wrap λ "Check possible typo in YAML metadata database."

    λ(){ eg '  - .*[a-z]–[a-Z]' ./metadata/custom.yaml ./metadata/partial.yaml; }
    wrap λ "Look for en-dash abuse."

    λ(){ fgrep -v -e 'N,N-DMT' -e 'E,Z-nepetalactone' -e 'Z,E-nepetalactone' -e 'N,N-Dimethyltryptamine' -e 'N,N-dimethyltryptamine' -e 'h,s,v' -e ',VGG<sub>' -e 'data-link-icon-type="text,' -- ./metadata/custom.yaml | \
             eg -e ',[A-Za-z]'; }
    wrap λ "Look for run-together commas (but exclude chemical names where that's correct)."

    λ(){ egrep -v '^- - http' ./metadata/*.yaml | eg '[a-zA-Z0-9>]-$'; }
    wrap λ "Look for YAML line breaking at a hyphen."

    λ(){ egrep -e '[.,:;-<!]</a>' -e '\]</a>' -- ./metadata/*.yaml | fgrep -v -e 'i.i.d.' -e 'sativum</em> L.</a>' -e 'this cloning process.</a>' -e '#' -e '[review]</a>' | eg -e '[.,:;-<!]</a>' -e '\]</a>'; }
    wrap λ "Look for punctuation inside links; unless it's a full sentence or a quote or a section link, generally prefer to put punctuation outside."

    λ(){ gf -e '**' -e 'amp#' -e ' _' -e '_ ' -e '!!' -e '*' -- ./metadata/custom.yaml ./metadata/partial.yaml; }
    wrap λ "Look for italics errors."

    λ(){ egrep --color=always -e '^- - /doc/.*' -e '^  -  ' -e "\. '$" -e '[a-zA-Z]\.[0-9]\+ [A-Z]' \
            -e 'href="[a-ce-gi-ln-zA-Z]' -e '>\.\.[a-zA-Z]' -e '\]\([0-9]' \
            -e '[⁰ⁱ⁴⁵⁶⁷⁸⁹⁻⁼⁽⁾ⁿ₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓₔₕₖₗₘₙₚₛₜ]' -e '<p>Table [0-9]' -e '<p>Figure [0-9]' \
            -e 'id="[0-9]' -e '</[a-z][a-z]+\?' -e 'via.*ihub' -e " '$" -e "’’" -e ' a [aeio]' -e '</[0-9]\+' \
            -e ' - 20[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' -e '#googl$' -e "#googl$'" -- ./metadata/*.yaml; }
    wrap λ "Check possible syntax errors in YAML metadata database (regexp matches)."

    λ(){ fgrep --color=always -e ']{' -e 'id="cb1"' -e '<dd>' -e '<dl>' \
            -e '&lgt;/a>' -e '</a&gt;' -e '&lgt;/p>' -e '</p&gt;' -e '<i><i' -e '</e>' -e '>>' \
            -e '<abstract' -e '<em<' -e '<center' -e '<p/>' -e '</o>' -e '< sub>' -e '< /i>' \
            -e '</i></i>' -e '<i><i>' -e 'font-style:italic' -e '<p><p>' -e '</p></p>' -e 'fnref' \
            -e '<figure class="invertible">' -e '</a<' -e 'href="%5Bhttps' -e '<jats:inline-graphic' \
            -e '<figure-inline' -e '<small></small>' -e '<inline-formula' -e '<inline-graphic' -e '<ahref=' \
            -e '](/' -e '-, ' -e '<abstract abstract-type="' -e '- pdftk' -e 'thumb|' -- ./metadata/*.yaml; }
    wrap λ "#1: Check possible syntax errors in YAML metadata database (fixed string matches)."
    λ(){ fgrep --color=always -e '<sec ' -e '<list' -e '</list>' -e '<wb<em>r</em>' -e '<abb<em>' -e '<ext-link' -e '<title>' -e '</title>' \
            -e ' {{' -e '<<' -e '[Formula: see text]' -e '<p><img' -e '<p> <img' -e '- - /./' -e '[Keyword' -e '[KEYWORD' \
            -e '[Key word' -e '<strong>[Keywords:' -e 'href="$"' -e 'en.m.wikipedia.org' -e '<em>Figure' \
            -e '<strongfigure' -e ' ,' -e ' ,' -e 'href="Wikipedia"' -e 'href="W"' -e 'href="(' -e '>/em>' -e '<figure>[' \
            -e '<figcaption></figcaption>' -e '&Ouml;' -e '&uuml;' -e '&amp;gt;' -e '&amp;lt;' -e '&amp;ge;' -e '&amp;le;' \
            -e '<ul class="columns"' -e '<ol class="columns"' -e ',/div>' -e '](https://' -e ' the the ' \
            -e 'Ꜳ' -e 'ꜳ'  -e 'ꬱ' -e 'Ꜵ' -e 'ꜵ' -e 'Ꜷ' -e 'ꜷ' -e 'Ꜹ' -e 'ꜹ' -e 'Ꜻ' -e 'ꜻ' -e 'Ꜽ' -e 'ꜽ' -- ./metadata/*.yaml; }
    wrap λ "#2: Check possible syntax errors in YAML metadata database (fixed string matches)."
    λ(){ fgrep --color=always -e '🙰' -e 'ꭁ' -e 'ﬀ' -e 'ﬃ' -e 'ﬄ' -e 'ﬁ' -e 'ﬂ' -e 'ﬅ' -e 'ﬆ ' -e 'ᵫ' -e 'ꭣ' -e ']9h' -e ']9/' \
            -e ']https' -e 'STRONG>' -e '\1' -e '\2' -e '\3' -e ']($' -e '](₿' -e 'M age' -e '….' -e '((' -e ' %' \
            -e '<h1' -e '</h1>' -e '<h2' -e '</h2>' -e '<h3' -e '</h3>' -e '<h4' -e '</h4>' -e '<h5' -e '</h5>' \
            -e '</strong>::' -e ' bya ' -e '?gi=' -e ' ]' -e '<span class="cit' -e 'gwsed' -e 'full.full' -e ',,' \
            -e '"!"' -e '</sub<' -e 'xref>' -e '<xref' -e '<e>' -e '\\$' -e 'title="http' -e '%3Csup%3E' -e 'sup%3E' -e ' et la ' \
            -e '<strong>Abstract' -e ' ]' -e "</a>’s" -e 'title="&#39; ' -e 'collapseAbstract' -e 'utm_' \
            -e ' JEL' -e 'top-k' -e '</p> </p>' -e '</sip>' -e '<sip>' -e ',</a>' -e ' : ' -e " ' " -e '>/>a' -e '</a></a>' -e '(, ' \
             -- ./metadata/*.yaml;
       }
    wrap λ "#3: Check possible syntax errors in YAML metadata database (fixed string matches)."

    λ(){ fgrep -e '""' -- ./metadata/*.yaml | fgrep -v -e ' alt=""' -e 'controls=""'; }
    wrap λ "Doubled double-quotes in YAML, usually an error."

    λ(){ fgrep -e "'''" -- ./metadata/custom.yaml ./metadata/partial.yaml; }
    wrap λ "Triple quotes in YAML, should be curly quotes for readability/safety."

    λ(){ eg -v '^- - ' -- ./metadata/*.yaml | gf -e ' -- ' -e '---'; }
    wrap λ "Markdown hyphen problems in YAML metadata database"

    λ(){ eg -e '^- - https://en\.wikipedia\.org/wiki/' -- ./metadata/custom.yaml; }
    wrap λ "Wikipedia annotations in YAML metadata database, but will be ignored by popups! Override with non-WP URL?"

    λ(){ eg -e '^- - /[12][0-9][0-9]-[a-z]\.pdf$' -- ./metadata/*.yaml; }
    wrap λ "Wrong filepaths in YAML metadata database—missing prefix?"

    λ(){ eg -e ' [0-9]*[02456789]th' -e ' [0-9]*[3]rd' -e ' [0-9]*[2]nd' -e ' [0-9]*[1]st' -- ./metadata/*.yaml | \
             fgrep -v -e '%' -e figure -e http -e '- - /' -e "- - ! '" -e 'src=' -e "- - '#"; }
    wrap λ "Missing superscript abbreviations in YAML metadata database"

    λ(){ eg -e 'up>T[Hh]<' -e 'up>R[Dd]<' -e 'up>N[Dd]<' -e 'up>S[Tt]<' -- ./metadata/*.yaml; }
    wrap λ "Superscript abbreviations are weirdly capitalized?"

    λ(){ eg -e '<p><img ' -e '<img src="http' -e '<img src="[^h/].*"'  ./metadata/*.yaml; }
    wrap λ "Check <figure> vs <img> usage, image hotlinking, non-absolute relative image paths in YAML metadata database"

    λ(){ gf -e ' significant'  ./metadata/custom.yaml; }
    wrap λ "Misleading language in custom.yaml"

    λ(){ gf -e 'backlinks/' -e 'metadata/annotations/' -e '?gi=' -- ./metadata/backlinks.hs; }
    wrap λ "Bad paths in backlinks databases: metadata paths are being annotated when they should not be!"

    λ(){ eg -e '#[[:alnum:]]+#' -- ./metadata/*.hs ./metadata/*.yaml; }
    wrap λ "Bad paths in metadata databases: redundant anchors"

    λ(){ gf '{#' $(find _site/ -type f -name "index"); }
    wrap λ "Broken anchors in directory indexes."

    λ(){
        set +e;
        IFS=$(echo -en "\n\b");
        PAGES="$(find . -type f -name "*.page" | fgrep -v -e '_site/' -e 'index' | sort -u)"
        OTHERS="$(find metadata/annotations/ -name "*.html"; echo index)"
        for PAGE in $PAGES $OTHERS ./static/404; do
            HTML="${PAGE%.page}"
            TIDY=$(tidy -quiet -errors --doctype html5 ./_site/"$HTML" 2>&1 >/dev/null | \
                       fgrep --invert-match -e '<link> proprietary attribute ' -e 'Warning: trimming empty <span>' \
                             -e "Error: missing quote mark for attribute value" -e 'Warning: <img> proprietary attribute "loading"' \
                             -e 'Warning: <svg> proprietary attribute "alt"' -e 'Warning: <source> proprietary attribute "alt"' \
                             -e 'Warning: missing <!DOCTYPE> declaration' -e 'Warning: inserting implicit <body>' \
                             -e "Warning: inserting missing 'title' element" -e 'Warning: <img> proprietary attribute "decoding"' \
                             -e 'Warning: <a> escaping malformed URI reference' -e 'Warning: <script> proprietary attribute "fetchpriority"' )
            if [[ -n $TIDY ]]; then echo -e "\n\e[31m$PAGE\e[0m:\n$TIDY"; fi
        done

        set -e;
    }
    wrap λ "Markdown→HTML pages don't validate as HTML5"

    ## anchor-checker.php doesn't work on HTML fragments, like the metadata annotations, and those rarely ever have within-fragment anchor links anyway, so skip those:
    λ() { for PAGE in $PAGES ./static/404; do
              HTML="${PAGE%.page}"
              ANCHOR=$(static/build/anchor-checker.php ./_site/"$HTML")
              if [[ -n $ANCHOR ]]; then echo -e "\n\e[31m$PAGE\e[0m:\n$ANCHOR"; fi
          done;
          }
    wrap λ "Anchors linked but not defined inside page?"

    λ(){ find . -not -name "*#*" -xtype l -printf 'Broken symbolic link: %p\n'; }
    wrap λ "Broken symbolic links"

    λ(){ gwa | fgrep -- '[]' | sort; }
    wrap λ "Untagged annotations."

    ## Is the Internet up?
    ping -q -c 5 google.com  &>/dev/null

    # Testing complete.

    # Sync:
    ## make sure nginx user can list all directories (x) and read all files (r)
    chmod a+x $(find ~/wiki/ -type d)
    chmod --recursive a+r ~/wiki/*

    set -e
    ## sync to Hetzner server: (`--size-only` because Hakyll rebuilds mean that timestamps will always be different, forcing a slower rsync)
    ## If any links are symbolic links (such as to make the build smaller/faster), we make rsync follow the symbolic link (as if it were a hard link) and copy the file using `--copy-links`.
    ## NOTE: we skip time/size syncs because sometimes the infrastructure changes values but not file size, and it's confusing when JS/CSS doesn't get updated; since the infrastructure is so small (compared to eg. docs/*), just force a hash-based sync every time:
    bold "Syncing static/…"
    rsync --exclude=".*" --exclude "*.hi" --exclude "*.o" --exclude '#*' --exclude='preprocess-markdown' --exclude 'generateLinkBibliography' --exclude='generateDirectory' --exclude='generateSimilar' --exclude='hakyll' --chmod='a+r' --recursive --checksum --copy-links --verbose --itemize-changes --stats ./static/ gwern@176.9.41.242:"/home/gwern/gwern.net/static"
    ## Likewise, force checks of the Markdown pages but skip symlinks (ie. non-generated files):
    bold "Syncing pages…"
    rsync --exclude=".*" --chmod='a+r' --recursive --checksum --quiet --info=skip0 ./_site/  gwern@176.9.41.242:"/home/gwern/gwern.net"
    ## Randomize sync type—usually, fast, but occasionally do a regular slow hash-based rsync which deletes old files:
    bold "Syncing everything else…"
    SPEED=""; if ((RANDOM % 100 < 99)); then SPEED="--size-only"; else SPEED="--delete --checksum"; fi;
    rsync --exclude=".*" --chmod='a+r' --recursive $SPEED --copy-links --verbose --itemize-changes --stats ./_site/  gwern@176.9.41.242:"/home/gwern/gwern.net"
    set +e

    bold "Expiring ≤100 updated files…"
    # expire CloudFlare cache to avoid hassle of manual expiration: (if more than 100, we've probably done some sort of major systemic change & better to flush whole cache or otherwise investigate manually)
    # NOTE: 'bot-fighting' CloudFlare settings must be largely disabled, otherwise CF will simply CAPTCHA or block outright the various curl/linkchecker tests as 'bots'.
    EXPIRE="$(find . -type f -mtime -1 -not -wholename "*/\.*/*" -not -wholename "*/_*/*" | fgrep -v 'images/thumbnails/' | sed -e 's/\.page$//' -e 's/^\.\/\(.*\)$/https:\/\/www\.gwern\.net\/\1/' | sort | head -100) https://www.gwern.net/sitemap.xml https://www.gwern.net/Lorem https://www.gwern.net/ https://www.gwern.net/index"
    for URL in $EXPIRE; do
        echo -n "Expiring: $URL "
        ( curl --silent --request POST "https://api.cloudflare.com/client/v4/zones/57d8c26bc34c5cfa11749f1226e5da69/purge_cache" \
            --header "X-Auth-Email:gwern@gwern.net" \
            --header "Authorization: Bearer $CLOUDFLARE_CACHE_TOKEN" \
            --header "Content-Type: application/json" \
            --data "{\"files\":[\"$URL\"]}" > /dev/null; ) &
    done
    echo

    # test a random page modified in the past month for W3 validation & dead-link/anchor errors (HTML tidy misses some, it seems, and the W3 validator is difficult to install locally):
    CHECK_RANDOM=$(find . -type f -mtime -31 -name "*.page" | sed -e 's/\.page$//' -e 's/^\.\/\(.*\)$/https:\/\/www\.gwern\.net\/\1/' \
                       | shuf | head -1 | xargs urlencode)
    ( curl --silent --request POST "https://api.cloudflare.com/client/v4/zones/57d8c26bc34c5cfa11749f1226e5da69/purge_cache" \
            --header "X-Auth-Email:gwern@gwern.net" \
            --header "Authorization: Bearer $CLOUDFLARE_CACHE_TOKEN" \
            --header "Content-Type: application/json" \
            --data "{\"files\":[\"$CHECK_RANDOM\"]}" > /dev/null; )
    # wait a bit for the CF cache to expire so it can refill with the latest version to be checked:
    (sleep 20s && $X_BROWSER "https://validator.w3.org/nu/?doc=$CHECK_RANDOM"; sleep 5s; $X_BROWSER "https://validator.w3.org/checklink?uri=$CHECK_RANDOM&no_referer=on"; )

    # once in a while, do a detailed check for accessibility issues using WAVE Web Accessibility Evaluation Tool:
    if ((RANDOM % 100 > 99)); then $X_BROWSER "https://wave.webaim.org/report#/$CHECK_RANDOM"; fi

    # some of the live popups have probably broken, since websites keep adding X-FRAME options...
    if ((RANDOM % 100 > 99)); then ghci -istatic/build/ ./static/build/LinkLive.hs  -e 'linkLiveTestHeaders'; fi

    # Testing post-sync:
    bold "Checking MIME types, redirects, content…"
    c () { curl --compressed --silent --output /dev/null --head "$@"; }
    λ(){ cr () { [[ "$2" != $(c --location --write-out '%{url_effective}' "$1") ]] && echo "$1" "$2"; }
         cr 'https://www.gwern.net/dnm-archives' 'https://www.gwern.net/DNM-archives'
         cr 'https://www.gwern.net/docs/dnb/1978-zimmer.pdf' 'https://www.gwern.net/docs/music-distraction/1978-zimmer.pdf'
         cr 'https://www.gwern.net/AB%20testing' 'https://www.gwern.net/AB-testing'
         cr 'https://www.gwern.net/Archiving%20URLs.html' 'https://www.gwern.net/Archiving-URLs'
         cr 'https://www.gwern.net/Book-reviews' 'https://www.gwern.net/reviews/Books'
         cr 'https://www.gwern.net/docs/ai/2019-10-21-gwern-gpt2-folkrnn-samples.ogg' 'https://www.gwern.net/docs/ai/music/2019-10-21-gwern-gpt2-folkrnn-samples.mp3';
         cr 'https://www.gwern.net/docs/sr/2013-06-07-premiumdutch-profile.htm' 'https://www.gwern.net/docs/darknet-markets/silk-road/1/2013-06-07-premiumdutch-profile.htm'
         cr 'https://www.gwern.net/docs/elections/2012-gwern-notes.txt' 'https://www.gwern.net/docs/prediction/election/2012-gwern-notes.txt'
         cr 'https://www.gwern.net/docs/statistics/peerreview/1976-rosenthal-experimenterexpectancyeffects-ch3.pdf' 'https://www.gwern.net/docs/statistics/peer-review/1976-rosenthal-experimenterexpectancyeffects-ch3.pdf'
         cr 'https://www.gwern.net/docs/longnow/form990-longnowfoundation-2001-12.pdf' 'https://www.gwern.net/docs/long-now/form990-longnowfoundation-2001-12.pdf'
       }
    wrap λ "Check that some redirects go where they should"
    λ() { cm () { [[ "$1" != $(c --write-out '%{content_type}' "$2") ]] && echo "$1" "$2"; }
          ### check key pages:
          ## check every possible extension:
          ## check some random ones:
          cm "application/epub+zip" 'https://www.gwern.net/docs/eva/2002-takeda-notenkimemoirs.epub'
          cm "application/font-sfnt" 'https://www.gwern.net/static/font/drop-cap/kanzlei/Kanzlei-Initialen-M.ttf'
          cm "application/javascript" 'https://www.gwern.net/docs/statistics/order/beanmachine-multistage/script.js'
          cm "application/javascript" 'https://www.gwern.net/static/js/rewrite.js'
          cm "application/javascript" 'https://www.gwern.net/static/js/sidenotes.js'
          cm "application/json" 'https://www.gwern.net/docs/touhou/2013-c84-downloads.json'
          cm "application/msaccess" 'https://www.gwern.net/docs/touhou/2013-06-08-acircle-tohoarrange.mdb'
          cm "application/msword" 'https://www.gwern.net/docs/iq/2014-tenijenhuis-supplement.doc'
          cm "application/octet-stream" 'https://www.gwern.net/docs/zeo/firmware-v2.6.3R-zeo.img'
          cm "application/pdf" 'https://www.gwern.net/docs/cs/2010-bates.pdf'
          cm "application/pdf" 'https://www.gwern.net/docs/history/1694-gregory.pdf'
          cm "application/vnd.ms-excel" 'https://www.gwern.net/docs/dual-n-back/2012-05-30-kundu-dnbrapm.xls'
          cm "application/vnd.oasis.opendocument.spreadsheet" 'https://www.gwern.net/docs/genetics/heritable/1980-osborne-twinsblackandwhite-appendix.ods'
          cm "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" 'https://www.gwern.net/docs/cs/2010-nordhaus-nordhaus2007twocenturiesofproductivitygrowthincomputing-appendix.xlsx'
          cm "application/vnd.openxmlformats-officedocument.wordprocessingml.document" 'https://www.gwern.net/docs/genetics/heritable/2015-mosing-supplement.docx'
          cm "application/vnd.rn-realmedia" 'https://www.gwern.net/docs/rotten.com/library/bio/crime/serial-killers/elmer-wayne-henley/areyouguilty.rm'
          cm "application/x-maff" 'https://www.gwern.net/docs/eva/2001-pulpmag-hernandez-2.html.maff'
          cm "application/x-shockwave-flash" 'https://www.gwern.net/docs/rotten.com/library/bio/entertainers/comic/patton-oswalt/patton.swf'
          cm "application/x-tar" 'https://www.gwern.net/docs/dual-n-back/2011-zhong.tar'
          cm "application/x-xz" 'https://www.gwern.net/docs/personal/2013-09-25-gwern-googlealertsemails.tar.xz'
          cm "application/zip" 'https://www.gwern.net/docs/statistics/bayes/2014-tenan-supplement.zip'
          cm "audio/mpeg" 'https://www.gwern.net/docs/history/1969-schirra-apollo11flighttothemoon.mp3'
          cm "audio/wav" 'https://www.gwern.net/docs/rotten.com/library/bio/entertainers/comic/david-letterman/letterman_any_sense.wav'
          cm "image/gif" 'https://www.gwern.net/docs/gwern.net-gitstats/arrow-none.gif'
          cm "image/gif" 'https://www.gwern.net/docs/rotten.com/library/religion/creationism/creationism6.GIF'
          cm "image/jpeg" 'https://www.gwern.net/docs/personal/2011-gwern-yourmorals.org/schwartz_process.php_files/schwartz_graph.jpg'
          cm "image/jpeg" 'https://www.gwern.net/docs/rotten.com/library/bio/pornographers/al-goldstein/goldstein-fuck-you.jpeg'
          cm "image/jpeg" 'https://www.gwern.net/docs/rotten.com/library/religion/heresy/circumcellions/circumcellions-augustine.JPG'
          cm "image/png" 'https://www.gwern.net/docs/statistics/order/beanmachine-multistage/beanmachine-demo.png'
          cm "image/png" 'https://www.gwern.net/static/img/logo/logo.png'
          cm "image/svg+xml" 'https://www.gwern.net/images/spacedrepetition/forgetting-curves.svg'
          cm "image/x-icon" 'https://www.gwern.net/static/img/favicon.ico'
          cm "image/x-ms-bmp" 'https://www.gwern.net/docs/rotten.com/library/bio/hackers/robert-morris/morris.bmp'
          cm "image/x-xcf" 'https://www.gwern.net/docs/personal/businesscard-front-draft.xcf'
          cm "message/rfc822" 'https://www.gwern.net/docs/linkrot/2009-08-20-b3ta-fujitsuhtml.mht'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/docs/gwern.net-gitstats/gitstats.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/docs/statistics/order/beanmachine-multistage/offsets.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/docs/statistics/order/beanmachine-multistage/style.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/static/css/default.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/static/css/fonts.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/static/css/include/initial.css'
          cm "text/css; charset=utf-8" 'https://www.gwern.net/static/css/links.css'
          cm "text/csv; charset=utf-8" 'https://www.gwern.net/docs/statistics/2013-google-index.csv'
          cm "text/html" 'https://www.gwern.net/atom.xml'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/docs/cs/2012-terencetao-anonymity.html'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/docs/darknet-markets/silk-road/1/2013-06-07-premiumdutch-profile.htm'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/notes/Attention'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/notes/Faster'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/nootropics/Magnesium'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/zeo/CO2'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/reviews/Anime'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/reviews/Anime'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/reviews/Movies'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/docs/existential-risk/1985-hofstadter'
          cm "text/html; charset=utf-8" 'https://www.gwern.net/reviews/Bakewell'
          cm "text/markdown; charset=utf-8" 'https://www.gwern.net/2014-spirulina.page'
          cm "text/plain; charset=utf-8" 'https://www.gwern.net/docs/personal/2009-sleep.txt'
          cm "text/plain; charset=utf-8" 'https://www.gwern.net/static/redirects/nginx.conf'
          cm "text/x-adobe-acrobat-drm" 'https://www.gwern.net/docs/dual-n-back/2012-zhong.ebt'
          cm "text/x-haskell; charset=utf-8" 'https://www.gwern.net/static/build/hakyll.hs'
          cm "text/x-opml; charset=utf-8" 'https://www.gwern.net/docs/personal/rss-subscriptions.opml'
          cm "text/x-patch; charset=utf-8" 'https://www.gwern.net/docs/ai/music/2019-12-22-gpt2-preferencelearning-gwern-abcmusic.patch'
          cm "text/x-r; charset=utf-8" 'https://www.gwern.net/static/build/linkAbstract.R'
          cm "text/plain; charset=utf-8" 'https://www.gwern.net/static/build/linkArchive.sh'
          cm "text/yaml; charset=utf-8" 'https://www.gwern.net/metadata/custom.yaml'
          cm "video/mp4"  'https://www.gwern.net/images/genetics/selection/2019-coop-illinoislongtermselectionexperiment-responsetoselection-animation.mp4'
          cm "video/webm" 'https://www.gwern.net/images/statistics/2003-murray-humanaccomplishment-region-proportions-bootstrap.webm'
          cm "image/jpeg" 'https://www.gwern.net/images/technology/security/lobel-frogandtoadtogether-thebox-crop.jpg'
          cm "image/png"  'https://www.gwern.net/images/technology/search/googlesearch-tools-daterange.png'
          cm "application/wasm"  'https://www.gwern.net/static/js/patterns/en-us.wasm'
        }
    wrap λ "The live MIME types are incorrect"

    ## known-content check:
    λ(){ curl --silent 'https://www.gwern.net/' | tr -d '­' | fgrep --quiet 'This Is The Website</span> of <strong>Gwern Branwen</strong>' || echo "/ content-check failed";
         curl --silent 'https://www.gwern.net/Zeo'   | tr -d '­' | fgrep --quiet 'lithium orotate' || echo "/Zeo Content-check failed"; }
    wrap λ "Known-content check of index/Zeo"

    ## did any of the key pages mysteriously vanish from the live version?
    linkchecker --threads=5 --check-extern --recursion-level=1 'https://www.gwern.net/'
    ## - traffic checks/alerts are done in Google Analytics: alerts on <900 pageviews/daily, <40s average session length/daily.
    ## - latency/downtime checks are done in `updown.io` (every 1h, 1s response-time for /index)
    set +e

    # Cleanup post:
    rm --recursive --force -- ~/wiki/_cache/ ~/wiki/_site/ || true

    # Testing files, post-sync
    bold "Checking for file anomalies…"
    λ(){ fdupes --quiet --sameline --size --nohidden $(find ~/wiki/ -type d | egrep -v -e 'static' -e '.git' -e 'gwern/wiki/$' -e 'metadata/annotations/backlinks' -e 'metadata/annotations/similar') | fgrep --invert-match -e 'bytes each' -e 'trimfill.png'  ; }
    wrap λ "Duplicate file check"

    λ() { find . -perm u=r -path '.git' -prune; }
    wrap λ "Read-only file check" ## check for read-only outside ./.git/ (weird but happened):

    λ(){ gf -e 'RealObjects' -e '404 Not Found Error: No Page' -e ' may refer to:' ./metadata/auto.yaml; }
    wrap λ "Broken links, corrupt authors', or links to Wikipedia disambiguation pages in auto.yaml."

    λ(){ (find . -type f -name "*--*"; find . -type f -name "*~*"; ) | fgrep -v -e images/thumbnails/ -e metadata/annotations/; }
    wrap λ "No files should have double hyphens or tildes in their names."

    λ(){ fgrep --before-context=1 -e 'Right Nothing' -e 'Just ""' ./metadata/archive.hs; }
    wrap λ "Links failed to archive (broken)."

    λ(){ find . -type f | fgrep -v -e '.'; }
    wrap λ "Every file should have at least one period in them (extension)."

    λ(){ find . -type f -name "*\.*\.page" | fgrep -v -e '404.page'; }
    wrap λ "Markdown files should have exactly one period in them."

    λ(){ find . -type f -mtime +3 -name "*#*"; }
    wrap λ "Stale temporary files?"

    bold "Checking for HTML/PDF/image anomalies…"
    λ(){ BROKEN_HTMLS="$(find ./ -type f -name "*.html" | fgrep --invert-match 'static/' | \
                         parallel --max-args=100 "fgrep --ignore-case --files-with-matches \
                         -e '404 Not Found' -e '<title>Sign in - Google Accounts</title' -e 'Download Limit Exceeded' -e 'Access Denied'" | sort)"
         for BROKEN_HTML in $BROKEN_HTMLS;
         do grep --before-context=3 "$BROKEN_HTML" ./metadata/archive.hs | fgrep --invert-match -e 'Right' -e 'Just' ;
         done; }
    wrap λ "Archives of broken links"

    λ(){ BROKEN_PDFS="$(find ./ -type f -name "*.pdf" -not -size 0 | sort | parallel --max-args=100 file | grep -v 'PDF document' | cut -d ':' -f 1)"
         for BROKEN_PDF in $BROKEN_PDFS; do
             echo "$BROKEN_PDF"; grep --before-context=3 "$BROKEN_PDF" ./metadata/archive.hs;
         done; }
    wrap λ "Corrupted or broken PDFs"

    λ(){
        export LL="$(curl --silent ifconfig.me)"
        checkSpamHeader () {
            # extract text from first page:
            HEADER=$(pdftotext -f 1 -l 1 "$@" - 2> /dev/null | \
                         fgrep -e 'INFORMATION TO USERS' -e 'Your use of the JSTOR archive indicates your acceptance of JSTOR' \
                               -e 'This PDF document was made available from www.rand.org as a public' -e 'A journal for the publication of original scientific research' \
                               -e 'This is a PDF file of an unedited manuscript that has been accepted for publication.' \
                               -e 'Additional services and information for ' -e 'Access to this document was granted through an Emerald subscription' \
                               -e 'PLEASE SCROLL DOWN FOR ARTICLE' -e 'ZEW Discussion Papers' -e "$LL" -e 'eScholarship.org' \
                  -e 'Full Terms & Conditions of access and use can be found at' -e 'This paper is posted at DigitalCommons' -e 'This paper is included in the Proceedings of the' \
                  -e 'See discussions, stats, and author profiles for this publication at' \
                  -e 'This article appeared in a journal published by Elsevier. The attached' \
                  -e 'The user has requested enhancement of the downloaded file' \
                  -e 'See discussions, stats, and author profiles for this publication at: https://www.researchgate.net' )
            if [ "$HEADER" != "" ]; then echo "Header: $@"; fi;
        }
        export -f checkSpamHeader
        find ./docs/ -type f -name "*.pdf" | fgrep -v -e 'docs/www/' | sort | parallel checkSpamHeader
    }
    wrap λ "Remove junk from PDF & add metadata"

    λ(){ find ./ -type f -name "*.jpg" | parallel --max-args=100 file | fgrep --invert-match 'JPEG image data'; }
    wrap λ "Corrupted JPGs"

    λ(){ find ./ -type f -name "*.png" | parallel --max-args=100 file | fgrep --invert-match 'PNG image data'; }
    wrap λ "Corrupted PNGs"

    λ(){  find ./ -name "*.png" | fgrep -v -e '/static/img/' -e '/docs/www/misc/' | sort | xargs identify -format '%F %[opaque]\n' | fgrep ' false'; }
    wrap λ "Partially transparent PNGs (may break in dark mode, convert with 'mogrify -background white -alpha remove -alpha off')"

    ## 'file' throws a lot of false negatives on HTML pages, often detecting XML and/or ASCII instead, so we whitelist some:
    λ(){ find ~/wiki/ -type f -name "*.html" | fgrep --invert-match -e 4a4187fdcd0c848285640ce9842ebdf1bf179369 -e 5fda79427f76747234982154aad027034ddf5309 \
                                                -e f0cab2b23e1929d87f060beee71f339505da5cad -e a9abc8e6fcade0e4c49d531c7d9de11aaea37fe5 \
                                                -e 2015-01-15-outlawmarket-index.html -e ac4f5ed5051405ddbb7deabae2bce48b7f43174c.html \
                                                -e %3FDaicon-videos.html -e 86600697f8fd73d008d8383ff4878c25eda28473.html \
             | parallel --max-args=100 file | fgrep --invert-match -e 'HTML document, ' -e 'ASCII text'; }
    wrap λ "Corrupted HTMLs"

    λ(){ checkEncryption () { ENCRYPTION=$(exiftool -quiet -quiet -Encryption "$@");
                              if [ "$ENCRYPTION" != "" ]; then
                                  echo "$@"
                                  TEMP=$(mktemp /tmp/encrypted-XXXX.pdf)
                                  pdftk "$FILE" input_pw output "$TEMP" && mv "$TEMP" "$FILE";
                              fi; }
         export -f checkEncryption
         find ./ -type f -name "*.pdf" -not -size 0 | parallel checkEncryption; }
    wrap λ "'Encrypted' PDFs (fix with pdftk: 'pdftk $PDF input_pw output foo.pdf')" &

    ## DjVu is deprecated (due to SEO: no search engines will crawl DjVu, turns out!):
    λ(){ find ./ -type f -name "*.djvu"; }
    wrap λ "DjVu detected (convert to PDF)"

    ## having noindex tags causes conflicts with the robots.txt and throws SEO errors; except in the ./docs/www/ mirrors, where we don't want them to be crawled:
    λ(){ find ./ -type f -name "*.html" | fgrep --invert-match -e './docs/www/' -e './static/404' -e './static/templates/default.html' | xargs fgrep --files-with-matches 'noindex'; }
    wrap λ "Noindex tags detected in HTML pages"

    λ(){ find ./ -type f -name "*.gif" | fgrep --invert-match -e 'static/img/' -e 'docs/gwern.net-gitstats/' -e 'docs/rotten.com/' -e 'docs/genetics/selection/www.mountimprobable.com/' -e 'images/thumbnails/' | parallel --max-args=100 identify | egrep '\.gif\[[0-9]\] '; }
    wrap λ "Animated GIF is deprecated; GIFs should be converted to WebMs/MP4"

    λ(){ JPGS_BIG="$(find ./ -type f -name "*.jpg" | parallel --max-args=100 "identify -format '%Q %F\n'" {} | sort --numeric-sort | egrep -e '^[7-9][0-9] ' -e '^6[6-9]' -e '^100')";
          echo "$JPGS_BIG";
          compressJPG2 $(echo "$JPGS_BIG" | cut --delimiter=' ' --field=2); }
    wrap λ "Compress JPGs to ≤65% quality"

    ## Find JPGS which are too wide (1600px is an entire screen width on even wide monitors, which is too large for a figure/illustration):
    λ() { for IMAGE in $(find ./images/ -type f -name "*.jpg" -or -name "*.png" | fgrep --invert-match -e '2020-07-19-oceaninthemiddleofanisland-gpt3-chinesepoetrytranslation.png' -e '2020-05-22-caji9-deviantart-stylegan-ahegao.png' -e '2021-meme-virginvschad-journalpapervsblogpost.png' -e 'tadne-l4rz-kmeans-k256-n120k-centroidsamples.jpg' -e '2009-august-newtype-rebuildinterview-maayasakamoto-pg090091.jpg' -e 'images/fiction/batman/' | sort); do
              SIZE_W=$(identify -format "%w" "$IMAGE")
              if (( $SIZE_W > 1600  )); then echo "Too wide image: $IMAGE $SIZE_W ; shrinking…";
                                             mogrify  -resize 1600x10000 "$IMAGE";
              fi;
          done; }
    wrap λ "Too-wide images (downscale)"

    ## Look for domains that may benefit from link icons or link live status now:
    λ() { ghci -istatic/build/ ./static/build/LinkIcon.hs  -e 'linkIconPrioritize' | fgrep -v -e ' secs,' -e 'it :: [(Int, Text)]' -e '[]'; }
    wrap λ "Need link icons?"
    λ() { ghci -istatic/build/ ./static/build/LinkLive.hs  -e 'linkLivePrioritize' | fgrep -v -e ' secs,' -e 'it :: [(Int, T.Text)]' -e '[]'; }
    wrap λ "Need link live whitelist/blacklisting?"

    # if the first of the month, download all pages and check that they have the right MIME type and are not suspiciously small or redirects.
    if [ $(date +"%d") == "1" ]; then

        bold "Checking all MIME types…"
        PAGES=$(cd ~/wiki/ && find . -type f -name "*.page" | sed -e 's/\.\///' -e 's/\.page$//' | sort)
        c () { curl --compressed --silent --output /dev/null --head "$@"; }
        for PAGE in $PAGES; do
            MIME=$(c --max-redirs 0 --write-out '%{content_type}' "https://www.gwern.net/$PAGE")
            if [ "$MIME" != "text/html; charset=utf-8" ]; then red "$PAGE : $MIME"; exit 2; fi

            SIZE=$(curl --max-redirs 0 --compressed --silent "https://www.gwern.net/$PAGE" | wc --bytes)
            if [ "$SIZE" -lt 7500 ]; then red "$PAGE : $SIZE : $MIME" && exit 2; fi
        done

        # check for any pages that could use multi-columns now:
        λ(){ (find . -name "*.page"; find ./metadata/annotations/ -maxdepth 1 -name "*.html") | shuf | \
                 parallel --max-args=100 runghc -istatic/build/ ./static/build/Columns.hs --print-filenames; }
        wrap λ "Multi-columns use?"
    fi
    # if the end of the month, expire all of the annotations to get rid of stale ones:
    if [ $(date +"%d") == "31" ]; then
        rm ./metadata/annotations/*.html
    fi

    # once a year, check all on-site local links to make sure they point to the true current URL; this avoids excess redirects and various possible bugs (such as an annotation not being applied because it's defined for the true current URL but not the various old ones, or going through HTTP nginx redirects first)
    if [ $(date +"%j") == "002" ]; then
        bold "Checking all URLs for redirects…"
        for URL in $(find . -type f -name "*.page" | parallel --max-args=100 runghc ./static/build/link-extractor.hs | \
                         egrep -e '^/' | cut --delimiter=' ' --field=1 | sort -u); do
            echo "$URL"
            MIME=$(curl --silent --max-redirs 0 --output /dev/null --write '%{content_type}' "https://www.gwern.net$URL");
            if [[ "$MIME" == "" ]]; then red "redirect! $URL (MIME: $MIME)"; fi;
        done

        for URL in $(find . -type f -name "*.page" | parallel --max-args=100 ./static/build/link-extractor.hs | \
                         egrep -e '^https://www.gwern.net' | sort -u); do
            MIME=$(curl --silent --max-redirs 0 --output /dev/null --write '%{content_type}' "$URL");
            if [[ "$MIME" == "" ]]; then red "redirect! $URL"; fi;
        done
    fi

    rm static/build/generateLinkBibliography static/build/*.hi static/build/*.o &>/dev/null || true

    bold "Sync successful"
fi
