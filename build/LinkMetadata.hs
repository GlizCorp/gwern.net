{- LinkMetadata.hs: module for generating Pandoc links which are annotated with metadata, which can then be displayed to the user as 'popups' by /static/js/popups.js. These popups can be excerpts, abstracts, article introductions etc, and make life much more pleasant for the reader - hxbover over link, popup, read, decide whether to go to link.
Author: Gwern Branwen
Date: 2019-08-20
When:  Time-stamp: "2021-04-27 21:36:48 gwern"
License: CC-0
-}

-- TODO:
-- 1. bugs in packages: rxvist doesn't appear to support all bioRxiv/medRxiv schemas, including the '/early/' links, forcing me to use curl+Tagsoup; the R library 'fulltext' crashes on examples like `ft_abstract(x = c("10.1038/s41588-018-0183-z"))`

{-# LANGUAGE OverloadedStrings, DeriveGeneric #-}
module LinkMetadata (isLocalLink, readLinkMetadata, writeAnnotationFragments, Metadata, MetadataItem, createAnnotations, hasAnnotation, parseRawBlock, sed, replaceMany) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (unless, void, when)
import Data.Aeson (eitherDecode, FromJSON)
import Data.Char (isAlpha, isNumber, isSpace, toLower)
import qualified Data.ByteString as B (appendFile, writeFile)
import qualified Data.ByteString.Lazy as BL (length)
import qualified Data.ByteString.Lazy.UTF8 as U (toString) -- TODO: why doesn't using U.toString fix the Unicode problems?
import qualified Data.Map.Strict as M (fromList, toList, lookup, traverseWithKey, union, Map)
import qualified Data.Text as T (append, unpack, pack, Text)
import Data.Containers.ListUtils (nubOrd)
import Data.FileStore.Utils (runShellCommand)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sort, (\\))
import Data.List.Utils (replace, split, uniq)
import Data.Maybe (Maybe, fromMaybe)
import Data.Text.IO as TIO (readFile, writeFile)
import Data.Yaml as Y (decodeFileEither, encode, ParseException)
import GHC.Generics (Generic)
import Network.HTTP (urlEncode)
import System.Directory (doesFileExist)
import System.Exit (ExitCode(ExitFailure))
import System.FilePath (takeBaseName, takeExtension)
import System.IO (stderr, hPutStrLn)
import Text.HTML.TagSoup (isTagCloseName, isTagOpenName, parseTags, Tag(TagOpen, TagText))
import Text.Pandoc (readerExtensions, writerWrapText, writerHTMLMathMethod, Inline(Link, Span), HTMLMathMethod(MathJax),
                    defaultMathJaxURL, def, readLaTeX, readMarkdown, writeHtml5String, WrapOption(WrapNone), runPure, pandocExtensions,
                    readHtml, writerExtensions, nullAttr, nullMeta, queryWith,
                    Inline(Str, RawInline, Space), Pandoc(..), Format(..), Block(RawBlock, Para, BlockQuote, Div))
import Text.Pandoc.Walk (walk, walkM)
import Text.Regex (subRegex, mkRegex)

import Inflation (nominalToRealInflationAdjuster)
import Interwiki (convertInterwikiLinks)
import Typography (typographyTransform)
import LinkArchive (localizeLink, ArchiveMetadata)

