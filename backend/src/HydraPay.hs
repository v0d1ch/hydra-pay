-- | 
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}


module HydraPay where

{-
What is the path of head creation?
Init requires funds, and it requires that people

In simple terms we just need a list of participants
because we need to setup the nodes, then we need to init as one of the participants

The issue here is each participant needs fuel, and each participant needs a cardano key
and a hydra key.

As part of our usecase we can't have people entering their seed phrases. Which means
until we have external de/commit, we must use proxy addresses that the user can send funds to
this means that we likely have to provide endpoints to make this convenient!

So in essence creating a head is providing a list of addresses and participants
These addresses and participants will need to have fuel and fund things, and this

What is a Head?
A collection of nodes that may have state on L1
HeadId exists on-chain

Creating a head means sending the participant list

The backend needs to prepare translated addresses for each participant

State Management:

-}
import Prelude hiding ((.))
import Control.Category ((.))
import System.Process
import GHC.Generics
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as T
import Data.Int
import Data.Bool
import Data.List (intercalate)
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import qualified Data.Map as Map
import Data.Aeson as Aeson
import Data.Proxy
import Data.Pool
import Data.Maybe
import Database.Beam
import Database.Beam.Postgres
import qualified Database.Beam.AutoMigrate as BA
import Data.String.Interpolate ( i, iii )
import System.IO (IOMode(WriteMode), openFile)
import Network.WebSockets.Client
import qualified Network.WebSockets.Connection as WS

import Control.Concurrent

import Data.Text.Prettyprint.Doc
import Control.Monad.Log
import System.Directory

import Database.PostgreSQL.Simple as Pg
import Gargoyle
import Gargoyle.PostgreSQL (defaultPostgres)
import Gargoyle.PostgreSQL.Connect

import Data.Foldable
import Data.Traversable

import Control.Monad

import Hydra.Types
import Hydra.Devnet
import Hydra.ClientInput

import qualified Hydra.Types as HT

type HeadId = Int

data ProxyAddressesT f = ProxyAddress
  { proxyAddress_ownerAddress :: Columnar f T.Text
  , proxyAddress_address :: Columnar f T.Text

  , proxyAddress_cardanoVerificationKey :: Columnar f T.Text
  , proxyAddress_cardanoSigningKey :: Columnar f T.Text
  , proxyAddress_hydraVerificationKey :: Columnar f T.Text
  , proxyAddress_hydraSigningKey :: Columnar f T.Text
  }
  deriving (Generic, Beamable)

data HeadsT f = DbHead
  { head_name :: Columnar f T.Text
  , head_state :: Columnar f T.Text
  }
  deriving (Generic, Beamable)

-- NOTE So beam doesn't have many to many or uniqueness constraints
-- we would have to use beam-migrate or beam-automigrate to include these things as
-- they are properites of the database.
data HeadParticipantsT f = HeadParticipant
  { headParticipant_head :: PrimaryKey HeadsT f
  , headParticipant_proxy :: PrimaryKey ProxyAddressesT f
  }
  deriving (Generic, Beamable)

type ProxyAddress = ProxyAddressesT Identity

data HydraDB f = HydraDB
  { hydraDb_proxyAddresses :: f (TableEntity ProxyAddressesT)
  , hydraDb_heads :: f (TableEntity HeadsT)
  , hydraDb_headParticipants :: f (TableEntity HeadParticipantsT)
  }
  deriving (Generic, Database be)

instance Table ProxyAddressesT where
  data PrimaryKey ProxyAddressesT f = ProxyAddressID (Columnar f T.Text)
    deriving (Generic, Beamable)
  primaryKey = ProxyAddressID . proxyAddress_ownerAddress

instance Table HeadsT where
  data PrimaryKey HeadsT f = HeadID (Columnar f T.Text)
    deriving (Generic, Beamable)
  primaryKey = HeadID . head_name

instance Table HeadParticipantsT where
  data PrimaryKey HeadParticipantsT f = HeadParticipantID (PrimaryKey HeadsT f) (PrimaryKey ProxyAddressesT f)
    deriving (Generic, Beamable)
  primaryKey = HeadParticipantID <$> headParticipant_head <*> headParticipant_proxy

