use aiken/collection/list.{for_each, unique}
use aiken/collection/pairs
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/fuzz.{and_then, constant as return, label}
use aiken/fuzz/scenario.{Label, Scenario}
use cardano/address.{Credential}
use cardano/assets.{Lovelace, PolicyId}
use cardano/fuzz as cardano
use cardano/transaction.{Input, Redeemer, ScriptPurpose, Transaction}
use check_badges.{Index} as handlers

// A fake hash used to identify our validator in generated data.
const check_badges_validator_hash: ScriptHash = #"12345678"

// A fake policy id used in scenarii for authentication
const fst_badge: PolicyId = #"bad9e00001"

// Another policy id used in scenarii for authentication
const snd_badge: PolicyId = #"bad9e00002"

// ------ Top-level properties
// Plumbing things together. Nothing really interesting here for the machinery is handled by the chaos framework.
// We declare 3 main properties:
//
// - A sequence of "ok" scenarii, where we simply go through the generated
//   sequence of transaction which is expected to be *valid*. So no errors should
//   arise whatsoever. Said differently, this tests the happy path.
//
// - A sequence of "ko" scenarii, where we expect one of the transition to be
//   illegal and caught by the validators. We collect the reason of the failure
//   for classification.
//
// - A 'coverage' property, which simply measure the frequency of O.K. vs K.O.
//   scenarii, ensuring that we maintain a reasonable distribution as we
//   complexify scenarii down the line.

test prop_scenario_coverage(
  outcome via scenario.report_coverage(default_state, step),
) {
  fuzz.label_when(outcome == scenario.Ok, @"O.K.", @"K.O.")
}

test prop_check_badges_ok(ok via scenario.ok(default_state, step)) {
  scenario.run(
    ok,
    check_badges_validator_hash,
    scenario.into_mint_handler(handlers.check_badges.else),
    scenario.into_spend_handler(handlers.check_badges.else),
    cast_withdraw(handlers.check_badges.withdraw),
    handlers.check_badges.publish,
    scenario.into_vote_handler(handlers.check_badges.else),
  )
  for_each(ok, post_conditions)
}

test prop_check_badges_ko(
  (labels, ko) via scenario.ko(default_state, step),
) fail {
  for_each(unique(labels), fuzz.label)
  scenario.run(
    ko,
    check_badges_validator_hash,
    scenario.into_mint_handler(handlers.check_badges.else),
    scenario.into_spend_handler(handlers.check_badges.else),
    cast_withdraw(handlers.check_badges.withdraw),
    handlers.check_badges.publish,
    scenario.into_vote_handler(handlers.check_badges.else),
  )
}

// ------ Labelling
// While the framework provides labels for the K.O. scenarios out-of-box, we have to manually label

fn post_conditions(scenario: Transaction) {
  expect Some(redeemer) =
    scenario.redeemers
      |> pairs.get_first(
          ScriptPurpose.Withdraw(Credential.Script(check_badges_validator_hash)),
        )

  expect policies: Pairs<PolicyId, Index> = redeemer

  let spent_badges_count = count_badges(scenario.inputs)

  let ref_badges_count = count_badges(scenario.reference_inputs)

  []
    |> scenario.classify(
        @"· more authorizations than necessary",
        spent_badges_count + ref_badges_count > list.length(policies),
      )
    |> scenario.classify(
        @"· at least one spent authorization",
        spent_badges_count > 0,
      )
    |> scenario.classify(
        @"· at least one reference authorization",
        ref_badges_count > 0,
      )
    |> scenario.classify(
        @"· more than one badge checked",
        list.length(policies) > 1,
      )
    |> scenario.classify(
        @"· mixed of reference/spent badges",
        spent_badges_count > 0 && ref_badges_count > 0,
      )
    |> for_each(label)
}

// ----- Failing scenarii

const unrecognized_spent: String = @"· unrecognized spent"

const unrecognized_ref: String = @"· unrecognized reference"

