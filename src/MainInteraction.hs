
module MainInteraction where

import qualified Data.Map.Strict as M
import System.Environment
import System.Exit
import qualified FlatParse.Stateful as FP

import Common
import CoreTypes
import Cubical
import ElabState
import Elaboration
import Pretty
import Quotation
import Statistics

helpMsg = unlines [
   "usage: cctt <file> [nf <topdef>] [ty <topdef>] [elab] [verbose] [no-hole-cxts]"
  ,""
  ,"Checks <file>. Options:"
  ,"  nf <topdef>   prints the normal form of top-level definition <topdef>"
  ,"  ty <topdef>   prints the type of the top-level definition <topdef>"
  ,"  elab          prints the elaboration output"
  ,"  verbose       prints path endpoints, hcom types and hole source positions explicitly"
  ,"  no-hole-cxt   turn off printing local contexts of holes"
  ]

elabPath :: FilePath -> String -> IO ()
elabPath path args = mainWith (pure $ path : words args)

mainInteraction :: IO ()
mainInteraction = mainWith getArgs

parseArgs :: [String] -> IO (FilePath, Maybe String, Maybe String, Bool, Bool, Bool)
parseArgs args = do
  let exit = putStrLn helpMsg >> exitSuccess
  (path, args) <- case args of
    path:args -> pure (path, args)
    _         -> exit
  (printnf, args) <- case args of
    "nf":def:args -> pure (Just def, args)
    args          -> pure (Nothing, args)
  (printty, args) <- case args of
    "ty":def:args -> pure (Just def, args)
    args          -> pure (Nothing, args)
  (elab, args) <- case args of
    "elab":args -> pure (True, args)
    args        -> pure (False, args)
  (verbose, args) <- case args of
    "verbose":args -> pure (True, args)
    args           -> pure (False, args)
  holeCxts <- case args of
    "no-hole-cxts":[] -> pure False
    []                -> pure True
    _                 -> exit
  pure (path, printnf, printty, elab, verbose, holeCxts)

mainWith :: IO [String] -> IO ()
mainWith getArgs = do
  resetElabState
  resetStats
  (path, printnf, printty, printelab, verbosity, holeCxts) <- parseArgs =<< getArgs

  modState $ printingOpts %~
      (verbose .~ verbosity)
    . (showHoleCxts .~ holeCxts)

  (_, !totaltime) <- timed (elaborate path)
  st <- getState
  putStrLn ""
  putStrLn ("parsing time: " ++ show (st^.parsingTime))
  putStrLn ("elaboration time: " ++ show (totaltime - st^.parsingTime))
  putStrLn ("checked " ++ show (st^.lvl) ++ " definitions")

  when printelab do
    putStrLn ("\n------------------------------------------------------------")
    putStrLn ("------------------------------------------------------------")
    putStrLn $ pretty0 (st^.top')

  case printnf of
    Just x -> do
      (!nf, !nftime) <- case M.lookup (FP.strToUtf8 x) (st^.top) of
        Just (TEDef i) -> do
          let ?env = ENil; ?cof = emptyNCof; ?dom = 0
          timedPure (quote (i^.defVal))
        _ -> do
          putStrLn $ "No top-level definition with name: " ++ show x
          exitSuccess
      putStrLn ("------------------------------------------------------------")
      putStrLn ("------------------------------------------------------------")
      putStrLn ""
      putStrLn $ "Normal form of " ++ x ++ ":\n\n" ++ pretty0 nf
      putStrLn ""
      putStrLn $ "Normalized in " ++ show nftime
    Nothing ->
      pure ()

  case printty of
    Just x -> do
      case M.lookup (FP.strToUtf8 x) (st^.top) of
        Just (TEDef i) -> do
          putStrLn ""
          putStrLn $ show (i^.pos)
          putStrLn $ x ++ " : " ++ pretty0 (i^.defTy)
        _ -> do
          putStrLn $ "No top-level definition with name: " ++ show x
          exitSuccess
    Nothing ->
      pure ()

  renderStats
