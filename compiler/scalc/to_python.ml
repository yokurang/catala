(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
open Shared_ast
open Ast
module Runtime = Runtime_ocaml.Runtime
module D = Dcalc.Ast
module L = Lcalc.Ast

let format_lit (fmt : Format.formatter) (l : lit Mark.pos) : unit =
  match Mark.remove l with
  | LBool true -> Format.pp_print_string fmt "True"
  | LBool false -> Format.pp_print_string fmt "False"
  | LInt i ->
    Format.fprintf fmt "integer_of_string(\"%s\")" (Runtime.integer_to_string i)
  | LUnit -> Format.pp_print_string fmt "Unit()"
  | LRat i -> Format.fprintf fmt "decimal_of_string(\"%a\")" Print.lit (LRat i)
  | LMoney e ->
    Format.fprintf fmt "money_of_cents_string(\"%s\")"
      (Runtime.integer_to_string (Runtime.money_to_cents e))
  | LDate d ->
    Format.fprintf fmt "date_of_numbers(%d,%d,%d)"
      (Runtime.integer_to_int (Runtime.year_of_date d))
      (Runtime.integer_to_int (Runtime.month_number_of_date d))
      (Runtime.integer_to_int (Runtime.day_of_month_of_date d))
  | LDuration d ->
    let years, months, days = Runtime.duration_to_years_months_days d in
    Format.fprintf fmt "duration_of_numbers(%d,%d,%d)" years months days

let format_op (fmt : Format.formatter) (op : operator Mark.pos) : unit =
  match Mark.remove op with
  | Log (_entry, _infos) -> assert false
  | Minus_int | Minus_rat | Minus_mon | Minus_dur ->
    Format.pp_print_string fmt "-"
  (* Todo: use the names from [Operator.name] *)
  | Not -> Format.pp_print_string fmt "not"
  | Length -> Format.pp_print_string fmt "list_length"
  | ToRat_int -> Format.pp_print_string fmt "decimal_of_integer"
  | ToRat_mon -> Format.pp_print_string fmt "decimal_of_money"
  | ToMoney_rat -> Format.pp_print_string fmt "money_of_decimal"
  | GetDay -> Format.pp_print_string fmt "day_of_month_of_date"
  | GetMonth -> Format.pp_print_string fmt "month_number_of_date"
  | GetYear -> Format.pp_print_string fmt "year_of_date"
  | FirstDayOfMonth -> Format.pp_print_string fmt "first_day_of_month"
  | LastDayOfMonth -> Format.pp_print_string fmt "last_day_of_month"
  | Round_mon -> Format.pp_print_string fmt "money_round"
  | Round_rat -> Format.pp_print_string fmt "decimal_round"
  | Add_int_int | Add_rat_rat | Add_mon_mon | Add_dat_dur _ | Add_dur_dur
  | Concat ->
    Format.pp_print_string fmt "+"
  | Sub_int_int | Sub_rat_rat | Sub_mon_mon | Sub_dat_dat | Sub_dat_dur
  | Sub_dur_dur ->
    Format.pp_print_string fmt "-"
  | Mult_int_int | Mult_rat_rat | Mult_mon_rat | Mult_dur_int ->
    Format.pp_print_string fmt "*"
  | Div_int_int | Div_rat_rat | Div_mon_mon | Div_mon_rat | Div_dur_dur ->
    Format.pp_print_string fmt "/"
  | And -> Format.pp_print_string fmt "and"
  | Or -> Format.pp_print_string fmt "or"
  | Eq -> Format.pp_print_string fmt "=="
  | Xor -> Format.pp_print_string fmt "!="
  | Lt_int_int | Lt_rat_rat | Lt_mon_mon | Lt_dat_dat | Lt_dur_dur ->
    Format.pp_print_string fmt "<"
  | Lte_int_int | Lte_rat_rat | Lte_mon_mon | Lte_dat_dat | Lte_dur_dur ->
    Format.pp_print_string fmt "<="
  | Gt_int_int | Gt_rat_rat | Gt_mon_mon | Gt_dat_dat | Gt_dur_dur ->
    Format.pp_print_string fmt ">"
  | Gte_int_int | Gte_rat_rat | Gte_mon_mon | Gte_dat_dat | Gte_dur_dur ->
    Format.pp_print_string fmt ">="
  | Eq_int_int | Eq_rat_rat | Eq_mon_mon | Eq_dat_dat | Eq_dur_dur ->
    Format.pp_print_string fmt "=="
  | Map -> Format.pp_print_string fmt "list_map"
  | Map2 -> Format.pp_print_string fmt "list_map2"
  | Reduce -> Format.pp_print_string fmt "list_reduce"
  | Filter -> Format.pp_print_string fmt "list_filter"
  | Fold -> Format.pp_print_string fmt "list_fold_left"
  | HandleDefault -> Format.pp_print_string fmt "handle_default"
  | HandleDefaultOpt -> Format.pp_print_string fmt "handle_default_opt"
  | FromClosureEnv | ToClosureEnv -> failwith "unimplemented"

let format_uid_list (fmt : Format.formatter) (uids : Uid.MarkedString.info list)
    : unit =
  Format.fprintf fmt "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
       (fun fmt info ->
         Format.fprintf fmt "\"%a\"" Uid.MarkedString.format info))
    uids

