{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module HipBot.API
  ( HipBotAPI(..)
  , HasHipBotAPI(hipBotAPI)
  , stmAPI
  , pgAPI
  ) where

import Control.Applicative
import Control.Concurrent.STM
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.UTF8 as B
import qualified Data.HashMap.Strict as HashMap
import Data.Monoid
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.FromRow
import Safe

import HipBot.Internal.Types

data HipBotAPI m = HipBotAPI
  { apiInsertRegistration :: Registration -> AccessToken -> m ()
  , apiDeleteRegistration :: OAuthId -> m ()
  , apiLookupRegistration :: OAuthId -> m (Maybe (Registration, AccessToken))
  , apiUpdateAccessToken :: OAuthId -> AccessToken -> m ()
  }

makeClassy ''HipBotAPI

stmAPI :: MonadIO m => IO (HipBotAPI m)
stmAPI = do
  regs <- newTVarIO HashMap.empty
  return HipBotAPI
    { apiInsertRegistration = \r t ->
        liftIO .
          atomically .
          modifyTVar' regs .
          HashMap.insert (r ^. oauthId) $
          (r, t)
    , apiDeleteRegistration =
        liftIO .
          atomically .
          modifyTVar' regs .
          HashMap.delete
    , apiLookupRegistration =
        liftIO .
          atomically .
          flip fmap (readTVar regs) .
          HashMap.lookup
    , apiUpdateAccessToken = \oid t ->
        liftIO .
          atomically .
          modifyTVar' regs .
          HashMap.adjust (set _2 t) $
          oid
    }

pgAPI :: MonadIO m => Connection -> HipBotAPI m
pgAPI conn = HipBotAPI
  { apiInsertRegistration = \r t ->
      let
        stmt = "insert into hipbot (" <> pgFields <> ") values (?, ?, ?, ?, ?, ?, ?)"
        row =
          ( r ^. oauthId
          , r ^. capabilitiesUrl . to show
          , r ^. roomId
          , r ^. groupId
          , r ^. oauthSecret
          , t ^. accessToken
          , t ^. expires
          )
      in
        liftIO . void . execute conn stmt $ row
  , apiDeleteRegistration =
      let stmt = "delete from hipbot where oauthId = ?"
      in liftIO . void . execute conn stmt . Only
  , apiLookupRegistration =
      let q = "select " <> pgFields <> " from hipbot where oauthId = ?"
      in liftIO . fmap (fmap getRegRow . headMay) . query conn q . Only
  , apiUpdateAccessToken = \oid t ->
      let
        stmt = "update hipbot set accessToken = ?, accessTokenExpires = ? where oauthId = ?"
        ps = (t ^. accessToken, t ^. expires, oid)
      in
        liftIO . void . execute conn stmt $ ps
  }

pgFields :: Query
pgFields = "oauthId, capabilitiesUrl, roomId, groupId, oauthSecret, accessToken, accessTokenExpires"

newtype RegRow = RegRow { getRegRow :: (Registration, AccessToken) }

instance FromRow RegRow where
  fromRow = (RegRow .) . (,) <$> reg <*> tok where
    reg = Registration
      <$> field
      <*> fieldWith parseUri
      <*> field
      <*> field
      <*> field
    tok = AccessToken <$> field <*> field
    parseUri f = maybe err parse where
      err = returnError UnexpectedNull f ""
      parse = maybe err' return . parseAbsoluteURI . B.toString where
        err' = returnError ConversionFailed f "not an absolute URI"

