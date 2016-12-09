{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Projector.Html (
    HtmlError (..)
  , renderHtmlError
  , thing
  ) where


import qualified Data.Text as T

import           P

import           Projector.Html.Core  (CoreError(..), renderCoreErrorRange, templateToCore, HtmlType, HtmlExpr)
import           Projector.Html.Data.Position  (Range)
import           Projector.Html.Parser (ParseError (..), parse)

import           System.IO  (FilePath)


data HtmlError
  = HtmlParseError ParseError
  | HtmlCoreError (CoreError Range)
  deriving (Eq, Show)

renderHtmlError :: HtmlError -> Text
renderHtmlError he =
  case he of
    HtmlParseError e ->
      -- FIX
      T.pack (show e)
    HtmlCoreError e ->
      renderCoreErrorRange e

thing :: FilePath -> Text -> Either HtmlError (HtmlType, HtmlExpr Range)
thing file t =
  first HtmlParseError (parse file t) >>= first HtmlCoreError . templateToCore