let format_string_list (fmt : Format.formatter) (uids : string list) : unit =
  let sanitize_quotes = Re.compile (Re.char '"') in
  Format.fprintf fmt "[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
       (fun fmt info ->
         Format.fprintf fmt "\"%s\""
           (Re.replace sanitize_quotes ~f:(fun _ -> "\\\"") info)))
    uids

let avoid_keywords (s : string) : string =
  if
    match s with
    (* list taken from
       https://www.programiz.com/python-programming/keyword-list *)
    | "False" | "None" | "True" | "and" | "as" | "assert" | "async" | "await"
    | "break" | "class" | "continue" | "def" | "del" | "elif" | "else"
    | "except" | "finally" | "for" | "from" | "global" | "if" | "import" | "in"
    | "is" | "lambda" | "nonlocal" | "not" | "or" | "pass" | "raise" | "return"
    | "try" | "while" | "with" | "yield" ->
      true
    | _ -> false
  then s ^ "_"
  else s

module StringMap = String.Map

module IntMap = Map.Make (struct
  include Int

  let format ppf i = Format.pp_print_int ppf i
end)

let format_name_cleaned (fmt : Format.formatter) (s : string) : unit =
  s
  |> String.to_ascii
  |> String.to_snake_case
  |> Re.Pcre.substitute ~rex:(Re.Pcre.regexp "\\.") ~subst:(fun _ -> "_dot_")
  |> String.to_ascii
  |> avoid_keywords
  |> Format.fprintf fmt "%s"

(** For each `VarName.t` defined by its string and then by its hash, we keep
    track of which local integer id we've given it. This is used to keep
    variable naming with low indices rather than one global counter for all
    variables. TODO: should be removed when
    https://github.com/CatalaLang/catala/issues/240 is fixed. *)
let string_counter_map : int IntMap.t StringMap.t ref = ref StringMap.empty

let format_var (fmt : Format.formatter) (v : VarName.t) : unit =
  let v_str = Mark.remove (VarName.get_info v) in
  let hash = VarName.hash v in
  let local_id =
    match StringMap.find_opt v_str !string_counter_map with
    | Some ids -> (
      match IntMap.find_opt hash ids with
      | None ->
        let max_id =
          snd
            (List.hd
               (List.fast_sort
                  (fun (_, x) (_, y) -> Int.compare y x)
                  (IntMap.bindings ids)))
        in
        string_counter_map :=
          StringMap.add v_str
            (IntMap.add hash (max_id + 1) ids)
            !string_counter_map;
        max_id + 1
      | Some local_id -> local_id)
    | None ->
      string_counter_map :=
        StringMap.add v_str (IntMap.singleton hash 0) !string_counter_map;
      0
  in
  if v_str = "_" then Format.fprintf fmt "_"
    (* special case for the unit pattern *)
  else if local_id = 0 then format_name_cleaned fmt v_str
  else Format.fprintf fmt "%a_%d" format_name_cleaned v_str local_id

let format_path ctx fmt p =
  match List.rev p with
  | [] -> ()
  | m :: _ ->
    format_var fmt (ModuleName.Map.find m ctx.modules);
    Format.pp_print_char fmt '.'

let format_struct_name ctx (fmt : Format.formatter) (v : StructName.t) : unit =
  format_path ctx fmt (StructName.path v);
  Format.pp_print_string fmt
    (avoid_keywords
       (String.to_camel_case
          (String.to_ascii (Mark.remove (StructName.get_info v)))))

let format_struct_field_name (fmt : Format.formatter) (v : StructField.t) : unit
    =
  Format.pp_print_string fmt
    (avoid_keywords (String.to_ascii (StructField.to_string v)))

let format_enum_name ctx (fmt : Format.formatter) (v : EnumName.t) : unit =
  format_path ctx fmt (EnumName.path v);
  Format.pp_print_string fmt
    (avoid_keywords
       (String.to_camel_case
          (String.to_ascii (Mark.remove (EnumName.get_info v)))))

let format_enum_cons_name (fmt : Format.formatter) (v : EnumConstructor.t) :
    unit =
  Format.pp_print_string fmt
    (avoid_keywords (String.to_ascii (EnumConstructor.to_string v)))

let typ_needs_parens (e : typ) : bool =
  match Mark.remove e with TArrow _ | TArray _ -> true | _ -> false

let rec format_typ ctx (fmt : Format.formatter) (typ : typ) : unit =
  let format_typ = format_typ ctx in
  let format_typ_with_parens (fmt : Format.formatter) (t : typ) =
    if typ_needs_parens t then Format.fprintf fmt "(%a)" format_typ t
    else Format.fprintf fmt "%a" format_typ t
  in
  match Mark.remove typ with
  | TLit TUnit -> Format.fprintf fmt "Unit"
  | TLit TMoney -> Format.fprintf fmt "Money"
  | TLit TInt -> Format.fprintf fmt "Integer"
  | TLit TRat -> Format.fprintf fmt "Decimal"
  | TLit TDate -> Format.fprintf fmt "Date"
  | TLit TDuration -> Format.fprintf fmt "Duration"
  | TLit TBool -> Format.fprintf fmt "bool"
  | TTuple ts ->
    Format.fprintf fmt "Tuple[%a]"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ", ")
         (fun fmt t -> Format.fprintf fmt "%a" format_typ_with_parens t))
      ts
  | TStruct s -> Format.fprintf fmt "%a" (format_struct_name ctx) s
  | TOption some_typ ->
    (* We translate the option type with an overloading by Python's [None] *)
    Format.fprintf fmt "Optional[%a]" format_typ some_typ
  | TDefault t -> format_typ fmt t
  | TEnum e -> Format.fprintf fmt "%a" (format_enum_name ctx) e
  | TArrow (t1, t2) ->
    Format.fprintf fmt "Callable[[%a], %a]"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         format_typ_with_parens)
      t1 format_typ_with_parens t2
  | TArray t1 -> Format.fprintf fmt "List[%a]" format_typ_with_parens t1
  | TAny -> Format.fprintf fmt "Any"
  | TClosureEnv -> failwith "unimplemented!"

