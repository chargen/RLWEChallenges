{-# LANGUAGE FlexibleContexts, NoImplicitPrelude, RebindableSyntax, ScopedTypeVariables #-}

import Challenges.Beacon
import Challenges.Common
import qualified Challenges.Proto.LWEInstance as P
import qualified Challenges.Proto.LWESample as P
import qualified Challenges.Proto.LWESecret as P
import Challenges.Proto.InstType
import qualified Challenges.ContinuousLWE.Verify as C
import qualified Challenges.DiscretizedLWE.Verify as D

import Control.Applicative
import Control.Monad (when)
import Control.Monad.Except
import Control.Monad.Trans (lift)

import Crypto.Lol hiding (lift)
import Crypto.Lol.Reflects
import Crypto.Lol.Types.Proto (fromProto)
import Crypto.Lol.Types.RealQ

import qualified Data.ByteString.Lazy as BS
import Data.List (nub)
import Data.Maybe (fromJust, isNothing, isJust)
import Data.Reflection
import Data.Word

import Net.Beacon

import System.Directory (doesFileExist, getDirectoryContents, doesDirectoryExist)
import System.IO

import Text.ProtocolBuffers (messageGet)
import Text.ProtocolBuffers.Header (ReflectDescriptor, Wire)

-- Tensor type used to verify instances
type T = CT

main :: IO ()
main = do
  -- for nice printing when running executable
  hSetBuffering stdout NoBuffering
  
  abspath <- getPath
  let challDir = abspath </> challengeFilesDir
  challDirExists <- doesDirectoryExist challDir
  when (not challDirExists) $ error $ "Could not find " ++ challDir

  challs <- getChallengeList challDir

  -- verifies challenges and accumulates beacon positions for each challenge
  bps <- mapM (verifyChallenge abspath) challs
  -- verifies that all challenges use distinct random bits
  when (all isJust bps) $ printPassFail "Checking for distinct beacon positions..." "DISTINCT" $ 
    when ((length $ nub bps) /= length bps) $ throwError "Beacon positions overlap"

-- | Verifies all instances that have a secret and return the beacon position for the challenge.
verifyChallenge :: FilePath -> String -> IO (Maybe BeaconPos)
verifyChallenge path name = do
  let challPath = path </> challengeFilesDir </> name

  printPassFail ("Verifying challenge " ++ name ++ ":\n") "DONE" $ do
    bp@(BP time offset) <- readRevealData challPath
    -- read the beacon record from an xml file
    rec <- readBeacon path time

    let secretIdx = getSecretIdx rec offset
        instIDs = [0..(numInstances-1)]    
    -- verify all instances
    lift $ mapM_ (verifyInstance path name secretIdx) instIDs
    -- verifyInstance prints out several progress statements
    -- so we need to indent to print the status
    lift $ putStr "\t"
    return $ Just bp

-- | Verifies an instance with a particular ID.
verifyInstance :: FilePath -> String -> Int -> Int -> IO ()
verifyInstance path challName secretID instID 
  | secretID == instID = printPassFail ("\tSecret for instance " ++ (show secretID) ++ " is suppressed.\t") "" $ do
    let secDir = path </> secretFilesDir </> challName
        secretName = secretFileName challName secretID
    secExists <- lift $ doesFileExist (secDir </> secretName)
    when secExists $ throwError $ "The secret index for challenge " ++ 
          challName ++ " is " ++ (show secretID) ++ ", but this secret is present!"
  | otherwise = printPassFail ("\tChecking instance " ++ (show instID) ++ "\t") "VERIFIED" $ do
    (inst, sec) <- parseInst path challName instID
    checkInstErr inst sec

-- | Verifies an instance that has a corresponding secret.
parseInst :: FilePath -> String -> Int -> ExceptT String IO (P.LWEInstance, P.LWESecret)
parseInst path challName instID = do
  let instFile = path </> challengeFilesDir </> challName </> (instFileName challName instID)
      secFile = path </> secretFilesDir </> challName </> (secretFileName challName instID)
  instFileExists <- lift $ doesFileExist instFile
  when (not instFileExists) $ throwError $ instFile ++ " does not exist."
  secFileExists <- lift $ doesFileExist secFile
  when (not secFileExists) $ throwError $ secFile ++ " does not exist."
  inst@(P.LWEInstance instType idx m _ _ _ _) <- lift $ messageGet' <$> BS.readFile instFile
  sec@(P.LWESecret idx' m' _) <- lift $ messageGet' <$> BS.readFile secFile
  when (idx /= idx') $ throwError $ "Instance ID is " ++ (show idx) ++ ", but secret ID is " ++ (show idx')
  when (m /= m') $ throwError $ "Instance index is " ++ (show m) ++ ", but secret index is " ++ (show m')
  return (inst,sec)

checkInstErr :: P.LWEInstance -> P.LWESecret -> ExceptT String IO ()
checkInstErr inst@(P.LWEInstance t _ m q _ _ _) sec 
  | t == ContLWE = 
    reifyFactI (fromIntegral m) (\(_::proxy m) -> 
      reify (fromIntegral q :: Int64) (\(_::Proxy q) -> do
        let (C.LWEInstance _ _ bound samples) = fromProto inst :: C.LWEInstance Double T m (ZqBasic (Reified q) Int64) (RealQ (RealMod (Reified q)) Double)
            (C.LWESecret _ secret) = fromProto sec
        when (not $ C.checkInstance bound secret samples) $ 
          throwError $ "A sample exceeded the noise bound."
        ))
  | t == DiscLWE =
    reifyFactI (fromIntegral m) (\(_::proxy m) -> 
      reify (fromIntegral q :: Int64) (\(_::Proxy q) -> do
        let (D.LWEInstance _ _ bound samples) = fromProto inst :: D.LWEInstance Double T m (ZqBasic (Reified q) Int64)
            (D.LWESecret _ secret) = fromProto sec
        when (not $ D.checkInstance (round bound) secret samples) $ 
          throwError $ "A sample in instance exceeded the noise bound."
        ))
  | t == LWR = error "cannot verify LWR instances yet"

-- | Reads a serialized protobuffer file to the unparameterized proto type.
messageGet' :: (ReflectDescriptor a, Wire a) => BS.ByteString -> a
messageGet' bs = 
  case messageGet bs of
    (Left str) -> error $ "when getting protocol buffer. Got string " ++ str
    (Right (a,bs')) -> 
      if BS.null bs'
      then a
      else error $ "when getting protocol buffer. There were leftover bits!"

-- | Read an XML file for the beacon corresponding to the provided time.
readBeacon :: FilePath -> Int -> ExceptT String IO Record
readBeacon path time = do
  let file = path </> secretFilesDir </> xmlFileName time
  beaconExists <- lift $ doesFileExist file
  when (not beaconExists) $ throwError $ "Cannot find " ++ file
  rec' <- lift $ fromXML <$> BS.readFile file
  when (isNothing rec') $ throwError $ "Could not parse " ++ file
  return $ fromJust rec'
