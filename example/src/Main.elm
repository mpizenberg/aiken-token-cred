port module Main exposing (main)

import Browser
import Bytes.Comparable as Bytes exposing (Bytes)
import Bytes.Map
import Cardano.Address as Address exposing (Address, Credential(..), CredentialHash, NetworkId(..))
import Cardano.Cip30 as Cip30
import Cardano.Data as Data
import Cardano.Script as Script exposing (PlutusScript, PlutusVersion(..), ScriptCbor)
import Cardano.Transaction as Transaction exposing (Transaction)
import Cardano.TxExamples
import Cardano.TxIntent as TxIntent exposing (CertificateIntent(..), SpendSource(..), TxFinalized, TxIntent(..), TxOtherInfo(..))
import Cardano.Uplc as Uplc
import Cardano.Utxo as Utxo exposing (Output, OutputReference, TransactionId)
import Cardano.Value as Value
import Cardano.Witness as Witness
import Dict.Any
import Html exposing (Html, button, div, text)
import Html.Attributes as HA exposing (height, src)
import Html.Events as HE exposing (onClick)
import Http
import Integer
import Json.Decode as JD exposing (Decoder, Value)
import List.Extra
import Natural
import TokenCred exposing (TokenOwner(..))


tokenCredScriptHash =
    -- Constant retrieved from the aiken-token-cred blueprint
    Bytes.fromHexUnchecked "3f64a17e7dcb294ede555c607ba879671155e1807d5ad8e7b556b71a"


tokenCredScriptBytes =
    -- Constant retrieved from the aiken-token-cred blueprint
    Bytes.fromHexUnchecked "59045001010029800aba4aba2aba1aba0aab9faab9eaab9dab9cab9a4888888888c966002646465300130073754003370e90004c02c00e601600491112cc004cdc3a400800913259800801402626464660020020044464b30010028cc0048c054c0580066eb0c050c044dd5003cdd6180a180a980a980a980a980a980a980a980a98089baa0079bab30143015301530153015301530153011375400e9111191919800800805112cc00400629462b30019800980d800c896600200314bd7044cc070c064c074004cc008008c07800501b488c8cc00400400c896600200314a115980099b8f375c603e00200714a31330020023020001406480ea444b30010028a6103d87a80008acc004c048006266e9520003301d301e0024bd70466002007301f00299b80001480050032030407091114c004dd7180d8024c0700126006007300100148888c966002603060406ea8012264b3001301930213754003132598009980498019bab30123023375400200f13259800980d98119baa0018998050089bae302730243754003132330010010112259800800c528456600266ebcc094c0a400400e2946266004004605400281190272042302630233754604c60466ea80062a6604292139657870656374206c6973742e686173286173736574732e706f6c6963696573286f75747075742e76616c7565292c20706f6c6963795f69642900164080604a604c60446ea8c094c088dd5000c54cc08124012d65787065637420536f6d6528696e70757429203d206c6973742e6174287265665f696e707574732c20696478290016407c660040186eb4c090c084dd500244c966002603260426ea800626601060046eacc044c088dd51812981318111baa30253022375400200d153302049013865787065637420536f6d6528496e707574207b206f75747075742c202e2e207d29203d206c6973742e617428696e707574732c20696478290016407c6600401e6eb4c090c084dd5002203c230030012266004004603800314a080a90191bac300430153754016899192cc00400601f00f807c03e26644b3001001899912cc004c038006264b300100180a44c96600200301580ac056264b3001301e003802c05901b1bad00180aa03c301b0014064602e6ea800e2b30013370e9001000c4c9660020030148992cc00400602b01580ac4c966002603c00700580b2036375a0030154078603600280c8c05cdd5001c04d014202813005301900630143754003011808c04602280d0dd70009809801203030110013014002404860040046eac00a013009804a024300f300c375400b15980099b87480180122646644b300130060018a518acc004cdc3a400400314a314a0806100c1bad3010001300c37546020602200260186ea80162941009201218051805800980500098029baa00b8a4d15330034911856616c696461746f722072657475726e65642066616c7365001365640082a6600492012072656465656d65723a2050616972733c506f6c69637949642c20496e6465783e001601"


