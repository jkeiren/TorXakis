{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Name
-- Copyright   :  (c) TNO and Radboud University
-- License     :  BSD3 (see the file license.txt)
-- 
-- Maintainer  :  pierre.vandelaar@tno.nl (Embedded Systems Innovation by TNO)
-- Stability   :  experimental
-- Portability :  portable
--
-- Name
-----------------------------------------------------------------------------
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module Name
( Name
, toText
, name
, fromNonEmpty
, nameOf
, searchDuplicateNames
, searchDuplicateNames2
, HasName (..)
)
where

import           Control.DeepSeq
import           Data.Data
import           Data.List.NonEmpty (NonEmpty, toList)
import           Data.List.Unique
import           Data.Text (Text)
import qualified Data.Text as T
import           GHC.Generics     (Generic)

-- | Definition of names of entities.
newtype Name = Name
    { -- | 'Data.Text' representation of Name
      toText :: Text
    }
    deriving (Eq, Ord, Read, Show, Generic, NFData, Data)

-- | Smart constructor for Name
--
--   Precondition:
--
--   * Name should be non-empty
--
--   Given a 'Data.Text',
--
--   * either an error message indicating violation of precondition
--
--   * or a 'Name' structure containing the 'Data.Text'
--
--   is returned.
name :: Text -> Either Text Name
name s | T.null s = Left $ T.pack "Illegal input: Empty String"
name s            = Right $ Name s

-- | Creates a name from a given 'show'able entity.
nameOf :: Show t => t -> Name
nameOf = Name . T.pack . show

fromNonEmpty :: NonEmpty Char -> Name
fromNonEmpty = Name . T.pack . toList

class HasName a where
    getName :: a -> Name

instance HasName Name where
    getName = id

-- | Search values in the first list that have non-unique names among combination
--   of both lists.
searchDuplicateNames2 :: (HasName a, HasName b) => [a] -> [b] -> [a]
searchDuplicateNames2 xs ys = filter ((`elem` nuNames) . getName) xs
    where nuNames = repeated $ map getName xs ++ map getName ys

-- | Search values in the list that have non-unique names.
searchDuplicateNames :: (HasName a) => [a] -> [a]
searchDuplicateNames = (`searchDuplicateNames2` ([] :: [Name]))