let format_func_name (fmt : Format.formatter) (v : FuncName.t) : unit =
  let v_str = Mark.remove (FuncName.get_info v) in
  format_name_cleaned fmt v_str

let format_exception (fmt : Format.formatter) (exc : except Mark.pos) : unit =
  let pos = Mark.get exc in
  match Mark.remove exc with
  | ConflictError _ ->
    Format.fprintf fmt
      "ConflictError(@[<hov 0>SourcePosition(@[<hov 0>filename=\"%s\",@ \
       start_line=%d,@ start_column=%d,@ end_line=%d,@ end_column=%d,@ \
       law_headings=%a)@])@]"
      (Pos.get_file pos) (Pos.get_start_line pos) (Pos.get_start_column pos)
      (Pos.get_end_line pos) (Pos.get_end_column pos) format_string_list
      (Pos.get_law_info pos)
  | EmptyError -> Format.fprintf fmt "EmptyError"
  | Crash -> Format.fprintf fmt "Crash"
  | NoValueProvided ->
    Format.fprintf fmt
      "NoValueProvided(@[<hov 0>SourcePosition(@[<hov 0>filename=\"%s\",@ \
       start_line=%d,@ start_column=%d,@ end_line=%d,@ end_column=%d,@ \
       law_headings=%a)@])@]"
      (Pos.get_file pos) (Pos.get_start_line pos) (Pos.get_start_column pos)
      (Pos.get_end_line pos) (Pos.get_end_column pos) format_string_list
      (Pos.get_law_info pos)