main =
    -- The main entry point of our app
    -- More info about that in the Browser package docs:
    -- https://package.elm-lang.org/packages/elm/browser/latest/
    Browser.element
        { init = init
        , update = update
        , subscriptions = \_ -> fromWallet WalletMsg
        , view = view
        }


port toWallet : Value -> Cmd msg


port fromWallet : (Value -> msg) -> Sub msg



-- #########################################################
-- MODEL
-- #########################################################


type Model
    = Startup
    | WalletDiscovered (List Cip30.WalletDescriptor)
    | WalletLoading
        { wallet : Cip30.Wallet
        , utxos : List Cip30.Utxo
        }
    | WalletLoaded LoadedWallet { errors : String }
    | BlueprintLoaded LoadedWallet (List ScriptBlueprint) { errors : String }
    | ParametersSet AppContext { errors : String }
    | TokenMintingDone AppContext { txId : Bytes TransactionId, errors : String }
    | LockingDone AppContext { txId : Bytes TransactionId, errors : String }
    | UnlockingDone AppContext { txId : Bytes TransactionId, errors : String }
    | TokenBurningDone AppContext { txId : Bytes TransactionId, errors : String }
    | Signing AppContext Action { tx : TxFinalized, errors : String }
    | Submitting AppContext Action { tx : Transaction, errors : String }


type alias LoadedWallet =
    { wallet : Cip30.Wallet
    , utxos : Utxo.RefDict Output
    , changeAddress : Address
    }


type alias ScriptBlueprint =
    { name : String
    , scriptBytes : Bytes ScriptCbor
    , hash : Bytes CredentialHash
    , hasParams : Bool
    }


type alias AppContext =
    { loadedWallet : LoadedWallet
    , localStateUtxos : Utxo.RefDict Output
    , tokenCredScript : { hash : Bytes CredentialHash, plutus : PlutusScript }
    , uniqueMint : { pickedUtxo : OutputReference, appliedScript : PlutusScript }
    , lockScript : { address : Address, plutus : PlutusScript }
    }


type Action
    = Registering
    | MintingTokenKey
    | BurningTokenKey
    | Locking
    | Unlocking


init : () -> ( Model, Cmd Msg )
init _ =
    ( Startup
    , toWallet <| Cip30.encodeRequest Cip30.discoverWallets
    )


setError : String -> Model -> Model
setError e model =
    let
        _ =
            Debug.log "ERROR" e
    in
    case model of
        Startup ->
            model

        WalletDiscovered _ ->
            model

        WalletLoading _ ->
            model

        WalletLoaded loadedWallet _ ->
            WalletLoaded loadedWallet { errors = e }

        BlueprintLoaded loadedWallet unappliedScript _ ->
            BlueprintLoaded loadedWallet unappliedScript { errors = e }

        ParametersSet appContext _ ->
            ParametersSet appContext { errors = e }

        TokenMintingDone appContext { txId } ->
            TokenMintingDone appContext { txId = txId, errors = e }

        LockingDone appContext { txId } ->
            LockingDone appContext { txId = txId, errors = e }

        UnlockingDone appContext { txId } ->
            UnlockingDone appContext { txId = txId, errors = e }

        TokenBurningDone appContext { txId } ->
            TokenBurningDone appContext { txId = txId, errors = e }

        Signing ctx action { tx } ->
            Signing ctx action { tx = tx, errors = e }

        Submitting ctx action { tx } ->
            Submitting ctx action { tx = tx, errors = e }



-- #########################################################
-- UPDATE
-- #########################################################


