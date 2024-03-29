(**************************************************************************)
(*                                                                        *)
(*  This file is part of the Frama-C's E-ACSL plug-in.                    *)
(*                                                                        *)
(*  Copyright (C) 2012-2019                                               *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

module Libc = Functions.Libc
module RTL = Functions.RTL
module E_acsl_label = Label
open Cil_types
open Cil_datatype

let dkey = Options.dkey_translation

(* ************************************************************************** *)
(* Visitor *)
(* ************************************************************************** *)

(* local references to the below visitor and to [do_visit] *)
let function_env = ref Env.dummy
let dft_funspec = Cil.empty_funspec ()
let funspec = ref dft_funspec

(* extend the environment with statements which allocate/deallocate memory
   blocks *)
module Memory: sig
  val store: ?before:stmt -> Env.t -> kernel_function -> varinfo list -> Env.t
  val duplicate_store:
    ?before:stmt -> Env.t -> kernel_function -> Varinfo.Set.t -> Env.t
  val delete_from_list:
    ?before:stmt -> Env.t -> kernel_function -> varinfo list -> Env.t
  val delete_from_set:
    ?before:stmt -> Env.t -> kernel_function -> Varinfo.Set.t -> Env.t
end = struct

  let tracking_stmt ?before fold mk_stmt env kf vars =
    if Functions.instrument kf then
      fold
        (fun vi env ->
           if Mmodel_analysis.must_model_vi ~kf vi then
             let vi = Visitor_behavior.Get.varinfo (Env.get_behavior env) vi in
             Env.add_stmt ?before env (mk_stmt vi)
           else
             env)
        vars
        env
    else
      env

  let store ?before env kf vars =
    tracking_stmt
      ?before
      List.fold_right (* small list *)
      Misc.mk_store_stmt
    env
      kf
      vars

  let duplicate_store ?before env kf vars =
    tracking_stmt
      ?before
      Varinfo.Set.fold
      Misc.mk_duplicate_store_stmt
      env
      kf
      vars

  let delete_from_list ?before env kf vars =
    tracking_stmt
      ?before
      List.fold_right (* small list *)
      Misc.mk_delete_stmt
      env
      kf
      vars

  let delete_from_set ?before env kf vars =
    tracking_stmt
      ?before
      Varinfo.Set.fold
      Misc.mk_delete_stmt
      env
      kf
      vars

end

(* Observation of literal strings in C expressions *)
module Literal_observer: sig

  val exp: Env.t -> exp -> exp * Env.t
  (* replace the given exp by an observed variable if it is a literal string *)

  val exp_in_depth: Env.t -> exp -> exp * Env.t
  (* replace any sub-expression of the given exp that is a literal string by an
     observed variable   *)

end =
struct

  let literal loc env s =
    try
      let vi = Literal_strings.find s in
      (* if the literal string was already created, just get it. *)
      Cil.evar ~loc vi, env
    with Not_found ->
      (* never seen this string before: replace it by a new global var *)
      let vi, exp, env =
        Env.new_var
          ~loc
          ~scope:Varname.Global
          ~name:"literal_string"
          env
          None
          Cil.charPtrType
          (fun _ _ -> [] (* done in the initializer, see {!vglob_aux} *))
      in
      Literal_strings.add s vi;
      exp, env

  let exp env e = match e.enode with
    (* the guard below could be optimized: if no annotation **depends on this
       string**, then it is not required to monitor it.
       (currently, the guard says: "no annotation uses the memory model" *)
    | Const (CStr s) when Mmodel_analysis.use_model () -> literal e.eloc env s
    | _ -> e, env

  let exp_in_depth env e =
    let env_ref = ref env in
    let o = object
      inherit Cil.genericCilVisitor (Visitor_behavior.copy (Project.current ()))
      method !vexpr e = match e.enode with
      (* the guard below could be optimized: if no annotation **depends on this
         string**, then it is not required to monitor it.
         (currently, the guard says: "no annotation uses the memory model" *)
      | Const (CStr s) when Mmodel_analysis.use_model () ->
        let e, env = literal e.eloc !env_ref s in
        env_ref := env;
        Cil.ChangeTo e
      | _ ->
        Cil.DoChildren
    end in
    let e = Cil.visitCilExpr o e in
    e, !env_ref

end

(* Observation of global variables. *)
module Global_observer: sig
  val function_name: string (* name of the function in which [mk_init] generates
                               the code *)
  val reset: unit -> unit
  val is_empty: unit -> bool

  val add: varinfo -> unit (* observes the given variable if necessary *)
  val add_initializer: varinfo -> offset -> init -> unit
  (* add the initializer for the given observed variable *)

  val mk_init: Visitor_behavior.t -> Env.t -> varinfo * fundec * Env.t
  (* generates a new C function containing the observers for global variable
     declaration and initialization *)

  val mk_delete: Visitor_behavior.t -> stmt list -> stmt list
  (* generates the observers for global variable de-allocation *)

end = struct

  let function_name = RTL.mk_api_name "globals_init"

  (* Hashtable mapping global variables (as Cil_type.varinfo) to their
     initializers (if any).

     NOTE: here, varinfos as keys belong to the original project while values
     belong to the new one *)
  let tbl
      : (offset (* compound initializers *) * init) list ref Varinfo.Hashtbl.t
      = Varinfo.Hashtbl.create 7

  let reset () = Varinfo.Hashtbl.reset tbl

  let is_empty () = Varinfo.Hashtbl.length tbl = 0

  let add vi =
    if Mmodel_analysis.must_model_vi vi then
      Varinfo.Hashtbl.replace tbl vi (ref [])

  let add_initializer vi offset init =
    if Mmodel_analysis.must_model_vi vi then
      try
        let l = Varinfo.Hashtbl.find tbl vi in
        l := (offset, init) :: !l
      with Not_found ->
        assert false

  let rec literal_in_initializer env = function
    | SingleInit exp -> snd (Literal_observer.exp_in_depth env exp)
    | CompoundInit (_, l) ->
      List.fold_left (fun env (_, i) -> literal_in_initializer env i) env l

  let mk_init bhv env =
    (* Create [__e_acsl_globals_init] function with definition
       for initialization of global variables *)
    let vi =
      Cil.makeGlobalVar ~source:true
        function_name
        (TFun(Cil.voidType, Some [], false, []))
    in
    vi.vdefined <- true;
    (* There is no contract associated with the function *)
    let spec = Cil.empty_funspec () in
    (* Create function definition which no stmt yet: they will be added
       afterwards *)
    let blk = Cil.mkBlock [] in
    let fundec =
      { svar = vi;
        sformals = [];
        slocals = [];
        smaxid = 0;
        sbody = blk;
        smaxstmtid = None;
        sallstmts = [];
        sspec = spec }
    in
    let fct = Definition(fundec, Location.unknown) in
    (* Create and register [__e_acsl_globals_init] as kernel
       function *)
    let kf =
      { fundec = fct; spec = spec }
    in
    Globals.Functions.register kf;
    Globals.Functions.replace_by_definition spec fundec Location.unknown;
    (* Now generate the statements. The generation is done only now because it
       depends on the local variable [already_run] whose generation required the
       existence of [fundec] *)
    let env = Env.push env in
    (* 2-stage observation of initializers: temporal analysis must be performed
       after generating observers of **all** globals *)
    let env, stmts =
      Varinfo.Hashtbl.fold_sorted
        (fun old_vi l stmts ->
          let new_vi = Visitor_behavior.Get.varinfo bhv old_vi in
          List.fold_left
            (fun (env, stmts) (off, init) ->
              let env = literal_in_initializer env init in
              let stmt = Temporal.generate_global_init new_vi off init env in
              env, match stmt with None -> stmts | Some stmt -> stmt :: stmts)
            stmts
            !l)
        tbl
        (env, [])
    in
    (* allocation and initialization of globals *)
    let stmts =
      Varinfo.Hashtbl.fold_sorted
        (fun old_vi _ stmts ->
          let new_vi = Visitor_behavior.Get.varinfo bhv old_vi in
          (* a global is both allocated and initialized *)
          Misc.mk_store_stmt new_vi
          :: Misc.mk_initialize ~loc:Location.unknown (Cil.var new_vi)
          :: stmts)
        tbl
        stmts
    in
    (* literal strings allocations and initializations *)
    let stmts =
      Literal_strings.fold
        (fun s vi stmts ->
          let loc = Location.unknown in
          let e = Cil.new_exp ~loc:loc (Const (CStr s)) in
          let str_size = Cil.new_exp loc (SizeOfStr s) in
          Cil.mkStmtOneInstr ~valid_sid:true (Set(Cil.var vi, e, loc))
          :: Misc.mk_store_stmt ~str_size vi
          :: Misc.mk_full_init_stmt ~addr:false vi
          :: Misc.mk_mark_readonly vi
          :: stmts)
        stmts
    in
    (* Create a new code block with generated statements *)
    let (b, env), stmts = match stmts with
      | [] -> assert false
      | stmt :: stmts ->
        Env.pop_and_get env stmt ~global_clear:true Env.Before, stmts
    in
    let stmts = Cil.mkStmt ~valid_sid:true (Block b) :: stmts in
    (* Prevent multiple calls to globals_init *)
    let loc = Location.unknown in
    let vi_already_run =
      Cil.makeLocalVar fundec (RTL.mk_api_name "already_run") (TInt(IChar, []))
    in
    vi_already_run.vdefined <- true;
    vi_already_run.vreferenced <- true;
    vi_already_run.vstorage <- Static;
    let init = AssignInit (SingleInit (Cil.zero ~loc)) in
    let init_stmt =
      Cil.mkStmtOneInstr ~valid_sid:true
        (Local_init (vi_already_run, init, loc))
    in
    let already_run =
      Cil.mkStmtOneInstr ~valid_sid:true
        (Set (Cil.var vi_already_run, Cil.one ~loc, loc))
    in
    let stmts = already_run :: stmts in
    let guard =
      Cil.mkStmt
        ~valid_sid:true
        (If (Cil.evar vi_already_run, Cil.mkBlock [], Cil.mkBlock stmts, loc))
    in
    let return = Cil.mkStmt ~valid_sid:true (Return (None, loc)) in
    let stmts = [ init_stmt; guard; return ] in
    blk.bstmts <- stmts;
    vi, fundec, env

    let mk_delete bhv stmts =
      Varinfo.Hashtbl.fold_sorted
        (fun old_vi _l acc ->
          let new_vi = Visitor_behavior.Get.varinfo bhv old_vi in
          Misc.mk_delete_stmt new_vi :: acc)
        tbl
        stmts

end

(* the main visitor performing e-acsl checking and C code generator *)
class e_acsl_visitor prj generate = object (self)

  inherit Visitor.generic_frama_c_visitor
    (if generate then Visitor_behavior.copy prj else Visitor_behavior.inplace ())

  val mutable main_fct = None
  (* fundec of the main entry point, in the new project [prj].
     [None] while the global corresponding to this fundec has not been
     visited *)

  val mutable is_initializer = false
  (* Global flag set to [true] if a currently visited node
     belongs to a global initializer and set to [false] otherwise *)

  method private reset_env () =
    function_env := Env.empty (self :> Visitor.frama_c_visitor)

  method !vfile _f =
    (* copy the options used during the visit in the new project: it is the
       right place to do this: it is still before visiting, but after
       that the visitor internals reset all of them :-(. *)
    let cur = Project.current () in
    let selection =
      State_selection.of_list
        [ Options.Gmp_only.self; Options.Check.self; Options.Full_mmodel.self;
          Kernel.SignedOverflow.self; Kernel.UnsignedOverflow.self;
          Kernel.SignedDowncast.self; Kernel.UnsignedDowncast.self;
          Kernel.Machdep.self ]
    in
    if generate then Project.copy ~selection ~src:cur prj;
    Cil.DoChildrenPost
      (fun f ->
        (* extend [main] with forward initialization and put it at end *)
        if generate then begin
          if not (Global_observer.is_empty () && Literal_strings.is_empty ())
          then begin
            let build_initializer () =
              Options.feedback ~dkey ~level:2 "building global initializer.";
              let vi, fundec, env =
                Global_observer.mk_init self#behavior !function_env
              in
              function_env := env;
              let cil_fct = GFun(fundec, Location.unknown) in
              if Mmodel_analysis.use_model () then
                match main_fct with
                | Some main ->
                  let exp = Cil.evar ~loc:Location.unknown vi in
                  (* Create [__e_acsl_globals_init();] call *)
                  let stmt =
                    Cil.mkStmtOneInstr ~valid_sid:true
                      (Call(None, exp, [], Location.unknown))
                  in
                  vi.vreferenced <- true;
                  (* insert [__e_acsl_globals_init ();] as first statement of
                     [main] *)
                  main.sbody.bstmts <- stmt :: main.sbody.bstmts;
                  let new_globals =
                    List.fold_right
                      (fun g acc -> match g with
                      | GFun({ svar = vi }, _)
                          when Varinfo.equal vi main.svar ->
                        acc
                      | _ -> g :: acc)
                      f.globals
                      [ cil_fct; GFun(main, Location.unknown) ]
                  in
                  (* add the literal string varinfos as the very first
                     globals *)
                  let new_globals =
                    Literal_strings.fold
                      (fun _ vi l ->
                        GVar(vi, { init = None }, Location.unknown) :: l)
                      new_globals
                  in
                  f.globals <- new_globals
                | None ->
                  Kernel.warning "@[no entry point specified:@ \
you must call function `%s' and `__e_acsl_memory_clean by yourself.@]"
                    Global_observer.function_name;
                  f.globals <- f.globals @ [ cil_fct ]
            in
            Project.on prj build_initializer ()
          end; (* must_init *)
          (* Add a call to [__e_acsl_memory_init] that initializes memory
             storage and potentially records program arguments. Parameters to
             [__e_acsl_memory_init] are addresses of program arguments or
             NULLs if [main] is declared without arguments. *)
          let build_mmodel_initializer () =
            let loc = Location.unknown in
            let nulls = [ Cil.zero loc ; Cil.zero loc ] in
            let handle_main main =
              let args =
                (* record arguments only if the second has a pointer type, so a
                   argument strings can be recorded. This is sufficient to
                   capture C99 compliant arguments and GCC extensions with
                   environ. *)
                match main.sformals with
                | [] ->
                  (* no arguments to main given *)
                  nulls
                | _argc :: argv :: _ when Cil.isPointerType argv.vtype ->
                  (* grab addresses of arguments for a call to the main
                     initialization function, i.e., [__e_acsl_memory_init] *)
                  List.map Cil.mkAddrOfVi main.sformals;
                | _ :: _ ->
                  (* some non-standard arguments. *)
                  nulls
              in
              let ptr_size = Cil.sizeOf loc Cil.voidPtrType in
              let args = args @ [ ptr_size ] in
              let name = RTL.mk_api_name "memory_init" in
              let init = Misc.mk_call loc name args in
              main.sbody.bstmts <- init :: main.sbody.bstmts
            in
            Extlib.may handle_main main_fct
          in
          Project.on
            prj
            (fun () ->
               f.globals <- Logic_functions.add_generated_functions f.globals;
               build_mmodel_initializer ())
            ();
          (* reset copied states at the end to be observationally
              equivalent to a standard visitor. *)
          Project.clear ~selection ~project:prj ();
        end; (* generate *)
        f)

  method !vglob_aux = function
  | GVarDecl(vi, _) | GVar(vi, _, _)
  | GFunDecl(_, vi, _) | GFun({ svar = vi }, _)
      when Misc.is_library_loc vi.vdecl || Builtins.mem vi.vname ->
    if generate then
      Cil.JustCopyPost
        (fun l ->
          let new_vi = Visitor_behavior.Get.varinfo self#behavior vi in
          if Misc.is_library_loc vi.vdecl then
            Misc.register_library_function new_vi;
          if Builtins.mem vi.vname then Builtins.update vi.vname new_vi;
          l)
    else begin
      Misc.register_library_function vi;
      Cil.SkipChildren
    end
  | GVarDecl(vi, _) | GVar(vi, _, _) | GFun({ svar = vi }, _)
      when Cil.is_builtin vi ->
    if generate then Cil.JustCopy else Cil.SkipChildren
  | g when Misc.is_library_loc (Global.loc g) ->
    if generate then Cil.JustCopy else Cil.SkipChildren
  | g ->
    let do_it = function
      | GVar(vi, _, _) ->
        vi.vghost <- false
      | GFun({ svar = vi } as fundec, _) ->
        vi.vghost <- false;
        Builtins.update vi.vname vi;
        (* remember that we have to remove the main later (see method
           [vfile]); do not use the [vorig_name] since both [main] and
           [__e_acsl_main] have the same [vorig_name]. *)
        if vi.vname = Kernel.MainFunction.get () then
          main_fct <- Some fundec
      | GVarDecl(vi, _) | GFunDecl(_, vi, _) ->
        (* do not convert extern ghost variables, because they can't be linked,
           see bts #1392 *)
        if vi.vstorage <> Extern then
          vi.vghost <- false
      | _ ->
        ()
    in
    (match g with
    | GVar(vi, _, _) | GVarDecl(vi, _) | GFun({ svar = vi }, _)
      (* Track function addresses but the main function that is tracked
         internally via RTL *)
        when vi.vorig_name <> Kernel.MainFunction.get () ->
      (* Make a unique mapping for each global variable omitting initializers.
         Initializers (used to capture literal strings) are added to
         [global_vars] via the [vinit] visitor method (see comments below). *)
      Global_observer.add (Visitor_behavior.Get_orig.varinfo self#behavior vi)
    | _ -> ());
    if generate then Cil.DoChildrenPost(fun g -> List.iter do_it g; g)
    else Cil.DoChildren

  (* Add mappings from global variables to their initializers in [global_vars].
     Note that the below function captures only [SingleInit]s. All compound
     initializers containing SingleInits (except for empty compound
     initializers) are unrapped and thrown away. *)
  method !vinit vi off _ =
    if generate then
      if Mmodel_analysis.must_model_vi vi then begin
        is_initializer <- vi.vglob;
        Cil.DoChildrenPost
          (fun i ->
            (match is_initializer with
            | true ->
              (match i with
              | CompoundInit(_,[]) ->
                (* Case of an empty CompoundInit, treat it as if there were
                   no initializer at all *)
                ()
              | CompoundInit(_,_) | SingleInit _ ->
                (* TODO: [off] should be the one of the new project while it is
                   from the old project *)
                Global_observer.add_initializer vi off i)
            | false-> ());
            is_initializer <- false;
          i)
      end else
        Cil.JustCopy
    else
      Cil.SkipChildren

  method !vvdec vi =
    (try
       let old_vi = Visitor_behavior.Get_orig.varinfo self#behavior vi in
       let old_kf = Globals.Functions.get old_vi in
       funspec :=
         Cil.visitCilFunspec
         (self :> Cil.cilVisitor)
         (Annotations.funspec old_kf)
     with Not_found ->
       ());
    Cil.SkipChildren

  method private add_generated_variables_in_function f =
    assert generate;
    let vars = Env.get_generated_variables !function_env in
    self#reset_env ();
    let locals, blocks =
      List.fold_left
        (fun (local_vars, block_vars as acc) (v, scope) -> match scope with
        (* TODO: [kf] assumed to be consistent. Should be asserted. *)
        | Env.LFunction _kf -> v :: local_vars, v :: block_vars
        | Env.LLocal_block _kf -> v :: local_vars, block_vars
        | _ -> acc)
        (f.slocals, f.sbody.blocals)
        vars
    in
    f.slocals <- locals;
    f.sbody.blocals <- blocks

  (* Memory management for \at on purely logic variables:
    Put [malloc] stmts at proper locations *)
  method private insert_malloc_and_free_stmts kf f =
    let malloc_stmts = At_with_lscope.Malloc.find_all kf in
    let fstmts = malloc_stmts @ f.sbody.bstmts in
    f.sbody.bstmts <- fstmts;
    (* Now that [malloc] stmts for [kf] have been inserted,
      there is no more need to keep the corresponding entries in the
      table managing them. *)
    At_with_lscope.Malloc.remove_all kf

  method !vfunc f =
    if generate then begin
      let kf = Extlib.the self#current_kf in
      if Functions.instrument kf then Exit_points.generate f;
      Options.feedback ~dkey ~level:2 "entering in function %a."
        Kernel_function.pretty kf;
      List.iter (fun vi -> vi.vghost <- false) f.slocals;
      Cil.DoChildrenPost
        (fun f ->
          Exit_points.clear ();
          self#add_generated_variables_in_function f;
          self#insert_malloc_and_free_stmts kf f;
          Options.feedback ~dkey ~level:2 "function %a done."
            Kernel_function.pretty kf;
          f)
    end else
      Cil.DoChildren

  method private is_return old_kf stmt =
    let old_ret =
      try Kernel_function.find_return old_kf
      with Kernel_function.No_Statement -> assert false
    in
    Stmt.equal stmt (Visitor_behavior.Get.stmt self#behavior old_ret)

  method private is_first_stmt old_kf stmt =
    try
      Stmt.equal
        (Visitor_behavior.Get_orig.stmt self#behavior stmt)
        (Kernel_function.find_first_stmt old_kf)
    with Kernel_function.No_Statement ->
      assert false

  method private is_main old_kf =
    try
      let main, _ = Globals.entry_point () in
      Kernel_function.equal old_kf main
    with Globals.No_such_entry_point _s ->
      (* [JS 2013/05/21] already a warning in pre-analysis *)
      (*      Options.warning ~once:true "%s@ \
              @[The generated program may be incomplete.@]"
              s;*)
      false

  method !vstmt_aux stmt =
    Options.debug ~level:4 "proceeding stmt (sid %d) %a@."
      stmt.sid Stmt.pretty stmt;
    let kf = Extlib.the self#current_kf in
    let is_main = self#is_main kf in
    let env = Env.push !function_env in
    let env = match stmt.skind with
      | Loop _ -> Env.push_loop env
      | _ -> env
    in
    let env =
      if self#is_first_stmt kf stmt then
        (* JS: should be done in the new project? *)
        let env =
          if generate && not is_main then
            let env = Memory.store env kf (Kernel_function.get_formals kf) in
            Temporal.handle_function_parameters kf env
          else
            env
        in
        (* translate the precondition of the function *)
        if Functions.check kf then
          Project.on prj (Translate.translate_pre_spec kf env) !funspec
        else
          env
      else
        env
    in

    let env, new_annots =
      if Functions.check kf then
        Annotations.fold_code_annot
          (fun _ old_a (env, new_annots) ->
            let a =
              (* [VP] Don't use Visitor here, as it will fill the queue in the
                 middle of the computation... *)
              Cil.visitCilCodeAnnotation (self :> Cil.cilVisitor) old_a
            in
            let env =
              Project.on prj (Translate.translate_pre_code_annotation kf env) a
            in
            env, a :: new_annots)
          (Visitor_behavior.Get_orig.stmt self#behavior stmt)
          (env, [])
      else
        env, []
    in

    (* Add [__e_acsl_store_duplicate] calls for local variables which
     * declarations are bypassed by gotos. Note: should be done before
     * [vinst] method (which adds initializers) is executed, otherwise
     * init calls appear before store calls. *)
    let duplicates = Exit_points.store_vars stmt in
    let env =
      if generate then Memory.duplicate_store ~before:stmt env kf duplicates
      else env
    in
    function_env := env;

    let mk_block stmt =
      (* be careful: since this function is called in a post action, [env] has
         been modified from the time where pre actions have been executed.
         Use [function_env] to get it back. *)
      let env = !function_env in
      let env =
        if generate then
          (* Add temporal analysis instrumentations *)
          let env = Temporal.handle_stmt stmt env in
          (* Add initialization statements and store_block statements stemming
             from Local_init *)
          self#handle_instructions stmt env kf
        else
          env
      in
      let new_stmt, env, must_mv =
        if Functions.check kf then
          let env =
            (* handle ghost statement *)
            if stmt.ghost then begin
              stmt.ghost <- false;
              (* translate potential RTEs of ghost code *)
              let rtes = Rte.stmt ~warn:false kf stmt in
              Translate.translate_rte_annots Printer.pp_stmt stmt kf env rtes
            end else
              env
          in
          (* handle loop invariants *)
          let new_stmt, env, must_mv =
            Loops.preserve_invariant prj env kf stmt
          in
          let orig = Visitor_behavior.Get_orig.stmt self#behavior stmt in
          Visitor_behavior.Set_orig.stmt self#behavior new_stmt orig;
          Visitor_behavior.Set.stmt self#behavior orig new_stmt;
          new_stmt, env, must_mv
        else
          stmt, env, false
      in
      let mk_post_env env =
        (* [fold_right] to preserve order of generation of pre_conditions *)
        Project.on
          prj
          (List.fold_right
             (fun a env -> Translate.translate_post_code_annotation kf env a)
             new_annots)
          env
      in
      let new_stmt, env =
        (* Remove local variables which scopes ended via goto/break/continue. *)
        let del_vars = Exit_points.delete_vars stmt in
        let env =
          if generate then Memory.delete_from_set ~before:stmt env kf del_vars
          else env
        in
        if self#is_return kf stmt then
          let env =
            if Functions.check kf then
              (* must generate the post_block before including [stmt] (the
                 'return') since no code is executed after it. However, since
                 this statement is pure (Cil invariant), that is semantically
                 correct. *)
              (* [JS 2019/2/19] TODO: what about the other ways of early exiting
                 a block? *)
              let env = mk_post_env env in
              (* also handle the postcondition of the function and clear the
                 env *)
              Project.on prj (Translate.translate_post_spec kf env) !funspec
            else
              env
          in
          (* de-allocating memory previously allocating by the kf *)
          (* JS: should be done in the new project? *)
          if generate then
            (* Remove recorded function arguments *)
            let fargs = Kernel_function.get_formals kf in
            let env =
              if generate then Memory.delete_from_list env kf fargs
              else env
            in
            let b, env =
              Env.pop_and_get env new_stmt ~global_clear:true Env.After
            in
            if is_main && Mmodel_analysis.use_model () then begin
              let stmts = b.bstmts in
              let l = List.rev stmts in
              let mclean = (RTL.mk_api_name "memory_clean") in
              match l with
              | [] -> assert false (* at least the 'return' stmt *)
              | ret :: l ->
                let loc = Stmt.loc stmt in
                let delete_stmts =
                  Global_observer.mk_delete
                    self#behavior
                    [ Misc.mk_call ~loc mclean []; ret ]
                in
                b.bstmts <- List.rev l @ delete_stmts
            end;
            let new_stmt = Misc.mk_block prj stmt b in
            if not (Cil_datatype.Stmt.equal stmt new_stmt) then begin
              (* move the labels of the return to the new block in order to
                 evaluate the postcondition when jumping to them. *)
              E_acsl_label.move
                (self :> Visitor.generic_frama_c_visitor) stmt new_stmt
            end;
            new_stmt, env
          else
            stmt, env
        else (* i.e. not (is_return stmt) *)
          if generate then begin
            (* must generate [pre_block] which includes [stmt] before generating
               [post_block] *)
            let pre_block, env =
              Env.pop_and_get
                ~split:true
                env
                new_stmt
                ~global_clear:false
                Env.After
            in
            let env =
              (* if [kf] is not monitored, do not translate any postcondition,
                 but still push an empty environment consumed by
                 [Env.pop_and_get] below. This [Env.pop_and_get] call is always
                 required in order to generate the code not directly related to
                 the annotations of the current stmt in anycase. *)
              if Functions.check kf then mk_post_env (Env.push env)
              else Env.push env
            in
            let post_block, env =
              Env.pop_and_get
                env
                (Misc.mk_block prj new_stmt pre_block)
                ~global_clear:false
                Env.Before
            in
            let post_block =
              if post_block.blocals = [] && new_stmt.labels = []
              then Cil.transient_block post_block
              else post_block
            in
            let res = Misc.mk_block prj new_stmt post_block in
            if not (Cil_datatype.Stmt.equal new_stmt res) then
              E_acsl_label.move (self :> Visitor.generic_frama_c_visitor)
                new_stmt res;
            let orig = Visitor_behavior.Get_orig.stmt self#behavior stmt in
            Visitor_behavior.Set.stmt self#behavior orig res;
            Visitor_behavior.Set_orig.stmt self#behavior res orig;
            res, env
          end else
            stmt, env
      in
      if must_mv then Loops.mv_invariants env ~old:new_stmt stmt;
      function_env := env;
      Options.debug ~level:4
      "@[new stmt (from sid %d):@ %a@]" stmt.sid Printer.pp_stmt new_stmt;
      if generate then new_stmt else stmt
    in
    Cil.ChangeDoChildrenPost(stmt, mk_block)

  method private handle_instructions stmt env kf =
    let add_initializer loc ?vi lv ?(post=false) stmt env kf =
      assert generate;
      if Functions.instrument kf then
        let may_safely_ignore = function
          | Var vi, NoOffset -> vi.vglob || vi.vformal
          | _ -> false
        in
        let must_model = Mmodel_analysis.must_model_lval ~stmt ~kf lv in
        if not (may_safely_ignore lv) && must_model then
          let before = Cil.mkStmt stmt.skind in
          let new_stmt =
            (* Bitfields are not yet supported ==> no initializer.
               A not_yet will be raised in [Translate]. *)
            if Cil.isBitfield lv then Project.on prj Cil.mkEmptyStmt ()
            else Project.on prj (Misc.mk_initialize ~loc) lv
          in
          let env = Env.add_stmt ~post ~before env new_stmt in
          let env = match vi with
            | None -> env
            | Some vi ->
              let new_stmt = Project.on prj Misc.mk_store_stmt vi in
              Env.add_stmt ~post ~before env new_stmt
          in
          env
        else
          env
      else
        env
    in
    let check_formats = Options.Validate_format_strings.get () in
    let replace_libc_fn = Options.Replace_libc_functions.get () in
    match stmt.skind with
    | Instr(Set(lv, _, loc)) -> add_initializer loc lv stmt env kf
    | Instr(Local_init(vi, init, loc)) ->
      let lv = (Var vi, NoOffset) in
      let env = add_initializer loc ~vi lv ~post:true stmt env kf in
      (* Handle variable-length array allocation via [__fc_vla_alloc].
         Here each instance of [__fc_vla_alloc] is rewritten to [alloca]
         (that is used to implement VLA) and further a custom call to
         [store_block] tracking VLA allocation is issued. *)
      (* KV: Do not add handling [alloca] allocation here (or anywhere else for
         that matter). Handling of [alloca] should be implemented in Frama-C
         (eventually). This is such that each call to [alloca] becomes
         [__fc_vla_alloc]. It is already handled using the code below. *)
      (match init with
      | ConsInit (fvi, sz :: _, _) when Libc.is_vla_alloc_name fvi.vname ->
        fvi.vname <- Libc.actual_alloca;
        (* Since we need to pass [vi] by value cannot use [Misc.mk_store_stmt]
           here. Do it manually. *)
        let sname = RTL.mk_api_name "store_block" in
        let store = Misc.mk_call ~loc sname [ Cil.evar vi ; sz ] in
        Env.add_stmt ~post:true env store
      (* Rewrite format functions (e.g., [printf]). See some comments below *)
      | ConsInit (fvi, args, knd) when check_formats
          && Libc.is_printf_name fvi.vname ->
        let name = RTL.get_rtl_replacement_name fvi.vname in
        let new_vi = Misc.get_lib_fun_vi name in
        let fmt = Libc.get_printf_argument_str ~loc fvi.vname args in
        stmt.skind <-
          Instr(Local_init(vi, ConsInit(new_vi, fmt :: args, knd), loc));
        env
      (* Rewrite names of functions for which we have alternative
        definitions in the RTL. *)
      | ConsInit (fvi, _, _) when replace_libc_fn &&
        RTL.has_rtl_replacement fvi.vname ->
        fvi.vname <- RTL.get_rtl_replacement_name fvi.vname;
        env
      | _ -> env)
    | Instr(Call (result, exp, args, loc)) ->
      (* Rewrite names of functions for which we have alternative
         definitions in the RTL. *)
      (match exp.enode with
      | Lval(Var vi, _) when replace_libc_fn &&
          RTL.has_rtl_replacement vi.vname ->
        vi.vname <- RTL.get_rtl_replacement_name vi.vname
      | Lval(Var vi , _) when Libc.is_vla_free_name vi.vname ->
        (* Handle variable-length array allocation via [__fc_vla_free].
           Rewrite its name to [delete_block]. The rest is in place. *)
        vi.vname <- RTL.mk_api_name "delete_block"
      | Lval(Var vi, _) when check_formats && Libc.is_printf_name vi.vname ->
        (* Rewrite names of format functions (such as printf). This case
           differs from the above because argument list of format functions is
           extended with an argument describing actual variadic arguments *)
        (* Replacement name, e.g., [printf] -> [__e_acsl_builtin_printf] *)
        let name = RTL.get_rtl_replacement_name vi.vname in
        (* Variadic arguments descriptor *)
        let fmt = Libc.get_printf_argument_str ~loc vi.vname args in
        (* get the name of the library function we need. Cannot just rewrite
           the name as AST check will then fail *)
        let vi = Misc.get_lib_fun_vi name in
        stmt.skind <- Instr(Call (result, Cil.evar vi, fmt :: args, loc))
      | _ -> ());
      (* Add statement tracking initialization of return values of function
         calls *)
      (match result with
        | Some lv when not (RTL.is_generated_kf kf) ->
          add_initializer loc lv ~post:false stmt env kf
        | _ -> env)
    | _ -> env

  method !vblock blk =
    let handle_memory new_blk =
      let kf = Extlib.the self#current_kf in
      let free_stmts = At_with_lscope.Free.find_all kf in
      match new_blk.blocals, free_stmts with
      | [], [] ->
        new_blk
      | [], _ :: _ | _ :: _, [] | _ :: _, _ :: _ ->
        let add_locals stmts =
          if Functions.instrument kf then
            List.fold_left
              (fun acc vi ->
                 if Mmodel_analysis.must_model_vi ~bhv:self#behavior ~kf vi then
                   Misc.mk_delete_stmt vi :: acc
                 else
                   acc)
              stmts
              new_blk.blocals
          else
            stmts
        in
        let rec insert_in_innermost_last_block blk = function
          | { skind = Return _ } as ret :: ((potential_clean :: tl) as l) ->
            (* keep the return (enclosed in a generated block) at the end;
               preceded by clean if any *)
            let init, tl =
              if self#is_main kf && Mmodel_analysis.use_model () then
                free_stmts @ [ potential_clean; ret ], tl
              else
                free_stmts @ [ ret ], l
            in
            (* Now that [free] stmts for [kf] have been inserted,
              there is no more need to keep the corresponding entries in the
              table managing them. *)
            At_with_lscope.Free.remove_all kf;
            blk.bstmts <-
              List.fold_left (fun acc v -> v :: acc) (add_locals init) tl
          | { skind = Block b } :: _ ->
            insert_in_innermost_last_block b (List.rev b.bstmts)
          | l -> blk.bstmts <-
            List.fold_left (fun acc v -> v :: acc) (add_locals []) l
        in
        insert_in_innermost_last_block new_blk (List.rev new_blk.bstmts);
        if Functions.instrument kf then
          new_blk.bstmts <-
            List.fold_left
              (fun acc vi ->
                 if Mmodel_analysis.must_model_vi vi && not vi.vdefined then
                   let vi = Visitor_behavior.Get.varinfo self#behavior vi in
                   Misc.mk_store_stmt vi :: acc
                 else acc)
              new_blk.bstmts
              blk.blocals;
        new_blk
    in
    if generate then Cil.DoChildrenPost handle_memory else Cil.DoChildren

  (* Processing expressions for the purpose of replacing literal strings found
   in the code with variables generated by E-ACSL. *)
  method !vexpr _ =
    if generate then begin
      match is_initializer with
      (* Do not touch global initializers because they accept only constants *)
      | true -> Cil.DoChildren
      (* Replace literal strings elsewhere *)
      | false ->
        Cil.DoChildrenPost
          (fun e ->
            let e, env = Literal_observer.exp !function_env e in
            function_env := env;
            e)
    end else
      Cil.SkipChildren

  initializer
    Misc.reset ();
    Logic_functions.reset ();
    Literal_strings.reset ();
    Global_observer.reset ();
    Keep_status.before_translation ();
    self#reset_env ()

end

let do_visit ?(prj=Project.current ()) generate =
  (* The main visitor proceeds by tracking declarations belonging to the
     E-ACSL runtime library and then using these declarations to generate
     statements used in instrumentation. The following code reorders AST
     so declarations belonging to E-ACSL library appear atop of any location
     requiring instrumentation. *)
  Misc.reorder_ast ();
  Options.feedback ~level:2 "%s annotations in %a."
    (if generate then "translating" else "checking")
    Project.pretty prj;
  let vis =
    Extlib.try_finally ~finally:Typing.clear (new e_acsl_visitor prj) generate
  in
  (* explicit type annotation in order to check that no new method is
     introduced by error *)
  (vis : Visitor.frama_c_visitor)

(*
Local Variables:
compile-command: "make -C ../.."
End:
*)
