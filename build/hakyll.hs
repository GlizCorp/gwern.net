#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}

{-
Hakyll file for building Gwern.net
Author: gwern
Date: 2010-10-01
When: Time-stamp: "2023-12-27 20:35:38 gwern"
License: CC-0

Debian dependencies:
$ sudo apt-get install libghc-hakyll-dev libghc-pandoc-dev libghc-filestore-dev libghc-tagsoup-dev libghc-yaml-dev imagemagick rsync git libghc-aeson-dev libghc-missingh-dev libghc-digest-dev tidy gridsite-clients

(GHC is needed for Haskell; Hakyll & Pandoc do the heavy lifting of compiling Markdown files to HTML; tag soup & ImageMagick are runtime dependencies used to help optimize images, and rsync for the server/git upload to hosting/Github respectively.)
Demo command (for the full script, with all static checks & generation & optimizations, see `sync-gwern.net.sh`):
-}

import Control.Monad (when, unless, (<=<))
import Data.Char (toLower)
import Data.IORef (newIORef, IORef)
import Data.List (intercalate, isInfixOf, isSuffixOf)
import qualified Data.Map.Strict as M (lookup)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import Hakyll (compile, composeRoutes, constField,
               symlinkFileCompiler, copyFileCompiler, dateField, defaultContext, defaultHakyllReaderOptions, field, getMetadata, getMetadataField, lookupString,
               defaultHakyllWriterOptions, getRoute, gsubRoute, hakyll, idRoute, itemIdentifier,
               loadAndApplyTemplate, match, modificationTimeField, mapContext,
               pandocCompilerWithTransformM, route, setExtension, pathField, preprocess, boolField, toFilePath,
               templateCompiler, version, Compiler, Context, Item, unsafeCompiler, noResult, getUnderlying, escapeHtml)
import Text.Pandoc (nullAttr, runPure, runWithDefaultPartials, compileTemplate,
                    def, pandocExtensions, readerExtensions, readMarkdown, writeHtml5String,
                    Block(..), HTMLMathMethod(MathJax), defaultMathJaxURL, Inline(..),
                    ObfuscationMethod(NoObfuscation), Pandoc(..), WriterOptions(..), nullMeta)
import Text.Pandoc.Walk (walk, walkM)
import Network.HTTP (urlEncode)
import System.IO.Unsafe (unsafePerformIO)

import qualified Data.Text as T (append, filter, isInfixOf, pack, unpack, length)

-- local custom modules:
import Annotation (tooltipToMetadataTest)
import Image (invertImageInline, imageMagickDimensions, addImgDimensions, imageLinkHeightWidthSet)
import Inflation (nominalToRealInflationAdjuster, inflationDollarTestSuite)
import Interwiki (convertInterwikiLinks, interwikiTestSuite, interwikiCycleTestSuite)
import LinkArchive (archivePerRunN, localizeLink, readArchiveMetadata, testLinkRewrites, ArchiveMetadata)
import LinkAuto (linkAuto)
import LinkBacklink (getBackLinkCheck, getLinkBibLinkCheck, getSimilarLinkCheck)
import LinkIcon (linkIconTest)
import LinkLive (linkLiveTest, linkLivePrioritize)
import LinkMetadata (addPageLinkWalk, readLinkMetadata, readLinkMetadata, writeAnnotationFragments, createAnnotations, hasAnnotation,)
import LinkMetadataTypes (Metadata)
import Tags (tagsToLinksDiv, testTags)
import Typography (linebreakingTransform, typographyTransform, titlecaseInline, titleCaseTest)
import Utils (printGreen, printRed, replace, safeHtmlWriterOptions, simplifiedHTMLString, printDoubleTestSuite, testCycleDetection, cleanAbstractsHTMLTest, cleanAuthorsTest, inlinesToText, flattenLinksInInlines) -- sed
import Arrow (upDownArrows, testUpDownArrows)

