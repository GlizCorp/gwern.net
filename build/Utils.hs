{-# LANGUAGE OverloadedStrings #-}
module Utils where

import Control.Monad (when)
import Data.Char (isSpace)
import Data.List (group, sort, isInfixOf, isPrefixOf, isSuffixOf)
import Data.List.Utils (replace)
import Data.Text.IO as TIO (readFile, writeFile)
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (getCurrentTime, utctDay)
import Network.URI (parseURIReference, uriAuthority, uriRegName)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeDirectory)
import System.IO (stderr, hPutStrLn)
import System.IO.Temp (emptySystemTempFile)
import System.IO.Unsafe (unsafePerformIO)
import Text.Show.Pretty (ppShow)
import qualified Data.Text as T (Text, pack, unpack, isInfixOf, isPrefixOf, isSuffixOf)

import Data.Array (elems)
import Text.Regex.TDFA ((=~), MatchArray)

import Text.Pandoc (def, nullMeta, runPure,
                    writerColumns, writePlain, Block, Pandoc(Pandoc), Inline(Code, Image, Link, Span, Str), Block(Para), readerExtensions, writerExtensions, readHtml, writeMarkdown, pandocExtensions)

-- Auto-update the current year.
{-# NOINLINE currentYear #-}
currentYear :: Int
currentYear = unsafePerformIO $ fmap ((\(year,_,_) -> fromInteger year) . toGregorian . utctDay) Data.Time.Clock.getCurrentTime

-- Write only when changed, to reduce sync overhead; creates parent directories as necessary; writes
-- to a temp file in /tmp/ (at a specified template name), and does an atomic rename to the final
-- file.
writeUpdatedFile :: String -> FilePath -> T.Text -> IO ()
writeUpdatedFile template target contentsNew =
  do existsOld <- doesFileExist target
     if not existsOld then do
       createDirectoryIfMissing True (takeDirectory target)
       TIO.writeFile target contentsNew
       else do contentsOld <- TIO.readFile target
               when (contentsNew /= contentsOld) $ do tempPath <- emptySystemTempFile ("hakyll-"++template)
                                                      TIO.writeFile tempPath contentsNew
                                                      renameFile tempPath target

trim :: String -> String
trim = reverse . dropWhile badChars . reverse . dropWhile badChars -- . filter (/='\n')
  where badChars c = isSpace c || (c=='-')

simplifiedString :: String -> String
simplifiedString s = trim $ -- NOTE: 'simplified' will return a trailing newline, which is unhelpful when rendering titles.
                     T.unpack $ simplified $ Para [Str $ T.pack s]

simplified :: Block -> T.Text
simplified i = simplifiedDoc (Pandoc nullMeta [i])

simplifiedDoc :: Pandoc -> T.Text
simplifiedDoc p = let md = runPure $ writePlain def{writerColumns=100000} p in -- NOTE: it is important to make columns ultra-wide to avoid formatting-newlines being inserted to break up lines mid-phrase, which would defeat matches in LinkAuto.hs.
                         case md of
                           Left _ -> error $ "Failed to render: " ++ show md
                           Right md' -> md'

toMarkdown :: String -> String
toMarkdown abst = let clean = runPure $ do
                                   pandoc <- readHtml def{readerExtensions=pandocExtensions} (T.pack abst)
                                   md <- writeMarkdown def{writerExtensions = pandocExtensions, writerColumns=100000} pandoc
                                   return $ T.unpack md
                             in case clean of
                                  Left e -> error $ ppShow e ++ ": " ++ abst
                                  Right output -> output


-- Add or remove a class to a Link or Span; this is a null op if the class is already present or it
-- is not a Link/Span.
addClass :: T.Text -> Inline -> Inline
addClass clss x@(Span  (i, clsses, ks) s)           = if clss `elem` clsses then x else Span (i, clss:clsses, ks) s
addClass clss x@(Link  (i, clsses, ks) s (url, tt)) = if clss `elem` clsses then x else Link (i, clss:clsses, ks) s (url, tt)
addClass clss x@(Image (i, clsses, ks) s (url, tt)) = if clss `elem` clsses then x else Image (i, clss:clsses, ks) s (url, tt)
addClass clss x@(Code  (i, clsses, ks) code)        = if clss `elem` clsses then x else Code (i, clss:clsses, ks) code
addClass _    x = x
removeClass :: T.Text -> Inline -> Inline
removeClass clss x@(Span (i, clsses, ks) s)            = if clss `notElem` clsses then x else Span (i, filter (/=clss) clsses, ks) s
removeClass clss x@(Link (i, clsses, ks) s (url, tt))  = if clss `notElem` clsses then x else Link (i, filter (/=clss) clsses, ks) s (url, tt)
removeClass clss x@(Image (i, clsses, ks) s (url, tt)) = if clss `notElem` clsses then x else Image (i, filter (/=clss) clsses, ks) s (url, tt)
removeClass clss x@(Code  (i, clsses, ks) code)        = if clss `notElem` clsses then x else Code (i, filter (/=clss) clsses, ks) code
removeClass _    x = x

-- print normal progress messages to stderr in bold green:
printGreen :: String -> IO ()
printGreen s = hPutStrLn stderr $ "\x1b[32m" ++ s ++ "\x1b[0m"

-- print danger or error messages to stderr in red background:
printRed :: String -> IO ()
printRed s = hPutStrLn stderr $ "\x1b[41m" ++ s ++ "\x1b[0m"

-- Repeatedly apply `f` to an input until the input stops changing. Show constraint for better error
-- reporting on the occasional infinite loop.
fixedPoint :: (Show a, Eq a) => (a -> a) -> a -> a
fixedPoint = fixedPoint' 100000
 where fixedPoint' :: (Show a, Eq a) => Int -> (a -> a) -> a -> a
       fixedPoint' 0 _ i = error $ "Hit recursion limit: still changing after 100,000 iterations! Infinite loop? Final result: " ++ show i
       fixedPoint' n f i = let i' = f i in if i' == i then i else fixedPoint' (n-1) f i'

sed :: String -> String -> String -> String
sed regex new_str str  =
    let parts = concat $ map elems $ (str  =~  regex :: [MatchArray])
    in foldl (replace' new_str) str (reverse parts)

  where
     replace' :: [a] -> [a] -> (Int, Int) -> [a]
     replace' new list (shift, l)   =
        let (pre, post) = splitAt shift list
        in pre ++ new ++ (drop l post)

-- list of regexp string rewrites
sedMany :: [(String,String)] -> (String -> String)
sedMany regexps s = foldr (uncurry sed) s regexps

-- list of fixed string rewrites
replaceMany :: [(String,String)] -> (String -> String)
replaceMany rewrites s = foldr (uncurry replace) s rewrites

frequency :: Ord a => [a] -> [(Int,a)]
frequency list = map (\l -> (length l, head l)) (group (sort list))

host :: T.Text -> T.Text
host p = case parseURIReference (T.unpack p) of
              Nothing -> ""
              Just uri' -> case uriAuthority uri' of
                                Nothing -> ""
                                Just uridomain' -> T.pack $ uriRegName uridomain'

anyInfix, anyPrefix, anySuffix :: String -> [String] -> Bool
anyInfix p = any (`isInfixOf` p)
anyPrefix p = any (`isPrefixOf` p)
anySuffix p = any (`isSuffixOf` p)

anyInfixT, anyPrefixT, anySuffixT :: T.Text -> [T.Text] -> Bool
anyInfixT p = any (`T.isInfixOf` p)
anyPrefixT p = any (`T.isPrefixOf` p)
anySuffixT p = any (`T.isSuffixOf` p)
