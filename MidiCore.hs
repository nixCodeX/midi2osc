{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

module MidiCore
  ( MidiControl (MidiButton, MidiFader, MidiUnknown)
  , MidiId (MidiId)
  , MidiValue (MidiButtonValue, MidiFaderValue)
  , buttonValueMap
  , faderValueMap
  , Control (Control)
  , ControlState (ControlState)
  , openDevice
  ) where

import Control.Monad ((<=<), when, filterM)
import Control.Exception (Exception, throwIO)
import Data.List (isPrefixOf)
import Data.Serialize (Serialize)
import Data.Word (Word8)
import GHC.Generics (Generic)

import Sound.PortMidi

newtype MidiId = MidiId Word8
  deriving (Show, Eq, Ord, Generic)
instance Serialize MidiId

data MidiValue = MidiButtonValue Bool | MidiFaderValue Word8
  deriving (Eq, Ord, Generic)
instance Serialize MidiValue
instance Show MidiValue where
  show (MidiButtonValue v) = show v
  show (MidiFaderValue  v) = padLeft 3 '0' (show v)

data MidiException = MidiInitialisationException
                   | DeviceNotFoundException String
                   | InputDeviceNotFoundException String
                   | OutputDeviceNotFoundException String
                   | InputDeviceOpeningException DeviceID
                   | OutputDeviceOpeningException DeviceID
  deriving (Show, Exception)

buttonValueMap :: (Bool -> Bool) -> MidiValue -> MidiValue
buttonValueMap f (MidiButtonValue v) = MidiButtonValue (f v)
buttonValueMap _ (MidiFaderValue  v) = MidiFaderValue v

faderValueMap :: (Word8 -> Word8) -> MidiValue -> MidiValue
faderValueMap f (MidiFaderValue v) = MidiFaderValue (f v)
faderValueMap _ (MidiButtonValue  v) = MidiButtonValue v

data MidiControl = MidiButton MidiId | MidiFader MidiId | MidiUnknown
  deriving (Eq, Ord, Generic)
instance Serialize MidiControl

instance Show MidiControl where
  show (MidiButton (MidiId n)) = "Button: " ++ padLeft 3 '0' (show n)
  show (MidiFader  (MidiId n)) = "Fader:  " ++ padLeft 3 '0' (show n)
  show  MidiUnknown            = "Unknown"

newtype Control = Control String
  deriving (Eq, Ord, Generic)
instance Serialize Control
instance Show Control where
  show (Control s) = s

data ControlState = ControlState Control MidiValue
instance Show ControlState where
  show (ControlState c v) = show c ++ ": " ++ show v

openDevice :: String -> IO (PMStream, PMStream)
openDevice d = do
  _ <- either (const . throwIO $ MidiInitialisationException) return =<< initialize
  devices <- filterM (return . isPrefixOf d . name <=< getDeviceInfo) . upTo =<< countDevices
  when (null devices) $ throwIO (DeviceNotFoundException d)
  inDevice <- maybe (throwIO (InputDeviceNotFoundException d)) return . head =<< filterM (return . input <=< getDeviceInfo) devices
  outDevice <- maybe (throwIO (OutputDeviceNotFoundException d)) return . head =<< filterM (return . output <=< getDeviceInfo) devices
  inStream <- either (const . throwIO . InputDeviceOpeningException $ inDevice) return =<< openInput inDevice
  outStream <- either (const . throwIO . OutputDeviceOpeningException $ outDevice) return =<< openOutput outDevice 0
  return (inStream, outStream)