hydraDb :: DatabaseSettings Postgres HydraDB
hydraDb = defaultDbSettings

hydraDbAnnotated :: BA.AnnotatedDatabaseSettings Postgres HydraDB
hydraDbAnnotated = BA.defaultAnnotatedDbSettings hydraDb

hsSchema :: BA.Schema
hsSchema = BA.fromAnnotatedDbSettings hydraDbAnnotated (Proxy @'[])

hydraShowMigration :: Connection -> IO ()
hydraShowMigration conn =
  runBeamPostgres conn $ BA.printMigration $ BA.migrate conn hsSchema

hydraAutoMigrate :: Connection -> IO ()
hydraAutoMigrate = BA.tryRunMigrationsWithEditUpdate hydraDbAnnotated

withHydraPool :: (Pool Connection -> IO a) -> IO a
withHydraPool action = withDb "db" $ \pool -> do
  withResource pool $ \conn -> do
    hydraShowMigration conn
    hydraAutoMigrate conn
  action pool

proxyAddressExists :: Connection -> Address -> IO Bool
proxyAddressExists conn addr = do
  fmap isJust $ runBeamPostgres conn $ runSelectReturningOne $ select $ do
    pa <- all_ (hydraDb_proxyAddresses hydraDb)
    guard_ $ proxyAddress_ownerAddress pa ==. val_ addr
    pure pa

addProxyAddress :: (MonadIO m, MonadLog (WithSeverity (Doc ann)) m) => Address -> Connection -> m ()
addProxyAddress addr conn = do
  path <- liftIO getKeyPath
  keyInfo <- generateKeysIn path

  let
    cvk = _verificationKey . _cardanoKeys $ keyInfo
    csk = _signingKey . _cardanoKeys $ keyInfo
    hvk = _verificationKey . _hydraKeys $ keyInfo
    hsk = _signingKey . _hydraKeys $ keyInfo

  cardanoAddress <- liftIO $ getCardanoAddress $ _verificationKey . _cardanoKeys $ keyInfo

  liftIO $ runBeamPostgres conn $ runInsert $ insert (hydraDb_proxyAddresses hydraDb) $
    insertValues [ProxyAddress addr cardanoAddress (T.pack cvk) (T.pack csk) (T.pack hvk) (T.pack hsk)]
  pure ()

-- | The location where we store cardano and hydra keys
getKeyPath :: IO (FilePath)
getKeyPath = do
  createDirectoryIfMissing True path
  pure path
  where
    path = "keys"

data HeadCreate = HeadCreate
  { headCreate_name :: T.Text
  , headCreate_participants :: [Address]
  , headCreate_startNetwork :: Bool
  }
  deriving (Generic)

instance ToJSON HeadCreate
instance FromJSON HeadCreate

data HeadInit = HeadInit
  { headInit_name :: T.Text
  , headInit_participant :: Address
  }
  deriving (Eq, Show, Generic)

instance ToJSON HeadInit
instance FromJSON HeadInit

data HeadCommit = HeadCommit
  { headCommit_name :: T.Text
  , headCommit_participant :: T.Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON HeadCommit
instance FromJSON HeadCommit

withLogging = flip runLoggingT (print . renderWithSeverity id)

-- This is the API json type that we need to send back out
data HeadStatus = HeadStatus
  { headStatus_name :: T.Text
  , headStatus_running :: Bool
  , headStatus_status :: Status
  }
  deriving (Eq, Show, Generic)

instance ToJSON HeadStatus
instance FromJSON HeadStatus

data HydraPayError
  = InvalidPayload
  | HeadCreationFailed
  | NotEnoughParticipants
  | HeadExists HeadName
  | HeadDoesn'tExist
  | NetworkIsn'tRunning
  | FailedToBuildFundsTx
  | NotAParticipant
  | InsufficientFunds
  deriving (Eq, Show, Generic)

instance ToJSON HydraPayError
instance FromJSON HydraPayError

{-
What does it mean to get the head status?

Check if the network is running
Fetch status as last seen from the database
Scan the logs to actually have the network state
-}

{-
What does it mean to create a head?
Really just to list the participants and record that as a head that may exist
the Head could also be called created when it is actually initialized on L1
so we should have the different parts of getting to the init state

So creation in HydraPay terms is simply the intent to actually have one of these heads
To get to init a couple of things need to happen:

- Funds need to be sent to the proxy addresses: this constitutes an endpoint for getting the transaction
that will do this?

- Then we have to ensure everybody has Fuel outputs so that is likely another endpoint thing or maybe
they can be combined

- After that somebody just has to send in "Init" which is one of the valid operations you can do to your node
that request should be routed automatically

- Starting and stopping heads should be more or less automatic, we shouldn't worry about that for now
for now creating a head is analogous to running one, but we should be able to run a head by just
-}

getProxyAddressKeyInfo :: MonadIO m => Connection -> Address -> m (Maybe HydraKeyInfo)
getProxyAddressKeyInfo conn addr = liftIO $ do
  mpa <- runBeamPostgres conn $ runSelectReturningOne $ select $ do
    pa <- all_ (hydraDb_proxyAddresses hydraDb)
    guard_ $ proxyAddress_ownerAddress pa ==. val_ addr
    pure pa
  pure $ dbProxyToHydraKeyInfo <$> mpa


dbProxyToHydraKeyInfo :: ProxyAddress -> HydraKeyInfo
dbProxyToHydraKeyInfo pa = keyInfo
  where
    keyInfo =
      HydraKeyInfo
      (KeyPair (T.unpack $ proxyAddress_cardanoSigningKey pa) (T.unpack $ proxyAddress_cardanoVerificationKey pa))
      (KeyPair (T.unpack $ proxyAddress_hydraSigningKey pa) (T.unpack $ proxyAddress_hydraVerificationKey pa))

type HeadName = T.Text

-- | State we need to run/manage Heads
data State = State
  { _state_hydraInfo :: HydraSharedInfo
  , _state_proxyAddresses :: MVar (Map Address (Address, HydraKeyInfo))
  -- ^ This is really temporary it has the mapping from cardano address to proxy + keys
  , _state_heads :: MVar (Map HeadName Head)
  -- ^ This is really temporary until we stuff it all in a database
  , _state_networks :: MVar (Map HeadName Network)
  -- , _state_connectionPool :: Pool Connection -- We could ignore htis for now
  , _state_keyPath :: FilePath
  }

-- | A Hydra Head in Hydra Pay
data Head = Head
  { _head_name :: HeadName
  -- ^ Unique name of the Head
  , _head_participants :: Set Address
      --- Map Address (Address, HydraKeyInfo)
  , _head_status :: Status
  -- ^ The participants list with proxy addresses and not owner addresses
  }

data Status
  = Status_Pending
  | Status_Init
  | Status_Commiting
  | Status_Open
  | Status_Closed
  | Status_Fanout
  deriving (Eq, Show, Generic)

instance ToJSON Status
instance FromJSON Status

-- | A Hydra Node running as part of a network
data Node = Node
  { _node_handle :: ProcessHandle
  , _node_info :: HydraNodeInfo
  }

-- | The network of nodes that hold up a head
data Network = Network
  { _network_nodes :: Map Address Node
  , _network_monitor_thread :: ThreadId
  }

getHydraPayState :: (MonadIO m)
  => HydraSharedInfo
  -> m State
getHydraPayState hydraSharedInfo = do
  addrs <- liftIO $ newMVar mempty
  heads <- liftIO $ newMVar mempty
  networks <- liftIO $ newMVar mempty
  path <- liftIO $ getKeyPath
  pure $ State hydraSharedInfo addrs heads networks path

data Tx = Tx
  { txType :: T.Text
  , txDescription :: T.Text
  , txCborHex :: T.Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON Tx where
  toJSON (Tx t d c) =
    object [ "type" .= t
           , "description" .= d
           , "cborHex" .= c
           ]

instance FromJSON Tx where
  parseJSON = withObject "Tx" $ \v -> Tx
    <$> v .: "type"
    <*> v .: "description"
    <*> v .: "cborHex"

data TxType =
  Funds | Fuel
  deriving (Eq, Show)

isFuelType :: TxType -> Bool
isFuelType Fuel = True
isFuelType _ = False

buildAddTx :: MonadIO m => TxType -> State -> Address -> Lovelace -> m (Either HydraPayError Tx)
buildAddTx txType state fromAddr amount = do
  utxos <- queryAddressUTXOs fromAddr
  let
    txInAmounts = Map.mapMaybe (Map.lookup "lovelace" . HT.value) utxos
  (toAddr, _) <- addOrGetKeyInfo state fromAddr

  let
    fullAmount = sum txInAmounts
    txInCount = Map.size txInAmounts
  txBodyPath <- liftIO $ snd <$> getTempPath
  _ <- liftIO $ readCreateProcess (proc cardanoCliPath
                       (filter (/= "") $ [ "transaction"
                        , "build"
                        , "--babbage-era"
                        , "--cardano-mode"
                        ]
                        <> (concatMap (\txin -> ["--tx-in", T.unpack txin]) . Map.keys $ txInAmounts)
                        <>
                        [ "--tx-out"
                        , [i|#{toAddr}+#{amount}|]
                        ]
                        <> bool [] [ "--tx-out-datum-hash", T.unpack fuelMarkerDatumHash ] (isFuelType txType)
                        <>
                        [ "--change-address"
                        , T.unpack fromAddr
                        , "--testnet-magic"
                        , "42"
                        , "--out-file"
                        , txBodyPath
                        ])) { env = Just [("CARDANO_NODE_SOCKET_PATH", "devnet/node.socket")] }
    ""
  txResult <- liftIO $ readFile txBodyPath
  liftIO $ putStrLn txResult
  case Aeson.decode $ LBS.pack txResult of
    Just tx -> pure $ Right tx
    Nothing -> pure $ Left FailedToBuildFundsTx

initHead :: MonadIO m => State -> HeadInit -> m (Either HydraPayError ())
initHead state (HeadInit name addr) = do
  mNetwork <- getNetwork state name
  case mNetwork of
    Nothing -> pure $ Left NetworkIsn'tRunning
    Just network -> do
      (proxyAddr, _) <- addOrGetKeyInfo state addr
      case Map.lookup proxyAddr $ _network_nodes network of
        Nothing -> pure $ Left NotAParticipant
        Just node -> do
          let port = _apiPort $ _node_info node
          liftIO $ do
            runClient "localhost" port "/" $ \conn -> do
              WS.sendTextData conn ("{\"tag\":\"Init\",\"contestationPeriod\":60}" :: T.Text)
          pure $ Right ()

commitToHead :: MonadIO m => State -> HeadCommit -> m (Either HydraPayError ())
commitToHead state (HeadCommit name addr) = do
  mNetwork <- getNetwork state name
  case mNetwork of
    Nothing -> pure $ Left NetworkIsn'tRunning
    Just network -> do
      (proxyAddr, _) <- addOrGetKeyInfo state addr
      case Map.lookup proxyAddr $ _network_nodes network of
        Nothing -> pure $ Left NotAParticipant
        Just node -> do
          proxyFunds <- filterOutFuel <$> queryAddressUTXOs proxyAddr
          let port = _apiPort $ _node_info node
          liftIO $ do
            runClient "localhost" port "/" $ \conn -> do
              WS.sendTextData conn $ Aeson.encode $ Commit proxyFunds
          pure $ Right ()

createHead :: MonadIO m => State -> HeadCreate -> m (Either HydraPayError Head)
createHead state (HeadCreate name participants start) = do
  case null participants of
    True -> pure $ Left NotEnoughParticipants
    False -> do
      mHead <- lookupHead state name
      case mHead of
        Just _ -> pure $ Left $ HeadExists name
        Nothing -> do
          let head = Head name (Set.fromList participants) Status_Pending
          liftIO $ modifyMVar_ (_state_heads state) $ pure . Map.insert name head
          when start $ void $ startNetwork state head
          pure $ Right head

-- | Lookup head via name
lookupHead :: MonadIO m => State -> HeadName -> m (Maybe Head)
lookupHead state name = do
  liftIO $ withMVar (_state_heads state) (pure . Map.lookup name)

-- NOTE(skylar): Idempotent
-- | Generate a proxy address with keys,
addOrGetKeyInfo :: MonadIO m => State -> Address -> m (Address, HydraKeyInfo)
addOrGetKeyInfo state addr = do
  liftIO $ modifyMVar (_state_proxyAddresses state) $ \old -> do
    case Map.lookup addr old of
      Just info -> pure (old, info)
      Nothing -> do
        keyInfo <- withLogging $ generateKeysIn path
        proxyAddress <- liftIO $ getCardanoAddress $ _verificationKey . _cardanoKeys $ keyInfo
        let info = (proxyAddress, keyInfo)
        pure $ (Map.insert addr info old, info)
  where
    path = _state_keyPath state

getHeadStatus :: MonadIO m => State -> HeadName -> m (Either HydraPayError HeadStatus)
getHeadStatus state name = liftIO $ do
  mHead <- lookupHead state name
  case mHead of
    Nothing -> pure $ Left HeadDoesn'tExist
    Just (Head name _ status) -> do
      running <- isJust <$> getNetwork state name
      pure $ Right $ HeadStatus name running status

-- | Start a network for a given Head, trying to start a network that already exists is a no-op and you will just get the existing network
startNetwork :: MonadIO m => State -> Head -> m Network
startNetwork state (Head name participants _) = do
  mNetwork <- getNetwork state name
  case mNetwork of
    Just network -> pure network
    Nothing -> do
      proxyMap <- participantsToProxyMap state participants
      nodes <- (fmap . fmap) (uncurry Node) $ startHydraNetwork (_state_hydraInfo state) proxyMap

      let
        firstNodePort = _apiPort . _node_info . snd $ Map.elemAt 0 nodes
      liftIO $ putStrLn $ intercalate "\n" . fmap (show . _port . _node_info) . Map.elems $ nodes

      monitor <- liftIO $ forkIO $ do
        threadDelay 3000000
        runClient "localhost" firstNodePort "/" $ \conn -> forever $ do
          msg :: T.Text <- WS.receiveData conn
          putStrLn $ "Got message: " <> T.unpack msg
          let
            handleMsg m
              | T.isInfixOf "ReadyToCommit" m = Just Status_Init
              | T.isInfixOf "Commit" m = Just Status_Commiting
              | T.isInfixOf "HeadIsOpen" m = Just Status_Open
              | otherwise = Nothing

          case handleMsg msg of
            Just status -> do
              liftIO $ modifyMVar_ (_state_heads state) $ pure . Map.adjust (\h -> h { _head_status = status }) name
            Nothing -> pure ()

      let network = Network nodes monitor
      -- Add the network to the running networks mvar
      liftIO $ modifyMVar_ (_state_networks state) $ pure . Map.insert name network
      pure network

-- | This takes the set participants in a Head and gets their proxy equivalents as actual addresses
-- participating in the network are not the addresses registered in the head, but their proxies
participantsToProxyMap :: MonadIO m => State -> Set Address -> m (Map Address HydraKeyInfo)
participantsToProxyMap state participants = liftIO $ fmap Map.fromList $ for (Set.toList participants) $ addOrGetKeyInfo state

-- | Lookup the network associated with a head name
getNetwork :: MonadIO m => State -> HeadName -> m (Maybe Network)
getNetwork state name =
  liftIO $ withMVar (_state_networks state) (pure . Map.lookup name)

startHydraNetwork :: (MonadIO m)
  => HydraSharedInfo
  -> Map Address HydraKeyInfo
  -> m (Map Address (ProcessHandle, HydraNodeInfo))
startHydraNetwork sharedInfo actors = do
  liftIO $ createDirectoryIfMissing True "demo-logs"
  liftIO $ sequence . flip Map.mapWithKey nodes $ \name node -> do
    logHndl <- openFile [iii|demo-logs/hydra-node-#{name}.log|] WriteMode
    errHndl <- openFile [iii|demo-logs/hydra-node-#{name}.error.log|] WriteMode
    let cp = (mkHydraNodeCP sharedInfo node (filter ((/= _nodeId node) . _nodeId) (Map.elems nodes)))
             { std_out = UseHandle logHndl
             , std_err = UseHandle errHndl
             }
    (_,_,_,handle) <- createProcess cp
    pure (handle, node)
  where
    portNum p n = p * 1000 + n
    node (n, (name, keys)) =
      ( name
      , HydraNodeInfo n (portNum 5 n) (portNum 9 n) (portNum 6 n) keys
      )
    nodes = Map.fromList . fmap node $ zip [1 ..] (Map.toList actors)

data HydraSharedInfo = HydraSharedInfo
  { _hydraScriptsTxId :: String
  , _ledgerGenesis :: FilePath
  , _ledgerProtocolParameters :: FilePath
  , _networkId :: String
  , _nodeSocket :: FilePath
  }

data HydraNodeInfo = HydraNodeInfo
  { _nodeId :: Int
  , _port :: Int
  -- ^ The port this node is running on
  , _apiPort :: Int
  -- ^ The port that this node is serving its pub/sub websockets api on
  , _monitoringPort :: Int
  , _keys :: HydraKeyInfo
  }

-- | Takes the node participant and the list of peers
mkHydraNodeCP :: HydraSharedInfo -> HydraNodeInfo -> [HydraNodeInfo] -> CreateProcess
mkHydraNodeCP sharedInfo node peers =
  (proc hydraNodePath $ sharedArgs sharedInfo <> nodeArgs node <> concatMap peerArgs peers)
  { std_out = Inherit
  }

sharedArgs :: HydraSharedInfo -> [String]
sharedArgs (HydraSharedInfo hydraScriptsTxId ledgerGenesis protocolParams networkId nodeSocket) =
  [ "--ledger-genesis"
  , ledgerGenesis
  , "--ledger-protocol-parameters"
  , protocolParams
  , "--network-id"
  , networkId
  , "--node-socket"
  , nodeSocket
  , "--hydra-scripts-tx-id"
  , hydraScriptsTxId
  ]

nodeArgs :: HydraNodeInfo -> [String]
nodeArgs (HydraNodeInfo nodeId port apiPort monitoringPort
           (HydraKeyInfo
            (KeyPair cskPath _cvkPath)
            (KeyPair hskPath _hvkPath))) =
  [ "--node-id"
  , show nodeId
  , "--port"
  , show port
  , "--api-port"
  , show apiPort
  , "--monitoring-port"
  , show monitoringPort
  , "--hydra-signing-key"
  , hskPath
  , "--cardano-signing-key"
  , cskPath
  ]

peerArgs :: HydraNodeInfo -> [String]
peerArgs ni =
  [ "--peer"
  , [i|127.0.0.1:#{_port ni}|]
  , "--hydra-verification-key"
  , _verificationKey . _hydraKeys . _keys $ ni
  , "--cardano-verification-key"
  , _verificationKey . _cardanoKeys . _keys $ ni
  ]

cardanoNodeCreateProcess :: CreateProcess
cardanoNodeCreateProcess =
  (proc cardanoNodePath
   [ "run"
   , "--config"
   , "devnet/cardano-node.json"
   , "--topology"
   , "devnet/topology.json"
   , "--database-path"
   , "devnet/db"
   , "--socket-path"
   , "devnet/node.socket"
   , "--shelley-operational-certificate"
   , "devnet/opcert.cert"
   , "--shelley-kes-key"
   , "devnet/kes.skey"
   , "--shelley-vrf-key"
   , "devnet/vrf.skey"
   ]) { std_out = CreatePipe
      }