main :: IO ()
main =
 do arg <- lookupEnv "SLOW" -- whether to do the more expensive stuff; Hakyll eats the CLI arguments, so we pass it in as an exported environment variable instead
    let slow = "true" == fromMaybe "" arg
    hakyll $ do
               preprocess $ printGreen ("Testing link icon matches…" :: String)
               let linkIcons = linkIconTest
               unless (null linkIcons) $ preprocess $ printRed ("Link icon rules have errors in: " ++ show linkIcons)

               let arrows = testUpDownArrows
               unless (null arrows) $ preprocess $ printRed ("Self-link arrow up/down AST test suite has errors in: " ++ show arrows)

               let doubles = printDoubleTestSuite
               unless (null doubles) $ preprocess $ printRed ("Double-printing function test suite has errors in: " ++ show doubles)

               let cycles = testCycleDetection
               unless (null cycles) $ preprocess $ printRed ("Cycle-detection test suite has errors in: " ++ show cycles)

               let cases = titleCaseTest
               unless (null cases) $ preprocess $ printRed ("Title-case typography test suite has errors in: " ++ show cases)

               let infixRewrites = cleanAbstractsHTMLTest ++ cleanAuthorsTest
               preprocess $ printGreen ("Tested HTML/author cleanup rules for infinite loops, verified: " ++ show (length infixRewrites))

               archives <- preprocess testLinkRewrites
               unless (null archives) $ preprocess $ printRed ("Link-archive rewrite test suite has errors in: " ++ show archives)

               preprocess $ printGreen ("Testing tag rewrites…" :: String)
               preprocess testTags

               preprocess $ printGreen ("Testing live-link-popup rules…" :: String)
               let livelinks = linkLiveTest
               unless (null livelinks) $ preprocess $ printRed ("Live link pop rules have errors in: " ++ show livelinks)
               _ <- preprocess linkLivePrioritize -- generate testcases for new live-link targets
               -- NOTE: we skip `linkLiveTestHeaders` due to requiring too much time & IO & bandwidth, and instead do it once in a while post-sync

               preprocess $ printGreen ("Testing interwiki rewrite rules…" :: String)
               let interwikiPopupTestCases = interwikiTestSuite
               unless (null interwikiPopupTestCases) $ preprocess $ printRed ("Interwiki rules have errors in: " ++ show interwikiPopupTestCases)
               let interwikiCycleTestCases = interwikiCycleTestSuite
               unless (null interwikiCycleTestCases) $ preprocess $ printRed ("Interwiki redirect rewrite rules have errors in: " ++ show interwikiCycleTestCases)

               let inflationTestCases = inflationDollarTestSuite
               unless (null inflationTestCases) $ preprocess $ printRed ("Inflation-adjustment rules have errors in: " ++ show inflationTestCases)

               unless (null tooltipToMetadataTest) $ preprocess $ printRed ("Tooltip-parsing rules have errors in: " ++ show tooltipToMetadataTest)
               preprocess $ printGreen ("Testing finished." :: String)

               preprocess $ printGreen ("Local archives parsing…" :: String)
               am           <- preprocess readArchiveMetadata
               hasArchivedN <- preprocess $ if slow then newIORef archivePerRunN else newIORef 0

               preprocess $ printGreen ("Popup annotations parsing…" :: String)
               meta <- preprocess readLinkMetadata
               preprocess $ if slow then do printGreen ("Writing all annotations…" :: String)
                                            writeAnnotationFragments am meta hasArchivedN False
                                    else do printGreen ("Writing only missing annotations…" :: String)
                                            writeAnnotationFragments am meta hasArchivedN True

               preprocess $ printGreen ("Begin site compilation…" :: String)
               match "**.page" $ do
                   -- strip extension since users shouldn't care if HTML3-5/XHTML/etc (cool URLs); delete apostrophes/commas & replace spaces with hyphens
                   -- as people keep screwing them up endlessly:
                   route $ gsubRoute "," (const "") `composeRoutes` gsubRoute "'" (const "") `composeRoutes` gsubRoute " " (const "-") `composeRoutes`
                            setExtension ""
                   -- https://groups.google.com/forum/#!topic/pandoc-discuss/HVHY7-IOLSs
                   let readerOptions = defaultHakyllReaderOptions
                   compile $ do
                              ident <- getUnderlying
                              indexpM <- getMetadataField ident "index"
                              let indexp = fromMaybe "" indexpM
                              pandocCompilerWithTransformM readerOptions woptions (unsafeCompiler . pandocTransform meta am hasArchivedN indexp)
                                >>= loadAndApplyTemplate "static/template/default.html" (postCtx meta)
                                >>= imgUrls

               let static        = route idRoute >> compile copyFileCompiler
               version "static" $ mapM_ (`match` static) ["metadata/**"] -- we want to overwrite annotations in-place with various post-processing things

               -- handle the simple static non-.page files; we define this after the pages because the pages' compilation has side-effects which may create new static files (archives & downsized images)
               let staticSymlink = route idRoute >> compile symlinkFileCompiler -- WARNING: custom optimization requiring forked Hakyll installation; see https://github.com/jaspervdj/hakyll/issues/786
               version "static" $ mapM_ (`match` staticSymlink) [
                                       "doc/**",
                                       "**.hs",
                                       "**.sh",
                                       "**.txt",
                                       "**.html",
                                       "**.page",
                                       "**.css",
                                       "**.R",
                                       "**.conf",
                                       "**.php",
                                       "**.svg",
                                       "**.png",
                                       "**.jpg",
                                       "**.yaml",
                                       -- skip "static/build/**" because of the temporary files
                                       "static/css/**",
                                       "static/font/**",
                                       "static/img/**",
                                       "static/include/**",
                                       "static/nginx/**",
                                       "static/redirect/**",
                                       "static/template/**",
                                       "static/**.conf",
                                       "static/**.css",
                                       "static/**.gif",
                                       "static/**.git",
                                       "static/**.gitignore",
                                       "static/**.hs",
                                       "static/**.html",
                                       "static/**.ico",
                                       "static/**.js",
                                       "static/**.net",
                                       "static/**.png",
                                       "static/**.R",
                                       "static/**.sh",
                                       "static/**.svg",
                                       "static/**.ttf",
                                       "static/**.otf",
                                       "static/**.php",
                                       "static/**.py",
                                       "static/**.wasm",
                                       "static/**.el",
                                       "static/build/.htaccess",
                                       "static/build/upload",
                                       "static/build/newsletter-lint",
                                       "static/build/gwa",
                                       "static/build/crossref",
                                       "static/build/compressPdf",
                                       "static/build/compressJPG2",
                                       "test-include",
                                       "atom.xml"] -- copy stub of deprecated RSS feed

               match "static/template/*.html" $ compile templateCompiler

