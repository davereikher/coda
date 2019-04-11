[%%import
"../../config.mlh"]

open Core_kernel
open Async_kernel
open Protocols
open Coda_pow
open O1trace

let val_or_exn label = function
  | Error e -> failwithf "%s: %s" label (Error.to_string_hum e) ()
  | Ok x -> x

let option lab =
  Option.value_map ~default:(Or_error.error_string lab) ~f:(fun x -> Ok x)

module Make_completed_work = Transaction_snark_work.Make
module Make_diff = Staged_ledger_diff.Make

module Make_with_constants (Constants : sig
  val transaction_capacity_log_2 : int

  val work_delay_factor : int

  val latency_factor : int
end)
(Inputs : Inputs.S) : sig
  include
    Coda_pow.Staged_ledger_intf
    with type diff := Inputs.Staged_ledger_diff.t
     and type valid_diff :=
                Inputs.Staged_ledger_diff.With_valid_signatures_and_proofs.t
     and type ledger_hash := Inputs.Ledger_hash.t
     and type frozen_ledger_hash := Inputs.Frozen_ledger_hash.t
     and type staged_ledger_hash := Inputs.Staged_ledger_hash.t
     and type public_key := Inputs.Compressed_public_key.t
     and type ledger := Inputs.Ledger.t
     and type user_command_with_valid_signature :=
                Inputs.User_command.With_valid_signature.t
     and type statement := Inputs.Transaction_snark_work.Statement.t
     and type completed_work_checked := Inputs.Transaction_snark_work.Checked.t
     and type ledger_proof := Inputs.Ledger_proof.t
     and type staged_ledger_aux_hash := Inputs.Staged_ledger_aux_hash.t
     and type sparse_ledger := Inputs.Sparse_ledger.t
     and type ledger_proof_statement := Inputs.Ledger_proof_statement.t
     and type ledger_proof_statement_set := Inputs.Ledger_proof_statement.Set.t
     and type transaction := Inputs.Transaction.t
     and type user_command := Inputs.User_command.t
     and type transaction_witness := Inputs.Transaction_witness.t
     and type pending_coinbase_collection := Inputs.Pending_coinbase.t