----
-- Should the current link get a 'G' icon because it's an essay or regular page of some sort?
-- we exclude several directories (docs/, static/, images/) entirely; a Gwern.net page is then any link without a file extension (ie. a '.' in the URL - we guarantee that no Markdown essay has a period inside its URL).
-- Local links get the 'link-local' class.
isLocalLink :: Pandoc -> Pandoc
isLocalLink = walk isLocalLink'
  where isLocalLink' :: Inline -> Inline
        isLocalLink' y@(Link (a,b,c) e (f,g)) =
          let f' = replace "https://www.gwern.net" "" $ T.unpack f in
            (if
                not ("/" `isPrefixOf` f') ||
              ("/images/" `isPrefixOf` f' || "/static/" `isPrefixOf` f')
             then y else
               (if takeExtension f' /= "" then y else
                  (Link (a, "link-local" : b, c) e (f, g))))
        isLocalLink' x = x


-------------------------------------------------------------------------------------------------------------------------------

readLinkMetadata :: IO Metadata
readLinkMetadata = do
             -- for hand created definitions, to be saved; since it's handwritten and we need line errors, we use YAML:
             custom <- readYaml "metadata/custom.yaml"

             -- Quality checks:
             -- - URLs, titles & annotations should all be unique, although author/date/DOI needn't be (we might annotate multiple parts of a single DOI)
             let urls = map fst custom
             when (length (uniq (sort urls)) /=  length urls) $ error $ "Duplicate URLs in 'custom.yaml'!" ++ unlines (urls \\ nubOrd urls)
             let brokenUrls = filter (\u -> null u || not (head u == 'h' || head u == '/') || ' ' `elem` u) urls in when (brokenUrls /= []) $ error $ "Broken URLs in 'custom.yaml': " ++ unlines brokenUrls
             let titles = map (\(_,(t,_,_,_,_)) -> t) custom in when (length (uniq (sort titles)) /= length titles) $ error $ "Duplicate titles in 'custom.yaml': " ++ unlines (titles \\ nubOrd titles)
             let annotations = map (\(_,(_,_,_,_,s)) -> s) custom in when (length (uniq (sort annotations)) /= length annotations) $ error $ "Duplicate annotations in 'custom.yaml': " ++ unlines (annotations \\ nubOrd annotations)
             -- - DOIs are optional since they usually don't exist, and dates are optional for always-updated things like WP; but everything else should:
             let emptyCheck = filter (\(u,(t,a,_,_,s)) ->  "" `elem` [u,t,a,s]) custom
             unless (null emptyCheck) $ error $ "Link Annotation Error: empty mandatory fields! This should never happen: " ++ show emptyCheck

             -- auto-generated cached definitions; can be deleted if gone stale
             rewriteLinkMetadata "metadata/auto.yaml" -- cleanup first
             auto <- readYaml "metadata/auto.yaml"

             -- merge the hand-written & auto-generated link annotations, and return:
             let final = M.union (M.fromList custom) (M.fromList auto) -- left-biased, 'custom' overrides 'auto'
             return final

writeAnnotationFragments :: ArchiveMetadata -> Metadata -> IO ()
writeAnnotationFragments am md = void $ M.traverseWithKey (\p mi -> void $ forkIO $ writeAnnotationFragment am md p mi) md
writeAnnotationFragment :: ArchiveMetadata -> Metadata -> Path -> MetadataItem -> IO ()
writeAnnotationFragment am md u i@(a,b,c,d,e) = when (length e > 180) $
                                          do let u' = linkCanonicalize u
                                             let filepath = "metadata/annotations/" ++ urlEncode u' ++ ".html"
                                             let filepath' = take 274 filepath
                                             when (filepath /= filepath') $ hPutStrLn stderr $ "Warning, annotation fragment path → URL truncated! Was: " ++ filepath ++ " but truncated to: " ++ filepath' ++ "; (check that the truncated file name is still unique, otherwise some popups will be wrong)"
                                             let titleHtml    = typesetHtmlField "" a
                                             let authorHtml   = typesetHtmlField "" b
                                             -- obviously no point in smallcapsing date/DOI, so skip those
                                             let abstractHtml = typesetHtmlField e e
                                             -- TODO: this is fairly redundant with 'pandocTransform' in hakyll.hs; but how to fix without circular dependencies...
                                             let pandoc = Pandoc nullMeta $ generateAnnotationBlock (u', Just (titleHtml,authorHtml,c,d,abstractHtml))
                                             void $ createAnnotations md pandoc
                                             let annotationPandoc = walk (nominalToRealInflationAdjuster . convertInterwikiLinks) $ walk (hasAnnotation md True) pandoc
                                             localizedPandoc <- walkM (localizeLink am) annotationPandoc

                                             let finalHTMLEither = runPure $ writeHtml5String def{writerExtensions = pandocExtensions} localizedPandoc
                                             case finalHTMLEither of
                                               Left er -> error ("Writing annotation fragment failed! " ++ show u ++ ": " ++ show i ++ ": " ++ show er)
                                               Right finalHTML -> let refloated = T.pack $ restoreFloatRight e $ T.unpack finalHTML
                                                                  in writeUpdatedFile filepath' refloated
   where -- write only when changed, to reduce sync overhead
    writeUpdatedFile :: FilePath -> T.Text -> IO ()
    writeUpdatedFile target contentsNew = do existsOld <- doesFileExist target
                                             if not existsOld then
                                               TIO.writeFile target contentsNew
                                               else do contentsOld <- TIO.readFile target
                                                       when (contentsNew /= contentsOld) $ TIO.writeFile target contentsNew

    typesetHtmlField :: String -> String -> String
    typesetHtmlField orig t = let fieldPandocMaybe = runPure $ readHtml def{readerExtensions = pandocExtensions} (T.pack t) in
                           case fieldPandocMaybe of
                             Left errr -> error $ show i ++ ": " ++ t ++ show errr
                             Right fieldPandoc -> let (Pandoc _ fieldPandoc') = typographyTransform fieldPandoc in
                                                    let (Right fieldHtml) = runPure $ writeHtml5String def{writerExtensions = pandocExtensions} (Pandoc nullMeta fieldPandoc') in
                               restoreFloatRight orig $ T.unpack fieldHtml

-- walk each page, extract the links, and create annotations as necessary for new links
createAnnotations :: Metadata -> Pandoc -> IO ()
createAnnotations md (Pandoc _ markdown) = mapM_ (annotateLink md) $ queryWith extractLink markdown
  where
   extractLink :: Inline -> [String]
   extractLink (Link _ _ (path, _)) = [T.unpack path]
   extractLink _ = []

annotateLink :: Metadata -> String -> IO Bool
annotateLink md target =
  do when (null target) $ error (show target)
     -- normalize: convert 'https://www.gwern.net/docs/foo.pdf' to '/docs/foo.pdf' and './docs/foo.pdf' to '/docs/foo.pdf'
     -- the leading '/' indicates this is a local Gwern.net file
     let target' = replace "https://www.gwern.net/" "/" target
     let target'' = if head target' == '.' then drop 1 target' else target'

     let annotated = M.lookup target'' md
     case annotated of
       -- the link has a valid annotation already defined, so we're done: nothing changed.
       Just _  -> return False
       Nothing -> do new <- linkDispatcher target''
                     case new of
                       -- some failures we don't want to cache because they may succeed when checked differently or later on or should be fixed:
                       Left Temporary -> return False -- hPutStrLn stderr ("Skipping "++target) >> return False
                       -- cache the failures too, so we don't waste time rechecking the PDFs every build; return False because we didn't come up with any new useful annotations:
                       Left Permanent -> writeLinkMetadata target'' ("", "", "", "", "") >> return False
                       Right y@(f,m@(_,_,_,_,e)) -> do
                                       when (e=="") $ hPutStrLn stderr (f ++ ": " ++ show target ++ ": " ++ show y)
                                       -- return true because we *did* change the database & need to rebuild:
                                       forkIO (writeLinkMetadata target'' m) >> return True

-- walk the page, and modify each URL to specify if it has an annotation available or not:
hasAnnotation :: Metadata -> Bool -> Block -> Block
hasAnnotation md idp = walk (hasAnnotationInline md idp)
    where hasAnnotationInline :: Metadata -> Bool -> Inline -> Inline
          hasAnnotationInline mdb idBool y@(Link (_,_,_) _ (f,_)) =
            if "https://en.wikipedia.org/wiki/" `isPrefixOf` T.unpack f then addHasAnnotation idBool True y ("","","","","")
            else
              let f' = linkCanonicalize $ T.unpack f in
                case M.lookup f' mdb of
                  Nothing -> y
                  Just mi -> addHasAnnotation idBool False y mi
          hasAnnotationInline _ _ y = y

          addHasAnnotation :: Bool -> Bool -> Inline -> MetadataItem -> Inline
          addHasAnnotation idBool forcep y@(Link (a,b,c) e (f,g)) (_,aut,dt,_,abstrct) =
           let a'
                 | not idBool = ""
                 | a == "" = generateID (T.unpack f) aut dt
                 | otherwise = a
           in -- erase link ID?
              if (length abstrct < 180) && not forcep then y else
                  Link (a', nubOrd (b++["docMetadata"]), c) e (f,g)
          addHasAnnotation _ _ z _ = z

parseRawBlock :: Block -> Block
parseRawBlock x@(RawBlock (Format "html") h) = let markdown = runPure $ readHtml def{readerExtensions = pandocExtensions} h in
                                          case markdown of
                                            Left e -> error (show x ++ ": " ++ show e)
                                            Right (Pandoc _ markdown') -> Div nullAttr markdown'
parseRawBlock x = x

generateAnnotationBlock :: (FilePath, Maybe LinkMetadata.MetadataItem) -> [Block]
generateAnnotationBlock (f, ann) = case ann of
                              Nothing -> nonAnnotatedLink
                              Just ("",   _, _,_ ,_) -> nonAnnotatedLink
                              Just (_,    _, _,_ ,"") -> nonAnnotatedLink
                              Just (tle,aut,dt,doi,abst) -> let lid = let tmpID = (generateID f aut dt) in if tmpID=="" then "" else (T.pack "linkBibliography-") `T.append` tmpID in
                                                            let author = if aut=="" then [Space] else [Space, Span ("", ["author"], []) [Str (T.pack aut)], Space] in
                                                              let date = if dt=="" then [] else [Str "(", Span ("", ["date"], []) [Str (T.pack dt)], Str ")"] in
                                                                let values = if doi=="" then [] else [("doi",T.pack doi)] in
                                                                  let link =
                                                                             Link (lid, ["docMetadata"], values) [RawInline (Format "html") (T.pack $ "“"++tle++"”")] (T.pack f,"")
                                                                        in
                                                                    -- make sure every abstract is wrapped in paragraph tags for proper rendering:
                                                                     let abst' = let start = take 3 abst in if start == "<p>" || start == "<ul" || start == "<ol" || start=="<h2" || start=="<h3" || start=="<bl" || take 7 abst == "<figure" then abst else "<p>" ++ abst ++ "</p>" in
                                                                       -- check that float-right hasn't been deleted by Pandoc again:
                                                                       let abst'' = restoreFloatRight abst abst' in
                                                              [Para
                                                                ([link,
                                                                  Str ","] ++ author ++ date ++ [Str ":"]),
                                                           BlockQuote [parseRawBlock $ RawBlock (Format "html") (rewriteAnchors f (T.pack abst''))]
                                                           ]
                             where
                               nonAnnotatedLink :: [Block]
                               nonAnnotatedLink = [Para [Link nullAttr [Str (T.pack f)] (T.pack f, "")]]

-- annotations, like /Faces, often link to specific sections or anchors, like 'I clean the data with [Discriminator Ranking](#discriminator-ranking)'; when transcluded into other pages, these links are broken. But we don't want to rewrite the original abstract as `[Discriminator Ranking](/Faces#discriminator-ranking)` to make it absolute, because that screws with section-popups/link-icons! So instead, when we write out the body of each annotation inside the link bibliography, while we still know what the original URL was, we traverse it looking for any links starting with '#' and rewrite them to be absolute:
-- WARNING: because of the usual RawHtml issues, reading with Pandoc doesn't help - it just results in RawInlines which still need to be parsed somehow. I settled for a braindead string-rewrite; in annotations, there shouldn't be *too* many cases where the href=# pattern shows up without being a div link...
rewriteAnchors :: FilePath -> T.Text -> T.Text
rewriteAnchors f = T.pack . replace "href=\"#" ("href=\""++f++"#") . T.unpack

-------------------------------------------------------------------------------------------------------------------------------

type Metadata = M.Map Path MetadataItem -- (Title, Author, Date, DOI, Abstract)
type MetadataItem = (String, String, String, String, String)
type MetadataList = [(Path, MetadataItem)]
type Path = String

readYaml :: Path -> IO MetadataList
readYaml yaml = do file <- Y.decodeFileEither yaml :: IO (Either ParseException [[String]])
                   case file of
                     Left e -> error $ "File: "++ yaml ++ "; parse error: " ++ show e
                     Right y -> (return $ concatMap convertListToMetadata y) :: IO MetadataList
                where
                 convertListToMetadata :: [String] -> MetadataList
                 convertListToMetadata [u, t, a, d, di, s] = [(u, (t,a,d,di,s))]
                 convertListToMetadata e = error $ "Pattern-match failed (too few fields?): " ++ show e

-- clean a YAML metadata file by sorting & unique-ing it (this cleans up the various appends or duplicates):
rewriteLinkMetadata :: Path -> IO ()
rewriteLinkMetadata yaml = do old <- readYaml yaml
                              let new = M.fromList old :: Metadata -- NOTE: constructing a Map data structure automatically sorts/dedupes
                              let newYaml = Y.encode $ map (\(a,(b,c,d,e,f)) -> (a,b,c,d,e,f)) $ -- flatten [(Path, (String, String, String, String, String))]
                                    M.toList new
                              B.writeFile yaml newYaml

-- append (rather than rewrite entirely) a new automatic annotation if its Path is not already in the auto-annotation database:
writeLinkMetadata :: Path -> MetadataItem -> IO ()
writeLinkMetadata l i@(t,a,d,di,abst) = do hPutStrLn stderr (l ++ " : " ++ show i)
                                           -- we do deduplication in rewriteLinkMetadata (when constructing the Map) on startup, so no need to check here, just blind write:
                                           let newYaml = Y.encode [(l,t,a,d,di,abst)]
                                           B.appendFile "metadata/auto.yaml" newYaml

data Failure = Temporary | Permanent deriving Show

linkDispatcher :: Path -> IO (Either Failure (Path, MetadataItem))
arxiv, biorxiv, pubmed :: Path -> IO (Either Failure (Path, MetadataItem))
linkDispatcher l | "https://en.wikipedia.org/wiki/" `isPrefixOf` l = return (Left Temporary) -- WP is now handled by annotations.js calling the Mobile WP API
                     | "https://arxiv.org/abs/" `isPrefixOf` l = arxiv l
                     | "https://www.biorxiv.org/content/" `isPrefixOf` l = biorxiv l
                     | "https://www.medrxiv.org/content/" `isPrefixOf` l = biorxiv l
                     | "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC" `isPrefixOf` l = pubmed l
                     -- WARNING: this is not a complete list of PLOS domains, just the ones currently used on Gwern.net; didn't see a complete list anywhere...
                     | "journals.plos.org" `isInfixOf` l = pubmed l
                     | "plosbiology.org" `isInfixOf` l = pubmed l
                     | "ploscompbiology.org" `isInfixOf` l = pubmed l
                     | "plosgenetics.org" `isInfixOf` l = pubmed l
                     | "plosmedicine.org" `isInfixOf` l = pubmed l
                     | "plosone.org" `isInfixOf` l = pubmed l
                     | null l = return (Left Permanent)
                     -- locally-hosted PDF?
                     | ".pdf" `isInfixOf` l = let l' = linkCanonicalize l in if head l' == '/' then pdf $ tail l else return (Left Permanent)
                     -- We skip Gwern.net pages, because Gwern.net pages are handled as live cross-page popups: if they have an abstract, it'll be visible at the top right under the metadata block, so generating annotations automatically turns out to be unnecessary (and bug prone)
                     | "/" `isPrefixOf` l || "https://www.gwern.net/" `isPrefixOf` l = return (Left Permanent)
                     -- And everything else is unhandled:
                     | otherwise = return (Left Permanent)

-- handles both PM & PLOS right now:
pubmed l = do (status,_,mb) <- runShellCommand "./" Nothing "Rscript" ["static/build/linkAbstract.R", l]
              case status of
                ExitFailure err -> hPutStrLn stderr (intercalate " : " [l, show status, show err, show mb]) >> return (Left Permanent)
                _ -> do
                        let parsed = lines $ replace " \n" "\n" $ trim $ U.toString mb
                        if length parsed < 5 then return (Left Permanent) else
                          do let (title:author:date:doi:abstrct) = parsed
                             return $ Right (l, (trimTitle title, initializeAuthors $ trim author, trim date, trim doi, processPubMedAbstract $ unlines abstrct))

pdf :: Path -> IO (Either Failure (Path, MetadataItem))
pdf p = do (_,_,mb) <- runShellCommand "./" Nothing "exiftool" ["-printFormat", "$Title$/$Author$/$Date", "-Title", "-Author", "-dateFormat", "%F", "-Date", p]
           (_,_,mb2) <- runShellCommand "./" Nothing "exiftool" ["-printFormat", "$DOI", "-DOI", p]
           if BL.length mb > 0 then
             do let (etitle:eauthor:edate:_) = lines $ U.toString mb
                let edoi = lines $ U.toString mb2
                let edoi' = if null edoi then "" else head edoi
                -- PDFs have both a 'Creator' and 'Author' metadata field sometimes. Usually Creator refers to the (single) person who created the specific PDF file in question, and Author refers to the (often many) authors of the content; however, sometimes PDFs will reverse it: 'Author' means the PDF-maker and 'Creators' the writers. If the 'Creator' field is longer than the 'Author' field, then it's a reversed PDF and we want to use that field instead of omitting possibly scores of authors from our annotation.
                (_,_,mb3) <- runShellCommand "./" Nothing "exiftool" ["-printFormat", "$Creator", "-Creator", p]
                let ecreator = U.toString mb3
                let author = initializeAuthors $ trim $ if (length eauthor > length ecreator) || ("Adobe" `isInfixOf` ecreator || "InDesign" `isInfixOf` ecreator || "Arbortext" `isInfixOf` ecreator || "Unicode" `isInfixOf` ecreator || "Total Publishing" `isInfixOf` ecreator || "pdftk" `isInfixOf` ecreator || "aBBYY" `isInfixOf` ecreator || "FineReader" `isInfixOf` ecreator || "LaTeX" `isInfixOf` ecreator || "hyperref" `isInfixOf` ecreator || "Microsoft" `isInfixOf` ecreator  || "Acrobat" `isInfixOf` ecreator || "ocrmypdf" `isInfixOf` ecreator || "tesseract" `isInfixOf` ecreator || "Windows" `isInfixOf` ecreator ) then eauthor else ecreator
                hPutStrLn stderr $ "PDF: " ++ p ++" DOI: " ++ edoi'
                a <- fmap (fromMaybe "") $ doi2Abstract edoi'
                return $ Right (p, (trimTitle etitle, author, trim $ replace ":" "-" edate, edoi', a))
                -- if there is no abstract, there's no point in displaying title/author/date since that's already done by tooltip+URL:
                -- case aMaybe of
                --   Nothing -> return (Left Permanent)
                --   Just a -> return $ Right (p, (trimTitle etitle, author, trim $ replace ":" "-" edate, edoi', a))
           else return (Left Permanent)

-- nested JSON object: eg 'jq .message.abstract'
newtype Crossref = Crossref { message :: Message } deriving (Show,Generic)
instance FromJSON Crossref
newtype Message = Message { abstract :: Maybe String } deriving (Show,Generic)
instance FromJSON Message
doi2Abstract :: String -> IO (Maybe String)
doi2Abstract doi = if length doi < 7 then return Nothing
                   else do (_,_,bs) <- runShellCommand "./" Nothing "curl" ["--location", "--silent", "https://api.crossref.org/works/"++doi, "--user-agent", "gwern+crossrefscraping@gwern.net"]
                           threadDelay 1000000 -- delay 1s
                           if bs=="Resource not found." then return Nothing
                           else let j = eitherDecode bs :: Either String Crossref
                                in case j of -- start unwrapping...
                                    Left e -> hPutStrLn stderr ("Error: Crossref request failed: "++doi++" "++e) >> return Nothing
                                    Right j' -> let j'' = abstract $ message j' in
                                      case j'' of
                                       Nothing -> return Nothing
                                       Just a -> let trimmedAbstract = cleanAbstractsHTML a
                                                 in return $ Just trimmedAbstract

-- handles medRxiv too (same codebase)
biorxiv p = do (status,_,bs) <- runShellCommand "./" Nothing "curl" ["--location", "--silent", p, "--user-agent", "gwern+biorxivscraping@gwern.net"]
               case status of
                 ExitFailure _ -> hPutStrLn stderr ("BioRxiv download failed: " ++ p) >> return (Left Permanent)
                 _ -> do
                        let b = U.toString bs
                        let f = parseTags b
                        let metas = filter (isTagOpenName "meta") f

                        let title = concat $ parseMetadataTagsoup "DC.Title" metas
                        if (title=="") then hPutStrLn stderr ("BioRxiv parsing failed: " ++ p ++ ": " ++ show metas) >> return (Left Permanent)
                          else do
                                 let date    = concat $ parseMetadataTagsoup "DC.Date" metas
                                 let doi     = concat $ parseMetadataTagsoup "citation_doi" metas
                                 let author  = initializeAuthors $ intercalate ", " $ filter (/="") $ parseMetadataTagsoup "DC.Contributor" metas
                                 let abstrct = cleanAbstractsHTML $ concat $ parseMetadataTagsoup "citation_abstract" metas
                                 return $ Right (p, (title, author, date, doi, abstrct))
  where
    parseMetadataTagsoup :: String -> [Tag String] -> [String]
    parseMetadataTagsoup key metas = map (\(TagOpen _ (a:b)) ->  if snd a == key then snd $ head b else "") metas

arxiv url = do -- Arxiv direct PDF links are deprecated but sometimes sneak through or are deliberate section/page links
               let arxivid = takeWhile (/='#') $ if "/pdf/" `isInfixOf` url && ".pdf" `isSuffixOf` url
                                 then replaceMany [("https://arxiv.org/pdf/", ""), (".pdf", "")] url
                                 else replace "https://arxiv.org/abs/" "" url
               threadDelay 15000000 -- Arxiv anti-scraping has been getting increasingly aggressive about blocking me despite hardly touching them, so add a long 15s delay for each request...
               (status,_,bs) <- runShellCommand "./" Nothing "curl" ["--location","--silent","https://export.arxiv.org/api/query?search_query=id:"++arxivid++"&start=0&max_results=1", "--user-agent", "gwern+arxivscraping@gwern.net"]
               case status of
                 ExitFailure _ -> hPutStrLn stderr ("Error: curl API call failed on Arxiv ID " ++ arxivid) >> return (Left Temporary)
                 _ -> do let (tags,_) = element "entry" $ parseTags $ U.toString bs
                         let title = trimTitle $ findTxt $ fst $ element "title" tags
                         let authors = initializeAuthors $ intercalate ", " $ getAuthorNames tags
                         let published = take 10 $ findTxt $ fst $ element "published" tags -- "2017-12-01T17:13:14Z" → "2017-12-01"
                         let doi = findTxt $ fst $ element "arxiv:doi" tags
                         let abst = processArxivAbstract url $ findTxt $ fst $ element "summary" tags
                         return $ Right (url, (title,authors,published,doi,abst))
-- NOTE: we inline Tagsoup convenience code from Network.Api.Arxiv (https://hackage.haskell.org/package/arxiv-0.0.1/docs/src/Network-Api-Arxiv.html); because that library is unmaintained & silently corrupts data (https://github.com/toschoo/Haskell-Libs/issues/1), we keep the necessary code close at hand so at least we can easily patch it when errors come up
-- Get the content of a 'TagText'
findTxt :: [Tag String] -> String
findTxt [] = ""
findTxt (t:ts) = case t of
                   TagText x -> x
                   _         -> findTxt ts
getAuthorNames :: [Tag String] -> [String]
getAuthorNames = go
  where go s = case element "author" s of
                 ([],[]) -> []
                 (a,[])  -> [getString "name" a]
                 (a,r)   ->  getString "name" a : go r
        getString :: String -> [Tag String] -> String
        getString n soup = let (i,_) = element n soup
                      in if null i then "" else findTxt i
element :: String -> [Tag String] -> ([Tag String], [Tag String])
element _  []     = ([],[])
element nm (t:ts) | isTagOpenName nm t = let (r,rs) = closeEl 0 ts
                                          in (t:r,rs)
                  | otherwise          = element nm ts
  where closeEl :: Int -> [Tag String] -> ([Tag String], [Tag String])
        closeEl _ [] = ([],[])
        closeEl i (x:xs) = go i (isTagCloseName nm x) x xs
        go i b x xs | b && i == 0        = ([x],xs)
                    | b && i >  0        = let (r,rs) = closeEl (i-1) xs
                                            in (x:r,rs)
                    | isTagOpenName nm x = let (r,rs) = closeEl (i+1) xs
                                            in (x:r,rs)
                    | otherwise          = let (r,rs) = closeEl i     xs
                                            in (x:r,rs)

processPubMedAbstract :: String -> String
processPubMedAbstract abst = let clean = runPure $ do
                                   pandoc <- readMarkdown def{readerExtensions=pandocExtensions} (T.pack abst)
                                   html <- writeHtml5String def pandoc
                                   return $ T.unpack html
                             in case clean of
                                  Left e -> error $ show e ++ ": " ++ abst
                                  Right output -> trim $ replace "<br/>" " " $ cleanAbstractsHTML output

-- Arxiv makes multi-paragraph abstracts hard because the 'HTML' is actually LaTeX, so we need to special Pandoc preprocessing (for paragraph breaks, among other issues):
processArxivAbstract :: String -> String -> String
processArxivAbstract u a = let cleaned = runPure $ do
                                    pandoc <- readLaTeX def{ readerExtensions = pandocExtensions } $ T.pack $
                                      -- NOTE: an Arxiv API abstract can have any of '%', '\%', or '$\%$' in it. All of these are dangerous and potentially breaking downstream LaTeX parsers.
                                              replaceMany [("%", "\\%"), ("\\%", "%"), ("$\\%$", "%"), ("\n  ", "\n\n")] a
                                    writeHtml5String def{writerWrapText=WrapNone, writerHTMLMathMethod = MathJax defaultMathJaxURL} pandoc
              in case cleaned of
                 Left e -> error $ u ++ " : " ++ show e ++ ": " ++ a
                 Right output -> cleanAbstractsHTML $ T.unpack output

--------------------------------------------
-- String munging and processing
--------------------------------------------

-- WARNING: Pandoc erases attributes set on `<figure>` like 'float-right', so blindly restore a float-right class to all <figure>s if there was one in the original (it's a hack, but I generally don't use any other classes besides 'float-right', or more than one image per annotation or mixed float/non-float, and it's a lot simpler...):
restoreFloatRight :: String -> String -> String
restoreFloatRight original final = if ("<figure class=\"float-right\">" `isInfixOf` original) then replace "<figure>" "<figure class=\"float-right\">" final else final

-- so after meditating on it, I think I've decided how duplicate annotation links should be handled:
--
-- 1. all citations like 'Foo & Bar 1990' or 'Quux et al 2020' should be hyperlinked (either as a internal anchor or fulltext link);
-- 2. annotated links get a predictable anchor ID generated from the metadata, like '#foo-et-al-2020' (ie grab the first 4 characters of the date, check
--    the number of commas in the author field to decide if 'foo 1990' or 'foo & bar 1990' or 'foo et al 1990' etc);
-- 3. duplicate links will, then, generate invalid HTML as two Foo et al 2020s (which must be links per #1) will both define id='#foo-et-al-2020', and this will trigger htmltidy errors/warnings on sync; so, one of them will be manually edited to either point to another instance which
--    is part of a larger discussion/context, or be given a manual ID like id='#foo-et-al-2020-2'. (since the annotation is based on the URL not the
--    ID, this doesn't affect the annotations.)
--
-- so, all citations have a hyperlink, supporting hypertextual reading or readers who didn't happen to
-- memorize the previous use in the page, independent instances of links remain independent while back/forward
-- references pop up the relevant section with the annotated link in context, htmltidy automatically detects links that need to be updated, and a
-- regexp can warn about citation-text which needs to be linkified.
generateID :: String -> String -> String -> T.Text
generateID url author date
  -- shikata ga nai:
  | author == "" = ""
  | date   == "" = ""
  -- skip the ubiquitous WP links: I don't repeat WP refs, and the identical author/dates impedes easy cites/links anyway.
  | "https://en.wikipedia.org/wiki/" `isPrefixOf` url = ""
  -- eg '/Faces' = '#gwern-faces'
  | "Gwern Branwen" == author = T.pack (trim $ replaceMany [(".", "-"), ("--", "-"), ("/", "-"), ("#", "-"), ("https://", ""), ("https://www.gwern.net/", "")] $ map toLower $ "gwern-"++url)
  -- 'Foo 2020' → '#foo-2020'; 'Foo & Bar 2020' → '#foo-bar-2020'; 'foo et al 2020' → 'foo-et-al-2020'
  | otherwise = T.pack $ let year = if date=="" then "2020" else take 4 date in -- YYYY-MM-DD
                           let authors = split ", " $ head $ split " (" author in -- handle affiliations like "Tom Smith (Wired)"
                           let authorCount = length authors in
                             if authorCount == 0 then "" else
                               let firstAuthorSurname = filter isAlpha $ reverse $ takeWhile (/=' ') $ reverse $ head authors in
                                 -- handle cases like '/docs/statistics/peerreview/1975-johnson-2.pdf'
                                 let suffix = (let s = take 1 $ reverse $ takeBaseName url in if (s /= "") && isNumber (head s) then "-" ++ s else "") in
                                   let suffix' = if suffix == "-1" then "" else suffix in
                                 filter (/='.') $ map toLower $ if authorCount >= 3 then
                                                 firstAuthorSurname ++ "-et-al-" ++ year ++ suffix' else
                                                   if authorCount == 2 then
                                                     let secondAuthorSurname = filter isAlpha $ reverse $ takeWhile (/=' ') $ reverse (authors !! 1) in
                                                       firstAuthorSurname ++ "-" ++ secondAuthorSurname ++ "-" ++ year ++ suffix'
                                                   else
                                                     firstAuthorSurname ++ "-" ++ year ++ suffix'

linkCanonicalize :: String -> String
linkCanonicalize l | "https://www.gwern.net/" `isPrefixOf` l = replace "https://www.gwern.net/" "/" l
                   -- | head l == '#' = l
                   | otherwise = l

trim :: String -> String
trim = reverse . dropWhile badChars . reverse . dropWhile badChars -- . filter (/='\n')
  where badChars c = isSpace c || (c=='-')

sed :: String -> String -> (String -> String)
sed before after s = subRegex (mkRegex before) s after
sedMany :: [(String,String)] -> (String -> String)
sedMany regexps s = foldr (uncurry sed) s regexps

replaceMany :: [(String,String)] -> (String -> String)
replaceMany rewrites s = foldr (uncurry replace) s rewrites

-- handle initials consistently as space-separated; delete the occasional final Oxford 'and' cluttering up author lists
initializeAuthors :: String -> String
initializeAuthors a' = replaceMany [(" and ", ", "), (", & ", ", "), (", and ", ", ")] $
                       sedMany [
                         ("([A-Z]\\.)([A-Za-z]+)", "\\1 \\2"),                              -- "A.Smith" → "A. Smith"
                         ("([A-Z]\\.)([A-Z]\\.) ([A-Za-z]+)", "\\1 \\2 \\3"),               -- "A.B. Smith" → "A. B. Smith"
                         ("([A-Z]\\.)([A-Z]\\.)([A-Z]\\.) ([A-Za-z]+)", "\\1 \\2 \\3 \\4"), -- "C.A.B. Smith" → "C. A. B. Smith"
                         (" ([A-Z]) ", " \\1. ")                                            -- "John H Smith" → "John H. Smith"
                         ]
                       a'

-- title clean up: delete the period at the end of many titles, extraneous colon spacing, remove Arxiv's newline+doublespace, and general whitespace cleaning
trimTitle :: String -> String
trimTitle [] = ""
trimTitle t = let t' = reverse $ replaceMany [(" : ", ": "), ("\n ", "")] $ trim t in
                if not (null t') then reverse (if head t' == '.' then tail t' else t') else ""

cleanAbstractsHTML :: String -> String
cleanAbstractsHTML t = trim $
  -- regexp substitutions:
  sedMany [
  ("([a-zA-Z]) – ([[:punct:]])", "\\1—\\2"), -- en dash errors in WP abstracts: usually meant em-dash. eg 'disc format – <a href="https://en.wikipedia.org/wiki/Universal_Media_Disc">Universal'
  ("([[:punct:]]) – ([a-zA-Z])", "\\1—\\2"),
  ("([a-zA-Z]) – ([a-zA-Z])", "\\1—\\2"), -- eg: "Aspects of General Intelligence – a Deep Phenotyping Approach"
  ("([a-zA-Z]) - ([a-zA-Z])", "\\1—\\2"), -- spaced hyphens: also usually em dashes: "Towards personalized human AI interaction - adapting the behavior of AI agents"
  ("([.0-9]+)x", "\\1×"),
  ("([.0-9]+)X", "\\1×"),
  ("=-\\.([.0-9]+)", " = -0.\\1"),
  (" ([0-9]*[02456789])th", " \\1<sup>th</sup>"),
  (" ([0-9]*[1])st",        " \\1<sup>st</sup>"),
  (" ([0-9]*[3])rd",        " \\1<sup>rd</sup>"),
  (" \\(JEL [A-Z][0-9][0-9], .* [A-Z][0-9][0-9]\\)", ""), -- rm AERA classification tags they stick into the Crossref abstracts
  -- math regexes
  ("\\$([.0-9]+) \\\\cdot ([.0-9]+)\\^([.0-9]+)\\$",             "\\1 × \\2^\\3^"),
  ("\\$([.0-9]+) \\\\cdot ([.0-9]+)\\^\\{([.0-9]+)\\}\\$",       "\\1 × \\2^\\3^"),
  ("<span class=\"math inline\">\\\\\\(([0-9.]+)\\\\times\\\\\\)</span>", "\\1×"), -- '<span class="math inline">\(1.5\times\)</span>'
  ("<span class=\"math inline\">\\\\\\(\\\\times\\\\\\)</span>", "×"), -- '<span class="math inline">\(\times\)</span>'
  ("<span class=\"math inline\">\\\\\\(([0-9]*)\\^([0-9{}]*)\\\\\\)</span>", "\\1<sup>\\2</sup>") -- '<span class="math inline">\(10^4\)</span>'
  ] $
  -- simple string substitutions:
  replaceMany [
    ("<span style=\"font-weight:normal\"> </span>", "")
    , ("<span style=\"display:inline-block;vertical-align:-0.4em;font-size:80%;text-align:left\"><sup></sup><br /><sub>", "")
    , ("<sup></sup>", "")
    , ("<sub></sub>", "")
    -- math substitutions:
    , ("<span class=\"texhtml \">O(log <i>n</i>)</span>", "𝒪(log <em>n</em>)")
    , ("<span class=\"texhtml \">\\mathcal{O}(log <i>n</i>)</span>", "𝒪(log <em>n</em>)")
    , ("$O(log n)$", "𝒪(log <em>n</em>)")
    , ("$\\mathcal{O}(log n)$", "𝒪(log <em>n</em>)")
    , ("$\\mathrm{sinc}(ax)$", "sinc(<em>ax</em>)")
    , ("<span class=\"texhtml \">\\mathrm{sinc}(ax)</span>", "sinc(<em>ax</em>)")
    , ("$\\mathrm{sinc}(x)=\\sin(x)/x$", "sinc(<em>x</em>) = sin(<em>x</em>)⁄<em>x</em>")
    , ("$x$", "<em>x</em>")
    , ("$\\mathrm{sinc}(0)=1$", "sinc(0) = 1")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">n</span>", "<em>n</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">x</span>", "<em>x</em>")
    , ("<span><span class=\"texhtml mvar\" style=\"font-style:italic\">π</span></span>", "<em>π</em>")
    , ("<span class=\"texhtml \"><i>a</i> + <i>b i</i></span>", "<em>a</em> + <em>b i</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">a</span>", "<em>a</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">b</span>", "<em>b</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">i</span>", "<em>i</em>")
    , ("<span class=\"texhtml \">ℂ</span>", "ℂ")
    , ("<span class=\"texhtml \"><strong>C</strong></span>", "<strong>C</strong>")
    , ("<span class=\"texhtml \"><i>x</i><sup>2</sup> + 1 = 0</span>", "<em>x</em><sup>2</sup> + 1 = 0")
    , ("<span class=\"texhtml \">2 + 3<i>i</i></span>", "2 + 3<em>i</em>")
    , ("<span class=\"texhtml \"><i>Y</i> = ln(<i>X</i>)</span>", "<em>Y</em> = ln(<em>X</em>)")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">Y</span>", "<em>Y</em>")
    , ("<span class=\"texhtml \"><i>X</i> = exp(<i>Y</i>)</span>", "<em>X</em> = exp(<em>Y</em>)")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">p</span>", "<em>p</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">n</span>", "<em>n</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">π</span>", "<em>π</em>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\"><strong>c</strong></span>", "<strong><em>c</em></strong>")
    , ("<span class=\"texhtml \"><strong>C</strong></span>", "<strong>C</strong>")
    , ("<span class=\"texhtml mvar\" style=\"font-style:italic\">c</span>", "<em>c</em>")
    , ("<span class=\"math inline\">\\(\\times\\)</span>", "×")
    , ("<span class=\"math inline\">\\(n\\)</span>", "<em>n</em>")
    , ("<span class=\"math inline\">\\(\\pi\\)</span>", "π")
    , ("<span class=\"math inline\">\\(1,...,n\\)</span>", "1,...,<em>n</em>")
    , ("<span class=\"math inline\">\\(\\pi^*\\)</span>", "π<sup>*</sup>")
    , ("<span class=\"math inline\">\\(c\\)</span>", "<em>c</em>")
    , ("<span class=\"math inline\">\\(G\\)</span>", "<em>G</em>")
    , ("<span class=\"math inline\">\\(\\hbar\\)</span>", "ℏ")
    , ("<span class=\"math inline\">\\(n\\)</span>", "<em>n</em>")
    , ("<span class=\"math inline\">\\(n^{-1/2}\\)</span>", "<em>n</em><sup>−1⁄2</sup>")
    , ("<span class=\"math inline\">\\(n^{-1}\\)</span>", "<em>n</em><sup>−1</sup>")
    , ("<span class=\"math inline\">\\(n^{-\beta}\\)</span>", "<em>n<sup>−β</sup></em>")
    , ("<span class=\"math inline\">\\(\\beta&gt;0\\)</span>", "<em>β</em> > 0")
    , ("<span class=\"math inline\">\\(1,\\!000\\times\\)</span>", "1,000×")
    , ("<span class=\"math inline\">\\(3,\\!000\\times\\)</span>", "3,000×")
    , ("<span class=\"math inline\">\\(100,\\!000\\)</span>", "100,000")
    , ("<math>A</math>", "<em>A</em>")
    , ("<math>B</math>", "<em>B</em>")
    , ("<math>C</math>", "<em>C</em>")
    , ("<math>S</math>", "<em>S</em>")
    , (" O(sqrt(n)) ", " 𝑂(√<em>n</em>) ")
    , ("O(log n) ", "𝑂(log <em>n</em>) ")
    , (" O(log n)", " 𝑂(log <em>n</em>)")
    , (" O(n log n) ", " 𝑂(<em>n</em> log <em>n</em>) ")
    , ("<span class=\"math inline\">\\(O(K^2 \\log T)\\)</span>", "𝑂(<em>K</em><sup>2</sup> log <em>T</em>)")
    , ("<span class=\"math inline\">\\(O(K \\log T + K^2 \\log \\log T)\\)</span>", "𝑂(<em>K</em> log <em>T</em> + <em>K</em><sup>2</sup> log log <em>T</em>)")
    , ("<span class=\"math inline\">\\(Q\\)</span>", "<em>Q</em>")
    , ("<span class=\"math inline\">\\(\\epsilon\\)</span>", "ε")
    , ("<span class=\"math inline\">\\(\\rightarrow\\)</span>", "→")
    , ("<span class=\"math inline\">\\(\\leftarrow\\)</span>", "←")
    , ("<span class=\"math inline\">\\(D\\)</span>", "<em>D</em>")
    , ("<span class=\"math inline\">\\(G\\)</span>", "<em>G</em>")
    , ("<span class=\"math inline\">\\(K\\)</span>", "<em>K</em>")
    , ("<span class=\"math inline\">\\(\\sin\\Theta\\)</span>", "sinΘ")
    , ("<span class=\"math inline\">\\(\\ell_2\\)</span>", "𝓁<sub>2</sub>")
    , ("<span class=\"math inline\">\\(l_1\\)</span>", "𝓁<sub>1</sub>")
    , ("<span class=\"math inline\">\\(2.4\\)</span>", "2.4")
    , ("<span class=\"math inline\">\\(47.1\\)</span>", "47.1")
    , ("<span class=\"math inline\">\\(42.5\\)</span>", "42.5")
    , ("<span class=\"math inline\">\\(f(x) = x \\cdot \\text{sigmoid}(\\beta x)\\)</span>", "<em>f(x)</em> = <em>x</em> × sigmoid(β <em>x</em>)")
    , ("<span class=\"math inline\">\\(<em>r</em> = 0.99\\)</span>", "<em>r</em> = 0.99")
    , ("<span class=\"math inline\">\\(0.96\\)</span>", "0.96")
    , ("<span class=\"math inline\">\\(\\it<br/>performance\\)</span>", "<em>performance</em>")
    , ("<span class=\"math inline\">\\(\\it and\\)</span>", "<span class=\"math inline\">\\(\\it also\\)</span> <em>and also</em>")
    , ("<span class=\"math inline\">\\(\\sim\\)</span>", "~")
    , ("<span class=\"math inline\">\\(\\sim 10^3\\)</span>", "~10<sup>3</sup>")
    , ("<span class=\"math inline\">\\(5\\%-35\\%\\)</span>", "5%–35%")
    , ("<span class=\"math inline\">\\(124/144\\)</span>", "124⁄144")
    , ("<span class=\"math inline\">\\(86\\%\\)</span>", "86%")
    , ("<span class=\"math inline\">\\(9.3\\%\\)</span>", "9.3%")
    , ("<span class=\"math inline\">\\(4.5\\%\\)</span>", "4.5%")
    , ("<span class=\"math inline\">\\(\\textit{Magic: The Gathering}\\)</span>", "<em>Magic: The Gathering</em>")
    , ("<span class=\"math inline\">\\(\\textit{Magic}\\)</span>", "<em>Magic</em>")
    , ("<span class=\"math inline\">\\(O(n \\sqrt{n})\\)</span>", "𝑂(<em>n</em> √<em>n</em>)")
    , ("<span class=\"math inline\">\\(\\textit{Embedded agents}\\)</span>", "<em>Embedded agents</em>")
    , ("<span class=\"math inline\">\\(\\textit{wirehead}\\)</span>", "<em>wirehead</em>")
    , ("<span class=\"math inline\">\\(L\\)</span>", "<em>L</em>")
    , ("<span class=\"math inline\">\\(O(L(\\log L)^{2})\\)</span>", "𝑂(<em>L</em>(log <em>L</em>)<sup>2</sup>)")
    , ("<span class=\"math inline\">\\(_{16}\\)</span>", "<sub>16</sub>")
    , ("<span class=\"math inline\">\\(&gt;\\)</span>", "&gt;")
    , ("<span class=\"math inline\">\\(O(k\\cdot n\\log (n/k))\\)</span>", " 𝑂(<em>k</em> × log(<em>n</em>⁄<em>k</em>))")
    , ("O(<span class=\"math inline\">\\(L^2\\)</span>", "𝑂(<em>L</em><sup>2</sup>)")
    , ("<span class=\"math inline\">\\(L\\)</span>", "<em>L</em>")
    , ("<span class=\"math inline\">\\(N\\)</span>", "<em>N</em>")
    , ("O(<span class=\"math inline\">\\(L\\log L\\)</span>", "𝑂(<em>L</em> log <em>L</em>)")
    , ("<span class=\"math inline\">\\(\\Delta^0_n\\)</span>", "Δ<span class=\"supsub\"><sup>0</sup><sub><em>n</em></sub></span>")
    , ("O(N) ", "𝑂(<em>N</em>) ")
    , (" O(N)", " 𝑂(<em>N</em>)")
    , (" N pixels", " <em>N</em> pixels")
    , ("a n layer", "a <em>n</em> layer")
    , ("$f(x; x_0,\\gamma)$", "<em>f(x; x<sub>0</sub>,γ")
    , ("$(x_0,\\gamma)$", "<em>(x<sub>0</sub>, γ)</em>")
    , ("$e=mc^2$", "<em>e</em> = <em>mc</em><sup>2</sup>")
    , ("$\frac{4}{3} \\cdot \\pi \\cdot r^3$", "4⁄3 × π × _r_^3^")
    -- rest:
    , (" </sec>", "")
    , ("<title>", "")
    , ("</title>", "")
    , ("   <title/>    <p>", "<p>")
    , ("  <p>", "<p>")
    , (" h2",     " <em>h</em><sup>2</sup>")
    , ("h(2)",    "<em>h</em><sup>2</sup>")
    , ("</h2>", "</strong></p>")
    , ("<h2>", "<p><strong>")
    , ("</h3>", "</strong></p>")
    , ("<h3>", "<p><strong>")
    , ("<br/><h3>", "<h3>")
    , ("</p><p>", "</p> <p>")
    , ("<jats:title>SUMMARY</jats:title>", "")
    , ("<strong>ABSTRACT</strong><br/>              <p>", "<p>")
    , ("</strong><p>", "</strong>: <p>")
    , ("<strong>Abstract</strong>:        ", "")
    , ("<abstract abstract-type=\"summary\"><br/>", "")
    , ("<abstract abstract-type=\"toc\">", "")
    , ("<abstract abstract-type=\"editor\">", "")
    , ("<abstract abstract-type=\"synopsis\">", "")
    , ("<strong>SUMMARY</jats:title>", "")
    , ("<strong>Abstract</jats:title>", "")
    , ("<strong>Abstract</strong><br/>", "")
    , ("<h3>Abstract:</h3>", "")
    , ("<h3>Summary/Abstract</h3>", "")
    , ("Alzheimer9", "Alzheimer'")
    , ("<br/> <br/>", "</br>")
    , ("1.<p>", "<p>")
    , ("<list list-type=\"bullet\">", "<ul>")
    , ("</list>", "</ul>")
    , ("</list-item>", "</li>")
    , ("<list-item>", "<li>")
    , ("<p> ", "<p>")
    , (" <p>", "<p>")
    , ("</p> ", "</p>")
    , (" </p>", "</p>")
    , ("</p><br/>", "</p>")
    , ("</p> <br/>", "</p>")
    , ("<p><br/>", "<p>")
    , ("<p><br />", "<p>")
    , ("</li><br/>", "</li>")
    , ("  </sec><br/>  ", "")
    , ("<sec><br/>    ", "")
    , ("</jats:sec>", "")
    , ("<jats:sec><br/>", "")
    , ("</jats:sec><br/>", "")
    , ("  </sec> <br/>", "")
    , ("<sec id=\"sec001\">  ", "")
    , ("<sec id=\"sec002\">  ", "")
    , ("<sec id=\"sec003\">  ", "")
    , ("<sec id=\"sec004\">  ", "")
    , ("<sec id=\"sec005\">  ", "")
    , ("<sec id=\"sec006\">  ", "")
    , ("<sec id=\"sec007\">  ", "")
    , ("<sec id=\"sec008\">  ", "")
    , ("<sec id=\"sec009\">  ", "")
    , ("<sec id=\"sec010\">  ", "")
    , ("<sec id=\"sec001\">  ", "")
    , ("<sec id=\"sec002\">  ", "")
    , ("<sec id=\"sec003\">  ", "")
    , ("<sec id=\"sec004\">  ", "")
    , ("<sec id=\"sec005\">  ", "")
    , ("<sec id=\"sec006\">  ", "")
    , ("<sec id=\"sec007\">  ", "")
    , ("<sec id=\"sec008\">  ", "")
    , ("<sec id=\"sec009\">  ", "")
    , ("<sec id=\"sec010\">  ", "")
    , ("<sec id=\"english\">  ", "")
    , ("<sec id=\"st1\">", "")
    , ("<sec id=\"st2\">", "")
    , ("<sec id=\"st3\">", "")
    , ("<sec id=\"sb1a\">", "")
    , ("<sec id=\"sb1b\">", "")
    , ("<sec id=\"sb1c\">", "")
    , ("<sec id=\"sb1d\">", "")
    , ("<sec id=\"sb1e\">", "")
    , ("<sec sec-type=\"headed\">", "")
    , ("<p><sec sec-type=\"headed\"></p>", "")
    , ("</strong></p>    <p>", "</strong> ")
    , ("</title>", ":</strong></p>")
    , ("<title/>", "")
    , ("<title>", "<p><strong>")
    , ("</title><br/>", "</title>")
    , ("<p>\n\n", "<p>")
    , ("<br></p>", "</p>")
    , ("\n<br />\n", "")
    , ("<br/><p>", "<p>")
    , ("\n", "<br/>")
    , (" -- ", "&mdash;")
    , ("---", "&mdash;")
    , (" - ", "—")
    , (" — ", "—")
    , ("was significantly diminished", "was statistically-significantly diminished")
    , ("decreased significantly", "decreased statistically-significantly")
    , ("is significantly better than", "is statistically-significantly better than")
    , (" significant increase", " statistically-significant increase")
    , (" significantly less", " statistically-significantly less")
    , (" significantly more", " statistically-significantly more")
    , ("boundary of significance", "boundary of statistical-significance")
    , ("robustly significant", "robustly statistically-significant")
    , (" significant trend", " statistically-significant trend")
    , (" non-significant trend", " non-statistically-significant trend")
    , (" significant difference", " statistically-significant difference")
    , (" significant genetic correlation", " statistically-significant genetic correlation")
    , (" significant allele-phenotype associations", " statistically-significant allele-phenotype associations")
    , (" significant association", " statistically-significant association")
    , (" significant correlation", " statistically-significant correlation")
    , ("the significant SNPs", "the statistically-significant SNPs")
    , (" significantly associated", " statistically-significantly associated")
    , (" significantly correlated", " statistically-significantly correlated")
    , (" significantly higher (", " statistically-significantly higher (")
    , (" significant interaction effect", "  statistically-significant interaction effect")
    , (" significant effect", " statistically-significant effect")
    , (" significance testing", " statistical-significance testing")
    , ("nominally significant", "nominally statistically-significant")
    , (" nonsignificant result", " nonsignificant result")
    , (" significant excess", " statistically-significant excess")
    , (" significantly enriched", " statistically-significantly enriched")
    , ("levels of significance", "levels of significance")
    , (" significant at the ", " statistically-significant at the ")
    , ("statistical significance", "statistical-significance")
    , ("statistically significant", "statistically-significant")
    , ("genome-wide significance", "genome-wide statistical-significance")
    , ("genome-wide significant", "genome-wide statistically-significant")
    , ("statistical significance", "statistical-significance")
    , ("statistically significant", "statistically-significant")
    , ("clinical significance", "clinical-significance")
    , ("clinically significant", "clinically-significant")
    , ("<p>Background: ", "<p><strong>Background</strong>: ")
    , ("<p>Methods: ", "<p><strong>Methods</strong>: ")
    , ("<p>Outcomes: ", "<p><strong>Outcomes</strong>: ")
    , ("<p>Interpretation: ", "<p><strong>Interpretation</strong>: ")
    , ("<p>Funding: ", "<p><strong>Funding</strong>: ")
    , ("<em>N</em> =", "<em>n</em> =")
    , (" =  ", " = ")
    , ("<strong><strong>", "<strong>")
    , ("</strong></strong>", "</strong>")
    , ("< /b>", "</strong>")
    , ("<b>", "<strong>")
    , ("</b>", "</strong>")
    , ("<jats:sec><strong>", "<strong>")
    , ("<jats:title>Abstract</jats:title><br/>               ", "")
    , ("</jats:p>", "</p>")
    , ("< sub>", "<sub>")
    , ("<jats:sub>", "<sub>")
    , ("</jats:sub>", "</sub>")
    , ("<jats:sup>", "<sup>")
    , ("</jats:sup>", "</sup>")
    , ("<jats:title content-type=\"abstract-subheading\">", "<strong>")
    , ("<jats:title>", "<strong>")
    , ("</jats:title>", "</strong>")
    , ("<jats:title>", "<strong>")
    , ("</jats:title>", "</strong>")
    , ("<jats:p xml:lang=\"en\">", "<p>")
    , ("<jats:p>", "<p>")
    , (" <i> </i>", " ") -- Wikipedia {{ety}} weirdness, but just in Ancient Greek instances?
    , ("<jats:italics>", "<em>")
    , ("</jats:italics>", "</em>")
    , ("<jats:italic>", "<em>")
    , ("</jats:italic>", "</em>")
    , ("<italic>", "<em>")
    , ("</ italic>", "</em>")
    , ("< /italic>", "</em>")
    , ("</italic>", "</em>")
    , ("< /i>", "</i>")
    , ("<jats:title>Abstract</jats:title>\n\t  <jats:p>", "<p>")
    , ("<h3>ABSTRACT</h3>", "")
    , ("<h3>Abstract</h3>", "")
    , ("<h3>SUMMARY</h3>", "")
    , ("<h3>Summary</h3>", "")
    , ("<abstract>", "")
    , ("<abstract>\n  ", "")
    , ("\n</abstract>", "")
    , ("<p><strong>Abstract</strong>: ", "<p>")
    , ("\nHighlights: ", "\n<strong>Highlights</strong>: ")
    , ("\nBackground: ", "\n<strong>Background</strong>: ")
    , ("\nAbstract: ", "\n<strong>Abstract</strong>: ")
    , ("\nContext: ", "\n<strong>Context</strong>: ")
    , ("\nPurpose: ", "\n<strong>Purpose</strong>: ")
    , ("\nRationale: ", "\n<strong>Rationale</strong>: ")
    , ("\nObjective: ", "\n<strong>Objective</strong>: ")
    , ("\nObjectives: ", "\n<strong>Objectives</strong>: ")
    , ("\nQuestion: ", "\n<strong>Question</strong>: ")
    , ("\nDescription: ", "\n<strong>Description</strong>: ")
    , ("\nDesign: ", "\n<strong>Design</strong>: ")
    , ("\nMethods: ", "\n<strong>Methods</strong>: ")
    , ("\nSetting: ", "\n<strong>Setting</strong>: ")
    , ("\nParticipants: ", "\n<strong>Participants</strong>: ")
    , ("\nMeaning: ", "\n<strong>Meaning</strong>: ")
    , ("\nDesign, Setting, and Participants: ", "\n<strong>Design, Setting, & Participants</strong>: ")
    , ("\nIntervention: ", "\n<strong>Intervention</strong>: ")
    , ("\nData Sources: ", "\n<strong>Data Sources</strong>: ")
    , ("\nMain Outcomes & Measures: ", "\n<strong>Main Outcomes and Measures</strong>: ")
    , ("\nMeasurements: ", "\n<strong>Measurements</strong>: ")
    , ("\nResults: ", "\n<strong>Results</strong>: ")
    , ("\nSignificance: ", "\n<strong>Significance</strong>: ")
    , ("\nConclusion: ", "\n<strong>Conclusion</strong>: ")
    , ("\nConclusions: ", "\n<strong>Conclusion</strong>: ")
    , ("\nConclusions & Relevance: ", "\n<strong>Conclusions and Relevance</strong>: ")
    , ("\nTrial Registration: ", "\n<strong>Trial Registration</strong>: ")
    , ("<h3>Highlights</h3>\n<p>", "<p><strong>Highlights</strong>: ")
    , ("<h3>Background</h3>\n<p>", "<p><strong>Background</strong>: ")
    , ("<h3>Abstract</h3>\n<p>", "<p><strong>Abstract</strong>: ")
    , ("<h3>Context</h3>\n<p>", "<p><strong>Context</strong>: ")
    , ("<h3>Purpose</h3>\n<p>", "<p><strong>Purpose</strong>: ")
    , ("<h3>Rationale</h3>\n<p>", "<p><strong>Rationale</strong>: ")
    , ("<h3>Objective</h3>\n<p>", "<p><strong>Objective</strong>: ")
    , ("<h3>Objectives</h3>\n<p>", "<p><strong>Objectives</strong>: ")
    , ("<h3>Question</h3>\n<p>", "<p><strong>Question</strong>: ")
    , ("<h3>Description</h3>\n<p>", "<p><strong>Description</strong>: ")
    , ("<h3>Design</h3>\n<p>", "<p><strong>Design</strong>: ")
    , ("<h3>Methods</h3>\n<p>", "<p><strong>Methods</strong>: ")
    , ("<h3>Setting</h3>\n<p>", "<p><strong>Setting</strong>: ")
    , ("<h3>Participants</h3>\n<p>", "<p><strong>Participants</strong>: ")
    , ("<h3>Meaning</h3>\n<p>", "<p><strong>Meaning</strong>: ")
    , ("<h3>Design, Setting, and Participants</h3>\n<p>", "<p><strong>Design, Setting, & Participants</strong>: ")
    , ("<h3>Intervention</h3>\n<p>", "<p><strong>Intervention</strong>: ")
    , ("<h3>Data Sources</h3>\n<p>", "<p><strong>Data Sources</strong>: ")
    , ("<h3>Main Outcomes & Measures</h3>\n<p>", "<p><strong>Main Outcomes and Measures</strong>: ")
    , ("<h3>Measurements</h3>\n<p>", "<p><strong>Measurements</strong>: ")
    , ("<h3>Results</h3>\n<p>", "<p><strong>Results</strong>: ")
    , ("<h3>Significance</h3>\n<p>", "<p><strong>Significance</strong>: ")
    , ("<h3>Conclusion</h3>\n<p>", "<p><strong>Conclusion</strong>: ")
    , ("<h3>Conclusions</h3>\n<p>", "<p><strong>Conclusion</strong>: ")
    , ("<h3>Conclusions & Relevance</h3>\n<p>", "<p><strong>Conclusions and Relevance</strong>: ")
    , ("<h3>Trial Registration</h3>\n<p>", "<p><strong>Trial Registration</strong>: ")
    , ("</h3><br/>", "</h3>")
    , ("<br/><h3>", "<h3>")
    , ("\91Keywords: ", "<strong>\91Keywords</strong>: ")
    , (" (4/8 ", " (4⁄8 ")
    , (" (4/8 ", " (4⁄8 ")
    , (" (5/8 ", " (5⁄8 ")
    , (" (5/8 ", " (5⁄8 ")
    , (" (5/8 ", " (5⁄8 ")
    , (" 1/2 ", " 1⁄2 ")
    , (" 1/4 ", " 1⁄4 ")
    , (" 2/3 ", " 2⁄3 ")
    , (" 4/5 ", " 4⁄5 ")
    , (" 5/8 ", " 5⁄8 ")
    , (" 5/9 ", " 5⁄9 ")
    , (" 6/13 ", " 6⁄13 ")
    , (" 7/13 ", " 7⁄13 ")
    , (" 8/13 ", " 8⁄13 ")
    , (" 9/13 ", " 9⁄13 ")
    , (" 15/16 ", " 15⁄16 ")
    , (" 5/16 ", " 5⁄16 ")
    , (" 5/8 ", " 5⁄8 ")
    , (" 15/20 ", " 15⁄20 ")
    , (" (23/96) ", " (23⁄96) ")
    , (" (24/50) ", " (24⁄50) ")
    , (" (30/96) ", " (30⁄96) ")
    , (" (35/96) ", " (35⁄96) ")
    , (" (39/50) ", " (39⁄50) ")
    , (" (41/50) ", " (41⁄50) ")
    , (" (43/50) ", " (43⁄50) ")
    , (" (48/96) ", " (48⁄96) ")
    , (" (50/96) ", " (50⁄96) ")
    , (" (6/96), ", " (6⁄96), ")
    , (" (68/96) ", " (68⁄96) ")
    , (" (90/96) ", " (90⁄96) ")
    , (" 11/90 ", " 11⁄90 ")
    , (" 33/96 ", " 33⁄96 ")
    , (" 42/50 ", " 42⁄50 ")
    , ("(11/31)", "(11⁄31)")
    , ("(9/11)", "(9⁄11)")
    , ("(2/7)", "(2⁄7)")
    , ("(28/31)", "(28⁄31)")
    , ("(9/10)", "(9⁄10)")
    , ("10(-10)", "10<sup>−10</sup>")
    , ("10(-11)", "10<sup>−11</sup>")
    , ("10(-13)", "10<sup>−13</sup>")
    , ("10(-15)", "10<sup>−15</sup>")
    , ("10(-19)", "10<sup>−19</sup>")
    , ("10(-26)", "10<sup>−26</sup>")
    , ("10(-3)", "10<sup>−3</sup>")
    , ("10(-4)", "10<sup>−4</sup>")
    , ("10(-5)", "10<sup>−5</sup>")
    , ("10(-6)", "10<sup>−6</sup>")
    , ("10(-7)", "10<sup>−7</sup>")
    , ("10(-8)", "10<sup>−8</sup>")
    , ("10(-9)", "10<sup>−9</sup>")
    , ("10(-)(3)", "10<sup>−3</sup>")
    , ("10(-)(4)", "10<sup>−4</sup>")
    , ("10(-)(5)", "10<sup>−5</sup>")
    , ("10(-)(6)", "10<sup>−6</sup>")
    , ("10(-)(7)", "10<sup>−7</sup>")
    , ("10(-)(8)", "10<sup>−8</sup>")
    , ("10(-)(9)", "10<sup>−9</sup>")
    , ("10(-)(10)", "10<sup>−10</sup>")
    , ("R (2) ", "R<sup>2</sup> ")
    , ("CO(2)", "CO<sub>2</sub>")
    , (" = .",    " = 0.")
    , (" gf ", " <em>gf</em> ")
    , (" gc ", " <em>gc</em> ")
    , ("<i><em>h</em><sup>2</sup></i>", "<em>h</em><sup>2</sup>")
    , ("<i><em>h</em><sup>2</sup><sub>SNP</sub></i>", "<em>h</em><sup>2</sup><sub>SNP</sub>")
    , ("h<sup>2</sup>", "<em>h</em><sup>2</sup>")
    , ("<em>r</em> <sub>g</sub>", "<em>r</em><sub>g</sub>")
    , ("r(g)",    "<em>r</em><sub><em>g</em></sub>")
    , (" rg ", " <em>r</em><sub><em>g</em></sub> ")
    , (" rg=", " <em>r</em><sub><em>g</em></sub> = ")
    , (" rg = ", " <em>r</em><sub><em>g</em></sub> = ")
    , ("(rg)", "(<em>r</em><sub><em>g</em></sub>)")
    , ("-&gt;", "→")
    , (" r=", "<em>r</em> = ")
    , (" r>", "<em>r</em> > ")
    , (" r<", " <em>r</em> < ")
    , ("r≥", "<em>r</em> ≥ ")
    , ("r≤", "<em>r</em> ≤ ")
    , ("<var>", "<em>")
    , ("</var>", "</em>")
    , ("<code class=\"mw-highlight mw-highlight-lang-text mw-content-ltr\" dir=\"ltr\"", "<code")
    , ("<wbr />", "")
    , ("<wbr/>", "")
    , ("<wbr>", "")
    , ("<wbr />&#8203;", "")
    , ("<wbr></wbr>", "")
    , ("<wbr></wbr>\8203", "")
    , ("<abbr>", "<span>")
    , ("</abbr>", "</span>")
    , ("<ext-link ext-link-type=\"uri\"", "<a")
    , ("<ext-link ext-link-type=\"uri\" xlink:href=", "<a href=")
    , ("xlink:type=\"simple\"", "")
    , ("</ext-link>", "</a>")
    , ("beta=", "β = ")
    , ("≤p≤",     " ≤ <em>p</em> ≤ ")
    , ("\40r=",     "\40<em>r</em> = ")
    , ("\40R=",     "\40<em>r</em> = ")
    , ("\40R = ",   "\40<em>r</em> = ")
    , ("\40r = ",   "\40<em>r</em> = ")
    , ("\40N = ",   "\40<em>N</em> = ")
    , ("\40n = ",   "\40<em>n</em> = ")
    , ("\40n=",     "\40<em>n</em> = ")
    , ("\40N=",     "\40<em>N</em> = ")
    , ("(r&gt;", "9<em>r</em> &gt; ")
    , (" N ~ ",     " <em>n</em> ~ ")
    , ("( N = ", "(<em>n</em> = ")
    , ("( n = ", "(<em>n</em> = ")
    , ("( ns = ", "(<em>ns</em> = ")
    , ("( n = ", "(<em>n</em> = ")
    , ("n = ", "<em>n</em> = ")
    , ("(p = ", "(<em>p</em> = ")
    , (" p&lt;", " <em>p</em> < ")
    , (" p&gt;", " <em>p</em> > ")
    , (" p&gte;", " <em>p</em> ≥ ")
    , (" p&lte;", " <em>p</em> ≤ ")
    , (" P&lt;", " <em>p</em> < ")
    , (" P&gt;", " <em>p</em> > ")
    , (" P&gte;", " <em>p</em> ≥ ")
    , (" P&lte;", " <em>p</em> ≤ ")
    , ("<em>p</em> = .", "<em>p</em> = 0.")
    , ("<em>p</em> < .", "<em>p</em> < 0.")
    , (" N=",     " <em>N</em> = ")
    , ("\40p=",     "\40<em>p</em> = ")
    , (" n=",     " <em>n</em> = ")
    , (" p&lt;", " <em>p</em> &lt; ")
    , ("p = 0",   "<em>p</em> = 0")
    , (" P=",     " <em>p</em> = ")
    , (" P = ",   " <em>p</em> = ")
    , ("(P = ",   "(<em>p</em> = ")
    , ("(P=",     "(<em>p</em> = ")
    , (" p = ",   " <em>p</em> = ")
    , (" p=",     " <em>p</em> = ")
    , (" P<",     " <em>p</em> < ")
    , ("P ≤ ", "<em>p</em> ≤ ")
    , ("\40P<",     "\40<em>p</em> < ")
    , (" P < ",   " <em>p</em> < ")
    , (" p < ",   " <em>p</em> < ")
    , (" p<",     " <em>p</em> < ")
    , (" p<.",    " <em>p</em> < 0.")
    , ("(P < 0.", "(<em>p</em> < 0.")
    , ("(P < .", "(<em>p</em> < 0.")
    , ("\40P=",     "\40<em>p</em> = ")
    , ("P-value", "<em>p</em>-value")
    , ("p-value", "<em>p</em>-value")
    , (" ", " ")
    , ("∼", "~")
    , ("GxE", "G×E")
    , (" 10x", " 10×")
    , (" 100x", " 100×")
    , (" 2x", " 2×")
    , (" 3x", " 3×")
    , ("<p> ", "<p>")
    , ("+/-", "±")
    , ("<sup>~</sup>", "~")
    , (" 11th", " 11<sup>th</sup>")
    , (" 12th", " 12<sup>th</sup>")
    , (" 13th", " 13<sup>th</sup>")
    , (" 14th", " 14<sup>th</sup>")
    , (" 15th", " 15<sup>th</sup>")
    , (" 16th", " 16<sup>th</sup>")
    , (" 17th", " 17<sup>th</sup>")
    , (" 18th", " 18<sup>th</sup>")
    , (" 19th", " 19<sup>th</sup>")
    , (" 20th", " 20<sup>th</sup>")
    , (" 21st", " 21<sup>st</sup>")
    , ("\"21st", "\"21<sup>st</sup>")
    , ("early-12th", "early-12<sup>th</sup>")
    , ("mid-21st", "mid-21<sup>st</sup>")
    , ("early-20th-century", "early-20<sup>th</sup>-century")
    , ("<i>25th", "<i>25<sup>th</sup>")
    , (">15th", ">15<sup>th</sup>")
    , ("mid-17th", "mid-17<sup>th</sup>")
    , ("mid-16th", "mid-16<sup>th</sup>")
    , (">21st", ">21st")
    , ("–19th", "–19<sup>th</sup>")
    , ("late-20th", "late-20<sup>th</sup>")
    , ("64,000th", "64,000<sup>th</sup>")
    , ("(5th", "(5<sup>th</sup>")
    , ("(12th", "(12<sup>th</sup>")
    , ("<code class=\"mw-highlight mw-highlight-lang-bash mw-content-ltr\" dir=\"ltr\">", "<code>")
    , ("ml-1", "ml<sup>−1</sup>")
    , ("Cmax", "C<sub>max</sub>")
    , ("<small></small>", "")
    , (" et al ", " et al ") -- et al: try to ensure no linebreaking of citations
    , (" et al. ", " et al ")
    , ("Per- formance", "Performance")
    , ("per- formance", "performance")
    , ("one- or five-shot", "one-shot or five-shot")
    , ("lan- guage", "language")
    , ("pro-posed", "proposed")
    , ("\t\t", "")
    , ("\t\t\t\t\t", "")
    , ("\173", "") -- all web browsers now do hyphenation so strip soft-hyphens
      ] t
