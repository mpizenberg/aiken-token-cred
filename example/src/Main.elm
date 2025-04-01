port module Main exposing (main)

import Browser
import Bytes.Comparable as Bytes exposing (Bytes)
import Bytes.Map
import Cardano exposing (ScriptWitness(..), SpendSource(..), TxFinalized, TxIntent(..), WitnessSource(..))
import Cardano.Address as Address exposing (Address, Credential(..), CredentialHash, NetworkId(..))
import Cardano.Cip30 as Cip30
import Cardano.Data as Data
import Cardano.MultiAsset as MultiAsset exposing (MultiAsset)
import Cardano.Script as Script exposing (PlutusScript, PlutusVersion(..), Script, ScriptCbor)
import Cardano.Transaction as Transaction exposing (Transaction)
import Cardano.TxExamples
import Cardano.Uplc as Uplc
import Cardano.Utxo as Utxo exposing (Output, OutputReference, TransactionId)
import Cardano.Value as Value
import Dict.Any
import Html exposing (Html, button, div, text)
import Html.Attributes as HA exposing (height, src)
import Html.Events as HE exposing (onClick)
import Http
import Integer
import Json.Decode as JD exposing (Decoder, Value)
import List.Extra
import Natural


tokenCredScriptHash =
    -- Constant retrieved from the aiken-token-cred blueprint
    Bytes.fromHexUnchecked "94c48e8037705486cdb9d972464a194c92088339df749a3d2300d783"


tokenCredScriptBytes =
    -- Constant retrieved from the aiken-token-cred blueprint
    Bytes.fromHexUnchecked "59020001010029800aba2aba1aba0aab9faab9eaab9dab9a488888896600264646644b30013370e900218031baa002899199119801001001912cc00400626530013758600260166ea80166eacc038c03cc03cc03cc03cc03cc03cc02cdd5002cdd618071807980798079807980798079807980798059baa0054888c8cc004004020896600200314a31598009991192cc004c008c048dd5000c6600244b30010018a5eb8226602e6028603000266004004603200280b244646600200200644b30010018a508acc004cdc79bae301a0010038a51899801001180d800a02a40613016301730133754602c60266ea80052225980099801198018019bab300c301637540026eb8c05401a264b300130063016375400313300300a375c6034602e6ea80062646600200201844b30010018a508acc004cdd7980c180e000801c528c4cc008008c074005017203440546032602c6ea8c064c058dd5000c5901422c8088ca60020030089bad30130034004444b30010028a60103d87a80008acc004c010006266e9520003301730180024bd70466002007301900299b80001480050032026405860260026e1d2000899801001180a000c528201c40442300e300f00189919911980280298088021bae300a001375a6016002601a0028058c02cc020dd50019bab300a0038a504014601060120026010004601000260066ea802229344d95900101"


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
    = MintingTokenKey
    | BurningTokenKey


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
    | BurnTokenKeyButtonClicked


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
                            Cardano.updateLocalState txId tx ctx.localStateUtxos

                        updatedCtx =
                            { ctx | localStateUtxos = updatedState }
                    in
                    case action of
                        MintingTokenKey ->
                            ( TokenMintingDone updatedCtx { txId = txId, errors = "" }
                            , Cmd.none
                            )

                        BurningTokenKey ->
                            ( TokenBurningDone updatedCtx { txId = txId, errors = "" }
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
                        , scriptWitness = PlutusWitness mintWitness
                        }

                    -- Send the token to the wallet
                    , SendTo ctx.loadedWallet.changeAddress
                        (Value.onlyToken policyId emptyName Natural.one)
                    ]

                mintWitness =
                    { script =
                        ( Script.plutusVersion ctx.uniqueMint.appliedScript
                        , WitnessByValue <| Script.cborWrappedBytes ctx.uniqueMint.appliedScript
                        )
                    , redeemerData = \_ -> Data.List []
                    , requiredSigners = []
                    }
            in
            case Cardano.finalize ctx.localStateUtxos [] mintingIntents of
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
                    ( setError (Debug.toString err) model, Cmd.none )

        ( BurnTokenKeyButtonClicked, TokenMintingDone ctx _ ) ->
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
                        , scriptWitness = PlutusWitness mintWitness
                        }
                    ]

                mintWitness =
                    { script =
                        ( Script.plutusVersion ctx.uniqueMint.appliedScript
                        , WitnessByValue <| Script.cborWrappedBytes ctx.uniqueMint.appliedScript
                        )
                    , redeemerData = \_ -> Data.List []
                    , requiredSigners = []
                    }
            in
            case Cardano.finalize ctx.localStateUtxos [] burningIntents of
                Ok tx ->
                    let
                        _ =
                            Debug.log "tx" <| Transaction.serialize tx.tx
                    in
                    ( Signing ctx BurningTokenKey { tx = tx, errors = "" }
                    , toWallet (Cip30.encodeRequest (Cip30.signTx ctx.loadedWallet.wallet { partialSign = True } tx.tx))
                    )

                Err err ->
                    ( setError (Debug.toString err) model, Cmd.none )

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
                       , displayErrors errors
                       ]
                )

        TokenMintingDone ctx { txId, errors } ->
            div []
                (viewLoadedWallet ctx.loadedWallet
                    ++ [ div [] [ text <| "Token minting done" ]
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
                    ++ [ div [] [ text <| "Signing Tx: " ++ Bytes.toHex (Transaction.computeTxId tx.tx) ]
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
                    ++ [ div [] [ text <| "Submitting Tx: " ++ Bytes.toHex (Transaction.computeTxId tx) ]
                       , displayErrors errors
                       ]
                )


displayErrors : String -> Html msg
displayErrors err =
    if err == "" then
        text ""

    else
        div [ HA.style "color" "red" ] [ Html.b [] [ text <| "ERRORS: " ], text err ]


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