let rec format_expression ctx (fmt : Format.formatter) (e : expr) : unit =
  match Mark.remove e with
  | EVar v -> format_var fmt v
  | EFunc f -> format_func_name fmt f
  | EStruct { fields = es; name = s } ->
    Format.fprintf fmt "%a(%a)" (format_struct_name ctx) s
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt (struct_field, e) ->
           Format.fprintf fmt "%a = %a" format_struct_field_name struct_field
             (format_expression ctx) e))
      (StructField.Map.bindings es)
  | EStructFieldAccess { e1; field; _ } ->
    Format.fprintf fmt "%a.%a" (format_expression ctx) e1
      format_struct_field_name field
  | EInj { cons; name = e_name; _ }
    when EnumName.equal e_name Expr.option_enum
         && EnumConstructor.equal cons Expr.none_constr ->
    (* We translate the option type with an overloading by Python's [None] *)
    Format.fprintf fmt "None"
  | EInj { e1 = e; cons; name = e_name; _ }
    when EnumName.equal e_name Expr.option_enum
         && EnumConstructor.equal cons Expr.some_constr ->
    (* We translate the option type with an overloading by Python's [None] *)
    format_expression ctx fmt e
  | EInj { e1 = e; cons; name = enum_name; _ } ->
    Format.fprintf fmt "%a(%a_Code.%a,@ %a)" (format_enum_name ctx) enum_name
      (format_enum_name ctx) enum_name format_enum_cons_name cons
      (format_expression ctx) e
  | EArray es ->
    Format.fprintf fmt "[%a]"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt e -> Format.fprintf fmt "%a" (format_expression ctx) e))
      es
  | ELit l -> Format.fprintf fmt "%a" format_lit (Mark.copy e l)
  | EAppOp { op = (Map | Filter) as op; args = [arg1; arg2] } ->
    Format.fprintf fmt "%a(%a,@ %a)" format_op (op, Pos.no_pos)
      (format_expression ctx) arg1 (format_expression ctx) arg2
  | EAppOp { op; args = [arg1; arg2] } ->
    Format.fprintf fmt "(%a %a@ %a)" (format_expression ctx) arg1 format_op
      (op, Pos.no_pos) (format_expression ctx) arg2
  | EApp
      { f = EAppOp { op = Log (BeginCall, info); args = [f] }, _; args = [arg] }
    when Cli.globals.trace ->
    Format.fprintf fmt "log_begin_call(%a,@ %a,@ %a)" format_uid_list info
      (format_expression ctx) f (format_expression ctx) arg
  | EAppOp { op = Log (VarDef var_def_info, info); args = [arg1] }
    when Cli.globals.trace ->
    Format.fprintf fmt
      "log_variable_definition(%a,@ LogIO(input_io=InputIO.%s,@ \
       output_io=%s),@ %a)"
      format_uid_list info
      (match var_def_info.log_io_input with
      | Runtime.NoInput -> "NoInput"
      | Runtime.OnlyInput -> "OnlyInput"
      | Runtime.Reentrant -> "Reentrant")
      (if var_def_info.log_io_output then "True" else "False")
      (format_expression ctx) arg1
  | EAppOp { op = Log (PosRecordIfTrueBool, _); args = [arg1] }
    when Cli.globals.trace ->
    let pos = Mark.get e in
    Format.fprintf fmt
      "log_decision_taken(SourcePosition(filename=\"%s\",@ start_line=%d,@ \
       start_column=%d,@ end_line=%d, end_column=%d,@ law_headings=%a), %a)"
      (Pos.get_file pos) (Pos.get_start_line pos) (Pos.get_start_column pos)
      (Pos.get_end_line pos) (Pos.get_end_column pos) format_string_list
      (Pos.get_law_info pos) (format_expression ctx) arg1
  | EAppOp { op = Log (EndCall, info); args = [arg1] } when Cli.globals.trace ->
    Format.fprintf fmt "log_end_call(%a,@ %a)" format_uid_list info
      (format_expression ctx) arg1
  | EAppOp { op = Log _; args = [arg1] } ->
    Format.fprintf fmt "%a" (format_expression ctx) arg1
  | EAppOp { op = Not; args = [arg1] } ->
    Format.fprintf fmt "%a %a" format_op (Not, Pos.no_pos)
      (format_expression ctx) arg1
  | EAppOp
      {
        op = (Minus_int | Minus_rat | Minus_mon | Minus_dur) as op;
        args = [arg1];
      } ->
    Format.fprintf fmt "%a %a" format_op (op, Pos.no_pos)
      (format_expression ctx) arg1
  | EAppOp { op; args = [arg1] } ->
    Format.fprintf fmt "%a(%a)" format_op (op, Pos.no_pos)
      (format_expression ctx) arg1
  | EAppOp { op = (HandleDefault | HandleDefaultOpt) as op; args } ->
    let pos = Mark.get e in
    Format.fprintf fmt
      "%a(@[<hov 0>SourcePosition(filename=\"%s\",@ start_line=%d,@ \
       start_column=%d,@ end_line=%d, end_column=%d,@ law_headings=%a), %a)@]"
      format_op (op, pos) (Pos.get_file pos) (Pos.get_start_line pos)
      (Pos.get_start_column pos) (Pos.get_end_line pos) (Pos.get_end_column pos)
      format_string_list (Pos.get_law_info pos)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (format_expression ctx))
      args
  | EApp { f = EFunc x, pos; args }
    when Ast.FuncName.compare x Ast.handle_default = 0
         || Ast.FuncName.compare x Ast.handle_default_opt = 0 ->
    Format.fprintf fmt
      "%a(@[<hov 0>SourcePosition(filename=\"%s\",@ start_line=%d,@ \
       start_column=%d,@ end_line=%d, end_column=%d,@ law_headings=%a), %a)@]"
      format_func_name x (Pos.get_file pos) (Pos.get_start_line pos)
      (Pos.get_start_column pos) (Pos.get_end_line pos) (Pos.get_end_column pos)
      format_string_list (Pos.get_law_info pos)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (format_expression ctx))
      args
  | EApp { f; args } ->
    Format.fprintf fmt "%a(@[<hov 0>%a)@]" (format_expression ctx) f
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (format_expression ctx))
      args
  | EAppOp { op; args } ->
    Format.fprintf fmt "%a(@[<hov 0>%a)@]" format_op (op, Pos.no_pos)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (format_expression ctx))
      args
  | ETuple es ->
    Format.fprintf fmt "(%a)"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt e -> Format.fprintf fmt "%a" (format_expression ctx) e))
      es
  | ETupleAccess { e1; index } ->
    Format.fprintf fmt "%a[%d]" (format_expression ctx) e1 index
  | EExternal { modname; name } ->
    Format.fprintf fmt "%a.%a" format_var (Mark.remove modname)
      format_name_cleaned (Mark.remove name)

