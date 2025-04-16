module TokenCred exposing
    ( findWithdrawalRedeemerIndex
    , checkOwnership, ScriptConfig, TokenProof, TokenOwner(..)
    )

{-| Helper functions to interact with the token-cred authentication scripts.

@docs findWithdrawalRedeemerIndex

@docs checkOwnership, ScriptConfig, TokenProof, TokenOwner

-}

import Bytes.Comparable as Bytes exposing (Bytes)
import Bytes.Map exposing (BytesMap)
import Cardano.Address as Address exposing (Credential(..), CredentialHash, NetworkId, StakeAddress)
import Cardano.Data as Data exposing (Data)
import Cardano.MultiAsset exposing (PolicyId)
import Cardano.Redeemer as Redeemer exposing (Redeemer)
import Cardano.Script as Script exposing (PlutusScript)
import Cardano.TxContext exposing (TxContext)
import Cardano.TxIntent exposing (TxIntent(..), TxOtherInfo(..))
import Cardano.Utxo as Utxo exposing (Output, OutputReference)
import Cardano.Witness as Witness
import Dict.Any
import Integer
import List.Extra
import Natural exposing (Natural)


{-| Find the index of the withdrawal redeemer in the script context
corresponding to the token-cred withdrawal script.
-}
findWithdrawalRedeemerIndex : Bytes CredentialHash -> List Redeemer -> List ( StakeAddress, Natural ) -> Maybe Int
findWithdrawalRedeemerIndex tokenCredScriptHash redeemers withdrawals =
    let
        -- Check if the current redeemer is the one of the token-cred script
        isTokenCredWithdrawalRedeemer redeemer =
            (redeemer.tag == Redeemer.Reward)
                && (Just redeemer.index == withdrawalIndex)

        withdrawalIndex =
            List.Extra.findIndex
                (\( { stakeCredential }, _ ) -> stakeCredential == ScriptHash tokenCredScriptHash)
                withdrawals
    in
    List.Extra.findIndex isTokenCredWithdrawalRedeemer redeemers


type alias ScriptConfig =
    { hash : Bytes CredentialHash
    , plutus : PlutusScript
    }


type alias TokenProof =
    { policyId : Bytes PolicyId
    , ownerType : TokenOwner
    }


type TokenOwner
    = SpentToken
    | ReferencedTokenAtPubkeyAddress
    | ReferencedTokenAtScriptAddress { withdrawAmount : Natural, scriptWitness : Witness.Script }


