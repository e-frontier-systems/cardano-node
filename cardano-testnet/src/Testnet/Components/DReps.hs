{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Testnet.Components.DReps
  ( generateDRepKeyPair
  , generateRegistrationCertificate
  , createDRepRegistrationTxBody
  , signTx
  , submitTx
  , failToSubmitTx
  , getDRepDeposits
  ) where

import           Cardano.Api (AnyCardanoEra (..), ConwayEra, EpochNo, FileDirection (In),
                   NodeConfigFile, ShelleyBasedEra (..), SocketPath, renderTxIn)
import           Cardano.Api.Ledger (Coin (..), DRepState (..))

import           Prelude

import           Control.Monad (void)
import           Control.Monad.Catch (MonadCatch)
import           Control.Monad.IO.Class (MonadIO)
import qualified Data.Text as Text
import           GHC.IO.Exception (ExitCode (..))
import           GHC.Stack (HasCallStack)
import qualified GHC.Stack as GHC
import           System.FilePath ((</>))

import           Testnet.Components.Query (EpochStateView, findLargestUtxoForPaymentKey,
                   waitForDRepsAndGetState)
import qualified Testnet.Process.Run as H
import           Testnet.Runtime (PaymentKeyInfo (paymentKeyInfoAddr), PaymentKeyPair (..))
import           Testnet.Start.Types (anyEraToString)

import           Hedgehog (MonadTest)
import qualified Hedgehog.Extras as H


-- | Generates a key pair for a decentralized representative (DRep) using @cardano-cli@.
--
-- The function takes three parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'work': Base directory path where keys will be stored.
-- * 'prefix': Name for the subfolder that will be created under 'work' folder to store the output keys.
--
-- Returns the generated 'PaymentKeyPair' containing paths to the verification and
-- signing key files.
generateDRepKeyPair :: (MonadTest m, MonadCatch m, MonadIO m, HasCallStack) => H.ExecConfig -> FilePath -> String -> m PaymentKeyPair
generateDRepKeyPair execConfig work prefix = do
  baseDir <- H.createDirectoryIfMissing $ work </> prefix
  let dRepKeyPair = PaymentKeyPair { paymentVKey = baseDir </> "verification.vkey"
                                   , paymentSKey = baseDir </> "signature.skey"
                                   }
  void $ H.execCli' execConfig [ "conway", "governance", "drep", "key-gen"
                               , "--verification-key-file", paymentVKey dRepKeyPair
                               , "--signing-key-file", paymentSKey dRepKeyPair
                               ]
  return dRepKeyPair

-- DRep registration certificate generation

newtype DRepRegistrationCertificate = DRepRegistrationCertificate { registrationCertificateFile :: FilePath }

-- | Generates a registration certificate for a decentralized representative (DRep)
-- using @cardano-cli@.
--
-- The function takes five parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'work': Base directory path where the certificate file will be stored.
-- * 'prefix': Prefix for the output certificate file name. The extension will be @.regcert@.
-- * 'drepKeyPair': Payment key pair associated with the DRep. Can be generated using
--                  'generateDRepKeyPair'.
-- * 'depositAmount': Deposit amount required for DRep registration. The right amount
--                    can be obtained using 'getMinDRepDeposit'.
--
-- Returns the generated 'DRepRegistrationCertificate' containing the file path to
-- the registration certificate.
generateRegistrationCertificate
  :: (MonadTest m, MonadCatch m, MonadIO m, HasCallStack)
  => H.ExecConfig
  -> FilePath
  -> String
  -> PaymentKeyPair
  -> Integer
  -> m DRepRegistrationCertificate
generateRegistrationCertificate execConfig work prefix drepKeyPair depositAmount = do
  let dRepRegistrationCertificate = DRepRegistrationCertificate (work </> prefix <> ".regcert")
  void $ H.execCli' execConfig [ "conway", "governance", "drep", "registration-certificate"
                               , "--drep-verification-key-file", paymentVKey drepKeyPair
                               , "--key-reg-deposit-amt", show @Integer depositAmount
                               , "--out-file", registrationCertificateFile dRepRegistrationCertificate
                               ]
  return dRepRegistrationCertificate

-- DRep registration transaction composition (without signing)

newtype TxBody = TxBody { txBodyFile :: FilePath }

-- | Composes a decentralized representative (DRep) registration transaction body
--   (without signing) using @cardano-cli@.
--
-- This function takes seven parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'epochStateView': Current epoch state view for transaction building. It can be obtained
--                     using the 'getEpochStateView' function.
-- * 'sbe': The Shelley-based era (e.g., 'ShelleyEra') in which the transaction will be constructed.
-- * 'work': Base directory path where the transaction body file will be stored.
-- * 'prefix': Prefix for the output transaction body file name. The extension will be @.txbody@.
-- * 'drepRegCert': The registration certificate for the DRep, obtained using
--                  'generateRegistrationCertificate'.
-- * 'wallet': Payment key information associated with the transaction,
--             as returned by 'cardanoTestnetDefault'.
--
-- Returns the generated 'TxBody' containing the file path to the transaction body.
createDRepRegistrationTxBody
  :: (H.MonadAssertion m, MonadTest m, MonadCatch m, MonadIO m)
  => H.ExecConfig
  -> EpochStateView
  -> ShelleyBasedEra era
  -> FilePath
  -> String
  -> DRepRegistrationCertificate
  -> PaymentKeyInfo
  -> m TxBody