woptions :: WriterOptions
woptions = defaultHakyllWriterOptions{ writerSectionDivs = True,
                                       writerTableOfContents = True,
                                       writerColumns = 130,
                                       writerTemplate = Just tocTemplate,
                                       writerTOCDepth = 4,
                                       -- we use MathJax directly to bypass Texmath; this enables features like colored equations:
                                       -- https://docs.mathjax.org/en/latest/input/tex/extensions/color.html http://mirrors.ctan.org/macros/latex/required/graphics/color.pdf#page=4 eg. "Roses are $\color{red}{\text{beautiful red}}$, violets are $\color{blue}{\text{lovely blue}}$" or "${\color{red} x} + {\color{blue} y}$"
                                       writerHTMLMathMethod = MathJax defaultMathJaxURL,
                                       writerEmailObfuscation = NoObfuscation }
   where
    -- below copied from https://github.com/jaspervdj/hakyll/blob/e8ed369edaae1808dffcc22d1c8fb1df7880e065/web/site.hs#L73 because god knows I don't know what this type bullshit is either:
    -- "When did it get so hard to compile a string to a Pandoc template?"
    tocTemplate =
        either error id $ either (error . show) id $
        runPure $ runWithDefaultPartials $
        compileTemplate "" $ T.pack $ "<div id=\"TOC\" class=\"TOC\">$toc$</div> <div id=\"markdownBody\" class=\"markdownBody\">" ++
                              noScriptTemplate ++ "$body$" -- we do the main $body$ substitution inside default.html so we can inject stuff inside the #markdownBody wrapper; the div is closed there

   -- NOTE: we need to do the site-wide `<noscript>` warning  to make sure it is inside the #markdownBody and gets all of the CSS styling that we expect it to.
    noScriptTemplate = "<noscript><div id=\"noscript-warning-header\" class=\"admonition error\"><div class=\"admonition-title\"><p>[<strong>Warning</strong>: JavaScript Disabled!]</p></div> <p>[For support of key <a href=\"/design\" title=\"About: Gwern.net Design: principles, features, links, tricks\">website features</a> (link annotation popups/popins & transclusions, collapsible sections, backlinks, tablesorting, image zooming, <a href=\"/sidenote\">sidenotes</a> etc), you must enable JavaScript.]</p></div></noscript>"

