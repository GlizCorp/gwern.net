{-# LANGUAGE OverloadedStrings #-}

-- Module for typographic enhancements of text:
-- 1. add link-live (cross-domain iframe popups) & link icon classes to links
-- 2. adding line-break tags (`<wbr>` as Unicode ZERO WIDTH SPACE) to slashes so web browsers break at slashes in text
-- 3. Adding classes to horizontal rulers (nth ruler modulo 3, allowing CSS to decorate it in a
--    cycling pattern, like `<div class="horizontalRule-nth-0"><hr></div>`/`class="horizontalRule-nth-1"`/`class="horizontalRule-nth-2"`/`class="horizontalRule-nth-0"`..., (the div wrapper is necessary because Pandoc's 'HorizontalRule' Block element supports no attributes)
--    like a repeating pattern of stars/moon/sun/stars/moon/sun... CSS can do this with :nth, but only
--    for immediate sub-children, it can't count elements *globally*, and since Pandoc nests horizontal
--    rulers and other block elements within each section, it is not possible to do the usual trick
--    like with blockquotes/lists).
module Typography (invertImage, invertImageInline, linebreakingTransform, typographyTransform, imageMagickDimensions, titlecase') where

import Control.Monad.State.Lazy (evalState, get, put, State)
import Control.Monad (void, when)
import Data.ByteString.Lazy.Char8 as B8 (unpack)
import Data.Char (toUpper)
import Data.List (isPrefixOf)
import Data.List.Utils (replace)
import Data.Time.Clock (diffUTCTime, getCurrentTime, nominalDay)
import System.Directory (doesFileExist, getModificationTime, removeFile)
import System.Exit (ExitCode(ExitFailure))
import System.Posix.Temp (mkstemp)
import qualified Data.Text as T (any, isSuffixOf, pack, unpack, replace, Text)
import Text.Read (readMaybe)
import qualified Text.Regex.Posix as R (makeRegex, match, Regex)
import Text.Regex (subRegex, mkRegex)
import System.IO (stderr, hPrint)
import System.IO.Temp (emptySystemTempFile)

import Data.Text.Titlecase (titlecase)

import Data.FileStore.Utils (runShellCommand)

import Text.Pandoc (Inline(..), Block(..), Pandoc, topDown, nullAttr)
import Text.Pandoc.Walk (walk, walkM)

import LinkIcon (linkIcon)
import LinkLive (linkLive)

import Utils (addClass, printRed)

typographyTransform :: Pandoc -> Pandoc
typographyTransform = walk (linkLive . linkIcon) .
                      linebreakingTransform .
                      rulersCycle 3

linebreakingTransform :: Pandoc -> Pandoc
linebreakingTransform = walk (breakSlashes . breakEquals)

-------------------------------------------

-- add '<wbr>'/ZERO WIDTH SPACE (https://developer.mozilla.org/en-US/docs/Web/HTML/Element/wbr) HTML element to inline uses of forward slashes, such as in lists, to tell Chrome to linebreak there (see https://www.gwern.net/Lorem#inline-formatting in Chrome for examples of how its linebreaking is incompetent, sadly).
--
-- WARNING: this will affect link texts like '[AC/DC](!W)', so make sure you do the rewrite after
-- the interwiki and any passes which insert inline HTML - right now 'breakSlashes' tests for
-- possible HTML and bails out to avoid damaging it.
breakSlashes :: Block -> Block
-- skip CodeBlock/RawBlock/Header/Table: enabling line-breaking on slashes there is a bad idea or not possible:
breakSlashes x@CodeBlock{} = x
breakSlashes x@RawBlock{}  = x
breakSlashes x@Header{}    = x
breakSlashes x@Table{}     = x
breakSlashes x = topDown breakSlashesInline x
breakSlashesInline, breakSlashesPlusHairSpaces :: Inline -> Inline
breakSlashesInline x@Code{}        = x
breakSlashesInline (Link a [Str ss] (t,"")) = if ss == t then
                                                -- if an autolink like '<https://example.com>' which
                                                -- converts to 'Link () [Str "https://example.com"]
                                                -- ("https://example.com","")' or '[Para [Link
                                                -- ("",["uri"],[]) [Str "https://www.example.com"]
                                                -- ("https://www.example.com","")]]' (NOTE: we
                                                -- cannot rely on there being a "uri" class), then
                                                -- we mark it up as Code and skip it:
                                                 addClass "uri" $ Link a [Code nullAttr ss] (t,"")
                                                else
                                                 Link a (walk breakSlashesPlusHairSpaces [Str ss]) (t,"")
breakSlashesInline (Link a ss ts) = Link a (walk breakSlashesPlusHairSpaces ss) ts
breakSlashesInline x@(Str s) = if T.any (\t -> t=='/' && not (t=='<' || t=='>' || t ==' ' || t == '\8203')) s then -- things get tricky if we mess around with raw HTML, so we bail out for anything that even *looks* like it might be HTML tags & has '<>' or a HAIR SPACE or ZERO WIDTH SPACE already
                                 Str (T.replace " /\8203 " " / " $ T.replace " /\8203" " /" $ T.replace "/\8203 " "/ " $ -- fix redundant \8203s to make HTML source nicer to read; 2 cleanup substitutions is easier than using a full regexp rewrite
                                                   T.replace "/" "/\8203" s) else x
breakSlashesInline x = x
-- the link-underlining hack, using drop-shadows, causes many problems with characters like slashes
-- 'eating' nearby characters; a phrase like "A/B testing" is not usually a problem because the
-- slash is properly kerned, but inside a link, the '/' will eat at 'B' and other characters where
-- the top-left comes close to the top of the slash. (NOTE: We may be able to drop this someday if
-- CSS support for underlining with skip-ink ever solidifies.)
--
-- The usual solution is to insert a HAIR SPACE or THIN SPACE. Here, we descend inside Link nodes to
-- their Str to add both <wbr> (line-breaking is still an issue AFAIK) and HAIR SPACE (THIN SPACE
-- proved to be too much).
breakSlashesPlusHairSpaces x@(Str s) = if T.any (\t -> t=='/' && not (t=='<' || t=='>' || t ==' ')) s then
                                 Str (T.replace " /\8203 " " / " $ T.replace " /\8203" " /" $ T.replace "/\8203 " "/ " $
                                                   T.replace "/" " / \8203" s) else x
breakSlashesPlusHairSpaces x = x

breakEquals :: Block -> Block
breakEquals x@CodeBlock{} = x
breakEquals x@RawBlock{}  = x
breakEquals x@Header{}    = x
breakEquals x@Table{}     = x
breakEquals x = walk breakEqualsInline x
breakEqualsInline :: Inline -> Inline
breakEqualsInline (Str s) = let s' = T.unpack s in Str $ T.pack $ subRegex equalsRegex s' " \\1 \\2"
breakEqualsInline x = x
equalsRegex :: R.Regex
equalsRegex = mkRegex "([=≠])([a-zA-Z0-9])"

-------------------------------------------

-- Look at mean color of image, 0-1: if it's close to 0, then it's a monochrome-ish white-heavy
-- image. Such images look better in HTML/CSS dark mode when inverted, so we can use this to check
-- every image for color, and set an 'invertible-auto' HTML class on the ones which are low. We can
-- manually specify a 'invertible' class on images which don't pass the heuristic but should.
invertImageInline :: Inline -> IO Inline
invertImageInline x@(Image (htmlid, classes, kvs) xs (p,t)) =
  if notInvertibleP classes then
    return x else do
                   (color,_,_) <- invertFile p
                   if not color then return x else
                     return (Image (htmlid, "invertible-auto":classes, kvs++[("loading","lazy")]) xs (p,t))
invertImageInline x@(Link (htmlid, classes, kvs) xs (p, t)) =
  if notInvertibleP classes || not (".png" `T.isSuffixOf` p || ".jpg" `T.isSuffixOf` p)  then
                                                          return x else
                                                            do (color,_,_) <- invertFile p
                                                               if not color then return x else
                                                                 return $ addClass "invertible-auto" $ Link (htmlid, classes, kvs) xs (p, t)
invertImageInline x = return x

invertFile :: T.Text -> IO (Bool, String, String)
invertFile p = do let p' = T.unpack p
                  let p'' = if head p' == '/' then tail p' else p'
                  invertImage p''

notInvertibleP :: [T.Text] -> Bool
notInvertibleP classes = "invertible-not" `elem` classes

invertImage :: FilePath -> IO (Bool, String, String) -- invertible / height / width
invertImage f | "https://www.gwern.net/" `isPrefixOf` f = invertImageLocal $ Data.List.Utils.replace "https://www.gwern.net/" "" f
              | "http" `isPrefixOf` f = do (temp,_) <- mkstemp "/tmp/image-invertible"
                                           -- NOTE: while wget preserves it, curl erases the original modification time reported by server in favor of local file creation; this is useful for `invertImagePreview` --- we want to check downloaded images manually before their annotation gets stored permanently.
                                           (status,_,_) <- runShellCommand "./" Nothing "curl" ["--location", "--silent", "--user-agent", "gwern+wikipediascraping@gwern.net", f, "--output", temp]
                                           case status of
                                             ExitFailure _ -> do hPrint stderr ("Download failed (unable to check image invertibility): " ++ f)
                                                                 removeFile temp
                                                                 return (False, "320", "320") -- NOTE: most WP thumbnails are 320/320px squares, so to be safe we'll use that as a default value
                                             _ -> do c <- imageMagickColor f temp
                                                     (h,w) <- imageMagickDimensions temp
                                                     let invertp = c < invertThreshold
                                                     when invertp $ invertImagePreview temp
                                                     removeFile temp
                                                     return (invertp, h, w)
              | otherwise = invertImageLocal f

invertImageLocal :: FilePath -> IO (Bool, String, String)
invertImageLocal "" = return (False, "0", "0")
invertImageLocal f = do does <- doesFileExist f
                        if not does then printRed ("invertImageLocal: " ++ f ++ " " ++ "does not exist") >> return (False, "0", "0") else
                          do c <- imageMagickColor f f
                             (h,w) <- imageMagickDimensions f
                             let invertp = c < invertThreshold
                             return (invertp, h, w)
invertThreshold :: Float
invertThreshold = 0.09

-- Manually check the inverted version of new images which trigger the inversion heuristic. I don't
-- want to store a database of image inversion status, so I'll use the cheaper heuristic of just
-- opening up every image modified <1 day ago (which should catch all of the WP thumbnails + any
-- images added).
invertImagePreview :: FilePath -> IO ()
invertImagePreview f = do utcFile <- getModificationTime f
                          utcNow  <- getCurrentTime
                          let age  = utcNow `diffUTCTime` utcFile
                          when (age < nominalDay) $ do
                            f' <- emptySystemTempFile "inverted"
                            void $ runShellCommand "./" Nothing "convert" ["-negate", f, f']
                            void $ runShellCommand "./" Nothing "firefox" [f']

imageMagickColor :: FilePath -> FilePath -> IO Float
imageMagickColor f f' = do (status,_,bs) <- runShellCommand "./" Nothing "convert" [f', "-colorspace", "HSL", "-channel", "g", "-separate", "+channel", "-format", "%[fx:mean]", "info:"]
                           case status of
                             ExitFailure err ->  printRed ("imageMagickColor: " ++ f ++ " : ImageMagick color read error: " ++ show err ++ " " ++ f') >> return 1.0
                             _ -> do let color = readMaybe (take 4 $ unpack bs) :: Maybe Float -- WARNING: for GIFs, ImageMagick returns the mean for each frame; 'take 4' should give us the first frame, more or less
                                     case color of
                                       Nothing -> printRed ("imageMagickColor: " ++ f ++ " : ImageMagick parsing error: " ++ show (unpack bs) ++ " " ++ f') >> return 1.0
                                       Just c -> return c

-- | Use FileStore utility to run imageMagick's 'identify', & extract the height/width dimensions
-- Note that for animated GIFs, 'identify' returns width/height for each frame of the GIF, which in
-- most cases will all be the same, so we take the first line of whatever dimensions 'identify' returns.
imageMagickDimensions :: FilePath -> IO (String,String)
imageMagickDimensions f =
  let f'
        | "/" `isPrefixOf` f && not ("/tmp" `isPrefixOf` f) = tail f
        | "https://www.gwern.net/" `isPrefixOf` f = drop 22 f
        | otherwise = f
  in
    do exists <- doesFileExist f'
       if not exists then return ("","") else
        do (status,_,bs) <- runShellCommand "./" Nothing "identify" ["-format", "%h %w\n", f']
           case status of
             ExitFailure exit -> error $ f ++ ":" ++ f' ++ ":" ++ show exit ++ ":" ++ B8.unpack bs
             _             -> do let [height, width] = words $ head $ lines $ B8.unpack bs
                                 return (height, width)

-------------------------------------------

-- Annotate body horizontal rulers with a class based on global count: '<div class="ruler-nth-0"> /
-- <hr /> / </div>' / '<div class="ruler-nth-1"> / <hr /> / </div>' / '<div class="ruler-nth-2"> /
-- <hr /> / </div>' etc (cycling). Allows CSS decoration of "every second ruler" or "every fourth
-- ruler" etc. I use it for cycling rulers in 3 levels, similar to the rest of Gwern.net's visual
-- design.
--
-- Generalized versions for arbitrary Inline/Block types using generic programming:
-- https://groups.google.com/g/pandoc-discuss/c/x1IXyfC2tfU/m/sXnHU7DIAgAJ (not currently necessary,
-- but worth noting should I need to number anything in the future).
---
-- (NOTE: As a rewrite pass, this does not affect the horizontal ruler in the endnotes section, nor
-- any horizontal rulers in the outer HTML document.)
rulersCycle :: Int -> Pandoc -> Pandoc
rulersCycle modulus doc = evalState (walkM addHrNth doc) 0
 where addHrNth :: Block -> State Int Block
       addHrNth HorizontalRule = do
         count <- get
         put (count + 1)
         let nth = count `mod` modulus
         let nthClass = T.pack $ "horizontalRule" ++ "-nth-" ++ show nth
         return $ Div ("", [nthClass], []) [HorizontalRule]
       addHrNth x = return x

-- rewrite a string (presumably an annotation title) into a mixed-case 'title case'
-- https://en.wikipedia.org/wiki/Title_case as we expect from headlines/titles
--
-- uses <https://hackage.haskell.org/package/titlecase>
--
-- TODO: This wrapper function exists to temporarily work around `titlecase`'s lack of hyphen
-- handling: <https://github.com/peti/titlecase/issues/5>. We crudely just uppercase every lowercase
-- letter after a hyphen, not bothering with skipping prepositions/conjunctions/particles/etc.
-- Hopefully titlecase will do better and we can remove this.
titlecase' :: String -> String
titlecase' "" = ""
titlecase' t = titlecase $ titlecase'' t
   where titlecase'' :: String -> String
         titlecase'' "" = ""
         titlecase'' t' = let (before,matched,after) = R.match (R.makeRegex ("-[a-z]"::String) :: R.Regex) t' :: (String,String,String)
                          in before ++ map toUpper matched ++ titlecase'' after