const unauthorized_vkey_ref: String = @"· unauthorized (key) reference"

const unauthorized_script_ref: String = @"· unauthorized (script) reference"

const out_of_range_index: String = @"· out-of-range index"

// ----- Interfacing
// The scenario interface is quite generic, so in case we have specific
// data-types for redeemers, we have to explicitly cast them.

fn cast_withdraw(
  withdraw: fn(Pairs<PolicyId, Index>, Data, Transaction) -> Bool,
) -> scenario.WithdrawHandler {
  fn(data: Data, account: Credential, transaction: Transaction) -> Bool {
    expect redeemer: Pairs<PolicyId, Index> = data
    withdraw(redeemer, account, transaction)
  }
}

// ----- Test's state
// Used for writing dependent generators. It is sometimes useful (if not
// crucial) to be able to *remember* some previous step in order to generate
// the next scenario.
//
// The `State` is therefore free of form, and can be arbitrarily complex to the
// need of our validator.

type State {
  labels: List<Label>,
  authorized_inputs: Pairs<PolicyId, Index>,
  unauthorized_inputs: Pairs<Input, Index>,
  required_signers: Pairs<Index, VerificationKeyHash>,
  required_scripts: Pairs<Index, ScriptHash>,
  done: Bool,
}

const default_state =
  State {
    labels: [],
    authorized_inputs: [],
    unauthorized_inputs: [],
    required_signers: [],
    required_scripts: [],
    done: False,
  }

type Weights {
  scenario_inputs: Int,
  scenario_redeemers: Int,
  scenario_signatories: Int,
  scenario_withdrawals: Int,
}

const weights =
  Weights {
    scenario_inputs: 192,
    scenario_redeemers: 168,
    scenario_signatories: 128,
    scenario_withdrawals: 128,
  }

// ----- Generator

fn step(st: State) -> Fuzzer<Scenario<State>> {
  if st.done {
    // The check_badges validator is a simple single transition, there's no need
    // for a sequence of transactions. So we only ever generate a single
    // transaction scenario.
    return(Scenario.Done)
  } else {
    let (st, inputs) <-
      scenario.fork_and_then(
        weights.scenario_inputs,
        fn() { scenario_inputs_baseline(st) },
        fn() { scenario_inputs_no_auth(st) },
      )

    let (st, reference_inputs) <-
      scenario.fork_and_then(
        weights.scenario_inputs,
        fn() { scenario_ref_inputs_baseline(st) },
        fn() { return((st, [])) },
      )

    let (st, redeemers) <-
      and_then(
        when st.authorized_inputs is {
          [] ->
            scenario.fork2(
              weights.scenario_redeemers,
              // O.K. -> give no policies to the redeemer
              fn() { scenario_redeemers_baseline(st) },
              // K.O. -> point the redeemer to an unauthorized input
              fn() { scenario_redeemers_pick_unauthorized(st) },
              // K.O. -> point at some non-existing/out-of-range index
              fn() { scenario_redeemers_out_of_range(st) },
            )
          _authorized_inputs ->
            if st.unauthorized_inputs != [] {
              scenario.fork2(
                weights.scenario_redeemers,
                // O.K. -> use all authorized inputs as-is
                fn() { scenario_redeemers_baseline(st) },
                // O.K. -> remove any authorization requirement, still O.K.
                fn() { scenario_redeemers_relax_constraints(st) },
                // K.O. -> point the redeemer to an unauthorized input
                fn() { scenario_redeemers_pick_unauthorized(st) },
              )
            } else {
              scenario.fork2(
                weights.scenario_redeemers,
                // O.K. -> use all authorized inputs as-is
                fn() { scenario_redeemers_baseline(st) },
                // O.K. -> remove any authorization requirement, still O.K.
                fn() { scenario_redeemers_relax_constraints(st) },
                // K.O. -> point at some non-existing/out-of-range index
                fn() { scenario_redeemers_out_of_range(st) },
              )
            }
        },
      )

    let (st, extra_signatories) <-
      scenario.fork_if_and_then(
        st.labels == [] && st.required_signers != [],
        weights.scenario_signatories,
        // O.K. -> keep all expected signers
        fn() { scenario_signatories_baseline(st) },
        // K.O. -> remove some arbitrary signers for reference_inputs
        fn() { scenario_signatories_drop_some(st) },
      )

    let (st, withdrawals) <-
      scenario.fork_if_and_then(
        st.labels == [] && st.required_scripts != [],
        weights.scenario_withdrawals,
        // O.K. -> Keep all expected withdrawals
        fn() { scenario_withdrawals_baseline(st) },
        // K.O. -> Remove necessary withdrawals
        fn() { scenario_withdrawals_drop_some(st) },
      )

    return(
      Scenario.Step(
        st.labels,
        State { ..st, done: True, labels: [] },
        Transaction {
          ..transaction.placeholder,
          inputs: inputs,
          reference_inputs: reference_inputs,
          extra_signatories: extra_signatories,
          withdrawals: [
            // Always insert a withdrawal to trigger the validator. The amount can
            // literally be anything; it has no influence on the validator's logic.
            Pair(Credential.Script(check_badges_validator_hash), 0),
            ..withdrawals
          ],
          redeemers: redeemers,
        },
      ),
    )
  }
}