type Msg
    = WalletMsg Value
    | ConnectButtonClicked { id : String }
    | LoadBlueprintButtonClicked
    | GotBlueprint (Result Http.Error (List ScriptBlueprint))
    | PickUtxoParam
    | MintTokenKeyButtonClicked
    | LockButtonClicked
    | RegisterButtonClicked
    | UnlockButtonClicked
    | BurnTokenKeyButtonClicked
    | TrySubmitAgainButtonClicked


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model ) of
        ( WalletMsg value, _ ) ->
            case ( JD.decodeValue Cip30.responseDecoder value, model ) of
                -- We just discovered available wallets
                ( Ok (Cip30.AvailableWallets wallets), Startup ) ->
                    ( WalletDiscovered wallets, Cmd.none )

                -- We just connected to the wallet, let’s ask for the available utxos
                ( Ok (Cip30.EnabledWallet wallet), WalletDiscovered _ ) ->
                    ( WalletLoading { wallet = wallet, utxos = [] }
                    , toWallet <| Cip30.encodeRequest <| Cip30.getUtxos wallet { amount = Nothing, paginate = Nothing }
                    )

                -- We just received the utxos, let’s ask for the main change address of the wallet
                ( Ok (Cip30.ApiResponse _ (Cip30.WalletUtxos utxos)), WalletLoading { wallet } ) ->
                    ( WalletLoading { wallet = wallet, utxos = utxos }
                    , toWallet (Cip30.encodeRequest (Cip30.getChangeAddress wallet))
                    )

                ( Ok (Cip30.ApiResponse _ (Cip30.ChangeAddress address)), WalletLoading { wallet, utxos } ) ->
                    ( WalletLoaded { wallet = wallet, utxos = Utxo.refDictFromList utxos, changeAddress = address } { errors = "" }
                    , Cmd.none
                    )

                ( Ok (Cip30.ApiResponse _ (Cip30.SignedTx vkeywitnesses)), Signing ctx action { tx } ) ->
                    let
                        -- Update the signatures of the Tx with the wallet response
                        signedTx =
                            Transaction.updateSignatures (\_ -> Just vkeywitnesses) tx.tx
                                |> Debug.log "Signed Tx"
                    in
                    ( Submitting ctx action { tx = signedTx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.submitTx ctx.loadedWallet.wallet signedTx))
                    )

                ( Ok (Cip30.ApiResponse _ (Cip30.SubmittedTx txId)), Submitting ctx action { tx } ) ->
                    let
                        { updatedState } =
                            TxIntent.updateLocalState txId tx ctx.localStateUtxos

                        updatedCtx =
                            { ctx | localStateUtxos = updatedState }
                    in
                    case action of
                        Registering ->
                            ( ParametersSet updatedCtx { errors = "" }
                            , Cmd.none
                            )

                        MintingTokenKey ->
                            ( TokenMintingDone updatedCtx { txId = txId, errors = "" }
                            , Cmd.none
                            )

                        BurningTokenKey ->
                            ( TokenBurningDone updatedCtx { txId = txId, errors = "" }
                            , Cmd.none
                            )

                        Locking ->
                            ( LockingDone updatedCtx { txId = txId, errors = "" }
                            , Cmd.none
                            )

                        Unlocking ->
                            ( UnlockingDone updatedCtx { txId = txId, errors = "" }
                            , Cmd.none
                            )

                ( Ok (Cip30.ApiError { info }), m ) ->
                    ( setError info m, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ( ConnectButtonClicked { id }, WalletDiscovered _ ) ->
            ( model, toWallet (Cip30.encodeRequest (Cip30.enableWallet { id = id, extensions = [] })) )

        ( LoadBlueprintButtonClicked, WalletLoaded _ _ ) ->
            ( model
            , let
                blueprintDecoder : Decoder (List ScriptBlueprint)
                blueprintDecoder =
                    JD.at [ "validators" ]
                        (JD.list
                            (JD.map4 ScriptBlueprint
                                (JD.field "title" JD.string)
                                (JD.field "compiledCode" JD.string |> JD.map Bytes.fromHexUnchecked)
                                (JD.field "hash" JD.string |> JD.map Bytes.fromHexUnchecked)
                                (JD.maybe (JD.field "parameters" JD.value) |> JD.map (\p -> Maybe.map (always True) p |> Maybe.withDefault False))
                            )
                        )
              in
              Http.get
                { url = "lock/plutus.json"
                , expect = Http.expectJson GotBlueprint blueprintDecoder
                }
            )

        ( GotBlueprint result, WalletLoaded w _ ) ->
            case result of
                Ok scripts ->
                    ( BlueprintLoaded w scripts { errors = "" }, Cmd.none )

                Err err ->
                    -- Handle error as needed
                    ( WalletLoaded w { errors = Debug.toString err }, Cmd.none )

        ( PickUtxoParam, BlueprintLoaded w scripts { errors } ) ->
            case List.head (Dict.Any.keys w.utxos) of
                Just headUtxo ->
                    let
                        appliedMint =
                            List.Extra.find (\{ name } -> name == "unique.mint_unique.mint") scripts
                                |> Result.fromMaybe "Mint script not found in blueprint"
                                |> Result.map (\blueprint -> Script.plutusScriptFromBytes PlutusV3 blueprint.scriptBytes)
                                |> Result.andThen (Uplc.applyParamsToScript [ Utxo.outputReferenceToData headUtxo ])

                        lockScriptResult =
                            List.Extra.find (\{ name } -> name == "lock.lock.spend") scripts
                                |> Result.fromMaybe "Lock script not found in blueprint"
                                |> Result.map (\blueprint -> Script.plutusScriptFromBytes PlutusV3 blueprint.scriptBytes)
                    in
                    case ( appliedMint, lockScriptResult ) of
                        ( Ok plutusScript, Ok plutusLockScript ) ->
                            ( ParametersSet
                                { loadedWallet = w
                                , localStateUtxos = w.utxos
                                , tokenCredScript =
                                    { hash = tokenCredScriptHash
                                    , plutus = Script.plutusScriptFromBytes PlutusV3 tokenCredScriptBytes
                                    }
                                , uniqueMint =
                                    { pickedUtxo = headUtxo
                                    , appliedScript = plutusScript
                                    }
                                , lockScript =
                                    { address =
                                        Address.script
                                            (Address.extractNetworkId w.changeAddress |> Maybe.withDefault Testnet)
                                            (Script.hash <| Script.Plutus plutusLockScript)
                                    , plutus = plutusLockScript
                                    }
                                }
                                { errors = errors }
                            , Cmd.none
                            )

                        ( Err err, _ ) ->
                            ( BlueprintLoaded w scripts { errors = Debug.toString err }
                            , Cmd.none
                            )

                        ( _, Err err ) ->
                            ( BlueprintLoaded w scripts { errors = Debug.toString err }
                            , Cmd.none
                            )

                Nothing ->
                    ( BlueprintLoaded w scripts { errors = "Selected wallet has no UTxO." }
                    , Cmd.none
                    )

        ( RegisterButtonClicked, ParametersSet ctx _ ) ->
            let
                depositAmount =
                    Natural.fromSafeInt 2000000

                registerIntents =
                    -- Take the deposit amount from our wallet
                    [ Spend <|
                        FromWallet
                            { address = ctx.loadedWallet.changeAddress
                            , value = Value.onlyLovelace depositAmount
                            , guaranteedUtxos = []
                            }

                    -- Register the script cred
                    , IssueCertificate <|
                        RegisterStake
                            { delegator = Witness.WithScript ctx.tokenCredScript.hash <| Witness.Plutus registerWitness
                            , deposit = depositAmount
                            }
                    ]

                registerWitness =
                    { script =
                        ( Script.plutusVersion ctx.tokenCredScript.plutus
                        , Witness.ByValue <| Script.cborWrappedBytes ctx.tokenCredScript.plutus
                        )
                    , redeemerData = \_ -> Data.List []
                    , requiredSigners = []
                    }
            in
            case TxIntent.finalize ctx.localStateUtxos [] registerIntents of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx Registering { tx = tx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (TxIntent.errorToString err) model, Cmd.none )

        ( MintTokenKeyButtonClicked, ParametersSet ctx _ ) ->
            let
                policyId =
                    Script.hash <| Script.Plutus ctx.uniqueMint.appliedScript

                emptyName =
                    Bytes.fromHexUnchecked ""

                mintingIntents =
                    -- Spend the picked UTXO
                    [ Spend <|
                        FromWallet
                            { address = ctx.loadedWallet.changeAddress
                            , value = Value.zero
                            , guaranteedUtxos = [ ctx.uniqueMint.pickedUtxo ]
                            }

                    -- Mint the token
                    , MintBurn
                        { policyId = policyId
                        , assets = Bytes.Map.singleton emptyName Integer.one
                        , scriptWitness = Witness.Plutus mintWitness
                        }

                    -- Send the token to the wallet
                    , SendTo ctx.loadedWallet.changeAddress
                        (Value.onlyToken policyId emptyName Natural.one)
                    ]

                mintWitness =
                    { script =
                        ( Script.plutusVersion ctx.uniqueMint.appliedScript
                        , Witness.ByValue <| Script.cborWrappedBytes ctx.uniqueMint.appliedScript
                        )
                    , redeemerData = \_ -> Data.List []
                    , requiredSigners = []
                    }
            in
            case TxIntent.finalize ctx.localStateUtxos [] mintingIntents of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx MintingTokenKey { tx = tx, errors = "" }
                      -- TODO: here it should not require partial signing ... (report it to eternl?)
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (TxIntent.errorToString err) model, Cmd.none )

        ( LockButtonClicked, TokenMintingDone ctx _ ) ->
            let
                policyId =
                    Script.hash <| Script.Plutus ctx.uniqueMint.appliedScript

                lockedValue =
                    Value.onlyLovelace <| Natural.fromSafeInt 2000000

                lockingIntents =
                    -- Spend 2 ada from the wallet
                    [ Spend <|
                        FromWallet
                            { address = ctx.loadedWallet.changeAddress
                            , value = lockedValue
                            , guaranteedUtxos = []
                            }

                    -- Send 2 ada to the lock script
                    , SendToOutput
                        { address = ctx.lockScript.address
                        , amount = lockedValue
                        , datumOption = Just tokenPolicyInDatum
                        , referenceScript = Nothing
                        }
                    ]

                -- Use the token policy as the lock key in the datum
                tokenPolicyInDatum =
                    Utxo.datumValueFromData <| Data.Bytes <| Bytes.toAny policyId
            in
            case TxIntent.finalize ctx.localStateUtxos [] lockingIntents of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx Locking { tx = tx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (TxIntent.errorToString err) model, Cmd.none )

        ( UnlockButtonClicked, LockingDone ctx { txId } ) ->
            let
                lockedValue =
                    Value.onlyLovelace <| Natural.fromSafeInt 2000000

                -- The locked UTxO was the first output of the locking transaction
                lockedUtxo =
                    { transactionId = txId, outputIndex = 0 }

                ( tokenCredIntents, tokenCredOtherInfo ) =
                    TokenCred.checkOwnership networkId tokenCredScriptConfig ctx.localStateUtxos tokenProofs

                networkId =
                    Address.extractNetworkId ctx.loadedWallet.changeAddress |> Maybe.withDefault Testnet

                tokenCredScriptConfig =
                    { hash = tokenCredScriptHash
                    , plutus = Script.plutusScriptFromBytes Script.PlutusV3 tokenCredScriptBytes
                    }

                tokenProofs =
                    [ { policyId = Script.hash <| Script.Plutus ctx.uniqueMint.appliedScript
                      , ownerType = ReferencedTokenAtPubkeyAddress
                      }
                    ]

                -- Building all the unlocking intents
                unlockingIntents =
                    -- Spend the locked UTxO
                    [ Spend <|
                        FromPlutusScript
                            { spentInput = lockedUtxo
                            , datumWitness = Nothing
                            , plutusScriptWitness = unlockWitness
                            }

                    -- Send the locked value back to our wallet
                    , SendTo ctx.loadedWallet.changeAddress lockedValue
                    ]

                unlockWitness =
                    { script =
                        ( Script.plutusVersion ctx.lockScript.plutus
                        , Witness.ByValue <| Script.cborWrappedBytes ctx.lockScript.plutus
                        )
                    , redeemerData =
                        \txContext ->
                            TokenCred.findWithdrawalRedeemerIndex tokenCredScriptHash txContext.redeemers txContext.withdrawals
                                |> Maybe.withDefault -1
                                |> Integer.fromSafeInt
                                |> Data.Int
                    , requiredSigners = []
                    }
            in
            case TxIntent.finalize ctx.localStateUtxos tokenCredOtherInfo (unlockingIntents ++ tokenCredIntents) of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx Unlocking { tx = tx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (TxIntent.errorToString err) model, Cmd.none )

        ( BurnTokenKeyButtonClicked, UnlockingDone ctx _ ) ->
            let
                policyId =
                    Script.hash <| Script.Plutus ctx.uniqueMint.appliedScript

                emptyName =
                    Bytes.fromHexUnchecked ""

                burningIntents =
                    -- Spend the token to be burned
                    [ Spend <|
                        FromWallet
                            { address = ctx.loadedWallet.changeAddress
                            , value = Value.onlyToken policyId emptyName Natural.one
                            , guaranteedUtxos = []
                            }

                    -- Burn the token
                    , MintBurn
                        { policyId = policyId
                        , assets = Bytes.Map.singleton emptyName Integer.negativeOne
                        , scriptWitness = Witness.Plutus mintWitness
                        }
                    ]

                mintWitness =
                    { script =
                        ( Script.plutusVersion ctx.uniqueMint.appliedScript
                        , Witness.ByValue <| Script.cborWrappedBytes ctx.uniqueMint.appliedScript
                        )
                    , redeemerData = \_ -> Data.List []
                    , requiredSigners = []
                    }
            in
            case TxIntent.finalize ctx.localStateUtxos [] burningIntents of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx BurningTokenKey { tx = tx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (TxIntent.errorToString err) model, Cmd.none )

        ( TrySubmitAgainButtonClicked, Submitting ctx _ { tx } ) ->
            ( setError "" model
            , toWallet (Cip30.encodeRequest (Cip30.submitTx ctx.loadedWallet.wallet tx))
            )

        _ ->
            ( model, Cmd.none )