imgUrls :: Item String -> Compiler (Item String)
imgUrls item = do
    rte <- getRoute $ itemIdentifier item
    case rte of
        Nothing -> return item
        Just _  -> traverse (unsafeCompiler . addImgDimensions) item

postCtx :: Metadata -> Context String
postCtx md =
    fieldsTagPlain md <>
    fieldsTagHTML  md <>
    titlePlainField "titlePlain" <>
    descField False "title" "title" <>
    descField True "description" "descriptionEscaped" <>
    descField False "description" "description" <>
    -- NOTE: as a hack to implement conditional loading of JS/metadata in /index, in default.html, we switch on an 'index' variable; this variable *must* be left empty (and not set using `constField "index" ""`)! (It is defined in the YAML front-matter of /index.page as `index: true` to set it to a non-null value.) Likewise, "error404" for generating the 404.html page.
    -- similarly, 'author': default.html has a conditional to set 'Gwern Branwen' as the author in the HTML metadata if 'author' is not defined, but if it is, then the HTML metadata switches to the defined author & the non-default author is exposed in the visible page metadata as well for the human readers.
    defaultContext <>
    boolField "backlinksYes" (check notNewsletterOrIndex getBackLinkCheck)    <>
    boolField "similarsYes"  (check notNewsletterOrIndex getSimilarLinkCheck) <>
    boolField "linkbibYes"   (check (const True)         getLinkBibLinkCheck) <>
    dateField "created" "%F" <>
    -- if no manually set last-modified time, fall back to checking file modification time:
    dateField "modified" "%F" <>
    modificationTimeField "modified" "%F" <>
    -- page navigation defaults:
    constField "next" "/index" <>
    constField "previous" "/index" <>
    -- metadata:
    constField "status" "notes" <>
    constField "confidence" "log" <>
    constField "importance" "0" <>
    constField "cssExtension" "drop-caps-de-zs" <>
    imageDimensionWidth "thumbnailHeight" <>
    imageDimensionWidth "thumbnailWidth" <>
    -- for use in templating, `<body class="page-$safeURL$">`, allowing page-specific CSS like `.page-sidenote` or `.page-slowing-moores-law`:
    escapedTitleField "safeURL" <>
    (mapContext (\p -> urlEncode $ concatMap (\t -> if t=='/'||t==':' then urlEncode [t] else [t]) ("/" ++ replace ".page" ".html" p)) . pathField) "escapedURL" -- for use with backlinks ie 'href="/metadata/annotation/backlink/$escapedURL$"', so 'Bitcoin-is-Worse-is-Better.page' → '/metadata/annotation/backlink/%2FBitcoin-is-Worse-is-Better.html', 'notes/Faster.page' → '/metadata/annotation/backlink/%2Fnotes%2FFaster.html'

