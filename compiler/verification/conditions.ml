(* This file is part of the Catala compiler, a specification language for tax and social benefits
   computation rules. Copyright (C) 2022 Inria, contributor: Denis Merigoux
   <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
   in compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software distributed under the License
   is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
   or implied. See the License for the specific language governing permissions and limitations under
   the License. *)

open Utils
open Dcalc
open Ast

type vc_return = expr Pos.marked * typ Pos.marked VarMap.t
(** The return type of VC generators is the VC expression plus the types of any locally free
    variable inside that expression. *)

let conjunction (args : vc_return list) (pos : Pos.t) : vc_return =
  let acc, list =
    match args with hd :: tl -> (hd, tl) | [] -> (((ELit (LBool true), pos), VarMap.empty), [])
  in
  List.fold_left
    (fun (acc, acc_ty) (arg, arg_ty) ->
      ( (EApp ((EOp (Binop And), pos), [ arg; acc ]), pos),
        VarMap.union (fun _ _ _ -> failwith "should not happen") acc_ty arg_ty ))
    acc list

let negation ((arg, arg_ty) : vc_return) (pos : Pos.t) : vc_return =
  ((EApp ((EOp (Unop Not), pos), [ arg ]), pos), arg_ty)

let disjunction (args : vc_return list) (pos : Pos.t) : vc_return =
  let acc, list =
    match args with hd :: tl -> (hd, tl) | [] -> (((ELit (LBool false), pos), VarMap.empty), [])
  in
  List.fold_left
    (fun ((acc, acc_ty) : vc_return) (arg, arg_ty) ->
      ( (EApp ((EOp (Binop Or), pos), [ arg; acc ]), pos),
        VarMap.union (fun _ _ _ -> failwith "should not happen") acc_ty arg_ty ))
    acc list

type ctx = { decl : decl_ctx; input_vars : Var.t list }

(** [generate_vc_must_not_return_empty_e] returns the logical expression [b] such that if [b] is
    true, then [e] will never return an empty error. It also returns a map of all the types of
    locally free variables inside the expression. TODO: right now this code skims through the
    topmost layers of the terms like this: [error on empty < reentrant_variable () | true :- e1 >].
    But what we really want to analyze is only e1, so we should match this outermost structure
    explicitely and have a clean verification condition generator that only runs on e1. *)
