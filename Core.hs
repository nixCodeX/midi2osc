{-# LANGUAGE DeriveGeneric, DefaultSignatures, TupleSections, RecordWildCards, MultiParamTypeClasses #-}

module Core
  ( Control
  , Mapping
  , emptyMapping
  , insertControlMapping
  , insertChannelMapping
  , insertActionMapping
  , removeControlFromMapping
  , removeChannelFromMapping
  , removeActionFromMapping
  , Feedback (..)
  , updateControlOutput
  , updateChannelOutput
  , updateActionOutput
  , removeControlOutput
  , removeChannelOutput
  , removeActionOutput
  , controlsInMapping
  , controlsForChannel
  , controlsForAction
  , outputForControl
  , State (State)
  , profile
  , stream
  , streamFb
  , oscConnections
  , filenames
  , eMoved
  , hMoved
  , eBankSwitch
  , hBankSwitch
  , bankLefts
  , bankRights
  , channelGroups
  , actionGroups
  , mappings
  , currentMappingIndex
  , stateFromConf
  , currentMapping
  , save
  , open
  , Connection (Connection)
  , Channel
  , Action
  ) where

import MidiCore
import OSC
import OutputCore
import Utils

import ConfParser
import ProfileParser

import Prelude hiding (readFile, writeFile, lookup)
import Control.Applicative ((<|>))
import Control.Arrow (second)
import Control.Exception (throwIO, catch, IOException)
import Data.Array (Array, (!), (//))
import Data.ByteString (readFile, writeFile)
import Data.IORef (IORef, readIORef, newIORef, modifyIORef')
import Data.Map.Strict (Map, empty, keys, lookup, insert, delete)
import qualified Data.Map.Strict as Map (fromList)
import Data.Serialize (Serialize, encode, decode)
import Data.Set (Set)
import qualified Data.Set as Set (fromList)
import GHC.Generics (Generic)

import Reactive.Threepenny hiding (empty)
import Sound.PortMidi (PMStream)

data Mapping = Mapping (Map Control Output) (Map Channel OutputChannel) (Map Action OutputAction)
  deriving (Generic)
instance Serialize Mapping

mapCs :: (Map Control Output -> Map Control Output) -> Mapping -> Mapping
mapCs f (Mapping cs chs as) = Mapping (f cs) chs as

mapChs :: (Map Channel OutputChannel -> Map Channel OutputChannel) -> Mapping -> Mapping
mapChs f (Mapping cs chs as) = Mapping cs (f chs) as

mapAs :: (Map Action OutputAction -> Map Action OutputAction) -> Mapping -> Mapping
mapAs f (Mapping cs chs as) = Mapping cs chs (f as)

emptyMapping :: Mapping
emptyMapping = Mapping empty empty empty

insertControlMapping :: Control -> Output -> Mapping -> Mapping
insertControlMapping c o = mapCs (insert c o)

insertChannelMapping :: Channel -> OutputChannel -> Mapping -> Mapping
insertChannelMapping ch oCh = mapChs (insert ch oCh)

insertActionMapping :: Action -> OutputAction -> Mapping -> Mapping
insertActionMapping a oA = mapAs (insert a oA)

removeControlFromMapping :: Control -> Mapping -> Mapping
removeControlFromMapping c = mapCs (delete c)

removeChannelFromMapping :: Channel -> Mapping -> Mapping
removeChannelFromMapping ch = mapChs (delete ch)

removeActionFromMapping :: Action -> Mapping -> Mapping
removeActionFromMapping a = mapAs (delete a)

class Feedback where
  addFeedback :: State -> Control -> IO ()
  clearFeedback :: Control -> IO ()
  clearAllFeedbacks :: IO ()
  addAllFeedbacks :: State -> IO ()
  addChannelFeedbacks :: State -> Channel -> IO ()
  addActionFeedbacks :: State -> Action -> IO ()
  clearChannelFeedbacks :: State -> Channel -> IO ()
  clearActionFeedbacks :: State -> Action -> IO ()

updateOutput :: (a -> b -> Mapping -> Mapping) -> (State -> a -> IO ()) -> State -> a -> b -> IO ()
updateOutput f fb State{..} x y = do
  i <- readIORef currentMappingIndex
  modifyIORef' mappings (\ms -> ms // [(i, f x y (ms ! i))])
  currentMapping >>= save (filenames ! i)
  fb State{..} x

updateControlOutput :: Feedback => State -> Control -> Output -> IO ()
updateControlOutput = updateOutput insertControlMapping addFeedback

updateChannelOutput :: Feedback => State -> Channel -> OutputChannel -> IO ()
updateChannelOutput = updateOutput insertChannelMapping addChannelFeedbacks

updateActionOutput :: Feedback => State -> Action -> OutputAction -> IO ()
updateActionOutput = updateOutput insertActionMapping addActionFeedbacks

removeOutput :: (a -> Mapping -> Mapping) -> (State -> a -> IO ()) -> State -> a -> IO ()
removeOutput f fb State{..} x = do
  i <- readIORef currentMappingIndex
  modifyIORef' mappings (\ms -> ms // [(i, f x (ms ! i))])
  currentMapping >>= save (filenames ! i)
  fb State{..} x

removeControlOutput :: Feedback => State -> Control -> IO ()
removeControlOutput = removeOutput removeControlFromMapping (const clearFeedback)

removeChannelOutput :: Feedback => State -> Channel -> IO ()
removeChannelOutput = removeOutput removeChannelFromMapping clearChannelFeedbacks

removeActionOutput :: Feedback => State -> Action -> IO ()
removeActionOutput = removeOutput removeActionFromMapping clearActionFeedbacks

controlsInMapping :: State -> Mapping -> [Control]
controlsInMapping State{..} (Mapping cs chs as) = keys cs ++ filter (not . null . outputForControl State{..} (Mapping cs chs as)) (keys channelGroups ++ keys actionGroups)

controlsForChannel :: State -> Channel -> [Control]
controlsForChannel State{..} ch = lookupKeysWithValue ch channelGroups

controlsForAction :: State -> Action -> [Control]
controlsForAction State{..} a = lookupKeysWithValue a actionGroups

outputForControl :: State -> Mapping -> Control -> Maybe Output
outputForControl State{..} (Mapping cs chs as) c = lookup c cs
                                               <|> (
                                                 lookup c channelGroups >>= (\ch ->
                                                   lookup ch chs >>= (\oCh ->
                                                     lookup c actionGroups >>= (\a ->
                                                       lookup a as >>= (\oA ->
                                                         outputCombine oCh oA
                                                       )
                                                     )
                                                   )
                                                 )
                                               )

data State = State
  { profile :: Profile
  , stream :: PMStream
  , streamFb :: PMStream
  , oscConnections :: Map Connection OSCConnection
  , filenames :: Array Int String
  , eMoved :: Event ControlState
  , hMoved :: Handler ControlState
  , eBankSwitch :: Event ()
  , hBankSwitch :: Handler ()
  , bankLefts :: Set Control
  , bankRights :: Set Control
  , channelGroups :: Map Control Channel
  , actionGroups :: Map Control Action
  , mappings :: IORef (Array Int Mapping)
  , currentMappingIndex :: IORef Int
  , currentMapping :: IO Mapping
  }

stateFromConf :: FilePath -> IO State
stateFromConf confFn = do
  conf <- openConf confFn
  profile <- openProfile . confProfile $ conf
  (stream, streamFb) <- openDevice . confMidiDevice $ conf
  let oscConnections = Map.fromList . map (second openOSCConnection) . confOSCAddresses $ conf
  let filenames = mkArray . confBanks $ conf
  (eMoved, hMoved) <- newEvent
  (eBankSwitch, hBankSwitch) <- newEvent
  let bankLefts  = Set.fromList . confBankLefts  $ conf
  let bankRights = Set.fromList . confBankRights $ conf
  let channelGroups = Map.fromList . concat . map (\(ch,cs) -> map (,ch) cs) . confChannelGroups $ conf
  let actionGroups  = Map.fromList . concat . map (\(ch,cs) -> map (,ch) cs) . confActionGroups  $ conf
  mappings <- newIORef . mkArray =<< (sequence . map open . confBanks $ conf)
  currentMappingIndex <- newIORef 0
  let currentMapping = (!) <$> readIORef mappings <*> readIORef currentMappingIndex
  return State{..}


save :: String -> Mapping -> IO ()
save filename mapping = writeFile filename . encode $ mapping

open :: String -> IO Mapping
open filename = catch (either (const . throwIO . userError $ "Invalid file") return . decode =<< readFile filename) (const . return $ emptyMapping :: IOException -> IO Mapping)