{-| Build the TxIntent leveraging the token-cred withdrawal script
to verify ownership proofs of the provided tokens.

WARNING: It’s your responsibility to make sure there is no duplicate token.
It’s also your responsability to guarantee that UTxO references are present in localStateUtxos.
TODO: Maybe switch to return a Result with errors in case it’s not the case.

This function automates the discovery of the relevant indexes
to be provided to the redeemer thanks to its access to the TxContext.

-}
checkOwnership : NetworkId -> ScriptConfig -> Utxo.RefDict Output -> List TokenProof -> ( List TxIntent, List TxOtherInfo )
checkOwnership networkId scriptConfig localStateUtxos tokenProofs =
    let
        -- Helper function creating one redeemer pair for the token-cred withdrawal script
        policyRedeemerEntry : TxContext -> TokenProof -> ( Data, Data )
        policyRedeemerEntry txContext { policyId, ownerType } =
            case ownerType of
                -- If the token is spent, we provide its UTxO index in the inputs
                SpentToken ->
                    ( Data.Bytes <| Bytes.toAny policyId
                    , Data.Constr Natural.one [ Data.Int <| Integer.fromSafeInt <| indexOfInputHoldingToken policyId txContext.inputs ]
                    )

                -- Otherwise, the token is just referenced, we provide its UTxO index in the reference inputs
                _ ->
                    ( Data.Bytes <| Bytes.toAny policyId
                    , Data.Constr Natural.zero [ Data.Int <| Integer.fromSafeInt <| indexOfInputHoldingToken policyId txContext.referenceInputs ]
                    )

        indexOfInputHoldingToken policyId inputs =
            inputs
                |> List.Extra.findIndex (\( _, output ) -> Bytes.Map.member policyId output.amount.assets)
                |> Maybe.withDefault -1

        -- Helper definition to create the Plutus script witness for the main token-cred withdrawal script
        witness : Witness.PlutusScript
        witness =
            { script =
                ( Script.plutusVersion scriptConfig.plutus
                , Witness.ByValue <| Script.cborWrappedBytes scriptConfig.plutus
                )
            , redeemerData =
                \txContext -> Data.Map (List.map (policyRedeemerEntry txContext) tokenProofs)

            -- The token is hold in a UTxO in our wallet,
            -- so we need to add our payment credential to the required signers.
            , requiredSigners =
                List.filterMap extractTokenKeyHolder tokenProofs
            }

        -- Helper function looking for the pubkey credential currently owning that token.
        -- Returns Nothing if the token is held by a script.
        -- since in that case the contract doesn’t need looking for proof, it’s in the pudding, euh spending.
        extractTokenKeyHolder : TokenProof -> Maybe (Bytes CredentialHash)
        extractTokenKeyHolder tokenProof =
            case tokenProof.ownerType of
                ReferencedTokenAtPubkeyAddress ->
                    relevantOutputs
                        |> List.Extra.find (\output -> Bytes.Map.member tokenProof.policyId output.amount.assets)
                        |> Maybe.andThen (\output -> Address.extractPubKeyHash output.address)

                _ ->
                    Nothing

        -- Subset of all outputs in the local state that are relevant, meaning they contain some token cred.
        relevantOutputs : List Output
        relevantOutputs =
            Dict.Any.values relevantUtxos

        -- Look for the UTxOs containing any of the token creds
        relevantUtxos : Utxo.RefDict Output
        relevantUtxos =
            localStateUtxos
                |> Dict.Any.filter (\_ output -> outputContainsSomeTokenProof output)

        outputContainsSomeTokenProof output =
            Bytes.Map.keys output.amount.assets
                |> List.any (\assetPolicyId -> Bytes.Map.member assetPolicyId tokenProofsAsMap)

        tokenProofsAsMap : BytesMap PolicyId TokenOwner
        tokenProofsAsMap =
            List.map (\{ policyId, ownerType } -> ( policyId, ownerType )) tokenProofs
                |> Bytes.Map.fromList

        -- Prepare the list of UTxOs to be added to the reference inputs
        -- because they hold the tokens used as credential
        referencedOutputs : List OutputReference
        referencedOutputs =
            tokenProofs
                |> List.filterMap
                    (\tokenProof ->
                        case tokenProof.ownerType of
                            SpentToken ->
                                -- Discard if token is spent
                                Nothing

                            _ ->
                                -- Look for the output ref if the token is referenced
                                Dict.Any.toList relevantUtxos
                                    |> List.Extra.find (\( _, output ) -> Bytes.Map.member tokenProof.policyId output.amount.assets)
                                    |> Maybe.map (\( ref, _ ) -> ref)
                    )

        -- Prepare the withdraw intents for each token held at a script address
        withdrawIntentsForTokensAtScriptAddresses : List TxIntent
        withdrawIntentsForTokensAtScriptAddresses =
            tokenProofs
                |> List.filterMap
                    (\tokenProof ->
                        case tokenProof.ownerType of
                            ReferencedTokenAtScriptAddress { withdrawAmount, scriptWitness } ->
                                Just <|
                                    WithdrawRewards
                                        { stakeCredential =
                                            { networkId = networkId
                                            , stakeCredential = ScriptHash tokenProof.policyId
                                            }
                                        , amount = withdrawAmount
                                        , scriptWitness = Just scriptWitness
                                        }

                            _ ->
                                Nothing
                    )
    in
    -- Main token-cred withdrawal
    ( WithdrawRewards
        { stakeCredential =
            { networkId = networkId
            , stakeCredential = ScriptHash scriptConfig.hash
            }
        , amount = Natural.zero
        , scriptWitness = Just <| Witness.Plutus witness
        }
        -- Additional withdrawals for every referenced token at a script address
        :: withdrawIntentsForTokensAtScriptAddresses
      -- Create a TxOtherIntent for each reference output containing one of the tokens
    , List.map TxReferenceInput referencedOutputs
    )