lookupTags :: Metadata -> Item a -> Compiler (Maybe [String])
lookupTags m item = do
  let path = "/" ++ replace ".page" "" (toFilePath $ itemIdentifier item)
  case M.lookup path m of
    Nothing               -> return Nothing
    Just (_,_,_,_,tags,_) -> return $ Just tags

fieldsTagHTML :: Metadata -> Context String
fieldsTagHTML m = field "tagsHTML" $ \item -> do
  maybeTags <- lookupTags m item
  case maybeTags of
    Nothing -> return "" -- noResult "no tag field"
    Just tags -> case runPure $ writeHtml5String safeHtmlWriterOptions (Pandoc nullMeta [tagsToLinksDiv $ map T.pack tags]) of
                   Left e -> error ("Failed to compile tags to HTML fragment: " ++ show item ++ show tags ++ show e)
                   Right html -> return (T.unpack html)

fieldsTagPlain :: Metadata -> Context String
fieldsTagPlain m = field "tagsPlain" $ \item -> do
    maybeTags <- lookupTags m item
    case maybeTags of
      Nothing -> return "" -- noResult "no tag field"
      Just tags -> return $ intercalate ", " tags

-- should backlinks be in the metadata? We skip backlinks for newsletters & indexes (excluded from the backlink generation process as well) due to lack of any value of looking for backlinks to hose.
-- HACK: uses unsafePerformIO. Not sure how to check up front without IO... Read the backlinks DB and thread it all the way through `postCtx`, and `main`?
check :: (String -> Bool) -> (String -> IO (String, String)) -> Item a -> Bool
check filterfunc checkfunc i = unsafePerformIO $ do let p = pageIdentifierToPath i
                                                    (_,path) <- checkfunc p
                                                    return $ path /= "" && filterfunc p
notNewsletterOrIndex :: String -> Bool
notNewsletterOrIndex p = not ("newsletter/" `isInfixOf` p || "index" `isSuffixOf` p)

pageIdentifierToPath :: Item a -> String
pageIdentifierToPath i = "/" ++ replace ".page" "" (toFilePath $ itemIdentifier i)

imageDimensionWidth :: String -> Context String
imageDimensionWidth d = field d $ \item -> do
                  metadataMaybe <- getMetadataField (itemIdentifier item) "thumbnail"
                  let (h,w) = case metadataMaybe of
                        Nothing -> ("530","441") -- /static/img/logo/logo-whitebg-large-border.png-530px.jpg dimensions
                        Just thumbnailPath -> unsafePerformIO $ imageMagickDimensions $ tail thumbnailPath
                  if d == "thumbnailWidth" then return w else return h

escapedTitleField :: String -> Context String
escapedTitleField = mapContext (map toLower . replace "/" "-" . replace ".page" "") . pathField

-- for 'title' metadata, they can have formatting like <em></em> italics; this would break when substituted into <title> or <meta> tags.
-- So we render a simplified ASCII version of every 'title' field, '$titlePlain$', and use that in default.html when we need a non-display
-- title.
titlePlainField :: String -> Context String
titlePlainField d = field d $ \item -> do
                  metadataMaybe <- getMetadataField (itemIdentifier item) "title"
                  case metadataMaybe of
                    Nothing -> noResult "no title field"
                    Just t -> return (simplifiedHTMLString t)

descField :: Bool -> String -> String -> Context String
descField escape d d' = field d' $ \item -> do
                  metadata <- getMetadata (itemIdentifier item)
                  let descMaybe = lookupString d metadata
                  case descMaybe of
                    Nothing -> noResult "no description field"
                    Just desc ->
                     let cleanedDesc = runPure $ do
                              pandocDesc <- readMarkdown def{readerExtensions=pandocExtensions} (T.pack desc)
                              let pandocDesc' = convertInterwikiLinks $ linebreakingTransform pandocDesc
                              htmlDesc <- writeHtml5String def pandocDesc' -- NOTE: we can skip 'safeHtmlWriterOptions' use here because descriptions are always very simple & will never have anything complex like tables
                              return $ (\t -> if escape then escapeHtml t else t) $ T.unpack htmlDesc
                      in case cleanedDesc of
                         Left _          -> noResult "no description field"
                         Right finalDesc -> return $ replace "<p>" "" $ replace "</p>" "" finalDesc -- strip <p></p>

