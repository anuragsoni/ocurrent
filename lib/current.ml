open Lwt.Infix

let src = Logs.Src.create "current" ~doc:"OCurrent engine"
module Log = (val Logs.src_log src : Logs.LOG)

type 'a or_error = ('a, [`Msg of string]) result

module Input = struct
  class type watch = object
    method pp : Format.formatter -> unit
    method changed : unit Lwt.t
    method cancel : (unit -> unit) option
    method release : unit
  end

  type 'a t = unit -> 'a Current_term.Output.t * watch list

  let of_fn t = t

  let get (t : 'a t) = t ()

  let pp_watch f t = t#pp f
end

include Current_term.Make(Input)

type 'a term = 'a t

module Var (T : Current_term.S.T) = struct
  type t = {
    mutable current : T.t Current_term.Output.t;
    name : string;
    cond : unit Lwt_condition.t;
  }

  let create ~name current =
    { current; name; cond = Lwt_condition.create () }

  let watch t =
    let v = t.current in
    object
      method pp f = Fmt.string f t.name

      method changed =
        let rec aux () =
          if Current_term.Output.equal T.equal t.current v then
            Lwt_condition.wait t.cond >>= aux
          else
            Lwt.return ()
        in aux ()

      method release = ()

      method cancel = None
    end

  let get t =
    track (fun () -> t.current, [watch t] )

  let set t v =
    t.current <- v;
    Lwt_condition.broadcast t.cond ()

  let update t f =
    t.current <- f t.current;
    Lwt_condition.broadcast t.cond ()
end

let default_trace r inputs =
  Log.info (fun f ->
      f "@[<v2>Evaluation complete:@,\
         Result: %a@,\
         Watching: %a@]"
        Current_term.(Output.pp Fmt.(unit "()")) r
        Fmt.(Dump.list Input.pp_watch) inputs
    )

module Engine = struct
  let run ?(trace=default_trace) f =
    let rec aux ~old_watches =
      Log.info (fun f -> f "Evaluating...");
      let r, watches = Executor.run (f ()) in
      List.iter (fun w -> w#release) old_watches;
      trace r watches;
      Log.info (fun f -> f "Waiting for inputs to change...");
      Lwt.choose (List.map (fun w -> w#changed) watches) >>= fun () ->
      aux ~old_watches:watches
    in
    aux ~old_watches:[]
end

let state_dir_root = Fpath.v @@ Filename.concat (Sys.getcwd ()) "var"

let state_dir name =
  let name = Fpath.v name in
  assert (Fpath.is_rel name);
  let path = Fpath.append state_dir_root name in
  match Bos.OS.Dir.create path with
  | Ok (_ : bool) -> path
  | Error (`Msg m) -> failwith m

module Monitor : sig
  val create :
    read:(unit -> 'a or_error Lwt.t) ->
    watch:((unit -> unit) -> (unit -> unit Lwt.t) Lwt.t) ->
    pp:(Format.formatter -> unit) ->
    'a Input.t
end = struct
  type 'a t = {
    read : unit -> 'a or_error Lwt.t;
    watch : (unit -> unit) -> (unit -> unit Lwt.t) Lwt.t;
    pp : Format.formatter -> unit;
    mutable value : 'a Current_term.Output.t;
    mutable ref_count : int;              (* Number of terms using this input *)
    mutable need_refresh : bool;          (* Update detected after current read started *)
    mutable active : bool;                (* Monitor thread is running *)
    cond : unit Lwt_condition.t;          (* Maybe time to leave the "wait" state *)
    external_cond : unit Lwt_condition.t; (* New value ready for external user *)
  }

  let refresh t () =
    t.need_refresh <- true;
    Lwt_condition.broadcast t.cond ()

  let rec enable t =
    t.watch (refresh t) >>= fun unwatch ->
    if t.ref_count = 0 then disable ~unwatch t
    else get_value t ~unwatch
  and disable ~unwatch t =
    unwatch () >>= fun () ->
    if t.ref_count > 0 then enable t
    else (
      assert (t.active);
      t.active <- false;
      (* Clear the saved value, so that if we get activated again then we don't
         start by serving up the previous value, which could be quite stale by then. *)
      t.value <- Error `Pending;
      Lwt.return `Finished
    )
  and get_value ~unwatch t =
    t.need_refresh <- false;
    t.read () >>= fun v ->
    t.value <- (v :> _ Current_term.Output.t);
    Lwt_condition.broadcast t.external_cond ();
    wait ~unwatch t
  and wait ~unwatch t =
    if t.ref_count = 0 then disable ~unwatch t
    else if t.need_refresh then get_value ~unwatch t
    else Lwt_condition.wait t.cond >>= fun () -> wait ~unwatch t

  let run t =
    Input.of_fn @@ fun () ->
    t.ref_count <- t.ref_count + 1;
    if not t.active then (
      t.active <- true;
      Lwt.async (fun () -> enable t >|= fun `Finished -> ())
    );  (* (else the previous thread will check [ref_count] before exiting) *)
    let changed = Lwt_condition.wait t.external_cond in
    let watch =
      object
        method changed = changed
        method cancel = None
        method pp f = t.pp f
        method release =
          assert (t.ref_count > 0);
          t.ref_count <- t.ref_count - 1;
          if t.ref_count = 0 then Lwt_condition.broadcast t.cond ()
      end
    in
    t.value, [watch]

  let create ~read ~watch ~pp =
    let cond = Lwt_condition.create () in
    let external_cond = Lwt_condition.create () in
    let t = {
      ref_count = 0;
      active = false;
      need_refresh = true;
      cond; external_cond;
      value = Error `Pending;
      read; watch; pp
    } in
    run t
end

let monitor = Monitor.create