let rec format_statement ctx (fmt : Format.formatter) (s : stmt Mark.pos) : unit
    =
  match Mark.remove s with
  | SInnerFuncDef { name; func = { func_params; func_body; _ } } ->
    Format.fprintf fmt "@[<hov 4>def %a(%a):@\n%a@]" format_var
      (Mark.remove name)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ", ")
         (fun fmt (var, typ) ->
           Format.fprintf fmt "%a:%a" format_var (Mark.remove var)
             (format_typ ctx) typ))
      func_params (format_block ctx) func_body
  | SLocalDecl _ ->
    assert false (* We don't need to declare variables in Python *)
  | SLocalDef { name = v; expr = e; _ } | SLocalInit { name = v; expr = e; _ }
    ->
    Format.fprintf fmt "@[<hov 4>%a = %a@]" format_var (Mark.remove v)
      (format_expression ctx) e
  | STryExcept { try_block = try_b; except; with_block = catch_b } ->
    Format.fprintf fmt "@[<hov 4>try:@\n%a@]@\n@[<hov 4>except %a:@\n%a@]"
      (format_block ctx) try_b format_exception (except, Pos.no_pos)
      (format_block ctx) catch_b
  | SRaise except ->
    Format.fprintf fmt "@[<hov 4>raise %a@]" format_exception
      (except, Mark.get s)
  | SIfThenElse { if_expr = cond; then_block = b1; else_block = b2 } ->
    Format.fprintf fmt "@[<hov 4>if %a:@\n%a@]@\n@[<hov 4>else:@\n%a@]"
      (format_expression ctx) cond (format_block ctx) b1 (format_block ctx) b2
  | SSwitch
      {
        switch_expr = e1;
        enum_name = e_name;
        switch_cases =
          [
            { case_block = case_none; _ };
            { case_block = case_some; payload_var_name = case_some_var; _ };
          ];
        _;
      }
    when EnumName.equal e_name Expr.option_enum ->
    (* We translate the option type with an overloading by Python's [None] *)
    let tmp_var = VarName.fresh ("perhaps_none_arg", Pos.no_pos) in
    Format.fprintf fmt
      "%a = %a@\n\
       @[<hov 4>if %a is None:@\n\
       %a@]@\n\
       @[<hov 4>else:@\n\
       %a = %a@\n\
       %a@]"
      format_var tmp_var (format_expression ctx) e1 format_var tmp_var
      (format_block ctx) case_none format_var case_some_var format_var tmp_var
      (format_block ctx) case_some
  | SSwitch { switch_expr = e1; enum_name = e_name; switch_cases = cases; _ } ->
    let cons_map = EnumName.Map.find e_name ctx.decl_ctx.ctx_enums in
    let cases =
      List.map2
        (fun x (cons, _) -> x, cons)
        cases
        (EnumConstructor.Map.bindings cons_map)
    in
    let tmp_var = VarName.fresh ("match_arg", Pos.no_pos) in
    Format.fprintf fmt "%a = %a@\n@[<hov 4>if %a@]" format_var tmp_var
      (format_expression ctx) e1
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@]@\n@[<hov 4>elif ")
         (fun fmt ({ case_block; payload_var_name; _ }, cons_name) ->
           Format.fprintf fmt "%a.code == %a_Code.%a:@\n%a = %a.value@\n%a"
             format_var tmp_var (format_enum_name ctx) e_name
             format_enum_cons_name cons_name format_var payload_var_name
             format_var tmp_var (format_block ctx) case_block))
      cases
  | SReturn e1 ->
    Format.fprintf fmt "@[<hov 4>return %a@]" (format_expression ctx)
      (e1, Mark.get s)
  | SAssert e1 ->
    let pos = Mark.get s in
    Format.fprintf fmt
      "@[<hov 4>if not (%a):@\n\
       raise AssertionFailure(@[<hov 0>SourcePosition(@[<hov \
       0>filename=\"%s\",@ start_line=%d,@ start_column=%d,@ end_line=%d,@ \
       end_column=%d,@ law_headings=@[<hv>%a@])@])@]@]"
      (format_expression ctx)
      (e1, Mark.get s)
      (Pos.get_file pos) (Pos.get_start_line pos) (Pos.get_start_column pos)
      (Pos.get_end_line pos) (Pos.get_end_column pos) format_string_list
      (Pos.get_law_info pos)
  | SSpecialOp _ -> failwith "should not happen"

and format_block ctx (fmt : Format.formatter) (b : block) : unit =
  Format.pp_print_list
    ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
    (format_statement ctx) fmt
    (List.filter
       (fun s -> match Mark.remove s with SLocalDecl _ -> false | _ -> true)
       b)

let format_ctx
    (type_ordering : Scopelang.Dependency.TVertex.t list)
    (fmt : Format.formatter)
    ctx : unit =
  let format_struct_decl fmt (struct_name, struct_fields) =
    let fields = StructField.Map.bindings struct_fields in
    Format.fprintf fmt
      "class %a:@\n\
      \    def __init__(self, %a) -> None:@\n\
       %a@\n\
       @\n\
      \    def __eq__(self, other: object) -> bool:@\n\
      \        if isinstance(other, %a):@\n\
      \            return @[<hov>(%a)@]@\n\
      \        else:@\n\
      \            return False@\n\
       @\n\
      \    def __ne__(self, other: object) -> bool:@\n\
      \        return not (self == other)@\n\
       @\n\
      \    def __str__(self) -> str:@\n\
      \        @[<hov 4>return \"%a(%a)\".format(%a)@]" (format_struct_name ctx)
      struct_name
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ", ")
         (fun fmt (struct_field, struct_field_type) ->
           Format.fprintf fmt "%a: %a" format_struct_field_name struct_field
             (format_typ ctx) struct_field_type))
      fields
      (if StructField.Map.is_empty struct_fields then fun fmt _ ->
         Format.fprintf fmt "        pass"
       else
         Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
           (fun fmt (struct_field, _) ->
             Format.fprintf fmt "        self.%a = %a" format_struct_field_name
               struct_field format_struct_field_name struct_field))
      fields (format_struct_name ctx) struct_name
      (if not (StructField.Map.is_empty struct_fields) then
         Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt " and@ ")
           (fun fmt (struct_field, _) ->
             Format.fprintf fmt "self.%a == other.%a" format_struct_field_name
               struct_field format_struct_field_name struct_field)
       else fun fmt _ -> Format.fprintf fmt "True")
      fields (format_struct_name ctx) struct_name
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",")
         (fun fmt (struct_field, _) ->
           Format.fprintf fmt "%a={}" format_struct_field_name struct_field))
      fields
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt (struct_field, _) ->
           Format.fprintf fmt "self.%a" format_struct_field_name struct_field))
      fields
  in
  let format_enum_decl fmt (enum_name, enum_cons) =
    if EnumConstructor.Map.is_empty enum_cons then
      failwith "no constructors in the enum"
    else
      Format.fprintf fmt
        "@[<hov 4>class %a_Code(Enum):@\n\
         %a@]@\n\
         @\n\
         class %a:@\n\
        \    def __init__(self, code: %a_Code, value: Any) -> None:@\n\
        \        self.code = code@\n\
        \        self.value = value@\n\
         @\n\
         @\n\
        \    def __eq__(self, other: object) -> bool:@\n\
        \        if isinstance(other, %a):@\n\
        \            return self.code == other.code and self.value == \
         other.value@\n\
        \        else:@\n\
        \            return False@\n\
         @\n\
         @\n\
        \    def __ne__(self, other: object) -> bool:@\n\
        \        return not (self == other)@\n\
         @\n\
        \    def __str__(self) -> str:@\n\
        \        @[<hov 4>return \"{}({})\".format(self.code, self.value)@]"
        (format_enum_name ctx) enum_name
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
           (fun fmt (i, enum_cons, _enum_cons_type) ->
             Format.fprintf fmt "%a = %d" format_enum_cons_name enum_cons i))
        (List.mapi
           (fun i (x, y) -> i, x, y)
           (EnumConstructor.Map.bindings enum_cons))
        (format_enum_name ctx) enum_name (format_enum_name ctx) enum_name
        (format_enum_name ctx) enum_name
  in

  let is_in_type_ordering s =
    List.exists
      (fun struct_or_enum ->
        match struct_or_enum with
        | Scopelang.Dependency.TVertex.Enum _ -> false
        | Scopelang.Dependency.TVertex.Struct s' -> s = s')
      type_ordering
  in
  let scope_structs =
    List.map
      (fun (s, _) -> Scopelang.Dependency.TVertex.Struct s)
      (StructName.Map.bindings
         (StructName.Map.filter
            (fun s _ -> not (is_in_type_ordering s))
            ctx.decl_ctx.ctx_structs))
  in
  List.iter
    (fun struct_or_enum ->
      match struct_or_enum with
      | Scopelang.Dependency.TVertex.Struct s ->
        if StructName.path s = [] then
          Format.fprintf fmt "%a@\n@\n" format_struct_decl
            (s, StructName.Map.find s ctx.decl_ctx.ctx_structs)
      | Scopelang.Dependency.TVertex.Enum e ->
        if EnumName.path e = [] then
          Format.fprintf fmt "%a@\n@\n" format_enum_decl
            (e, EnumName.Map.find e ctx.decl_ctx.ctx_enums))
    (type_ordering @ scope_structs)