-- #########################################################
-- VIEW
-- #########################################################


view : Model -> Html Msg
view model =
    case model of
        Startup ->
            div [] [ div [] [ text "Hello Cardano!" ] ]

        WalletDiscovered availableWallets ->
            div []
                [ div [] [ text "Hello Cardano!" ]
                , div [] [ text "CIP-30 wallets detected:" ]
                , viewAvailableWallets availableWallets
                ]

        WalletLoading _ ->
            div [] [ text "Loading wallet assets ..." ]

        WalletLoaded loadedWallet { errors } ->
            div []
                (viewLoadedWallet loadedWallet
                    ++ [ button [ onClick LoadBlueprintButtonClicked ] [ text "Load Blueprint" ]
                       , displayErrors errors
                       ]
                )

        BlueprintLoaded loadedWallet scripts { errors } ->
            let
                viewBlueprint { name, scriptBytes, hasParams } =
                    if hasParams then
                        div [] [ text <| "(unapplied) " ++ name ++ " (size: " ++ String.fromInt (Bytes.width scriptBytes) ++ " bytes)" ]

                    else
                        div [] [ text <| "☑️ " ++ name ++ " (size: " ++ String.fromInt (Bytes.width scriptBytes) ++ " bytes)" ]
            in
            div []
                (viewLoadedWallet loadedWallet
                    ++ List.map viewBlueprint scripts
                    ++ [ button [ HE.onClick PickUtxoParam ] [ text "Auto-pick UTxO to be spent for unicity guarantee of the mint contract" ]
                       , displayErrors errors
                       ]
                )

        ParametersSet ctx { errors } ->
            let
                mintScriptHash =
                    Script.hash <| Script.Plutus ctx.uniqueMint.appliedScript

                lockScriptHash =
                    Script.hash <| Script.Plutus ctx.lockScript.plutus
            in
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "☑️ Picked UTxO: " ++ Utxo.refAsString ctx.uniqueMint.pickedUtxo ]
                       , div [] [ text <| "Minted token policy ID used as credential: " ++ Bytes.toHex mintScriptHash ]
                       , div [] [ text <| "Lock script hash: " ++ Bytes.toHex lockScriptHash ]
                       , div [] [ text <| "Token-cred script hash: " ++ Bytes.toHex ctx.tokenCredScript.hash ]
                       , button [ onClick MintTokenKeyButtonClicked ] [ text "Mint the token key" ]
                       , button [ onClick RegisterButtonClicked ] [ text "Register the token cred script (do only if needed)" ]
                       , displayErrors errors
                       ]
                )

        TokenMintingDone ctx { txId, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Token minting done" ]
                       , div [] [ text <| "Transaction ID: " ++ Bytes.toHex txId ]
                       , button [ onClick LockButtonClicked ] [ text "Lock 2 Ada with the token as key" ]
                       , displayErrors errors
                       ]
                )

        LockingDone ctx { txId, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Assets locking done" ]
                       , div [] [ text <| "Transaction ID: " ++ Bytes.toHex txId ]
                       , button [ onClick UnlockButtonClicked ] [ text "Unlock the assets with the token as key" ]
                       , displayErrors errors
                       ]
                )

        UnlockingDone ctx { txId, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Assets unlocked!" ]
                       , div [] [ text <| "Transaction ID: " ++ Bytes.toHex txId ]
                       , button [ onClick BurnTokenKeyButtonClicked ] [ text "Burn the token key" ]
                       , displayErrors errors
                       ]
                )

        TokenBurningDone ctx { txId, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Token burning done" ]
                       , div [] [ text <| "Transaction ID: " ++ Bytes.toHex txId ]
                       , displayErrors errors
                       ]
                )

        Signing ctx action { tx, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Signing " ++ Debug.toString action ++ " Tx: " ++ Bytes.toHex (Transaction.computeTxId tx.tx) ]
                       , div []
                            [ text <| "Expected signatures:"
                            , div [] (List.map (\hash -> div [] [ text <| Bytes.toHex hash ]) tx.expectedSignatures)
                            ]
                       , Html.pre [] [ text <| Cardano.TxExamples.prettyTx tx.tx ]
                       , displayErrors errors
                       ]
                )

        Submitting ctx action { tx, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Submitting " ++ Debug.toString action ++ " Tx: " ++ Bytes.toHex (Transaction.computeTxId tx) ]
                       , button [ onClick TrySubmitAgainButtonClicked ] [ text "Try submitting again" ]
                       , displayErrors errors
                       ]
                )