createDRepRegistrationTxBody execConfig epochStateView sbe work prefix drepRegCert wallet = do
  let dRepRegistrationTxBody = TxBody (work </> prefix <> ".txbody")
  walletLargestUTXO <- findLargestUtxoForPaymentKey epochStateView sbe wallet
  void $ H.execCli' execConfig
    [ "conway", "transaction", "build"
    , "--change-address", Text.unpack $ paymentKeyInfoAddr wallet
    , "--tx-in", Text.unpack $ renderTxIn walletLargestUTXO
    , "--certificate-file", registrationCertificateFile drepRegCert
    , "--witness-override", show @Int 2
    , "--out-file", txBodyFile dRepRegistrationTxBody
    ]
  return dRepRegistrationTxBody

-- Transaction signing

newtype SignedTx = SignedTx { signedTxFile :: FilePath }

-- | Calls @cardano-cli@ to signs a transaction body using the specified key pairs.
--
-- This function takes five parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'cEra': Specifies the current Cardano era.
-- * 'work': Base directory path where the signed transaction file will be stored.
-- * 'prefix': Prefix for the output signed transaction file name. The extension will be @.tx@.
-- * 'txBody': Transaction body to be signed, obtained using 'createDRepRegistrationTxBody' or similar.
-- * 'signatoryKeyPairs': List of payment key pairs used for signing the transaction.
--
-- Returns the generated 'SignedTx' containing the file path to the signed transaction file.
signTx :: (MonadTest m, MonadCatch m, MonadIO m)
  => H.ExecConfig
  -> AnyCardanoEra
  -> FilePath
  -> String
  -> TxBody
  -> [PaymentKeyPair]
  -> m SignedTx
signTx execConfig cEra work prefix txBody signatoryKeyPairs = do
  let signedTx = SignedTx (work </> prefix <> ".tx")
  void $ H.execCli' execConfig $
    [ anyEraToString cEra, "transaction", "sign"
    , "--tx-body-file", txBodyFile txBody
    ] ++ (concat [["--signing-key-file", paymentSKey kp] | kp <- signatoryKeyPairs]) ++
    [ "--out-file", signedTxFile signedTx
    ]
  return signedTx

-- | Submits a signed transaction using @cardano-cli@.
--
-- This function takes two parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'cEra': Specifies the current Cardano era.
-- * 'signedTx': Signed transaction to be submitted, obtained using 'signTx'.
submitTx
  :: (MonadTest m, MonadCatch m, MonadIO m)
  => H.ExecConfig
  -> AnyCardanoEra
  -> SignedTx
  -> m ()
submitTx execConfig cEra signedTx =
  void $ H.execCli' execConfig
    [ anyEraToString cEra, "transaction", "submit"
    , "--tx-file", signedTxFile signedTx
    ]

-- | Attempts to submit a transaction that is expected to fail using @cardano-cli@.
--
-- This function takes two parameters:
--
-- * 'execConfig': Specifies the CLI execution configuration.
-- * 'cEra': Specifies the current Cardano era.
-- * 'signedTx': Signed transaction to be submitted, obtained using 'signTx'.
--
-- If the submission fails (the expected behavior), the function succeeds.
-- If the submission succeeds unexpectedly, it raises a failure message that is
-- meant to be caught by @Hedgehog@.
failToSubmitTx
  :: (MonadTest m, MonadCatch m, MonadIO m)
  => H.ExecConfig
  -> AnyCardanoEra
  -> SignedTx
  -> m ()
failToSubmitTx execConfig cEra signedTx = GHC.withFrozenCallStack $ do
  (exitCode, _, _) <- H.execFlexAny' execConfig "cardano-cli" "CARDANO_CLI"
                                     [ anyEraToString cEra, "transaction", "submit"
                                     , "--tx-file", signedTxFile signedTx
                                     ]
  case exitCode of
    ExitSuccess -> H.failMessage GHC.callStack "Transaction submission was expected to fail but it succeeded"
    _ -> return ()

-- | Obtains a list of deposits made by decentralized representatives (DReps) under specified conditions.
--
-- This function takes five parameters:
--
-- * 'sbe': A 'ShelleyBasedEra' witness that this is the 'ConwayEra'.
-- * 'nodeConfigFile': The FoldBlocks configuration file as returned by 'cardanoTestnetDefault'.
-- * 'socketPath': Path to the socket file for communicating with the node.
-- * 'maxEpoch': The timeout epoch by which the exact required number of DReps must be reached.
-- * 'expectedDRepsNb': Expected number of DReps. If not reached by 'maxEpoch', the test fails.
--
-- If the expected number of DReps is attained by 'maxEpoch', the function returns
-- the list of the amounts deposited by each DReps when the expected number of registered DReps
-- was attained. Otherwise, the test fails.
getDRepDeposits ::
  (HasCallStack, MonadCatch m, MonadIO m, MonadTest m)
  => ShelleyBasedEra ConwayEra
  -> NodeConfigFile In
  -> SocketPath
  -> EpochNo
  -> Int
  -> m (Maybe [Integer])
getDRepDeposits sbe nodeConfigFile socketPath maxEpoch expectedDRepsNb = do
  mDRepInfo <- waitForDRepsAndGetState sbe nodeConfigFile socketPath maxEpoch expectedDRepsNb
  return $ map (unCoin . drepDeposit) <$> mDRepInfo
