#!/usr/bin/env runhaskell

-- CLI tool to add link-tags to specified URLs/paths. eg 'addTag.hs "economics/experience-curve" "https://en.wikipedia.org/wiki/Experience_curve_effects"'
module Main where

import Control.Monad (when)
import Data.Maybe (isJust, fromJust)
import System.Environment (getArgs)

import LinkMetadata (annotateLink, readLinkMetadata, readYaml, writeYaml, MetadataList, MetadataItem)

main :: IO ()
main = do [tag, link] <- getArgs
          when (head link /= '/' && take 4 link /= "http") $ error $ "Arguments not 'addTag.hs tag *link*'? : " ++ link
          when (head tag == '/'  || take 4 tag == "http")  $ error $ "Arguments not 'addTag.hs *tag* link'? : " ++ tag
          [custom,partial,auto] <- mapM readYaml ["metadata/custom.yaml", "metadata/partial.yaml", "metadata/auto.yaml"]
          addAndWriteTags tag link custom partial auto

-- If an annotation is in custom.yaml, we only want to write that. If it's in partial.yaml, likewise. If it's in auto.yaml, now that we've added a tag to it, it is no longer disposable and must be preserved by moving it from auto.yaml to partial.yaml. If it's not in any metadata file (such as a Wikipedia link, which is normally suppressed), then we add it to partial.yaml.
addAndWriteTags :: String -> String -> MetadataList -> MetadataList -> MetadataList -> IO ()
addAndWriteTags t i c p a  = do let cP = hasItem c i
                                    pP = hasItem p i
                                    aP = hasItem a i
                                if cP then writeYaml "metadata/custom.yaml" (addTag c i t) else
                                  if pP then writeYaml "metadata/partial.yaml" (addTag p i t) else
                                    if aP then let (autoNew,partialNew) = mvItem a p i in writeYaml "metadata/auto.yaml" autoNew >> writeYaml "metadata/partial.yaml" (addTag partialNew i t)
                                    else addNewLink i

-- what if a link is completely new and is not in either custom.yaml (handwritten) or auto.yaml (often auto-annotated)? If we write it directly into partial.yaml, then for many links like Arxiv/Biorxiv, we'd skip creating an automatic annotation!
-- So instead we hook back into the main link annotation workflow, create a new annotation for that (which will be in auto.yaml), and then run addTag.hs *again*, so this time it has an annotation to work with (and will do auto.yaml → partial.yaml).
addNewLink :: String -> IO ()
addNewLink p = do md <- readLinkMetadata
                  _ <- annotateLink md p
                  main

addTag :: MetadataList -> String -> String -> MetadataList
addTag ml i tag = map (\(path,item@(a,b,c,d,e,f)) -> if i /= path || (tag `elem` e) then (path,item) else
                                                      (path,(a,b,c,d,e++[tag],f)) ) ml

mvItem :: MetadataList -> MetadataList -> String -> (MetadataList,MetadataList)
mvItem original new i = (removeItem original i,
                          new ++ [(i, fromJust $ getItem original i)])

getItem :: MetadataList -> String -> Maybe MetadataItem
getItem ml i = lookup i ml

removeItem :: MetadataList -> String -> MetadataList
removeItem ml i = filter (\(p,_) -> p /= i) ml

hasItem :: MetadataList -> String -> Bool
hasItem ml i = isJust $ getItem ml i