// A baseline setup for a 'SpentInput' scenario, with a single input at an arbitrary position holding a badge.
fn scenario_inputs_baseline(st: State) -> Fuzzer<(State, List<Input>)> {
  let inputs_before <- and_then(fuzz.list_between(cardano.input(), 0, 2))

  let badge <- and_then(fuzz.one_of([fst_badge, snd_badge]))

  let auth_input <- and_then(input_with(badge))

  let inputs_after <- and_then(fuzz.list_between(cardano.input(), 0, 2))

  let auth_input_index = list.length(inputs_before)

  let st =
    State {
      ..st,
      authorized_inputs: [
        Pair(badge, Index.SpentInputIndex(auth_input_index)),
        ..st.authorized_inputs
      ],
      unauthorized_inputs: list.concat(
        st.unauthorized_inputs,
        list.concat(
          indexed_map_from(inputs_before, Index.SpentInputIndex, 0),
          indexed_map_from(
            inputs_after,
            Index.SpentInputIndex,
            auth_input_index + 1,
          ),
        ),
      ),
    }

  let inputs = list.concat(inputs_before, [auth_input, ..inputs_after])

  return((st, inputs))
}

/// A scenario where none of the spent input holds a badge.
fn scenario_inputs_no_auth(st: State) -> Fuzzer<(State, List<Input>)> {
  let inputs <- and_then(fuzz.list_between(cardano.input(), 1, 3))
  return(
    (
      State {
        ..st,
        unauthorized_inputs: indexed_map_from(inputs, Index.SpentInputIndex, 0),
      },
      inputs,
    ),
  )
}

/// Valid base 'RefInput' scenario, with a single reference input at an arbitrary position holding a badge.
fn scenario_ref_inputs_baseline(st: State) -> Fuzzer<(State, List<Input>)> {
  let inputs_before <- and_then(fuzz.list_between(cardano.input(), 0, 1))

  let badge <- and_then(fuzz.one_of([fst_badge, snd_badge]))

  let auth_input <- and_then(input_with(badge))

  let auth_input_index = list.length(inputs_before)

  let st =
    when auth_input.output.address.payment_credential is {
      Credential.VerificationKey(signer) ->
        State {
          ..st,
          required_signers: [
            Pair(Index.RefInputIndex(auth_input_index), signer),
            ..st.required_signers
          ],
        }
      Credential.Script(script) ->
        State {
          ..st,
          required_scripts: [
            Pair(Index.RefInputIndex(auth_input_index), script),
            ..st.required_scripts
          ],
        }
    }

  let inputs_after <- and_then(fuzz.list_between(cardano.input(), 0, 1))

  let inputs = list.concat(inputs_before, [auth_input, ..inputs_after])

  let st =
    State {
      ..st,
      authorized_inputs: [
        Pair(badge, Index.RefInputIndex(auth_input_index)),
        ..st.authorized_inputs
      ],
      unauthorized_inputs: list.concat(
        st.unauthorized_inputs,
        list.concat(
          indexed_map_from(inputs_before, Index.RefInputIndex, 0),
          indexed_map_from(
            inputs_after,
            Index.RefInputIndex,
            auth_input_index + 1,
          ),
        ),
      ),
    }

  return((st, inputs))
}

