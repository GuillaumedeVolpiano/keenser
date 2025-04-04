{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TemplateHaskell  #-}
module Keenser.Middleware.Retry
  ( retry
  ) where

import           Control.Exception.Lifted    (SomeException, catch)
import           Control.Monad.Logger
import           Data.Aeson
import qualified Data.ByteString.Lazy        as LBS
import qualified Data.Aeson.KeyMap         as HM
import           Database.Redis

import Keenser.Import
import Keenser.Types

import qualified Data.Text as T

retry :: (MonadLogger m, MonadBaseControl IO m, MonadIO m) => Middleware m
retry Manager{..} _ job q inner = catch inner $ \e -> do
  (count, ts, rJob) <- nextRetry e job q
  void . liftIO $ if count < 10
    then
      runRedis managerRedis $
        zadd "retry" [(timeToDouble ts, LBS.toStrict $ encode rJob)]
    else do
      now <- getCurrentTime
      runRedis managerRedis $ do
         zadd "dead" [(timeToDouble now, LBS.toStrict $ encode job)]
         -- TODO: prune by count and time, customizable
         zremrangebyrank "dead" 0 (-1000)

-- TODO: + rand(30) * (count + 1) to prevent thundering herd
retryTime :: Integer -> UTCTime -> UTCTime
retryTime count start = fromInteger offset `secondsFrom` start
  where offset = (count ^ 4) + 15

nextRetry :: (MonadLogger m, MonadIO m)
          => SomeException -> Object -> Queue -> m (Integer, UTCTime, Object)
nextRetry ex old q = do
  now <- liftIO getCurrentTime

  let
    -- TODO: I don't love how stringly-typed this direct `Object` manipulation is,
    --   but if we're staying consistent w/ Sidekiq's Redis API, we need to allow
    --   middleware authors to jam whatever metadata they want on the Jobject
    (count, status) = case HM.lookup "retry_count" old >>= mJSON of
      Just n  -> (n+1, ["retried_at" .= timeToJson now])
      Nothing -> (  0, ["failed_at"  .= timeToJson now])
    updates = HM.fromList $
      [ "queue"         .= fromMaybe q (HM.lookup "retry_queue" old >>= mJSON)
      , "error_message" .= show ex
      , "error_class"   .= ("SomeException" :: T.Text)
      , "retry_count"   .= count
      ] ++ status
  $(logInfo) $ "Retry number " <> T.pack (show count)
  return $! (count, retryTime count now, HM.union updates old)

mJSON :: FromJSON a => Value -> Maybe a
mJSON v = case fromJSON v of
  Success a -> Just a
  _         -> Nothing
