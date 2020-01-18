(*
Copyright (C) 2016- National Institute of Advanced Industrial Science and Technology (AIST)

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
open Globnames
open Pp
open CErrors
open Constr
open EConstr

open Cgenutil
open State
open Linear
open Specialize

let c_funcname (fname : string) : string =
  c_id fname

let goto_label (fname : string) : string =
  "entry_" ^ (c_id fname)

let c_typename (sigma : Evd.evar_map) (t : EConstr.types) : string =
  match ConstrMap.find_opt (EConstr.to_constr sigma t) !ind_config_map with
  | Some ind_cfg -> ind_cfg.c_type
  | None -> c_id (mangle_type t)

let c_cstrname (env : Environ.env) (sigma : Evd.evar_map) (t : EConstr.types) (cstr : Names.constructor) : string =
  let ((mutind, i), j) = cstr in
  match ConstrMap.find_opt (EConstr.to_constr sigma t) !ind_config_map with
  | Some ind_cfg ->
      (match ind_cfg.cstr_configs.(j-1).c_cstr with
      | Some c_cstr -> c_cstr
      | None -> user_err (
        Pp.str "inductive constructor not configured:" ++ Pp.spc () ++
        Id.print ind_cfg.cstr_configs.(j-1).coq_cstr ++ Pp.spc () ++
        Pp.str "for" ++ Pp.spc () ++
        Printer.pr_constr_env env sigma ind_cfg.coq_type))
  | None ->
      let mind_body = Environ.lookup_mind mutind env in
      let oind_body = mind_body.Declarations.mind_packets.(i) in
      let cons_id = oind_body.Declarations.mind_consnames.(j-1) in
      let fname = Id.to_string cons_id in
      c_funcname fname

let case_swfunc (env : Environ.env) (sigma : Evd.evar_map) (t : EConstr.types) : string =
  match ConstrMap.find_opt (EConstr.to_constr sigma t) !ind_config_map with
  | Some ind_cfg ->
      (match ind_cfg.c_swfunc with
      | Some c_swfunc -> c_swfunc
      | None -> user_err (
        Pp.str "inductive match configuration not registered:" ++ Pp.spc () ++
        Printer.pr_lconstr_env env sigma ind_cfg.coq_type))
  | None -> c_id ("sw_" ^ (mangle_type t))

let case_cstrlabel (env : Environ.env) (sigma : Evd.evar_map) (t : EConstr.types) (j : int) : string =
  match ConstrMap.find_opt (EConstr.to_constr sigma t) !ind_config_map with
  | Some ind_cfg ->
      (match ind_cfg.c_swfunc with
      | Some _ -> ind_cfg.cstr_configs.(j-1).c_caselabel
      | None -> raise (CodeGenError "inductive match configuration not registered")) (* should be called after case_swfunc *)
  | None ->
      let indty =
        match EConstr.kind sigma t with
        | Constr.App (f, argsary) -> f
        | _ -> t
      in
      let (mutind, i) = out_punivs (EConstr.destInd sigma indty) in
      let mutind_body = Environ.lookup_mind mutind env in
      let oneind_body = mutind_body.Declarations.mind_packets.(i) in
      let consname = Id.to_string oneind_body.Declarations.mind_consnames.(j-1) in
      c_id ("case_" ^ consname ^ "_" ^ (mangle_type t))

let case_cstrfield (env : Environ.env) (sigma : Evd.evar_map) (t : EConstr.types) (j : int) (k : int) : string =
  match ConstrMap.find_opt (EConstr.to_constr sigma t) !ind_config_map with
  | Some ind_cfg ->
      (match ind_cfg.c_swfunc with
      | Some _ -> ind_cfg.cstr_configs.(j-1).c_accessors.(k)
      | None -> raise (CodeGenError "inductive match configuration not registered")) (* should be called after case_swfunc *)
  | None ->
      let indty =
        match EConstr.kind sigma t with
        | Constr.App (f, argsary) -> f
        | _ -> t
      in
      let (mutind, i) = out_punivs (EConstr.destInd sigma indty) in
      let mutind_body = Environ.lookup_mind mutind env in
      let oneind_body = mutind_body.Declarations.mind_packets.(i) in
      let consname = Id.to_string oneind_body.Declarations.mind_consnames.(j-1) in
      c_id ("field" ^ string_of_int k ^ "_" ^ consname ^ "_" ^ (mangle_type t))

let gensym () : string =
  let n = !gensym_id in
  gensym_id := n + 1;
  "g" ^ string_of_int n

let gensym_with_str (suffix : string) : string =
  gensym () ^ "_" ^ (c_id suffix)

let gensym_with_name (name : Name.t) : string =
  match name with
  | Names.Name.Anonymous -> gensym ()
  | Names.Name.Name id -> gensym () ^ "_" ^ (c_id (Id.to_string id))

let gensym_with_nameopt (nameopt : Name.t option) : string =
  match nameopt with
  | None -> gensym ()
  | Some name -> gensym_with_name name

let local_gensym_id : (int ref) list ref = ref []

let  local_gensym_with (f : unit -> 'a) : 'a =
  local_gensym_id := (ref 0) :: !local_gensym_id;
  let ret = f () in
  local_gensym_id := List.tl !local_gensym_id;
  ret

let local_gensym () : string =
  let idref = List.hd !local_gensym_id in
  let n = !idref in
  idref := n + 1;
  "v" ^ string_of_int n

let local_gensym_with_str (suffix : string) : string =
  local_gensym () ^ "_" ^ (c_id suffix)

let local_gensym_with_name (name : Name.t) : string =
  match name with
  | Name.Anonymous -> local_gensym ()
  | Name.Name id -> local_gensym () ^ "_" ^ (c_id (Id.to_string id))

let local_gensym_with_nameopt (nameopt : Name.t option) : string =
  match nameopt with
  | None -> local_gensym ()
  | Some name -> local_gensym_with_name name

let rec argtys_and_rety_of_type (sigma : Evd.evar_map) (ty : EConstr.types) : EConstr.types list * EConstr.types =
  match EConstr.kind sigma ty with
  | Prod (name, ty', body) ->
      let (argtys, rety) = argtys_and_rety_of_type sigma body in
      (ty :: argtys, rety)
  | _ -> ([], ty)

let rec nargtys_and_rety_of_type (sigma : Evd.evar_map) (n : int) (ty : EConstr.types) : EConstr.types list * EConstr.types =
  if n == 0 then
    ([], ty)
  else
    match EConstr.kind sigma ty with
    | Prod (name, ty', body) ->
        let (argtys, rety) = nargtys_and_rety_of_type sigma (n-1) body in
        (ty :: argtys, rety)
    | _ -> user_err (Pp.str "too few prods in type")

type context_elt =
  | CtxVar of string
  | CtxRec of
      string *
      (string * EConstr.types) array (* fname, argname_argtype_array *)

let rec fargs_and_body (env : Environ.env) (sigma : Evd.evar_map) (term : EConstr.t) : (string * EConstr.types) list * Environ.env * EConstr.t =
  match EConstr.kind sigma term with
  | Constr.Lambda (name, ty, body) ->
      let decl = Context.Rel.Declaration.LocalAssum (name, ty) in
      let env2 = EConstr.push_rel decl env in
      let var = local_gensym_with_name (Context.binder_name name) in
      let fargs1, env1, body1 = fargs_and_body env2 sigma body in
      let fargs2 = (var, ty) :: fargs1 in
      (fargs2, env1, body1)
  | _ -> ([], env, term)

let fargs_and_body_ary (env : Environ.env) (sigma : Evd.evar_map)
    (strnameary : string array) (ty : EConstr.types)
    (ia : int array) (i : int)
    (nameary : Name.t array)
    (tyary : EConstr.types array)
    (funary : EConstr.t array) :
    (string *
     EConstr.types *
     (string * EConstr.types) list *
     context_elt list *
     Environ.env *
     EConstr.t) array =
  let fb_ary = Array.map (fun term1 -> fargs_and_body env sigma term1) funary in
  let ctxrec_ary = Array.map
    (fun j ->
      let nm = strnameary.(j) in
      let fargs, envb, _(* _ was previously named body but was not used *) =
        fb_ary.(j) in
      CtxRec (nm, Array.of_list fargs))
    (iota_ary 0 (Array.length funary))
  in
  let ctxrec_list = Array.to_list ctxrec_ary in
  let fb_ary2 = array_map2
    (fun ty (fargs, envb, body) ->
      let context1 = List.rev_map (fun (var, ty) -> CtxVar var) fargs in
      let context2 = List.append context1 (List.rev ctxrec_list) in
      (ty, fargs, context2, envb, body))
    tyary fb_ary
  in
  array_map2 (fun nm (ty, fargs, context, envb, body) ->
      (nm, ty, fargs, context, envb, body))
    strnameary fb_ary2

let genc_farg (sigma : Evd.evar_map) (farg : string * EConstr.types) : Pp.t =
  let (var, ty) = farg in
  hv 2 (str (c_typename sigma ty) ++ spc () ++ str var)

let genc_fargs (sigma : Evd.evar_map) (fargs : (string * EConstr.types) list) : Pp.t =
  match fargs with
  | [] -> str "void"
  | farg1 :: rest ->
      List.fold_left
        (fun pp farg -> pp ++ str "," ++ spc () ++ genc_farg sigma farg)
        (genc_farg sigma farg1)
        rest

let genc_vardecl (sigma : Evd.evar_map) (ty : EConstr.types) (varname : string) : Pp.t =
  hv 0 (str (c_typename sigma ty) ++ spc () ++ str varname ++ str ";")

let genc_varinit (sigma : Evd.evar_map) (ty : EConstr.types) (varname : string) (init : Pp.t) : Pp.t =
  hv 0 (str (c_typename sigma ty) ++ spc () ++ str varname ++ spc () ++ str "=" ++ spc () ++ init ++ str ";")

let genc_assign (lhs : Pp.t) (rhs : Pp.t) : Pp.t =
  hv 0 (lhs ++ spc () ++ str "=" ++ spc () ++ rhs ++ str ";")

let genc_return (arg : Pp.t) : Pp.t =
  hv 0 (str "return" ++ spc () ++ arg ++ str ";")

let genc_void_return (retvar : string) (arg : Pp.t) : Pp.t =
  hv 0 (genc_assign (str retvar) arg ++ spc () ++ str "return;")

let varname_of_rel (context : context_elt list) (i : int) : string =
  match List.nth context (i-1) with
  | CtxVar varname -> varname
  | _ -> raise (Invalid_argument "unexpected context element")

let genc_app (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (f : EConstr.t) (argsary : EConstr.t array) : Pp.t =
  match EConstr.kind sigma f with
  | Constr.Rel i ->
      (match List.nth context (i-1) with
      | CtxVar _ -> user_err (str "indirect call not implemented")
      | CtxRec (fname, _) ->
          let argvars = Array.map (fun arg -> varname_of_rel context (destRel sigma arg)) argsary in
          let c_fname = c_funcname fname in
          str c_fname ++ str "(" ++
          pp_join_ary (str "," ++ spc ()) (Array.map (fun av -> str av) argvars) ++
          str ")")
  | Constr.Const ctntu ->
      let fname = Label.to_string (KerName.label (Constant.canonical (out_punivs ctntu))) in
      let c_fname = c_funcname fname in
      let argvars = Array.map (fun arg -> varname_of_rel context (destRel sigma arg)) argsary in
      str c_fname ++ str "(" ++
      pp_join_ary (str "," ++ spc ()) (Array.map (fun av -> str av) argvars) ++
      str ")"
  | Constr.Construct cstru ->
      let ty = Reductionops.nf_all env sigma (Retyping.get_type_of env sigma (mkApp (f, argsary))) in
      (*Feedback.msg_info (Printer.pr_constr_env env sigma ty);*)
      let fname_argn = c_cstrname env sigma ty (out_punivs cstru) in
      let argvars = Array.map (fun arg -> varname_of_rel context (destRel sigma arg)) argsary in
      if Array.length argvars = 0 then
        str fname_argn
      else
        str fname_argn ++ str "(" ++
        pp_join_ary (str "," ++ spc ()) (Array.map (fun av -> str av) argvars) ++
        str ")"
  | _ -> assert false

let genc_multi_assign (sigma : Evd.evar_map) (assignments : (string * (string * EConstr.types)) array) : Pp.t =
  let ass = Array.to_list assignments in
  let ass = List.filter (fun (lhs, (rhs, ty)) -> lhs <> rhs) ass in
  let rpp = ref (mt ()) in
  (* better algorithm using topological sort? *)
  let rec loop ass =
    match ass with
    | [] -> ()
    | a :: rest ->
        let rhs_list = List.map (fun (lhs, (rhs, ty)) -> rhs) ass in
        let blocked_ass, nonblocked_ass =
          List.partition (fun (lhs, (rhs, ty)) -> List.mem lhs rhs_list) ass
        in
        if nonblocked_ass <> [] then
          (List.iter
            (fun (lhs, (rhs, ty)) ->
              let pp = genc_assign (str lhs) (str rhs) in
              if Pp.ismt !rpp then rpp := pp else rpp := !rpp ++ spc () ++ pp)
            nonblocked_ass;
          loop blocked_ass)
        else
          (let a_lhs, (a_rhs, a_ty) = a in
          let tmp = local_gensym () in
          let pp = genc_varinit sigma a_ty tmp (str a_lhs) in
          (if Pp.ismt !rpp then rpp := pp else rpp := !rpp ++ spc () ++ pp);
          let ass2 = List.map
            (fun (lhs, (rhs, ty)) ->
              if rhs = a_lhs then (lhs, (tmp, ty)) else (lhs, (rhs, ty)))
            ass
          in
          loop ass2)
  in
  loop ass;
  !rpp

let genc_goto (sigma : Evd.evar_map) (context : context_elt list) (ctxrec : string * (string * EConstr.types) array) (argsary : EConstr.t array) : Pp.t =
  let fname, argvars = ctxrec in
  (if Array.length argsary <> Array.length argvars then
    user_err (str "partial function invocation not supported yet");
  let fname_argn = goto_label fname in
  let assignments =
    (array_map2
      (fun (var, ty) arg -> (var, (varname_of_rel context (destRel sigma arg), ty)))
      argvars argsary)
  in
  let pp_assigns = genc_multi_assign sigma assignments in
  let pp_goto = (hv 0 (str "goto" ++ spc () ++ str fname_argn ++ str ";")) in
  if Pp.ismt pp_assigns then pp_goto else pp_assigns ++ spc () ++ pp_goto)

let genc_const (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (ctnt : Constant.t) : Pp.t =
  genc_app env sigma context (mkConst ctnt) [| |]

let genc_construct (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (cstr : Names.constructor) : Pp.t =
  genc_app env sigma context (mkConstruct cstr) [| |]

let split_case_tyf (sigma : Evd.evar_map) (tyf : EConstr.t) : EConstr.types * EConstr.t =
  match EConstr.kind sigma tyf with
  | Constr.Lambda (name, ty, body) -> (ty, body)
  | _ -> user_err (str "unexpected case type function")

let rec strip_outer_lambdas (sigma : Evd.evar_map) (ndecls : int) (term : EConstr.t) : (Name.t Context.binder_annot * EConstr.types) list * EConstr.t =
  if ndecls = 0 then
    ([], term)
  else
    match EConstr.kind sigma term with
    | Constr.Lambda (name, ty, body) ->
        let (decls, innermostbody) = strip_outer_lambdas sigma (ndecls-1) body in
        ((name, ty) :: decls, innermostbody)
    | _ -> user_err (str "case body lambda nesting is not enough")

let genc_case_branch_body (env : Environ.env) (sigma : Evd.evar_map)
    (context : context_elt list)
    (bodyfunc : Environ.env -> Evd.evar_map -> context_elt list -> EConstr.constr -> Pp.t)
    (exprty : EConstr.types) (exprvar : string) (ndecls : int)
    (br : EConstr.t) (cstr_index : int) : Pp.t =
  let (decls, body) = strip_outer_lambdas sigma ndecls br in
  let decls2 =
    List.map2
      (fun (name, ty) field_index ->
        let name = Context.binder_name name in
        let varname = local_gensym_with_name name in
        let cstr_field = case_cstrfield env sigma exprty cstr_index field_index in
        (CtxVar varname, genc_varinit sigma ty varname (str cstr_field ++ str "(" ++ str exprvar ++ str ")")))
       decls
      (iota_list 0 (List.length decls))
  in
  let context2 = List.rev_append (List.map fst decls2) context in
  let decls3 = List.map snd decls2 in
  pp_postjoin_list (spc ()) decls3 ++ bodyfunc env sigma context2 body

let genc_case_branch (env : Environ.env) (sigma : Evd.evar_map)
    (context : context_elt list)
    (bodyfunc : Environ.env -> Evd.evar_map -> context_elt list -> EConstr.constr -> Pp.t)
    (exprty : EConstr.types) (exprvar : string) (ndecls : int)
    (br : EConstr.t) (cstr_index : int) : Pp.t =
  let cstr_label = case_cstrlabel env sigma exprty cstr_index in
  let pp_label = str cstr_label ++ str ":" in
  hv 0 (hv 0 (pp_label ++ spc () ++ str "{") ++ brk (1,2) ++
    hv 0 (genc_case_branch_body env sigma context bodyfunc exprty exprvar ndecls br cstr_index) ++ spc () ++
    str "}")

let genc_case_nobreak (env : Environ.env) (sigma : Evd.evar_map)
    (context : context_elt list) (ci : Constr.case_info) (tyf : EConstr.t)
    (expr : EConstr.t) (brs : EConstr.t array)
    (bodyfunc : Environ.env -> Evd.evar_map -> context_elt list -> EConstr.constr -> Pp.t) : Pp.t =
  let (exprty, rety) = split_case_tyf sigma tyf in
  let exprvar = varname_of_rel context (destRel sigma expr) in
  if Array.length brs = 1 then
    let ndecls = ci.Constr.ci_cstr_ndecls.(0) in
    let br = brs.(0) in
    let cstr_index = 1 in
    genc_case_branch_body env sigma context bodyfunc exprty exprvar ndecls br cstr_index
  else
    let swfunc = case_swfunc env sigma exprty in
    let swexpr = if swfunc = "" then str exprvar else str swfunc ++ str "(" ++ str exprvar ++ str ")" in
    hv 0 (
    hv 0 (str "switch" ++ spc () ++ str "(" ++ swexpr ++ str ")") ++ spc () ++
    str "{" ++ brk (1,2) ++
    hv 0 (
    pp_join_ary (spc ())
      (array_map3
        (genc_case_branch env sigma context bodyfunc exprty exprvar)
        ci.Constr.ci_cstr_ndecls
        brs
        (iota_ary 1 (Array.length brs)))) ++
    spc () ++ str "}")

let genc_case_break (env : Environ.env) (sigma : Evd.evar_map)
    (context : context_elt list) (ci : Constr.case_info) (tyf : EConstr.t)
    (expr : EConstr.t) (brs : EConstr.t array)
    (bodyfunc : Environ.env -> Evd.evar_map -> context_elt list -> EConstr.constr -> Pp.t) : Pp.t =
  genc_case_nobreak env sigma context ci tyf expr brs
    (fun envb sigma context2 body -> bodyfunc envb sigma context2 body ++ spc () ++ str "break;")

let genc_geninitvar (sigma : Evd.evar_map) (ty : EConstr.types) (namehint : Names.Name.t) (init : Pp.t) : Pp.t * string =
  let varname = local_gensym_with_name namehint in
  (genc_varinit sigma ty varname init, varname)

(* not tail position. return a variable *)
let rec genc_body_var (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (namehint : Names.Name.t) (term : EConstr.t) (termty : EConstr.types) : Pp.t * string =
  match EConstr.kind sigma term with
  | Constr.Rel i ->
      (mt (), varname_of_rel context i)
  | Constr.LetIn (name, expr, exprty, body) ->
      let decl = Context.Rel.Declaration.LocalDef (name, expr, exprty) in
      let name = Context.binder_name name in
      let env2 = EConstr.push_rel decl env in
      let (exprbody, exprvarname) = genc_body_var env sigma context name expr exprty in
      let (bodybody, bodyvarname) = genc_body_var env2 sigma (CtxVar exprvarname :: context) namehint body termty in
      (exprbody ++ (if ismt exprbody then mt () else spc ()) ++ bodybody, bodyvarname)
  | Constr.App (f, argsary) ->
      genc_geninitvar sigma termty namehint (genc_app env sigma context f argsary)
  | Constr.Case (ci, tyf, expr, brs) ->
      let varname = local_gensym_with_name namehint in
      (genc_vardecl sigma termty varname ++ spc () ++
       genc_case_break env sigma context ci tyf expr brs
        (fun envb sigma context2 body -> genc_body_assign envb sigma context2 varname body),
      varname)
  | Constr.Const ctntu ->
      genc_geninitvar sigma termty namehint (genc_const env sigma context (out_punivs ctntu))
  | Constr.Construct cstru ->
      genc_geninitvar sigma termty namehint (genc_construct env sigma context (out_punivs cstru))
  | _ -> (user_err (str "not impelemented (genc_body_var:" ++ str (constr_name sigma term) ++ str "): " ++ Printer.pr_econstr_env env sigma term))

(* not tail position. assign to the specified variable *)
and genc_body_assign (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (retvar : string) (term : EConstr.t) : Pp.t =
  match EConstr.kind sigma term with
  | Constr.Rel i ->
      genc_assign (str retvar) (str (varname_of_rel context i))
  | Constr.LetIn (name, expr, exprty, body) ->
      let decl = Context.Rel.Declaration.LocalDef (name, expr, exprty) in
      let name = Context.binder_name name in
      let env2 = EConstr.push_rel decl env in
      let (exprbody, varname) = genc_body_var env sigma context name expr exprty in
      exprbody ++
      (if ismt exprbody then mt () else spc ()) ++
      genc_body_assign env2 sigma (CtxVar varname :: context) retvar body
  | Constr.App (f, argsary) ->
      genc_assign (str retvar) (genc_app env sigma context f argsary)
  | Constr.Case (ci, tyf, expr, brs) ->
      genc_case_break env sigma context ci tyf expr brs
        (fun envb sigma context2 body -> genc_body_assign envb sigma context2 retvar body)
  | Constr.Const ctntu ->
      genc_assign (str retvar) (genc_const env sigma context (out_punivs ctntu))
  | Constr.Construct cstru ->
      genc_assign (str retvar) (genc_construct env sigma context (out_punivs cstru))
  | _ -> (user_err (str "not impelemented (genc_body_assign:" ++ str (constr_name sigma term) ++ str "): " ++ Printer.pr_econstr_env env sigma term))

(* tail position.  usual return. *)
let rec genc_body_tail (env : Environ.env) (sigma : Evd.evar_map) (context : context_elt list) (term : EConstr.t) : Pp.t =
  match EConstr.kind sigma term with
  | Constr.Rel i ->
      genc_return (str (varname_of_rel context i))
  | Constr.LetIn (name, expr, exprty, body) ->
      let decl = Context.Rel.Declaration.LocalDef (name, expr, exprty) in
      let name = Context.binder_name name in
      let env2 = EConstr.push_rel decl env in
      let (exprbody, varname) = genc_body_var env sigma context name expr exprty in
      exprbody ++
      (if ismt exprbody then mt () else spc ()) ++
      genc_body_tail env2 sigma (CtxVar varname :: context) body
  | Constr.App (f, argsary) ->
      (match EConstr.kind sigma f with
      | Constr.Rel i ->
          (match List.nth context (i-1) with
          | CtxRec (fname, argvars) -> genc_goto sigma context (fname, argvars) argsary
          | _ -> genc_return (genc_app env sigma context f argsary))
      | _ -> genc_return (genc_app env sigma context f argsary))
  | Constr.Case (ci, tyf, expr, brs) ->
      genc_case_nobreak env sigma context ci tyf expr brs genc_body_tail
  | Constr.Const ctntu ->
      genc_return (genc_const env sigma context (out_punivs ctntu))
  | Constr.Construct cstru ->
      genc_return (genc_construct env sigma context (out_punivs cstru))
  | _ -> (user_err (str "not impelemented (genc_body_tail:" ++ str (constr_name sigma term) ++ str "): " ++ Printer.pr_econstr_env env sigma term))

(* tail position.  assign and return. *)
let rec genc_mufun_body_tail (env : Environ.env) (sigma : Evd.evar_map) (retvar : string) (context : context_elt list) (term : EConstr.t) : Pp.t =
  match EConstr.kind sigma term with
  | Constr.Rel i ->
      genc_void_return retvar (str (varname_of_rel context i))
  | Constr.LetIn (name, expr, exprty, body) ->
      let decl = Context.Rel.Declaration.LocalDef (name, expr, exprty) in
      let name = Context.binder_name name in
      let env2 = EConstr.push_rel decl env in
      let (exprbody, varname) = genc_body_var env sigma context name expr exprty in
      exprbody ++
      (if ismt exprbody then mt () else spc ()) ++
      genc_mufun_body_tail env2 sigma retvar (CtxVar varname :: context) body
  | Constr.App (f, argsary) ->
      (match EConstr.kind sigma f with
      | Constr.Rel i ->
          (match List.nth context (i-1) with
          | CtxRec (fname, argvars) -> genc_goto sigma context (fname, argvars) argsary
          | _ -> genc_void_return retvar (genc_app env sigma context f argsary))
      | _ -> genc_void_return retvar (genc_app env sigma context f argsary))
  | Constr.Case (ci, tyf, expr, brs) ->
      genc_case_nobreak env sigma context ci tyf expr brs
        (fun envb sigma -> genc_mufun_body_tail envb sigma retvar)
  | Constr.Const ctntu ->
      genc_void_return retvar (genc_const env sigma context (out_punivs ctntu))
  | Constr.Construct cstru ->
      genc_void_return retvar (genc_construct env sigma context (out_punivs cstru))
  | _ -> (user_err (str "not impelemented (genc_mufun_body_tail:" ++ str (constr_name sigma term) ++ str "): " ++ Printer.pr_econstr_env env sigma term))

let found_funref (context : (int * bool ref * bool ref * bool ref) option list) (i : int) =
  match List.nth context (i-1) with
  | None -> ()
  | Some callsites ->
      let nargs, headcall, tailcall, partcall = callsites in
      partcall := true

let found_callsite (tail : bool) (context : (int * bool ref * bool ref * bool ref) option list) (i : int) (n : int) : unit =
  match List.nth context (i-1) with
  | None -> ()
  | Some callsites ->
      let nargs, headcall, tailcall, partcall = callsites in
      if nargs <= n then
        if tail then
          tailcall := true
        else
          headcall := true
      else
        partcall := true

let rec scan_callsites_rec (env : Environ.env) (sigma : Evd.evar_map) (tail : bool) (context : (int * bool ref * bool ref * bool ref) option list) (term : EConstr.t) : unit =
  match EConstr.kind sigma term with
  | Constr.Const ctntu -> ()
  | Constr.Construct cstru -> ()
  | Constr.Rel i ->
      found_funref context i
  | Constr.Cast (expr, kind, ty) ->
      scan_callsites_rec env sigma false context expr
  | Constr.LetIn (name, expr, ty, body) ->
      let decl = Context.Rel.Declaration.LocalDef (name, expr, ty) in
      let env2 = EConstr.push_rel decl env in
      (scan_callsites_rec env sigma false context expr;
      scan_callsites_rec env2 sigma tail (None :: context) body)
  | Constr.App (f, argsary) ->
      ((match EConstr.kind sigma f with
      | Constr.Rel i -> found_callsite tail context i (Array.length argsary)
      | _ -> scan_callsites_rec env sigma false context f);
      Array.iter (scan_callsites_rec env sigma false context) argsary)
  | Constr.Case (ci, tyf, expr, brs) ->
      (scan_callsites_rec env sigma false context expr;
      array_iter2
        (fun nargs br ->
          let context2 = ncons nargs None context in
          let (decls, br2) = strip_outer_lambdas sigma nargs br in
          let env2 = EConstr.push_rel_context
            (List.map
              (fun (name, ty) -> Context.Rel.Declaration.LocalAssum (name, ty))
              (List.rev decls))
            env in
          scan_callsites_rec env2 sigma tail context2 br2)
        ci.Constr.ci_cstr_nargs brs)
  | Constr.Proj (proj, expr) ->
      scan_callsites_rec env sigma false context expr
  | _ -> user_err ~hdr:"scan_callsites_rec" (hv 0 (str "unexpected term:" ++ spc () ++ Printer.pr_econstr_env env sigma term))

let scan_callsites (sigma : Evd.evar_map) (i : int)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array) :
    (bool * bool * bool) array =
  let context = Array.to_list (array_rev (Array.mapi
    (fun j (nm, ty, fargs, ctx, envb, body) ->
      Some (List.length fargs, ref (j = i), ref false, ref false))
    ntfcb_ary))
  in
  Array.iter
    (fun (nm, ty, fargs, ctx, envb, body) ->
      scan_callsites_rec envb sigma true (ncons (List.length fargs) None context) body)
    ntfcb_ary;
  Array.map
    (fun callsites_opt ->
      match callsites_opt with
      | Some (nargs, headcall, tailcall, partcall) -> (!headcall, !tailcall, !partcall)
      | None -> assert false)
    (array_rev (Array.of_list context))

let genc_func_single (env : Environ.env) (sigma : Evd.evar_map)
    (fname : string) (ty : EConstr.types)
    (fargs : (string * EConstr.types) list)
    (context : context_elt list) (body : EConstr.t) : Pp.t =
  (*let (ty, fargs, context, body) = fargs_and_body fname term in*)
  let (argtys, rety) = argtys_and_rety_of_type sigma ty in
  (if List.length argtys <> List.length fargs then
    user_err (str ("function value not supported yet: " ^
      string_of_int (List.length argtys) ^ " prods and " ^
      string_of_int (List.length fargs) ^ " lambdas")));
  let c_fname = c_funcname fname in
  hv 0 (
  str "static" ++ spc () ++
  str (c_typename sigma rety) ++ spc () ++
  str c_fname ++ str "(" ++
  hv 0 (genc_fargs sigma fargs) ++
  str ")" ++ spc () ++
  str "{" ++ brk (1,2) ++
  hv 0 (
    genc_body_tail env sigma context body) ++
  spc () ++ str "}")

let find_headcalls
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) :
    (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array =
  Array.concat
    (Array.to_list
      (array_map2
        (fun ntfcb (headcall, tailcall, partcall) ->
          if headcall then [| ntfcb |] else [| |])
        ntfcb_ary callsites_ary))

let genc_mufun_struct_one (sigma : Evd.evar_map) (ntfcb : string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) : Pp.t =
  let nm, ty, fargs, context, envb, body = ntfcb in
  hv 0 (
  str "struct" ++ spc () ++
  str nm ++ spc () ++
  str "{" ++ spc () ++
  pp_postjoin_list (str ";" ++ spc ()) (List.map (genc_farg sigma) fargs) ++
  str "};")

let genc_mufun_structs (sigma : Evd.evar_map)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) : Pp.t =
  let ntfcb_ary2 = find_headcalls ntfcb_ary callsites_ary in
  pp_join_ary (spc ())
    (Array.map (genc_mufun_struct_one sigma) ntfcb_ary2)

let genc_mufun_entry (sigma : Evd.evar_map) (mfnm : string) (i : int) (ntfcb : string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) : Pp.t =
  let nm, ty, fargs, context, envb, body = ntfcb in
  let (argtys, rety) = nargtys_and_rety_of_type sigma (List.length fargs) ty in
  let c_fname = c_funcname nm in
  hv 0 (
  str "static" ++ spc () ++
  str (c_typename sigma rety) ++ spc () ++
  str c_fname ++ str "(" ++
  hv 0 (genc_fargs sigma fargs) ++
  str ")" ++ spc () ++
  str "{" ++ brk (1,2) ++
  hv 0 (
    hv 0 (str "struct" ++ spc () ++ str nm ++ spc () ++ str "args" ++ spc () ++
      str "=" ++ spc () ++ str "{" ++ spc () ++
      pp_join_list (str "," ++ spc ())
        (List.map
          (fun (var, ty) -> hv 0 (str var))
        fargs) ++ spc () ++ str "};") ++ spc () ++
    hv 0 (str (c_typename sigma rety) ++ spc () ++ str "ret;") ++ spc () ++
    hv 0 (str mfnm ++ str "(" ++ int i ++ str "," ++ spc () ++ str "&args," ++ spc () ++ str "&ret);") ++ spc () ++
    hv 0 (str "return" ++ spc () ++ str "ret;")) ++
  spc () ++ str "}")

let genc_mufun_entries (sigma : Evd.evar_map) (mfnm : string)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) : Pp.t =
  let ntfcb_ary2 = find_headcalls ntfcb_ary callsites_ary in
  pp_join_ary (spc ())
    (Array.mapi (genc_mufun_entry sigma mfnm) ntfcb_ary2)

let genc_mufun_forward_decl (mfnm : string) : Pp.t =
  hv 0 (
  str "static" ++ spc () ++
  str "void" ++ spc () ++
  str mfnm ++ str "(" ++
  hv 0 (
    hv 0 (str "int" ++ spc () ++ str "i") ++ str "," ++ spc () ++
    hv 0 (str "void*" ++ spc () ++ str "argsp") ++ str "," ++ spc () ++
    hv 0 (str "void*" ++ spc () ++ str "retp")) ++ str ");")

let genc_mufun_bodies_func (sigma :Evd.evar_map) (mfnm : string) (i : int)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) : Pp.t =
  hv 0 (
  str "static" ++ spc () ++
  str "void" ++ spc () ++
  str mfnm ++ str "(" ++
  hv 0 (
    hv 0 (str "int" ++ spc () ++ str "i") ++ str "," ++ spc () ++
    hv 0 (str "void*" ++ spc () ++ str "argsp") ++ str "," ++ spc () ++
    hv 0 (str "void*" ++ spc () ++ str "retp")) ++ str ")" ++ spc () ++
  str "{" ++ brk (1,2) ++
  hv 0 (
    pp_join_ary (spc ())
      (Array.map
        (fun (nm, ty, fargs, context, envb, body) ->
           pp_join_list (spc ())
             (List.map
               (fun (var, ty) -> hv 0 (str (c_typename sigma ty) ++ spc () ++ str var ++ str ";"))
               fargs))
        ntfcb_ary) ++ spc () ++
    hv 0 (str "switch" ++ spc () ++ str "(i)") ++ spc () ++ str "{" ++ brk (1,2) ++
      hv 0 (
        pp_join_ary (spc ())
          (Array.mapi
            (fun j (nm, ty, fargs, context, envb, body) ->
              let headcall, tailcall, partcall = callsites_ary.(j) in
              let (argtys, rety) = nargtys_and_rety_of_type sigma (List.length fargs) ty in
              let fname_argn = goto_label nm in
              hv 0 (
                (if j == i then str "default:" else hv 0 (str "case" ++ spc () ++ int j ++ str ":")) ++ brk (1,2) ++
                hv 0 (
                  pp_join_list (spc ())
                    (List.map
                      (fun (var, ty) -> hv 0 (str var ++ spc () ++ str "=" ++ spc () ++ str "((struct" ++ spc () ++ str nm ++ spc () ++ str "*)argsp)->" ++ str var ++ str ";"))
                      fargs) ++ spc () ++
                  (if tailcall then str fname_argn ++ str ":;" ++ spc () else mt ()) ++
                  genc_mufun_body_tail envb sigma ("(*(" ^ c_typename sigma rety ^ " *)retp)") context body ++ spc () ++
                  str "return;")))
            ntfcb_ary)) ++ spc () ++ str "}") ++ spc () ++
    str "}")

let genc_mufun_single_func (sigma : Evd.evar_map) (mfnm : string) (i : int)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) : Pp.t =
  let entry_nm, entry_ty, entry_fargs, entry_context, entry_envb, entry_body = ntfcb_ary.(i) in
  let (entry_argtys, entry_rety) = nargtys_and_rety_of_type sigma (List.length entry_fargs) entry_ty in
  let c_fname = c_funcname entry_nm in
  let label_fname_argn = goto_label entry_nm in
  hv 0 (
  str "static" ++ spc () ++
  str (c_typename sigma entry_rety) ++ spc () ++
  str c_fname ++ str "(" ++
  hv 0 (genc_fargs sigma entry_fargs) ++
  str ")" ++ spc () ++
  str "{" ++ brk (1,2) ++
  hv 0 (
    pp_postjoin_ary (spc ())
      (Array.mapi
        (fun j (nm, ty, fargs, context, envb, body) ->
          if j = i then
            mt ()
          else
            pp_join_list (spc ())
              (List.map
                (fun (var, ty) -> hv 0 (str (c_typename sigma ty) ++ spc () ++ str var ++ str ";"))
                fargs))
        ntfcb_ary) ++
    (if i = 0 then mt () else hv 0 (str "goto" ++ spc () ++ str label_fname_argn ++ str ";") ++ spc ()) ++
    pp_join_ary (spc ())
      (Array.mapi
        (fun j (nm, ty, fargs, context, envb, body) ->
          let headcall, tailcall, partcall = callsites_ary.(j) in
          let fname_argn = goto_label nm in
          hv 0 (
            (if tailcall || (i <> 0 && i == j) then str fname_argn ++ str ":;" ++ spc () else mt ()) ++
            genc_body_tail envb sigma context body))
        ntfcb_ary)) ++
  spc () ++ str "}")

let genc_func_mutual (sigma : Evd.evar_map) (mfnm : string) (i : int)
    (ntfcb_ary : (string * EConstr.types * (string * EConstr.types) list * context_elt list * Environ.env * EConstr.t) array)
    (callsites_ary : (bool * bool * bool) array) : Pp.t =
  let num_entry_funcs = Array.fold_left (+) 0 (Array.map (fun (headcall, tailcall, partcall) -> if headcall then 1 else 0) callsites_ary) in
  if num_entry_funcs = 1 then
    genc_mufun_single_func sigma mfnm i ntfcb_ary callsites_ary
  else
    genc_mufun_structs sigma ntfcb_ary callsites_ary ++ spc () ++
    genc_mufun_forward_decl mfnm ++ spc () ++
    genc_mufun_entries sigma mfnm ntfcb_ary callsites_ary ++ spc () ++
    genc_mufun_bodies_func sigma mfnm i ntfcb_ary callsites_ary

let genc_func (env : Environ.env) (sigma : Evd.evar_map) (fname : string) (ty : EConstr.types) (term : EConstr.t) : Pp.t =
  local_gensym_with (fun () ->
  match EConstr.kind sigma term with
  | Constr.Fix ((ia, i), ((nameary, tyary, funary) as prec)) ->
      let env2 = push_rec_types prec env in
      let nameary' = Array.map Context.binder_name nameary in
      let strnameary = Array.mapi (fun j nm ->
          if j = i then
            fname
          else
            let nm = Context.binder_name nm in
            gensym_with_name nm)
        nameary
      in
      let ntfcb_ary = fargs_and_body_ary env2 sigma strnameary ty ia i nameary' tyary funary in
      let callsites_ary = scan_callsites sigma i ntfcb_ary in
      let mfnm = gensym_with_str fname in
      genc_func_mutual sigma mfnm i ntfcb_ary callsites_ary
  | _ ->
      let fargs, envb, body = fargs_and_body env sigma term in
      let context = List.rev_map (fun (var, ty) -> CtxVar var) fargs in
      genc_func_single envb sigma fname ty fargs context body)

let get_ctnt_type_body (env : Environ.env) (name : Libnames.qualid) : Constant.t * Constr.types * Constr.t =
  let reference = Smartlocate.global_with_alias name in
  match reference with
  | ConstRef ctnt ->
      begin match Global.body_of_constant ctnt with
      | Some (b,_) ->
          let (ty, _) = Typeops.type_of_global_in_context env reference in
          (ctnt, ty, b)
      | None -> user_err (Pp.str "can't genc axiom")
      end
  | VarRef _ -> user_err (Pp.str "can't genc VarRef")
  | IndRef _ -> user_err (Pp.str "can't genc IndRef")
  | ConstructRef _ -> user_err (Pp.str "can't genc ConstructRef")

let get_ctnt_type_body_from_cfunc (cfunc_name : string) : Constant.t * Constr.types * Constr.t =
  let (sp_cfg, sp_inst) =
    match CString.Map.find_opt cfunc_name !cfunc_instance_map with
    | None ->
        user_err (Pp.str "C function name not found:" ++
                  Pp.spc () ++ Pp.str cfunc_name)
    | Some (sp_cfg, sp_inst) -> (sp_cfg, sp_inst)
  in
  let ctnt =
    match sp_inst.sp_specialization_name with
    | SpExpectedId id ->
        codegen_specialization_specialize1 cfunc_name (* modify global env *)
    | SpDefinedCtnt ctnt -> ctnt
  in
  let env = Global.env () in
  let (ctnt, ty, body) =
    let cdef = Environ.lookup_constant ctnt env in
    let ty = cdef.Declarations.const_type in
    match Global.body_of_constant_body cdef with
    | None -> user_err (Pp.str "couldn't obtain the body:" ++ Pp.spc () ++
                        Printer.pr_constant env ctnt)
    | Some (body, _) -> (ctnt, ty, body)
  in
  (ctnt, ty, body)

let gen (cfunc_list : string list) : unit =
  List.iter
    (fun cfunc_name ->
      let (ctnt, ty, body) = get_ctnt_type_body_from_cfunc cfunc_name in
      let env = Global.env () in
      let sigma = Evd.from_env env in
      linear_type_check_term body;
      let ty = EConstr.of_constr ty in
      let body = EConstr.of_constr body in
      let pp = genc_func env sigma cfunc_name ty body in
      Feedback.msg_info pp)
    cfunc_list

let gen_file (fn : string) (cfunc_list : string list) : unit =
  (let ch = open_out fn in
  let fmt = Format.formatter_of_out_channel ch in
  List.iter
    (fun cfunc_name ->
      let (ctnt, ty, body) = get_ctnt_type_body_from_cfunc cfunc_name in
      let env = Global.env () in
      let sigma = Evd.from_env env in
      linear_type_check_term body;
      let ty = EConstr.of_constr ty in
      let body = EConstr.of_constr body in
      let pp = genc_func env sigma cfunc_name ty body in
      Pp.pp_with fmt (pp ++ Pp.fnl ()))
    cfunc_list;
  Format.pp_print_flush fmt ();
  close_out ch;
  Feedback.msg_info (str ("file generated: " ^ fn)))

let gen_endfile (fn : string) =
  gen_file fn !generation_list;
  generation_list := []

let genc (libref_list : Libnames.qualid list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  List.iter
    (fun libref ->
      let (ctnt, ty, body) = get_ctnt_type_body env libref in
      linear_type_check_term body;
      let fname = Label.to_string (KerName.label (Constant.canonical ctnt)) in
      let ty = EConstr.of_constr ty in
      let body = EConstr.of_constr body in
      let pp = genc_func env sigma fname ty body in
      Feedback.msg_info pp)
    libref_list

let genc_file (fn : string) (libref_list : Libnames.qualid list) : unit =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  (let ch = open_out fn in
  let fmt = Format.formatter_of_out_channel ch in
  List.iter
    (fun libref ->
      let (ctnt, ty, body) = get_ctnt_type_body env libref in
      linear_type_check_term body;
      let fname = Label.to_string (KerName.label (Constant.canonical ctnt)) in
      let ty = EConstr.of_constr ty in
      let body = EConstr.of_constr body in
      let pp = genc_func env sigma fname ty body in
      Pp.pp_with fmt (pp ++ Pp.fnl ()))
    libref_list;
  Format.pp_print_flush fmt ();
  close_out ch;
  Feedback.msg_info (str ("file generated: " ^ fn)))