/// A scenario where we use the unaltered redeemers.
fn scenario_redeemers_baseline(
  st: State,
) -> Fuzzer<(State, Pairs<ScriptPurpose, Redeemer>)> {
  return((st, [new_redeemer(st.authorized_inputs)]))
}

/// An O.K. scenario where we drop of the policies within the redeemers. We
/// still expect the contract to pass as we've simply made it less constrained
/// and easier to satisfy.
fn scenario_redeemers_relax_constraints(
  st: State,
) -> Fuzzer<(State, Pairs<ScriptPurpose, Redeemer>)> {
  let (_, auth) <- and_then(fuzz.pick(st.authorized_inputs))

  // Don't forget to remove required signers / scripts from the list. Since we
  // dropped the constraint, they are no longer required.
  let st =
    when auth.2nd is {
      Index.SpentInputIndex(_) -> st
      Index.RefInputIndex(_) ->
        State {
          ..st,
          required_signers: pairs.delete_first(st.required_signers, auth.2nd),
          required_scripts: pairs.delete_first(st.required_scripts, auth.2nd),
        }
    }

  let leftovers = list.delete(st.authorized_inputs, auth)

  return((st, [new_redeemer(leftovers)]))
}

/// A scenario where we purposely point a redeemer to an unrecognised input
/// (i.e. an input that doesn't carry a badge).
fn scenario_redeemers_pick_unauthorized(
  st: State,
) -> Fuzzer<(State, Pairs<ScriptPurpose, Redeemer>)> {
  let (_, Pair(input, ix)) <- and_then(fuzz.pick(st.unauthorized_inputs))

  let st =
    when ix is {
      Index.SpentInputIndex { .. } ->
        State { ..st, labels: [unrecognized_spent, ..st.labels] }
      Index.RefInputIndex { .. } ->
        State {
          ..st,
          labels: [unrecognized_ref, ..st.labels],
          required_signers: when input.output.address.payment_credential is {
            Credential.VerificationKey(signer) ->
              [Pair(ix, signer), ..st.required_signers]
            Credential.Script(..) -> st.required_signers
          },
        }
    }

  let badge <- and_then(fuzz.one_of([fst_badge, snd_badge]))

  return((st, [new_redeemer([Pair(badge, ix)])]))
}

/// Checking what happens if we pick indexes completely out-of-range.
fn scenario_redeemers_out_of_range(
  st: State,
) -> Fuzzer<(State, Pairs<ScriptPurpose, Redeemer>)> {
  let st = State { ..st, labels: [out_of_range_index, ..st.labels] }

  let badge <- and_then(fuzz.one_of([fst_badge, snd_badge]))

  fuzz.either(
    {
      let max_bound =
        0
          |> list.foldl(st.authorized_inputs, _, count_spent_input)
          |> list.foldl(st.unauthorized_inputs, _, count_spent_input)

      let ix <- and_then(fuzz.either(return(-1), return(max_bound)))

      return((st, [new_redeemer([Pair(badge, Index.SpentInputIndex(ix))])]))
    },
    {
      let max_bound =
        0
          |> list.foldl(st.authorized_inputs, _, count_ref_input)
          |> list.foldl(st.unauthorized_inputs, _, count_ref_input)

      let ix <- and_then(fuzz.either(return(-1), return(max_bound)))

      return((st, [new_redeemer([Pair(badge, Index.RefInputIndex(ix))])]))
    },
  )
}