let format_code_item ctx fmt = function
  | SVar { var; expr; typ = _ } ->
    Format.fprintf fmt "@[<hv 4>%a = (@,%a@,@])@," format_var var
      (format_expression ctx) expr
  | SFunc { var; func }
  | SScope { scope_body_var = var; scope_body_func = func; _ } ->
    let { Ast.func_params; Ast.func_body; _ } = func in
    Format.fprintf fmt "@[<hv 4>def %a(%a):@\n%a@]@," format_func_name var
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ", ")
         (fun fmt (var, typ) ->
           Format.fprintf fmt "%a:%a" format_var (Mark.remove var)
             (format_typ ctx) typ))
      func_params (format_block ctx) func_body

let format_program
    (fmt : Format.formatter)
    (p : Ast.program)
    (type_ordering : Scopelang.Dependency.TVertex.t list) : unit =
  Format.pp_open_vbox fmt 0;
  let header =
    [
      "# This file has been generated by the Catala compiler, do not edit!";
      "";
      "from catala.runtime import *";
      "from typing import Any, List, Callable, Tuple";
      "from enum import Enum";
      "";
    ]
  in
  Format.pp_print_list Format.pp_print_string fmt header;
  ModuleName.Map.iter
    (fun m v ->
      Format.fprintf fmt "import %a as %a@," ModuleName.format m format_var v)
    p.ctx.modules;
  Format.pp_print_cut fmt ();
  format_ctx type_ordering fmt p.ctx;
  Format.pp_print_cut fmt ();
  Format.pp_print_list (format_code_item p.ctx) fmt p.code_items;
  Format.pp_print_flush fmt ()
