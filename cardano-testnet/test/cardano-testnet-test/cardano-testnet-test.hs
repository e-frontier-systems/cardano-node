{-# LANGUAGE FlexibleInstances #-}

module Main
  ( main
  ) where

import qualified Cardano.Crypto.Init as Crypto
import qualified Cardano.Testnet.Test.Cli.Babbage.LeadershipSchedule
import qualified Cardano.Testnet.Test.Cli.Babbage.StakeSnapshot
import qualified Cardano.Testnet.Test.Cli.Babbage.Transaction
import qualified Cardano.Testnet.Test.Cli.Conway.Plutus
import qualified Cardano.Testnet.Test.Cli.KesPeriodInfo
import qualified Cardano.Testnet.Test.Cli.Query
import qualified Cardano.Testnet.Test.Cli.QuerySlotNumber
import qualified Cardano.Testnet.Test.FoldEpochState
import qualified Cardano.Testnet.Test.Gov.CommitteeAddNew as Gov
import qualified Cardano.Testnet.Test.Gov.DRepDeposit as Gov
import qualified Cardano.Testnet.Test.Gov.DRepRetirement as Gov
import qualified Cardano.Testnet.Test.Gov.NoConfidence as Gov
import qualified Cardano.Testnet.Test.Gov.ProposeNewConstitution as Gov
import qualified Cardano.Testnet.Test.Gov.ProposeNewConstitutionSPO as Gov
import qualified Cardano.Testnet.Test.Gov.TreasuryGrowth as Gov
import qualified Cardano.Testnet.Test.Gov.TreasuryWithdrawal as Gov
import qualified Cardano.Testnet.Test.Node.Shutdown
import qualified Cardano.Testnet.Test.SanityCheck as LedgerEvents
import qualified Cardano.Testnet.Test.SubmitApi.Babbage.Transaction

import           Prelude

import qualified System.Environment as E
import           System.IO (BufferMode (LineBuffering), hSetBuffering, hSetEncoding, stdout, utf8)

import           Testnet.Property.Run (ignoreOnMacAndWindows, ignoreOnWindows)

import qualified Test.Tasty as T
import           Test.Tasty (TestTree)

tests :: IO TestTree
tests = do
  pure $ T.testGroup "test/Spec.hs"
    [ T.testGroup "Spec"
        [ T.testGroup "Ledger Events"
            [ ignoreOnWindows "Sanity Check" LedgerEvents.hprop_ledger_events_sanity_check
            , ignoreOnWindows "Treasury Growth" Gov.prop_check_if_treasury_is_growing
            -- TODO: Replace foldBlocks with checkLedgerStateCondition
            , T.testGroup "Governance"
                [ ignoreOnMacAndWindows "Committee Add New" Gov.hprop_constitutional_committee_add_new
                -- FIXME: This test is broken - drepActivity is not updated within the expeted period
                -- , ignoreOnWindows "DRep Activity" Gov.hprop_check_drep_activity
                , ignoreOnMacAndWindows "Committee Motion Of No Confidence"  Gov.hprop_gov_no_confidence
                , ignoreOnWindows "DRep Deposits" Gov.hprop_ledger_events_drep_deposits
                  -- FIXME Those tests are flaky
                  -- , ignoreOnWindows "InfoAction" LedgerEvents.hprop_ledger_events_info_action
                , ignoreOnWindows "DRep Retirement" Gov.hprop_drep_retirement
                , ignoreOnMacAndWindows "Propose And Ratify New Constitution" Gov.hprop_ledger_events_propose_new_constitution
                , ignoreOnWindows "Propose New Constitution SPO" Gov.hprop_ledger_events_propose_new_constitution_spo
                , ignoreOnWindows "Treasury Withdrawal" Gov.hprop_ledger_events_treasury_withdrawal
                ]
            , T.testGroup "Plutus"
                [ ignoreOnWindows "PlutusV3" Cardano.Testnet.Test.Cli.Conway.Plutus.hprop_plutus_v3]
            ]
        , T.testGroup "CLI"
          [ ignoreOnWindows "Shutdown" Cardano.Testnet.Test.Node.Shutdown.hprop_shutdown
          -- ShutdownOnSigint fails on Mac with
          -- "Log file: /private/tmp/tmp.JqcjW7sLKS/kes-period-info-2-test-30c2d0d8eb042a37/logs/test-spo.stdout.log had no logs indicating the relevant node has minted blocks."
          , ignoreOnMacAndWindows "Shutdown On Sigint" Cardano.Testnet.Test.Node.Shutdown.hprop_shutdownOnSigint
          -- ShutdownOnSlotSynced FAILS Still. The node times out and it seems the "shutdown-on-slot-synced" flag does nothing
          -- , ignoreOnWindows "ShutdownOnSlotSynced" Cardano.Testnet.Test.Node.Shutdown.hprop_shutdownOnSlotSynced
          , T.testGroup "Babbage"
              [ ignoreOnMacAndWindows "leadership-schedule" Cardano.Testnet.Test.Cli.Babbage.LeadershipSchedule.hprop_leadershipSchedule -- FAILS
              , ignoreOnWindows "stake-snapshot" Cardano.Testnet.Test.Cli.Babbage.StakeSnapshot.hprop_stakeSnapshot
              , ignoreOnWindows "transaction" Cardano.Testnet.Test.Cli.Babbage.Transaction.hprop_transaction
              ]
          -- TODO: Conway -  Re-enable when create-staked is working in conway again
          --, T.testGroup "Conway"
          --  [ ignoreOnWindows "stake-snapshot" Cardano.Testnet.Test.Cli.Conway.StakeSnapshot.hprop_stakeSnapshot
          --  ]
            -- Ignored on Windows due to <stdout>: commitBuffer: invalid argument (invalid character)
            -- as a result of the kes-period-info output to stdout.
          , ignoreOnWindows "kes-period-info" Cardano.Testnet.Test.Cli.KesPeriodInfo.hprop_kes_period_info
          , ignoreOnWindows "query-slot-number" Cardano.Testnet.Test.Cli.QuerySlotNumber.hprop_querySlotNumber
          , ignoreOnWindows "foldEpochState receives ledger state" Cardano.Testnet.Test.FoldEpochState.prop_foldEpochState
          , ignoreOnWindows "CliQueries" Cardano.Testnet.Test.Cli.Query.hprop_cli_queries
          ]
        ]
    , T.testGroup "SubmitApi"
        [ T.testGroup "Babbage"
            [ ignoreOnWindows "transaction" Cardano.Testnet.Test.SubmitApi.Babbage.Transaction.hprop_transaction
            ]
        ]
    ]

main :: IO ()
main = do
  Crypto.cryptoInit

  hSetBuffering stdout LineBuffering
  hSetEncoding stdout utf8
  args <- E.getArgs

  E.withArgs args $ tests >>= T.defaultMainWithIngredients T.defaultIngredients