pandocTransform :: Metadata -> ArchiveMetadata -> IORef Integer -> String -> Pandoc -> IO Pandoc
pandocTransform md adb archived indexp' p = -- linkAuto needs to run before `convertInterwikiLinks` so it can add in all of the WP links and then convertInterwikiLinks will add link-annotated as necessary; it also must run before `typographyTransform`, because that will decorate all the 'et al's into <span>s for styling, breaking the LinkAuto regexp matches for paper citations like 'Brock et al 2018'
                           -- tag-directories/link-bibliographies special-case: we don't need to run all the heavyweight passes, and LinkAuto has a regrettable tendency to screw up section headers, so we check to see if we are processing a document with 'index: true' set in the YAML metadata, and if we are, we slip several of the rewrite transformations:
  do let indexp = indexp' == "true"
     let pw
           = if indexp then convertInterwikiLinks p else
               walk footnoteAnchorChecker $ convertInterwikiLinks $
                 walk linkAuto p
     unless indexp $ createAnnotations md pw
     let pb = (if indexp then id else upDownArrows) $ walk (hasAnnotation md) $ addPageLinkWalk pw  -- we walk local link twice: we need to run it before 'hasAnnotation' so essays don't get overridden, and then we need to add it later after all of the archives have been rewritten, as they will then be local links
     pbt <- fmap typographyTransform . walkM (localizeLink adb archived)
              $ if indexp then pb else
                walk (map nominalToRealInflationAdjuster) pb
     let pbth = wrapInParagraphs $ addPageLinkWalk $ walk headerSelflinkAndSanitize pbt
     if indexp then return pbth else
       walkM (imageLinkHeightWidthSet <=< invertImageInline) pbth

