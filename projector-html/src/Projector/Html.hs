{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Projector.Html (
    HtmlError (..)
  , renderHtmlError
  -- * Builds
  , Build (..)
  , runBuild
  , RawTemplates (..)
  , BuildArtefacts (..)
  , DataModuleName (..)
  , UserDataTypes (..)
  , ModulePrefix (..)
  , ModuleGraph (..)
  , HB.ModuleName (..)
  , HB.BackendT (..)
  -- * Useful template and module utils
  , parseTemplate
  , checkTemplate
  , checkTemplateIncremental
  , checkModule
  , checkModules
  , codeGenModule
  -- * Templates
  , Template
  , Range
  , HtmlType
  , HtmlExpr
  ) where


import qualified Data.Char as Char
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Text as T

import qualified Machinator.Core as MC

import           P

import qualified Projector.Core as PC
import qualified Projector.Html.Backend as HB
import qualified Projector.Html.Core as HC
import           Projector.Html.Core  (CoreError(..))
import qualified Projector.Html.Core.Elaborator as Elab
import qualified Projector.Html.Core.Machinator as CM
import           Projector.Html.Data.Annotation
import qualified Projector.Html.Data.Backend as HB
import qualified Projector.Html.Data.Module as HB
import           Projector.Html.Data.Position  (Range)
import           Projector.Html.Data.Prim
import           Projector.Html.Data.Template  (Template)
import           Projector.Html.ModuleGraph
import           Projector.Html.Parser (ParseError (..), renderParseError, parse)

import qualified System.FilePath.Posix as FilePath
import           System.IO  (FilePath)

import           X.Control.Monad.Trans.Either (sequenceEither)


-- -----------------------------------------------------------------------------
-- Top-level errors

data HtmlError
  = HtmlParseError ParseError
  | HtmlCoreError (CoreError Annotation)
  | HtmlModuleGraphError GraphError
  | HtmlBackendError HB.BackendError
  deriving (Eq, Show)

renderHtmlError :: HtmlError -> Text
renderHtmlError he =
  case he of
    HtmlParseError e ->
      renderParseError e
    HtmlCoreError e ->
      HC.renderCoreErrorAnnotation e
    HtmlModuleGraphError e ->
      renderGraphError e
    HtmlBackendError e ->
      HB.renderBackendError e

-- -----------------------------------------------------------------------------
-- Interfaces for doing things with templates

parseTemplate :: FilePath -> Text -> Either HtmlError (Template Annotation)
parseTemplate f =
  bimap HtmlParseError annotateTemplate . parse f

checkTemplate :: Template Annotation -> Either HtmlError (HtmlType, HtmlExpr (HtmlType, Annotation))
checkTemplate =
  checkTemplateIncremental mempty

checkTemplateIncremental ::
     Map Text (HtmlType, Annotation)
  -> Template Annotation
  -> Either HtmlError (HtmlType, HtmlExpr (HtmlType, Annotation))
checkTemplateIncremental known ast =
    first HtmlCoreError
  . (>>= (maybe (Left (HC.HtmlTypeError [])) pure . M.lookup (PC.Name "it")))
  . HC.typeCheckIncremental mempty (libraryExprs <> (M.mapKeys PC.Name known))
  . M.singleton (PC.Name "it")
  $ Elab.elaborate ast

checkModule ::
     HtmlDecls
  -> HB.Module () PrimT Annotation
  -> Either HtmlError (HB.Module HtmlType PrimT (HtmlType, Annotation))
checkModule decls (HB.Module typs imps exps) = do
  exps' <- first HtmlCoreError (HC.typeCheckAll (decls <> typs) (fmap snd exps))
  pure (HB.Module typs imps exps')

-- | Figure out the dependency order of a set of modules, then
-- typecheck them all in that order.
checkModules ::
     HtmlDecls
  -> Map PC.Name (HtmlType, Annotation)
  -> Map HB.ModuleName (HB.Module () PrimT Annotation)
  -> Either HtmlError (Map HB.ModuleName (HB.Module HtmlType PrimT (HtmlType, Annotation)))
checkModules decls known exprs =
  first HtmlCoreError (fmap fst (foldM fun (mempty, known) deps))
  where
    deps = dependencyOrder (buildDependencyGraph (buildModuleGraph exprs))
    --
    fun (res, acc) n =
      maybe (pure (res, acc)) (\mo -> doit n mo res acc) (M.lookup n exprs)
    --
    doit n (HB.Module types imports exps) res acc = do
      exps' <- HC.typeCheckIncremental decls acc (fmap snd exps)
      let result = HB.Module types imports exps'
          newacc = M.union (fmap (PC.extractAnnotation . snd) exps') acc
      pure (M.insert n result res, newacc)

codeGenModule ::
     HB.BackendT
  -> HB.ModuleName
  -> HB.Module HtmlType PrimT (HtmlType, Annotation)
  -> (FilePath, Text)
codeGenModule backend =
  HB.renderModule (HB.getBackend backend)

-- -----------------------------------------------------------------------------
-- Build interface, i.e. things an end user should use

data Build = Build {
    buildBackend :: Maybe HB.BackendT -- ^ The type of code to generate.
  , buildModulePrefix :: ModulePrefix -- ^ A prefix to be prepended to generated module names.
  , buildDataModule :: DataModuleName -- ^ The module containing user datatypes.
  } deriving (Eq, Ord, Show)

newtype ModulePrefix = ModulePrefix {
    unModulePrefix :: HB.ModuleName
  } deriving (Eq, Ord, Show)

-- | A set of templates that have been read from disk, but not yet
-- parsed or checked.
--
-- The generated module name will be derived from the 'FilePath'
-- argument. Any irrelevant common prefixes should be stripped before
-- construction.
newtype RawTemplates = RawTemplates {
    unRawTemplates :: [(FilePath, Text)]
  } deriving (Eq, Ord, Show)

newtype BuildArtefacts = BuildArtefacts {
    unBuildArtefacts :: [(FilePath, Text)]
  } deriving (Eq, Ord, Show)

newtype DataModuleName = DataModuleName {
    unDataModuleName :: HB.ModuleName
  } deriving (Eq, Ord, Show)

newtype UserDataTypes = UserDataTypes {
    unUserDataTypes :: [MC.Definition]
  } deriving (Eq, Ord, Show, Monoid)

-- | Run a complete build from start to finish, with no caching of artefacts.
--
-- TODO return partial results when we bomb out. 'These'-esque datatype.
runBuild :: Build -> UserDataTypes -> RawTemplates -> Either [HtmlError] BuildArtefacts
runBuild (Build mb mp dm) (UserDataTypes dfs) rts = do
  -- Build the module map
  (mg, mmap) <- smush dm mp rts
  -- Check it for cycles
  (_ :: ()) <- first (pure . HtmlModuleGraphError) (detectCycles mg)
  -- Check all modules (this can be a lazy stream)
  -- TODO the Map forces all of this at once, remove
  checked <- first pure (checkModules (CM.machinatorDecls dfs) libraryExprs mmap)
  -- If there's a backend, codegen (this can be a lazy stream)
  case mb of
    Just backend -> do
      validateModules backend checked
      pure (BuildArtefacts (M.elems (M.mapWithKey (codeGenModule backend) checked)))
    Nothing ->
      pure (BuildArtefacts [])

-- TODO hmm is this a compilation detail we should hide in HC?
libraryExprs :: Map PC.Name (HtmlType, Annotation)
libraryExprs =
  M.mapWithKey (\n (ty,_e) -> (ty, LibraryFunction n)) HC.libraryExprs

-- | Run a set of backend-specific predicates.
validateModules :: HB.BackendT -> Map HB.ModuleName (HB.Module HtmlType PrimT a) -> Either [HtmlError] ()
validateModules backend mods =
  bimap (fmap HtmlBackendError) (const ()) (sequenceEither (with mods (HB.checkModule (HB.getBackend backend))))

-- | Produce the initial module map from a set of template inputs.
-- Note that:
-- * we do one template per module right now
-- * the expression names are derived from the filepath
-- * the module name is also derived from the filepath
-- * we expect all user datatypes to be exported from a single module
smush ::
     DataModuleName
  -> ModulePrefix
  -> RawTemplates
  -> Either
       [HtmlError]
       (ModuleGraph, Map HB.ModuleName (HB.Module () PrimT Annotation))
smush (DataModuleName dm) (ModulePrefix prefix) (RawTemplates templates) = do
  mmap <- fmap (deriveImports . M.fromList) . sequenceEither . with templates $ \(fp, body) -> do
    ast <- first (:[]) (parseTemplate fp body)
    let core = Elab.elaborate ast
        modn = prefix `HB.moduleNameAppend` (filePathToModuleName fp)
        expn = filePathToExprName fp
    pure (modn, HB.Module {
        HB.moduleTypes = mempty
      , HB.moduleImports = M.fromList [
            (HB.htmlRuntime, HB.OpenImport)
          , (dm, HB.OpenImport)
          ]
      , HB.moduleExprs = M.singleton expn ((), core)
      })
  pure (buildModuleGraph mmap, mmap)

-- | Derive a module name from the relative 'FilePath'.
--
-- @
-- λ> filePathToModuleName "./path_to/my/favourite_Template_place.hs"
-- ModuleName {unModuleName = "PathTo.My.FavouriteTemplatePlace"}
-- @
filePathToModuleName :: FilePath -> HB.ModuleName
filePathToModuleName =
  HB.ModuleName . T.pack . goUpper . FilePath.dropExtension
  where
    goUpper [] = []
    goUpper (x:xs)
      | Char.isAlphaNum x = Char.toUpper x : go xs
      | otherwise = goUpper xs
    go [] = []
    go (x:xs)
      | x == '/' = '.' : goUpper xs
      | Char.isAlphaNum x = x : go xs
      | otherwise = goUpper xs

-- | Derive an expression name from the relative 'FilePath'.
--
-- @
-- λ> 'filePathToExprName' "path/to/foo_bar_baz_bapGilPoilk.hsbc"
-- Name {unName = "fooBarBazBapGilPoilk"}
-- @
filePathToExprName :: FilePath -> PC.Name
filePathToExprName =
  PC.Name . T.pack . goLower . FilePath.dropExtension
  where
    go [] = []
    go (x:xs)
      | Char.isAlphaNum x = x : go xs
      | otherwise = goUpper xs
    goUpper [] = []
    goUpper (x:xs)
      | Char.isAlphaNum x = Char.toUpper x : go xs
      | otherwise = goUpper xs
    goLower [] = []
    goLower (x:xs)
      | Char.isAlphaNum x = Char.toLower x : go xs
      | otherwise = goLower xs