let rec generate_vc_must_not_return_empty (ctx : ctx) (e : expr Pos.marked) : vc_return =
  let out =
    match Pos.unmark e with
    | ETuple (args, _) | EArray args ->
        conjunction (List.map (generate_vc_must_not_return_empty ctx) args) (Pos.get_position e)
    | EMatch (arg, arms, _) ->
        conjunction
          (List.map (generate_vc_must_not_return_empty ctx) (arg :: arms))
          (Pos.get_position e)
    | ETupleAccess (e1, _, _, _) | EInj (e1, _, _, _) | EAssert e1 | ErrorOnEmpty e1 ->
        (generate_vc_must_not_return_empty ctx) e1
    | EAbs (binder, typs) ->
        (* Hot take: for a function never to return an empty error when called, it has to do
           so whatever its input. So we universally quantify over the variable of the function
           when inspecting the body, resulting in simply traversing through in the code here. *)
        let vars, body = Bindlib.unmbind (Pos.unmark binder) in
        let vc_body_expr, vc_body_ty = (generate_vc_must_not_return_empty ctx) body in
        ( vc_body_expr,
          List.fold_left
            (fun acc (var, ty) -> VarMap.add var ty acc)
            vc_body_ty
            (List.map2 (fun x y -> (x, y)) (Array.to_list vars) typs) )
    | EApp ((EVar (x, _), _), [ (ELit LUnit, _) ])
      when List.exists (fun x' -> Bindlib.eq_vars x x') ctx.input_vars ->
        (* Here we have a special case. If all the default trees in all the scopes of our
           program respect our verification, then there will be no empty error anywhere. Except at
           one place: when we don't pass a redefining argument to a callee scope. This matches
           the reentrant expressions in our default trees. *)
        (Pos.same_pos_as (ELit (LBool false)) e, VarMap.empty)
    | EApp (f, args) ->
        conjunction
          (List.map (generate_vc_must_not_return_empty ctx) (f :: args))
          (Pos.get_position e)
    | EIfThenElse (e1, e2, e3) ->
        conjunction
          (List.map (generate_vc_must_not_return_empty ctx) [ e1; e2; e3 ])
          (Pos.get_position e)
    | ELit LEmptyError -> (Pos.same_pos_as (ELit (LBool false)) e, VarMap.empty)
    | EVar _
    (* Per default calculus semantics, you cannot call a function with an argument
       that evaluates to the empty error. Thus, all variable evaluate to non-empty-error terms. *)
    | ELit _ | EOp _ ->
        (Pos.same_pos_as (ELit (LBool true)) e, VarMap.empty)
    | EDefault (exceptions, just, cons) ->
        (* <e1 ... en | ejust :- econs > never returns empty if and only if:
           - first we look if e1 .. en ejust can return empty;
           - if no, we check that if ejust is true, whether econs can return empty.
        *)
        disjunction
          (List.map (generate_vc_must_not_return_empty ctx) exceptions
          @ [
              conjunction
                [
                  generate_vc_must_not_return_empty ctx just;
                  (let vc_just_expr, vc_just_ty = generate_vc_must_not_return_empty ctx cons in
                   ( ( EIfThenElse
                         ( just,
                           (* TODO : the justification is not checked for holding an default term.
                              In such cases, we need to encode the logic of the default terms within
                              the generation of the verification condition (Z3encoding.translate_expr).
                              Answer from Denis: Normally, there is a structural invariant from the
                              surface language to intermediate representation translation preventing
                              any default terms to appear in justifications.*)
                           vc_just_expr,
                           (ELit (LBool false), Pos.get_position e) ),
                       Pos.get_position e ),
                     vc_just_ty ));
                ]
                (Pos.get_position e);
            ])
          (Pos.get_position e)
  in
  (* Cli.debug_print
     (Format.asprintf ">>> Input:@\n%a@\nOutput:@\n%a" (Print.format_expr ctx.decl) e
        (Print.format_expr ctx.decl) out); *)
  out
  [@@ocamlformat "wrap-comments=false"]

let half_product l1 l2 =
  l1
  |> List.mapi (fun i ei -> List.filteri (fun j _ -> i < j) l2 |> List.map (fun ej -> (ei, ej)))
  |> List.concat