displayErrors : String -> Html msg
displayErrors err =
    if err == "" then
        text ""

    else
        Html.pre [ HA.style "color" "red" ] [ Html.b [] [ text <| "ERRORS: " ], text err ]


viewLoadedWallet : LoadedWallet -> List (Html msg)
viewLoadedWallet { wallet, utxos, changeAddress } =
    [ div [] [ text <| "Wallet: " ++ (Cip30.walletDescriptor wallet).name ]
    , div [] [ text <| "Address: " ++ (Address.toBytes changeAddress |> Bytes.toHex) ]
    , div [] [ text <| "UTxO count: " ++ String.fromInt (Dict.Any.size utxos) ]
    ]


viewAvailableWallets : List Cip30.WalletDescriptor -> Html Msg
viewAvailableWallets wallets =
    let
        walletDescription : Cip30.WalletDescriptor -> String
        walletDescription w =
            "id: " ++ w.id ++ ", name: " ++ w.name

        walletIcon : Cip30.WalletDescriptor -> Html Msg
        walletIcon { icon } =
            Html.img [ src icon, height 32 ] []

        connectButton { id } =
            Html.button [ onClick (ConnectButtonClicked { id = id }) ] [ text "connect" ]

        walletRow w =
            div [] [ walletIcon w, text (walletDescription w), connectButton w ]
    in
    div [] (List.map walletRow wallets)
