{-# OPTIONS_GHC -fno-warn-orphans #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}

module Database.Beam.Postgres.Types
  ( Postgres(..)
  , fromPgIntegral
  , fromPgScientificOrIntegral
  ) where

import           Database.Beam
import           Database.Beam.Backend
import           Database.Beam.Backend.Internal.Compat
import           Database.Beam.Migrate.Generics
import           Database.Beam.Migrate.SQL (BeamMigrateOnlySqlBackend)
import           Database.Beam.Postgres.Syntax
import           Database.Beam.Query.SQL92

import qualified Database.PostgreSQL.Simple.FromField as Pg
import qualified Database.PostgreSQL.Simple.HStore as Pg (HStoreMap, HStoreList)
import qualified Database.PostgreSQL.Simple.Types as Pg
import qualified Database.PostgreSQL.Simple.Range as Pg (PGRange)
import qualified Database.PostgreSQL.Simple.Time as Pg (Date, UTCTimestamp, ZonedTimestamp, LocalTimestamp)

import           Data.Aeson (Value)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import           Data.CaseInsensitive (CI)
import           Data.Int
import           Data.Proxy
import           Data.Ratio (Ratio)
import           Data.Scientific (Scientific, toBoundedInteger)
import           Data.Tagged
import           Data.Text (Text)
import qualified Data.Text.Lazy as TL
import           Data.Time (UTCTime, Day, TimeOfDay, LocalTime, NominalDiffTime, ZonedTime(..))
import           Data.UUID.Types (UUID)
import           Data.Vector (Vector)
import           Data.Word
import           GHC.TypeLits

-- | The Postgres backend type, used to parameterize 'MonadBeam'. See the
-- definitions there for more information. The corresponding query monad is
-- 'Pg'. See documentation for 'MonadBeam' and the
-- <https://haskell-beam.github/beam/ user guide> for more information on using
-- this backend.
data Postgres
  = Postgres

instance BeamBackend Postgres where
  type BackendFromField Postgres = Pg.FromField

instance HasSqlInTable Postgres where

instance Pg.FromField SqlNull where
  fromField field d = fmap (\Pg.Null -> SqlNull) (Pg.fromField field d)

-- | Deserialize integral fields, possibly downcasting from a larger numeric type
-- via 'Scientific' if we won't lose data, and then falling back to any integral
-- type via 'Integer'
fromPgScientificOrIntegral :: (Bounded a, Integral a) => FromBackendRowM Postgres a
fromPgScientificOrIntegral = do
  sciVal <- fmap (toBoundedInteger =<<) peekField
  case sciVal of
    Just sciVal' -> do
      pure sciVal'
    Nothing -> fromIntegral <$> fromBackendRow @Postgres @Integer

-- | Deserialize integral fields, possibly downcasting from a larger integral
-- type, but only if we won't lose data
fromPgIntegral :: forall a
                . (Pg.FromField a, Integral a, Typeable a)
               => FromBackendRowM Postgres a
fromPgIntegral = do
  val <- peekField
  case val of
    Just val' -> do
      pure val'
    Nothing -> do
      val' <- parseOneField @Postgres @Integer
      let val'' = fromIntegral val'
      if fromIntegral val'' == val'
        then pure val''
        else fail (concat [ "Data loss while downsizing Integral type. "
                          , "Make sure your Haskell types are wide enough for your data" ])

-- Default FromBackendRow instances for all postgresql-simple FromField instances
instance FromBackendRow Postgres SqlNull
instance FromBackendRow Postgres Bool
instance FromBackendRow Postgres Char
instance FromBackendRow Postgres Double
instance FromBackendRow Postgres Int16 where
  fromBackendRow = fromPgIntegral
instance FromBackendRow Postgres Int32 where
  fromBackendRow = fromPgIntegral
instance FromBackendRow Postgres Int64 where
  fromBackendRow = fromPgIntegral

instance TypeError (PreferExplicitSize Int Int32) => FromBackendRow Postgres Int where
  fromBackendRow = fromPgIntegral

-- Word values are serialized as SQL @NUMBER@ types to guarantee full domain coverage.
-- However, we want them te be serialized/deserialized as whichever type makes sense
instance FromBackendRow Postgres Word16 where
  fromBackendRow = fromPgScientificOrIntegral
instance FromBackendRow Postgres Word32 where
  fromBackendRow = fromPgScientificOrIntegral
instance FromBackendRow Postgres Word64 where
  fromBackendRow = fromPgScientificOrIntegral

instance TypeError (PreferExplicitSize Word Word32) => FromBackendRow Postgres Word where
  fromBackendRow = fromPgScientificOrIntegral

instance FromBackendRow Postgres Integer
instance FromBackendRow Postgres ByteString
instance FromBackendRow Postgres Scientific
instance FromBackendRow Postgres BL.ByteString
instance FromBackendRow Postgres Text
instance FromBackendRow Postgres UTCTime
instance FromBackendRow Postgres Value
instance FromBackendRow Postgres TL.Text
instance FromBackendRow Postgres Pg.Oid
instance FromBackendRow Postgres LocalTime where
  fromBackendRow =
    peekField >>=
    \case
      Just (x :: LocalTime) -> pure x

      -- Also accept 'TIMESTAMP WITH TIME ZONE'. Considered as
      -- 'LocalTime', because postgres always returns times in the
      -- server timezone, regardless of type.
      Nothing ->
        peekField >>=
        \case
          Just (x :: ZonedTime) -> pure (zonedTimeToLocalTime x)
          Nothing -> fail "'TIMESTAMP WITH TIME ZONE' or 'TIMESTAMP WITHOUT TIME ZONE' required for LocalTime"
instance FromBackendRow Postgres TimeOfDay
instance FromBackendRow Postgres Day
instance FromBackendRow Postgres UUID
instance FromBackendRow Postgres Pg.Null
instance FromBackendRow Postgres Pg.Date
instance FromBackendRow Postgres Pg.ZonedTimestamp
instance FromBackendRow Postgres Pg.UTCTimestamp
instance FromBackendRow Postgres Pg.LocalTimestamp
instance FromBackendRow Postgres Pg.HStoreMap
instance FromBackendRow Postgres Pg.HStoreList
instance FromBackendRow Postgres [Char]
instance FromBackendRow Postgres (Ratio Integer)
instance FromBackendRow Postgres (CI Text)
instance FromBackendRow Postgres (CI TL.Text)
instance (Pg.FromField a, Typeable a) => FromBackendRow Postgres (Vector a)
instance (Pg.FromField a, Typeable a) => FromBackendRow Postgres (Pg.PGArray a)
instance FromBackendRow Postgres (Pg.Binary ByteString)
instance FromBackendRow Postgres (Pg.Binary BL.ByteString)
instance (Pg.FromField a, Typeable a) => FromBackendRow Postgres (Pg.PGRange a)
instance (Pg.FromField a, Pg.FromField b, Typeable a, Typeable b) => FromBackendRow Postgres (Either a b)

instance BeamSqlBackend Postgres where
    type BeamSqlBackendSupportsColumnAliases Postgres = 'True
instance BeamMigrateOnlySqlBackend Postgres
type instance BeamSqlBackendSyntax Postgres = PgCommandSyntax

instance BeamSqlBackendIsString Postgres String
instance BeamSqlBackendIsString Postgres Text

instance HasQBuilder Postgres where
  buildSqlQuery = buildSql92Query' True

-- * Instances for 'HasDefaultSqlDataType'

instance HasDefaultSqlDataType Postgres ByteString where
  defaultSqlDataType _ _ _ = pgByteaType

instance HasDefaultSqlDataType Postgres LocalTime where
  defaultSqlDataType _ _ _ = timestampType Nothing False

instance HasDefaultSqlDataType Postgres UTCTime where
  defaultSqlDataType _ _ _ = timestampType Nothing True

instance HasDefaultSqlDataType Postgres (SqlSerial Int16) where
  defaultSqlDataType _ _ False = pgSmallSerialType
  defaultSqlDataType _ _ _ = smallIntType

instance HasDefaultSqlDataType Postgres (SqlSerial Int32) where
  defaultSqlDataType _ _ False = pgSerialType
  defaultSqlDataType _ _ _ = intType

instance HasDefaultSqlDataType Postgres (SqlSerial Int64) where
  defaultSqlDataType _ _ False = pgBigSerialType
  defaultSqlDataType _ _ _ = bigIntType

instance TypeError (PreferExplicitSize Int Int32) => HasDefaultSqlDataType Postgres (SqlSerial Int) where
  defaultSqlDataType _ = defaultSqlDataType (Proxy @(SqlSerial Int32))

instance HasDefaultSqlDataType Postgres UUID where
  defaultSqlDataType _ _ _ = pgUuidType

-- * Instances for 'HasSqlEqualityCheck'

#define PG_HAS_EQUALITY_CHECK(ty)                                 \
  instance HasSqlEqualityCheck Postgres (ty);           \
  instance HasSqlQuantifiedEqualityCheck Postgres (ty);

PG_HAS_EQUALITY_CHECK(Bool)
PG_HAS_EQUALITY_CHECK(Double)
PG_HAS_EQUALITY_CHECK(Float)
PG_HAS_EQUALITY_CHECK(Int8)
PG_HAS_EQUALITY_CHECK(Int16)
PG_HAS_EQUALITY_CHECK(Int32)
PG_HAS_EQUALITY_CHECK(Int64)
PG_HAS_EQUALITY_CHECK(Integer)
PG_HAS_EQUALITY_CHECK(Word8)
PG_HAS_EQUALITY_CHECK(Word16)
PG_HAS_EQUALITY_CHECK(Word32)
PG_HAS_EQUALITY_CHECK(Word64)
PG_HAS_EQUALITY_CHECK(Text)
PG_HAS_EQUALITY_CHECK(TL.Text)
PG_HAS_EQUALITY_CHECK(UTCTime)
PG_HAS_EQUALITY_CHECK(Value)
PG_HAS_EQUALITY_CHECK(Pg.Oid)
PG_HAS_EQUALITY_CHECK(LocalTime)
PG_HAS_EQUALITY_CHECK(ZonedTime)
PG_HAS_EQUALITY_CHECK(TimeOfDay)
PG_HAS_EQUALITY_CHECK(NominalDiffTime)
PG_HAS_EQUALITY_CHECK(Day)
PG_HAS_EQUALITY_CHECK(UUID)
PG_HAS_EQUALITY_CHECK([Char])
PG_HAS_EQUALITY_CHECK(Pg.HStoreMap)
PG_HAS_EQUALITY_CHECK(Pg.HStoreList)
PG_HAS_EQUALITY_CHECK(Pg.Date)
PG_HAS_EQUALITY_CHECK(Pg.ZonedTimestamp)
PG_HAS_EQUALITY_CHECK(Pg.LocalTimestamp)
PG_HAS_EQUALITY_CHECK(Pg.UTCTimestamp)
PG_HAS_EQUALITY_CHECK(Scientific)
PG_HAS_EQUALITY_CHECK(ByteString)
PG_HAS_EQUALITY_CHECK(BL.ByteString)
PG_HAS_EQUALITY_CHECK(Vector a)
PG_HAS_EQUALITY_CHECK(CI Text)
PG_HAS_EQUALITY_CHECK(CI TL.Text)

instance TypeError (PreferExplicitSize Int Int32) => HasSqlEqualityCheck Postgres Int
instance TypeError (PreferExplicitSize Int Int32) => HasSqlQuantifiedEqualityCheck Postgres Int
instance TypeError (PreferExplicitSize Word Word32) => HasSqlEqualityCheck Postgres Word
instance TypeError (PreferExplicitSize Word Word32) => HasSqlQuantifiedEqualityCheck Postgres Word

instance HasSqlEqualityCheck Postgres a =>
  HasSqlEqualityCheck Postgres (Tagged t a)
instance HasSqlQuantifiedEqualityCheck Postgres a =>
  HasSqlQuantifiedEqualityCheck Postgres (Tagged t a)