fn scenario_signatories_baseline(
  st: State,
) -> Fuzzer<(State, List<VerificationKeyHash>)> {
  return((st, pairs.values(st.required_signers)))
}

fn scenario_signatories_drop_some(
  st: State,
) -> Fuzzer<(State, List<VerificationKeyHash>)> {
  let (_, removed) <- and_then(fuzz.pick(st.required_signers))
  return(
    (
      State { ..st, labels: [unauthorized_vkey_ref, ..st.labels] },
      {
        let signer, signatories <- list.foldl(st.required_signers, [])
        if signer == removed {
          signatories
        } else {
          [signer.2nd, ..signatories]
        }
      },
    ),
  )
}

fn scenario_withdrawals_baseline(
  st: State,
) -> Fuzzer<(State, Pairs<Credential, Lovelace>)> {
  return(
    (
      st,
      {
        let Pair(_, script) <- list.map(st.required_scripts)
        Pair(Credential.Script(script), 0)
      },
    ),
  )
}

fn scenario_withdrawals_drop_some(
  st: State,
) -> Fuzzer<(State, Pairs<Credential, Lovelace>)> {
  let (_, removed) <- and_then(fuzz.pick(st.required_scripts))
  return(
    (
      State { ..st, labels: [unauthorized_script_ref, ..st.labels] },
      {
        let script, withdrawals <- list.foldl(st.required_scripts, [])
        if script == removed {
          withdrawals
        } else {
          [Pair(Credential.Script(script.2nd), 0), ..withdrawals]
        }
      },
    ),
  )
}

// ------ Helpers

/// Construct a range of indices from a starting index, and as large as a given list.
fn indexed_map_from(xs: List<a>, into: fn(Int) -> b, zero: Int) -> Pairs<a, b> {
  when xs is {
    [] -> []
    [head, ..tail] ->
      [Pair(head, into(zero)), ..indexed_map_from(tail, into, zero + 1)]
  }
}

/// Construct a new redeemer for the 'check_badges' validator, pointing at the given authorizations (possibly empty).
fn new_redeemer(
  authorizations: Pairs<PolicyId, Index>,
) -> Pair<ScriptPurpose, Redeemer> {
  Pair(
    ScriptPurpose.Withdraw(Credential.Script(check_badges_validator_hash)),
    as_data(authorizations),
  )
}

/// Generate a single input containing _at least_ an NFT of the given policy id. Everything else is arbitrary.
fn input_with(badge: PolicyId) -> Fuzzer<Input> {
  let base_value <- and_then(cardano.value(assets.zero))
  cardano.input_with(
    cardano.output_reference(),
    cardano.output_with(
      cardano.address(),
      cardano.value_with(
        base_value,
        return([badge]),
        fn(_) { return("") },
        fn(_, _) { return(1) },
      ),
      cardano.datum(),
      cardano.reference_script(),
    ),
  )
}

/// Count known badges seen in the given list of inputs (spent or ref).
fn count_badges(inputs: List<Input>) {
  list.foldl(
    inputs,
    0,
    fn(input, count) {
      list.foldl(
        assets.policies(input.output.value),
        count,
        fn(policy_id, count) {
          if policy_id == fst_badge || policy_id == snd_badge {
            count + 1
          } else {
            count
          }
        },
      )
    },
  )
}

fn count_spent_input(Pair(_, index): Pair<a, Index>, total: Int) -> Int {
  when index is {
    Index.SpentInputIndex { .. } -> total + 1
    Index.RefInputIndex { .. } -> total
  }
}

fn count_ref_input(Pair(_, index): Pair<a, Index>, total: Int) -> Int {
  when index is {
    Index.SpentInputIndex { .. } -> total
    Index.RefInputIndex { .. } -> total + 1
  }
}