let rec generate_vs_must_not_return_confict (ctx : ctx) (e : expr Pos.marked) : vc_return =
  let out =
    match Pos.unmark e with
    | ETuple (args, _) | EArray args ->
        conjunction (List.map (generate_vs_must_not_return_confict ctx) args) (Pos.get_position e)
    | EMatch (arg, arms, _) ->
        conjunction
          (List.map (generate_vs_must_not_return_confict ctx) (arg :: arms))
          (Pos.get_position e)
    | ETupleAccess (e1, _, _, _) | EInj (e1, _, _, _) | EAssert e1 | ErrorOnEmpty e1 ->
        generate_vs_must_not_return_confict ctx e1
    | EAbs (binder, typs) ->
        (* there is a problem here : the error can be raised in a completly different context. We
           choose to pass throught for simplicity. *)
        let vars, body = Bindlib.unmbind (Pos.unmark binder) in
        let vc_body_expr, vc_body_ty = (generate_vs_must_not_return_confict ctx) body in
        ( vc_body_expr,
          List.fold_left
            (fun acc (var, ty) -> VarMap.add var ty acc)
            vc_body_ty
            (List.map2 (fun x y -> (x, y)) (Array.to_list vars) typs) )
    | EApp (f, args) ->
        conjunction
          (List.map (generate_vs_must_not_return_confict ctx) (f :: args))
          (Pos.get_position e)
    | EIfThenElse (e1, e2, e3) ->
        conjunction
          (List.map (generate_vs_must_not_return_confict ctx) [ e1; e2; e3 ])
          (Pos.get_position e)
    | EVar _ | ELit _ | EOp _ -> (Pos.same_pos_as (ELit (LBool true)) e, VarMap.empty)
    | EDefault (exceptions, just, cons) ->
        (* <e1 ... en | ejust :- econs > never returns conflict if and only if: - neither e1, ...,
           nor en nor ejust nor econs return conflict - there is no two differents ei ej that are
           not empty. *)
        let quadratic =
          negation
            (disjunction
               (List.map
                  (fun (e1, e2) ->
                    conjunction
                      [
                        generate_vc_must_not_return_empty ctx e1;
                        generate_vc_must_not_return_empty ctx e2;
                      ]
                      (Pos.get_position e))
                  (half_product exceptions exceptions))
               (Pos.get_position e))
            (Pos.get_position e)
        in

        let others =
          List.map (generate_vs_must_not_return_confict ctx) (just :: cons :: exceptions)
        in

        let out = conjunction (quadratic :: others) (Pos.get_position e) in

        (* let _ = Cli.debug_print (Format.asprintf ">>> Conflict,
           Input:@\n%a@\nQuadratic:@\n%a@\nOthers:@\n%a@\nOutput:@\n%a" (Print.format_expr ctx.decl)
           e (Print.format_expr ctx.decl) (Bindlib.unbox (Optimizations.optimize_expr quadratic))
           (Print.format_expr ctx.decl) (Bindlib.unbox (Optimizations.optimize_expr (conjunction
           others (Pos.get_position e)))) (Print.format_expr ctx.decl) (Bindlib.unbox
           (Optimizations.optimize_expr out))) in *)
        out
  in

  out

type verification_condition_kind = NoEmptyError | NoOverlappingExceptions

type verification_condition = {
  vc_guard : expr Pos.marked;
  (* should have type bool *)
  vc_kind : verification_condition_kind;
  vc_free_vars_typ : typ Pos.marked VarMap.t;
}

let generate_verification_conditions (p : program) : verification_condition list =
  List.fold_left
    (fun acc (_s_name, _s_var, s_body) ->
      let ctx = { decl = p.decl_ctx; input_vars = [] } in
      let acc, _ =
        List.fold_left
          (fun (acc, ctx) s_let ->
            match s_let.scope_let_kind with
            | DestructuringInputStruct ->
                (acc, { ctx with input_vars = Pos.unmark s_let.scope_let_var :: ctx.input_vars })
            | ScopeVarDefinition | SubScopeVarDefinition ->
                (* TODO: for scope variables, we should check both that they never evaluate to
                   emptyError nor conflictError. But for subscope variable definitions, what we're
                   really doing is adding exceptions to something defined in the subscope so we just
                   ought to verify only that the exceptions overlap. *)
                let e = Bindlib.unbox s_let.scope_let_expr in
                let vc_empty, vc_empty_typs = generate_vc_must_not_return_empty ctx e in
                let vc_empty =
                  if !Cli.optimize_flag then Bindlib.unbox (Optimizations.optimize_expr vc_empty)
                  else vc_empty
                in

                let vc_confl, vc_confl_typs = generate_vs_must_not_return_confict ctx e in
                let vc_confl =
                  if !Cli.optimize_flag then Bindlib.unbox (Optimizations.optimize_expr vc_confl)
                  else vc_confl
                in
                ( {
                    vc_guard = Pos.same_pos_as (Pos.unmark vc_confl) e;
                    vc_kind = NoOverlappingExceptions;
                    vc_free_vars_typ = vc_confl_typs;
                  }
                  :: {
                       vc_guard = Pos.same_pos_as (Pos.unmark vc_empty) e;
                       vc_kind = NoEmptyError;
                       vc_free_vars_typ = vc_empty_typs;
                     }
                  :: acc,
                  ctx )
            | _ -> (acc, ctx))
          (acc, ctx) s_body.scope_body_lets
      in
      acc)
    [] p.scopes
