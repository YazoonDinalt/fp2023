(** Copyright 2021-2023, PavlushaSource, Kakadu *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open Ast
open Stdint
open Format
open InterpretTypes
open String
module StringMap = Map.Make (String)

module type MONAD_ERROR = sig
  include Base.Monad.S2

  val fail : 'e -> ('a, 'e) t

  val ( let* ) : ('a, 'e) t -> ('a -> ('b, 'e) t) -> ('b, 'e) t
end

type var_stack = {addr_in_stack: int; var_type: types}

type var_malloc = {own_heap: Bytes.t; var_type: types}

type variable = Stack_var of var_stack | Heap_var of var_malloc

type jmp_state = Break of bool | Return of bool | Continue of bool

type context =
  { return_type: types
  ; func_name: name
  ; stack: Bytes.t
  ; var_map: variable StringMap.t
  ; free_byte_stack: int
  ; functions_list: program
  ; last_value: value
  ; return_flag: bool }

module Interpret (M : MONAD_ERROR) = struct
  open M

  let shift_left x y = Base.Int32.shift_left x (Int32.to_int y)

  let shift_right x y = Base.Int32.shift_right x (Int32.to_int y)

  let take_var name var_map =
    match StringMap.find_opt name var_map with
    | Some var ->
        return var
    | None ->
        fail @@ UnknownVariable name

  let const_for_value ctx = function
    | V_int x ->
        return (ID_int32, I_Int32 (Int32.of_int x), ctx)
    | V_char x ->
        return (ID_char, I_Char x, ctx)
    | V_float _ ->
        fail Unreachable
    | V_void ->
        fail Unreachable
    | V_null ->
        fail Unreachable

  let rec cast_val old_val new_type =
    match (old_val, new_type) with
    | I_Int32 x, ID_int32 ->
        return (I_Int32 x)
    | I_Int32 x, ID_int16 ->
        return (I_Int16 (Int16.of_int32 x))
    | I_Int32 x, ID_int8 ->
        return (I_Int8 (Int8.of_int32 x))
    | I_Int32 x, ID_char ->
        let new_x = Int32.to_int x in
        if new_x <= 255 && new_x >= 0 then
          return (I_Char (Base.Char.of_int_exn new_x))
        else
          fail
          @@ ReturnTypeMismatch
               "Trying to convert int number not in char boundaries in char"
    | I_Int32 x, ID_bool ->
        return (I_Bool (if Int32.to_int x = 0 then false else true))
    (* cast to grow type early*)
    | I_Int16 x, _ ->
        cast_val (I_Int32 (Int32.of_int16 x)) new_type
    | I_Int8 x, _ ->
        cast_val (I_Int32 (Int32.of_int8 x)) new_type
    | I_Char x, _ ->
        cast_val (I_Int32 (Int32.of_int (Char.code x))) new_type
    | I_Bool x, _ ->
        cast_val (I_Int32 (Int32.of_int (Bool.to_int x))) new_type
    | _ ->
        fail @@ ReturnTypeMismatch "not supported type to cast"

  let find_necessary_func name func_list =
    let func_name = function Func_decl (_, func_name, _, _) -> func_name in
    Stdlib.List.find_opt
      (fun func -> String.equal (func_name func) name)
      func_list

  let relevant_type t1 t2 =
    match (t1, t2) with
    | ID_int32, _ | _, ID_int32 ->
        return ID_int32
    | ID_int16, _ | _, ID_int16 ->
        return ID_int16
    | ID_int8, _ | _, ID_int8 ->
        return ID_int8
    | ID_char, _ | _, ID_char ->
        return ID_char
    | ID_bool, _ | _, ID_bool ->
        return ID_bool
    | _ ->
        fail
        @@ ReturnTypeMismatch
             "It is impossible to compare this type with anything"

  let exec_int_arith_op value1 value2 op =
    let* x = cast_val value1 ID_int32 in
    let* y = cast_val value2 ID_int32 in
    match (x, y) with
    | I_Int32 x, I_Int32 y ->
        return (I_Int32 (op x y))
    | _ ->
        fail Unreachable

  let exec_int_logical_op value1 value2 op =
    let* x = cast_val value1 ID_int32 in
    let* y = cast_val value2 ID_int32 in
    match (x, y) with
    | I_Int32 x, I_Int32 y ->
        return (I_Bool (op x y))
    | _ ->
        fail Unreachable

  let check_zero x =
    let* x = cast_val x ID_int32 in
    match x with I_Int32 x when x = 0l -> return true | _ -> return false

  let rec exec_bin_op expr1 expr2 bin_op ctx =
    let* val1_type, val1, ctx = exec_expression expr1 ctx in
    match (bin_op, val1) with
    | And, I_Bool false ->
        return (ID_bool, I_Bool false, ctx)
    | Or, I_Bool true ->
        return (ID_bool, I_Bool true, ctx)
    | _ ->
        let* val2_type, val2, ctx = exec_expression expr2 ctx in
        let* res =
          match (bin_op, val1, val2) with
          | Add, x, y ->
              exec_int_arith_op x y Base.Int32.( + )
          | Sub, x, y ->
              exec_int_arith_op x y Base.Int32.( - )
          | Mul, x, y ->
              exec_int_arith_op x y Base.Int32.( * )
          | Div, x, y ->
              let* zero_exist = check_zero y in
              if not zero_exist then exec_int_arith_op x y Base.Int32.( / )
              else fail DivisionByZero
          | Mod, x, y ->
              let* zero_exist = check_zero y in
              if not zero_exist then exec_int_arith_op x y Base.Int32.( % )
              else fail DivisionByZero
          | Lshift, x, y ->
              exec_int_arith_op x y shift_left
          | Rshift, x, y ->
              exec_int_arith_op x y shift_right
          | Less, x, y ->
              exec_int_logical_op x y Base.Int32.( < )
          | LessOrEqual, x, y ->
              exec_int_logical_op x y Base.Int32.( <= )
          | Grow, x, y ->
              exec_int_logical_op x y Base.Int32.( > )
          | GrowOrEqual, x, y ->
              exec_int_logical_op x y Base.Int32.( >= )
          | Equal, x, y ->
              exec_int_logical_op x y Base.Int32.( = )
          | NotEqual, x, y ->
              exec_int_logical_op x y Base.Int32.( <> )
          | Or, _, y -> (
              let* y = cast_val y ID_int32 in
              match y with
              | I_Int32 y when y = 0l ->
                  return (I_Bool true)
              | _ ->
                  return (I_Bool false) )
          | And, _, y -> (
              let* y = cast_val y ID_int32 in
              match y with
              | I_Int32 y when y = 1l ->
                  return (I_Bool true)
              | _ ->
                  return (I_Bool false) )
        in
        let* necessary_type = relevant_type val1_type val2_type in
        let* return_val = cast_val res necessary_type in
        return (necessary_type, return_val, ctx)

  (* | Sub, x, y ->
     let* res = exec_bin_op' x y Base.Int32.( - ) in
     let* grow_type = change_grow_type val1_type val2_type in
     let* return_val = cast_val res grow_type in
     return (grow_type, return_val, ctx) *)
  and take_var name ctx =
    match StringMap.find_opt name ctx.var_map with
    | Some x ->
        return x
    | None ->
        fail (UnknownVariable name)

  and take_stack_var (var : var_stack) ctx =
    get_value_in_bytes ctx.stack var.addr_in_stack var.var_type
    >>= fun value -> return (var.var_type, value, ctx)

  and exec_un_op expr un_op ctx =
    match (un_op, expr) with
    | Address, Var_name name -> (
      match StringMap.find_opt name ctx.var_map with
      | Some (Heap_var var) ->
          fail NotImplemented
      | Some (Stack_var var) ->
          return (ID_int32, I_Int32 (Int32.of_int var.addr_in_stack), ctx)
      | None ->
          fail (UnknownVariable name) )
    | Dereference, Index (Var_name name, expr) ->
        fail NotImplemented
    | Dereference, Var_name name -> (
        take_var name ctx
        >>= function
        | Stack_var x -> (
            let* _, addres_in_stack, ctx = take_stack_var x ctx in
            match (addres_in_stack, x.var_type) with
            | I_Int32 addres_in_stack, Pointer t ->
                get_value_in_bytes ctx.stack (Int32.to_int addres_in_stack) t
                >>= fun deref_value -> return (t, deref_value, ctx)
            | _ ->
                fail @@ InvalidFunctionCall "dereference only pointer" )
        | _ ->
            fail NotImplemented )
    | _ ->
        fail
        @@ InvalidFunctionCall
             "the address can only be taken from the variable name"

  and is_simple_type = function
    | Pointer _ ->
        false
    | Array _ ->
        false
    | _ ->
        true

  and exec_expression expr ctx : (types * value * context, error) t =
    match expr with
    | Bin_expr (bin_op, expr1, expr2) ->
        exec_bin_op expr1 expr2 bin_op ctx
    | Const x ->
        const_for_value ctx x
    | Var_name x -> (
      match StringMap.find_opt x ctx.var_map with
      | Some (Heap_var var) ->
          fail Unreachable
      | Some (Stack_var var) ->
          take_stack_var var ctx
      | None ->
          fail (UnknownVariable x) )
    | Unary_expr (un_op, expr) ->
        exec_un_op expr un_op ctx
    | Index (Var_name name, x) -> (
        let* _, index_value, ctx = exec_expression x ctx in
        let* index_value = cast_val index_value ID_int32 in
        let* var = take_var name ctx in
        let* _, addr_start, ctx = exec_expression (Var_name name) ctx in
        let* addr_start = cast_val addr_start ID_int32 in
        match (var, index_value, addr_start) with
        | Heap_var _, I_Int32 index, I_Int32 addr_start ->
            fail Unreachable
        | Stack_var x, I_Int32 index, I_Int32 addr_start -> (
          match x.var_type with
          | Pointer t when is_simple_type t ->
              let* return_value =
                get_value_in_bytes ctx.stack
                  ( Int32.to_int addr_start
                  + (get_size_type t * Int32.to_int index) )
                  t
              in
              return (t, return_value, ctx)
          | _ ->
              fail (InvalidFunctionCall "Only the index can be indexed") )
        | _ ->
            fail Unreachable )
    | Index _ ->
        fail NotImplemented
    | Func_call (func_name, func_args) -> (
      match find_necessary_func func_name ctx.functions_list with
      | Some Func_decl(return_type, func_name, args, sts) -> (
        
      )
      | None ->
          fail
            (UnknownVariable ("Call undefined function with name - " ^ func_name)
            ) )
    (* | Func_call (func_name, func_args) -> (
        let rec get_name_args arg_list =
          match arg_list with
          | hd :: tail -> (
            match hd with Arg (_, n) -> nfail
              (UnknownVariable
                 ("Call undefined function with name - " ^ func_name) ) ) :: get_name_args tail )
          | [] ->
              []
        in
        match find_necessary_func func_name ctx.functions with
        | Some func_finded -> (
          match func_finded with
          | Func_def (Func_decl (return_type, func_name, args), _) ->
              let* ctx' =
                List.fold_left2
                  (fun ctx' argument expr ->
                    let* ctx' = ctx' in
                    let* ctx' =
                      match argument with
                      | Arg (t, n) ->
                          exec_declaration t n (Some (Expression expr)) ctx'
                    in
                    return ctx' )
                  (return {ctx with func_name; return_type})
                  args func_args
              in
              let arg_names = get_name_args args in
              let ctx' =
                { ctx' with
                  var_map=
                    StringMap.filter
                      (fun name _ ->
                        List.exists (fun arg_name -> arg_name = name) arg_names
                        )
                      ctx'.var_map }
              in
              let* ret_val, ctx' = exec_function func_finded (return ctx') in
              return (return_type, ret_val, ctx')
          | _ ->
              fail Unreachable )
        | None ->
            fail
              (UnknownVariable
                 ("Call undefined function with name - " ^ func_name) ) ) *)
    (* | Var_name name -> (
        let* variable = take_var name ctx.var_map in
        match variable with
        | {var_type= t; var_value= Some v; var_addr= -1} ->
            return (t, v, ctx)
        | _ ->
            fail NotImplemented ) *)
    | _ ->
        fail NotImplemented

  and set_value_to_bytes bts addr = function
    | I_Int32 x ->
        Bytes.set_int32_le bts addr x
    | I_Int16 x ->
        Bytes.set_int16_le bts addr @@ Int16.to_int x
    | I_Int8 x ->
        Bytes.set_int8 bts addr @@ Int8.to_int x
    | I_Char x ->
        Bytes.set bts addr x
    | I_Bool x ->
        Bytes.set_int8 bts addr @@ Bool.to_int x
    | I_Null ->
        ()

  and get_value_in_bytes bts addr = function
    | ID_int32 ->
        return (I_Int32 (Int32.of_bytes_little_endian bts addr))
    | ID_int16 ->
        return (I_Int16 (Int16.of_bytes_little_endian bts addr))
    | ID_int8 ->
        return (I_Int8 (Int8.of_bytes_little_endian bts addr))
    | ID_char ->
        return (I_Char (Bytes.get bts addr))
    | Pointer _ ->
        return (I_Int32 (Int32.of_bytes_little_endian bts addr))
    | _ ->
        fail NotImplemented

  and update_var name ctx value =
    match StringMap.find_opt name ctx.var_map with
    | Some (Stack_var var_in_stack) ->
        cast_val value var_in_stack.var_type
        >>= fun value ->
        let () =
          set_value_to_bytes ctx.stack var_in_stack.addr_in_stack value
        in
        return ctx
    | Some (Heap_var var_in_heap) ->
        fail Unreachable
    | None ->
        fail @@ UnknownVariable name

  and exec_assign name ctx expr =
    exec_expression expr ctx
    >>= fun (type_val, return_value, ctx) -> update_var name ctx return_value

  and take_necassary_bytes ctx = function
    | Heap_var x ->
        return x.own_heap
    | Stack_var x ->
        return ctx.stack

  and take_simple_type (var : variable) =
    let rec take_simple_type' = function
      | Pointer t ->
          take_simple_type' t
      | Array (_, t) ->
          take_simple_type' t
      | x ->
          x
    in
    match var with
    | Heap_var var ->
        take_simple_type' var.var_type
    | Stack_var var ->
        take_simple_type' var.var_type

  and exec_statement (st : statement) ctx =
    match st with
    | Return expr ->
        let* _, return_value, ctx = exec_expression expr ctx in
        let* return_value = cast_val return_value ctx.return_type in
        return {ctx with last_value= return_value; return_flag= true}
    | Var_decl (type_var, name, statement) -> (
      match statement with
      | Some (Expression expr) ->
          exec_declaration ctx type_var name expr
      | None ->
          let* default_value = get_default_value type_var in
          add_var_in_stack type_var default_value name ctx
      | _ ->
          fail NotImplemented )
    | Assign (expr_l, st) -> (
      match (st, expr_l) with
      | Expression expr_r, Var_name name ->
          let* _, assign_value, ctx = exec_expression expr_r ctx in
          update_var name ctx assign_value
      | Expression expr_r, Unary_expr (Dereference, Var_name name) -> (
          let* _, r_expr_value, ctx = exec_expression expr_r ctx in
          take_var name ctx
          >>= function
          | Heap_var x ->
              fail NotImplemented
          | Stack_var x -> (
            match x.var_type with
            | Pointer t -> (
                let* r_expr_value = cast_val r_expr_value t in
                let* _, addres_in_stack, ctx = take_stack_var x ctx in
                match addres_in_stack with
                | I_Int32 x ->
                    let () =
                      set_value_to_bytes ctx.stack (Int32.to_int x) r_expr_value
                    in
                    return ctx
                | _ ->
                    fail Unreachable )
            | _ ->
                fail @@ InvalidFunctionCall "Dereference must be only ptr type"
            ) )
      | Expression expr_r, Index (Var_name name, x) -> (
          let* _, assign_value, ctx = exec_expression expr_r ctx in
          let* var = take_var name ctx in
          let* assign_value = cast_val assign_value (take_simple_type var) in
          let* bt = take_necassary_bytes ctx var in
          let* _, addr_pointer, ctx = exec_expression (Var_name name) ctx in
          let* _, index_val, ctx = exec_expression x ctx in
          let* index_int32 = cast_val index_val ID_int32 in
          match (index_int32, addr_pointer) with
          | I_Int32 index_int32, I_Int32 addr_pointer ->
              let () =
                set_value_to_bytes bt
                  ( Int32.to_int addr_pointer
                  + Int32.to_int index_int32
                    * get_size_type (take_simple_type var) )
                  assign_value
              in
              return ctx
          | _ ->
              fail Unreachable )
      | _ ->
          fail NotImplemented )
    | _ ->
        fail NotImplemented

  and add_var_in_heap type_var size_heap name ctx =
    cast_val size_heap ID_int32
    >>= function
    | I_Int32 x ->
        return
          { ctx with
            var_map=
              StringMap.add name
                (Heap_var
                   {own_heap= Bytes.create (Int32.to_int x); var_type= type_var}
                )
                ctx.var_map }
    | _ ->
        fail Unreachable

  and get_size_type = function
    | ID_int32 ->
        4
    | ID_int16 ->
        2
    | ID_int8 | ID_char ->
        1
    | Pointer t ->
        get_size_type t
    | Array (_, t) ->
        get_size_type t
    | _ ->
        2048

  and add_var_in_stack type_var value name ctx =
    if ctx.free_byte_stack + get_size_type type_var < 1024 then
      let () = set_value_to_bytes ctx.stack ctx.free_byte_stack value in
      return
        { ctx with
          var_map=
            StringMap.add name
              (Stack_var {addr_in_stack= ctx.free_byte_stack; var_type= type_var}
              )
              ctx.var_map
        ; free_byte_stack= ctx.free_byte_stack + get_size_type type_var }
    else fail StackOverflow

  and get_default_value = function
    | ID_int8 ->
        return (I_Int8 (Int8.of_int 0))
    | ID_int16 ->
        return (I_Int16 (Int16.of_int 0))
    | ID_int32 ->
        return (I_Int32 (Int32.of_int 0))
    | ID_uint16 | ID_uint32 | ID_uint8 | ID_float | ID_void ->
        fail NotImplemented
    | ID_bool ->
        return (I_Bool true)
    | ID_char ->
        return (I_Char (Base.Char.of_int_exn 0))
    | Pointer _ ->
        return (I_Int32 (Int32.of_int 0))
    | Array _ ->
        return (I_Int32 (Int32.of_int 0))

  and exec_declaration_simple_var ctx type_var name expr =
    match expr with
    | Func_call ("malloc", _) ->
        fail @@ InvalidFunctionCall "malloc not supported for simple type"
    | _ ->
        exec_expression expr ctx
        >>= fun (_, expr_value, ctx) ->
        cast_val expr_value type_var
        >>= fun expr_value -> add_var_in_stack type_var expr_value name ctx

  and exec_declaration_pointer_var ctx type_var name expr =
    match expr with
    | Func_call ("malloc", [expr]) ->
        fail NotImplemented
    | Func_call ("malloc", _) ->
        fail
        @@ InvalidFunctionCall
             "there are too many arguments for the signature malloc function"
    | _ ->
        exec_expression expr ctx
        >>= fun (_, expr_value, ctx) ->
        cast_val expr_value ID_int32
        >>= fun expr_value -> add_var_in_stack type_var expr_value name ctx

  and exec_declaration_array_var ctx type_var name expr =
    let add_var_without_name ctx value =
      if ctx.free_byte_stack + get_size_type type_var < 1024 then
        let () = set_value_to_bytes ctx.stack ctx.free_byte_stack value in
        return
          { ctx with
            free_byte_stack= ctx.free_byte_stack + get_size_type type_var }
      else fail StackOverflow
    in
    match expr with
    | Array_value exp_list ->
        let addr_first_elm = ctx.free_byte_stack in
        let* ctx =
          List.fold_left
            (fun ctx expr ->
              let* ctx = ctx in
              let* _, value_expr, ctx = exec_expression expr ctx in
              let* value_expr = cast_val value_expr type_var in
              add_var_without_name ctx value_expr )
            (return ctx) exp_list
        in
        let* ctx =
          exec_declaration_pointer_var ctx (Pointer type_var) name
            (Const (V_int addr_first_elm))
        in
        return ctx
    | _ ->
        fail @@ InvalidFunctionCall "Array definition only {....} template"

  and exec_declaration ctx type_var name expr =
    match type_var with
    | ID_bool | ID_int8 | ID_int16 | ID_int32 | ID_char ->
        exec_declaration_simple_var ctx type_var name expr
    | ID_void ->
        fail UndefinedTypesConst
    | Pointer ID_bool
    | Pointer ID_int8
    | Pointer ID_int16
    | Pointer ID_int32
    | Pointer ID_char ->
        exec_declaration_pointer_var ctx type_var name expr
    | Pointer _ ->
        fail NotImplemented
    | Array (_, t) ->
        exec_declaration_array_var ctx t name expr
    | ID_uint32 | ID_uint16 | ID_uint8 | ID_float ->
        fail NotImplemented

  and exec_function func ctx =
    match func with
    | Func_decl (return_type, _, _, body) -> (
      match body with
      | Compound sts ->
          let* ctx =
            List.fold_left
              (fun ctx st ->
                let* ctx = ctx in
                if ctx.return_flag = true then return ctx
                else
                  let* ctx = exec_statement st ctx in
                  return ctx )
              ctx sts
          in
          cast_val ctx.last_value return_type
          >>= fun last_value -> return (last_value, {ctx with last_value})
      | _ ->
          fail Unreachable )

  let exec_program program =
    match find_necessary_func "main" program with
    | Some func ->
        exec_function func
          (return
             { func_name= "main"
             ; return_type= ID_int32
             ; var_map= StringMap.empty
             ; stack= Bytes.create 1024
             ; free_byte_stack= 0
             ; functions_list= program
             ; return_flag= false
             ; last_value= I_Null } )
    | None ->
        fail @@ NoFunctionDeclaration "main"
end

module MONAD_RESULT = struct
  include Base.Result

  let ( let* ) m f = m >>= fun x -> f x
end

module InterpreterResult = Interpret (MONAD_RESULT)

let parse_and_run str =
  match Parser.parse str with
  | Ok parse_result -> (
    match InterpreterResult.exec_program parse_result with
    | Ok (value, _) ->
        printf "%a" InterpretTypes.pp_value value
    | Error err ->
        printf "%a" InterpretTypes.pp_error err )
  | Error _ ->
      print_endline "Parsing Error!"

let%expect_test _ =
  let _ =
    parse_and_run
      {|
      int main() {
        int8_t a = 10;
        int* b = &a;
        int32_t* c = b;
        *c = 30;
        return a;
      }
      |}
  in
  [%expect {| 30 |}]

let%expect_test _ =
  let _ =
    parse_and_run
      {|
      int main() {
        int8_t a[3] = {1, 2, 3};
        int8_t* b = a;
        return b[1];
      }
      |}
  in
  [%expect {| 2 |}]

let%expect_test _ =
  let _ =
    parse_and_run
      {|
      int main() {
        int32_t count = 10;
        int32_t a[4] = {1 * 3, 2 + 2, 52, 1337};
        a[1] = 52;
        return a[1];
      }
      |}
  in
  [%expect {| 52 |}]