end = struct
  open Inputs
  module Scan_state = Transaction_snark_scan_state.Make (Constants) (Inputs)

  module Staged_ledger_error = struct
    type t =
      | Bad_signature of User_command.t
      | Coinbase_error of string
      | Bad_prev_hash of Staged_ledger_hash.t * Staged_ledger_hash.t
      | Insufficient_fee of Currency.Fee.t * Currency.Fee.t
      | Non_zero_fee_excess of
          Scan_state.Space_partition.t * Transaction.t list
      | Invalid_proof of
          Ledger_proof.t * Ledger_proof_statement.t * Compressed_public_key.t
      | Unexpected of Error.t
    [@@deriving sexp]

    let to_string = function
      | Bad_signature t ->
          Format.asprintf
            !"Bad signature of the user command: %{sexp: User_command.t} \n"
            t
      | Coinbase_error err -> Format.asprintf !"Coinbase error: %s \n" err
      | Bad_prev_hash (h1, h2) ->
          Format.asprintf
            !"bad prev_hash: Expected %{sexp: Staged_ledger_hash.t}, got \
              %{sexp: Staged_ledger_hash.t} \n"
            h1 h2
      | Insufficient_fee (f1, f2) ->
          Format.asprintf
            !"Transaction fee %{sexp: Currency.Fee.t} does not suffice proof \
              fee %{sexp: Currency.Fee.t} \n"
            f1 f2
      | Non_zero_fee_excess (partition, txns) ->
          Format.asprintf
            !"Fee excess is non-zero for the transactions: %{sexp: \
              Transaction.t list} and the current queue with slots \
              partitioned as %{sexp: Scan_state.Space_partition.t} \n"
            txns partition
      | Invalid_proof (p, s, prover) ->
          Format.asprintf
            !"Verification failed for proof: %{sexp: Ledger_proof.t} \
              Statement: %{sexp: Ledger_proof_statement.t} Prover: \
              %{sexp:Compressed_public_key.t}\n"
            p s prover
      | Unexpected e -> Error.to_string_hum e

    let to_error = Fn.compose Error.of_string to_string

    let to_or_error = function
      | Ok s -> Ok s
      | Error e -> Or_error.error_string (to_string e)
  end

  let to_staged_ledger_or_error = function
    | Ok a -> Ok a
    | Error e -> Error (Staged_ledger_error.Unexpected e)

  type job = Scan_state.Available_job.t [@@deriving sexp]

  let verify_proof proof statement ~message =
    Inputs.Ledger_proof_verifier.verify proof statement ~message

  let verify ~message job proof prover =
    let open Deferred.Let_syntax in
    match Scan_state.statement_of_job job with
    | None ->
        Deferred.return
          ( Or_error.errorf !"Error creating statement from job %{sexp:job}" job
          |> to_staged_ledger_or_error )
    | Some statement -> (
        match%map verify_proof proof statement ~message with
        | true -> Ok ()
        | _ ->
            Error
              (Staged_ledger_error.Invalid_proof (proof, statement, prover)) )

  (*TODO: Punish*)

  module M = struct
    include Monad.Ident
    module Or_error = Or_error
  end

  module Statement_scanner = struct
    include Scan_state.Make_statement_scanner
              (M)
              (struct
                let verify (_ : Ledger_proof.t) (_ : Ledger_proof_statement.t)
                    ~message:(_ : Sok_message.t) =
                  true
              end)
  end

  module Statement_scanner_with_proofs =
    Scan_state.Make_statement_scanner
      (Deferred)
      (struct
        let verify proof stmt ~message = verify_proof proof stmt ~message
      end)

  type pending_coinbase_collection = Pending_coinbase.t
  [@@deriving sexp, bin_io]

  type t =
    { scan_state:
        Scan_state.t
        (* Invariant: this is the ledger after having applied all the transactions in
       *the above state. *)
    ; ledger: Ledger.attached_mask sexp_opaque
    ; pending_coinbase_collection: Pending_coinbase.t }
  [@@deriving sexp]

  type serializable =
    Scan_state.Stable.V1.t * Ledger.serializable * pending_coinbase_collection
  [@@deriving bin_io]

  let serializable_of_t t =
    ( t.scan_state
    , Ledger.serializable_of_t t.ledger
    , t.pending_coinbase_collection )

  let of_serialized_and_unserialized ~(serialized : serializable)
      ~(unserialized : Ledger.maskable_ledger) =
    (* reattach the serialized mask to the unserialized ledger *)
    let scan_state, serialized_mask, pending_coinbase_collection =
      serialized
    in
    let attached_mask =
      Ledger.register_mask unserialized
        (Ledger.unattached_mask_of_serializable serialized_mask)
    in
    {scan_state; ledger= attached_mask; pending_coinbase_collection}

  let proof_txns t =
    Scan_state.latest_ledger_proof t.scan_state
    |> Option.bind ~f:(Fn.compose Non_empty_list.of_list_opt snd)

  let chunks_of xs ~n = List.groupi xs ~break:(fun i _ _ -> i mod n = 0)

  let all_work_pairs_exn t =
    let all_jobs = Scan_state.next_jobs t.scan_state |> Or_error.ok_exn in
    let module A = Scan_state.Available_job in
    let module L = Ledger_proof_statement in
    let single_spec (job : job) =
      match Scan_state.extract_from_job job with
      | First (transaction_with_info, statement, witness) ->
          let transaction =
            Or_error.ok_exn @@ Ledger.Undo.transaction transaction_with_info
          in
          Snark_work_lib.Work.Single.Spec.Transition
            (statement, transaction, witness)
      | Second (p1, p2) ->
          let merged =
            Ledger_proof_statement.merge
              (Ledger_proof.statement p1)
              (Ledger_proof.statement p2)
            |> Or_error.ok_exn
          in
          Snark_work_lib.Work.Single.Spec.Merge (merged, p1, p2)
    in
    let all_jobs_paired =
      let pairs = chunks_of all_jobs ~n:2 in
      List.map pairs ~f:(fun js ->
          match js with
          | [j] -> (j, None)
          | [j1; j2] -> (j1, Some j2)
          | _ -> failwith "error pairing jobs" )
    in
    let job_pair_to_work_spec_pair = function
      | j, Some j' -> (single_spec j, Some (single_spec j'))
      | j, None -> (single_spec j, None)
    in
    List.map all_jobs_paired ~f:job_pair_to_work_spec_pair

  let scan_state {scan_state; _} = scan_state

  let pending_coinbase_collection {pending_coinbase_collection; _} =
    pending_coinbase_collection

  let get_target ((proof, _), _) =
    let {Ledger_proof_statement.target; _} = Ledger_proof.statement proof in
    target

  let verify_scan_state_after_apply ledger (scan_state : Scan_state.t) =
    let error_prefix =
      "Error verifying the parallel scan state after applying the diff."
    in
    match Scan_state.latest_ledger_proof scan_state with
    | None ->
        Statement_scanner.check_invariants scan_state ~error_prefix
          ~ledger_hash_end:ledger ~ledger_hash_begin:None
    | Some proof ->
        Statement_scanner.check_invariants scan_state ~error_prefix
          ~ledger_hash_end:ledger
          ~ledger_hash_begin:(Some (get_target proof))

  (* TODO: Remove this. This is deprecated *)
  let snarked_ledger :
      t -> snarked_ledger_hash:Frozen_ledger_hash.t -> Ledger.t Or_error.t =
   fun {ledger; scan_state; _} ~snarked_ledger_hash:expected_target ->
    let open Or_error.Let_syntax in
    let txns_still_being_worked_on =
      Scan_state.staged_transactions scan_state
    in
    Debug_assert.debug_assert (fun () ->
        let parallelism = Scan_state.capacity scan_state in
        let total_capacity_log_2 = Int.ceil_log2 parallelism in
        [%test_pred: int]
          (( >= ) (total_capacity_log_2 * parallelism))
          (List.length txns_still_being_worked_on) ) ;
    let snarked_ledger = Ledger.register_mask ledger (Ledger.Mask.create ()) in
    let%bind () =
      List.fold_left txns_still_being_worked_on ~init:(Ok ()) ~f:(fun acc t ->
          Or_error.bind
            (Or_error.map acc ~f:(fun _ -> t))
            ~f:(fun u -> Ledger.undo snarked_ledger u) )
    in
    let snarked_ledger_hash =
      Ledger.merkle_root snarked_ledger |> Frozen_ledger_hash.of_ledger_hash
    in
    if not (Frozen_ledger_hash.equal snarked_ledger_hash expected_target) then
      Or_error.errorf
        !"Error materializing the snarked ledger with hash \
          %{sexp:Frozen_ledger_hash.t}: "
        expected_target
    else
      match Scan_state.latest_ledger_proof scan_state with
      | None -> return snarked_ledger
      | Some proof ->
          let target = get_target proof in
          if Frozen_ledger_hash.equal snarked_ledger_hash target then
            return snarked_ledger
          else
            Or_error.errorf
              !"Last snarked ledger (%{sexp: Frozen_ledger_hash.t}) is \
                different from the one being requested ((%{sexp: \
                Frozen_ledger_hash.t}))"
              target expected_target

  let statement_exn t =
    match Statement_scanner.scan_statement t.scan_state with
    | Ok s -> `Non_empty s
    | Error `Empty -> `Empty
    | Error (`Error e) -> failwithf !"statement_exn: %{sexp:Error.t}" e ()

  let of_scan_state_and_ledger ~snarked_ledger_hash ~ledger ~scan_state
      ~pending_coinbase_collection =
    let open Deferred.Or_error.Let_syntax in
    let verify_snarked_ledger t snarked_ledger_hash =
      match snarked_ledger t ~snarked_ledger_hash with
      | Ok _ -> Ok ()
      | Error e ->
          Or_error.error_string
            ( "Error verifying snarked ledger hash from the ledger.\n"
            ^ Error.to_string_hum e )
    in
    let t = {ledger; scan_state; pending_coinbase_collection} in
    let%bind () =
      Statement_scanner_with_proofs.check_invariants scan_state
        ~error_prefix:"Staged_ledger.of_scan_state_and_ledger"
        ~ledger_hash_end:
          (Frozen_ledger_hash.of_ledger_hash (Ledger.merkle_root ledger))
        ~ledger_hash_begin:(Some snarked_ledger_hash)
    in
    let%bind () =
      Deferred.return (verify_snarked_ledger t snarked_ledger_hash)
    in
    return t

  let of_scan_state_pending_coinbases_and_snarked_ledger ~scan_state
      ~snarked_ledger ~expected_merkle_root ~pending_coinbases =
    let open Deferred.Or_error.Let_syntax in
    let snarked_ledger_hash = Ledger.merkle_root snarked_ledger in
    let snarked_frozen_ledger_hash =
      Frozen_ledger_hash.of_ledger_hash snarked_ledger_hash
    in
    let%bind txs = Scan_state.all_transactions scan_state |> Deferred.return in
    let%bind () =
      List.fold_result
        ~f:(fun _ tx ->
          Ledger.apply_transaction snarked_ledger tx |> Or_error.ignore )
        ~init:() txs
      |> Deferred.return
    in
    let%bind () =
      let staged_ledger_hash = Ledger.merkle_root snarked_ledger in
      Deferred.return
      @@ Result.ok_if_true
           (Ledger_hash.equal expected_merkle_root staged_ledger_hash)
           ~error:
             (Error.createf
                !"Mismatching merkle root Expected:%{sexp:Ledger_hash.t} \
                  Got:%{sexp:Ledger_hash.t}"
                expected_merkle_root staged_ledger_hash)
    in
    of_scan_state_and_ledger ~snarked_ledger_hash:snarked_frozen_ledger_hash
      ~ledger:snarked_ledger ~scan_state
      ~pending_coinbase_collection:pending_coinbases

  let copy {scan_state; ledger; pending_coinbase_collection} =
    let new_mask = Ledger.Mask.create () in
    { scan_state= Scan_state.copy scan_state
    ; ledger= Ledger.register_mask ledger new_mask
    ; pending_coinbase_collection }

  let hash {scan_state; ledger; pending_coinbase_collection} :
      Staged_ledger_hash.t =
    Staged_ledger_hash.of_aux_ledger_and_coinbase_hash
      (Scan_state.hash scan_state)
      (Ledger.merkle_root ledger)
      pending_coinbase_collection

  [%%if
  call_logger]

  let hash t =
    Coda_debug.Call_logger.record_call "Staged_ledger.hash" ;
    hash t

  [%%endif]

  let ledger {ledger; _} = ledger

  let create_exn ~ledger : t =
    { scan_state= Scan_state.empty ()
    ; ledger
    ; pending_coinbase_collection=
        Pending_coinbase.create () |> Or_error.ok_exn }

  let current_ledger_proof t =
    Option.map
      (Scan_state.latest_ledger_proof t.scan_state)
      ~f:(Fn.compose fst fst)

  let replace_ledger_exn t ledger =
    [%test_result: Ledger_hash.t]
      ~message:"Cannot replace ledger since merkle_root differs"
      ~expect:(Ledger.merkle_root t.ledger)
      (Ledger.merkle_root ledger) ;
    {t with ledger}

  let total_proofs (works : Transaction_snark_work.t list) =
    List.sum (module Int) works ~f:(fun w -> List.length w.proofs)

  let sum_fees xs ~f =
    with_return (fun {return} ->
        Ok
          (List.fold ~init:Fee.Unsigned.zero xs ~f:(fun acc x ->
               match Fee.Unsigned.add acc (f x) with
               | None -> return (Or_error.error_string "Fee overflow")
               | Some res -> res )) )

  let working_stack pending_coinbase_collection ~is_new_stack =
    to_staged_ledger_or_error
      (Pending_coinbase.latest_stack pending_coinbase_collection ~is_new_stack)

  let push_coinbase_and_get_new_collection current_stack (t : Transaction.t) =
    match t with
    | Coinbase c -> Pending_coinbase.Stack.push current_stack c
    | _ -> current_stack

  let apply_transaction_and_get_statement ledger current_stack s =
    let open Result.Let_syntax in
    let%bind fee_excess = Transaction.fee_excess s |> to_staged_ledger_or_error
    and supply_increase =
      Transaction.supply_increase s |> to_staged_ledger_or_error
    in
    let source =
      Ledger.merkle_root ledger |> Frozen_ledger_hash.of_ledger_hash
    in
    let pending_coinbase_after =
      push_coinbase_and_get_new_collection current_stack s
    in
    let%map undo =
      Ledger.apply_transaction ledger s |> to_staged_ledger_or_error
    in
    ( undo
    , { Ledger_proof_statement.source
      ; target= Ledger.merkle_root ledger |> Frozen_ledger_hash.of_ledger_hash
      ; fee_excess
      ; supply_increase
      ; pending_coinbase_stack_state=
          {source= current_stack; target= pending_coinbase_after}
      ; proof_type= `Base }
    , pending_coinbase_after )

  let apply_transaction_and_get_witness ledger current_stack s =
    let open Deferred.Let_syntax in
    let public_keys = function
      | Transaction.Fee_transfer t -> Fee_transfer.receivers t
      | User_command t ->
          let t = (t :> User_command.t) in
          User_command.accounts_accessed t
      | Coinbase c ->
          let ft_receivers =
            Option.value_map c.fee_transfer ~default:[] ~f:(fun ft ->
                Fee_transfer.receivers (Fee_transfer.of_single ft) )
          in
          c.proposer :: ft_receivers
    in
    let ledger_witness =
      measure "sparse ledger" (fun () ->
          Sparse_ledger.of_ledger_subset_exn ledger (public_keys s) )
    in
    let%bind () = Async.Scheduler.yield () in
    let r =
      measure "apply+stmt" (fun () ->
          apply_transaction_and_get_statement ledger current_stack s )
    in
    let%map () = Async.Scheduler.yield () in
    let open Result.Let_syntax in
    let%map undo, statement, updated_coinbase_stack = r in
    ( { Scan_state.Transaction_with_witness.transaction_with_info= undo
      ; witness= {ledger= ledger_witness}
      ; statement }
    , updated_coinbase_stack )

  let update_ledger_and_get_statements ledger current_stack ts =
    let open Deferred.Let_syntax in
    let rec go coinbase_stack acc = function
      | [] -> return (Ok (List.rev acc, coinbase_stack))
      | t :: ts -> (
          match%bind
            apply_transaction_and_get_witness ledger coinbase_stack t
          with
          | Ok (res, updated_coinbase_stack) ->
              go updated_coinbase_stack (res :: acc) ts
          | Error e -> return (Error e) )
    in
    go current_stack [] ts

  let check_completed_works scan_state
      (completed_works : Transaction_snark_work.t list) =
    let open Deferred.Result.Let_syntax in
    let%bind jobses =
      Deferred.return
        (let open Result.Let_syntax in
        let%map jobs =
          to_staged_ledger_or_error
            (Scan_state.next_k_jobs scan_state
               ~k:(total_proofs completed_works))
        in
        chunks_of jobs ~n:Transaction_snark_work.proofs_length)
    in
    let check job_proofs prover message =
      let open Deferred.Let_syntax in
      Deferred.List.find_map job_proofs ~f:(fun (job, proof) ->
          match%map verify ~message job proof prover with
          | Ok () -> None
          | Error e -> Some e )
    in
    let open Deferred.Let_syntax in
    let%map result =
      Deferred.List.find_map (List.zip_exn jobses completed_works)
        ~f:(fun (jobs, work) ->
          let message = Sok_message.create ~fee:work.fee ~prover:work.prover in
          check (List.zip_exn jobs work.proofs) work.prover message )
    in
    Option.value_map result ~default:(Ok ()) ~f:(fun e -> Error e)

  let create_fee_transfers completed_works delta public_key coinbase_fts =
    let open Result.Let_syntax in
    let singles =
      (if Fee.Unsigned.(equal zero delta) then [] else [(public_key, delta)])
      @ List.filter_map completed_works
          ~f:(fun {Transaction_snark_work.fee; prover; _} ->
            if Fee.Unsigned.equal fee Fee.Unsigned.zero then None
            else Some (prover, fee) )
    in
    let%bind singles_map =
      Or_error.try_with (fun () ->
          Compressed_public_key.Map.of_alist_reduce singles ~f:(fun f1 f2 ->
              Option.value_exn (Fee.Unsigned.add f1 f2) ) )
      |> to_staged_ledger_or_error
    in
    (* deduct the coinbase work fee from the singles_map. It is already part of the coinbase *)
    Or_error.try_with (fun () ->
        List.fold coinbase_fts ~init:singles_map ~f:(fun accum single ->
            match Compressed_public_key.Map.find accum (fst single) with
            | None -> accum
            | Some fee ->
                let new_fee =
                  Option.value_exn (Currency.Fee.sub fee (snd single))
                in
                if new_fee > Currency.Fee.zero then
                  Compressed_public_key.Map.update accum (fst single)
                    ~f:(fun _ -> new_fee )
                else Compressed_public_key.Map.remove accum (fst single) )
        (* TODO: This creates a weird incentive to have a small public_key *)
        |> Map.to_alist ~key_order:`Increasing
        |> Fee_transfer.of_single_list )
    |> to_staged_ledger_or_error

  (*A Coinbase is a single transaction that accommodates the coinbase amount
    and a fee transfer for the work required to add the coinbase. Unlike a
    transaction, a coinbase (including the fee transfer) just requires one slot
    in the jobs queue.

    The minimum number of slots required to add a single transaction is three (at
    worst case number of provers: when each pair of proofs is from a different
    prover). One slot for the transaction and two slots for fee transfers.

    When the diff is split into two prediffs (why? refer to #687) and if after
    adding transactions, the first prediff has two slots remaining which cannot
    not accommodate transactions, then those slots are filled by splitting the
    coinbase into two parts.
    If it has one slot, then we simply add one coinbase. It is also possible that
    the first prediff may have no slots left after adding transactions (For
    example, when there are three slots and
    maximum number of provers), in which case, we simply add one coinbase as part
    of the second prediff.
  *)
  let create_coinbase coinbase_parts proposer =
    let open Result.Let_syntax in
    let coinbase = Protocols.Coda_praos.coinbase_amount in
    let coinbase_or_error = function
      | Ok x -> Ok x
      | Error e ->
          Error (Staged_ledger_error.Coinbase_error (Error.to_string_hum e))
    in
    let overflow_err a1 a2 =
      Option.value_map
        ~default:
          (Error
             (Staged_ledger_error.Coinbase_error
                (sprintf
                   !"overflow when splitting coinbase: Minuend: %{sexp: \
                     Currency.Amount.t} Subtrahend: %{sexp: \
                     Currency.Amount.t} \n"
                   a1 a2)))
        (Currency.Amount.sub a1 a2)
        ~f:(fun x -> Ok x)
    in
    let two_parts amt ft1 ft2 =
      let%bind rem_coinbase = overflow_err coinbase amt in
      let%bind _ =
        overflow_err rem_coinbase
          (Option.value_map ~default:Currency.Amount.zero ft2 ~f:(fun single ->
               Currency.Amount.of_fee (snd single) ))
      in
      let%bind cb1 =
        coinbase_or_error
          (Coinbase.create ~amount:amt ~proposer ~fee_transfer:ft1)
      in
      let%map cb2 =
        Coinbase.create ~amount:rem_coinbase ~proposer ~fee_transfer:ft2
        |> coinbase_or_error
      in
      [cb1; cb2]
    in
    match coinbase_parts with
    | `Zero -> return []
    | `One x ->
        let%map cb =
          Coinbase.create ~amount:coinbase ~proposer ~fee_transfer:x
          |> coinbase_or_error
        in
        [cb]
    | `Two None -> two_parts (Currency.Amount.of_int 1) None None
    | `Two (Some (ft1, ft2)) ->
        two_parts (Currency.Amount.of_fee (snd ft1)) (Some ft1) ft2

  let fee_remainder (user_commands : User_command.With_valid_signature.t list)
      completed_works coinbase_fee =
    let open Result.Let_syntax in
    let%bind budget =
      sum_fees user_commands ~f:(fun t -> User_command.fee (t :> User_command.t)
      )
      |> to_staged_ledger_or_error
    in
    let%bind work_fee =
      sum_fees completed_works ~f:(fun {Transaction_snark_work.fee; _} -> fee)
      |> to_staged_ledger_or_error
    in
    let total_work_fee =
      Option.value ~default:Currency.Fee.zero
        (Currency.Fee.sub work_fee coinbase_fee)
    in
    Option.value_map
      ~default:
        (Error (Staged_ledger_error.Insufficient_fee (budget, total_work_fee)))
      ~f:(fun x -> Ok x)
      (Fee.Unsigned.sub budget total_work_fee)

  module Prediff_info = struct
    type ('data, 'work) t =
      { data: 'data
      ; work: 'work list
      ; user_commands_count: int
      ; coinbases: Coinbase.t list }
  end

  let apply_pre_diff coinbase_parts proposer user_commands completed_works =
    let open Deferred.Result.Let_syntax in
    let%map user_commands, coinbase, transactions =
      Deferred.return
        (let open Result.Let_syntax in
        let%bind user_commands =
          let%map user_commands' =
            List.fold_until user_commands ~init:[]
              ~f:(fun acc t ->
                match User_command.check t with
                | Some t -> Continue (t :: acc)
                | None ->
                    (* TODO: punish *)
                    Stop (Error (Staged_ledger_error.Bad_signature t)) )
              ~finish:(fun acc -> Ok acc)
          in
          List.rev user_commands'
        in
        let coinbase_fts =
          match coinbase_parts with
          | `Zero -> []
          | `One (Some ft) -> [ft]
          | `Two (Some (ft, None)) -> [ft]
          | `Two (Some (ft1, Some ft2)) -> [ft1; ft2]
          | _ -> []
        in
        let%bind coinbase_work_fees =
          sum_fees coinbase_fts ~f:snd |> to_staged_ledger_or_error
        in
        let%bind coinbase = create_coinbase coinbase_parts proposer in
        let%bind delta =
          fee_remainder user_commands completed_works coinbase_work_fees
        in
        let%map fee_transfers =
          create_fee_transfers completed_works delta proposer coinbase_fts
        in
        let transactions =
          List.map user_commands ~f:(fun t -> Transaction.User_command t)
          @ List.map coinbase ~f:(fun t -> Transaction.Coinbase t)
          @ List.map fee_transfers ~f:(fun t -> Transaction.Fee_transfer t)
        in
        (user_commands, coinbase, transactions))
    in
    { Prediff_info.data= transactions
    ; work= completed_works
    ; user_commands_count= List.length user_commands
    ; coinbases= coinbase }

  (**The total fee excess caused by any diff should be zero. In the case where
     the slots are split into two partitions, total fee excess of the transactions
     to be enqueued on each of the partitions should be zero respectively *)
  let check_zero_fee_excess scan_state data =
    let zero = Currency.Fee.Signed.zero in
    let partitions = Scan_state.partition_if_overflowing scan_state in
    let txns_from_data data =
      List.fold_right ~init:(Ok []) data
        ~f:(fun (d : Scan_state.Transaction_with_witness.t) acc ->
          let open Or_error.Let_syntax in
          let%bind acc = acc in
          let%map t = d.transaction_with_info |> Ledger.Undo.transaction in
          t :: acc )
    in
    let total_fee_excess txns =
      List.fold txns ~init:(Ok (Some zero)) ~f:(fun fe (txn : Transaction.t) ->
          let open Or_error.Let_syntax in
          let%bind fe' = fe in
          let%map fee_excess = Transaction.fee_excess txn in
          Option.bind fe' ~f:(fun f -> Currency.Fee.Signed.add f fee_excess) )
      |> to_staged_ledger_or_error
    in
    let open Result.Let_syntax in
    let check data slots =
      let%bind txns = txns_from_data data |> to_staged_ledger_or_error in
      let%bind fe = total_fee_excess txns in
      let%bind fe_no_overflow =
        Option.value_map
          ~default:
            (to_staged_ledger_or_error
               (Or_error.error_string "fee excess overflow"))
          ~f:(fun fe -> Ok fe)
          fe
      in
      if Currency.Fee.Signed.equal fe_no_overflow zero then Ok ()
      else Error (Non_zero_fee_excess (slots, txns))
    in
    let%bind () = check (List.take data partitions.first) partitions in
    Option.value_map ~default:(Result.return ())
      ~f:(fun _ -> check (List.drop data partitions.first) partitions)
      partitions.second

  let update_coinbase_stack_and_get_data scan_state ledger
      pending_coinbase_collection transactions =
    let open Deferred.Result.Let_syntax in
    let coinbase_exists ~get_transaction txns =
      List.fold_until ~init:(Ok false) txns
        ~f:(fun acc t ->
          match get_transaction t with
          | Ok (Transaction.Coinbase _) -> Stop (Ok true)
          | Error e -> Stop (Error e)
          | _ -> Continue acc )
        ~finish:Fn.id
      |> Deferred.return
    in
    let {Scan_state.Space_partition.first; second} =
      Scan_state.partition_if_overflowing scan_state
    in
    match second with
    | None ->
        (*Single partition:
         1.Check if a new stack is required and get a working stack [working_stack]
         2.create data for enqueuing into the scan state *)
        let%bind is_new_tree =
          Scan_state.next_on_new_tree scan_state
          |> to_staged_ledger_or_error |> Deferred.return
        in
        let have_data_to_enqueue = List.length transactions > 0 in
        let is_new_stack = is_new_tree && have_data_to_enqueue in
        let%bind working_stack =
          working_stack pending_coinbase_collection ~is_new_stack
          |> Deferred.return
        in
        let%map data, updated_stack =
          update_ledger_and_get_statements ledger working_stack transactions
        in
        (is_new_stack, data, `Update_one updated_stack)
    | Some _ ->
        (*Two partition:
        Assumption: Only one of the partition will have coinbase transaction(s)in it.
         1. Get the latest stack for coinbase in the first set of transactions
         2. get the first set of scan_state data[data1]
         3. get a new stack for the second parition because the second set of transactions would start from the begining of the scan_state
         4. get the second set of scan_state data[data2]*)
        let%bind working_stack1 =
          working_stack pending_coinbase_collection ~is_new_stack:false
          |> Deferred.return
        in
        let%bind data1, updated_stack1 =
          update_ledger_and_get_statements ledger working_stack1
            (List.take transactions first)
        in
        let%bind working_stack2 =
          working_stack pending_coinbase_collection ~is_new_stack:true
          |> Deferred.return
        in
        let%bind data2, updated_stack2 =
          update_ledger_and_get_statements ledger working_stack2
            (List.drop transactions first)
        in
        let%map first_has_coinbase =
          coinbase_exists
            ~get_transaction:(fun x -> Ok x)
            (List.take transactions first)
        in
        let second_has_data = List.length (List.drop transactions first) > 0 in
        let new_stack_in_snark, stack_update =
          match (first_has_coinbase, second_has_data) with
          | true, true -> (false, `Update_two (updated_stack1, updated_stack2))
          (*updated_stack2 will not have any coinbase and therefore we don't want to create a new stack in snark. updated_stack2 is only used to update the pending_coinbase_aux because there's going to be data(second has data) on a "new tree"*)
          | true, false -> (false, `Update_one updated_stack1)
          | false, true -> (true, `Update_one updated_stack2)
          (*updated stack2 has coinbase and it will be on a "new tree"*)
          | false, false -> (false, `Update_none)
        in
        (new_stack_in_snark, data1 @ data2, stack_update)

  (*update the pending_coinbase tree with the updated/new stack and delete the oldest stack if a proof was emitted*)
  let update_pending_coinbase_collection pending_coinbase_collection
      stack_update ~is_new_stack ~ledger_proof =
    let open Result.Let_syntax in
    (*Deleting oldest stack if proof emitted*)
    let%bind pending_coinbase_collection_updated1 =
      match ledger_proof with
      | Some (proof, _) ->
          let%bind oldest_stack, pending_coinbase_collection_updated1 =
            Pending_coinbase.remove_coinbase_stack pending_coinbase_collection
            |> to_staged_ledger_or_error
          in
          let ledger_proof_stack =
            (Ledger_proof.statement proof).pending_coinbase_stack_state.target
          in
          let%map () =
            if Pending_coinbase.Stack.equal oldest_stack ledger_proof_stack
            then Ok ()
            else
              Error
                (Staged_ledger_error.Unexpected
                   (Error.of_string
                      "Pending coinbase stack of the ledger proof did not \
                       match the oldest stack in the pending coinbase tree."))
          in
          pending_coinbase_collection_updated1
      | None -> Ok pending_coinbase_collection
    in
    (*updating the latest stack and/or adding a new one*)
    let%map pending_coinbase_collection_updated2 =
      match stack_update with
      | `Update_none -> Ok pending_coinbase_collection_updated1
      | `Update_one stack1 ->
          Pending_coinbase.update_coinbase_stack
            pending_coinbase_collection_updated1 stack1 ~is_new_stack
          |> to_staged_ledger_or_error
      | `Update_two (stack1, stack2) ->
          (*The case when part of the transactions go in to the old tree and remaining on to the new tree*)
          let%bind update1 =
            Pending_coinbase.update_coinbase_stack
              pending_coinbase_collection_updated1 stack1 ~is_new_stack:false
            |> to_staged_ledger_or_error
          in
          Pending_coinbase.update_coinbase_stack update1 stack2
            ~is_new_stack:true
          |> to_staged_ledger_or_error
    in
    pending_coinbase_collection_updated2

  let coinbase_for_blockchain_snark (coinbases : Coinbase.t list) =
    match coinbases with
    | [] -> Ok Currency.Amount.zero
    | [x] -> Ok x.amount
    | [x; _] -> Ok x.amount
    | _ ->
        Error
          (Staged_ledger_error.Coinbase_error "More than two coinbase parts")

  (* N.B.: we don't expose apply_diff_unverified
     in For_tests only, we expose apply apply_unverified, which calls apply_diff_unverified *)
  let apply_diff t (sl_diff : Staged_ledger_diff.t) ~logger =
    let open Deferred.Result.Let_syntax in
    let max_throughput =
      Int.pow 2
        Transaction_snark_scan_state.Constants.transaction_capacity_log_2
    in
    let%bind spots_available, proofs_waiting =
      let%map jobs =
        Deferred.return
        @@ (Scan_state.next_jobs t.scan_state |> to_staged_ledger_or_error)
      in
      ( Int.min (Scan_state.free_space t.scan_state) max_throughput
      , List.length jobs )
    in
    let apply_pre_diff_with_at_most_two
        (pre_diff1 : Staged_ledger_diff.pre_diff_with_at_most_two_coinbase) =
      let coinbase_parts =
        match pre_diff1.coinbase with
        | Zero -> `Zero
        | One x -> `One x
        | Two x -> `Two x
      in
      apply_pre_diff coinbase_parts sl_diff.creator pre_diff1.user_commands
        pre_diff1.completed_works
    in
    let apply_pre_diff_with_at_most_one
        (pre_diff2 : Staged_ledger_diff.pre_diff_with_at_most_one_coinbase) =
      let coinbase_added =
        match pre_diff2.coinbase with Zero -> `Zero | One x -> `One x
      in
      apply_pre_diff coinbase_added sl_diff.creator pre_diff2.user_commands
        pre_diff2.completed_works
    in
    let%bind () =
      let curr_hash = hash t in
      if Staged_ledger_hash.equal sl_diff.prev_hash (hash t) then return ()
      else
        Deferred.return
          (Error
             (Staged_ledger_error.Bad_prev_hash (curr_hash, sl_diff.prev_hash)))
    in
    let new_mask = Inputs.Ledger.Mask.create () in
    let new_ledger = Inputs.Ledger.register_mask t.ledger new_mask in
    let scan_state' = Scan_state.copy t.scan_state in
    let%bind transactions, works, user_commands_count, coinbases =
      let%bind p1 = apply_pre_diff_with_at_most_two (fst sl_diff.diff) in
      let%map p2 =
        Option.value_map
          ~f:(fun d -> apply_pre_diff_with_at_most_one d)
          (snd sl_diff.diff)
          ~default:
            (Deferred.return
               (Ok
                  { Prediff_info.data= []
                  ; work= []
                  ; user_commands_count= 0
                  ; coinbases= [] }))
      in
      ( p1.data @ p2.data
      , p1.work @ p2.work
      , p1.user_commands_count + p2.user_commands_count
      , p1.coinbases @ p2.coinbases )
    in
    let%bind is_new_stack, data, stack_update =
      update_coinbase_stack_and_get_data scan_state' new_ledger
        t.pending_coinbase_collection transactions
    in
    let%bind () = check_completed_works scan_state' works in
    let%bind () = Deferred.return (check_zero_fee_excess scan_state' data) in
    let%bind res_opt =
      (* TODO: Add rollback *)
      let r =
        Scan_state.fill_work_and_enqueue_transactions scan_state' data works
      in
      Or_error.iter_error r ~f:(fun e ->
          (* TODO: Pass a logger here *)
          eprintf !"Unexpected error: %s %{sexp:Error.t} \n%!" __LOC__ e ) ;
      Deferred.return (to_staged_ledger_or_error r)
    in
    let%bind updated_pending_coinbase_collection' =
      update_pending_coinbase_collection t.pending_coinbase_collection
        stack_update ~is_new_stack ~ledger_proof:res_opt
      |> Deferred.return
    in
    let%bind coinbase_amount =
      coinbase_for_blockchain_snark coinbases |> Deferred.return
    in
    let%map () =
      Deferred.return
        ( verify_scan_state_after_apply
            (Frozen_ledger_hash.of_ledger_hash (Ledger.merkle_root new_ledger))
            scan_state'
        |> to_staged_ledger_or_error )
    in
    Logger.info logger ~module_:__MODULE__ ~location:__LOC__
      ~metadata:
        [ ("user_command_count", `Int user_commands_count)
        ; ("coinbase_count", `Int (List.length coinbases))
        ; ("spots_available", `Int spots_available)
        ; ("proofs_waiting", `Int proofs_waiting)
        ; ("work_count", `Int (List.length works)) ]
      "apply_diff block info: No of transactions included:$user_command_count\n\
      \      Coinbase parts:$coinbase_count Spots\n\
      \      available:$spots_available Pending work in the \
       scan-state:$proofs_waiting Work included:$work_count" ;
    let new_staged_ledger =
      { scan_state= scan_state'
      ; ledger= new_ledger
      ; pending_coinbase_collection= updated_pending_coinbase_collection' }
    in
    ( `Hash_after_applying (hash new_staged_ledger)
    , `Ledger_proof res_opt
    , `Staged_ledger new_staged_ledger
    , `Pending_coinbase_data (is_new_stack, coinbase_amount) )

  let apply t witness ~logger = apply_diff t witness ~logger

  let ok_exn' (t : ('a, Staged_ledger_error.t) Result.t) =
    match t with
    | Ok x -> x
    | Error e -> Error.raise (Staged_ledger_error.to_error e)

  let apply_pre_diff_unchecked coinbase_parts proposer user_commands
      completed_works =
    let txn_works =
      List.map ~f:Transaction_snark_work.forget completed_works
    in
    let coinbase_fts =
      match coinbase_parts with
      | `One (Some ft) -> [ft]
      | `Two (Some (ft, None)) -> [ft]
      | `Two (Some (ft1, Some ft2)) -> [ft1; ft2]
      | _ -> []
    in
    let coinbase_work_fees = sum_fees coinbase_fts ~f:snd |> Or_error.ok_exn in
    let coinbase_parts =
      measure "create_coinbase" (fun () ->
          ok_exn' (create_coinbase coinbase_parts proposer) )
    in
    let delta =
      ok_exn' (fee_remainder user_commands txn_works coinbase_work_fees)
    in
    let fee_transfers =
      ok_exn' (create_fee_transfers txn_works delta proposer coinbase_fts)
    in
    let transactions =
      List.map user_commands ~f:(fun t -> Transaction.User_command t)
      @ List.map coinbase_parts ~f:(fun t -> Transaction.Coinbase t)
      @ List.map fee_transfers ~f:(fun t -> Transaction.Fee_transfer t)
    in
    (transactions, txn_works, coinbase_parts)

  let apply_diff_unchecked t
      (sl_diff : Staged_ledger_diff.With_valid_signatures_and_proofs.t) =
    let open Deferred.Or_error.Let_syntax in
    let apply_pre_diff_with_at_most_two
        (pre_diff1 :
          Staged_ledger_diff.With_valid_signatures_and_proofs
          .pre_diff_with_at_most_two_coinbase) =
      let coinbase_parts =
        match pre_diff1.coinbase with
        | Zero -> `Zero
        | One x -> `One x
        | Two x -> `Two x
      in
      apply_pre_diff_unchecked coinbase_parts sl_diff.creator
        pre_diff1.user_commands pre_diff1.completed_works
    in
    let apply_pre_diff_with_at_most_one
        (pre_diff2 :
          Staged_ledger_diff.With_valid_signatures_and_proofs
          .pre_diff_with_at_most_one_coinbase) =
      let coinbase_added =
        match pre_diff2.coinbase with Zero -> `Zero | One x -> `One x
      in
      apply_pre_diff_unchecked coinbase_added sl_diff.creator
        pre_diff2.user_commands pre_diff2.completed_works
    in
    let new_mask = Inputs.Ledger.Mask.create () in
    let new_ledger = Inputs.Ledger.register_mask t.ledger new_mask in
    let scan_state' = Scan_state.copy t.scan_state in
    let transactions, works, coinbases =
      let data1, work1, coinbases1 =
        apply_pre_diff_with_at_most_two (fst sl_diff.diff)
      in
      let data2, work2, coinbases2 =
        Option.value_map
          ~f:(fun d -> apply_pre_diff_with_at_most_one d)
          (snd sl_diff.diff) ~default:([], [], [])
      in
      (data1 @ data2, work1 @ work2, coinbases1 @ coinbases2)
    in
    let%bind is_new_stack, data, updated_coinbase_stack =
      let open Deferred.Let_syntax in
      let%bind x =
        update_coinbase_stack_and_get_data scan_state' new_ledger
          t.pending_coinbase_collection transactions
      in
      Staged_ledger_error.to_or_error x |> Deferred.return
    in
    let res_opt =
      Or_error.ok_exn
        (Scan_state.fill_work_and_enqueue_transactions scan_state' data works)
    in
    let%bind coinbase_amount =
      coinbase_for_blockchain_snark coinbases
      |> Staged_ledger_error.to_or_error |> Deferred.return
    in
    let%map update_pending_coinbase_collection' =
      update_pending_coinbase_collection t.pending_coinbase_collection
        updated_coinbase_stack ~is_new_stack ~ledger_proof:res_opt
      |> Staged_ledger_error.to_or_error |> Deferred.return
    in
    Or_error.ok_exn
      (verify_scan_state_after_apply
         (Frozen_ledger_hash.of_ledger_hash (Ledger.merkle_root new_ledger))
         scan_state') ;
    let new_staged_ledger =
      { scan_state= scan_state'
      ; ledger= new_ledger
      ; pending_coinbase_collection= update_pending_coinbase_collection' }
    in
    ( `Hash_after_applying (hash new_staged_ledger)
    , `Ledger_proof res_opt
    , `Staged_ledger new_staged_ledger
    , `Pending_coinbase_data (is_new_stack, coinbase_amount) )

  module Resources = struct
    module Discarded = struct
      type t =
        { user_commands_rev: User_command.With_valid_signature.t Sequence.t
        ; completed_work: Transaction_snark_work.Checked.t Sequence.t }
      [@@deriving sexp_of]

      let add_user_command t uc =
        { t with
          user_commands_rev=
            Sequence.append t.user_commands_rev (Sequence.singleton uc) }

      let add_completed_work t cw =
        { t with
          completed_work=
            Sequence.append (Sequence.singleton cw) t.completed_work }
    end

    type t =
      { max_space: int (*max space available currently*)
      ; max_jobs: int (*Max amount of work that can be purchased*)
      ; cur_work_count: int (*Current work capacity of the scan state *)
      ; work_capacity:
          int
          (*max number of pending jobs (currently in the tree and the ones that would arise in the future when current jobs are done) allowed on the tree*)
      ; user_commands_rev: User_command.With_valid_signature.t Sequence.t
      ; completed_work_rev: Transaction_snark_work.Checked.t Sequence.t
      ; fee_transfers: Currency.Fee.t Compressed_public_key.Map.t
      ; coinbase:
          (Compressed_public_key.t * Currency.Fee.t)
          Staged_ledger_diff.At_most_two.t
      ; self_pk: Compressed_public_key.t
      ; budget: Currency.Fee.t Or_error.t
      ; discarded: Discarded.t
      ; logger: Logger.t }

    let coinbase_ft (cw : Transaction_snark_work.t) =
      Option.some_if (cw.fee > Currency.Fee.zero) (cw.prover, cw.fee)

    let init (uc_seq : User_command.With_valid_signature.t Sequence.t)
        (cw_seq : Transaction_snark_work.Checked.t Sequence.t) max_job_count
        max_space self_pk ~add_coinbase cur_work_count logger =
      let seq_rev seq =
        let rec go seq rev_seq =
          match Sequence.next seq with
          | Some (w, rem_seq) ->
              go rem_seq (Sequence.append (Sequence.singleton w) rev_seq)
          | None -> rev_seq
        in
        go seq Sequence.empty
      in
      let cw_unchecked =
        Sequence.map cw_seq ~f:Transaction_snark_work.forget
      in
      let work_capacity = Scan_state.work_capacity in
      let coinbase, rem_cw =
        match (add_coinbase, Sequence.next cw_unchecked) with
        | true, Some (cw, rem_cw) ->
            (Staged_ledger_diff.At_most_two.One (coinbase_ft cw), rem_cw)
        | true, None ->
            (*new count after a coinbase is added should be less than the capacity*)
            let new_count = cur_work_count + 2 in
            if max_job_count = 0 || new_count <= work_capacity then
              (One None, cw_unchecked)
            else (Zero, cw_unchecked)
        | _ -> (Zero, cw_unchecked)
      in
      let singles =
        Sequence.filter_map rem_cw
          ~f:(fun {Transaction_snark_work.fee; prover; _} ->
            if Fee.Unsigned.equal fee Fee.Unsigned.zero then None
            else Some (prover, fee) )
        |> Sequence.to_list_rev
      in
      let fee_transfers =
        Compressed_public_key.Map.of_alist_reduce singles ~f:(fun f1 f2 ->
            Option.value_exn (Fee.Unsigned.add f1 f2) )
      in
      let budget =
        Or_error.map2
          (sum_fees (Sequence.to_list uc_seq) ~f:(fun t ->
               User_command.fee (t :> User_command.t) ))
          (sum_fees singles ~f:snd)
          ~f:(fun r c -> option "budget did not suffice" (Currency.Fee.sub r c))
        |> Or_error.join
      in
      let discarded =
        { Discarded.completed_work= Sequence.empty
        ; user_commands_rev= Sequence.empty }
      in
      { max_space
      ; max_jobs= max_job_count
      ; cur_work_count
      ; work_capacity
      ; user_commands_rev=
          uc_seq
          (*Completed work in reverse order for faster removal of proofs if budget doesn't suffice*)
      ; completed_work_rev= seq_rev cw_seq
      ; fee_transfers
      ; self_pk
      ; coinbase
      ; budget
      ; discarded
      ; logger }

    let re_budget t =
      let revenue =
        sum_fees (Sequence.to_list t.user_commands_rev) ~f:(fun t ->
            User_command.fee (t :> User_command.t) )
      in
      let cost =
        sum_fees (Compressed_public_key.Map.to_alist t.fee_transfers) ~f:snd
      in
      Or_error.map2 revenue cost ~f:(fun r c ->
          option "budget did not suffice" (Currency.Fee.sub r c) )
      |> Or_error.join

    let budget_sufficient t =
      match t.budget with Ok _ -> true | Error _ -> false

    let coinbase_added t =
      match t.coinbase with
      | Staged_ledger_diff.At_most_two.Zero -> 0
      | One _ -> 1
      | Two _ -> 2

    let max_work_done t =
      let no_of_proof_bundles = Sequence.length t.completed_work_rev in
      no_of_proof_bundles = t.max_jobs

    let slots_occupied t =
      let fee_for_self =
        match t.budget with
        | Error _ -> 0
        | Ok b -> if b > Currency.Fee.zero then 1 else 0
      in
      let total_fee_transfer_pks =
        Compressed_public_key.Map.length t.fee_transfers + fee_for_self
      in
      Sequence.length t.user_commands_rev
      + ((total_fee_transfer_pks + 1) / 2)
      + coinbase_added t

    let space_constraint_satisfied t =
      let occupied = slots_occupied t in
      occupied <= t.max_space

    let available_space t = t.max_space - slots_occupied t

    let new_work_count t =
      let occupied = slots_occupied t in
      let total_proofs work =
        Sequence.sum
          (module Int)
          work
          ~f:(fun (w : Transaction_snark_work.Checked.t) ->
            List.length w.proofs )
      in
      let no_of_proofs = total_proofs t.completed_work_rev in
      t.cur_work_count + (occupied * 2) - no_of_proofs

    let within_capacity t =
      let new_count = new_work_count t in
      new_count <= t.work_capacity

    let incr_coinbase_part_by t count =
      let open Or_error.Let_syntax in
      let incr = function
        | Staged_ledger_diff.At_most_two.Zero, ft_opt ->
            Ok (Staged_ledger_diff.At_most_two.One ft_opt)
        | One None, None -> Ok (Two None)
        | One (Some ft), ft_opt -> Ok (Two (Some (ft, ft_opt)))
        | _ -> Or_error.error_string "Coinbase count cannot be more than two"
      in
      let by_one res =
        let res' =
          match
            (Sequence.next res.discarded.completed_work, max_work_done res)
          with
          | Some (w, rem_work), _ ->
              let w' = Transaction_snark_work.forget w in
              let%map coinbase = incr (res.coinbase, coinbase_ft w') in
              { res with
                completed_work_rev=
                  Sequence.append (Sequence.singleton w) res.completed_work_rev
              ; discarded= {res.discarded with completed_work= rem_work}
              ; coinbase }
          | None, true ->
              let%map coinbase = incr (res.coinbase, None) in
              {res with coinbase}
          | _ -> Ok res
        in
        match res' with
        | Ok res'' -> if within_capacity res'' then res'' else res
        | Error e ->
            Logger.error t.logger ~module_:__MODULE__ ~location:__LOC__ "%s"
              (Error.to_string_hum e) ;
            res
      in
      match count with `One -> by_one t | `Two -> by_one (by_one t)

    let work_constraint_satisfied (t : t) =
      (*Are we doing all the work available? *)
      let all_proofs = max_work_done t in
      (*check if the job count doesn't exceed the capacity*)
      let work_capacity_satisfied = within_capacity t in
      (*if there are no user_commands then it doesn't matter how many proofs you have*)
      let uc_count = Sequence.length t.user_commands_rev in
      all_proofs || work_capacity_satisfied || uc_count = 0

    let non_coinbase_work t =
      let len = Sequence.length t.completed_work_rev in
      let cb_work =
        match t.coinbase with
        | Staged_ledger_diff.At_most_two.One (Some _) -> 1
        | Two (Some (_, None)) -> 1
        | Two (Some (_, Some _)) -> 2
        | _ -> 0
      in
      len - cb_work

    let discard_last_work t =
      (*Coinbase work is paid by the coinbase, so don't delete that unless the coinbase itself is deleted*)
      if non_coinbase_work t > 0 then
        match Sequence.next t.completed_work_rev with
        | None -> t
        | Some (w, rem_seq) ->
            let to_be_discarded = Transaction_snark_work.forget w in
            let current_fee =
              Option.value
                (Compressed_public_key.Map.find t.fee_transfers
                   to_be_discarded.prover)
                ~default:Currency.Fee.zero
            in
            let updated_map =
              match Currency.Fee.sub current_fee to_be_discarded.fee with
              | None ->
                  Compressed_public_key.Map.remove t.fee_transfers
                    to_be_discarded.prover
              | Some fee ->
                  if fee > Currency.Fee.zero then
                    Compressed_public_key.Map.update t.fee_transfers
                      to_be_discarded.prover ~f:(fun _ -> fee )
                  else
                    Compressed_public_key.Map.remove t.fee_transfers
                      to_be_discarded.prover
            in
            let discarded = Discarded.add_completed_work t.discarded w in
            let new_t =
              { t with
                completed_work_rev= rem_seq
              ; fee_transfers= updated_map
              ; discarded }
            in
            let budget =
              match t.budget with
              | Ok b ->
                  option "Currency overflow"
                    (Currency.Fee.add b to_be_discarded.fee)
              | _ -> re_budget new_t
            in
            {new_t with budget}
      else t

    let discard_user_command t =
      let decr_coinbase t =
        (*When discarding coinbase's fee transfer, add the fee transfer to the fee_transfers map so that budget checks can be done *)
        let update_fee_transfers t ft coinbase =
          let updated_fee_transfers =
            Compressed_public_key.Map.update t.fee_transfers (fst ft)
              ~f:(fun _ -> snd ft )
          in
          let new_t =
            {t with coinbase; fee_transfers= updated_fee_transfers}
          in
          let updated_budget = re_budget new_t in
          {new_t with budget= updated_budget}
        in
        match t.coinbase with
        | Staged_ledger_diff.At_most_two.Zero -> t
        | One None -> {t with coinbase= Staged_ledger_diff.At_most_two.Zero}
        | Two None -> {t with coinbase= One None}
        | Two (Some (ft, None)) -> {t with coinbase= One (Some ft)}
        | One (Some ft) -> update_fee_transfers t ft Zero
        | Two (Some (ft1, Some ft2)) ->
            update_fee_transfers t ft2 (One (Some ft1))
      in
      match Sequence.next t.user_commands_rev with
      | None ->
          (* If we have reached here then it means we couldn't afford a slot for coinbase as well *)
          decr_coinbase t
      | Some (uc, rem_seq) ->
          let discarded = Discarded.add_user_command t.discarded uc in
          let new_t = {t with user_commands_rev= rem_seq; discarded} in
          let budget =
            match t.budget with
            | Ok b ->
                option "Fee insufficient"
                  (Currency.Fee.sub b (User_command.fee (uc :> User_command.t)))
            | _ -> re_budget new_t
          in
          {new_t with budget}
  end

  let worked_more_than_required (resources : Resources.t) =
    if Resources.non_coinbase_work resources = 0 then false
    else
      (*Is the work constraint satisfied even after discarding a work bundle? *)
      let r = Resources.discard_last_work resources in
      Resources.work_constraint_satisfied r
      && Resources.space_constraint_satisfied r

  let rec check_constraints_and_update (resources : Resources.t) =
    if Resources.slots_occupied resources = 0 then resources
    else if Resources.work_constraint_satisfied resources then
      if
        (*There's enough work. Check if they satisfy other constraints*)
        Resources.budget_sufficient resources
      then
        if Resources.space_constraint_satisfied resources then resources
        else if worked_more_than_required resources then
          (*There are too many fee_transfers(from the proofs) occupying the slots. discard one and check*)
          check_constraints_and_update (Resources.discard_last_work resources)
        else
          (*Well, there's no space; discard a user command *)
          check_constraints_and_update
            (Resources.discard_user_command resources)
      else
        (* insufficient budget; reduce the cost*)
        check_constraints_and_update (Resources.discard_last_work resources)
    else
      (* There isn't enough work for the transactions. Discard a trasnaction and check again *)
      check_constraints_and_update (Resources.discard_user_command resources)

  let one_prediff cw_seq ts_seq self ~add_coinbase available_queue_space
      max_job_count cur_work_count logger =
    O1trace.measure "one_prediff" (fun () ->
        let init_resources =
          Resources.init ts_seq cw_seq max_job_count available_queue_space self
            ~add_coinbase cur_work_count logger
        in
        check_constraints_and_update init_resources )

  let generate logger cw_seq ts_seq self
      (partitions : Scan_state.Space_partition.t) max_job_count cur_work_count
      =
    let pre_diff_with_one (res : Resources.t) :
        Staged_ledger_diff.With_valid_signatures_and_proofs
        .pre_diff_with_at_most_one_coinbase =
      O1trace.measure "pre_diff_with_one" (fun () ->
          let to_at_most_one = function
            | Staged_ledger_diff.At_most_two.Zero ->
                Staged_ledger_diff.At_most_one.Zero
            | One x -> One x
            | _ ->
                Logger.error logger ~module_:__MODULE__ ~location:__LOC__
                  "Error creating diff: Should have at most one coinbase in \
                   the second pre_diff" ;
                Zero
          in
          (* We have to reverse here because we only know they work in THIS order *)
          { Staged_ledger_diff.With_valid_signatures_and_proofs.user_commands=
              Sequence.to_list_rev res.user_commands_rev
          ; completed_works= Sequence.to_list_rev res.completed_work_rev
          ; coinbase= to_at_most_one res.coinbase } )
    in
    let pre_diff_with_two (res : Resources.t) :
        Staged_ledger_diff.With_valid_signatures_and_proofs
        .pre_diff_with_at_most_two_coinbase =
      (* We have to reverse here because we only know they work in THIS order *)
      { user_commands= Sequence.to_list_rev res.user_commands_rev
      ; completed_works= Sequence.to_list_rev res.completed_work_rev
      ; coinbase= res.coinbase }
    in
    let make_diff res1 res2_opt =
      (pre_diff_with_two res1, Option.map res2_opt ~f:pre_diff_with_one)
    in
    let second_pre_diff (res : Resources.t) slots ~add_coinbase =
      let work_count = Sequence.length res.completed_work_rev in
      let max_jobs = max_job_count - work_count in
      let new_capacity = Resources.new_work_count res in
      one_prediff res.discarded.completed_work res.discarded.user_commands_rev
        self slots ~add_coinbase max_jobs new_capacity logger
    in
    let has_no_user_commands (res : Resources.t) =
      Sequence.length res.user_commands_rev = 0
    in
    let isEmpty (res : Resources.t) =
      has_no_user_commands res
      && Resources.coinbase_added res + Sequence.length res.completed_work_rev
         = 0
    in
    (*Partitioning explained in PR #687 *)
    match partitions.second with
    | None ->
        let res =
          one_prediff cw_seq ts_seq self partitions.first ~add_coinbase:true
            max_job_count cur_work_count logger
        in
        make_diff res None
    | Some y ->
        let res =
          one_prediff cw_seq ts_seq self partitions.first ~add_coinbase:false
            max_job_count cur_work_count logger
        in
        let res1, res2 =
          match Resources.available_space res with
          | 0 ->
              (*generate the next prediff with a coinbase at least*)
              let res2 = second_pre_diff res y ~add_coinbase:true in
              (res, Some res2)
          | 1 ->
              (*There's a slot available in the first partition, fill it with coinbase and create another pre_diff for the slots in the second partiton with the remaining user commands and work *)
              let new_res = Resources.incr_coinbase_part_by res `One in
              let res2 = second_pre_diff new_res y ~add_coinbase:false in
              if isEmpty res2 then (new_res, None) else (new_res, Some res2)
          | 2 ->
              (*There are two slots which cannot be filled using user commands, so we split the coinbase into two parts and fill those two spots*)
              let new_res = Resources.incr_coinbase_part_by res `Two in
              let res2 = second_pre_diff new_res y ~add_coinbase:false in
              if has_no_user_commands res2 then
                (*Wait, no transactions included in the next slot? don't split the coinbase*)
                let new_res = Resources.incr_coinbase_part_by res `One in
                (*There could be some free work in res2. Append the free work to res2. We know this is free work because provers are paid using transaction fees and there are no transactions or coinbase in res2*)
                let new_res' =
                  { new_res with
                    completed_work_rev=
                      Sequence.append res2.completed_work_rev
                        new_res.completed_work_rev }
                in
                (new_res', None)
              else (new_res, Some res2)
          | _ ->
              (* Too many slots left in the first partition. Either there wasn't enough work to add transactions or there weren't enough transactions. Create a new pre_diff for just the first partition*)
              let new_res =
                one_prediff cw_seq ts_seq self partitions.first
                  ~add_coinbase:true max_job_count cur_work_count logger
              in
              (new_res, None)
        in
        let coinbase_added =
          Resources.coinbase_added res1
          + Option.value_map ~f:Resources.coinbase_added res2 ~default:0
        in
        if coinbase_added > 0 then make_diff res1 res2
        else
          (*Coinbase takes priority over user-commands. Create a diff in partitions.first with coinbase first and user commands if possible*)
          let res =
            one_prediff cw_seq ts_seq self partitions.first ~add_coinbase:true
              max_job_count cur_work_count logger
          in
          make_diff res None

  let create_diff t ~self ~logger
      ~(transactions_by_fee : User_command.With_valid_signature.t Sequence.t)
      ~(get_completed_work :
            Transaction_snark_work.Statement.t
         -> Transaction_snark_work.Checked.t option) =
    let curr_hash = hash t in
    O1trace.trace_event "curr_hash" ;
    let validating_ledger = Transaction_validator.create t.ledger in
    O1trace.trace_event "done mask" ;
    let partitions = Scan_state.partition_if_overflowing t.scan_state in
    O1trace.trace_event "partitioned" ;
    (*TODO: return an or_error here *)
    let all_work_to_do =
      Scan_state.all_work_to_do t.scan_state |> Or_error.ok_exn
    in
    let unbundled_job_count = Scan_state.current_job_count t.scan_state in
    O1trace.trace_event "computed_work" ;
    let completed_works_seq, proof_count =
      Sequence.fold_until all_work_to_do ~init:(Sequence.empty, 0)
        ~f:(fun (seq, count) w ->
          match get_completed_work w with
          | Some cw_checked ->
              Continue
                ( Sequence.append seq (Sequence.singleton cw_checked)
                , List.length cw_checked.proofs + count )
          | None -> Stop (seq, count) )
        ~finish:Fn.id
    in
    (* max number of jobs that can be done *)
    let max_jobs_count = Sequence.length all_work_to_do in
    O1trace.trace_event "found completed work" ;
    (*Transactions in reverse order for faster removal if there is no space when creating the diff*)
    let valid_on_this_ledger =
      Sequence.fold transactions_by_fee ~init:Sequence.empty ~f:(fun seq t ->
          match
            O1trace.measure "validate txn" (fun () ->
                Transaction_validator.apply_transaction validating_ledger
                  (User_command t) )
          with
          | Error e ->
              Logger.error logger ~module_:__MODULE__ ~location:__LOC__
                ~metadata:
                  [ ( "user_command"
                    , User_command.With_valid_signature.to_yojson t ) ]
                !"Invalid user command! Error was: %s, command was: \
                  $user_command"
                (Error.to_string_hum e) ;
              seq
          | Ok _ -> Sequence.append (Sequence.singleton t) seq )
    in
    let diff =
      O1trace.measure "generate diff" (fun () ->
          generate logger completed_works_seq valid_on_this_ledger self
            partitions max_jobs_count unbundled_job_count )
    in
    Logger.info logger ~module_:__MODULE__ ~location:__LOC__
      "Block stats: Proofs ready for purchase: %d" proof_count ;
    trace_event "prediffs done" ;
    { Staged_ledger_diff.With_valid_signatures_and_proofs.diff
    ; creator= self
    ; prev_hash= curr_hash }

  module For_tests = struct
    let snarked_ledger = snarked_ledger
  end
end

module Make = Make_with_constants (Transaction_snark_scan_state.Constants)

let%test_module "test" =
  ( module struct
    module Test_input1 = struct
      open Coda_pow

      module String = struct
        include String

        let to_yojson s = `String s

        let of_yojson = function
          | `String s -> Ok s
          | _ -> Error "expected string"

        let empty = ""
      end

      (* mirrors module structure of Public_key.Compressed *)
      module Compressed_public_key = struct
        type t = string [@@deriving sexp, compare, yojson, hash]

        module Stable = struct
          module V1 = struct
            type t = string
            [@@deriving sexp, bin_io, compare, eq, yojson, hash]
          end
        end

        let to_yojson, of_yojson = String.(to_yojson, of_yojson)

        include Comparable.Make_binable (String)

        let empty, gen = String.(empty, gen)
      end

      module Sok_message = struct
        module Stable = struct
          module V1 = struct
            module T = struct
              type t = unit [@@deriving bin_io, sexp, yojson, version]
            end

            include T
          end

          module Latest = V1
        end

        module Digest = Unit

        type t = Stable.Latest.t [@@deriving sexp, yojson]

        let create ~fee:_ ~prover:_ = ()
      end

      module Account = struct
        type t = int
      end

      module User_command = struct
        type fee = Fee.Unsigned.t [@@deriving sexp, bin_io, compare, yojson]

        type txn_amt = int [@@deriving sexp, bin_io, compare, eq, yojson]

        type txn_fee = int [@@deriving sexp, bin_io, compare, eq, yojson]

        module Stable = struct
          module V1 = struct
            type t = txn_amt * txn_fee
            [@@deriving sexp, bin_io, compare, eq, yojson]
          end

          module Latest = V1
        end

        type t = Stable.Latest.t [@@deriving sexp, compare, eq, yojson]

        module With_valid_signature = struct
          type t = Stable.Latest.t
          [@@deriving sexp, bin_io, compare, eq, yojson]
        end

        let check : t -> With_valid_signature.t option = fun i -> Some i

        let fee : t -> Fee.Unsigned.t = fun t -> Fee.Unsigned.of_int (snd t)

        (*Fee excess*)
        let sender _ = "S"

        let accounts_accessed _ = ["R"; "S"]
      end

      module Fee_transfer = struct
        type public_key = Compressed_public_key.Stable.V1.t
        [@@deriving sexp, bin_io, compare, eq, yojson, hash]

        type fee = Fee.Unsigned.t
        [@@deriving sexp, bin_io, compare, eq, hash, yojson, hash]

        module Single = struct
          module Stable = struct
            module V1 = struct
              type t = public_key * fee
              [@@deriving bin_io, sexp, compare, eq, yojson, hash]
            end

            module Latest = V1
          end

          type t = Stable.Latest.t [@@deriving sexp, compare, yojson, hash]
        end

        module Stable = struct
          module V1 = struct
            type t =
              | One of Single.Stable.V1.t
              | Two of Single.Stable.V1.t * Single.Stable.V1.t
            [@@deriving bin_io, sexp, compare, eq, yojson]
          end

          module Latest = V1
        end

        type t = Stable.Latest.t =
          | One of Single.Stable.V1.t
          | Two of Single.Stable.V1.t * Single.Stable.V1.t
        [@@deriving sexp, compare, eq, yojson]

        let to_list = function One x -> [x] | Two (x, y) -> [x; y]

        let of_single t = One t

        let of_single_list xs =
          let rec go acc = function
            | x1 :: x2 :: xs -> go (Two (x1, x2) :: acc) xs
            | [] -> acc
            | [x] -> One x :: acc
          in
          go [] xs

        let fee_excess t : fee Or_error.t =
          match t with
          | One (_, fee) -> Ok fee
          | Two ((_, fee1), (_, fee2)) -> (
            match Fee.Unsigned.add fee1 fee2 with
            | None -> Or_error.error_string "Fee_transfer.fee_excess: overflow"
            | Some res -> Ok res )

        let fee_excess_int t =
          Fee.Unsigned.to_int (Or_error.ok_exn @@ fee_excess t)

        let receivers t = List.map (to_list t) ~f:(fun (pk, _) -> pk)
      end

      module Coinbase = struct
        type public_key = string [@@deriving sexp, bin_io, compare, eq, hash]

        type fee_transfer = Fee_transfer.Single.Stable.V1.t
        [@@deriving sexp, bin_io, compare, eq, hash]

        (* TODO : version *)
        type t =
          { proposer: public_key
          ; amount: Currency.Amount.Stable.V1.t
          ; fee_transfer: fee_transfer option }
        [@@deriving sexp, bin_io, compare, eq, hash]

        let supply_increase {proposer= _; amount; fee_transfer} =
          match fee_transfer with
          | None -> Ok amount
          | Some (_, fee) ->
              Currency.Amount.sub amount (Currency.Amount.of_fee fee)
              |> Option.value_map ~f:Or_error.return
                   ~default:(Or_error.error_string "Coinbase underflow")

        let fee_excess t =
          Or_error.map (supply_increase t) ~f:(fun _increase ->
              Currency.Fee.Signed.zero )

        let is_valid {proposer= _; amount; fee_transfer} =
          match fee_transfer with
          | None -> true
          | Some (_, fee) -> Currency.Amount.(of_fee fee <= amount)

        let create ~amount ~proposer ~fee_transfer =
          let t = {proposer; amount; fee_transfer} in
          if is_valid t then Ok t
          else
            Or_error.error_string "Coinbase.create: fee transfer was too high"
      end

      module Transaction = struct
        type valid_user_command = User_command.With_valid_signature.t
        [@@deriving sexp, bin_io, compare, eq]

        type fee_transfer = Fee_transfer.Stable.V1.t
        [@@deriving sexp, bin_io, compare, eq]

        type coinbase = Coinbase.t [@@deriving sexp, bin_io, compare, eq]

        type unsigned_fee = Fee.Unsigned.t [@@deriving sexp, bin_io, compare]

        type t =
          | User_command of valid_user_command
          | Fee_transfer of fee_transfer
          | Coinbase of coinbase
        [@@deriving sexp, bin_io, compare, eq]

        let fee_excess : t -> Fee.Signed.t Or_error.t =
         fun t ->
          let open Or_error.Let_syntax in
          match t with
          | User_command t' ->
              Ok (Currency.Fee.Signed.of_unsigned (User_command.fee t'))
          | Fee_transfer f ->
              let%map fee = Fee_transfer.fee_excess f in
              Currency.Fee.Signed.negate (Currency.Fee.Signed.of_unsigned fee)
          | Coinbase t -> Coinbase.fee_excess t

        let supply_increase = function
          | User_command _ | Fee_transfer _ -> Ok Currency.Amount.zero
          | Coinbase t -> Coinbase.supply_increase t
      end

      module Ledger_hash = struct
        module Stable = struct
          module V1 = struct
            module T = struct
              type t = int
              [@@deriving sexp, bin_io, compare, hash, eq, yojson, version]
            end

            include T
          end

          module Latest = V1
        end

        type t = int [@@deriving sexp, compare, hash, eq]

        include Hashable.Make_binable (Stable.Latest)

        let to_bytes : t -> string =
         fun _ -> failwith "to_bytes in ledger hash"

        let gen = Int.gen
      end

      module Frozen_ledger_hash = struct
        include Ledger_hash

        let of_ledger_hash = Fn.id
      end

      module Pending_coinbase_hash = struct
        module T = struct
          type t = string [@@deriving sexp, bin_io, compare, hash, eq]
        end

        include T

        let to_bytes = Fn.id

        let empty_hash = ""

        include Hashable.Make_binable (T)
      end

      module Pending_coinbase = struct
        module Coinbase_data = struct
          type t =
            Compressed_public_key.Stable.V1.t * Currency.Amount.Stable.V1.t
          [@@deriving bin_io, sexp, compare, hash, eq, yojson]

          let to_string (pk, amt) = pk ^ Currency.Amount.to_string amt

          let of_coinbase (cb : Coinbase.t) : t = (cb.proposer, cb.amount)

          let empty = (Compressed_public_key.empty, Currency.Amount.zero)

          let gen =
            Quickcheck.Generator.tuple2 Compressed_public_key.gen
              Currency.Amount.gen
        end

        module Stack = struct
          type t = Coinbase_data.t list
          [@@deriving sexp, bin_io, compare, hash, eq, yojson]

          let push (t : t) c =
            let cb = Coinbase_data.of_coinbase c in
            cb :: t

          let empty = []

          let gen = Quickcheck.Generator.list_non_empty Coinbase_data.gen
        end

        type t = Stack.t list [@@deriving sexp, bin_io]

        let merkle_root : t -> Pending_coinbase_hash.t =
         fun t ->
          List.map
            ~f:(fun t ->
              List.fold t ~init:"" ~f:(fun acc c ->
                  acc ^ " " ^ Coinbase_data.to_string c ) )
            t
          |> String.concat ~sep:","

        let hash_extra _ = ""

        let latest_stack t ~is_new_stack =
          if is_new_stack then Ok []
          else
            match List.hd t with
            | Some s -> Ok s
            | None -> Or_error.error_string "no stack found"

        let oldest_stack t =
          match List.rev t with [] -> Ok [] | x :: _ -> Ok x

        let create () = Ok []

        let remove_coinbase_stack t =
          match List.rev t with
          | [] ->
              Or_error.error_string
                "tried to remove stack from an empty collection"
          | x :: xs -> Ok (x, List.rev xs)

        let update_coinbase_stack (t : t) (stack : Stack.t) ~is_new_stack =
          if is_new_stack then Ok (stack :: t)
          else
            match t with
            | [] -> Or_error.error_string "tried to update empty tree"
            | _ :: xs -> Ok (stack :: xs)
      end

      module Pending_coinbase_stack_state = struct
        type t =
          {source: Pending_coinbase.Stack.t; target: Pending_coinbase.Stack.t}
        [@@deriving sexp, bin_io, compare, hash, yojson, eq]
      end

      module Ledger_proof_statement = struct
        module Stable = struct
          module V1 = struct
            module T = struct
              type t =
                { source: Ledger_hash.Stable.V1.t
                ; target: Ledger_hash.Stable.V1.t
                ; supply_increase: Currency.Amount.Stable.V1.t
                ; pending_coinbase_stack_state: Pending_coinbase_stack_state.t
                ; fee_excess: Fee.Signed.t
                ; proof_type: [`Base | `Merge] }
              [@@deriving
                sexp, bin_io, compare, hash, yojson, eq, version {for_test}]
            end

            include T

            let merge s1 s2 =
              let open Or_error.Let_syntax in
              let%bind _ =
                if s1.target = s2.source then Ok ()
                else
                  Or_error.errorf
                    !"Invalid merge: target: %s source %s"
                    (Int.to_string s1.target) (Int.to_string s2.source)
              in
              let%map fee_excess =
                Fee.Signed.add s1.fee_excess s2.fee_excess
                |> option "Error adding fees"
              and supply_increase =
                Currency.Amount.add s1.supply_increase s2.supply_increase
                |> option "Error adding supply increases"
              in
              { source= s1.source
              ; target= s2.target
              ; supply_increase
              ; pending_coinbase_stack_state=
                  { Pending_coinbase_stack_state.source=
                      s1.pending_coinbase_stack_state.source
                  ; target= s2.pending_coinbase_stack_state.target }
              ; fee_excess
              ; proof_type= `Merge }
          end

          module Latest = V1
        end

        include Stable.Latest
        include Comparable.Make (Stable.Latest)

        let gen =
          let open Quickcheck.Generator.Let_syntax in
          let%bind source = Ledger_hash.gen
          and target = Ledger_hash.gen
          and fee_excess = Fee.Signed.gen
          and supply_increase = Currency.Amount.gen
          and pending_coinbase_before = Pending_coinbase.Stack.gen
          and pending_coinbase_after = Pending_coinbase.Stack.gen in
          let%map proof_type =
            Quickcheck.Generator.bool
            >>| function true -> `Base | false -> `Merge
          in
          { source
          ; target
          ; supply_increase
          ; fee_excess
          ; proof_type
          ; pending_coinbase_stack_state=
              {source= pending_coinbase_before; target= pending_coinbase_after}
          }
      end

      module Proof = Ledger_proof_statement

      module Ledger_proof = struct
        (*A proof here is a statement *)
        module Stable = struct
          module V1 = Ledger_proof_statement
          module Latest = V1
        end

        type t = Stable.Latest.t [@@deriving sexp, yojson]

        type ledger_hash = Ledger_hash.t

        let statement_target : Ledger_proof_statement.t -> ledger_hash =
         fun statement -> statement.target

        let underlying_proof = Fn.id

        let sok_digest _ = ()

        let statement = Fn.id

        let create ~statement ~sok_digest:_ ~proof:_ = statement
      end

      module Ledger_proof_verifier = struct
        let verify (_ : Ledger_proof.t) (_ : Ledger_proof_statement.t)
            ~message:_ : bool Deferred.t =
          return true
      end

      module Ledger = struct
        (*TODO: Test with a ledger that's more comprehensive*)
        type t = int ref [@@deriving sexp, bin_io, compare]

        type ledger_hash = Ledger_hash.t

        type transaction = Transaction.t [@@deriving sexp, bin_io]

        module Undo = struct
          type t = transaction [@@deriving sexp]

          module Stable = struct
            module V1 = struct
              module T = struct
                type t = transaction
                [@@deriving sexp, bin_io, version {for_test}]
              end

              include T
            end

            module Latest = V1
          end

          module User_command = struct end

          let transaction t = Ok t
        end

        let create ?directory_name:_ () = ref 0

        let copy : t -> t = fun t -> ref !t

        let merkle_root : t -> ledger_hash = fun t -> !t

        let num_accounts _ = 0

        (* BEGIN BOILERPLATE UNUSED *)
        type serializable = int [@@deriving bin_io]

        type maskable_ledger = t

        type attached_mask = t [@@deriving sexp]

        module Mask = struct
          type t = int [@@deriving bin_io]

          let create () = 0
        end

        type unattached_mask = Mask.t

        let unregister_mask_exn _ = failwith "unimplemented"

        let register_mask l _m = copy l

        let remove_and_reparent_exn _ _ ~children:_ = failwith "unimplemented"

        let unattached_mask_of_serializable _ = failwith "unimplemented"

        let serializable_of_t _ = failwith "unimplemented"

        (* END BOILERPLATE UNUSED *)

        let commit _t = ()

        let to_list _ = failwith "unimplemented"

        let apply_transaction : t -> Undo.t -> Undo.t Or_error.t =
         fun t s ->
          match s with
          | User_command t' ->
              t := !t + fst t' ;
              Or_error.return (Transaction.User_command t')
          | Fee_transfer f ->
              let t' = Fee_transfer.fee_excess_int f in
              t := !t + t' ;
              Or_error.return (Transaction.Fee_transfer f)
          | Coinbase c ->
              t := !t + Currency.Amount.to_int c.amount ;
              Or_error.return (Transaction.Coinbase c)

        let undo_transaction : t -> transaction -> unit Or_error.t =
         fun t s ->
          let v =
            match s with
            | User_command t' -> fst t'
            | Fee_transfer f -> Fee_transfer.fee_excess_int f
            | Coinbase c -> Currency.Amount.to_int c.amount
          in
          t := !t - v ;
          Or_error.return ()

        let undo t (txn : Undo.t) = undo_transaction t txn
      end

      module Transaction_validator = struct
        include Ledger

        let apply_user_command _l = failwith "unimplemented"

        let apply_transaction l txn =
          apply_transaction l txn |> Result.map ~f:(Fn.const ())

        type ledger = t

        let create t = copy t
      end

      module Sparse_ledger = struct
        type t = int [@@deriving sexp, bin_io]

        let of_ledger_subset_exn :
            Ledger.t -> Compressed_public_key.t list -> t =
         fun ledger _ -> !ledger

        let merkle_root t = Ledger.merkle_root (ref t)

        let apply_transaction_exn t txn =
          let l : Ledger.t = ref t in
          Or_error.ok_exn (Ledger.apply_transaction l txn) |> ignore ;
          !l
      end

      module Staged_ledger_aux_hash = struct
        include String

        let of_bytes : string -> t = fun s -> s

        let to_bytes : t -> string = fun s -> s
      end

      module Staged_ledger_hash = struct
        module Stable = struct
          module V1 = struct
            module T = struct
              type t = string
              [@@deriving bin_io, sexp, hash, compare, eq, yojson, version]
            end

            include T
          end

          module Latest = V1
        end

        type t = string [@@deriving sexp, eq, compare]

        include Hashable.Make_binable (Stable.Latest)

        type ledger_hash = Ledger_hash.t

        type staged_ledger_aux_hash = Staged_ledger_aux_hash.t

        let ledger_hash _ = failwith "stub"

        let aux_hash _ = failwith "stub"

        let pending_coinbase_hash _ = failwith "stub"

        let of_aux_ledger_and_coinbase_hash :
            staged_ledger_aux_hash -> ledger_hash -> Pending_coinbase.t -> t =
         fun ah h hh -> ah ^ Int.to_string h ^ Pending_coinbase.merkle_root hh
      end

      module Transaction_snark_work = struct
        let proofs_length = 2

        type proof = Ledger_proof.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        type statement = Ledger_proof_statement.Stable.V1.t
        [@@deriving sexp, bin_io, compare, eq, hash, yojson]

        type fee = Fee.Unsigned.t
        [@@deriving sexp, bin_io, compare, hash, yojson]

        type public_key = Compressed_public_key.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        module Stable = struct
          module V1 = struct
            type t = {fee: fee; proofs: proof list; prover: public_key}
            [@@deriving sexp, bin_io, compare, yojson]
          end

          module Latest = V1
        end

        type t = Stable.Latest.t =
          {fee: fee; proofs: proof list; prover: public_key}
        [@@deriving sexp, compare]

        module Statement = struct
          module Stable = struct
            module V1 = struct
              module T = struct
                type t = statement list
                [@@deriving sexp, bin_io, compare, hash, eq, yojson]
              end

              include T
              include Hashable.Make_binable (T)
            end

            module Latest = V1
          end

          type t = Stable.Latest.t [@@deriving sexp, compare, hash, eq, yojson]

          include Hashable.Make (Stable.Latest)

          let gen =
            Quickcheck.Generator.list_with_length proofs_length
              Ledger_proof_statement.gen
        end

        type unchecked = t

        module Checked = struct
          module Stable = Stable

          type t = Stable.Latest.t =
            {fee: fee; proofs: proof list; prover: public_key}
          [@@deriving sexp, compare]

          let create_unsafe = Fn.id
        end

        let forget : Checked.t -> t =
         fun {Checked.fee= f; proofs= p; prover= pr} ->
          {fee= f; proofs= p; prover= pr}
      end

      module Staged_ledger_diff = struct
        type completed_work = Transaction_snark_work.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        type completed_work_checked =
          Transaction_snark_work.Checked.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        type user_command = User_command.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        type fee_transfer_single = Fee_transfer.Single.Stable.V1.t
        [@@deriving sexp, bin_io, yojson]

        type user_command_with_valid_signature =
          User_command.With_valid_signature.t
        [@@deriving sexp, bin_io, compare, yojson]

        type public_key = Compressed_public_key.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        type staged_ledger_hash = Staged_ledger_hash.Stable.V1.t
        [@@deriving sexp, bin_io, compare, yojson]

        module At_most_two = struct
          type 'a t =
            | Zero
            | One of 'a option
            | Two of ('a * 'a option) option
          [@@deriving sexp, bin_io, yojson]

          let increase t ws =
            match (t, ws) with
            | Zero, [] -> Ok (One None)
            | Zero, [a] -> Ok (One (Some a))
            | One _, [] -> Ok (Two None)
            | One _, [a] -> Ok (Two (Some (a, None)))
            | One _, [a; a'] -> Ok (Two (Some (a', Some a)))
            | _ -> Or_error.error_string "Error incrementing coinbase parts"
        end

        module At_most_one = struct
          type 'a t = Zero | One of 'a option
          [@@deriving sexp, bin_io, yojson]

          let increase t ws =
            match (t, ws) with
            | Zero, [] -> Ok (One None)
            | Zero, [a] -> Ok (One (Some a))
            | _ -> Or_error.error_string "Error incrementing coinbase parts"
        end

        type pre_diff_with_at_most_two_coinbase =
          { completed_works: completed_work list
          ; user_commands: user_command list
          ; coinbase: fee_transfer_single At_most_two.t }
        [@@deriving sexp, bin_io, yojson]

        type pre_diff_with_at_most_one_coinbase =
          { completed_works: completed_work list
          ; user_commands: user_command list
          ; coinbase: fee_transfer_single At_most_one.t }
        [@@deriving sexp, bin_io, yojson]

        type diff =
          pre_diff_with_at_most_two_coinbase
          * pre_diff_with_at_most_one_coinbase option
        [@@deriving sexp, bin_io, yojson]

        module Stable = struct
          module V1 = struct
            module T = struct
              type t =
                {diff: diff; prev_hash: staged_ledger_hash; creator: public_key}
              [@@deriving sexp, bin_io, version {for_test}]
            end

            include T
          end

          module Latest = V1
        end

        type t = Stable.Latest.t =
          {diff: diff; prev_hash: staged_ledger_hash; creator: public_key}
        [@@deriving sexp, yojson]

        module With_valid_signatures_and_proofs = struct
          type pre_diff_with_at_most_two_coinbase =
            { completed_works: completed_work_checked list
            ; user_commands: user_command_with_valid_signature list
            ; coinbase: fee_transfer_single At_most_two.t }
          [@@deriving sexp, yojson]

          type pre_diff_with_at_most_one_coinbase =
            { completed_works: completed_work_checked list
            ; user_commands: user_command_with_valid_signature list
            ; coinbase: fee_transfer_single At_most_one.t }
          [@@deriving sexp, yojson]

          type diff =
            pre_diff_with_at_most_two_coinbase
            * pre_diff_with_at_most_one_coinbase option
          [@@deriving sexp, yojson]

          type t =
            {diff: diff; prev_hash: staged_ledger_hash; creator: public_key}
          [@@deriving sexp, yojson]

          let user_commands t =
            (fst t.diff).user_commands
            @ Option.value_map (snd t.diff) ~default:[] ~f:(fun d ->
                  d.user_commands )
        end

        let forget_cw cw_list =
          List.map ~f:Transaction_snark_work.forget cw_list

        let forget_pre_diff_with_at_most_two
            (pre_diff :
              With_valid_signatures_and_proofs
              .pre_diff_with_at_most_two_coinbase) :
            pre_diff_with_at_most_two_coinbase =
          { completed_works= forget_cw pre_diff.completed_works
          ; user_commands= (pre_diff.user_commands :> User_command.t list)
          ; coinbase= pre_diff.coinbase }

        let forget_pre_diff_with_at_most_one
            (pre_diff :
              With_valid_signatures_and_proofs
              .pre_diff_with_at_most_one_coinbase) =
          { completed_works= forget_cw pre_diff.completed_works
          ; user_commands= (pre_diff.user_commands :> User_command.t list)
          ; coinbase= pre_diff.coinbase }

        let forget (t : With_valid_signatures_and_proofs.t) =
          { diff=
              ( forget_pre_diff_with_at_most_two (fst t.diff)
              , Option.map (snd t.diff) ~f:forget_pre_diff_with_at_most_one )
          ; prev_hash= t.prev_hash
          ; creator= t.creator }

        let user_commands (t : t) =
          (fst t.diff).user_commands
          @ Option.value_map (snd t.diff) ~default:[] ~f:(fun d ->
                d.user_commands )
      end

      module Transaction_witness = struct
        module Stable = struct
          module V1 = struct
            module T = struct
              type t = {ledger: Sparse_ledger.t}
              [@@deriving bin_io, sexp, version {for_test}]
            end

            include T
          end

          module Latest = V1
        end

        type t = Stable.Latest.t = {ledger: Sparse_ledger.t} [@@deriving sexp]
      end
    end

    module Sl = Make (Test_input1)
    open Test_input1

    let self_pk = "me"

    let stmt_to_work (stmts : Transaction_snark_work.Statement.t) :
        Transaction_snark_work.Checked.t option =
      let prover =
        List.fold stmts ~init:"P" ~f:(fun p stmt ->
            p ^ Int.to_string stmt.target )
      in
      Some
        { Transaction_snark_work.Checked.fee= Fee.Unsigned.of_int 1
        ; proofs= stmts
        ; prover }

    let stmt_to_work_restricted work_list
        (stmts : Transaction_snark_work.Statement.t) :
        Transaction_snark_work.Checked.t option =
      let prover =
        List.fold stmts ~init:"P" ~f:(fun p stmt ->
            p ^ Int.to_string stmt.target )
      in
      if
        Option.is_some
          (List.find work_list ~f:(fun s ->
               Transaction_snark_work.Statement.equal s stmts ))
      then
        Some
          { Transaction_snark_work.Checked.fee= Fee.Unsigned.of_int 1
          ; proofs= stmts
          ; prover }
      else None

    let create_and_apply sl logger txns stmt_to_work =
      let open Deferred.Let_syntax in
      let diff =
        Sl.create_diff !sl ~self:self_pk ~logger ~transactions_by_fee:txns
          ~get_completed_work:stmt_to_work
      in
      let diff' = Staged_ledger_diff.forget diff in
      let%map ( `Hash_after_applying hash
              , `Ledger_proof ledger_proof
              , `Staged_ledger sl'
              , `Pending_coinbase_data _ ) =
        match%map Sl.apply !sl diff' ~logger with
        | Ok x -> x
        | Error e -> Error.raise (Sl.Staged_ledger_error.to_error e)
      in
      assert (Staged_ledger_hash.equal hash (Sl.hash sl')) ;
      sl := sl' ;
      (ledger_proof, diff')

    let txns n f g = List.zip_exn (List.init n ~f) (List.init n ~f:g)

    let coinbase_added_first_prediff = function
      | Staged_ledger_diff.At_most_two.Zero -> 0
      | One _ -> 1
      | _ -> 2

    let coinbase_added_second_prediff = function
      | Staged_ledger_diff.At_most_one.Zero -> 0
      | _ -> 1

    let coinbase_added (sl_diff : Staged_ledger_diff.t) =
      coinbase_added_first_prediff (fst sl_diff.diff).coinbase
      + Option.value_map ~default:0 (snd sl_diff.diff) ~f:(fun d ->
            coinbase_added_second_prediff d.coinbase )

    let expected_ledger no_txns_included txns_sent old_ledger =
      old_ledger
      + Currency.Amount.to_int Protocols.Coda_praos.coinbase_amount
      + List.sum
          (module Int)
          (List.take txns_sent no_txns_included)
          ~f:(fun (t, fee) -> t + fee)

    let%test_unit "Max throughput" =
      (*Always at worst case number of provers. This is enforced by creating proof bundles *)
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 1 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun _ ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let%map ledger_proof, diff =
                create_and_apply sl logger (Sequence.of_list all_ts)
                  stmt_to_work
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero ledger_proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*At worst case number of provers coinbase should not be split more than two times*)
              assert (cb > 0 && cb < 3) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              assert (x > 0) ;
              let expected_value = expected_ledger x all_ts old_ledger in
              assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_unit "Be able to include random number of user_commands" =
      (*Always at worst case number of provers*)
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 1 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun i ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let ts = List.take all_ts i in
              let%map proof, diff =
                create_and_apply sl logger (Sequence.of_list ts) stmt_to_work
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*At worst case number of provers coinbase should not be split more than two times*)
              assert (cb > 0 && cb < 3) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              let expected_value = expected_ledger x all_ts old_ledger in
              assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_unit "Be able to include random number of user_commands (One \
                   prover)" =
      let get_work (stmts : Transaction_snark_work.Statement.t) :
          Transaction_snark_work.Checked.t option =
        Some
          { Transaction_snark_work.Checked.fee= Fee.Unsigned.of_int 1
          ; proofs= stmts
          ; prover= "P" }
      in
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 1 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun i ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let ts = List.take all_ts i in
              let%map proof, diff =
                create_and_apply sl logger (Sequence.of_list ts) get_work
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*With just one prover, coinbase should never be split*)
              assert (cb = 1) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              let expected_value = expected_ledger x all_ts old_ledger in
              assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_unit "Reproduce invalid statement error" =
      Async.Thread_safe.block_on_async_exn (fun () ->
          (*Always at worst case number of provers*)
          Backtrace.elide := false ;
          let get_work (stmts : Transaction_snark_work.Statement.t) :
              Transaction_snark_work.Checked.t option =
            Some
              { Transaction_snark_work.Checked.fee= Fee.Unsigned.zero
              ; proofs= stmts
              ; prover= "P" }
          in
          let logger = Logger.null () in
          let txns =
            List.init 6 ~f:(fun _ -> [])
            @ [[(1, 0); (1, 0); (1, 0)]] @ [[(1, 0); (1, 0)]]
            @ [[(1, 0); (1, 0)]]
          in
          let ledger = ref 0 in
          let sl = ref (Sl.create_exn ~ledger) in
          let%map _ =
            Deferred.List.fold ~init:() txns ~f:(fun _ ts ->
                let%map _, _ =
                  create_and_apply sl logger (Sequence.of_list ts) get_work
                in
                () )
          in
          () )

    let%test_unit "Invalid diff test: check zero fee excess for partitions" =
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 1 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      let create_diff_with_non_zero_fee_excess prev_hash txns completed_works
          (partition : Sl.Scan_state.Space_partition.t) : Staged_ledger_diff.t
          =
        match partition.second with
        | None ->
            { diff=
                ({completed_works; user_commands= txns; coinbase= Zero}, None)
            ; prev_hash
            ; creator= "C" }
        | Some _ ->
            let diff : Staged_ledger_diff.diff =
              ( { completed_works
                ; user_commands= List.take txns partition.first
                ; coinbase= Zero }
              , Some
                  { completed_works= []
                  ; user_commands= List.drop txns partition.first
                  ; coinbase= Zero } )
            in
            {diff; prev_hash; creator= "C"}
      in
      Quickcheck.test g ~trials:50 ~f:(fun i ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let open Deferred.Let_syntax in
              let logger = Logger.null () in
              let txns = txns i (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let scan_state = Sl.scan_state !sl in
              let work =
                Or_error.ok_exn (Sl.Scan_state.all_work_to_do scan_state)
              in
              let partitions =
                Sl.Scan_state.partition_if_overflowing scan_state
              in
              let work_done =
                Sequence.filter_map
                  ~f:(fun stmts ->
                    Some
                      { Transaction_snark_work.Checked.fee= Fee.Unsigned.zero
                      ; proofs= stmts
                      ; prover= "P" } )
                  work
              in
              let hash = Sl.hash !sl in
              let diff =
                create_diff_with_non_zero_fee_excess hash txns
                  (Sequence.to_list work_done)
                  partitions
              in
              match%map Sl.apply !sl diff ~logger with
              | Error (Sl.Staged_ledger_error.Non_zero_fee_excess _) -> ()
              | Error _ -> assert false
              | Ok
                  ( `Hash_after_applying _hash
                  , `Ledger_proof _ledger_proof
                  , `Staged_ledger sl'
                  , `Pending_coinbase_data _ ) ->
                  sl := sl' ) )

    let%test_unit "Snarked ledger" =
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 1 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      let expected_snarked_ledger = ref 0 in
      Quickcheck.test g ~trials:50 ~f:(fun i ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let ts = List.take all_ts i in
              let%map proof, _ =
                create_and_apply sl logger (Sequence.of_list ts) stmt_to_work
              in
              let last_snarked_ledger =
                Option.value_map ~default:!expected_snarked_ledger
                  ~f:(fun (p, _) -> p.target)
                  proof
              in
              expected_snarked_ledger := last_snarked_ledger ;
              let materialized_ledger =
                Or_error.ok_exn
                @@ Sl.For_tests.snarked_ledger !sl
                     ~snarked_ledger_hash:last_snarked_ledger
              in
              assert (!expected_snarked_ledger = !materialized_ledger) ) )

    let%test_unit "max throughput-random number of proofs-worst case provers" =
      (*Always at worst case number of provers*)
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g = Int.gen_incl 0 p in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun i ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let work_list : Transaction_snark_work.Statement.t list =
                let spec_list = Sl.all_work_pairs_exn !sl in
                List.map spec_list ~f:(fun (s1, s2_opt) ->
                    let stmt1 = Snark_work_lib.Work.Single.Spec.statement s1 in
                    let stmt2 =
                      Option.value_map s2_opt ~default:[] ~f:(fun s ->
                          [Snark_work_lib.Work.Single.Spec.statement s] )
                    in
                    stmt1 :: stmt2 )
              in
              let%map proof, diff =
                create_and_apply sl logger (Sequence.of_list all_ts)
                  (stmt_to_work_restricted (List.take work_list i))
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*coinbase is zero only when there are no proofs created*)
              if i > 0 then assert (cb > 0 && cb < 3) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              let expected_value = expected_ledger x all_ts old_ledger in
              if cb > 0 then assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_unit "random no of transactions-random number of proofs-worst \
                   case provers" =
      (*Always at worst case number of provers*)
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g =
        Quickcheck.Generator.tuple2 (Int.gen_incl 1 p) (Int.gen_incl 0 p)
      in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun (i, j) ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let ts = List.take all_ts i in
              let work_list : Transaction_snark_work.Statement.t list =
                let spec_list = Sl.all_work_pairs_exn !sl in
                List.map spec_list ~f:(fun (s1, s2_opt) ->
                    let stmt1 = Snark_work_lib.Work.Single.Spec.statement s1 in
                    let stmt2 =
                      Option.value_map s2_opt ~default:[] ~f:(fun s ->
                          [Snark_work_lib.Work.Single.Spec.statement s] )
                    in
                    stmt1 :: stmt2 )
              in
              let%map proof, diff =
                create_and_apply sl logger (Sequence.of_list ts)
                  (stmt_to_work_restricted (List.take work_list j))
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*coinbase is zero only when there are no proofs created*)
              if j > 0 then assert (cb > 0 && cb < 3) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              let expected_value = expected_ledger x all_ts old_ledger in
              if cb > 0 then assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_unit "Random number of user_commands-random number of proofs-one \
                   prover)" =
      let get_work work_list (stmts : Transaction_snark_work.Statement.t) :
          Transaction_snark_work.Checked.t option =
        if
          Option.is_some
            (List.find work_list ~f:(fun s ->
                 Transaction_snark_work.Statement.equal s stmts ))
        then
          Some
            { Transaction_snark_work.Checked.fee= Fee.Unsigned.of_int 1
            ; proofs= stmts
            ; prover= "P" }
        else None
      in
      Backtrace.elide := false ;
      let logger = Logger.null () in
      let p =
        Int.pow 2
          Transaction_snark_scan_state.Constants.transaction_capacity_log_2
      in
      let g =
        Quickcheck.Generator.tuple2 (Int.gen_incl 1 p) (Int.gen_incl 0 p)
      in
      let initial_ledger = ref 0 in
      let sl = ref (Sl.create_exn ~ledger:initial_ledger) in
      Quickcheck.test g ~trials:1000 ~f:(fun (i, j) ->
          Async.Thread_safe.block_on_async_exn (fun () ->
              let old_ledger = !(Sl.ledger !sl) in
              let all_ts = txns p (fun x -> (x + 1) * 100) (fun _ -> 4) in
              let ts = List.take all_ts i in
              let work_list : Transaction_snark_work.Statement.t list =
                let spec_list = Sl.all_work_pairs_exn !sl in
                List.map spec_list ~f:(fun (s1, s2_opt) ->
                    let stmt1 = Snark_work_lib.Work.Single.Spec.statement s1 in
                    let stmt2 =
                      Option.value_map s2_opt ~default:[] ~f:(fun s ->
                          [Snark_work_lib.Work.Single.Spec.statement s] )
                    in
                    stmt1 :: stmt2 )
              in
              let%map proof, diff =
                create_and_apply sl logger (Sequence.of_list ts)
                  (get_work (List.take work_list j))
              in
              let fee_excess =
                Option.value_map ~default:Currency.Fee.Signed.zero proof
                  ~f:(fun proof ->
                    let stmt = Ledger_proof.statement proof in
                    (fst stmt).fee_excess )
              in
              (*fee_excess at the top should always be zero*)
              assert (
                Currency.Fee.Signed.equal fee_excess Currency.Fee.Signed.zero
              ) ;
              let cb = coinbase_added diff in
              (*With just one prover, coinbase should never be split*)
              if j > 0 then assert (cb = 1) ;
              let x = List.length (Staged_ledger_diff.user_commands diff) in
              (*There are than two proof bundles. Should be able to add at least one payment. First and the second proof bundles would go for coinbase and fee_transfer resp.*)
              if j > 2 then assert (x > 0) ;
              let expected_value = expected_ledger x all_ts old_ledger in
              if cb > 0 then assert (!(Sl.ledger !sl) = expected_value) ) )

    let%test_module "staged ledgers with different latency factors" =
      ( module struct
        module Inputs = Test_input1

        module type Staged_ledger_intf =
          Coda_pow.Staged_ledger_intf
          with type diff := Inputs.Staged_ledger_diff.t
           and type valid_diff :=
                      Inputs.Staged_ledger_diff
                      .With_valid_signatures_and_proofs
                      .t
           and type ledger_hash := Inputs.Ledger_hash.t
           and type frozen_ledger_hash := Inputs.Frozen_ledger_hash.t
           and type staged_ledger_hash := Inputs.Staged_ledger_hash.t
           and type public_key := Inputs.Compressed_public_key.t
           and type ledger := Inputs.Ledger.t
           and type user_command_with_valid_signature :=
                      Inputs.User_command.With_valid_signature.t
           and type statement := Inputs.Transaction_snark_work.Statement.t
           and type completed_work_checked :=
                      Inputs.Transaction_snark_work.Checked.t
           and type ledger_proof := Inputs.Ledger_proof.t
           and type staged_ledger_aux_hash := Inputs.Staged_ledger_aux_hash.t
           and type sparse_ledger := Inputs.Sparse_ledger.t
           and type ledger_proof_statement := Inputs.Ledger_proof_statement.t
           and type ledger_proof_statement_set :=
                      Inputs.Ledger_proof_statement.Set.t
           and type transaction := Inputs.Transaction.t
           and type user_command := Inputs.User_command.t
           and type transaction_witness := Inputs.Transaction_witness.t
           and type pending_coinbase_collection := Inputs.Pending_coinbase.t

        let transaction_capacity_log_2 = 2

        let sl_modules =
          List.init 4 ~f:(fun i ->
              let module Constants = struct
                let transaction_capacity_log_2 = transaction_capacity_log_2

                let work_delay_factor = 5

                let latency_factor = i
              end in
              (module Make_with_constants (Constants) (Inputs)
              : Staged_ledger_intf ) )

        let%test_unit "max throughput at any latency: random number of \
                       proofs-one prover" =
          Backtrace.elide := false ;
          let get_work work_list (stmts : Transaction_snark_work.Statement.t) :
              Transaction_snark_work.Checked.t option =
            if
              Option.is_some
                (List.find work_list ~f:(fun s ->
                     Transaction_snark_work.Statement.equal s stmts ))
            then
              Some
                { Transaction_snark_work.Checked.fee= Fee.Unsigned.of_int 0
                ; proofs= stmts
                ; prover= "P" }
            else None
          in
          let logger = Logger.null () in
          let p = Int.pow 2 transaction_capacity_log_2 in
          let g = Int.gen_incl 0 p in
          List.iter sl_modules ~f:(fun (module Sl) ->
              let initial_ledger = ref 0 in
              let staged_ledger = ref (Sl.create_exn ~ledger:initial_ledger) in
              let create_and_apply sl logger txns stmt_to_work =
                let open Deferred.Let_syntax in
                let diff =
                  Sl.create_diff !sl ~self:self_pk ~logger
                    ~transactions_by_fee:txns ~get_completed_work:stmt_to_work
                in
                let diff' = Staged_ledger_diff.forget diff in
                let%map ( `Hash_after_applying _
                        , `Ledger_proof _
                        , `Staged_ledger sl'
                        , `Pending_coinbase_data _ ) =
                  match%map Sl.apply !sl diff' ~logger with
                  | Ok x -> x
                  | Error e -> Error.raise (Sl.Staged_ledger_error.to_error e)
                in
                sl := sl' ;
                diff'
              in
              Quickcheck.test g ~trials:100 ~f:(fun _ ->
                  Async.Thread_safe.block_on_async_exn (fun () ->
                      let all_ts =
                        txns p (fun x -> (x + 1) * 100) (fun _ -> 0)
                      in
                      let work_list : Transaction_snark_work.Statement.t list =
                        let capacity_reached =
                          Sl.Scan_state.work_capacity
                          >= Sl.Scan_state.current_job_count
                               (Sl.scan_state !staged_ledger)
                        in
                        let spec_list =
                          if capacity_reached then
                            Sl.all_work_pairs_exn !staged_ledger
                          else []
                        in
                        List.map spec_list ~f:(fun (s1, s2_opt) ->
                            let stmt1 =
                              Snark_work_lib.Work.Single.Spec.statement s1
                            in
                            let stmt2 =
                              Option.value_map s2_opt ~default:[] ~f:(fun s ->
                                  [Snark_work_lib.Work.Single.Spec.statement s]
                              )
                            in
                            stmt1 :: stmt2 )
                      in
                      let%map diff =
                        create_and_apply staged_ledger logger
                          (Sequence.of_list all_ts) (get_work work_list)
                      in
                      let cb = coinbase_added diff in
                      assert (cb > 0 && cb < 3) ;
                      let x =
                        List.length (Staged_ledger_diff.user_commands diff)
                      in
                      (*max throughput*)
                      assert (x + cb = p) ) ) )
      end )
  end )
