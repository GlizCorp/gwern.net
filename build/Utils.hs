{-# LANGUAGE OverloadedStrings #-}
module Utils where

import Control.Monad (when)
import Data.Text.IO as TIO (readFile, writeFile)
import qualified Data.Text as T (Text, pack, unpack)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (takeDirectory)
import System.IO.Temp (emptySystemTempFile)
import Text.Pandoc (def, nullMeta, runPure,
                    writerColumns, writePlain, Block, Pandoc(Pandoc), Inline(Link, Span), readerExtensions, writerExtensions, readHtml, writeMarkdown, pandocExtensions)
import System.IO (stderr, hPutStrLn)
import Data.Time.Clock (getCurrentTime, utctDay)
import Data.Time.Calendar (toGregorian)
import System.IO.Unsafe (unsafePerformIO)
import Text.Regex (subRegex, mkRegex)
import Data.List.Utils (replace)
import Text.Show.Pretty (ppShow)

-- Auto-update the current year.
{-# NOINLINE currentYear #-}
currentYear :: Int
currentYear = unsafePerformIO $ fmap ((\(year,_,_) -> fromInteger year) . toGregorian . utctDay) Data.Time.Clock.getCurrentTime

-- Write only when changed, to reduce sync overhead; creates parent directories as necessary; writes to a temp file in /tmp/ (at a specified template name), and does an atomic rename to the final file.
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


-- Add or remove a class to a Link or Span; this is a null op if the class is already present or it is not a Link/Span.
addClass :: T.Text -> Inline -> Inline
addClass clss x@(Span (i, clsses, ks) s)           = if clss `elem` clsses then x else Span (i, clss:clsses, ks) s
addClass clss x@(Link (i, clsses, ks) s (url, tt)) = if clss `elem` clsses then x else Link (i, clss:clsses, ks) s (url, tt)
addClass _    x = x
removeClass :: T.Text -> Inline -> Inline
removeClass clss x@(Span (i, clsses, ks) s)           = if clss `notElem` clsses then x else Span (i, filter (==clss) clsses, ks) s
removeClass clss x@(Link (i, clsses, ks) s (url, tt)) = if clss `notElem` clsses then x else Link (i, filter (==clss) clsses, ks) s (url, tt)
removeClass _    x = x

-- print normal progress messages to stderr in bold green:
printGreen :: String -> IO ()
printGreen s = hPutStrLn stderr $ "\x1b[32m" ++ s ++ "\x1b[0m"

-- print danger or error messages to stderr in red background:
printRed :: String -> IO ()
printRed s = hPutStrLn stderr $ "\x1b[41m" ++ s ++ "\x1b[0m"

-- Repeatedly apply `f` to an input until the input stops changing. Show constraint for better error reporting on the occasional infinite loop.
-- <https://stackoverflow.com/questions/38955348/is-there-a-fixed-point-operator-in-haskell>
fixedPoint :: (Show a, Eq a) => (a -> a) -> a -> a
fixedPoint = fixedPoint' 100000
 where fixedPoint' :: (Show a, Eq a) => Int -> (a -> a) -> a -> a
       fixedPoint' 0 _ i = error $ "Hit recursion limit: still changing after 100,000 iterations! Infinite loop? Final result: " ++ show i
       fixedPoint' n f i = let i' = f i in if i' == i then i else fixedPoint' (n-1) f i'

sed :: String -> String -> (String -> String)
sed before after s = subRegex (mkRegex before) s after
-- list of regexp string rewrites
sedMany :: [(String,String)] -> (String -> String)
sedMany regexps s = foldr (uncurry sed) s regexps

-- list of fixed string rewrites
replaceMany :: [(String,String)] -> (String -> String)
replaceMany rewrites s = foldr (uncurry replace) s rewrites
