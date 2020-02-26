(*
Copyright (C) 2019- National Institute of Advanced Industrial Science and Technology (AIST)

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
*)

open Names
open GlobRef
open Pp

(* open Term *)
open Constr
open EConstr

open CErrors

open Cgenutil
open State

let pr_s_or_d (sd : s_or_d) : Pp.t =
  match sd with
  | SorD_S -> Pp.str "s"
  | SorD_D -> Pp.str "d"

let drop_trailing_d (sd_list : s_or_d list) : s_or_d list =
  List.fold_right (fun sd l -> match (sd,l) with (SorD_D,[]) -> [] | _ -> sd :: l) sd_list []

let codegen_print_specialization (funcs : Libnames.qualid list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let pr_inst sp_inst =
    let pr_names =
      Pp.str "=>" ++ spc () ++
      Pp.str (escape_as_coq_string sp_inst.sp_cfunc_name) ++ spc () ++
      Printer.pr_constr_env env sigma sp_inst.sp_partapp_constr ++ spc () ++
      (match sp_inst.sp_specialization_name with
      | SpExpectedId id -> Pp.str "(" ++ Id.print id ++ Pp.str ")"
      | SpDefinedCtnt ctnt -> Printer.pr_constant env ctnt)
    in
    let pr_inst_list = List.map (Printer.pr_constr_env env sigma)
                                sp_inst.sp_static_arguments in
    pp_prejoin_list (spc ()) pr_inst_list ++ spc () ++
    pr_names
  in
  let pr_cfg (func, sp_cfg) =
    Feedback.msg_info (Pp.str "Arguments" ++ spc () ++
      Printer.pr_constr_env env sigma func ++
      pp_prejoin_list (spc ()) (List.map pr_s_or_d sp_cfg.sp_sd_list) ++
      Pp.str ".");
    let feedback_instance sp_inst =
      Feedback.msg_info (Pp.str "Instance" ++ spc () ++
        Printer.pr_constr_env env sigma func ++
        pr_inst sp_inst ++ Pp.str ".")
    in
    ConstrMap.iter (fun _ -> feedback_instance) sp_cfg.sp_instance_map
  in
  let l = if funcs = [] then
            ConstrMap.bindings !specialize_config_map |>
            (List.sort @@ fun (x,_) (y,_) -> Constr.compare x y)
          else
            funcs |> List.map @@ fun func ->
              let gref = Smartlocate.global_with_alias func in
              let func = match gref with
                | ConstRef ctnt -> Constr.mkConst ctnt
                | ConstructRef cstr -> Constr.mkConstruct cstr
                | _ -> user_err (Pp.str "constant or constructor expected:" ++ spc () ++
                                 Printer.pr_global gref)
              in
              (func, ConstrMap.get func !specialize_config_map)
  in
  Feedback.msg_info (Pp.str "Number of source functions:" ++ spc () ++ Pp.int (ConstrMap.cardinal !specialize_config_map));
  List.iter pr_cfg l

let func_of_qualid (env : Environ.env) (qualid : Libnames.qualid) : Constr.t =
  let gref = Smartlocate.global_with_alias qualid in
  match gref with
    | ConstRef ctnt -> Constr.mkConst ctnt
    | ConstructRef cstr -> Constr.mkConstruct cstr
    | _ -> user_err (Pp.str "constant or constructor expected:" ++ spc () ++ Printer.pr_global gref)

let codegen_specialization_define_arguments (env : Environ.env) (sigma : Evd.evar_map) (func : Constr.t) (sd_list : s_or_d list) : specialization_config =
  let sp_cfg = { sp_func=func; sp_sd_list=sd_list; sp_instance_map = ConstrMap.empty } in
  specialize_config_map := ConstrMap.add func sp_cfg !specialize_config_map;
  Feedback.msg_info (Pp.str "Specialization arguments defined:" ++ spc () ++ Printer.pr_constr_env env sigma func);
  sp_cfg

let codegen_specialization_define_or_check_arguments (env : Environ.env) (sigma : Evd.evar_map) (func : Constr.t) (sd_list : s_or_d list) : specialization_config =
  match ConstrMap.find_opt func !specialize_config_map with
  | None ->
      let sp_cfg = { sp_func=func; sp_sd_list=sd_list; sp_instance_map = ConstrMap.empty } in
      specialize_config_map := ConstrMap.add func sp_cfg !specialize_config_map;
      Feedback.msg_info (Pp.str "Specialization arguments defined:" ++ spc () ++ Printer.pr_constr_env env sigma func);
      sp_cfg
  | Some sp_cfg ->
      let sd_list_old = drop_trailing_d sp_cfg.sp_sd_list in
      let sd_list_new = drop_trailing_d sd_list in
      (if sd_list_old <> sd_list_new then
        user_err (Pp.str "inconsistent specialization configuration for" ++ spc () ++
        Printer.pr_constr_env env sigma func ++ Pp.str ":" ++
        pp_prejoin_list (spc ()) (List.map pr_s_or_d sd_list_old) ++ spc () ++ Pp.str "expected but" ++
        pp_prejoin_list (spc ()) (List.map pr_s_or_d sd_list_new)));
      sp_cfg

let codegen_specialization_arguments (func : Libnames.qualid) (sd_list : s_or_d list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let func = func_of_qualid env func in
  (if ConstrMap.mem func !specialize_config_map then
    user_err (Pp.str "specialization already configured:" ++ spc () ++ Printer.pr_constr_env env sigma func));
  ignore (codegen_specialization_define_arguments env sigma func sd_list)

let rec determine_sd_list (env : Environ.env) (sigma : Evd.evar_map) (ty : EConstr.t) : s_or_d list =
  (* Feedback.msg_info (Printer.pr_econstr_env env sigma ty); *)
  let ty = Reductionops.whd_all env sigma ty in
  match EConstr.kind sigma ty with
  | Prod (x,t,c) ->
      let t = Reductionops.whd_all env sigma t in
      let sd =
        if EConstr.isSort sigma t then
          SorD_S
        else
          SorD_D
      in
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env = EConstr.push_rel decl env in
      sd :: determine_sd_list env sigma c
  | _ -> []

let codegen_specialization_auto_arguments_internal
    (env : Environ.env) (sigma : Evd.evar_map)
    (func : Constr.t) : specialization_config =
  match ConstrMap.find_opt func !specialize_config_map with
  | Some sp_cfg -> sp_cfg (* already defined *)
  | None ->
      let ty = Retyping.get_type_of env sigma (EConstr.of_constr func) in
      let sd_list = (determine_sd_list env sigma ty) in
      codegen_specialization_define_arguments env sigma func sd_list

let codegen_specialization_auto_arguments_1 (env : Environ.env) (sigma : Evd.evar_map)
    (func : Libnames.qualid) : unit =
  let func = func_of_qualid env func in
  ignore (codegen_specialization_auto_arguments_internal env sigma func)

let codegen_specialization_auto_arguments (func_list : Libnames.qualid list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  List.iter (codegen_specialization_auto_arguments_1 env sigma) func_list

let build_partapp (env : Environ.env) (sigma : Evd.evar_map)
    (f : EConstr.t) (f_type : EConstr.types) (sd_list : s_or_d list)
    (static_args : Constr.t list) : (Evd.evar_map * Constr.t * EConstr.types) =
  let rec aux env f f_type sd_list static_args =
    match sd_list with
    | [] -> f
    | sd :: sd_list' ->
        let f_type = Reductionops.whd_all env sigma f_type in
        (match EConstr.kind sigma f_type with
        | Prod (x,t,c) ->
            (match sd with
            | SorD_S ->
                (match static_args with
                | [] -> user_err (Pp.str "needs more argument")
                | arg :: static_args' ->
                    let f' = mkApp (f, [| arg |]) in
                    let f_type' = Termops.prod_applist sigma f_type [arg] in
                    aux env f' f_type' sd_list' static_args')
            | SorD_D ->
                (let f1 = EConstr.Vars.lift 1 f in
                let f1app = mkApp (f1, [| mkRel 1 |]) in
                let decl = Context.Rel.Declaration.LocalAssum (x, t) in
                let env = EConstr.push_rel decl env in
                mkLambda (x, t, aux env f1app c sd_list' static_args)))
        | _ -> user_err (Pp.str "needs a function type"))
  in
  let sigma0 = sigma in
  let sd_list = drop_trailing_d sd_list in
  let t = aux env f f_type sd_list (List.map EConstr.of_constr static_args) in
  let (sigma, ty) = Typing.type_of env sigma t in
  Pretyping.check_evars env sigma0 sigma t;
  let t = Evarutil.flush_and_check_evars sigma t in
  (sigma, t, ty)

let gensym_ps (suffix : string) : Names.Id.t * Names.Id.t =
  let n = !gensym_ps_num in
  gensym_ps_num := n + 1;
  let suffix2 = if suffix = "" then suffix else "_" ^ suffix in
  let p = "codegen_p" ^ string_of_int n ^ suffix2 in
  let s = "codegen_s" ^ string_of_int n ^ suffix2 in
  (Id.of_string p, Id.of_string s)

let interp_args (env : Environ.env) (sigma : Evd.evar_map)
    (user_args : Constrexpr.constr_expr list) : Evd.evar_map * EConstr.t list =
  let interp_arg sigma user_arg =
    let sigma0 = sigma in
    let (sigma, arg) = Constrintern.interp_constr_evars env sigma user_arg in
    (* Feedback.msg_info (Printer.pr_econstr_env env sigma arg); *)
    Pretyping.check_evars env sigma0 sigma arg;
    (sigma, arg)
  in
  CList.fold_left_map interp_arg sigma user_args

let label_name_of_constant_or_constructor (func : Constr.t) : string =
  match Constr.kind func with
  | Const (ctnt, _) -> Label.to_string (Constant.label ctnt)
  | Construct (((mutind, i), j), _) ->
      let env = Global.env () in
      let mind_body = Environ.lookup_mind mutind env in
      let oind_body = mind_body.Declarations.mind_packets.(i) in
      let cons_id = oind_body.Declarations.mind_consnames.(j-1) in
      Id.to_string cons_id
  | _ -> user_err (Pp.str "expect constant or constructor")

let specialization_instance_internal
    ?(gen_constant=false)
    (env : Environ.env) (sigma : Evd.evar_map)
    (func : Constr.t) (static_args : Constr.t list)
    (names_opt : sp_instance_names option) : specialization_instance =
  let sp_cfg = match ConstrMap.find_opt func !specialize_config_map with
    | None -> user_err (Pp.str "specialization arguments not configured")
    | Some sp_cfg -> sp_cfg
  in
  let efunc = EConstr.of_constr func in
  let efunc_type = Retyping.get_type_of env sigma efunc in
  let (sigma, partapp, partapp_type) = build_partapp env sigma efunc efunc_type sp_cfg.sp_sd_list static_args in
  (if gen_constant && not (isInd sigma (fst (decompose_app sigma partapp_type))) then
    user_err (Pp.str "CodeGen Constant needs a constant:" ++ spc () ++
      Printer.pr_constr_env env sigma partapp ++ spc () ++ str ":" ++ spc () ++
      Printer.pr_econstr_env env sigma partapp_type));
  (if ConstrMap.mem partapp sp_cfg.sp_instance_map then
    user_err (Pp.str "specialization instance already configured:" ++ spc () ++ Printer.pr_constr_env env sigma partapp));
  let cfunc_name = match names_opt with
      | Some { spi_cfunc_name = Some name } ->
          (* valid_c_id_p is too restrictive to specify "0". *)
          (*
          (if not (valid_c_id_p name) then
            user_err (Pp.str "Invalid C function name specified:" ++ spc () ++ str name));
          *)
          name
      | _ ->
          let name = label_name_of_constant_or_constructor func in
          (if not (valid_c_id_p name) then
            user_err (Pp.str "Gallina function name is invalid in C:" ++ spc () ++ str name));
          name
  in
  (if CString.Map.mem cfunc_name !cfunc_instance_map then
    user_err
      (Pp.str "C function name already used:" ++ Pp.spc () ++
      Pp.str cfunc_name));
  let sp_inst =
    if List.for_all (fun sd -> sd = SorD_D) sp_cfg.sp_sd_list then
      let specialization_name = match names_opt with
        | Some { spi_specialized_id = Some id } -> SpExpectedId id
        | _ -> let (p_id, s_id) = gensym_ps (label_name_of_constant_or_constructor func) in
               SpExpectedId s_id
      in
      let sp_inst = {
        sp_partapp = partapp;
        sp_static_arguments = [];
        sp_partapp_constr = func; (* use the original function for fully dynamic function *)
        sp_specialization_name = specialization_name;
        sp_cfunc_name = cfunc_name;
        sp_gen_constant = gen_constant; }
      in
      Feedback.msg_info (Pp.str "Used:" ++ spc () ++ Printer.pr_constr_env env sigma func);
      sp_inst
    else
      let (p_id, s_id) = match names_opt with
        | Some { spi_partapp_id = Some p_id;
                 spi_specialized_id = Some s_id } -> (p_id, s_id)
        | _ ->
            let (p_id, s_id) = gensym_ps (label_name_of_constant_or_constructor func) in
            let p_id_opt = (match names_opt with | Some { spi_partapp_id = Some p_id } -> Some p_id | _ -> None) in
            let s_id_opt = (match names_opt with | Some { spi_specialized_id = Some s_id } -> Some s_id | _ -> None) in
            (
              (Stdlib.Option.fold ~none:p_id ~some:(fun x -> x) p_id_opt),
              (Stdlib.Option.fold ~none:s_id ~some:(fun x -> x) s_id_opt)
            )
      in
      let univs = Evd.univ_entry ~poly:false sigma in
      let defent = Declare.DefinitionEntry (Declare.definition_entry ~univs:univs partapp) in
      let kind = Decls.IsDefinition Decls.Definition in
      let declared_ctnt = Declare.declare_constant ~name:p_id ~kind:kind defent in
      let sp_inst = {
        sp_partapp = partapp;
        sp_static_arguments = static_args;
        sp_partapp_constr = Constr.mkConst declared_ctnt;
        sp_specialization_name = SpExpectedId s_id;
        sp_cfunc_name = cfunc_name;
        sp_gen_constant = gen_constant; }
      in
      Feedback.msg_info (Pp.str "Defined:" ++ spc () ++ Printer.pr_constant env declared_ctnt);
      sp_inst
  in
  gallina_instance_map := (ConstrMap.add sp_inst.sp_partapp_constr (sp_cfg, sp_inst) !gallina_instance_map);
  gallina_instance_map := (ConstrMap.add partapp (sp_cfg, sp_inst) !gallina_instance_map);
  cfunc_instance_map := (CString.Map.add cfunc_name (sp_cfg, sp_inst) !cfunc_instance_map);
  let inst_map = ConstrMap.add partapp sp_inst sp_cfg.sp_instance_map in
  let sp_cfg2 = { sp_cfg with sp_instance_map = inst_map } in
  specialize_config_map := ConstrMap.add func sp_cfg2 !specialize_config_map;
  sp_inst

let codegen_function_internal
    ?(gen_constant=false)
    (func : Libnames.qualid)
    (user_args : Constrexpr.constr_expr option list)
    (names : sp_instance_names) : specialization_instance =
  let sd_list = List.map
    (fun arg -> match arg with None -> SorD_D | Some _ -> SorD_S)
    user_args
  in
  let user_args = List.filter_map
    (fun arg -> match arg with None -> None| Some a -> Some a)
    user_args
  in
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let (sigma, args) = interp_args env sigma user_args in
  let args = List.map (Reductionops.nf_all env sigma) args in
  let args = List.map (Evarutil.flush_and_check_evars sigma) args in
  let func = func_of_qualid env func in
  ignore (codegen_specialization_define_or_check_arguments env sigma func sd_list);
  specialization_instance_internal ~gen_constant:gen_constant env sigma func args (Some names)

let codegen_function
    (func : Libnames.qualid)
    (user_args : Constrexpr.constr_expr option list)
    (names : sp_instance_names) : unit =
  let sp_inst = codegen_function_internal func user_args names in
  generation_list := GenFunc sp_inst.sp_cfunc_name :: !generation_list

let codegen_primitive
    (func : Libnames.qualid)
    (user_args : Constrexpr.constr_expr option list)
    (names : sp_instance_names) : unit =
  ignore (codegen_function_internal func user_args names)

let codegen_constant
    (func : Libnames.qualid)
    (user_args : Constrexpr.constr_expr list)
    (names : sp_instance_names) : unit =
  let user_args = List.map (fun arg -> Some arg) user_args in
  ignore (codegen_function_internal ~gen_constant:true func user_args names)

let check_convertible phase (env : Environ.env) (sigma : Evd.evar_map) (t1 : EConstr.t) (t2 : EConstr.t) : unit =
  if Reductionops.is_conv env sigma t1 t2 then
    ()
  else
    user_err (Pp.str "translation inconvertible:" ++ spc () ++ Pp.str phase ++
      Pp.fnl () ++
      Printer.pr_econstr_env env sigma t1 ++ Pp.fnl () ++
      Pp.str "=/=>" ++ Pp.fnl () ++
      Printer.pr_econstr_env env sigma t2)

let codegen_global_inline (func_qualids : Libnames.qualid list) : unit =
  let env = Global.env () in
  let funcs = List.map (func_of_qualid env) func_qualids in
  let ctnts = List.filter_map (fun func -> match Constr.kind func with Const (ctnt, _) -> Some ctnt | _ -> None) funcs in
  let f pred ctnt = Cpred.add ctnt pred in
  specialize_global_inline := List.fold_left f !specialize_global_inline ctnts

let codegen_local_inline (func_qualid : Libnames.qualid) (func_qualids : Libnames.qualid list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let func = func_of_qualid env func_qualid in
  let ctnt =
    match Constr.kind func with
    | Const (ctnt, _) -> ctnt
    | _ -> user_err (Pp.str "constant expected:" ++ Pp.spc () ++ Printer.pr_constr_env env sigma func)
  in
  let funcs = List.map (func_of_qualid env) func_qualids in
  let ctnts = List.filter_map (fun func -> match Constr.kind func with Const (ctnt, _) -> Some ctnt | _ -> None) funcs in
  let local_inline = !specialize_local_inline in
  let pred = match Cmap.find_opt ctnt local_inline with
             | None -> Cpred.empty
             | Some pred -> pred in
  let f pred ctnt = Cpred.add ctnt pred in
  let pred' = List.fold_left f pred ctnts in
  specialize_local_inline := Cmap.add ctnt pred' local_inline

let inline1 (env : Environ.env) (sigma : Evd.evar_map) (pred : Cpred.t) (term : EConstr.t) : EConstr.t =
  let trans = {
    TransparentState.tr_var = Id.Pred.empty;
    TransparentState.tr_cst = pred
  } in
  let reds = CClosure.RedFlags.red_add_transparent CClosure.RedFlags.no_red trans in
  let term = Reductionops.clos_norm_flags reds env sigma term in
  term

let inline (env : Environ.env) (sigma : Evd.evar_map) (pred : Cpred.t) (term : EConstr.t) : EConstr.t =
  let result = inline1 env sigma pred term in
  check_convertible "inline" env sigma term result;
  result

(* useless ?
let rec strip_cast (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  (* Feedback.msg_info (Pp.str "strip_cast arg: " ++ Printer.pr_econstr_env env sigma term); *)
  let result = strip_cast1 env sigma term in
  (* Feedback.msg_info (Pp.str "strip_cast ret: " ++ Printer.pr_econstr_env env sigma result); *)
  check_convertible "strip_cast" env sigma term result;
  result
and strip_cast1 (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel _ | Var _ | Meta _ | Evar _ | Sort _ | Ind _
  | Const _ | Construct _ | Int _ | Prod _ -> term
  | Lambda (x,t,b) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      mkLambda (x, t, strip_cast env2 sigma b)
  | Fix ((ia, i), ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      let fary' = Array.map (strip_cast env2 sigma) fary in
      mkFix ((ia, i), (nary, tary, fary'))
  | CoFix (i, ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      let fary' = Array.map (strip_cast env2 sigma) fary in
      mkCoFix (i, (nary, tary, fary'))
  | LetIn (x,e,t,b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, t) in
      let env2 = EConstr.push_rel decl env in
      let e' = strip_cast env sigma e in
      let b' = strip_cast env2 sigma b in
      mkLetIn (x, e', t, b')
  | Case (ci, p, item, branches) ->
      let item' = strip_cast env sigma item in
      let branches' = Array.map (strip_cast env sigma) branches in
      mkCase (ci, p, item', branches')
  | App (f,args) ->
      let f = strip_cast env sigma f in
      let args = Array.map (strip_cast env sigma) args in
      mkApp (f, args)
  | Cast (e,ck,ty) -> strip_cast env sigma e
  | Proj (proj, e) ->
      let e = strip_cast env sigma e in
      mkProj (proj, e)
*)

let rec normalizeK (env : Environ.env) (sigma : Evd.evar_map)
    (term : EConstr.t) : EConstr.t =
  (if !opt_debug_normalizeK then
    Feedback.msg_debug (Pp.str "normalizeK arg: " ++ Printer.pr_econstr_env env sigma term));
  let result = normalizeK1 env sigma term in
  (if !opt_debug_normalizeK then
    Feedback.msg_debug (Pp.str "normalizeK ret: " ++ Printer.pr_econstr_env env sigma result));
  check_convertible "normalizeK" env sigma term result;
  result
and normalizeK1 (env : Environ.env) (sigma : Evd.evar_map)
    (term : EConstr.t) : EConstr.t =
  let wrap_lets hoisted_exprs lifted_term =
    let hoisted_types = List.map (Retyping.get_type_of env sigma) hoisted_exprs in
    let hoisted_names = List.map (fun ty -> Context.nameR (Id.of_string (Namegen.hdchar env sigma ty))) hoisted_types in
    let rec aux i names exprs types acc_term =
      match names, exprs, types with
      | [], [], [] -> acc_term
      | x :: names', e :: exprs', ty :: types' ->
          let ty' = Vars.lift i ty in
          let e' = Vars.lift i (normalizeK env sigma e) in
          let acc_term' = aux (i+1) names' exprs' types' acc_term in
          mkLetIn (x, e', ty', acc_term')
      | _, _, _ -> user_err (Pp.str "inconsistent list length")
    in
    aux 0 hoisted_names hoisted_exprs hoisted_types lifted_term
  in
  match EConstr.kind sigma term with
  | Rel _ | Var _ | Meta _ | Evar _ | Sort _ | Ind _
  | Const _ | Construct _ | Int _ | Float _ | Prod _ -> term
  | Lambda (x,ty,b) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, ty) in
      let env2 = EConstr.push_rel decl env in
      mkLambda (x, ty, normalizeK env2 sigma b)
  | Fix ((ia, i), (nameary, tyary, funary)) ->
      let prec = (nameary, tyary, funary) in
      let env2 = push_rec_types prec env in
      let funary' = Array.map (normalizeK env2 sigma) funary in
      mkFix ((ia, i), (nameary, tyary, funary'))
  | CoFix (i, (nameary, tyary, funary)) ->
      let prec = (nameary, tyary, funary) in
      let env2 = push_rec_types prec env in
      let funary' = Array.map (normalizeK env2 sigma) funary in
      mkCoFix (i, (nameary, tyary, funary'))
  | LetIn (x,e,ty,b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, ty) in
      let env2 = EConstr.push_rel decl env in
      let e' = normalizeK env sigma e in
      let b' = normalizeK env2 sigma b in
      mkLetIn (x, e', ty, b')
  | Case (ci, p, item, branches) ->
      if isRel sigma item then
        mkCase (ci, p, item, Array.map (normalizeK env sigma) branches)
      else
        let term =
          mkCase (ci,
                  Vars.lift 1 p,
                  mkRel 1,
                  Array.map
                    (fun branch -> Vars.lift 1 (normalizeK env sigma branch))
                    branches)
        in
        wrap_lets [item] term
  | App (f,args) ->
      let f = normalizeK env sigma f in
      let hoist_args = Array.map (fun arg -> not (isRel sigma arg)) args in
      let nargs = Array.fold_left (fun n b -> n + if b then 1 else 0) 0 hoist_args in
      let hoisted_args = CList.filter_with (Array.to_list hoist_args) (Array.to_list args) in
      let app =
	let f' = Vars.lift nargs f in
        let (args', _) = array_fold_right_map
	  (fun (arg, hoist) n -> if not hoist then
                                   mkRel (destRel sigma arg + nargs), n
                                 else
                                   mkRel n, n+1)
	  (array_combine args hoist_args) 1
        in
        mkApp (f', args')
      in
      wrap_lets hoisted_args app
  | Cast (e,ck,ty) ->
      if isRel sigma e then term
      else wrap_lets [e] (mkCast (mkRel 1, ck, Vars.lift 1 ty))
  | Proj (proj, e) ->
      if isRel sigma e then term
      else wrap_lets [e] (mkProj (proj, mkRel 1))

(* The innermost let binding is appeared first in the result:
  Here, "exp" means AST of exp, not string.

    decompose_lets
      "let x : nat := 0 in
       let y : nat := 1 in
       let z : nat := 2 in
      body"

  returns

    ([("z","2","nat"); ("y","1","nat"); ("x","0","nat")], "body")

  This order of bindings is same as Constr.rel_context used by
  Environ.push_rel_context.
*)
let decompose_lets (sigma : Evd.evar_map) (term : EConstr.t) : (Name.t Context.binder_annot * EConstr.t * EConstr.types) list * EConstr.t =
  let rec aux term defs =
    match EConstr.kind sigma term with
    | LetIn (x, e, ty, b) ->
        aux b ((x, e, ty) :: defs)
    | _ -> (defs, term)
  in
  aux term []

let rec compose_lets (defs : (Name.t Context.binder_annot * EConstr.t * EConstr.types) list) (body : EConstr.t) : EConstr.t =
  match defs with
  | [] -> body
  | (x,e,ty) :: rest ->
      compose_lets rest (mkLetIn (x, e, ty, body))

let reduce_arg (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel i ->
      (match Environ.lookup_rel i env with
      | Context.Rel.Declaration.LocalAssum _ -> term
      | Context.Rel.Declaration.LocalDef (n,e,t) ->
          (match Constr.kind e with
          | Rel j -> mkRel (i + j)
          | _ -> term))
  | _ -> term

let debug_reduction (rule : string) (msg : unit -> Pp.t) : unit =
  if !opt_debug_reduction then
    Feedback.msg_debug (Pp.str ("reduction(" ^ rule ^ "):") ++ Pp.fnl () ++ msg ())

let rec fv_range_rec (sigma : Evd.evar_map) (numlocal : int) (term : EConstr.t) : (int*int) option =
  match EConstr.kind sigma term with
  | Var _ | Meta _ | Sort _ | Ind _ | Int _ | Float _
  | Const _ | Construct _ -> None
  | Rel i ->
      if numlocal < i then
        Some (i-numlocal,i-numlocal)
      else
        None
  | Evar (ev, es) ->
      fv_range_array sigma numlocal es
  | Proj (proj, e) ->
      fv_range_rec sigma numlocal e
  | Cast (e,ck,t) ->
      merge_range
        (fv_range_rec sigma numlocal e)
        (fv_range_rec sigma numlocal t)
  | App (f, args) ->
      merge_range
        (fv_range_rec sigma numlocal f)
        (fv_range_array sigma numlocal args)
  | LetIn (x,e,t,b) ->
      merge_range3
        (fv_range_rec sigma numlocal e)
        (fv_range_rec sigma numlocal t)
        (fv_range_rec sigma (numlocal+1) b)
  | Case (ci, p, item, branches) ->
      merge_range3
        (fv_range_rec sigma numlocal p)
        (fv_range_rec sigma numlocal item)
        (fv_range_array sigma numlocal branches)
  | Prod (x,t,b) ->
      merge_range
        (fv_range_rec sigma numlocal t)
        (fv_range_rec sigma (numlocal+1) b)
  | Lambda (x,t,b) ->
      merge_range
        (fv_range_rec sigma numlocal t)
        (fv_range_rec sigma (numlocal+1) b)
  | Fix ((ia, i), (nary, tary, fary)) ->
      merge_range
        (fv_range_array sigma numlocal tary)
        (fv_range_array sigma (numlocal + Array.length fary) fary)
  | CoFix (i, (nary, tary, fary)) ->
      merge_range
        (fv_range_array sigma numlocal tary)
        (fv_range_array sigma (numlocal + Array.length fary) fary)
and fv_range_array (sigma : Evd.evar_map) (numlocal : int) (terms : EConstr.t array) : (int*int) option =
  Array.fold_left
    (fun acc term -> merge_range acc (fv_range_rec sigma numlocal term))
    None terms

let fv_range (sigma : Evd.evar_map) (term : EConstr.t) : (int*int) option =
  fv_range_rec sigma 0 term

let test_bounded_fix (env : Environ.env) (sigma : Evd.evar_map) (k : int)
    (lift : int -> EConstr.t -> EConstr.t) (ia : int array)
    (prec : Name.t Context.binder_annot array * EConstr.types array * EConstr.t array) =
  (*Feedback.msg_info (Pp.str "test_bounded_fix: k=" ++ Pp.int k ++ Pp.spc () ++
    Printer.pr_econstr_env env sigma (mkFix ((ia,0),prec)));*)
  let n = Array.length ia in
  let vals_opt =
    let rec loop j acc =
      if n <= j then
        Some acc
      else
        match EConstr.lookup_rel (k + j) env with
        | Context.Rel.Declaration.LocalAssum _ -> None
        | Context.Rel.Declaration.LocalDef (_,e,_) ->
            match EConstr.kind sigma e with
            | Fix ((ia', i'), prec') ->
                if i' = n - j - 1 then
                  loop (j+1) (e :: acc)
                else
                  None
            | _ -> None

    in
    loop 0 []
  in
  match vals_opt with
  | None -> false
  | Some vals ->
      CList.for_all_i
        (fun i e -> EConstr.eq_constr sigma e
          (lift (-(k+n-1-i)) (mkFix ((ia, i), prec))))
        0 vals

(* This function returns (Some i) where i is the de Bruijn index that
    env[i] is (mkFix ((ia,0),prec)),
    env[i-1] is (mkFix ((ia,1),prec)), ...
    env[i-n+1] is (mkFix ((ia,n-1),prec))
  where n is the nubmer of the mutually recursive functions (i.e. the length of ia).

  None is returned otherwise.
  *)
let find_bounded_fix (env : Environ.env) (sigma : Evd.evar_map) (ia : int array)
    (prec : Name.t Context.binder_annot array * EConstr.types array * EConstr.t array) :
    int option =
  (*Feedback.msg_info (Pp.str "find_bounded_fix:" ++ Pp.spc () ++
    Printer.pr_econstr_env env sigma (mkFix ((ia,0),prec)));*)
  let (nary, tary, fary) = prec in
  let n = Array.length fary in
  let nb_rel = Environ.nb_rel env in
  match fv_range sigma (mkFix ((ia,0),prec)) with
  | None ->
      (*Feedback.msg_info (Pp.str "find_bounded_fix: fv_range=None");*)
      let lift _ term = term in
      let rec loop k =
        if nb_rel < k + n - 1 then
          None
        else
          if test_bounded_fix env sigma k lift ia prec then
            Some (k + n - 1)
          else
            loop (k+1)
      in
      loop 1
  | Some (fv_min, fv_max) ->
      (*Feedback.msg_info (Pp.str "find_bounded_fix: fv_range=Some (" ++ Pp.int fv_min ++ Pp.str "," ++ Pp.int fv_max ++ Pp.str ")");*)
      let lift = Vars.lift in
      let rec loop k =
        if fv_min <= k + n - 1 then
          None
        else
          if test_bounded_fix env sigma k lift ia prec then
            Some (k + n - 1)
          else
            loop (k+1)
      in
      loop 1

(* invariant: letin-bindings in env is reduced form *)
let rec reduce_exp (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  let t1 = Unix.times () in
  (if !opt_debug_reduce_exp then
    Feedback.msg_debug (Pp.str "reduce_exp arg: " ++ Printer.pr_econstr_env env sigma term));
  let result = reduce_exp1 env sigma term in
  (if !opt_debug_reduce_exp then
    let t2 = Unix.times () in
    Feedback.msg_debug (Pp.str "reduce_exp ret (" ++ Pp.real (t2.Unix.tms_utime -. t1.Unix.tms_utime) ++ Pp.str "): " ++ Printer.pr_econstr_env env sigma result));
  check_convertible "reduce_exp" env sigma term result;
  result
and reduce_exp1 (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel i ->
      let term2 = reduce_arg env sigma term in
      if destRel sigma term2 <> i then
        (debug_reduction "rel" (fun () ->
          Printer.pr_econstr_env env sigma term ++ Pp.fnl () ++
          Pp.str "->" ++ Pp.fnl () ++
          Printer.pr_econstr_env env sigma term2);
        check_convertible "reduction(rel)" env sigma term term2;
        term2)
      else
        term
  | Var _ | Meta _ | Evar _ | Sort _ | Prod _
  | Const _ | Ind _ | Construct _ | Int _ | Float _ -> term
  | Cast (e,ck,t) -> reduce_exp env sigma e
  | Lambda (x,t,e) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      mkLambda (x, t, reduce_exp env2 sigma e)
  | LetIn (x,e,t,b) ->
      let e' = reduce_exp env sigma e in
      if isLetIn sigma e' then
        let (defs, body) = decompose_lets sigma e' in
        let n = List.length defs in
        let t' = Vars.lift n t in
        let b' = Vars.liftn n 2 b in
        let term2 = compose_lets defs (mkLetIn (x, body, t', b')) in
        debug_reduction "letin" (fun () ->
          Printer.pr_econstr_env env sigma term ++ Pp.fnl () ++
          Pp.str "->" ++ Pp.fnl () ++
          Printer.pr_econstr_env env sigma term2);
        check_convertible "reduction(letin)" env sigma term term2;
        let ctx = List.map (fun (x,e,t) -> Context.Rel.Declaration.LocalDef (x,e,t)) defs in
        let env2 = EConstr.push_rel_context ctx env in
        let decl = Context.Rel.Declaration.LocalDef (x, body, t') in
        let env3 = EConstr.push_rel decl env2 in
        compose_lets defs (mkLetIn (x, body, t', reduce_exp env3 sigma b'))
      else
        let decl = Context.Rel.Declaration.LocalDef (x, e', t) in
        let env2 = EConstr.push_rel decl env in
        mkLetIn (x, e', t, reduce_exp env2 sigma b)
  | Case (ci,p,item,branches) ->
      let item' = reduce_arg env sigma item in
      let default () =
        mkCase (ci, p, item', Array.map (reduce_exp env sigma) branches)
      in
      let i = destRel sigma item' in
      (match EConstr.lookup_rel i env with
      | Context.Rel.Declaration.LocalAssum _ -> default ()
      | Context.Rel.Declaration.LocalDef (x,e,t) ->
          let (f, args) = decompose_app sigma e in
          (match EConstr.kind sigma f with
          | Construct ((ind, j), _) ->
              let branch = branches.(j-1) in
              let args = (Array.of_list (CList.skipn ci.ci_npar args)) in
              let args = Array.map (Vars.lift i) args in
              let term2 = mkApp (branch, args) in
              debug_reduction "match" (fun () ->
                Pp.str "match-item = " ++
                Printer.pr_econstr_env env sigma item ++ Pp.str " = " ++
                Printer.pr_econstr_env (Environ.pop_rel_context i env) sigma e ++ Pp.fnl () ++
                Printer.pr_econstr_env env sigma term ++ Pp.fnl () ++
                Pp.str "->" ++ Pp.fnl () ++
                Printer.pr_econstr_env env sigma term2);
              check_convertible "reduction(match)" env sigma term term2;
              reduce_exp env sigma term2
          | _ -> default ()))
  | Proj (pr,item) ->
      let item' = reduce_arg env sigma item in
      let default () = mkProj (pr, item') in
      let i = destRel sigma item' in
      (match EConstr.lookup_rel i env with
      | Context.Rel.Declaration.LocalAssum _ -> default ()
      | Context.Rel.Declaration.LocalDef (x,e,t) ->
          (* Feedback.msg_info (Pp.str "reduce_exp(Proj): lookup = " ++ Printer.pr_econstr_env (Environ.pop_rel_context i env) sigma e);
          Feedback.msg_info (Pp.str "reduce_exp(Proj): Projection.npars = " ++ int (Projection.npars pr));
          Feedback.msg_info (Pp.str "reduce_exp(Proj): Projection.arg = " ++ int (Projection.arg pr)); *)
          let (f, args) = decompose_app sigma e in
          (match EConstr.kind sigma f with
          | Construct _ ->
              let term2 = List.nth args (Projection.npars pr + Projection.arg pr) in
              let term2 = Vars.lift i term2 in
              debug_reduction "proj" (fun () ->
                Pp.str "proj-item = " ++
                Printer.pr_econstr_env env sigma item ++ Pp.str " = " ++
                Printer.pr_econstr_env (Environ.pop_rel_context i env) sigma e ++ Pp.fnl () ++
                Printer.pr_econstr_env env sigma term ++ Pp.fnl () ++
                Pp.str "->" ++ Pp.fnl () ++
                Printer.pr_econstr_env env sigma term2);
              check_convertible "reduction(proj)" env sigma term term2;
              reduce_exp env sigma term2
          | _ -> default ()))
  | Fix ((ia,i), ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkFix ((ia, i), (nary, tary, Array.map (reduce_exp env2 sigma) fary))
  | CoFix (i, ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkCoFix (i, (nary, tary, Array.map (reduce_exp env2 sigma) fary))
  | App (f,args) ->
      (*Feedback.msg_info (Pp.str "reduce_exp App f1:" ++ Pp.spc () ++ Printer.pr_econstr_env env sigma f);*)
      let f_nf = reduce_exp env sigma f in
      (*Feedback.msg_info (Pp.str "reduce_exp App f2:" ++ Pp.spc () ++ Printer.pr_econstr_env env sigma f);*)
      let args_nf = Array.map (reduce_arg env sigma) args in
      reduce_app env sigma f_nf args_nf
and reduce_app (env : Environ.env) (sigma : Evd.evar_map) (f_nf : EConstr.t) (args_nf : EConstr.t array) : EConstr.t =
  let f_nf_content =
    if isRel sigma f_nf then
      let m = destRel sigma f_nf in
      match EConstr.lookup_rel m env with
      | Context.Rel.Declaration.LocalAssum _ -> f_nf
      | Context.Rel.Declaration.LocalDef (x,e,t) -> Vars.lift m e
    else
      f_nf
  in
  (*Feedback.msg_info (Pp.str "reduce_app f_nf_content:" ++ Pp.spc () ++ Printer.pr_econstr_env env sigma f_nf_content);*)
  let default () = mkApp (f_nf, args_nf) in
  let term1 = mkApp (f_nf_content, args_nf) in
  match EConstr.kind sigma f_nf_content with
  | Lambda _ ->
      let term2 = Reductionops.beta_applist sigma (f_nf_content, (Array.to_list args_nf)) in
      debug_reduction "beta" (fun () ->
        Printer.pr_econstr_env env sigma term1 ++ Pp.fnl () ++
        Pp.str "->" ++ Pp.fnl () ++
        Printer.pr_econstr_env env sigma term2);
      check_convertible "reduction(beta)" env sigma term1 term2;
      reduce_exp env sigma term2
  | App (f_f_nf, f_args_nf) ->
      reduce_app env sigma f_f_nf (Array.append f_args_nf args_nf)
  | LetIn (x,e_nf,t,b_nf) ->
      let args_nf_lifted = Array.map (Vars.lift 1) args_nf in
      let term2 = mkLetIn (x,e_nf,t, mkApp (b_nf, args_nf_lifted)) in
      debug_reduction "app-let" (fun () ->
        Printer.pr_econstr_env env sigma term1 ++ Pp.fnl () ++
        Pp.str "->" ++ Pp.fnl () ++
        Printer.pr_econstr_env env sigma term2);
      check_convertible "reduction(app-let)" env sigma term1 term2;
      let decl = Context.Rel.Declaration.LocalDef (x, e_nf, t) in
      let env2 = EConstr.push_rel decl env in
      mkLetIn (x,e_nf,t, reduce_app env2 sigma b_nf args_nf_lifted)
  | Fix ((ia,i), ((nary, tary, fary_nf) as prec)) ->
      if ia.(i) < Array.length args_nf then
        let decarg_var = args_nf.(ia.(i)) in
        let decarg_decl = EConstr.lookup_rel (destRel sigma decarg_var) env in
        (match decarg_decl with
        | Context.Rel.Declaration.LocalAssum _ -> default ()
        | Context.Rel.Declaration.LocalDef (_,decarg_val,_) ->
            let (decarg_f, decarg_args) = decompose_app sigma decarg_val in
            if isConstruct sigma decarg_f then
              let n = Array.length fary_nf in
              let fi_nf = fary_nf.(i) in
              match find_bounded_fix env sigma ia prec with
              | Some bounded_fix ->
                  (*Feedback.msg_info (Pp.str "bounded_fix: " ++ Printer.pr_rel_decl (Environ.pop_rel_context bounded_fix env) sigma (Environ.lookup_rel bounded_fix env));*)
                  let fi_nf_subst = Vars.substl (List.map (fun j -> mkRel j) (iota_list (bounded_fix-n+1) n)) fi_nf in
                  let term2 = mkApp (fi_nf_subst, args_nf) in
                  debug_reduction "fix-reuse-let" (fun () ->
                    let env2 = Environ.pop_rel_context (destRel sigma decarg_var) env in
                    let nf_decarg_val = Reductionops.nf_all env2 sigma decarg_val in
                    Pp.str "decreasing-argument = " ++
                    Printer.pr_econstr_env env sigma decarg_var ++ Pp.str " = " ++
                    Printer.pr_econstr_env env2 sigma decarg_val ++ Pp.str " = " ++
                    Printer.pr_econstr_env env sigma nf_decarg_val ++ Pp.fnl () ++
                    Printer.pr_econstr_env env sigma term1 ++ Pp.fnl () ++
                    Pp.str "->" ++ Pp.fnl () ++
                    Printer.pr_econstr_env env sigma term2);
                  check_convertible "reduction(fix-reuse-let)" env sigma term1 term2;
                  reduce_app env sigma fi_nf_subst args_nf
              | None ->
                  let args_nf_lifted = Array.map (Vars.lift n) args_nf in
                  let (_, defs) = CArray.fold_left2_map
                    (fun j x t -> (j+1, (x, Vars.lift j (mkFix ((ia,j), prec)), Vars.lift j t)))
                    0 nary tary
                  in
                  let defs = Array.to_list (array_rev defs) in
                  let term2 = compose_lets defs (mkApp (fi_nf, args_nf_lifted)) in
                  debug_reduction "fix-new-let" (fun () ->
                    Pp.str "decreasing-argument = " ++
                    Printer.pr_econstr_env env sigma decarg_var ++ Pp.str " = " ++
                    Printer.pr_econstr_env (Environ.pop_rel_context (destRel sigma decarg_var) env) sigma decarg_val ++ Pp.fnl () ++
                    Printer.pr_econstr_env env sigma term1 ++ Pp.fnl () ++
                    Pp.str "->" ++ Pp.fnl () ++
                    Printer.pr_econstr_env env sigma term2);
                  check_convertible "reduction(fix-new-let)" env sigma term1 term2;
                  let ctx = List.map (fun (x,e,t) -> Context.Rel.Declaration.LocalDef (x,e,t)) defs in
                  let env2 = EConstr.push_rel_context ctx env in
                  let b = reduce_app env2 sigma fi_nf args_nf_lifted in
                  compose_lets defs b

            else
              default ())
      else
        default ()
  | _ -> default ()

let rec first_fv_rec (sigma : Evd.evar_map) (numrels : int) (term : EConstr.t) : int option =
  match EConstr.kind sigma term with
  | Var _ | Meta _ | Sort _ | Ind _ | Int _ | Float _
  | Const _ | Construct _ -> None
  | Rel i -> if numrels < i then Some i else None
  | Evar (ev, es) ->
      array_option_exists (first_fv_rec sigma numrels) es
  | Proj (proj, e) ->
      first_fv_rec sigma numrels e
  | Cast (e,ck,t) ->
      shortcut_option_or (first_fv_rec sigma numrels e)
        (fun () -> first_fv_rec sigma numrels t)
  | App (f, args) ->
      shortcut_option_or (first_fv_rec sigma numrels f)
        (fun () -> array_option_exists (first_fv_rec sigma numrels) args)
  | LetIn (x,e,t,b) ->
      shortcut_option_or (first_fv_rec sigma numrels e)
        (fun () -> shortcut_option_or (first_fv_rec sigma numrels t)
          (fun () -> Option.map int_pred (first_fv_rec sigma (numrels+1) b)))
  | Case (ci, p, item, branches) ->
      shortcut_option_or (first_fv_rec sigma numrels p)
        (fun () -> shortcut_option_or (first_fv_rec sigma numrels item)
          (fun () -> array_option_exists (first_fv_rec sigma numrels) branches))
  | Prod (x,t,b) ->
      shortcut_option_or (first_fv_rec sigma numrels t)
        (fun () -> Option.map int_pred (first_fv_rec sigma (numrels+1) b))
  | Lambda (x,t,b) ->
      shortcut_option_or (first_fv_rec sigma numrels t)
        (fun () -> Option.map int_pred (first_fv_rec sigma (numrels+1) b))
  | Fix ((ia, i), (nameary, tyary, funary)) ->
      let n = Array.length funary in
      shortcut_option_or (array_option_exists (first_fv_rec sigma numrels) tyary)
        (fun () -> Option.map (fun i -> i-n) (array_option_exists (first_fv_rec sigma (numrels+n)) funary))
  | CoFix (i, (nameary, tyary, funary)) ->
      let n = Array.length funary in
      shortcut_option_or (array_option_exists (first_fv_rec sigma numrels) tyary)
        (fun () -> Option.map (fun i -> i-n) (array_option_exists (first_fv_rec sigma (numrels+n)) funary))

let first_fv (sigma : Evd.evar_map) (term : EConstr.t) : int option =
  first_fv_rec sigma 0 term

let has_fv sigma term : bool =
  Stdlib.Option.is_some (first_fv sigma term)

let replace_app (env : Environ.env) (sigma : Evd.evar_map) (func : Constr.t) (args : EConstr.t array) : EConstr.t option =
  (* Feedback.msg_info (Pp.str "replace_app: " ++ Printer.pr_econstr_env env sigma (mkApp ((EConstr.of_constr func), args))); *)
  let sp_cfg = codegen_specialization_auto_arguments_internal env sigma func in
  let sd_list = drop_trailing_d sp_cfg.sp_sd_list in
  (if Array.length args < List.length sd_list then
    user_err (Pp.str "Not enough arguments for" ++ spc () ++ (Printer.pr_constr_env env sigma func)));
  let sd_list = List.append sd_list (List.init (Array.length args - List.length sd_list) (fun _ -> SorD_D)) in
  let static_flags = List.map (fun sd -> sd = SorD_S) sd_list in
  let static_args = CArray.filter_with static_flags args in
  let nf_static_args = Array.map (Reductionops.nf_all env sigma) static_args in
  (Array.iteri (fun i arg ->
    let nf_arg = nf_static_args.(i) in
    let fv_opt = first_fv sigma nf_arg in
    match fv_opt with
    | None -> ()
    | Some k ->
      user_err (Pp.str "Free variable found in a static argument:" ++ spc () ++
        Printer.pr_constr_env env sigma func ++
        Pp.str "'s" ++ spc () ++
        Pp.str (CString.ordinal (i+1)) ++ spc () ++
        Pp.str "static argument" ++ spc () ++
        Printer.pr_econstr_env env sigma arg ++ spc () ++
        Pp.str "refer" ++ spc () ++
        Printer.pr_econstr_env env sigma (mkRel k)))
    nf_static_args);
  let nf_static_args = CArray.map_to_list (EConstr.to_constr sigma) nf_static_args in
  let efunc = EConstr.of_constr func in
  let efunc_type = Retyping.get_type_of env sigma efunc in
  let (_, partapp, _) = build_partapp env sigma efunc efunc_type sd_list nf_static_args in
  (*Feedback.msg_info (Pp.str "replace partapp: " ++ Printer.pr_constr_env env sigma partapp);*)
  let sp_inst = match ConstrMap.find_opt partapp sp_cfg.sp_instance_map with
    | None -> specialization_instance_internal env sigma func nf_static_args None
    | Some sp_inst -> sp_inst
  in
  let sp_ctnt = sp_inst.sp_partapp_constr in
  let dynamic_flags = List.map (fun sd -> sd = SorD_D) sd_list in
  Some (mkApp (EConstr.of_constr sp_ctnt, CArray.filter_with dynamic_flags args))

let new_env_with_rels (env : Environ.env) : Environ.env =
  let n = Environ.nb_rel env in
  let r = ref (Global.env ()) in
  for i = n downto 1 do
    r := Environ.push_rel (Environ.lookup_rel i env) (!r)
  done;
  !r

(* This function assumes A-normal form.  So this function doesn't traverse subterms of Proj, Cast and App. *)
let rec replace (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  (if !opt_debug_replace then
    Feedback.msg_debug (Pp.str "replace arg: " ++ Printer.pr_econstr_env env sigma term));
  let result = replace1 env sigma term in
  (if !opt_debug_replace then
    Feedback.msg_debug (Pp.str "replace ret: " ++ Printer.pr_econstr_env env sigma result));
  check_convertible "replace" (new_env_with_rels env) sigma term result;
  result
and replace1 (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel _ | Var _ | Meta _ | Evar _ | Sort _ | Prod _
  | Const _ | Ind _ | Int _ | Float _ | Construct _
  | Proj _ | Cast _ -> term
  | Lambda (x, ty, e) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, ty) in
      let env2 = EConstr.push_rel decl env in
      mkLambda (x, ty, replace env2 sigma e)
  | Fix ((ia, i), ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkFix ((ia, i), (nameary, tyary, Array.map (replace env2 sigma) funary))
  | CoFix (i, ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkCoFix (i, (nameary, tyary, Array.map (replace env2 sigma) funary))
  | LetIn (x, e, ty, b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, ty) in
      let env2 = EConstr.push_rel decl env in
      mkLetIn (x, replace env sigma e, ty, replace env2 sigma b)
  | Case (ci, p, item, branches) ->
      mkCase (ci, p, replace env sigma item, Array.map (replace env sigma) branches)
  | App (f, args) ->
      let f = replace env sigma f in
      match EConstr.kind sigma f with
      | Const (ctnt, u) ->
          let f' = Constr.mkConst ctnt in
          (match replace_app env sigma f' args with
          | None -> term
          | Some e -> e)
      | Construct (cstr, u) ->
          let f' = Constr.mkConstruct cstr in
          (match replace_app env sigma f' args with
          | None -> term
          | Some e -> e)
      | _ -> mkApp (f, args)

(*
 * expand_eta assumes term is already reduced by reduce_exp,
 * "body" of following syntax:
 *
 *  body = let | exp
 *
 *  exp = lambda | app | func                   # body - let
 *
 *  func = var | ctnt | cstr | fix | match      # body - let - lambda - app
 *
 *  let = "let" var ":=" exp "in" body          # no (let x := (let ...) in body) because "letin" reduction
 *
 *  lambda = "fun" var "=>" body
 *
 *  app = func var+     # no ((let ...) args) because "app-let" reduction
 *                      # no ((fun ...) args) because "beta" reduction
 *                      # no ((f args) args) because mkApp generates single application.
 *
 *  fix = "fix" (var ":=" body)+ "for" var
 *
 *  match = "match" var "with" ( "|" cstr "=>" body )* "end"
 *
 * expand_eta apply eta expansion to "app" until the type
 * of "app" is not a function type.
 *)
let rec expand_eta (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  (if !opt_debug_expand_eta then
    Feedback.msg_debug (Pp.str "expand_eta arg: " ++ Printer.pr_econstr_env env sigma term));
  let result = expand_eta_body env sigma term in
  (if !opt_debug_expand_eta then
    Feedback.msg_debug (Pp.str "expand_eta ret: " ++ Printer.pr_econstr_env env sigma result));
  check_convertible "expand_eta" (new_env_with_rels env) sigma term result;
  result
and expand_eta_body (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | LetIn (x, e, t, b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, t) in
      let env2 = EConstr.push_rel decl env in
      mkLetIn (x, expand_eta_exp env sigma e, t, expand_eta_body env2 sigma b)
  | _ -> expand_eta_exp env sigma term
and expand_eta_exp (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Lambda (x, t, b) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      mkLambda (x, t, expand_eta_body env2 sigma b)
  | App (func, args) ->
      let func' = expand_eta_func env sigma func in
      let term_type = Retyping.get_type_of env sigma term in
      expand_eta_app env sigma func' args term_type
  | _ -> expand_eta_func env sigma term
and expand_eta_func (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Fix ((ia, i), ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkFix ((ia, i), (nary, tary, Array.map (expand_eta_body env2 sigma) fary))
  | CoFix (i, ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      mkCoFix (i, (nary, tary, Array.map (expand_eta_body env2 sigma) fary))
  | Case (ci, p, item, branches) ->
      mkCase (ci, p, item, Array.map (expand_eta_body env sigma) branches)
  | _ -> term
and expand_eta_app (env : Environ.env) (sigma : Evd.evar_map) (func : EConstr.t) (args : EConstr.t array) (term_type : EConstr.types) : EConstr.t =
  let term_type = Reductionops.nf_all env sigma term_type in
  let (n, relc, body_type) = Termops.decompose_prod_letin sigma term_type in
  let term' = mkApp (func, args) in
  let lifted_term = Vars.lift n term' in
  let args = Array.map (fun i -> mkRel i) (array_rev (iota_ary 1 n)) in
  it_mkLambda_or_LetIn (mkApp (lifted_term, args)) relc

let rec count_false_in_prefix (n : int) (refs : bool ref list) : int =
  if n <= 0 then
    0
  else
    match refs with
    | [] -> 0
    | r :: rest ->
        if !r then
          count_false_in_prefix (n-1) rest
        else
          1 + count_false_in_prefix (n-1) rest

let rec normalize_types (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel _ | Var _ | Meta _ | Sort _ | Ind _ | Int _ | Float _
  | Const _ | Construct _ -> term
  | Evar (ev, es) ->
      mkEvar (ev, Array.map (normalize_types env sigma) es)
  | Proj (proj, e) ->
      mkProj (proj, normalize_types env sigma e)
  | Cast (e,ck,t) ->
      let e' = normalize_types env sigma e in
      let t' = Reductionops.nf_all env sigma t in
      mkCast(e', ck, t')
  | App (f, args) ->
      let f' = normalize_types env sigma f in
      let args' = Array.map (normalize_types env sigma) args in
      mkApp (f', args')
  | LetIn (x,e,t,b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, t) in
      let env2 = EConstr.push_rel decl env in
      let e' = normalize_types env sigma e in
      let t' = Reductionops.nf_all env sigma t in
      let b' = normalize_types env2 sigma b in
      mkLetIn (x, e', t', b')
  | Case (ci, p, item, branches) ->
      let p' = Reductionops.nf_all env sigma p in
      let item' = normalize_types env sigma item in
      let branches' = Array.map (normalize_types env sigma) branches in
      mkCase (ci, p', item', branches')
  | Prod (x,t,b) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      let t' = Reductionops.nf_all env sigma t in
      let b' = normalize_types env2 sigma b in
      mkProd (x, t', b')
  | Lambda (x,t,e) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      let t' = Reductionops.nf_all env sigma t in
      let e' = normalize_types env2 sigma e in
      mkLambda (x, t', e')
  | Fix ((ia, i), ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      let tyary' = Array.map (Reductionops.nf_all env sigma) tyary in
      let funary' = Array.map (normalize_types env2 sigma) funary in
      mkFix ((ia, i), (nameary, tyary', funary'))
  | CoFix (i, ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      let tyary' = Array.map (Reductionops.nf_all env sigma) tyary in
      let funary' = Array.map (normalize_types env2 sigma) funary in
      mkCoFix (i, (nameary, tyary', funary'))

let rec reduce_function (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  match EConstr.kind sigma term with
  | Rel i ->
      (match EConstr.lookup_rel i env with
      | Context.Rel.Declaration.LocalAssum _ -> term
      | Context.Rel.Declaration.LocalDef (n,e,t) ->
          Vars.lift i e)
  | Var _ | Meta _ | Sort _ | Ind _ | Int _ | Float _
  | Const _ | Construct _ | Evar _ | Proj _ | Prod _ -> term
  | Cast (e,ck,t) -> reduce_function env sigma e
  | App (f, args) ->
      let f' = reduce_function env sigma f in
      mkApp (f', args)
  | LetIn (x,e,t,b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, t) in
      let env2 = EConstr.push_rel decl env in
      let e' = reduce_function env sigma e in
      let b' = reduce_function env2 sigma b in
      mkLetIn (x, e', t, b')
  | Case (ci, p, item, branches) ->
      let branches' = Array.map (reduce_function env sigma) branches in
      mkCase (ci, p, item, branches')
  | Lambda (x,t,e) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      let e' = reduce_function env2 sigma e in
      mkLambda (x, t, e')
  | Fix ((ia, i), ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      let fary' = Array.map (reduce_function env2 sigma) fary in
      mkFix ((ia, i), (nary, tary, fary'))
  | CoFix (i, ((nary, tary, fary) as prec)) ->
      let env2 = push_rec_types prec env in
      let fary' = Array.map (reduce_function env2 sigma) fary in
      mkCoFix (i, (nary, tary, fary'))

(* xxx: consider linear type *)
let rec delete_unused_let_rec (env : Environ.env) (sigma : Evd.evar_map) (refs : bool ref list) (term : EConstr.t) : unit -> EConstr.t =
  (if !opt_debug_delete_let then
    Feedback.msg_debug (Pp.str "delete_unused_let_rec arg: " ++ Printer.pr_econstr_env env sigma term));
  match EConstr.kind sigma term with
  | Var _ | Meta _ | Sort _ | Ind _ | Int _ | Float _
  | Const _ | Construct _ -> fun () -> term
  | Rel i ->
      (List.nth refs (i-1)) := true;
      fun () -> mkRel (i - count_false_in_prefix (i-1) refs)
  | Evar (ev, es) ->
      let fs = Array.map (delete_unused_let_rec env sigma refs) es in
      fun () -> mkEvar (ev, Array.map (fun f -> f ()) fs)
  | Proj (proj, e) ->
      let f = delete_unused_let_rec env sigma refs e in
      fun () -> mkProj (proj, f ())
  | Cast (e,ck,t) ->
      let fe = delete_unused_let_rec env sigma refs e in
      let ft = delete_unused_let_rec env sigma refs t in
      fun () -> mkCast(fe (), ck, ft ())
  | App (f, args) ->
      let ff = delete_unused_let_rec env sigma refs f in
      let fargs = Array.map (delete_unused_let_rec env sigma refs) args in
      fun () -> mkApp (ff (), Array.map (fun g -> g ()) fargs)
  | LetIn (x,e,t,b) ->
      let decl = Context.Rel.Declaration.LocalDef (x, e, t) in
      let env2 = EConstr.push_rel decl env in
      let r = ref false in
      let refs2 = r :: refs in
      let fb = delete_unused_let_rec env2 sigma refs2 b in
      if !r then
        let fe = delete_unused_let_rec env sigma refs e in
        let ft = delete_unused_let_rec env sigma refs t in
        fun () -> mkLetIn (x, fe (), ft (), fb ())
      else
        fb
  | Case (ci, p, item, branches) ->
      let fp = delete_unused_let_rec env sigma refs p in
      let fitem = delete_unused_let_rec env sigma refs item in
      let fbranches = Array.map (delete_unused_let_rec env sigma refs) branches in
      fun () -> mkCase (ci, fp (), fitem (), Array.map (fun g -> g ()) fbranches)
  | Prod (x,t,b) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      let refs2 = (ref true) :: refs in
      let ft = delete_unused_let_rec env sigma refs t in
      let fb = delete_unused_let_rec env2 sigma refs2 b in
      fun () -> mkProd (x, ft (), fb ())
  | Lambda (x,t,e) ->
      let decl = Context.Rel.Declaration.LocalAssum (x, t) in
      let env2 = EConstr.push_rel decl env in
      let refs2 = (ref true) :: refs in
      let ft = delete_unused_let_rec env sigma refs t in
      let fe = delete_unused_let_rec env2 sigma refs2 e in
      fun () -> mkLambda (x, ft (), fe ())
  | Fix ((ia, i), ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      let rs = List.init (Array.length funary) (fun _ -> ref true) in
      let refs2 = List.append rs refs in
      let ftyary = Array.map (delete_unused_let_rec env sigma refs) tyary in
      let ffunary = Array.map (delete_unused_let_rec env2 sigma refs2) funary in
      fun () -> mkFix ((ia, i), (nameary, Array.map (fun g -> g ()) ftyary, Array.map (fun g -> g ()) ffunary))
  | CoFix (i, ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      let rs = List.init (Array.length funary) (fun _ -> ref true) in
      let refs2 = List.append rs refs in
      let ftyary = Array.map (delete_unused_let_rec env sigma refs) tyary in
      let ffunary = Array.map (delete_unused_let_rec env2 sigma refs2) funary in
      fun () -> mkCoFix (i, (nameary, Array.map (fun g -> g ()) ftyary, Array.map (fun g -> g ()) ffunary))

let delete_unused_let (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : EConstr.t =
  (if !opt_debug_delete_let then
    Feedback.msg_debug (Pp.str "delete_unused_let arg: " ++ Printer.pr_econstr_env env sigma term));
  let f = delete_unused_let_rec env sigma [] term in
  let result = f () in
  (if !opt_debug_delete_let then
    Feedback.msg_debug (Pp.str "delete_unused_let ret: " ++ Printer.pr_econstr_env env sigma result));
  check_convertible "specialize" env sigma term result;
  result

let specialization_time = ref (Unix.times ())

let init_debug_specialization () : unit =
  if !opt_debug_specialization then
    specialization_time := Unix.times ()

let debug_specialization (env : Environ.env) (sigma : Evd.evar_map) (step : string) (term : EConstr.t) : unit =
  if !opt_debug_specialization then
    (let old = !specialization_time in
    let now = Unix.times () in
    Feedback.msg_debug (Pp.str ("--" ^ step ^ "--> (") ++ Pp.real (now.Unix.tms_utime -. old.Unix.tms_utime) ++ Pp.str "[s])" ++ Pp.fnl () ++ (Printer.pr_econstr_env env sigma term));
    specialization_time := now)

let codegen_specialization_specialize1 (cfunc : string) : Constant.t =
  init_debug_specialization ();
  let (sp_cfg, sp_inst) =
    match CString.Map.find_opt cfunc !cfunc_instance_map with
    | None ->
        user_err (Pp.str "specialization instance not defined:" ++
                  Pp.spc () ++ Pp.str (escape_as_coq_string cfunc))
    | Some (sp_cfg, sp_inst) -> (sp_cfg, sp_inst)
  in
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let name = (match sp_inst.sp_specialization_name with
    | SpExpectedId id -> id
    | SpDefinedCtnt _ -> user_err (Pp.str "specialization already defined"))
  in
  let partapp = sp_inst.sp_partapp in
  let epartapp = EConstr.of_constr partapp in
  let ctnt =
    match Constr.kind sp_cfg.sp_func with
    | Const (ctnt,_) -> ctnt
    | Construct _ -> user_err (Pp.str "constructor is not specializable")
    | _ -> user_err (Pp.str "non-constant and non-constructor specialization")
  in
  let inline_pred =
    let pred_func = Cpred.singleton ctnt in
    let global_pred = !specialize_global_inline in
    let local_pred = (match Cmap.find_opt ctnt !specialize_local_inline with
                     | None -> Cpred.empty
                     | Some pred -> pred) in
    Cpred.union (Cpred.union pred_func global_pred) local_pred
  in
  debug_specialization env sigma "partial-application" epartapp;
  let term = inline env sigma inline_pred epartapp in
  debug_specialization env sigma "inline" term;
  (*let term = strip_cast env sigma term in*)
  let term = normalizeK env sigma term in
  debug_specialization env sigma "normalizeK" term;
  let term = reduce_exp env sigma term in
  debug_specialization env sigma "reduce_exp" term;
  let term = replace env sigma term in
  debug_specialization env sigma "replace" term;
  (*let term = expand_eta env sigma term in
  debug_specialization env sigma "expand_eta" term;*)
  let term = normalize_types env sigma term in
  debug_specialization env sigma "normalize_types" term;
  let term = reduce_function env sigma term in
  debug_specialization env sigma "reduce_function" term;
  let term = delete_unused_let env sigma term in
  debug_specialization env sigma "delete_unused_let" term;
  let univs = Evd.univ_entry ~poly:false sigma in
  let defent = Declare.DefinitionEntry (Declare.definition_entry ~univs:univs (EConstr.to_constr sigma term)) in
  let kind = Decls.IsDefinition Decls.Definition in
  let declared_ctnt = Declare.declare_constant ~name:name ~kind:kind defent in
  let sp_inst2 = {
    sp_partapp = sp_inst.sp_partapp;
    sp_static_arguments = sp_inst.sp_static_arguments;
    sp_partapp_constr = sp_inst.sp_partapp_constr;
    sp_specialization_name = SpDefinedCtnt declared_ctnt;
    sp_cfunc_name = sp_inst.sp_cfunc_name;
    sp_gen_constant = sp_inst.sp_gen_constant; }
  in
  (let m = !gallina_instance_map in
    let m = ConstrMap.set sp_inst.sp_partapp_constr (sp_cfg, sp_inst2) m in
    let m = ConstrMap.set partapp (sp_cfg, sp_inst2) m in
    let m = ConstrMap.add (Constr.mkConst declared_ctnt) (sp_cfg, sp_inst2) m in
    gallina_instance_map := m);
  (let m = !cfunc_instance_map in
    let m = CString.Map.set sp_inst.sp_cfunc_name (sp_cfg, sp_inst2) m in
    cfunc_instance_map := m);
  (let inst_map = ConstrMap.add partapp sp_inst2 sp_cfg.sp_instance_map in
   let sp_cfg2 = { sp_cfg with sp_instance_map = inst_map } in
   let m = !specialize_config_map in
   specialize_config_map := ConstrMap.add (Constr.mkConst ctnt) sp_cfg2 m);
  declared_ctnt

let codegen_specialization_specialize (cfuncs : string list) : unit =
  let env = Global.env () in
  List.iter
    (fun cfunc_name ->
      let declared_ctnt = codegen_specialization_specialize1 cfunc_name in
      Feedback.msg_info (Pp.str "Defined:" ++ spc () ++ Printer.pr_constant env declared_ctnt))
    cfuncs


