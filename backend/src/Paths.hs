{-# LANGUAGE TemplateHaskell #-}
module Paths where

import System.Which (staticWhich, staticWhichNix)

realpathPath :: FilePath
realpathPath = $(staticWhich "realpath")

dirnamePath :: FilePath
dirnamePath = $(staticWhich "dirname")

livedocDevnetScriptPath :: FilePath
livedocDevnetScriptPath = $(staticWhichNix "prepare-devnet.sh")
