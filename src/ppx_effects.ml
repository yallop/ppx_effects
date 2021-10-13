(*————————————————————————————————————————————————————————————————————————————
   Copyright (c) 2021 Craig Ferguson <me@craigfe.io>
   Distributed under the MIT license. See terms at the end of this file.
  ————————————————————————————————————————————————————————————————————————————*)

open Ppxlib
open Ast_builder.Default

let namespace = "ppx_effects"
let pp_quoted ppf s = Format.fprintf ppf "‘%s’" s

(** Cases of [match] / [try] can be partitioned into three categories:

    - exception patterns (uing the [exception] keyword);
    - effect patterns (written using [\[%effect? ...\]]);
    - return patterns (available only to [match]).

    The [Obj.Effect_handlers] API requires passing different continuations for
    each of these categories. *)
module Cases = struct
  type partitioned = { ret : cases; exn : cases; eff : cases }

  let partition : cases -> partitioned =
    ListLabels.fold_right ~init:{ ret = []; exn = []; eff = [] }
      ~f:(fun case acc ->
        match case.pc_lhs with
        | [%pat? [%effect? [%p? eff_pattern], [%p? k_pattern]]] ->
            let case =
              {
                case with
                pc_lhs = eff_pattern;
                pc_rhs =
                  (let loc = case.pc_rhs.pexp_loc in
                   [%expr
                     Some
                       (fun ([%p k_pattern] :
                              (a, _) Obj.Effect_handlers.Deep.continuation) ->
                         [%e case.pc_rhs])]);
              }
            in
            { acc with eff = case :: acc.eff }
        | [%pat? exception [%p? exn_pattern]] ->
            let case = { case with pc_lhs = exn_pattern } in
            { acc with exn = case :: acc.exn }
        | _ ->
            (* TODO: handle guards on effects and exceptions properly *)
            { acc with ret = case :: acc.ret })

  let contain_effect_handler : cases -> bool =
    List.exists (fun case ->
        match case.pc_lhs with [%pat? [%effect? [%p? _]]] -> true | _ -> false)
end

(** The [Obj.Effect_handlers] API requires effects to happen under a function
    application *)