-- | Make headers into links to themselves, so they can be clicked on or copy-pasted easily. Put the displayed text into title-case if not already.
--
-- While processing Headers, ensure that they have valid CSS IDs. (Pandoc will happily generate invalid HTML IDs, which contain CSS-forbidden characters like periods; this can cause fatal errors in JS/CSS without dangerous workarounds. So the author needs to manually add a period-less ID. This is an outstanding issue: <https://github.com/jgm/pandoc/issues/6553>.)
-- NOTE: We could instead require the author to manually assign an ID like `# Foo.bar {#foobar}`, which would be reliable & compatible with other Markdown systems, but this would not solve the problem on *generated* pages, like the tag-directories which put paper titles in headers & will routinely incur this problem. So we have to automate it as a Pandoc rewrite.
-- headerSelflinkAndSanitize :: Block -> Block
-- headerSelflinkAndSanitize x@(Header _ _ ((Link _ _ _):[])) = x -- already processed by `headerSelflinkAndSanitize`
-- headerSelflinkAndSanitize   (Header a b (x@(Link _ _ _):y@(Link _ _ _):z)) = Header a b (x : flattenLinksInInlines (y:z))
-- headerSelflinkAndSanitize   (Header a b (x@(Link _ _ _):Space:y@(Link _ _ _):z)) = Header a b (x : flattenLinksInInlines (y:z))
-- headerSelflinkAndSanitize   (Header a b (x@(Str _):Space:y@(Link _ _ _):z)) = Header a b (x : flattenLinksInInlines (y:z))
-- headerSelflinkAndSanitize   (Header a b (x@(Str _):xx@(Str _):y@(Link _ _ _):z)) = Header a b (x : xx : flattenLinksInInlines (y:z))
-- headerSelflinkAndSanitize x@(Header _ _ []) = error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid header with no visible text‽ This should be impossible: " ++ show x
-- headerSelflinkAndSanitize x@(Header _ ("",_,_) _) = error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid header with no specified ID‽ This should be impossible: " ++ show x
-- headerSelflinkAndSanitize x@(Header a (href,b,c) d) =
--   let href' = T.filter (`notElem` ['.', '#', ':']) href in -- NOTE: these appear to be the only dangerously inconsistent allowed characters, and Pandoc already seems to filter out octothorpe & colon, but we will double-check by filtering those out too.
--     unsafePerformIO $ do
--       when (href' /= href) $ printRed $ "hakyll.hs: headerSelflinkAndSanitize: Invalid ID for header after filtering! The header text must be changed or a valid ID manually set: " ++ show x
--       if href' == "" then error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid ID for header after filtering! The header text must be changed or a valid ID manually set: " ++ show x else
--         -- NOTE: we do not need to check the new ID for uniqueness, as colliding IDs are invalid HTML and the document author is responsible for ensuring no collisions; this is enforced by checking the final HTML using HTML Tidy to verify validity.
--         return $ Header a (href',b,c) [Link nullAttr (walk titlecaseInline d)
--                                        ("#"`T.append`href', "Link to section: § '" `T.append` inlinesToText d `T.append` "'")]
-- headerSelflinkAndSanitize x = x

headerSelflinkAndSanitize :: Block -> Block
headerSelflinkAndSanitize x@(Header _ _ ((Link _ _ _):[])) = x
-- headerSelflinkAndSanitize (Header a b (x:xs))
--   | isLinkOrStr x = Header a b (x : flattenLinksInInlines xs)
--   where
--         isLinkOrStr :: Inline -> Bool
--         isLinkOrStr Link{}  = True
--         isLinkOrStr (Str _) = True
--         isLinkOrStr Space   = True
--         isLinkOrStr _       = False
headerSelflinkAndSanitize x@(Header _ _ []) = error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid header with no visible text‽ This should be impossible: " ++ show x
headerSelflinkAndSanitize x@(Header _ ("",_,_) _) = error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid header with no specified ID‽ This should be impossible: " ++ show x
headerSelflinkAndSanitize x@(Header a (href,b,c) d) =
  let href' = T.filter (`notElem` ['.', '#', ':']) href in
    unsafePerformIO $ do
      when (href' /= href) $ printRed $ "hakyll.hs: headerSelflinkAndSanitize: Invalid ID for header after filtering! The header text must be changed or a valid ID manually set: " ++ show x
      if href' == "" then error $ "hakyll.hs: headerSelflinkAndSanitize: Invalid ID for header after filtering! The header text must be changed or a valid ID manually set: " ++ show x else
        return $ Header a (href',b,c) [Link nullAttr (walk titlecaseInline $ flattenLinksInInlines d)
                                       ("#"`T.append`href', "Link to section: § '" `T.append` inlinesToText d `T.append` "'")]
headerSelflinkAndSanitize x = x

-- Check for footnotes which may be broken and rendering wrong, with the content inside the body rather than as a footnote. (An example was present for an embarrassingly long time in /gpt-3…)
footnoteAnchorChecker :: Inline -> Inline
footnoteAnchorChecker n@(Note [Para [Str s]]) = if " " `T.isInfixOf` s || T.length s > 10 then n else error ("Warning: a short spaceless footnote! May be a broken anchor (ie. swapping the intended '[^abc]:' for '^[abc]:'): " ++ show n)
footnoteAnchorChecker n = n

-- HACK: especially in list items, we wind up with odd situations like '<li>text</li>' instead of '<li><p>text</p></li>'. This *seems* to be due to the HTML/Markdown AST roundtripping resulting in 'loose' elements which Pandoc defaults to 'Plain'. I do not use 'Plain' anywhere wittingly, so it should be safe to blindly rewrite all instances of Plain to Para?
wrapInParagraphs :: Pandoc -> Pandoc
wrapInParagraphs = walk go
  where
    go :: Block -> Block
    go (Plain strs) = Para strs
    go x = x