module Scrutinee = struct
  type delayed = { function_ : expression; argument : expression }

  (* An expression is a syntactic value if its AST structure precludes it from
     raising an effect or an exception. Here we use a very simple
     under-approximation (avoiding multiple recursion): *)
  let rec expr_is_syntactic_value (expr : expression) : bool =
    match expr.pexp_desc with
    | Pexp_ident _ | Pexp_constant _ | Pexp_function _ | Pexp_fun _
    | Pexp_construct (_, None)
    | Pexp_variant (_, None)
    | Pexp_field _ | Pexp_lazy _ ->
        true
    | Pexp_let _ | Pexp_apply _ | Pexp_match _ | Pexp_try _ | Pexp_tuple _
    | Pexp_record _ | Pexp_setfield _ | Pexp_array _ | Pexp_ifthenelse _
    | Pexp_sequence _ | Pexp_while _ | Pexp_for _ | Pexp_new _ | Pexp_override _
    | Pexp_letmodule _ | Pexp_object _ | Pexp_pack _ | Pexp_letop _
    | Pexp_extension _ | Pexp_unreachable ->
        false
    (* Congruence cases: *)
    | Pexp_constraint (e, _)
    | Pexp_coerce (e, _, _)
    | Pexp_construct (_, Some e)
    | Pexp_variant (_, Some e)
    | Pexp_send (e, _)
    | Pexp_setinstvar (_, e)
    | Pexp_letexception (_, e)
    | Pexp_assert e
    | Pexp_newtype (_, e)
    | Pexp_open (_, e) ->
        expr_is_syntactic_value e
    | Pexp_poly _ -> assert false

  let of_expression = function
    | [%expr [%e? function_] [%e? argument]]
      when expr_is_syntactic_value function_ && expr_is_syntactic_value argument
      ->
        { function_; argument }
    | e ->
        (* If the expression is not already of the form [f x] then we must
           allocate a thunk to delay the effect. *)
        let loc = e.pexp_loc in
        (* NOTE: here we use [`unit] over [()] in case the user has
           shadowed the unit constructor. *)
        let function_ = [%expr fun `unit -> [%e e]] in
        let argument = [%expr `unit] in
        { function_; argument }
end

let effc ~loc cases =
  [%expr
    fun (type a) (effect : a Obj.Effect_handlers.eff) ->
      [%e
        pexp_match ~loc [%expr effect]
          (cases @ [ case ~lhs:[%pat? _] ~guard:None ~rhs:[%expr None] ])]]

let impl : structure -> structure =
  (object (this)
     inherit Ast_traverse.map as super

     method! expression expr =
       let loc = expr.pexp_loc in
       match expr with
       (* match _ with [%effect? E _, k] -> ... *)
       | { pexp_desc = Pexp_match (scrutinee, cases); _ }
         when Cases.contain_effect_handler cases ->
           let scrutinee =
             Scrutinee.of_expression (super#expression scrutinee)
           in
           let cases = Cases.partition cases in
           let expand_cases_rhs =
             List.map (fun case ->
                 { case with pc_rhs = this#expression case.pc_rhs })
           in
           let retc = pexp_function ~loc (cases.ret |> expand_cases_rhs)
           and exnc =
             pexp_function ~loc
               ((cases.exn |> expand_cases_rhs)
               @ [ case ~lhs:[%pat? e] ~guard:None ~rhs:[%expr raise e] ])
           and effc = effc ~loc (cases.eff |> expand_cases_rhs) in
           [%expr
             Obj.Effect_handlers.Deep.match_with [%e scrutinee.function_]
               [%e scrutinee.argument]
               { retc = [%e retc]; exnc = [%e exnc]; effc = [%e effc] }]
       (* try _ with [%effect? E _, k] -> ... *)
       | { pexp_desc = Pexp_try (scrutinee, cases); _ }
         when Cases.contain_effect_handler cases ->
           let scrutinee =
             Scrutinee.of_expression (super#expression scrutinee)
           in
           let cases = Cases.partition cases in
           let expand_cases_rhs =
             List.map (fun case ->
                 { case with pc_rhs = this#expression case.pc_rhs })
           in
           let effc = effc ~loc (cases.eff |> expand_cases_rhs) in
           [%expr
             Obj.Effect_handlers.Deep.try_with [%e scrutinee.function_]
               [%e scrutinee.argument]
               { effc = [%e effc] }]
       | e -> super#expression e

     method! structure_item stri =
       let loc = stri.pstr_loc in
       match stri with
       (* exception%effect ... *)
       | [%stri [%%effect [%%i? { pstr_desc = Pstr_exception exn; _ }]]] ->
           (* TODO: handle attributes on the extension? *)
           let name = exn.ptyexn_constructor.pext_name in
           let eff_type = Located.lident ~loc "Obj.Effect_handlers.eff" in
           let constrs, args =
             match exn.ptyexn_constructor.pext_kind with
             | Pext_decl (constrs, body) ->
                 let body =
                   Option.map
                     (fun typ -> ptyp_constr ~loc eff_type [ typ ])
                     body
                 in
                 (constrs, body)
             | Pext_rebind _ ->
                 Location.raise_errorf ~loc
                   "%s: cannot process effect defined as an alias of %a."
                   namespace pp_quoted name.txt
           in
           let params = [ (ptyp_any ~loc, (NoVariance, NoInjectivity)) ] in
           pstr_typext ~loc
             (type_extension ~loc ~path:eff_type ~params
                ~constructors:
                  [
                    extension_constructor ~loc ~name
                      ~kind:(Pext_decl (constrs, args));
                  ]
                ~private_:Public)
       | s -> super#structure_item s

     method! extension =
       function
       | { txt = "effect"; loc }, _ ->
           Location.raise_errorf ~loc
             "%s: dangling [%%effect ...] extension node. This node may be \
              used in the top level of %a or %a patterns as %a, or on an \
              exception definition as %a."
             namespace pp_quoted "match" pp_quoted "try" pp_quoted
             "[%effect? ...]" pp_quoted "exception%effect ..."
       | e -> super#extension e
  end)
    #structure

let () =
  Reserved_namespaces.reserve namespace;
  Driver.register_transformation ~impl namespace

(*————————————————————————————————————————————————————————————————————————————
   Copyright (c) 2021 Craig Ferguson <me@craigfe.io>

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
   THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.
  ————————————————————————————————————————————————————————————————————————————*)
